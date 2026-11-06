//! Explicitly gated legacy-core settlement reconstruction. Disabled by default.
//!
//! The rate/grade rules are observed in the supplied Oct31 core. The prepared
//! absolute-target journal is a new reconciliation design, not a claim that the
//! original command transport was transactional or conserved the fan pool.
use serde_json::{json,Value};

#[derive(Clone,Debug)]
pub struct Request {pub baseline:bool,pub match_id:usize,pub team:usize,pub replays:Vec<usize>,
    pub need_win:usize,pub won:usize,pub lost:usize,pub grade:usize,pub ratings:Vec<(usize,f64)>}
#[derive(Clone,Debug,PartialEq)]
struct Target{id:usize,before:i64,after:i64}
#[derive(Clone,Debug)]
struct Plan{match_id:usize,targets:Vec<Target>,mood_before:String,mood_after:String,remainder:i32}
#[derive(Clone,Debug,Default)]
struct Ledger{last:Option<usize>,remainder:i32,pending:Option<Plan>}

pub trait Backend {
    fn validate_match(&mut self,request:&Request)->bool;
    fn ledger_get(&mut self,team:usize)->Option<String>;
    fn ledger_set(&mut self,team:usize,value:&str)->bool;
    fn fans_get(&mut self,id:usize)->Option<i64>;
    fn fans_set(&mut self,id:usize,value:i64)->bool;
    fn mood_get(&mut self,team:usize)->Option<String>;
    fn mood_set(&mut self,team:usize,value:&str)->bool;
}
#[derive(Debug,PartialEq)]
pub enum Outcome{Baseline,Duplicate,Committed,Blocked(&'static str)}

// ev_c75f116e... FUN180002b10: rates -150,-60,0,60,120 basis
// points; on a losing side, positives*3/4, others*6/5, then subtract20.
pub fn legacy_fan_delta(fans:i64,raw:f64,losing:bool)->Option<i64>{
    if fans<0||!raw.is_finite()||!(0.0..=100.0).contains(&raw){return None;}
    let stars=super::fan_stars(raw);
    let mut rate=[-150,-60,0,60,120][stars-1];
    if losing{rate=if rate>0{rate*3/4}else{rate*6/5};rate-=20;}
    let product=fans.checked_mul(rate)?;
    let magnitude=(product/10000).checked_abs()?.max(i64::from(rate!=0));
    Some(if rate<0{-magnitude}else{magnitude})
}
fn mood_index(mood:&str)->Option<usize>{
    ["VeryDissatisfied","Dissatisfied","Normal","Satisfied","VerySatisfied"].iter().position(|s|*s==mood)
}
fn next_mood(before:&str,grade:usize,remainder:i32)->Option<(String,i32)>{
    if !(1..=5).contains(&grade)||!(-2..=2).contains(&remainder){return None;}
    // Original byte table at1800edf5d indexed3..5 is0,1,1.
    let points=if grade<3{-1}else if grade==3{0}else{1};
    let total=remainder+points;
    let (step,rem)=if total>=3{(1,total-3)}else if total<=-3{(-1,total+3)}else{(0,total)};
    let index=(mood_index(before)? as i32+step).clamp(0,4) as usize;
    Some((["VeryDissatisfied","Dissatisfied","Normal","Satisfied","VerySatisfied"][index].into(),rem))
}
fn ledger_encode(l:&Ledger)->String{
    let pending=l.pending.as_ref().map(|p|json!({"match":p.match_id,"targets":p.targets.iter().map(|t|json!({"id":t.id,"before":t.before,"after":t.after})).collect::<Vec<_>>(),"mood_before":p.mood_before,"mood_after":p.mood_after,"remainder":p.remainder}));
    json!({"schema":1,"last":l.last,"remainder":l.remainder,"pending":pending}).to_string()
}
fn number(v:&Value,key:&str)->Option<usize>{usize::try_from(v.get(key)?.as_u64()?).ok()}
fn ledger_decode(raw:&str)->Option<Ledger>{
    let v:Value=serde_json::from_str(raw).ok()?;
    if v.get("schema")?.as_u64()!=Some(1){return None;}
    let remainder=i32::try_from(v.get("remainder")?.as_i64()?).ok()?;
    if !(-2..=2).contains(&remainder){return None;}
    let p=v.get("pending")?;
    let pending=if p.is_null(){None}else{
        let targets=p.get("targets")?.as_array()?.iter().map(|t|Some(Target{id:number(t,"id")?,before:t.get("before")?.as_i64()?,after:t.get("after")?.as_i64()?})).collect::<Option<Vec<_>>>()?;
        if targets.is_empty()||targets.len()>20||targets.iter().any(|t|t.before<0||t.after<0){return None;}
        let rem=i32::try_from(p.get("remainder")?.as_i64()?).ok()?;
        if !(-2..=2).contains(&rem){return None;}
        let before=p.get("mood_before")?.as_str()?.to_owned();let after=p.get("mood_after")?.as_str()?.to_owned();
        mood_index(&before)?;mood_index(&after)?;
        Some(Plan{match_id:number(p,"match")?,targets,mood_before:before,mood_after:after,remainder:rem})
    };
    let last=if v.get("last")?.is_null(){None}else{Some(number(&v,"last")?)};
    Some(Ledger{last,remainder,pending})
}
fn reconcile<B:Backend>(backend:&mut B,team:usize,ledger:&mut Ledger)->Outcome{
    let Some(plan)=ledger.pending.clone()else{return Outcome::Duplicate;};
    // Check every current value before any new write. Later game changes or
    // unsupported schemas block reconciliation instead of being overwritten.
    for t in &plan.targets{
        if !backend.fans_get(t.id).is_some_and(|n|n==t.before||n==t.after){return Outcome::Blocked("fan-conflict");}
    }
    if !backend.mood_get(team).is_some_and(|m|m==plan.mood_before||m==plan.mood_after){return Outcome::Blocked("mood-conflict");}
    for t in &plan.targets{
        if backend.fans_get(t.id)!=Some(t.after)&&(!backend.fans_set(t.id,t.after)||backend.fans_get(t.id)!=Some(t.after)){return Outcome::Blocked("fan-write-pending");}
    }
    if backend.mood_get(team).as_deref()!=Some(plan.mood_after.as_str())&&(!backend.mood_set(team,&plan.mood_after)||backend.mood_get(team).as_deref()!=Some(plan.mood_after.as_str())){return Outcome::Blocked("mood-write-pending");}
    let committed=Ledger{last:Some(plan.match_id),remainder:plan.remainder,pending:None};
    if !backend.ledger_set(team,&ledger_encode(&committed)){return Outcome::Blocked("commit-pending");}
    *ledger=committed;Outcome::Committed
}
pub fn handle<B:Backend>(backend:&mut B,request:&Request)->Outcome{
    if !backend.validate_match(request){return Outcome::Blocked("match-schema");}
    let raw=backend.ledger_get(request.team);
    let mut ledger=match raw.as_deref(){Some(s)=>match ledger_decode(s){Some(l)=>l,None=>return Outcome::Blocked("ledger-schema")},None=>Ledger::default()};
    if ledger.pending.is_some(){
        if let Outcome::Blocked(reason)=reconcile(backend,request.team,&mut ledger){return Outcome::Blocked(reason);}
    }
    // Opening an existing save establishes a baseline, never retroactively
    // settles history. An absent journal has the same safe baseline rule.
    if request.baseline||raw.is_none(){
        if !request.replays.is_empty(){ledger.last=Some(ledger.last.unwrap_or(0).max(request.match_id));}
        return if backend.ledger_set(request.team,&ledger_encode(&ledger)){Outcome::Baseline}else{Outcome::Blocked("baseline-write")};
    }
    if ledger.last.is_some_and(|last|request.match_id<=last){return Outcome::Duplicate;}
    if !(1..=5).contains(&request.grade)||request.ratings.is_empty()||request.ratings.len()>20{return Outcome::Blocked("rating-schema");}
    let mut ids=std::collections::BTreeSet::new();let mut targets=Vec::new();
    for (id,rating) in &request.ratings{
        if !ids.insert(*id){return Outcome::Blocked("duplicate-athlete");}
        let Some(before)=backend.fans_get(*id)else{return Outcome::Blocked("fan-schema");};
        let Some(delta)=legacy_fan_delta(before,*rating,request.won<=request.lost)else{return Outcome::Blocked("fan-range");};
        let Some(after)=before.checked_add(delta).map(|n|n.max(0))else{return Outcome::Blocked("fan-overflow");};
        targets.push(Target{id:*id,before,after});
    }
    let Some(before)=backend.mood_get(request.team)else{return Outcome::Blocked("mood-schema");};
    let Some((after,remainder))=next_mood(&before,request.grade,ledger.remainder)else{return Outcome::Blocked("mood-range");};
    ledger.pending=Some(Plan{match_id:request.match_id,targets,mood_before:before,mood_after:after,remainder});
    if !backend.ledger_set(request.team,&ledger_encode(&ledger)){return Outcome::Blocked("prepare-write");}
    reconcile(backend,request.team,&mut ledger)
}

#[cfg(test)]
mod tests{
    use super::*;
    use std::collections::BTreeMap;
    #[derive(Clone)]struct Mock{ledger:Option<String>,fans:BTreeMap<usize,i64>,mood:String,fail:Option<usize>,writes:usize}
    impl Default for Mock{fn default()->Self{Self{ledger:None,fans:[(10,10000),(11,10000)].into(),mood:"Normal".into(),fail:None,writes:0}}}
    impl Mock{fn allowed(&mut self)->bool{self.writes+=1;self.fail!=Some(self.writes)}}
    impl Backend for Mock{
        fn validate_match(&mut self,_:&Request)->bool{true}
        fn ledger_get(&mut self,_:usize)->Option<String>{self.ledger.clone()}
        fn ledger_set(&mut self,_:usize,v:&str)->bool{if !self.allowed(){return false;}self.ledger=Some(v.into());true}
        fn fans_get(&mut self,id:usize)->Option<i64>{self.fans.get(&id).copied()}
        fn fans_set(&mut self,id:usize,v:i64)->bool{if !self.allowed(){return false;}self.fans.insert(id,v);true}
        fn mood_get(&mut self,_:usize)->Option<String>{Some(self.mood.clone())}
        fn mood_set(&mut self,_:usize,v:&str)->bool{if !self.allowed(){return false;}self.mood=v.into();true}
    }
    fn request(id:usize,baseline:bool)->Request{Request{baseline,match_id:id,team:1,replays:vec![1,2,3],need_win:2,won:2,lost:1,grade:4,ratings:vec![(10,70.0),(11,76.0)]}}
    #[test]fn observed_legacy_rate_table_and_losing_modifier(){
        for (rating,win,loss) in [(50.0,-150,-200),(60.0,-60,-92),(65.0,0,-20),(70.0,60,25),(76.0,120,70)]{
            assert_eq!(legacy_fan_delta(10000,rating,false),Some(win));assert_eq!(legacy_fan_delta(10000,rating,true),Some(loss));
        }
        assert_eq!(legacy_fan_delta(1,76.0,false),Some(1));assert_eq!(legacy_fan_delta(0,50.0,false),Some(-1));
    }
    #[test]fn no_retroactive_history_and_same_match_does_not_apply_twice(){
        let mut b=Mock::default();assert_eq!(handle(&mut b,&request(42,true)),Outcome::Baseline);
        assert_eq!(b.fans[&10],10000);
        assert_eq!(handle(&mut b,&request(43,false)),Outcome::Committed);
        assert_eq!((b.fans[&10],b.fans[&11]),(10060,10120));let after=b.fans.clone();
        assert_eq!(handle(&mut b,&request(43,false)),Outcome::Duplicate);assert_eq!(after,b.fans);
    }
    #[test]fn interrupted_prepare_each_fan_and_commit_reconcile_without_double_add(){
        let mut baseline=Mock::default();handle(&mut baseline,&request(42,true));
        for failure in 1..=4{
            let mut b=baseline.clone();b.writes=0;b.fail=Some(failure);
            assert!(matches!(handle(&mut b,&request(43,false)),Outcome::Blocked(_)));
            b.fail=None;let _=handle(&mut b,&request(43,false));
            assert_eq!((b.fans[&10],b.fans[&11]),(10060,10120));
            assert!(ledger_decode(b.ledger.as_ref().unwrap()).unwrap().pending.is_none());
        }
    }
    #[test]fn unrelated_later_game_changes_block_pending_reconciliation(){
        let mut b=Mock::default();handle(&mut b,&request(42,true));b.writes=0;b.fail=Some(3);
        assert!(matches!(handle(&mut b,&request(43,false)),Outcome::Blocked(_)));
        b.fail=None;b.fans.insert(10,20000);
        assert_eq!(handle(&mut b,&request(43,false)),Outcome::Blocked("fan-conflict"));assert_eq!(b.fans[&10],20000);
    }
    #[test]fn original_team_points_reach_mood_threshold_once(){
        assert_eq!(next_mood("Normal",5,1),Some(("Normal".into(),2)));
        assert_eq!(next_mood("Normal",5,2),Some(("Satisfied".into(),0)));
        assert_eq!(next_mood("VerySatisfied",4,2),Some(("VerySatisfied".into(),0)));
        assert_eq!(next_mood("Normal",1,-2),Some(("Dissatisfied".into(),0)));
    }
}
