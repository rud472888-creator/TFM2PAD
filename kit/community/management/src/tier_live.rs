//! Offline reconstruction of the original live counters. Always a valid-data
//! subset, never a claim of complete season coverage or device verification.
//! REA planner ev_9206a587..., bans ev_385df43c..., mappers ev_8317f3d3 / ev_afeafef6.
use crate::tier_math::{percentile,win_rate,Champion};
use mod_api_stable::RecordKindV1 as Kind;
use serde_json::Value;
use std::collections::{BTreeMap,BTreeSet};

#[derive(Clone,Copy,Debug,Default,PartialEq)]
pub struct Counter {pub wins:u64,pub matches:u64,pub bans:u64}
#[derive(Clone,Debug,Default)]
pub struct Snapshot {
 pub counters:BTreeMap<String,Counter>,pub competitions:usize,pub skipped:usize,
 pub matches:usize,pub replays:usize,pub bans:usize,pub rows:usize,
}
impl Snapshot {
 pub fn label(&self)->String {format!("부분 자료·오프라인 재구성: 대회 {} / 제외 {} / 경기 목록 {} / 세트 {} / 밴 {} · 기기 미검증",self.competitions,self.skipped,self.matches,self.replays,self.bans)}
 pub fn blend(&self,champions:&[Champion],base:&[f32],weight:f32,win_share:f32,k:f32)->Vec<f32>{
  let wins:Vec<_>=champions.iter().map(|c|{let v=self.counters.get(&c.name).copied().unwrap_or_default();win_rate(v.wins,v.matches,k)}).collect();
  // Actual original mapper reads the THIRD counter (bans), not matches+bans.
  let bans:Vec<_>=champions.iter().map(|c|self.counters.get(&c.name).map(|v|v.bans).unwrap_or(0)as f32/self.replays as f32).collect();
  let wp=percentile(&wins);let bp=percentile(&bans);
  base.iter().enumerate().map(|(i,b)|b*(1.0-weight)+(bp[i]*(1.0-win_share)+wp[i]*win_share)*weight).collect()
 }
}
fn count(v:&Value)->Option<u64>{v.as_u64().filter(|n|*n<=1_000_000_000)}
fn id(v:&Value)->Option<usize>{v.as_u64().and_then(|n|usize::try_from(n).ok())}
fn add(to:&mut Counter,from:Counter)->Option<()>{to.wins=to.wins.checked_add(from.wins)?;to.matches=to.matches.checked_add(from.matches)?;to.bans=to.bans.checked_add(from.bans)?;if to.matches>1_000_000_000_000{return None;}Some(())}
fn stats(root:&Value)->Option<(BTreeMap<String,Counter>,usize)>{
 let statistics=root["statistics"].as_object().filter(|o|!o.is_empty()&&o.len()<=10000)?;
 let mut result=BTreeMap::new();let mut rows=0;
 for entry in statistics.values(){
  // Original iterates map values, ignoring values without champion_detail.
  let Some(raw)=entry.get("champion_detail")else{continue;};
  let details=raw.as_object().filter(|o|o.len()<=2000)?;
  for(name,v)in details{if name.is_empty()||name.len()>128{return None;}
   let wins=count(&v["wins"])?;let matches=count(&v["matches"])?;
   if wins>matches{return None;}add(result.entry(name.clone()).or_default(),Counter{wins,matches,bans:0})?;rows+=1;
  }
 }
 if rows==0||!result.values().any(|v|v.matches>0){return None;}Some((result,rows))
}
fn match_ids(root:&Value)->Option<BTreeSet<usize>>{
 let mut ids=BTreeSet::new();
 for field in ["matches","playoffs","promotion_series"]{let Some(v)=root.get(field)else{continue;};
  for v in v.as_array().filter(|a|a.len()<=20000)?{ids.insert(id(v)?);}
 }
 if ids.is_empty()||ids.len()>20000{None}else{Some(ids)}
}
fn ban_names(v:Value)->Option<Vec<String>>{let a=v.as_array().filter(|a|a.len()<=64)?;a.iter().map(|v|v.as_str().filter(|s|!s.is_empty()&&s.len()<=128).map(str::to_owned)).collect()}

/// Both UI preview and server commit use this collector. The server supplies
/// its own fresh host reads; commands cannot inject competition/replay counters.
pub fn collect(all:bool,names:&BTreeSet<String>,mut ids:impl FnMut(Kind)->Vec<usize>,mut read:impl FnMut(Kind,usize,&str)->Option<Value>)->Result<Snapshot,String>{
 let mut candidates=Vec::new();for kind in [Kind::LeagueCompetition,Kind::TournamentCompetition]{for i in ids(kind){candidates.push((kind,i));}}
 // Client/server maps can enumerate in different hash order. Keep overlap
 // exclusion and aggregation reproducible from identical record content.
 candidates.sort_by_key(|(kind,id)|(kind.code(),*id));candidates.dedup_by_key(|(kind,id)|(kind.code(),*id));
 if candidates.len()>2048{return Err("실전 자료가 너무 많습니다. 기본 능력치 0% 모드를 사용해 주세요.".into());}
 let mut out=Snapshot::default();let mut used_matches=BTreeSet::new();let mut used_replays=BTreeSet::new();
 for(kind,i)in candidates{
  let Some(root)=read(kind,i,"")else{out.skipped+=1;continue;};
  let Some(finalized)=root["finalized"].as_bool()else{out.skipped+=1;continue;};
  if finalized&&!all{continue;}
  let attempt=(||->Option<_>{
   let(mut counters,rows)=stats(&root)?;let matches=match_ids(&root)?;
   if matches.iter().any(|m|used_matches.contains(m)){return None;}
   let mut replays=BTreeSet::new();
   for m in &matches{let v=read(Kind::Match,*m,"replays")?;let a=v.as_array().filter(|a|a.len()<=1000)?;
    for v in a{replays.insert(id(v)?);}
   }
   if replays.is_empty()||replays.len()>20000||replays.iter().any(|r|used_replays.contains(r)){return None;}
   let mut bans=0;
   for replay in &replays{for field in ["blue_ban","red_ban"]{
    for name in ban_names(read(Kind::MatchReplay,*replay,field)?)?{
     // Unknown champion IDs can be from an absent mod. They do not contribute
     // to known champion scores, but remain in total observed ban coverage.
     add(counters.entry(name).or_default(),Counter{wins:0,matches:0,bans:1})?;bans+=1;
    }
   }}Some((counters,rows,matches,replays,bans))
  })();
  let Some((counters,rows,matches,replays,bans))=attempt else{out.skipped+=1;continue;};
  for(name,c)in counters{add(out.counters.entry(name).or_default(),c).ok_or("실전 누적 자료 범위가 너무 큽니다.")?;}
  out.competitions+=1;out.rows+=rows;out.bans+=bans;used_matches.extend(matches);used_replays.extend(replays);
  if used_replays.len()>100000{return Err("실전 세트 자료가 너무 많습니다. 기본 능력치 0% 모드를 사용해 주세요.".into());}
 }
 out.matches=used_matches.len();out.replays=used_replays.len();
 if out.competitions==0||out.replays==0||!out.counters.iter().any(|(n,c)|names.contains(n)&&c.matches>0)||!out.counters.iter().any(|(n,c)|names.contains(n)&&c.bans>0){
  return Err(format!("실전 반영 불가: 대회·승패·세트·밴 자료 부족 (제외 {}개). 능력치 0% 모드로 전환해 주세요.",out.skipped));
 }
 Ok(out)
}

#[cfg(test)]pub mod tests{
 use super::*;use serde_json::json;
 pub type Records=BTreeMap<(u32,usize,String),Value>;
 pub fn fixtures()->Records{let mut r=Records::new();r.insert((9,1,"".into()),json!({"finalized":false,"statistics":{"7":{"champion_detail":{"a":{"wins":8,"matches":10},"b":{"wins":2,"matches":10}}}},"matches":[40,40],"playoffs":[],"promotion_series":[]}));r.insert((14,40,"replays".into()),json!([501,501,502]));r.insert((15,501,"blue_ban".into()),json!(["a"]));r.insert((15,501,"red_ban".into()),json!(["b"]));r.insert((15,502,"blue_ban".into()),json!(["a"]));r.insert((15,502,"red_ban".into()),json!([]));r}
 pub fn run(r:&Records,all:bool)->Result<Snapshot,String>{let names=["a".to_string(),"b".to_string()].into_iter().collect();collect(all,&names,|k|r.keys().filter(|(kind,_,path)|*kind==k.code()&&path.is_empty()).map(|(_,id,_)|*id).collect(),|k,id,p|r.get(&(k.code(),id,p.into())).cloned())}
 #[test]fn observed_nested_schema_both_sides_dedup_and_bayes_blend(){let r=fixtures();let s=run(&r,false).unwrap();assert_eq!((s.competitions,s.matches,s.replays,s.bans),(1,1,2,3));assert_eq!(s.counters["a"],Counter{wins:8,matches:10,bans:2});assert_eq!(s.counters["b"],Counter{wins:2,matches:10,bans:1});let c=|n:&str|Champion{name:n.into(),category:0,base:[0.;6],growth:[0.;6],speed:0.,range:0.};let scores=s.blend(&[c("a"),c("b")],&[0.5,0.5],0.35,0.65,20.);assert!((scores[0]-0.5875).abs()<1e-6);assert!((scores[1]-0.4125).abs()<1e-6);}
 #[test]fn missing_inconsistent_or_nonstring_data_is_unavailable(){for mutate in 0..5{let mut r=fixtures();match mutate{0=>{r.remove(&(15,501,"blue_ban".into()));},1=>{r.insert((15,502,"red_ban".into()),json!([{"champion":"a"}]));},2=>{r.get_mut(&(9,1,"".into())).unwrap()["statistics"]["7"]["champion_detail"]["a"]["wins"]=json!(11);},3=>{r.get_mut(&(9,1,"".into())).unwrap()["finalized"]=Value::Null;},_=>{r.insert((14,40,"replays".into()),json!([]));}}assert!(run(&r,false).is_err(),"case {mutate}");}}
 #[test]fn finalized_scope_partial_competitions_and_overlap_are_explicit(){let mut r=fixtures();let mut old=r[&(9,1,"".into())].clone();old["finalized"]=json!(true);r.insert((10,2,"".into()),old);let current=run(&r,false).unwrap();assert_eq!(current.skipped,0);let all=run(&r,true).unwrap();assert_eq!(all.skipped,1);assert_eq!(all.replays,2);r.get_mut(&(9,1,"".into())).unwrap()["finalized"]=json!(true);assert!(run(&r,false).is_err());assert!(run(&r,true).is_ok());r.insert((9,3,"".into()),json!({"finalized":false,"statistics":{}}));assert_eq!(run(&r,true).unwrap().skipped,2);}
 #[test]fn valid_zero_bans_and_empty_data_are_unavailable_not_invented(){let mut r=fixtures();for((kind,_,_),v)in r.iter_mut(){if *kind==15{*v=json!([]);}}assert!(run(&r,false).is_err());assert!(run(&Records::new(),false).is_err());}
 #[test]fn future_scheduled_matches_can_have_empty_replays(){let mut r=fixtures();r.get_mut(&(9,1,"".into())).unwrap()["matches"].as_array_mut().unwrap().push(json!(41));r.insert((14,41,"replays".into()),json!([]));let s=run(&r,false).unwrap();assert_eq!((s.matches,s.replays),(2,2));}
}
