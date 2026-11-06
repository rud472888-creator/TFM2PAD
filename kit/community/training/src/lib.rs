//! Explicit team-scoped champion-training assignments using the original game codec.
mod native;
mod pins;
mod planner;
use mod_api_stable::{
    CommandResultV1, LogLevel, RecordKindV1 as Kind, ServerCtxV1, ServerExtRegV1,
    ServerExtVtableV1, StableClient, StableCommand, StableHost, StableMod, StableServerCtx,
};
use planner::{Assignment, Athlete, Champion};
use serde_json::{json, Value};
use std::{
    collections::BTreeSet,
    ffi::c_void,
    io::Write,
    sync::{Arc, Mutex},
};
const ID: &str = "tfm2_training_plus_ios";
const ROOT: &str = "main.top.right.training";
const PANEL: &str = "main.top.right.training.tvp_panel";
#[derive(Clone, Default)]
struct State {
    open: bool,
    dirty: bool,
    modes: [usize; 5],
    pending: bool,
    execute: bool,
    status: String,
    page: usize,
}
struct Client {
    state: Arc<Mutex<State>>,
}
#[derive(Default)]
struct Server {
    done: Mutex<BTreeSet<String>>,
}
fn log(event: &str) {
    let Some(home) = std::env::var_os("HOME") else {
        return;
    };
    let p = std::path::PathBuf::from(home)
        .join("Documents/GameRuntime/mods")
        .join(ID);
    if !p.is_dir() {
        return;
    }
    let p = p.join("training-ios-v1.log");
    if std::fs::metadata(&p).is_ok_and(|m| m.len() > 262144) {
        return;
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(p)
    {
        let _ = writeln!(f, "0.1.0 {event}");
    }
}
fn init(host: &StableHost) -> StableMod {
    host.log(
        LogLevel::Info,
        "Training 0.1: explicit champion plan assignments with authoritative and client cache synchronization",
    );
    log("loaded ABI10 native-codec adapter");
    let m = StableMod::new(ID);

    m
}
#[no_mangle]
pub extern "C" fn tfm2_mod_required_abi_level() -> u32 {
    10
}
#[no_mangle]
pub unsafe extern "C" fn tfm2_mod_entry_stable(
    host: *const mod_api_stable::HostApiV1,
) -> *mut mod_api_stable::ModExportV1 {
    let e = mod_api_stable::entry_shim(host, init);
    if !e.is_null() {
        (*e).extension = mod_api_stable::ExtensionRegV1 {
            userdata: Box::into_raw(Box::new(Client {
                state: Arc::new(Mutex::new(State::default())),
            }))
            .cast(),
            vtable: &CLIENT_TABLE,
        };
        (*e).server_ext = ServerExtRegV1 {
            userdata: Box::into_raw(Box::new(Server::default())).cast(),
            vtable: &SERVER_TABLE,
        };
    }
    e
}
unsafe extern "C" fn destroy(p: *mut c_void) {
    if !p.is_null() {
        drop(Box::from_raw(p as *mut Server));
    }
}
unsafe extern "C" fn started(_: *mut c_void, _: *mut ServerCtxV1) {
    log("server-start; no mutation");
}
unsafe extern "C" fn command(
    user: *mut c_void,
    raw: *mut ServerCtxV1,
    c: *const u8,
    n: usize,
    p: *const u8,
    l: usize,
    player: usize,
    has_player: bool,
    team: usize,
    has_team: bool,
) -> u32 {
    if user.is_null() || c.is_null() || n > 128 || p.is_null() || l > 1024 * 1024 {
        return CommandResultV1::Pass as u32;
    }
    let Ok(name) = std::str::from_utf8(std::slice::from_raw_parts(c, n)) else {
        return CommandResultV1::Pass as u32;
    };
    if name != "tvp_apply" {
        return CommandResultV1::Pass as u32;
    }
    let Some(mut ctx) = StableServerCtx::from_raw(raw) else {
        return CommandResultV1::Handled as u32;
    };
    let cmd = StableCommand {
        command: name,
        payload: std::slice::from_raw_parts(p, l),
        sender_player_id: has_player.then_some(player),
        sender_team_id: has_team.then_some(team),
    };
    let (message, team, changes) = match (&*(user as *const Server)).apply(raw, &mut ctx, &cmd) {
        Ok((message, team, rows)) => (message, Some(team), rows),
        Err(e) => (e, None, Vec::new()),
    };
    let payload=json!({"message":message,"team":team,"changes":changes.iter().map(|r|json!([r.athlete,r.target])).collect::<Vec<_>>()}).to_string();
    ctx.emit_event(cmd.reply_target(), "tvp_result", payload.as_bytes());
    CommandResultV1::Handled as u32
}
static SERVER_TABLE: ServerExtVtableV1 = ServerExtVtableV1 {
    size: std::mem::size_of::<ServerExtVtableV1>(),
    destroy: Some(destroy),
    on_server_start: Some(started),
    before_management_tick: None,
    after_management_tick: None,
    handle_command: Some(command),
};
fn parse(s: Option<String>) -> Option<Value> {
    serde_json::from_str(&s?).ok()
}
fn champions(ctx: &StableClient<'_>) -> Vec<Champion> {
    ctx.champion_names()
        .into_iter()
        .filter_map(|name| {
            Some(Champion {
                category: ctx.champion_brief(&name)?.category?.code() as usize,
                name,
            })
        })
        .collect()
}
fn snapshot(ctx: &StableClient<'_>) -> Result<(Value, Vec<Athlete>, Vec<Champion>), String> {
    let team = ctx.player_team_id().ok_or("플레이어 팀이 없습니다.")?;
    let root =
        parse(ctx.record_get_json(Kind::Team, team, "")).ok_or("팀 정보를 읽을 수 없습니다.")?;
    let mut a = Vec::new();
    for id in ctx.athlete_ids() {
        if parse(ctx.record_get_json(Kind::Athlete, id, "contract"))
            .and_then(|v| planner::contract_team(&v))
            == Some(team as u64)
        {
            if let Some(data) = parse(ctx.record_get_json(Kind::Athlete, id, "")) {
                a.push(Athlete { id, data });
            }
        }
    }
    Ok((root, a, champions(ctx)))
}
fn q(s: &str) -> String {
    serde_json::to_string(s).unwrap()
}
fn label(id: &str, x: f32, y: f32, w: f32, s: &str) -> String {
    format!("#{id}:label {{ @\"asset/base/style/main#label\"; x:{x}px; y:{y}px; width:{w}px; height:38px; size:17; ignore_event:true; align_y:Center; text:{}; }}",q(s))
}
fn button(id: &str, x: f32, y: f32, w: f32, s: &str) -> String {
    format!("#{id}:color_icon_button {{ @\"asset/base/style/main#secondary_button\"; x:{x}px; y:{y}px; width:{w}px; height:44px; text:{{ text:{}; size:17; align_x:Center; align_y:Center; }} }}",q(s))
}
fn click(
    ctx: &mut StableClient<'_>,
    path: &str,
    state: Arc<Mutex<State>>,
    f: impl Fn(&mut State) + Send + Sync + 'static,
) {
    ctx.ui_register_click(path, "", move |_| {
        if let Ok(mut s) = state.lock() {
            if !s.pending {
                f(&mut s);
                s.dirty = true;
            }
        }
    });
}
fn render(ctx: &mut StableClient<'_>, state: Arc<Mutex<State>>, s: &State) {
    if ctx.ui_exists(PANEL) {
        ctx.ui_remove_node(PANEL);
    }
    if !s.open {
        return;
    }
    let snap = snapshot(ctx);
    let plan = snap
        .as_ref()
        .map_err(Clone::clone)
        .and_then(|(t, a, c)| planner::assignments(t, a, c, s.modes));
    let has_write = plan
        .as_ref()
        .is_ok_and(|r| r.iter().any(|r| r.target.is_some()));
    let mut src=String::from("tvp_panel:color { anchor_x:0.5; anchor_y:0.5; pivot_x:0.5; pivot_y:0.5; width:1240px; height:830px; z:2100; color:#161721ff;");
    src += &label("title", 24., 12., 1180., "챔피언 훈련 일괄 배치");
    src += &label(
        "scope",
        24.,
        54.,
        1180.,
        "포지션마다 분류를 선택하면 팀 티어가 높은 챔피언 최대 4명을 같은 비율로 배치합니다.",
    );
    for i in 0..5 {
        src += &label(
            &format!("pos{i}"),
            24. + i as f32 * 238.,
            108.,
            220.,
            planner::POS_LABEL[i],
        );
        src += &button(
            &format!("mode{i}"),
            24. + i as f32 * 238.,
            150.,
            220.,
            planner::MODE[s.modes[i]],
        );
    }
    src+=&label("keep",24.,210.,1180.,"현재 유지: 개인 설정 보존 / 팀 설정 따름: 개인 챔피언 지정 해제. 자동 적용은 하지 않습니다.");
    match (&snap, &plan) {
        (Ok((_, athletes, _)), Ok(rows)) => {
            for (i, row) in rows.iter().skip(s.page * 8).take(8).enumerate() {
                let name = athletes
                    .iter()
                    .find(|a| a.id == row.athlete)
                    .and_then(|a| a.data["name"].as_str())
                    .unwrap_or("선수");
                let pos = row
                    .position
                    .map(|p| planner::POS_LABEL[p])
                    .unwrap_or("포지션 미확인·유지");
                src += &label(
                    &format!("row{i}"),
                    24.,
                    264. + i as f32 * 42.,
                    1180.,
                    &format!("{name} · {pos} → {}", row.label),
                );
            }
        }
        (_, Err(e)) => src += &label("error", 24., 280., 1180., e),
        _ => {}
    }
    src += &label(
        "refresh",
        24.,
        615.,
        1180.,
        "서버와 화면의 훈련 계획을 함께 갱신합니다. 열려 있던 개인 훈련 창은 다시 열어 확인해 주세요.",
    );
    src += &label("status", 24., 660., 1180., &s.status);
    src += &button("close", 24., 748., 180., "닫기");
    src += &button("prev", 224., 748., 140., "이전");
    src += &button("next", 384., 748., 140., "다음");
    if has_write {
        src += &button(
            "apply",
            850.,
            748.,
            360.,
            if s.pending {
                "서버 적용 확인 중"
            } else {
                "표시된 훈련 계획 적용"
            },
        );
    }
    src.push('}');
    if !ctx.ui_spawn_source(ROOT, &src) {
        return;
    }
    click(ctx, &format!("{PANEL}.close"), state.clone(), |s| {
        s.open = false
    });
    click(ctx, &format!("{PANEL}.prev"), state.clone(), |s| {
        s.page = s.page.saturating_sub(1)
    });
    let pages = plan
        .as_ref()
        .map(|r| r.len().saturating_sub(1) / 8)
        .unwrap_or(0);
    click(ctx, &format!("{PANEL}.next"), state.clone(), move |s| {
        s.page = (s.page + 1).min(pages)
    });
    for i in 0..5 {
        click(ctx, &format!("{PANEL}.mode{i}"), state.clone(), move |s| {
            s.modes[i] = (s.modes[i] + 1) % 7;
            s.page = 0;
            s.status.clear();
        });
    }
    if has_write {
        click(ctx, &format!("{PANEL}.apply"), state, |s| {
            s.execute = true;
            s.pending = true;
        });
    }
}
impl Client {
    fn update(&self, raw: *mut mod_api_stable::ClientCtxV1, ctx: &mut StableClient<'_>, _dt: u64) {
        let Ok(mut s) = self.state.lock() else {
            return;
        };
        for e in ctx.take_events() {
            if e.event == "tvp_result" {
                let response: Value = serde_json::from_slice(&e.payload).unwrap_or(Value::Null);
                s.status = response["message"]
                    .as_str()
                    .unwrap_or("적용 결과를 읽을 수 없습니다.")
                    .into();
                if let Some(team) = response["team"].as_u64() {
                    let rows: Vec<_> = response["changes"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|v| {
                            Some(Assignment {
                                athlete: v[0].as_u64()? as usize,
                                position: None,
                                target: if v[1].is_null() {
                                    None
                                } else {
                                    Some(v[1].as_str()?.to_owned())
                                },
                                label: String::new(),
                            })
                        })
                        .collect();
                    let sync = native::Native::find()
                        .ok_or_else(|| "native version mismatch".to_string())
                        .and_then(|n| unsafe { n.apply_client(raw, team as usize, &rows) });
                    if sync.is_ok() {
                        log("client plan cache synchronized");
                    } else {
                        s.status.push_str(" 화면 정보 동기화를 확인하지 못했습니다. 저장 후 다시 불러와 확인해 주세요.");
                        log("client plan cache sync refused");
                    }
                }
                s.pending = false;
                s.dirty = true;
                log("apply-result received");
            }
        }
        if s.execute {
            s.execute = false;
            match snapshot(ctx) {
                Ok((_, _, c)) => {
                    let nonce = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|v| v.as_nanos().to_string())
                        .unwrap_or_default();
                    let list: Vec<_> = c
                        .iter()
                        .map(|c| json!({"name":c.name,"category":c.category}))
                        .collect();
                    let payload = json!({"roles":s.modes,"champions":list,"nonce":nonce});
                    if !ctx.send_command("tvp_apply", payload.to_string().as_bytes()) {
                        s.status = "적용 요청을 전달하지 못했습니다.".into();
                        s.pending = false;
                    } else {
                        s.status = "서버의 현재 팀과 훈련 계획을 확인하고 있습니다.".into();
                    }
                }
                Err(e) => {
                    s.pending = false;
                    s.status = e;
                }
            }
            s.dirty = true;
        }
        if !ctx.ui_exists(ROOT) || ctx.ui_visible(ROOT) == Some(false) {
            s.open = false;
            return;
        }
        let path = format!("{ROOT}.tvp_open");
        if !ctx.ui_exists(&path) {
            let b = button("tvp_open", 960., 0., 400., "챔피언 훈련 일괄");
            if ctx.ui_spawn_source(ROOT, &b[1..]) {
                click(ctx, &path, self.state.clone(), |s| {
                    s.open = true;
                    s.page = 0;
                });
                log("training UI attached");
            }
        }
        ctx.ui_set_visible(
            &path,
            ctx.ui_visible(&format!("{ROOT}.streaming_period_switcher")) != Some(true),
        );
        if s.dirty {
            s.dirty = false;
            render(ctx, self.state.clone(), &s);
        }
    }
}
impl Server {
    unsafe fn apply(
        &self,
        raw: *mut ServerCtxV1,
        ctx: &mut StableServerCtx<'_>,
        command: &StableCommand<'_>,
    ) -> Result<(String, usize, Vec<Assignment>), String> {
        let team = command
            .sender_team_id
            .or_else(|| command.sender_player_id.and_then(|p| ctx.player_team_id(p)))
            .ok_or("플레이어 팀을 확인할 수 없습니다.")?;
        if command
            .sender_player_id
            .is_some_and(|p| ctx.player_team_id(p) != Some(team))
        {
            return Err("현재 팀이 바뀌었습니다.".into());
        }
        let v: Value =
            serde_json::from_slice(command.payload).map_err(|_| "요청을 읽을 수 없습니다.")?;
        let nonce = v["nonce"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 64)
            .ok_or("요청 번호가 없습니다.")?;
        let key = format!("{team}:{nonce}");
        let mut done = self
            .done
            .lock()
            .map_err(|_| "적용 상태를 확인할 수 없습니다.")?;
        if done.contains(&key) {
            return Err("이미 처리한 요청입니다. 훈련 화면을 다시 열어 확인해 주세요.".into());
        }
        let roles = v["roles"]
            .as_array()
            .filter(|a| a.len() == 5)
            .ok_or("포지션 선택이 올바르지 않습니다.")?;
        let mut modes = [0; 5];
        for (i, m) in roles.iter().enumerate() {
            modes[i] = m
                .as_u64()
                .filter(|m| *m <= 6)
                .ok_or("분류가 올바르지 않습니다.")? as usize;
        }
        let list = v["champions"]
            .as_array()
            .filter(|a| a.len() <= 2000)
            .ok_or("챔피언 목록이 올바르지 않습니다.")?;
        let mut ch = Vec::new();
        let mut unique = BTreeSet::new();
        for c in list {
            let name = c["name"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 128 && !s.contains(['|', ':']))
                .ok_or("챔피언 이름이 올바르지 않습니다.")?;
            let category = c["category"]
                .as_u64()
                .filter(|v| *v < 5)
                .ok_or("챔피언 분류가 올바르지 않습니다.")? as usize;
            if !unique.insert(name) {
                return Err("챔피언 목록이 중복되었습니다.".into());
            }
            ch.push(Champion {
                name: name.into(),
                category,
            });
        }
        let root = parse(ctx.team_get_json(team, "")).ok_or("팀 정보를 읽을 수 없습니다.")?;
        let mut athletes = Vec::new();
        for id in ctx.record_ids(Kind::Athlete) {
            if parse(ctx.athlete_get_json(id, "contract")).and_then(|v| planner::contract_team(&v))
                == Some(team as u64)
            {
                let data =
                    parse(ctx.athlete_get_json(id, "")).ok_or("선수 정보를 읽을 수 없습니다.")?;
                athletes.push(Athlete { id, data });
            }
        }
        if athletes.is_empty() {
            return Err("현재 팀의 소속 선수를 확인할 수 없습니다.".into());
        }
        let rows = planner::assignments(&root, &athletes, &ch, modes)?;
        let api =
            native::Native::find().ok_or("이 게임 빌드의 훈련 쓰기 경로가 일치하지 않습니다.")?;
        let n = api.apply(raw, team, &rows)?;
        if done.len() > 4096 {
            done.pop_first();
        }
        done.insert(key);
        log(&format!(
            "authoritative apply changed={n}; no stack-relative send"
        ));
        Ok((
            format!("{n}명 훈련 계획 적용 · 개인 훈련 창을 다시 열어 확인해 주세요."),
            team,
            rows,
        ))
    }
}

unsafe extern "C" fn client_destroy(p: *mut c_void) {
    if !p.is_null() {
        drop(Box::from_raw(p as *mut Client));
    }
}
unsafe extern "C" fn client_update(p: *mut c_void, raw: *mut mod_api_stable::ClientCtxV1, dt: u64) {
    if p.is_null() {
        return;
    }
    let Some(mut ctx) = StableClient::from_raw(raw) else {
        return;
    };
    (&*(p as *mut Client)).update(raw, &mut ctx, dt);
}
static CLIENT_TABLE: mod_api_stable::ExtensionVtableV1 = mod_api_stable::ExtensionVtableV1 {
    size: std::mem::size_of::<mod_api_stable::ExtensionVtableV1>(),
    destroy: Some(client_destroy),
    on_init: None,
    pre_update: None,
    post_update: Some(client_update),
    on_end: None,
    pre_render: None,
    post_render: None,
};
