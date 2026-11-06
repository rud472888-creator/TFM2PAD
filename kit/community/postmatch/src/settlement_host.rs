//! Stable-SDK adapter for the default-off legacy reconciliation experiment.
use mod_api_stable::{CommandResultV1,RecordKindV1,StableCommand,StableServerCtx,StableServerExtension};
use serde_json::{json,Value};
use crate::{settlement::{self,Backend,Request},Review,StableClient};

const COMMAND:&str="legacy_settle_v1";
fn integer(v:&Value,key:&str)->Option<usize>{usize::try_from(v.get(key)?.as_u64()?).ok()}
pub fn send(ctx:&mut StableClient<'_>,review:Option<&Review>,baseline:bool)->bool{
    if !ctx.save_can_write(){return false;}
    let Some(team)=ctx.player_team_id()else{return false;};
    let (match_id,replays,need_win,won,lost,grade,ratings)=if let Some(r)=review{
        let Some(grade)=crate::team_grade(r,team)else{return false;};
        let own:Vec<_>=r.players.iter().filter(|p|p.team==team).collect();
        if own.is_empty()||own.iter().any(|p|p.ratings==0){return false;}
        (r.id,r.replay_ids.clone(),r.need_win,if team==r.blue{r.blue_wins}else{r.red_wins},if team==r.blue{r.red_wins}else{r.blue_wins},grade,
            own.iter().map(|p|json!([p.id,p.raw_rating/p.ratings as f64])).collect::<Vec<_>>())
    }else if baseline{(0,Vec::new(),0,0,0,3,Vec::new())}else{return false;};
    let payload=json!({"schema":1,"baseline":baseline,"match_id":match_id,"team":team,"replays":replays,
        "need_win":need_win,"won":won,"lost":lost,"grade":grade,"ratings":ratings}).to_string();
    ctx.send_command(COMMAND,payload.as_bytes())
}
fn parse(payload:&[u8])->Option<Request>{
    if payload.len()>65536{return None;}
    let v:Value=serde_json::from_slice(payload).ok()?;
    if v.get("schema")?.as_u64()!=Some(1){return None;}
    let replays=v.get("replays")?.as_array()?.iter().map(|v|usize::try_from(v.as_u64()?).ok()).collect::<Option<Vec<_>>>()?;
    let ratings=v.get("ratings")?.as_array()?.iter().map(|v|Some((usize::try_from(v.get(0)?.as_u64()?).ok()?,v.get(1)?.as_f64()?))).collect::<Option<Vec<_>>>()?;
    Some(Request{baseline:v.get("baseline")?.as_bool()?,match_id:integer(&v,"match_id")?,team:integer(&v,"team")?,replays,
        need_win:integer(&v,"need_win")?,won:integer(&v,"won")?,lost:integer(&v,"lost")?,grade:integer(&v,"grade")?,ratings})
}
struct Adapter<'a,'b>(&'a mut StableServerCtx<'b>);
impl Backend for Adapter<'_,'_>{
    fn validate_match(&mut self,r:&Request)->bool{
        if r.baseline&&r.replays.is_empty(){return r.ratings.is_empty();}
        if r.need_win==0||r.need_win>10||r.won.max(r.lost)!=r.need_win||r.won==r.lost||r.replays.len()!=r.won+r.lost{return false;}
        // Fail closed if the running game's authoritative Match schema differs.
        // The SDK exposes Match on the server, MatchNormal on the client.
        let Some(raw)=self.0.record_get_json(RecordKindV1::Match,r.match_id,"replays")else{return false;};
        let Ok(Value::Array(values))=serde_json::from_str::<Value>(&raw)else{return false;};
        let ids=values.iter().map(|v|usize::try_from(v.as_u64()?).ok()).collect::<Option<Vec<_>>>();
        if ids.as_ref()!=Some(&r.replays){return false;}
        let Some(raw)=self.0.record_get_json(RecordKindV1::Match,r.match_id,"need_win")else{return false;};
        serde_json::from_str::<usize>(&raw).ok()==Some(r.need_win)
    }
    fn ledger_get(&mut self,team:usize)->Option<String>{self.0.save_get_string(&format!("settlement:v1:team:{team}"))}
    fn ledger_set(&mut self,team:usize,value:&str)->bool{self.0.save_set_string(&format!("settlement:v1:team:{team}"),value)}
    fn fans_get(&mut self,id:usize)->Option<i64>{self.0.athlete_get_i64(id,"management.fan_count")}
    fn fans_set(&mut self,id:usize,n:i64)->bool{self.0.athlete_set_i64(id,"management.fan_count",n)}
    fn mood_get(&mut self,team:usize)->Option<String>{self.0.team_get_string(team,"fan_satisfaction")}
    fn mood_set(&mut self,team:usize,value:&str)->bool{self.0.team_set_string(team,"fan_satisfaction",value)}
}
pub struct Server;
impl StableServerExtension for Server{
    fn handle_command(&self,ctx:&mut StableServerCtx<'_>,command:&StableCommand<'_>)->CommandResultV1{
        if command.command!=COMMAND{return CommandResultV1::Pass;}
        let Some(request)=parse(command.payload)else{return CommandResultV1::Handled;};
        // Host-enforced command sender identity, never an unscoped broadcast.
        if command.sender_team_id!=Some(request.team){return CommandResultV1::Handled;}
        let result=settlement::handle(&mut Adapter(ctx),&request);
        let phase=match result{settlement::Outcome::Baseline=>"settlement-baseline",settlement::Outcome::Duplicate=>"settlement-duplicate",settlement::Outcome::Committed=>"settlement-committed",settlement::Outcome::Blocked(reason)=>reason};
        crate::status(phase,0);
        let event=json!({"phase":phase,"match_id":request.match_id,"baseline":request.baseline,"team":request.team}).to_string();
        ctx.emit_event(command.reply_target(),"legacy_settlement_status",event.as_bytes());
        CommandResultV1::Handled
    }
}
