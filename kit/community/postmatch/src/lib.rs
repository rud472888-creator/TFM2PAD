//! Stable-ABI reconstruction. The Windows core is never loaded or patched.
use mod_api_stable::{declare_stable_mod, LogLevel, RecordKindV1 as Kind, StableClient,
    StableExtension, StableHost, StableMod};
use serde_json::Value;
use std::{collections::{BTreeMap, BTreeSet}, sync::{Arc, Mutex}};
mod access;
mod settlement;
mod settlement_host;
static SETTLEMENT_ACTIVE:std::sync::atomic::AtomicBool=std::sync::atomic::AtomicBool::new(false);

const ID: &str = "tfm2_postmatch_ipad";
const PANEL: &str = "main.pm_ipad_panel";
const CORPUS: &str = include_str!("../comments.tsv");
fn status(phase: &str, reviews: usize) {
    // Observable operational counters only; never serialize save/player data.
    let dir=std::path::Path::new("mods").join(ID);
    if std::fs::create_dir_all(&dir).is_ok() {
        let data=serde_json::json!({"mod_id":ID,"phase":phase,"readable_reviews":reviews,
            "corpus_lines":1968,"save_updates_enabled":SETTLEMENT_ACTIVE.load(std::sync::atomic::Ordering::Relaxed),"implementation":"source-calibrated-reconstruction"});
        let tmp=dir.join(format!("{ID}-status.tmp"));
        if std::fs::write(&tmp,data.to_string()).is_ok() {
            let _=std::fs::rename(tmp,dir.join(format!("{ID}-status.json")));
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
struct Player {
    id: usize, team: usize, name: String, kills: u64, deaths: u64, assists: u64,
    rating: f64, raw_rating: f64, ratings: usize, sets: usize, wins: usize, mvps:usize,
}
#[derive(Clone, Debug, Default)]
struct Review { id: usize, blue: usize, red: usize, blue_name:String,red_name:String,
    blue_wins:usize,red_wins:usize,blue_fans:Option<i64>,red_fans:Option<i64>,blue_mood:String,red_mood:String,
    need_win:usize,kind:u32,official:bool,sets: usize,replay_ids:Vec<usize>, players: Vec<Player> }
#[derive(Default)]
struct State { reviews: Vec<Review>, page: usize, elapsed: u64,ui_elapsed:u64,auto:bool,seeded:bool,
    own_team:Option<usize>,seen:BTreeSet<(u32,usize)>,
    settlement_enabled:bool,settlement_ready:bool,settlement_baseline_captured:bool,
    settlement_baseline:Option<Review>,settlement_pending:Option<Review> }
struct Extension(Arc<Mutex<State>>);
fn update_reviews(state:&mut State,reviews:Vec<Review>)->bool {
    let next=reviews.iter().position(|r|r.official && !state.seen.contains(&(r.kind,r.id)));
    let open=state.auto&&state.seeded&&next.is_some();
    state.seen.extend(reviews.iter().filter(|r|r.official).map(|r|(r.kind,r.id)));
    state.seeded=true;state.reviews=reviews;
    state.page=state.page.min(state.reviews.len().saturating_sub(1));
    if open{state.page=next.unwrap_or(0);}
    open
}

fn integer(v: Option<&Value>) -> Option<usize> {
    let n = v?.as_u64()?;
    usize::try_from(n).ok()
}
fn stat(v: &Value, key: &str) -> Option<u64> {
    // Statistics documents use singular counters; replay presentations can
    // expose plural aliases. Both names occur in the reviewed binary.
    v.get(key).or_else(|| v.get(key.trim_end_matches('s'))).and_then(Value::as_u64)
}
fn team(v: &Value, key: &str) -> Option<usize> { integer(v.get(key)) }
fn normalized_rating(value:f64)->Option<f64> {
    // Recovered proxy FUN_1800285f0, 0x18002932a..0x180029366:
    // finite + 0..100, divide by ten only when above ten.
    (value.is_finite() && (0.0..=100.0).contains(&value)).then(||if value>10.0 {value/10.0}else{value})
}
fn fan_stars(raw_average:f64)->usize {
    // Original core FUN_180002b10: avg rating minus56, /20 clamped0..1,
    // mapped1..5 and rounded. This drives the core's fan delta rate table.
    ((((raw_average-56.0)/20.0).clamp(0.0,1.0)*4.0+1.0).round() as usize).clamp(1,5)
}
fn team_grade(review:&Review,team:usize)->Option<usize>{
    // Original core FUN_180005250: round mean player stars, penalize a
    // series loss and a multi-win clean sweep; reward an all-4+ winning
    // roster containing a five-star performance with team grade5.
    let members:Vec<_>=review.players.iter().filter(|p|p.team==team).collect();
    if members.is_empty()||members.iter().any(|p|p.ratings==0){return None;}
    let stars:Vec<_>=members.iter().map(|p|fan_stars(p.raw_rating/p.ratings as f64)).collect();
    let mut grade=(stars.iter().sum::<usize>() as f64/stars.len() as f64).round() as usize;
    let (won,lost)=if team==review.blue{(review.blue_wins,review.red_wins)}else{(review.red_wins,review.blue_wins)};
    if won<lost{
        grade=grade.saturating_sub(1).max(1);
        if won==0&&review.need_win>1{grade=grade.saturating_sub(1).max(1);}
    }else if stars.iter().all(|s|*s>=4)&&stars.contains(&5){grade=5;}
    Some(grade.clamp(1,5))
}
fn mood(value:&str)->&str{
    match value{"VeryDissatisfied"=>"매우 불만족","Dissatisfied"=>"불만족","Normal"=>"보통","Satisfied"=>"만족","VerySatisfied"=>"매우 만족",_=>"정보 없음"}
}

// Accept only the field names actually present in both shipped Windows modules.
// Missing or structurally different records are skipped instead of fabricated.
fn read_side(replay: &Value, side: &str, team: usize, won: bool) -> Option<Vec<Player>> {
    let roster = replay.get(side)?.as_array()?;
    let mut players = Vec::new();
    for p in roster {
        let id = integer(p.get("athlete_id"))?;
        let s = p.get("statistics").unwrap_or(p);
        if !s.is_object() { return None; }
        let raw_rating=s.get("rating").and_then(Value::as_f64);
        let rating = raw_rating.and_then(normalized_rating);
        players.push(Player { id, team, kills: stat(s,"kills")?, deaths: stat(s,"deaths")?,
            assists: stat(s,"assists")?, rating: rating.unwrap_or(0.0), raw_rating: if rating.is_some(){raw_rating.unwrap_or(0.0)}else{0.0}, ratings: usize::from(rating.is_some()),
            sets: 1, wins: usize::from(won),mvps:usize::from(s.get("mvp").is_some_and(|v|v.as_bool()==Some(true)||v.as_f64().is_some_and(|n|n>0.0))), ..Player::default() });
    }
    (!players.is_empty()).then_some(players)
}

fn merge_replays(id: usize, replays: &[Value]) -> Option<Review> {
    let first = replays.first()?;
    let blue = team(first,"blue_team_id")?;
    let red = team(first,"red_team_id")?;
    let mut all = BTreeMap::<(usize,usize),Player>::new();
    let mut blue_wins=0;
    for r in replays {
        let b = team(r,"blue_team_id")?;
        let rd = team(r,"red_team_id")?;
        if !((b==blue && rd==red)||(b==red && rd==blue)) { return None; }
        let won = r.get("blue_team_win")?.as_bool()?;
        blue_wins+=usize::from((b==blue && won)||(rd==blue && !won));
        let bp = read_side(r,"blue_team",b,won)?;
        let rp = read_side(r,"red_team",rd,!won)?;
        for p in bp.into_iter().chain(rp) {
            let a = all.entry((p.team,p.id)).or_insert_with(||Player{ id:p.id,team:p.team,..Player::default()});
            a.kills += p.kills; a.deaths += p.deaths; a.assists += p.assists;
            a.rating += p.rating; a.raw_rating+=p.raw_rating; a.ratings += p.ratings; a.sets += 1; a.wins += p.wins;
            a.mvps+=p.mvps;
        }
    }
    Some(Review{id,blue,red,blue_wins,red_wins:replays.len()-blue_wins,sets:replays.len(),players:all.into_values().collect(),..Review::default()})
}

fn read_replay(ctx:&StableClient<'_>,rid:usize,own:usize)->Option<Value>{
    // MatchReplay's root also contains the entire simulation timeline. Read
    // only the five schema-proven fragments the review actually needs.
    let field=|path:&str|serde_json::from_str::<Value>(&ctx.record_get_json(Kind::MatchReplay,rid,path)?).ok();
    let blue=field("blue_team_id")?;
    let red=field("red_team_id")?;
    if integer(Some(&blue))?!=own && integer(Some(&red))?!=own{return None;}
    Some(serde_json::json!({"blue_team_id":blue,"red_team_id":red,"blue_team_win":field("blue_team_win")?,
        "blue_team":field("blue_team")?,"red_team":field("red_team")?}))
}
fn refresh_team_metadata(ctx:&StableClient<'_>,r:&mut Review){
    r.blue_name=ctx.team_name(r.blue).unwrap_or_else(||format!("팀 #{}",r.blue));
    r.red_name=ctx.team_name(r.red).unwrap_or_else(||format!("팀 #{}",r.red));
    r.blue_fans=ctx.record_get_i64(Kind::Team,r.blue,"fan_count");
    r.red_fans=ctx.record_get_i64(Kind::Team,r.red,"fan_count");
    r.blue_mood=ctx.record_get_string(Kind::Team,r.blue,"fan_satisfaction").unwrap_or_default();
    r.red_mood=ctx.record_get_string(Kind::Team,r.red,"fan_satisfaction").unwrap_or_default();
}

fn campaign_score_matches(v:&Value,r:&Review)->bool {
    let Some(end)=v.get("running_state").and_then(|s|s.get("End")) else {return false};
    let (Some(t1),Some(t2),Some(s1),Some(s2))=(v.get("team1").and_then(|t|integer(t.get("Normal"))),v.get("team2").and_then(|t|integer(t.get("Normal"))),integer(end.get("team1_score")),integer(end.get("team2_score"))) else {return false};
    let (bw,rw)=if t1==r.blue&&t2==r.red{(s1,s2)}else if t2==r.blue&&t1==r.red{(s2,s1)}else{return false};
    // Some historical AI matches retain fewer replay records than their final
    // score. Do not present incomplete player totals as full-series statistics.
    bw==r.blue_wins && rw==r.red_wins
}

fn records(ctx: &StableClient<'_>,previous:&[Review]) -> Vec<Review> {
    let Some(own) = ctx.player_team_id() else { return Vec::new() };
    let mut reviews=Vec::new();
    // The actual campaign stores all Match records in Kind14. Legacy
    // subtype tables5..8 can be empty; use them only if the unified table is absent.
    let unified=ctx.record_ids(Kind::Match);
    let tables=if unified.is_empty(){[Kind::MatchNormal,Kind::MatchPractice,Kind::MatchTutorial,Kind::MatchSoloRank].into_iter().map(|k|(k,ctx.record_ids(k))).collect::<Vec<_>>()}else{vec![(Kind::Match,unified)]};
    for (kind,mut ids) in tables {
        ids.sort_unstable();
        for id in ids.into_iter().rev() {
            if let Some(cached)=previous.iter().find(|r|r.id==id&&r.kind==kind.code()&&(r.blue==own||r.red==own)){
                let mut r=cached.clone();refresh_team_metadata(ctx,&mut r);reviews.push(r);continue;
            }
            // Read only the small replay-id fragment for the many future
            // scheduled matches. No simulated scores or future popups.
            let Some(raw_ids)=ctx.record_get_json(kind,id,"replays") else {continue};
            let Ok(replay_ids)=serde_json::from_str::<Vec<usize>>(&raw_ids) else {continue};
            if replay_ids.is_empty(){continue;}
            let Some(raw)=ctx.record_get_json(kind,id,"") else { continue };
            let Ok(v)=serde_json::from_str::<Value>(&raw) else { continue };
            if kind==Kind::Match && v.get("running_state").and_then(|s|s.get("End")).is_none(){continue;}
            let replays:Option<Vec<Value>>=replay_ids.iter().map(|rid|read_replay(ctx,*rid,own)).collect();
            let Some(mut r)=replays.and_then(|rs|merge_replays(id,&rs)) else {continue};
            r.replay_ids=replay_ids;
            r.need_win=integer(v.get("need_win")).unwrap_or(2);
            if r.need_win==0 || r.blue_wins.max(r.red_wins)<r.need_win {continue;}
            if kind==Kind::Match && !campaign_score_matches(&v,&r){continue;}
            r.official=if kind==Kind::Match {v.get("is_practice").and_then(Value::as_bool)==Some(false)&&v.get("is_room_practice").and_then(Value::as_bool)==Some(false)}else{kind==Kind::MatchNormal};
            r.kind=kind.code();
            refresh_team_metadata(ctx,&mut r);
            for p in &mut r.players {p.name=ctx.athlete_name(p.id).unwrap_or_else(||format!("선수 {}",p.id));}
            reviews.push(r);
        }
    }
    reviews.sort_by_key(|r|std::cmp::Reverse(r.id));
    reviews.truncate(40);
    reviews
}

fn comment(p: &Player, match_id: usize) -> &'static str {
    let stars=if p.ratings>0{fan_stars(p.raw_rating/p.ratings as f64)}else{3};
    let category = if stars>=4 { "good" } else if stars<=2 { "bad" } else { "neutral" };
    let count=CORPUS.lines().filter(|l|l.split_once('\t').is_some_and(|(c,_)|c==category)).count();
    let index=p.id.wrapping_mul(31).wrapping_add(match_id)%count.max(1);
    CORPUS.lines().filter_map(|l|l.split_once('\t')).filter(|(c,_)|*c==category).nth(index).map(|(_,s)|s).unwrap_or("")
}

fn label(id: &str, x: &str, y: usize, width: &str, text: &str, size: usize) -> String {
    // serde's quoted string syntax is accepted by the shipped .ui grammar.
    format!("#{id}:label {{ @\"asset/base/style/main#bold_label\"; z:1802; x:{x}; y:{y}px; width:{width}; height:36px; ignore_event:true; text:{}; size:{size}; }}",serde_json::to_string(text).unwrap())
}
fn button_caption(text: &str) -> String {
    format!("text: {{ font: \"asset/base/font/set/bold\"; size: 16; align_x: Center; align_y: Center; text: {}; }}", serde_json::to_string(text).unwrap())
}
fn button(id: &str, x: &str, text: &str) -> String {
    format!("#{id}:color_icon_button {{ @\"asset/base/style/main#tertiary_button\"; z:1803; x:{x}; y:90%; width:100px; height:44px; {} }}",button_caption(text))
}
fn panel_source(state: &State) -> String {
    let mut s=String::from("pm_ipad_panel:color { z:1800; x:3%; y:5%; width:94%; height:90%; color:#14161df5; ");
    s+=&label("heading","3%",12,"65%","경기 후 평가 · 전 세트 합산",22);
    s+=&format!("#auto:color_icon_button {{ @\"asset/base/style/main#tertiary_button\"; z:1803; x:72%; y:12px; width:24%; height:40px; {} }}",button_caption(if state.auto{"자동 열기 켜짐"}else{"자동 열기 꺼짐"}));
    s+=&label("note","3%",47,"90%","원본 평점 변환 · 팬 별점 / 전 세트 합산",13);
    if let Some(r)=state.reviews.get(state.page) {
        s+=&label("match","3%",80,"90%",&format!("경기 #{} · BO{} · {}:{} · {}세트 · {}/{}",r.id,r.need_win.saturating_mul(2).saturating_sub(1),r.blue_wins,r.red_wins,r.sets,state.page+1,state.reviews.len()),16);
        // Two columns keep ten-player reviews usable on the iPad 4:3 viewport.
        for (side,tid) in [r.blue,r.red].into_iter().enumerate() {
            let x=if side==0 {"3%"} else {"51%"};
            s+=&label(&format!("team{side}"),x,118,"46%",if side==0{&r.blue_name}else{&r.red_name},18);
            let members:Vec<_>=r.players.iter().filter(|p|p.team==tid).collect();
            let (k,d,a)=members.iter().fold((0,0,0),|(k,d,a),p|(k+p.kills,d+p.deaths,a+p.assists));
            let ratings=members.iter().map(|p|p.ratings).sum::<usize>();
            let avg=if ratings>0{members.iter().map(|p|p.rating).sum::<f64>()/ratings as f64}else{0.0};
            s+=&label(&format!("summary{side}"),x,148,"46%",&format!("전 세트 K/D/A {k}/{d}/{a} · 평균 {avg:.1}/10"),14);
            let best=members.iter().filter(|p|p.ratings>0).max_by(|a,b|{
                (a.raw_rating/a.ratings as f64).total_cmp(&(b.raw_rating/b.ratings as f64)).then_with(||a.mvps.cmp(&b.mvps)).then_with(||b.id.cmp(&a.id))
            });
            if let Some(p)=best{s+=&label(&format!("mvp{side}"),x,177,"46%",&format!("평점 MVP · {} · 세트 MVP {}회",p.name,p.mvps),15);}
            let grade=team_grade(r,tid).map(|n|"★".repeat(n)).unwrap_or_else(||"정보 없음".into());
            let (fans,m)=if side==0{(r.blue_fans,&r.blue_mood)}else{(r.red_fans,&r.red_mood)};
            let fans=fans.map(|n|n.to_string()).unwrap_or_else(||"—".into());
            s+=&label(&format!("grade{side}"),x,208,"46%",&format!("팀 평가 {grade} · 현재 팬 {fans} · {}",mood(m)),13);
            for (row,p) in r.players.iter().filter(|p|p.team==tid).take(6).enumerate() {
                let rating=if p.ratings>0 {format!("평점 {:.1}/10",p.rating/p.ratings as f64)}else{"평점 없음".into()};
                s+=&label(&format!("p{side}_{row}"),x,248+row*64,"46%",&format!("{}  {}/{}/{} · {}",p.name,p.kills,p.deaths,p.assists,rating),16);
                let stars=if p.ratings>0{fan_stars(p.raw_rating/p.ratings as f64)}else{0};
                let text=format!("{}  {}","★".repeat(stars),comment(p,r.id));
                s+=&label(&format!("c{side}_{row}"),x,274+row*64,"46%",&text,13);
            }
        }
    } else {
        s+=&label("empty","3%",130,"90%","읽을 수 있는 완료 경기 기록이 없습니다.",18);
        s+=&label("hint","3%",175,"90%","경기를 마친 뒤 다시 열어 주세요.",16);
    }
    s+=&button("prev","3%","이전 경기");
    s+=&button("next","38%","다음 경기");
    s+=&button("close","76%","닫기");
    s+"}"
}
fn render(ctx: &mut StableClient<'_>, state: Arc<Mutex<State>>) {
    ctx.ui_remove_node(PANEL);
    let Ok(locked)=state.lock() else {return};
    let source=panel_source(&locked);
    drop(locked);
    if !ctx.ui_spawn_source("main",&source) { status("panel-spawn-failed",0); return; }
    status("panel-open",state.lock().map(|s|s.reviews.len()).unwrap_or(0));
    ctx.ui_register_click(&format!("{PANEL}.close"),"",|c|{c.ui_remove_node(PANEL);});
    let auto_state=state.clone();
    ctx.ui_register_click(&format!("{PANEL}.auto"),"",move|c|{
        if let Ok(mut s)=auto_state.lock(){
            s.auto=!s.auto;
            let _=std::fs::write(std::path::Path::new("mods").join(ID).join("auto-open.txt"),if s.auto{"true"}else{"false"});
        }
        render(c,auto_state.clone());
    });
    for (name,forward) in [("prev",false),("next",true)] {
        let st=state.clone();
        ctx.ui_register_click(&format!("{PANEL}.{name}"),"",move |c| {
            if let Ok(mut s)=st.lock() {
                if forward { s.page=(s.page+1).min(s.reviews.len().saturating_sub(1)); }
                else { s.page=s.page.saturating_sub(1); }
            }
            render(c,st.clone());
        });
    }
}
impl StableExtension for Extension {
    fn post_update(&self,ctx:&mut StableClient<'_>,dt:u64) {
        if !ctx.is_in_game() {
            if let Ok(mut s)=self.0.lock(){s.seeded=false;s.seen.clear();s.reviews.clear();s.own_team=None;s.settlement_ready=false;s.settlement_baseline_captured=false;s.settlement_baseline=None;s.settlement_pending=None;}
            return;
        }
        let current_team=ctx.player_team_id();
        if let Ok(mut s)=self.0.lock(){
            if current_team!=s.own_team{
                s.own_team=current_team;s.seeded=false;s.seen.clear();s.reviews.clear();s.settlement_ready=false;
                s.settlement_baseline_captured=false;s.settlement_baseline=None;s.settlement_pending=None;s.elapsed=5_000_000;s.ui_elapsed=1_000_000;
            }
        }
        let enabled=self.0.lock().map(|s|s.settlement_enabled).unwrap_or(false);
        if enabled{
            for event in ctx.take_events(){
                if event.event=="legacy_settlement_status"{
                    if let Ok(v)=serde_json::from_slice::<Value>(&event.payload){
                        let phase=v.get("phase").and_then(Value::as_str).unwrap_or("");
                        let id=integer(v.get("match_id"));
                        let team=integer(v.get("team"));
                        if let Ok(mut s)=self.0.lock(){
                            if team==s.own_team{
                                if phase=="settlement-baseline"&&id==Some(s.settlement_baseline.as_ref().map(|r|r.id).unwrap_or(0)){s.settlement_ready=true;}
                                if (phase=="settlement-committed"||phase=="settlement-duplicate")&&s.settlement_pending.as_ref().map(|r|r.id)==id{s.settlement_pending=None;}
                            }
                        }
                    }
                }
            }
        }
        if !ctx.ui_exists("main") || !access::reachable(ctx) {return;}
        let refresh=if let Ok(mut s)=self.0.lock() {
            s.elapsed=s.elapsed.saturating_add(dt);
            if s.elapsed>=5_000_000 {s.elapsed=0;true}else{false}
        }else{false};
        if refresh && !ctx.ui_exists(PANEL) {
            let previous=self.0.lock().map(|s|s.reviews.clone()).unwrap_or_default();
            let rs=records(ctx,&previous);
            status("records-scanned",rs.len());
            let mut open=false;
            if let Ok(mut s)=self.0.lock() {
                if s.settlement_enabled{
                    let latest=rs.iter().find(|r|r.official);
                    if !s.settlement_baseline_captured{s.settlement_baseline=latest.cloned();s.settlement_baseline_captured=true;}
                    if s.seeded&&latest.is_some_and(|r|s.reviews.iter().find(|p|p.official).is_none_or(|old|r.id>old.id)){
                        s.settlement_pending=latest.cloned();
                    }
                }
                open=update_reviews(&mut s,rs);
            }
            if enabled{
                let request=self.0.lock().ok().map(|s|if !s.settlement_ready{(s.settlement_baseline.clone(),true)}else{(s.settlement_pending.clone(),false)});
                if let Some((review,baseline))=request{if baseline||review.is_some(){settlement_host::send(ctx,review.as_ref(),baseline);}}
            }
            if open{render(ctx,self.0.clone());}
        }
        let update_access=if let Ok(mut s)=self.0.lock(){
            s.ui_elapsed=s.ui_elapsed.saturating_add(dt);
            if s.ui_elapsed>=1_000_000{s.ui_elapsed=0;true}else{false}
        }else{false};
        if update_access{access::update(ctx,self.0.clone());}
    }
}
fn init(host:&StableHost)->StableMod {
    let enabled=std::fs::read_to_string(std::path::Path::new("mods").join(ID).join("settlement-enabled.txt")).map(|v|v.trim()=="true").unwrap_or(false);
    SETTLEMENT_ACTIVE.store(enabled,std::sync::atomic::Ordering::Relaxed);
    host.log(LogLevel::Info,if enabled{"postmatch loaded; experimental legacy settlement explicitly enabled"}else{"postmatch loaded; save updates disabled"});
    status("initialized",0);
    let mut m=StableMod::new(ID);
    let auto=std::fs::read_to_string(std::path::Path::new("mods").join(ID).join("auto-open.txt")).map(|v|v.trim()!="false").unwrap_or(true);
    m.set_extension(Extension(Arc::new(Mutex::new(State{auto,settlement_enabled:enabled,..State::default()}))));
    if enabled{m.set_server_extension(settlement_host::Server);}
    m
}
// The shipped builder writes ABI_LEVEL into ModExportV1. Keep the symbol
// consistent with that field (the current SDK is level10).
declare_stable_mod!(init,requires=10);

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn replay(b:usize,r:usize,won:bool)->Value {
        json!({"blue_team_id":b,"red_team_id":r,"blue_team_win":won,
            "blue_team":[{"athlete_id":b*10,"statistics":{"kills":5,"deaths":2,"assists":4,"rating":7.5}}],
            "red_team":[{"athlete_id":r*10,"statistics":{"kills":2,"deaths":5,"assists":1,"rating":4.5}}]})
    }
    #[test] fn campaign_end_requires_matching_complete_replays_and_accepts_team_zero() {
        let v=serde_json::json!({"team1":{"Normal":0},"team2":{"Normal":3},"running_state":{"End":{"team1_score":2,"team2_score":1}}});
        let mut r=Review{blue:0,red:3,blue_wins:2,red_wins:1,..Review::default()};
        assert!(campaign_score_matches(&v,&r));r.blue=3;r.red=0;r.blue_wins=1;r.red_wins=2;
        assert!(campaign_score_matches(&v,&r));r.blue_wins=0;assert!(!campaign_score_matches(&v,&r));
        assert!(!campaign_score_matches(&serde_json::json!({"running_state":"Wait"}),&r));
    }
    #[test] fn new_completed_low_id_still_opens_once_after_high_id_history() {
        let mut state=State{auto:true,..State::default()};
        let old=Review{id:600,kind:14,official:true,..Review::default()};
        let new=Review{id:3,kind:14,official:true,..Review::default()};
        assert!(!update_reviews(&mut state,vec![old.clone()]));
        assert!(update_reviews(&mut state,vec![old.clone(),new.clone()]));assert_eq!(state.page,1);
        assert!(!update_reviews(&mut state,vec![old,new]));
    }

    #[test] fn merges_side_swap_by_athlete_and_team() {
        let r=merge_replays(42,&[replay(1,2,true),replay(2,1,false)]).unwrap();
        let p=r.players.iter().find(|p|p.id==10).unwrap();
        assert_eq!((r.sets,p.sets,p.kills,p.deaths,p.assists,p.wins),(2,2,7,7,5,2));
        assert_eq!(p.rating/p.ratings as f64,6.0);
    }
    #[test] fn refuses_mixed_matches_and_partial_rosters() {
        assert!(merge_replays(1,&[replay(1,2,true),replay(1,3,true)]).is_none());
        let mut broken=replay(1,2,true);broken["red_team"][0]["statistics"]=json!({});
        assert!(merge_replays(1,&[broken]).is_none());
    }
    #[test] fn accepts_documented_singular_statistics() {
        let mut r=replay(1,2,true);
        r["blue_team"][0]["statistics"]=json!({"kill":4,"death":1,"assist":9,"rating":5.0});
        let got=merge_replays(1,&[r]).unwrap();
        assert_eq!((got.players[0].kills,got.players[0].deaths,got.players[0].assists),(4,1,9));
    }
    #[test] fn recovered_rating_conversion_preserves_proxy_boundaries() {
        for (v,want) in [(0.0,0.0),(7.5,7.5),(10.0,10.0),(65.0,6.5),(100.0,10.0)] {
            assert_eq!(normalized_rating(v),Some(want));
        }
        for v in [-0.01,100.01,f64::INFINITY,f64::NAN] {assert!(normalized_rating(v).is_none());}
    }
    #[test] fn recovered_fan_stars_follow_core_thresholds() {
        for (raw,want) in [(0.0,1),(56.0,1),(58.4,1),(58.5,2),(63.5,3),(68.5,4),(73.5,5),(100.0,5)] {
            assert_eq!(fan_stars(raw),want);
        }
    }
    #[test] fn bo3_and_bo5_keep_both_team_results_across_side_swaps() {
        let mut set=replay(1,2,true);set["blue_team"][0]["statistics"]["mvp"]=json!(1);
        let bo3=merge_replays(12,&[set,replay(2,1,true),replay(1,2,true)]).unwrap();
        assert_eq!((bo3.blue_wins,bo3.red_wins,bo3.sets),(2,1,3));
        assert_eq!(bo3.players.iter().find(|p|p.id==10).unwrap().mvps,1);
        let bo5=merge_replays(13,&[replay(1,2,true),replay(2,1,true),replay(1,2,true),replay(2,1,true),replay(1,2,true)]).unwrap();
        assert_eq!((bo5.blue_wins,bo5.red_wins,bo5.sets),(3,2,5));
    }
    #[test] fn auto_popup_skips_startup_history_and_announces_new_official_result_once() {
        fn r(id:usize)->Review{Review{id,official:true,..Review::default()}}
        let mut state=State{auto:true,..State::default()};
        assert!(!update_reviews(&mut state,vec![r(42),r(41)]));
        assert!(!update_reviews(&mut state,vec![r(42),r(41)]));
        assert!(update_reviews(&mut state,vec![r(43),r(42)]));
        assert!(!update_reviews(&mut state,vec![r(43),r(42)]));
        state.auto=false;
        assert!(!update_reviews(&mut state,vec![r(44),r(43)]));
        state.seeded=false;state.auto=true;
        assert!(!update_reviews(&mut state,vec![r(900),r(899)]));
    }
    #[test] fn recovered_team_grade_penalizes_loss_and_sweep_and_rewards_strong_winner() {
        let mut r=Review{blue:1,red:2,blue_wins:2,red_wins:1,need_win:2,
            players:vec![Player{team:1,raw_rating:70.0,ratings:1,..Player::default()},Player{team:1,raw_rating:76.0,ratings:1,..Player::default()},Player{team:2,raw_rating:70.0,ratings:1,..Player::default()}],..Review::default()};
        assert_eq!(team_grade(&r,1),Some(5));
        assert_eq!(team_grade(&r,2),Some(3));
        r.blue_wins=3;r.red_wins=0;r.need_win=3;
        assert_eq!(team_grade(&r,2),Some(2));
        r.players[0].ratings=0;
        assert_eq!(team_grade(&r,1),None);
    }
    #[test] fn recovered_corpus_is_complete() {
        assert_eq!(CORPUS.lines().count(),1968);
        for c in ["good","neutral","bad"] {assert!(CORPUS.lines().any(|s|s.starts_with(&format!("{c}\t"))));}
        assert!(!comment(&Player{sets:1,wins:1,..Player::default()},1).is_empty());
    }
}
