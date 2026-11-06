//! Independent ARM64/iOS adaptation of the community view ideas.
//! Public stable SDK only. Read-only records; no Windows DLL code/addresses.
mod art;
mod inline;
mod json;
mod radar;
mod extra_radar;
use json::{parse, Json};
use mod_api_stable::{
    declare_stable_mod, LogLevel, RecordKindV1 as Kind, StableClient, StableExtension, StableHost,
    StableMod,
};
use std::io::Write;
use std::sync::{Arc, Mutex};

const ID: &str = "tfm2_view_plus_ios";
const PLAYER: &[&str] = &[
    "last_hit",
    "skill_avoid",
    "skill_hit",
    "control_speed",
    "positioning",
    "judgement",
    "mental",
    "concentration",
    "order",
    "roaming",
    "aggressive",
    "ego",
];
const PLAYER_LABEL: &[&str] = &[
    "막타",
    "회피",
    "명중",
    "컨트롤",
    "포지셔닝",
    "판단",
    "멘탈",
    "집중",
    "오더",
    "로밍",
    "공격성",
    "자아",
];
const STAFF: &[&str] = &[
    "banpick",
    "strategy",
    "negotiation",
    "judge_ability",
    "judge_potential",
    "feedback",
    "power_analysis",
    "control_coaching",
    "judgment_coaching",
    "mental_coaching",
];
const STAFF_LABEL: &[&str] = &[
    "밴픽",
    "전술",
    "협상",
    "능력분석",
    "잠재분석",
    "피드백",
    "전력분석",
    "컨트롤",
    "판단코칭",
    "멘탈코칭",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum View {
    Roster,
    Coaches,
    Recruitment,
}
impl View {
    fn root(self) -> &'static str {
        match self {
            Self::Roster => "main.top.right.squad",
            Self::Coaches => "main.top.right.staff",
            Self::Recruitment => "main.top.right.scout",
        }
    }
    fn original(self) -> String {
        format!(
            "{}.{}",
            self.root(),
            if self == Self::Recruitment {
                "contents"
            } else {
                "data"
            }
        )
    }
    fn title(self) -> &'static str {
        match self {
            Self::Roster => "선수단 능력치 비교",
            Self::Coaches => "코치진 능력치 비교",
            Self::Recruitment => "현재 영입 목록 능력치 비교",
        }
    }
    fn fields(self) -> &'static [&'static str] {
        if self == Self::Coaches {
            STAFF
        } else {
            PLAYER
        }
    }
    fn labels(self) -> &'static [&'static str] {
        if self == Self::Coaches {
            STAFF_LABEL
        } else {
            PLAYER_LABEL
        }
    }
    fn kind(self) -> Kind {
        if self == Self::Coaches {
            Kind::Staff
        } else {
            Kind::Athlete
        }
    }
}
#[derive(Clone, Debug)]
struct Row {
    id: usize,
    name: String,
    stats: Vec<Option<f64>>,
    proficiency: String,
    tops: Vec<(String, f64)>,
}
#[derive(Default)]
struct State {
    requested: Option<View>,
    open: Option<View>,
    rows: Vec<Row>,
    sort: Option<usize>,
    descending: bool,
    page: usize,
    dirty: bool,
    elapsed: u64,
    scene: String,
    date: Option<(i32, u32, u32)>,
    recruitment_ids: Vec<usize>,
    status: String,
    draft_seen: bool,
    art: art::Art,
    inline: inline::Inline,
    radar: radar::Radar,
}
struct Views {
    state: Arc<Mutex<State>>,
}
fn log(event: &str) {
    // iOS sandbox HOME, only an already-installed mod directory. On desktop
    // this does not create a Documents/GameRuntime directory or touch saves.
    let Some(home) = std::env::var_os("HOME") else {
        return;
    };
    let p = std::path::PathBuf::from(home)
        .join("Documents/GameRuntime/mods")
        .join(ID);
    if !p.is_dir() {
        return;
    }
    let path = p.join("view-plus-ios-v1.log");
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > 262_144) {
        return;
    }
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(path)
    {
        let _ = writeln!(f, "v0.2.0 {event}");
    }
}
fn init(host: &StableHost) -> StableMod {
    host.log(LogLevel::Info, "tfm2_view_plus_ios 0.2.0: ability comparison + taller ban/pick grid; read-only management data");
    log(&format!(
        "loaded host_abi={} game={}.{}.{}",
        host.abi_level(),
        host.game_version().major,
        host.game_version().minor,
        host.game_version().patch
    ));
    let mut m = StableMod::new(ID);
    m.set_extension(Views {
        state: Arc::new(Mutex::new(State {
            art: art::Art::load(),
            radar: radar::Radar::new(),
            ..State::default()
        })),
    });
    m
}
declare_stable_mod!(init, requires = 10);
fn q(s: &str) -> String {
    let mut r = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => r.push_str("\\\""),
            '\\' => r.push_str("\\\\"),
            '\n' | '\r' | '\t' => r.push(' '),
            c if c.is_control() => (),
            c => r.push(c),
        }
    }
    r.push('"');
    r
}
fn button(id: &str, x: f32, y: f32, w: f32, label: &str) -> String {
    format!("#{id}:color_icon_button {{ @\"asset/base/style/main#secondary_button\"; x: {x}px; y: {y}px; width: {w}px; height: 42px; text: {{ font: \"asset/base/font/set/bold\"; size: 16; align_x: Center; align_y: Center; text: {}; }} }}", q(label))
}
fn label(id: &str, x: f32, y: f32, w: f32, h: f32, text: &str, size: u32, color: &str) -> String {
    format!("#{id}:label {{ @\"asset/base/style/main#label\"; x:{x}px; y:{y}px; width:{w}px; height:{h}px; ignore_event:true; size:{size}; align_y:Center; color:{color}; text:{}; }}",q(text))
}
fn stat(root: &Json, key: &str) -> Option<f64> {
    let s = root.get("stat")?;
    s.get(key)
        .and_then(Json::number)
        .or_else(|| s.get("value")?.get(key)?.number())
        .filter(|v| (0.0..=1000.0).contains(v))
}
fn affiliation(root: &Json) -> Option<usize> {
    let contract = root.get("contract")?;
    contract.get("InContract").unwrap_or(contract).get("team_id")?.id()
}
fn proficiency_entries(root: &Json) -> Vec<(String, f64)> {
    let Some(v) = root.get("champion_proficiency").and_then(Json::object) else {
        return Vec::new();
    };
    let mut entries: Vec<_> = v
        .iter()
        .filter_map(|(key, entry)| {
            let value = entry.get("value").unwrap_or(entry).number()?;
            value.is_finite().then(|| (key.clone(), value))
        })
        .collect();
    entries.sort_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    entries.truncate(4);
    entries
}
fn proficiency(root: &Json) -> String {
    proficiency_entries(root)
        .into_iter()
        .map(|(key, value)| format!("{key} {value:.0}"))
        .collect::<Vec<_>>()
        .join("  ·  ")
}

fn snapshot(ctx: &StableClient<'_>, view: View, ids: Option<&[usize]>) -> Vec<Row> {
    let team = ctx.player_team_id();
    let candidates = ids
        .map(|v| v.to_vec())
        .unwrap_or_else(|| ctx.record_ids(view.kind()));
    let mut result = Vec::new();
    for id in candidates {
        let Some(raw) = ctx.record_get_json(view.kind(), id, "") else {
            continue;
        };
        let Some(doc) = parse(&raw) else {
            continue;
        };
        if ids.is_none() && (team.is_none() || affiliation(&doc) != team) {
            continue;
        }
        let name = if view.kind() == Kind::Athlete {
            ctx.athlete_name(id)
        } else {
            ctx.record_get_string(Kind::Staff, id, "name")
        }
        .or_else(|| doc.get("name")?.string().map(str::to_owned))
        .unwrap_or_else(|| format!("#{id}"));
        let stats: Vec<_> = view.fields().iter().map(|k| stat(&doc, k)).collect();
        // A supported row must have at least one actual recognized stat.
        // Missing/unknown values stay '-' and are never fabricated as zero.
        if !stats.iter().any(Option::is_some) {
            continue;
        }
        result.push(Row {
            id,
            name,
            stats,
            tops: if view == View::Roster {
                proficiency_entries(&doc)
            } else {
                Vec::new()
            },
            proficiency: if view == View::Roster {
                proficiency(&doc)
            } else {
                String::new()
            },
        });
    }
    result.sort_by(|a, b| a.name.cmp(&b.name).then(a.id.cmp(&b.id)));
    result
}
fn sorted(rows: &mut [Row], key: Option<usize>, descending: bool) {
    if let Some(key) = key {
        rows.sort_by(|a, b| {
            let (a_val, b_val) = (
                a.stats.get(key).copied().flatten(),
                b.stats.get(key).copied().flatten(),
            );
            match (a_val, b_val) {
                (Some(a_val), Some(b_val)) => {
                    if descending {
                        b_val.total_cmp(&a_val)
                    } else {
                        a_val.total_cmp(&b_val)
                    }
                }
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                _ => std::cmp::Ordering::Equal,
            }
            .then_with(|| a.name.cmp(&b.name))
            .then(a.id.cmp(&b.id))
        });
    }
}
fn color(n: Option<f64>) -> &'static str {
    match n {
        None => "#858d9dff",
        Some(n) if n >= 80.0 => "#ff8c33ff",
        Some(n) if n >= 60.0 => "#b873e6ff",
        Some(n) if n >= 40.0 => "#599ef2ff",
        Some(n) if n >= 20.0 => "#4dd999ff",
        _ => "#a8a8b3ff",
    }
}
fn register_action(
    ctx: &mut StableClient<'_>,
    path: &str,
    state: Arc<Mutex<State>>,
    action: impl Fn(&mut State) + Send + Sync + 'static,
) {
    ctx.ui_register_click(path, "", move |_| {
        if let Ok(mut s) = state.lock() {
            action(&mut s);
        }
    });
}
fn install(ctx: &mut StableClient<'_>, view: View, state: Arc<Mutex<State>>) {
    let root = view.root();
    if !ctx.ui_exists(root) || ctx.ui_visible(root) == Some(false) {
        return;
    }
    let path = format!("{root}.vp_open");
    if ctx.ui_exists(&path) {
        return;
    }
    // Attach below the original content and anchor to its actual 4:3 height.
    let src = button("vp_open", 0.0, 0.0, 250.0, "능력치 비교·정렬")
        .replace("x: 0px;", "anchor_x:1; pivot_x:1; x:-4px;")
        .replace("y: 0px;", "anchor_y: 1; pivot_y: 1; y: -4px;");
    if ctx.ui_spawn_source(root, src.trim_start_matches('#')) {
        register_action(ctx, &path, state, move |s| {
            s.requested = Some(view);
            s.dirty = true;
        });
        log(&format!("button-ready view={view:?}"));
    }
}
fn render_panel(ctx: &mut StableClient<'_>, view: View, state: Arc<Mutex<State>>, s: &mut State) {
    let root = view.root();
    let panel = format!("{root}.vp_panel");
    if ctx.ui_exists(&panel) {
        ctx.ui_remove_node(&panel);
    }
    let (_, _, rw, rh) = ctx.ui_node_rect(root).unwrap_or((0.0, 0.0, 1600.0, 968.0));
    let width = 1600.0f32;
    let height = if rw > 0.0 && rh > 0.0 {
        (rh / rw * width).clamp(600.0, 1800.0)
    } else {
        968.0
    };
    let rows_per_page = (((height - 200.0) / 58.0).floor() as usize).clamp(4, 25);
    let pages = s.rows.len().max(1).div_ceil(rows_per_page);
    s.page = s.page.min(pages - 1);
    sorted(&mut s.rows, s.sort, s.descending);
    let mut src=format!("#vp_panel:color {{ x:0px; y:0px; width:{width}px; height:{height}px; z:700; color:#161721ff;");
    src += &label(
        "title",
        20.0,
        8.0,
        1060.0,
        42.0,
        view.title(),
        24,
        "#e8e8e8ff",
    );
    src += &button("close", 1360.0, 8.0, 220.0, "기본 화면으로");
    src += &label(
        "note",
        20.0,
        56.0,
        1560.0,
        30.0,
        &format!(
            "{}명  ·  열 제목을 눌러 정렬  ·  — = 읽을 수 없는 값  ·  {}",
            s.rows.len(),
            s.status
        ),
        15,
        "#a8a8b3ff",
    );
    src += &label(
        "name_header",
        20.0,
        100.0,
        260.0,
        42.0,
        "이름 / 숙련 챔피언 상위 4",
        16,
        "#e8e8e8ff",
    );
    let col = (width - 310.0) / (view.fields().len() as f32);
    for (i, key) in view.labels().iter().enumerate() {
        let arrow = if s.sort == Some(i) {
            if s.descending {
                " ▼"
            } else {
                " ▲"
            }
        } else {
            ""
        };
        src += &button(
            &format!("sort{i}"),
            290.0 + i as f32 * col,
            98.0,
            col - 3.0,
            &format!("{key}{arrow}"),
        );
    }
    if s.rows.is_empty() {
        src += &label(
            "empty",
            20.0,
            165.0,
            1500.0,
            90.0,
            "현재 화면에서 확인 가능한 능력치가 없습니다. 기본 화면으로 돌아가 주세요.",
            20,
            "#a8a8b3ff",
        );
    }
    for (r, row) in s
        .rows
        .iter()
        .skip(s.page * rows_per_page)
        .take(rows_per_page)
        .enumerate()
    {
        let y = 148.0 + r as f32 * 58.0;
        src += &label(
            &format!("n{r}"),
            20.0,
            y,
            265.0,
            32.0,
            &row.name,
            18,
            "#e8e8e8ff",
        );
        for (i, (_, value)) in row.tops.iter().enumerate() {
            let x = 20.0 + i as f32 * 58.0;
            src+=&format!("#face{r}_{i}:image {{ ignore_event:true; x:{x}px; y:{}px; width:24px; height:24px; }}",y+30.0);
            src += &label(
                &format!("prof{r}_{i}"),
                x + 25.0,
                y + 30.0,
                30.0,
                24.0,
                &format!("{value:.0}"),
                10,
                "#a8a8b3ff",
            );
        }
        for (i, value) in row.stats.iter().enumerate() {
            src += &label(
                &format!("v{r}_{i}"),
                300.0 + i as f32 * col,
                y,
                col - 5.0,
                44.0,
                &value
                    .map(|v| format!("{v:.0}"))
                    .unwrap_or_else(|| "—".into()),
                20,
                color(*value),
            );
        }
    }
    let y = height - 50.0;
    src += &button("previous", 20.0, y, 180.0, "이전 페이지");
    src += &label(
        "page",
        220.0,
        y,
        350.0,
        42.0,
        &format!("{} / {}", s.page + 1, pages),
        18,
        "#e8e8e8ff",
    );
    src += &button("next", 580.0, y, 180.0, "다음 페이지");
    src.push('}');
    if !ctx.ui_spawn_source(root, src.trim_start_matches('#')) {
        log("panel-spawn-rejected");
        return;
    }
    for (r, row) in s
        .rows
        .iter()
        .skip(s.page * rows_per_page)
        .take(rows_per_page)
        .enumerate()
    {
        let mut resolved = 0;
        for (i, (champion, _)) in row.tops.iter().enumerate() {
            let path = format!("{panel}.face{r}_{i}");
            if !ctx.ui_set_champion_icon(&path, champion, 24.0, 24.0, 2.0) {
                ctx.ui_set_visible(&path, false);
            } else {
                resolved += 1;
            }
        }
        if resolved == 0 && !row.proficiency.is_empty() {
            ctx.ui_spawn_source(
                &panel,
                &label(
                    &format!("pfallback{r}"),
                    20.0,
                    178.0 + r as f32 * 58.0,
                    265.0,
                    22.0,
                    &row.proficiency,
                    10,
                    "#a8a8b3ff",
                )
                .trim_start_matches('#'),
            );
        }
    }
    register_action(ctx, &format!("{panel}.close"), state.clone(), |s| {
        s.requested = None;
        s.dirty = true;
    });
    for i in 0..view.fields().len() {
        register_action(ctx, &format!("{panel}.sort{i}"), state.clone(), move |s| {
            s.descending = if s.sort == Some(i) {
                !s.descending
            } else {
                true
            };
            s.sort = Some(i);
            s.page = 0;
            s.dirty = true;
        });
    }
    register_action(ctx, &format!("{panel}.previous"), state.clone(), |s| {
        s.page = s.page.saturating_sub(1);
        s.dirty = true;
    });
    register_action(ctx, &format!("{panel}.next"), state, move |s| {
        s.page = (s.page + 1).min(pages - 1);
        s.dirty = true;
    });
    ctx.ui_set_properties(
        &format!("{panel}.previous"),
        if s.page == 0 {
            "disable:true;"
        } else {
            "disable:false;"
        },
    );
    ctx.ui_set_properties(
        &format!("{panel}.next"),
        if s.page + 1 == pages {
            "disable:true;"
        } else {
            "disable:false;"
        },
    );
    log(&format!(
        "panel-ready view={view:?} rows={} fields={} page={}/{}",
        s.rows.len(),
        view.fields().len(),
        s.page + 1,
        pages
    ));
}
// Baseline iPad package owns all ban/pick geometry. This plugin adds only
// feature widgets/overlays and never restores old 1080px layout assumptions.
impl StableExtension for Views {
    fn post_render(&self, ctx: &mut StableClient<'_>) {
        if let Ok(s) = self.state.lock() {
            s.inline.render(ctx, s.open);
            s.radar.render(ctx);
        }
    }
    fn on_init(&self, _ctx: &mut StableClient<'_>) {
        log("client-on-init");
    }
    fn post_update(&self, ctx: &mut StableClient<'_>, dt: u64) {
        let Ok(mut s) = self.state.lock() else {
            return;
        };
        let scene = format!("{:?}", ctx.scene_kind());
        if s.scene != scene {
            s.scene = scene.clone();
            log(&format!("scene={scene}"));
        }
        s.elapsed = s.elapsed.saturating_add(dt);
        let due = s.elapsed >= 250_000;
        if due {
            s.elapsed = 0;
        }
        // Enforce only the draft properties whose host may recompute them.
        if due {
            let mut radar = std::mem::take(&mut s.radar);
            radar.update(ctx, self.state.clone());
            s.radar = radar;
            let mut art = std::mem::take(&mut s.art);
            art.update(ctx, self.state.clone());
            s.art = art;
            if !s.draft_seen
                && ctx.ui_exists("main.champions.contents")
                && ctx.ui_exists("main.champion_info")
            {
                s.draft_seen = true;
                log("draft-detected native-grid-height-adaptation");
            }
        }
        if !ctx.is_in_game() {
            s.open = None;
            s.requested = None;
            s.rows.clear();
            return;
        }
        if due {
            for view in [View::Roster, View::Coaches, View::Recruitment] {
                install(ctx, view, self.state.clone());
            }
        }
        let mut inline = std::mem::take(&mut s.inline);
        inline.update(ctx, self.state.clone(), dt);
        s.inline = inline;
        if s.requested != s.open {
            if let Some(old) = s.open {
                ctx.ui_remove_node(&format!("{}.vp_panel", old.root()));
                // Original panels only: never change visibility of native tabs,
                // coach delegation controls, dialogs or unrelated screens.
                ctx.ui_set_visible(&old.original(), true);
                ctx.ui_set_visible(&format!("{}.vp_open", old.root()), true);
            }
            s.open = s.requested;
            s.page = 0;
            s.sort = None;
            s.descending = true;
            if let Some(view) = s.open {
                let visible_ids = s.inline.current_ids(ctx, view);
                if view == View::Recruitment {
                    s.recruitment_ids.clone_from(&visible_ids);
                }
                s.rows = snapshot(
                    ctx,
                    view,
                    if view == View::Recruitment {
                        Some(&s.recruitment_ids)
                    } else if !visible_ids.is_empty() {
                        Some(&visible_ids)
                    } else {
                        None
                    },
                );
                s.status = if view == View::Recruitment {
                    "현재 목록의 확인된 선수만 표시"
                } else {
                    "관리 데이터 읽기 전용"
                }
                .into();
                ctx.ui_set_visible(&view.original(), false);
                ctx.ui_set_visible(&format!("{}.vp_open", view.root()), false);
                let verified: Vec<_> = view
                    .fields()
                    .iter()
                    .enumerate()
                    .filter_map(|(i, key)| {
                        s.rows
                            .iter()
                            .any(|r| r.stats.get(i).is_some_and(Option::is_some))
                            .then_some(*key)
                    })
                    .collect();
                log(&format!(
                    "snapshot view={view:?} rows={} recognized_stat_keys={}",
                    s.rows.len(),
                    verified.join(",")
                ));
            }
            s.dirty = true;
        }
        if let Some(view) = s.open {
            if !ctx.ui_exists(view.root()) {
                s.open = None;
                s.requested = None;
                s.rows.clear();
                return;
            }
            let date = ctx.game_date();
            if due && date != s.date {
                s.date = date;
                s.rows = snapshot(
                    ctx,
                    view,
                    if view == View::Recruitment {
                        Some(&s.recruitment_ids)
                    } else {
                        None
                    },
                );
                s.dirty = true;
            }
            if s.dirty {
                s.dirty = false;
                render_panel(ctx, view, self.state.clone(), &mut s);
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn in_contract_and_proficiency_objects_from_campaign_records() {
        let row = parse(r#"{"contract":{"InContract":{"team_id":0}},"champion_proficiency":{"a":{"floor":3,"value":7},"b":{"floor":19,"value":5}}}"#).unwrap();
        assert_eq!(affiliation(&row), Some(0));
        assert_eq!(proficiency_entries(&row), vec![("a".into(),7.0),("b".into(),5.0)]);
        assert_eq!(affiliation(&parse(r#"{"contract":"FreeAgent"}"#).unwrap()),None);
    }
    #[test]
    fn root_and_value_stat_shapes() {
        assert_eq!(
            stat(&parse(r#"{"stat":{"last_hit":34}}"#).unwrap(), "last_hit"),
            Some(34.0)
        );
        assert_eq!(
            stat(
                &parse(r#"{"stat":{"value":{"last_hit":72}}}"#).unwrap(),
                "last_hit"
            ),
            Some(72.0)
        );
        assert_eq!(
            stat(
                &parse(r#"{"stat":{"last_hit":{"value":52}}}"#).unwrap(),
                "last_hit"
            ),
            Some(52.0)
        );
        assert_eq!(
            stat(&parse(r#"{"stat":{"last_hit":-1}}"#).unwrap(), "last_hit"),
            None
        );
    }
    #[test]
    fn sorting_keeps_identity_and_missing_values_last() {
        let mut v = vec![
            Row {
                id: 1,
                name: "A".into(),
                stats: vec![Some(20.0)],
                proficiency: String::new(),
                tops: Vec::new(),
            },
            Row {
                id: 2,
                name: "B".into(),
                stats: vec![None],
                proficiency: String::new(),
                tops: Vec::new(),
            },
            Row {
                id: 3,
                name: "C".into(),
                stats: vec![Some(80.0)],
                proficiency: String::new(),
                tops: Vec::new(),
            },
        ];
        sorted(&mut v, Some(0), true);
        assert_eq!(v.iter().map(|v| v.id).collect::<Vec<_>>(), vec![3, 1, 2]);
        sorted(&mut v, Some(0), false);
        assert_eq!(v.iter().map(|v| v.id).collect::<Vec<_>>(), vec![1, 3, 2]);
    }
    #[test]
    fn proficiency_is_ranked_and_bounded() {
        let v = parse(r#"{"champion_proficiency":{"a":1,"b":5,"c":3,"d":4,"e":2}}"#).unwrap();
        assert_eq!(proficiency(&v), "b 5  ·  d 4  ·  c 3  ·  e 2");
    }
}
