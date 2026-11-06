use crate::{button,quoted};
use crate::tier_math::{Champion,stat_scores,assign};
use crate::tier_live::{self,Snapshot};
use mod_api_stable::{StableClient,StableServerCtx,StableCommand};
use serde_json::{Value,json};
use std::sync::{Arc,Mutex};
const ROOT:&str="main.top.right.champion_info";
const PANEL:&str="main.top.right.champion_info.mgmt_tier_panel";
#[derive(Clone,Debug)]pub struct Config{pub weights:[f32;7],pub cuts:[u32;4],pub level:f32,pub overall:bool,pub live_weight:f32,pub win_share:f32,pub bayes_k:f32,pub all_competitions:bool}
impl Default for Config{fn default()->Self{Self{weights:[0.35,0.35,0.1,0.1,0.1,0.0,0.0],cuts:[15,35,65,85],level:6.5,overall:false,live_weight:0.0,win_share:0.65,bayes_k:20.0,all_competitions:false}}}
impl Config{
 fn value(&self)->Value{json!({"weights":self.weights,"cuts":self.cuts,"level":self.level,"overall":self.overall,"live_weight":self.live_weight,"win_share":self.win_share,"bayes_k":self.bayes_k,"all_competitions":self.all_competitions})}
 fn parse(v:&Value)->Result<Self,String>{
  let mut c=Self::default();let weights=v["weights"].as_array().filter(|a|a.len()==7).ok_or("가중치를 확인해 주세요.")?;
  for(i,x)in weights.iter().enumerate(){c.weights[i]=x.as_f64().filter(|x|x.is_finite()&&(0.0..=10.0).contains(x)).ok_or("가중치 범위가 올바르지 않습니다.")? as f32;}
  if c.weights.iter().sum::<f32>()<=0.0{return Err("가중치를 하나 이상 설정해 주세요.".into());}
  let cuts=v["cuts"].as_array().filter(|a|a.len()==4).ok_or("티어 경계를 확인해 주세요.")?;
  for(i,x)in cuts.iter().enumerate(){c.cuts[i]=x.as_u64().filter(|x|*x<=100).ok_or("티어 경계 범위가 올바르지 않습니다.")? as u32;}
  if !c.cuts.windows(2).all(|w|w[0]<w[1]){return Err("티어 경계는 S < A < B < C 순서여야 합니다.".into());}
  c.level=v["level"].as_f64().filter(|x|x.is_finite()&&(1.0..=12.0).contains(x)).ok_or("기준 레벨을 확인해 주세요.")? as f32;
  c.overall=v["overall"].as_bool().ok_or("분류 기준을 확인해 주세요.")?;
  c.live_weight=v["live_weight"].as_f64().filter(|x|x.is_finite()&&(0.0..=1.0).contains(x)).ok_or("실전 반영 비율을 확인해 주세요.")? as f32;
  c.win_share=match v.get("win_share"){Some(x)=>x.as_f64().ok_or("승률 비중 형식을 확인해 주세요.")?,None=>0.65}as f32;c.bayes_k=match v.get("bayes_k"){Some(x)=>x.as_f64().ok_or("승률 보정 형식을 확인해 주세요.")?,None=>20.0}as f32;
  c.all_competitions=match v.get("all_competitions"){Some(x)=>x.as_bool().ok_or("대회 범위 형식을 확인해 주세요.")?,None=>false};
  if !c.win_share.is_finite()||!(0.0..=1.0).contains(&c.win_share)||!c.bayes_k.is_finite()||!(0.0..=1000.0).contains(&c.bayes_k){return Err("승률 비중·보정값을 확인해 주세요.".into());}Ok(c)
 }
}
fn cut_tier(p:f32,cuts:[u32;4])->char{for(i,c)in cuts.into_iter().enumerate(){if p<(c as f32/100.0){return ['S','A','B','C'][i];}}'D'}
fn score_tiers(champions:&[Champion],c:&Config,scores:Vec<f32>)->Vec<(String,char)>{if c.cuts==[15,35,65,85]{return assign(champions,&scores,c.overall);}let mut result=Vec::new();if c.overall{for(ch,p)in champions.iter().zip(crate::tier_math::percentile(&scores)){result.push((ch.name.clone(),cut_tier(1.0-p,c.cuts)));}}else{for category in 0..5{let mut ids:Vec<_>=champions.iter().enumerate().filter(|(_,ch)|ch.category==category).map(|(i,_)|i).collect();ids.sort_by(|a,b|scores[*b].total_cmp(&scores[*a]));for(rank,id)in ids.iter().enumerate(){result.push((champions[*id].name.clone(),cut_tier((rank as f32+0.5)/ids.len()as f32,c.cuts)));}}}result}
fn classify(champions:&[Champion],c:&Config,live:Option<&Snapshot>)->Result<Vec<(String,char)>,String>{
 let base=stat_scores(champions,c.level,c.weights);let scores=if c.live_weight>0.0{live.ok_or("실전 자료가 없습니다. 기본 능력치 0% 모드로 전환해 주세요.")?.blend(champions,&base,c.live_weight,c.win_share,c.bayes_k)}else{base};Ok(score_tiers(champions,c,scores))
}
fn names(champions:&[Champion])->std::collections::BTreeSet<String>{champions.iter().map(|c|c.name.clone()).collect()}
fn client_live(ctx:&StableClient<'_>,champions:&[Champion],c:&Config)->Result<Snapshot,String>{tier_live::collect(c.all_competitions,&names(champions),|k|ctx.record_ids(k),|k,id,path|ctx.record_get_json(k,id,path).and_then(|s|serde_json::from_str(&s).ok()))}
fn server_live(ctx:&StableServerCtx<'_>,champions:&[Champion],c:&Config)->Result<Snapshot,String>{tier_live::collect(c.all_competitions,&names(champions),|k|ctx.record_ids(k),|k,id,path|ctx.record_get_json(k,id,path).and_then(|s|serde_json::from_str(&s).ok()))}
fn payload_champions(v:&Value)->Result<Vec<Champion>,String>{
 let rows=v.as_array().filter(|v|!v.is_empty()&&v.len()<=2000).ok_or("챔피언 목록을 확인할 수 없습니다.")?;let mut names=std::collections::BTreeSet::new();let mut r=Vec::new();
 for v in rows{let name=v["name"].as_str().filter(|s|!s.is_empty()&&s.len()<=128).ok_or("챔피언 ID가 올바르지 않습니다.")?;
  if !names.insert(name){return Err("중복된 챔피언 ID입니다.".into());}
  let category=v["category"].as_u64().filter(|n|*n<5).ok_or("챔피언 역할을 확인할 수 없습니다.")? as usize;
  let mut base=[0.0;6];let mut growth=[0.0;6];for(key,out)in[("base",&mut base),("growth",&mut growth)]{let a=v[key].as_array().filter(|a|a.len()==6).ok_or("능력치 형식이 올바르지 않습니다.")?;for(i,x)in a.iter().enumerate(){out[i]=x.as_f64().filter(|n|n.is_finite()&&(0.0..=1e9).contains(n)).ok_or("능력치 범위가 올바르지 않습니다.")? as f32;}}
  let speed=v["speed"].as_f64().filter(|n|n.is_finite()&&(0.0..=1e9).contains(n)).ok_or("공격 속도를 확인할 수 없습니다.")? as f32;
  let range=v["range"].as_f64().filter(|n|n.is_finite()&&(0.0..=1e9).contains(n)).ok_or("공격 사거리를 확인할 수 없습니다.")? as f32;
  r.push(Champion{name:name.into(),category,base,growth,speed,range});
 }Ok(r)
}
fn read_champions(ctx:&StableClient<'_>,config:&Config)->Result<(Vec<Champion>,Value),String>{
 let actions:Value=serde_json::from_str(include_str!("champion-actions.json")).map_err(|_|"기본 공격 정보를 읽을 수 없습니다.")?;
 let mut rows=Vec::new();for name in ctx.champion_names(){let Some(b)=ctx.champion_brief(&name)else{return Err(format!("{name}: 능력치를 읽을 수 없습니다."));};let category=b.category.ok_or("챔피언 역할을 읽을 수 없습니다.")?.code();
  let cooldown=actions[&name]["cooltime"].as_f64();let range=actions[&name]["range"].as_f64();
  if (config.weights[5]>0.0||config.weights[6]>0.0)&&(cooldown.is_none()||range.is_none()){return Err(format!("{name}: 이 챔피언의 공격 속도·사거리 자료가 없습니다. 해당 가중치를 0으로 설정해 주세요."));}
  let base=b.stat;let growth=b.growth;rows.push(json!({"name":name,"category":category,"base":[base.attack,base.magic_power,base.hp,base.defence,base.magic_resistance,base.move_speed],"growth":[growth.attack,growth.magic_power,growth.hp,growth.defence,growth.magic_resistance,growth.move_speed],"speed":cooldown.filter(|c|*c>0.0).map(|c|60.0/c).unwrap_or(0.0),"range":range.unwrap_or(0.0)}));
 }let value=json!(rows);Ok((payload_champions(&value)?,value))
}
pub fn apply(ctx:&mut StableServerCtx<'_>,command:&StableCommand<'_>)->Result<String,String>{
 let team=command.sender_team_id.or_else(||command.sender_player_id.and_then(|p|ctx.player_team_id(p))).ok_or("플레이어 팀이 없습니다.")?;
 if let Some(p)=command.sender_player_id{if ctx.player_team_id(p)!=Some(team){return Err("현재 소속 팀을 확인할 수 없습니다.".into());}}
 let v:Value=serde_json::from_slice(command.payload).map_err(|_|"티어 요청 형식이 올바르지 않습니다.")?;let config=Config::parse(&v["config"])?;let champions=payload_champions(&v["champions"])?;let live=if config.live_weight>0.0{Some(server_live(ctx,&champions,&config)?)}else{None};let assignments=classify(&champions,&config,live.as_ref())?;
 let mut root:Value=serde_json::from_str(&ctx.team_get_json(team,"").ok_or("팀 데이터를 읽을 수 없습니다.")?).map_err(|_|"팀 데이터 형식이 올바르지 않습니다.")?;
 let map=root.get_mut("champion_tiers").and_then(Value::as_object_mut).ok_or("팀 티어 분류 형식을 읽을 수 없습니다.")?;
 for(name,tier)in &assignments{map.insert(name.clone(),json!(tier.to_string()));}
 if !ctx.team_set_json(team,"",&root.to_string()){return Err("게임이 티어 적용을 거절했습니다.".into());}
 Ok(format!("{}명 티어 적용 · 현재 팀만 변경 · 실전 {:.0}%{}",assignments.len(),config.live_weight*100.0,live.as_ref().map(|s|format!(" · {}",s.label())).unwrap_or_default()))
}
#[derive(Default)]struct State{open:bool,dirty:bool,pending:bool,execute:bool,config:Config,status:String,elapsed:u64,live:Option<Result<Snapshot,String>>}
pub struct TierClient{state:Arc<Mutex<State>>}
impl Default for TierClient{fn default()->Self{Self{state:Arc::new(Mutex::new(State::default()))}}}
fn label(id:&str,x:f32,y:f32,w:f32,text:&str)->String{format!("#{id}:label {{ @\"asset/base/style/main#label\"; x:{x}px; y:{y}px; width:{w}px; height:38px; size:17; align_y:Center; ignore_event:true; text:{}; }}",quoted(text))}
fn click(ctx:&mut StableClient<'_>,path:&str,state:Arc<Mutex<State>>,f:impl Fn(&mut State)+Send+Sync+'static){ctx.ui_register_click(path,"",move |_|{if let Ok(mut s)=state.lock(){if !s.pending{f(&mut s);s.dirty=true;}}});}
impl TierClient{
 pub fn result(&self,msg:&str){if let Ok(mut s)=self.state.lock(){s.status=msg.into();s.pending=false;s.dirty=true;}}
 pub fn update(&self,ctx:&mut StableClient<'_>,dt:u64){let Ok(mut s)=self.state.lock()else{return;};
  if s.execute{s.execute=false;match read_champions(ctx,&s.config){Ok((_,champions))=>{let payload=json!({"config":s.config.value(),"champions":champions});if !ctx.send_command("mgmt_tier",payload.to_string().as_bytes()){s.pending=false;s.status="요청을 전달하지 못했습니다.".into();}},Err(e)=>{s.status=e;s.pending=false;}}s.dirty=true;}
  if !ctx.ui_exists(ROOT)||ctx.ui_visible(ROOT)==Some(false){s.open=false;return;}
  let open=format!("{ROOT}.mgmt_tier_open");if !ctx.ui_exists(&open){let src=button("mgmt_tier_open",1020.0,0.0,300.0,"사용자 티어 분류").replace("y:0px;","anchor_y:1; pivot_y:1; y:-4px;");if ctx.ui_spawn_source(ROOT,&src[1..]){click(ctx,&open,self.state.clone(),|s|{s.open=true;s.status.clear();s.live=None;});}}
  s.elapsed=s.elapsed.saturating_add(dt);if s.elapsed>=1_000_000{s.elapsed=0;if s.open{s.dirty=true;}}
  if !s.dirty{return;}s.dirty=false;if ctx.ui_exists(PANEL){ctx.ui_remove_node(PANEL);}if !s.open{return;}
  let champion_data=read_champions(ctx,&s.config);
  if s.live.is_none(){if let Ok((ch,_))=&champion_data{s.live=Some(client_live(ctx,ch,&s.config));}}
  let preview=champion_data.and_then(|(ch,_)|classify(&ch,&s.config,s.live.as_ref().and_then(|r|r.as_ref().ok())));let summary=match &preview{Ok(a)=>format!("{}명 · S {} / A {} / B {} / C {} / D {}",a.len(),a.iter().filter(|(_,t)|*t=='S').count(),a.iter().filter(|(_,t)|*t=='A').count(),a.iter().filter(|(_,t)|*t=='B').count(),a.iter().filter(|(_,t)|*t=='C').count(),a.iter().filter(|(_,t)|*t=='D').count()),Err(e)=>e.clone()};
  let mut src=String::from("mgmt_tier_panel:color { x:120px; y:64px; width:1160px; height:960px; z:1900; color:#161721ff;");
  src+=&label("title",24.0,16.0,1000.0,"사용자 티어 분류 — 능력치·실전 통계");src+=&label("note",24.0,60.0,1100.0,"현재 팀의 S~D 분류만 명시적으로 바꿉니다. 실전 모드는 부분 자료 재구성이며 기기 미검증입니다.");
  for(i,name)in["피해량 (공격력·주문력 중 높은 순위)","체력","방어력","마법 저항력","이동 속도","공격 속도","공격 사거리"].iter().enumerate(){let y=120.0+i as f32*56.0;src+=&label(&format!("w{i}"),24.0,y,350.0,name);src+=&button(&format!("wd{i}"),380.0,y,60.0,"−");src+=&label(&format!("wv{i}"),450.0,y,86.0,&format!("{:.0}%",s.config.weights[i]*100.0));src+=&button(&format!("wu{i}"),540.0,y,60.0,"+");}
  for(i,name)in["S 상위","A 상위","B 상위","C 상위"].iter().enumerate(){let y=120.0+i as f32*56.0;src+=&label(&format!("c{i}"),650.0,y,130.0,name);src+=&button(&format!("cd{i}"),790.0,y,60.0,"−");src+=&label(&format!("cv{i}"),865.0,y,90.0,&format!("{}%",s.config.cuts[i]));src+=&button(&format!("cu{i}"),970.0,y,60.0,"+");}
  src+=&button("method",650.0,360.0,380.0,if s.config.overall{"분류 기준: 전체"}else{"분류 기준: 역할별"});src+=&label("level",650.0,420.0,380.0,&format!("기준 레벨: {:.1}",s.config.level));src+=&button("ld",650.0,468.0,170.0,"레벨 −0.5");src+=&button("lu",850.0,468.0,180.0,"레벨 +0.5");
  let live_ok=s.live.as_ref().is_some_and(|r|r.is_ok());
  src+=&button("refresh",24.0,530.0,230.0,"실전 자료 새로 읽기");src+=&button("scope",275.0,530.0,410.0,if s.config.all_competitions{"범위: 종료 대회 포함"}else{"범위: 진행 대회"});
  src+=&button("live_zero",710.0,530.0,390.0,&format!("실전 {:.0}% → 능력치 0%로",s.config.live_weight*100.0));
  if live_ok{src+=&button("live35",24.0,584.0,230.0,"원본 비율 35%");src+=&button("live_down",275.0,584.0,185.0,"실전 −5%");src+=&button("live_up",480.0,584.0,185.0,"실전 +5%");
   src+=&label("live_values",24.0,638.0,1080.0,&format!("승률 비중 {:.0}% / 밴 비중 {:.0}% · 승률 보정 K {:.0}",s.config.win_share*100.0,(1.0-s.config.win_share)*100.0,s.config.bayes_k));
   for(id,x,t)in[("share_down",24.0,"승률 −5%"),("share_up",260.0,"승률 +5%"),("k_down",496.0,"K −5"),("k_up",732.0,"K +5")]{src+=&button(id,x,688.0,215.0,t);}
  }
  let live_note=s.live.as_ref().map(|r|match r{Ok(v)=>v.label(),Err(e)=>e.clone()}).unwrap_or_else(||"실전 자료 읽기 대기".into());
  src+=&label("coverage",24.0,740.0,1100.0,&live_note);src+=&label("preview",24.0,790.0,1100.0,&summary);src+=&label("status",24.0,838.0,1100.0,&s.status);src+=&button("reset",24.0,900.0,250.0,"기본 설정 복원");src+=&button("close",300.0,900.0,220.0,"닫기");src+=&button("apply",760.0,900.0,360.0,if s.pending{"적용 결과 확인 중"}else{"현재 팀에 티어 적용"});src.push('}');if !ctx.ui_spawn_source(ROOT,&src){return;}
  click(ctx,&format!("{PANEL}.close"),self.state.clone(),|s|s.open=false);click(ctx,&format!("{PANEL}.reset"),self.state.clone(),|s|{s.config=Config::default();s.live=None;});click(ctx,&format!("{PANEL}.method"),self.state.clone(),|s|s.config.overall=!s.config.overall);
  click(ctx,&format!("{PANEL}.refresh"),self.state.clone(),|s|s.live=None);
  click(ctx,&format!("{PANEL}.scope"),self.state.clone(),|s|{s.config.all_competitions=!s.config.all_competitions;s.live=None;});
  click(ctx,&format!("{PANEL}.live_zero"),self.state.clone(),|s|s.config.live_weight=0.0);
  if live_ok{click(ctx,&format!("{PANEL}.live35"),self.state.clone(),|s|s.config.live_weight=0.35);click(ctx,&format!("{PANEL}.live_down"),self.state.clone(),|s|s.config.live_weight=(s.config.live_weight-0.05).max(0.0));click(ctx,&format!("{PANEL}.live_up"),self.state.clone(),|s|s.config.live_weight=(s.config.live_weight+0.05).min(1.0));click(ctx,&format!("{PANEL}.share_down"),self.state.clone(),|s|s.config.win_share=(s.config.win_share-0.05).max(0.0));click(ctx,&format!("{PANEL}.share_up"),self.state.clone(),|s|s.config.win_share=(s.config.win_share+0.05).min(1.0));click(ctx,&format!("{PANEL}.k_down"),self.state.clone(),|s|s.config.bayes_k=(s.config.bayes_k-5.0).max(0.0));click(ctx,&format!("{PANEL}.k_up"),self.state.clone(),|s|s.config.bayes_k=(s.config.bayes_k+5.0).min(1000.0));}
  click(ctx,&format!("{PANEL}.ld"),self.state.clone(),|s|s.config.level=(s.config.level-0.5).max(1.0));click(ctx,&format!("{PANEL}.lu"),self.state.clone(),|s|s.config.level=(s.config.level+0.5).min(12.0));
  for i in 0..7{click(ctx,&format!("{PANEL}.wd{i}"),self.state.clone(),move |s|s.config.weights[i]=(s.config.weights[i]-0.05).max(0.0));click(ctx,&format!("{PANEL}.wu{i}"),self.state.clone(),move |s|s.config.weights[i]=(s.config.weights[i]+0.05).min(2.0));}
  for i in 0..4{click(ctx,&format!("{PANEL}.cd{i}"),self.state.clone(),move |s|{let min=if i==0{0}else{s.config.cuts[i-1]+1};s.config.cuts[i]=s.config.cuts[i].saturating_sub(5).max(min);});click(ctx,&format!("{PANEL}.cu{i}"),self.state.clone(),move |s|{let max=if i==3{100}else{s.config.cuts[i+1]-1};s.config.cuts[i]=(s.config.cuts[i]+5).min(max);});}
  if preview.is_ok()&&!s.pending&&s.config.weights.iter().sum::<f32>()>0.0{click(ctx,&format!("{PANEL}.apply"),self.state.clone(),|s|{s.execute=true;s.pending=true;});}
 }
}
#[cfg(test)]mod tests{use super::*;#[test]fn config_accepts_live_but_rejects_out_of_range_and_bad_thresholds(){let mut v=Config::default().value();assert!(Config::parse(&v).is_ok());v["live_weight"]=json!(0.35);assert!(Config::parse(&v).is_ok());v["live_weight"]=json!(1.1);assert!(Config::parse(&v).is_err());v["live_weight"]=json!(0);v["cuts"]=json!([35,15,65,85]);assert!(Config::parse(&v).is_err());}#[test]fn configurable_thresholds_change_tiers(){let c=|name:&str,a|Champion{name:name.into(),category:0,base:[a,0.0,0.0,0.0,0.0,0.0],growth:[0.0;6],speed:0.0,range:0.0};let ch=[c("a",10.0),c("b",5.0)];let mut cfg=Config::default();cfg.weights=[1.0,0.0,0.0,0.0,0.0,0.0,0.0];cfg.cuts=[30,40,60,90];let a=classify(&ch,&cfg,None).unwrap();assert_eq!(a[0],("a".into(),'S'));assert_eq!(a[1],("b".into(),'C'));}}

#[cfg(test)]mod host_live_tests{
 use super::*;use crate::tier_live::tests::{fixtures,Records};use mod_api_stable::{ServerCtxV1,ServerVtableV1};use std::ffi::c_void;
 struct Host{records:Records,team:Value,writes:usize,reject:bool}
 unsafe fn output(data:&str,out:*mut u8,cap:usize,len:*mut usize)->bool{*len=data.len();if !out.is_null(){std::ptr::copy_nonoverlapping(data.as_ptr(),out,cap.min(data.len()));}true}
 unsafe extern "C" fn ids(s:*const c_void,kind:u32,out:*mut usize,cap:usize)->usize{let h=&*(s as *const Host);let ids:Vec<_>=h.records.keys().filter(|(k,_,p)|*k==kind&&p.is_empty()).map(|(_,id,_)|*id).collect();if !out.is_null(){for(i,id)in ids.iter().take(cap).enumerate(){*out.add(i)=*id;}}ids.len()}
 unsafe extern "C" fn read(s:*const c_void,kind:u32,id:usize,p:*const u8,n:usize,out:*mut u8,cap:usize,len:*mut usize)->bool{let h=&*(s as *const Host);let path=std::str::from_utf8(std::slice::from_raw_parts(p,n)).unwrap();let Some(v)=h.records.get(&(kind,id,path.into()))else{return false;};output(&v.to_string(),out,cap,len)}
 unsafe extern "C" fn team_get(s:*const c_void,id:usize,_p:*const u8,n:usize,out:*mut u8,cap:usize,len:*mut usize)->bool{let h=&*(s as *const Host);if id!=7||n!=0{return false;}output(&h.team.to_string(),out,cap,len)}
 unsafe extern "C" fn team_set(s:*mut c_void,id:usize,_p:*const u8,n:usize,b:*const u8,l:usize)->bool{let h=&mut*(s as *mut Host);assert_eq!(id,7);assert_eq!(n,0);if h.reject{return false;}h.team=serde_json::from_slice(std::slice::from_raw_parts(b,l)).unwrap();h.writes+=1;true}
 fn run(h:&mut Host,weight:f32)->Result<String,String>{run_with(h,weight,&["a".into(),"b".into(),"c".into(),"d".into()])}
 fn run_with(h:&mut Host,weight:f32,names:&[String])->Result<String,String>{let mut t:ServerVtableV1=unsafe{std::mem::zeroed()};t.size=std::mem::size_of::<ServerVtableV1>();t.record_ids=Some(ids);t.record_get_json=Some(read);t.team_get_json=Some(team_get);t.team_set_json=Some(team_set);let mut raw=ServerCtxV1{size:std::mem::size_of::<ServerCtxV1>(),vtable:&t,state:(h as *mut Host).cast()};let mut ctx=unsafe{StableServerCtx::from_raw(&mut raw)}.unwrap();let mut cfg=Config::default();cfg.overall=true;cfg.live_weight=weight;let champions:Vec<_>=names.iter().map(|n|json!({"name":n,"category":0,"base":[1,1,1,1,1,1],"growth":[0,0,0,0,0,0],"speed":1,"range":1})).collect();let data=json!({"config":cfg.value(),"champions":champions,"live":{"a":{"wins":0},"b":{"wins":999999}}}).to_string();apply(&mut ctx,&StableCommand{command:"mgmt_tier",payload:data.as_bytes(),sender_player_id:None,sender_team_id:Some(7)})}
 fn host()->Host{Host{records:fixtures(),team:json!({"champion_tiers":{"unlisted":"C"},"total_balance":123,"merchandise_products":[],"name":"keep"}),writes:0,reject:false}}
 #[test]fn original35_uses_authoritative_records_and_changes_tiers_only(){let mut h=host();let before=h.team.clone();let msg=run(&mut h,0.35).unwrap();assert!(msg.contains("실전 35%"));assert!(msg.contains("부분 자료"));assert_eq!(h.writes,1);assert_eq!(h.team["champion_tiers"]["a"],"S");assert_eq!(h.team["champion_tiers"]["b"],"D");assert_eq!(h.team["champion_tiers"]["unlisted"],"C");for k in ["name","total_balance","merchandise_products"]{assert_eq!(h.team[k],before[k]);}}
 #[test]fn missing_live_and_host_refusal_preserve_save_stat_only_still_works(){let mut h=host();h.records.remove(&(15,501,"red_ban".into()));let before=h.team.clone();assert!(run(&mut h,0.35).is_err());assert_eq!(h.writes,0);assert_eq!(h.team,before);assert!(run(&mut h,0.0).is_ok());assert_eq!(h.writes,1);for n in ["a","b","c","d"]{assert_eq!(h.team["champion_tiers"][n],"B");}let mut h=host();h.reject=true;let before=h.team.clone();assert!(run(&mut h,0.35).is_err());assert_eq!(h.writes,0);assert_eq!(h.team,before);}
 #[test]#[ignore="requires private original-reader backup corpus"]fn private_backup_original_reader_corpus(){
  let path=std::env::var("TFM_MANAGEMENT_LIVE_CORPUS").expect("private corpus path");let mut records=Records::new();let mut counts=std::collections::BTreeMap::new();
  for line in std::fs::read_to_string(path).unwrap().lines(){let v:Value=serde_json::from_str(line).unwrap();let kind=v["kind"].as_u64().unwrap()as u32;let id=v["id"].as_u64().unwrap()as usize;*counts.entry(kind).or_insert(0usize)+=1;let root=v["value"].clone();records.insert((kind,id,"".into()),root.clone());for field in match kind{14=>vec!["replays"],15=>vec!["blue_ban","red_ban"],_=>vec![]}{records.insert((kind,id,field.into()),root[field].clone());}}
  let actions:Value=serde_json::from_str(include_str!("champion-actions.json")).unwrap();let names:Vec<_>=actions.as_object().unwrap().keys().cloned().collect();let known=names.iter().cloned().collect();let snapshot=tier_live::collect(false,&known,|k|records.keys().filter(|(kind,_,p)|*kind==k.code()&&p.is_empty()).map(|(_,i,_)|*i).collect(),|k,i,p|records.get(&(k.code(),i,p.into())).cloned()).unwrap();
  println!("private original-reader records {:?}; {}",counts,snapshot.label());assert!(snapshot.competitions>0&&snapshot.replays>0&&snapshot.bans>0);
  let mut h=host();h.records=records;let before=h.team.clone();let msg=run_with(&mut h,0.35,&names).unwrap();assert!(msg.contains("실전 35%"));assert_eq!(h.writes,1);assert_eq!(h.team["champion_tiers"].as_object().unwrap().len(),names.len()+1);for k in ["total_balance","merchandise_products","name"]{assert_eq!(h.team[k],before[k]);}assert!(h.team["champion_tiers"].as_object().unwrap().values().any(|v|v=="S"));
 }
 #[test]fn malformed_mutable_live_settings_are_rejected(){for(k,v)in[("win_share",json!(2)),("bayes_k",json!(-1)),("all_competitions",json!("all")),("win_share",Value::Null)]{let mut c=Config::default().value();c[k]=v;assert!(Config::parse(&c).is_err());}}
}
