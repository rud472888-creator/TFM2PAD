//! Native stable SDK management actions. No writes occur during load/ticks.
mod facility;
mod tier;
mod tier_math;
mod tier_live;
#[cfg(test)]mod contract_tests;
use mod_api_stable::{declare_stable_mod,StableHost,StableMod,StableExtension,StableClient,StableServerExtension,StableServerCtx,StableCommand,CommandResultV1,RecordKindV1 as Kind,LogLevel};
use serde_json::{Value,json};
use std::sync::{Arc,Mutex};
use std::collections::BTreeSet;
const ID:&str="tfm2_management_ios";
const ROOT:&str="main.top.right.facility";
const PANEL:&str="main.top.right.facility.mgmt_panel";
const RESULT:&str="mgmt_result";
#[derive(Default)]struct State{open:bool,dirty:bool,count:usize,discount:u32,execute:bool,status:String,elapsed:u64,pending:bool,develop:bool}
struct Client{state:Arc<Mutex<State>>,tier:tier::TierClient}
#[derive(Default)]struct Server{done:Mutex<BTreeSet<String>>}
fn init(host:&StableHost)->StableMod{
 host.log(LogLevel::Info,"Native management 0.3: merchandise + tiers with gated partial live reconstruction; explicit apply only");
 let mut m=StableMod::new(ID);m.set_extension(Client{state:Arc::new(Mutex::new(State{count:1000,..State::default()})),tier:tier::TierClient::default()});m.set_server_extension(Server::default());m
}
declare_stable_mod!(init,requires=10);
fn quoted(s:&str)->String{serde_json::to_string(s).unwrap_or_else(|_|"\"\"".into())}
fn label(id:&str,y:f32,text:&str)->String{format!("#{id}:label {{ @\"asset/base/style/main#label\"; x:24px; y:{y}px; width:1050px; height:44px; size:17; align_y:Center; ignore_event:true; text:{}; }}",quoted(text))}
fn button(id:&str,x:f32,y:f32,w:f32,text:&str)->String{format!("#{id}:color_icon_button {{ @\"asset/base/style/main#secondary_button\"; x:{x}px; y:{y}px; width:{w}px; height:44px; text:{{ text:{}; size:17; align_x:Center; align_y:Center; }} }}",quoted(text))}
fn click(ctx:&mut StableClient<'_>,path:&str,state:Arc<Mutex<State>>,f:impl Fn(&mut State)+Send+Sync+'static){ctx.ui_register_click(path,"",move |_|{if let Ok(mut s)=state.lock(){f(&mut s);s.dirty=true;}});}
fn date(ctx:&StableClient<'_>)->Option<String>{let(y,m,d)=ctx.game_date()?;Some(format!("{y:04}-{m:02}-{d:02}"))}
fn snapshot(ctx:&StableClient<'_>)->Option<Value>{serde_json::from_str(&ctx.record_get_json(Kind::Team,ctx.player_team_id()?,"")?).ok()}
// The game serializes Contract as an externally tagged enum. FreeAgent
// contains requests, not an owning team; never infer ownership from offers.
fn contract_team_id(contract:&Value)->Option<usize>{
 let variants=contract.as_object()?;if variants.len()!=1{return None;}
 usize::try_from(variants.get("InContract")?["team_id"].as_u64()?).ok()
}
fn eligible_athletes(team:usize,ids:impl IntoIterator<Item=usize>,mut contract:impl FnMut(usize)->Option<String>)->Vec<usize>{
 ids.into_iter().filter(|&id|contract(id).and_then(|s|serde_json::from_str::<Value>(&s).ok()).and_then(|v|contract_team_id(&v))==Some(team)).collect()
}
fn client_athletes(ctx:&StableClient<'_>)->Vec<usize>{let Some(team)=ctx.player_team_id()else{return vec![];};eligible_athletes(team,ctx.athlete_ids(),|id|ctx.record_get_json(Kind::Athlete,id,"contract"))}
fn render(ctx:&mut StableClient<'_>,state:Arc<Mutex<State>>,s:&State){
 if ctx.ui_exists(PANEL){ctx.ui_remove_node(PANEL);}
 if !s.open{return;}
 let preview=snapshot(ctx).ok_or("팀 데이터를 읽을 수 없습니다.".to_owned()).and_then(|v|if s.develop{facility::develop(&v,s.count as u64,s.discount as f64/100.0,&date(ctx).unwrap_or_default(),&client_athletes(ctx))}else{facility::restock(&v,s.count as u64,s.discount as f64/100.0,&date(ctx).unwrap_or_default())});
 let detail=match &preview{Ok(p)=>format!("{}종류 생산 · 비용 {} · {}",p.changed,p.total,if p.stopped{"잔액 범위까지만 적용"}else{"전체 상품 적용"}),Err(e)=>e.clone()};
 let mut src=String::from("mgmt_panel:color { x:160px; y:120px; width:1120px; height:590px; z:1800; color:#161721ff;");
 src+=&label("title",16.0,if s.develop{"미등록 선수 상품 일괄 제작"}else{"상품 일괄 추가 생산"});src+=&button("mode",740.0,16.0,340.0,if s.develop{"기존 상품 추가 생산으로"}else{"신규 상품 제작으로"});src+=&label("scope",66.0,if s.develop{"현재 소속 선수의 미등록 상품을 제작합니다. 상품별 개발비와 생산비가 포함됩니다."}else{"현재 판매 중인 상품마다 지정 수량을 추가합니다. 기존 가격·판매 이력은 유지합니다."});
 src+=&label("discount",122.0,&format!("시설 할인율: {}% — 기본 화면에 표시된 생산 할인율에 맞춰 주세요.",s.discount));
 src+=&button("discount_down",24.0,174.0,190.0,"할인율 −5%");src+=&button("discount_up",234.0,174.0,190.0,"할인율 +5%");
 src+=&label("quantity",234.0,&format!("상품별 추가 수량: {}개",s.count));
 for(i,(n,t))in[(100,"100개"),(1000,"1,000개"),(5000,"5,000개")].iter().enumerate(){src+=&button(&format!("qty{i}"),24.0+i as f32*210.0,288.0,190.0,t);let _=n;}
 src+=&label("preview",350.0,&detail);src+=&label("status",408.0,&s.status);
 src+=&button("close",24.0,500.0,260.0,"닫기");src+=&button("execute",740.0,500.0,340.0,if s.pending{"적용 결과 확인 중"}else{"표시된 비용으로 추가 생산"});src.push('}');
 if !ctx.ui_spawn_source(ROOT,&src){return;}
 click(ctx,&format!("{PANEL}.close"),state.clone(),|s|s.open=false);click(ctx,&format!("{PANEL}.mode"),state.clone(),|s|{if !s.pending{s.develop=!s.develop;}});
 click(ctx,&format!("{PANEL}.discount_down"),state.clone(),|s|{if !s.pending{s.discount=s.discount.saturating_sub(5);}});
 click(ctx,&format!("{PANEL}.discount_up"),state.clone(),|s|{if !s.pending{s.discount=(s.discount+5).min(100);}});
 for(i,n)in[100,1000,5000].into_iter().enumerate(){click(ctx,&format!("{PANEL}.qty{i}"),state.clone(),move |s|{if !s.pending{s.count=n;}});}
 if preview.is_ok()&&!s.pending{click(ctx,&format!("{PANEL}.execute"),state,|s|{if !s.pending{s.execute=true;s.pending=true;}});}
}
impl StableExtension for Client{
 fn post_update(&self,ctx:&mut StableClient<'_>,dt:u64){
  self.tier.update(ctx,dt);
  let Ok(mut s)=self.state.lock()else{return;};
  for e in ctx.take_events(){if e.event=="mgmt_tier_result"{if let Ok(msg)=std::str::from_utf8(&e.payload){self.tier.result(msg);}}else if e.event==RESULT{if let Ok(msg)=std::str::from_utf8(&e.payload){s.status=msg.into();s.pending=false;s.dirty=true;}}}
  s.elapsed=s.elapsed.saturating_add(dt);
  if s.execute{s.execute=false;let nonce=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d|d.as_nanos().to_string()).unwrap_or_default();
   let payload=json!({"mode":if s.develop{"new"}else{"add"},"count":s.count,"discount":s.discount as f64/100.0,"date":date(ctx),"nonce":nonce});
   if ctx.send_command("mgmt_restock",payload.to_string().as_bytes()){s.status="서버에서 재고와 잔액을 확인하고 있습니다.".into();}else{s.status="생산 요청을 전달하지 못했습니다.".into();s.pending=false;}
   s.dirty=true;
  }
  if !ctx.ui_exists(ROOT)||ctx.ui_visible(ROOT)==Some(false){s.open=false;return;}
  let path=format!("{ROOT}.mgmt_open");
  if !ctx.ui_exists(&path){let src=button("mgmt_open",980.0,0.0,250.0,"상품 일괄 추가 생산").replace("y:0px;","anchor_y:1; pivot_y:1; y:-4px;");if ctx.ui_spawn_source(ROOT,&src[1..]){click(ctx,&path,self.state.clone(),|s|{s.open=true;s.status.clear();});}}
  if s.elapsed>=500_000{s.elapsed=0;if s.open{s.dirty=true;}}
  if s.dirty{s.dirty=false;render(ctx,self.state.clone(),&s);}
 }
}
fn date_valid(s:&str)->bool{let b=s.as_bytes();b.len()==10&&b[4]==b'-'&&b[7]==b'-'&&b.iter().enumerate().all(|(i,c)|i==4||i==7||c.is_ascii_digit())&&s[5..7].parse::<u32>().is_ok_and(|n|(1..=12).contains(&n))&&s[8..].parse::<u32>().is_ok_and(|n|(1..=31).contains(&n))}
impl Server{
 fn apply(&self,ctx:&mut StableServerCtx<'_>,command:&StableCommand<'_>)->Result<String,String>{
  let team=command.sender_team_id.or_else(||command.sender_player_id.and_then(|id|ctx.player_team_id(id))).ok_or("플레이어 팀이 없습니다.")?;
  if let Some(id)=command.sender_player_id{if ctx.player_team_id(id)!=Some(team){return Err("현재 팀을 확인할 수 없습니다.".into());}}
  let v:Value=serde_json::from_slice(command.payload).map_err(|_|"생산 요청 형식이 올바르지 않습니다.")?;
  let nonce=v["nonce"].as_str().filter(|n|!n.is_empty()&&n.len()<=64).ok_or("요청 번호가 없습니다.")?;
  let mut done=self.done.lock().map_err(|_|"생산 요청을 처리할 수 없습니다.")?;
  let key=format!("{team}:{nonce}");if done.contains(&key){return Ok("이미 처리한 생산 요청입니다.".into());}
  let count=v["count"].as_u64().ok_or("수량이 올바르지 않습니다.")?;let discount=v["discount"].as_f64().ok_or("할인율이 올바르지 않습니다.")?;
  let date=v["date"].as_str().filter(|d|date_valid(d)).ok_or("날짜를 확인할 수 없습니다.")?;
  let root:Value=serde_json::from_str(&ctx.team_get_json(team,"").ok_or("팀 데이터를 읽을 수 없습니다.")?).map_err(|_|"팀 데이터 형식이 올바르지 않습니다.")?;
  let p=match v["mode"].as_str().unwrap_or("add"){
   "add"=>facility::restock(&root,count,discount,date)?,
   "new"=>{let ids=eligible_athletes(team,ctx.record_ids(Kind::Athlete),|id|ctx.athlete_get_json(id,"contract"));facility::develop(&root,count,discount,date,&ids)?},
   _=>return Err("지원하지 않는 생산 요청입니다.".into())};
  if !ctx.team_set_json(team,"",&p.team.to_string()){return Err("게임이 변경 적용을 거절했습니다. 다시 요청하기 전에 현재 재고를 확인해 주세요.".into());}
  if done.len()>=4096{done.pop_first();}done.insert(key);
  let text=format!("{}종류에 {}개씩 추가 · 비용 {}{}",p.changed,count,p.total,if p.stopped{" · 잔액 한도로 중단"}else{""});
  ctx.news_push(team,"상품 추가 생산",&text,"시설 담당");Ok(text)
 }
}
impl StableServerExtension for Server{
 fn handle_command(&self,ctx:&mut StableServerCtx<'_>,command:&StableCommand<'_>)->CommandResultV1{
  if command.command=="mgmt_tier"{let msg=tier::apply(ctx,command).unwrap_or_else(|e|e);ctx.emit_event(command.reply_target(),"mgmt_tier_result",msg.as_bytes());return CommandResultV1::Handled;}
  if command.command!="mgmt_restock"{return CommandResultV1::Pass;}
  let result=self.apply(ctx,command).unwrap_or_else(|e|e);ctx.emit_event(command.reply_target(),RESULT,result.as_bytes());CommandResultV1::Handled
 }
}
#[cfg(test)]mod integration_tests{
 use super::*;use mod_api_stable::{ServerCtxV1,ServerVtableV1};use std::ffi::c_void;
 struct Host{root:String,writes:usize,reject:bool}
 unsafe extern "C" fn get(s:*const c_void,id:usize,_p:*const u8,n:usize,out:*mut u8,cap:usize,len:*mut usize)->bool{let h=&*(s as *const Host);if id!=7||n!=0{return false;}*len=h.root.len();if !out.is_null(){std::ptr::copy_nonoverlapping(h.root.as_ptr(),out,cap.min(h.root.len()));}true}
 unsafe extern "C" fn set(s:*mut c_void,id:usize,_p:*const u8,n:usize,b:*const u8,l:usize)->bool{let h=&mut*(s as *mut Host);assert_eq!(id,7);assert_eq!(n,0);if h.reject{return false;}h.root=String::from_utf8(std::slice::from_raw_parts(b,l).to_vec()).unwrap();h.writes+=1;true}
 fn setup()->(Host,ServerVtableV1){let h=Host{root:json!({"name":"keep","total_balance":20_000_000,"merchandise_products":[{"product_type":0,"stock":7,"last_produced_date":"2026-01-01"}]}).to_string(),writes:0,reject:false};let mut table:ServerVtableV1=unsafe{std::mem::zeroed()};table.size=std::mem::size_of::<ServerVtableV1>();table.team_get_json=Some(get);table.team_set_json=Some(set);(h,table)}
 #[test]fn no_startup_mutation_command_commits_once_and_replay_is_idempotent(){let(mut h,t)=setup();let mut raw=ServerCtxV1{size:std::mem::size_of::<ServerCtxV1>(),vtable:&t,state:(&mut h as *mut Host).cast()};let mut ctx=unsafe{StableServerCtx::from_raw(&mut raw)}.unwrap();let server=Server::default();server.on_server_start(&mut ctx);server.before_management_tick(&mut ctx);server.after_management_tick(&mut ctx);assert_eq!(h.writes,0);let payload=json!({"count":1000,"discount":0.0,"date":"2026-02-01","nonce":"one"}).to_string();let command=StableCommand{command:"mgmt_restock",payload:payload.as_bytes(),sender_player_id:None,sender_team_id:Some(7)};assert!(server.apply(&mut ctx,&command).unwrap().contains("1종류"));assert_eq!(h.writes,1);assert!(server.apply(&mut ctx,&command).unwrap().contains("이미 처리"));assert_eq!(h.writes,1);let root:Value=serde_json::from_str(&h.root).unwrap();assert_eq!(root["merchandise_products"][0]["stock"],1007);assert_eq!(root["total_balance"],12_000_000);assert_eq!(root["name"],"keep");}
 #[test]fn host_refusal_and_missing_sender_do_not_write(){let(mut h,t)=setup();h.reject=true;let mut raw=ServerCtxV1{size:std::mem::size_of::<ServerCtxV1>(),vtable:&t,state:(&mut h as *mut Host).cast()};let mut ctx=unsafe{StableServerCtx::from_raw(&mut raw)}.unwrap();let server=Server::default();let bytes=json!({"count":1000,"discount":0.0,"date":"2026-02-01","nonce":"one"}).to_string();let mut command=StableCommand{command:"mgmt_restock",payload:bytes.as_bytes(),sender_player_id:None,sender_team_id:None};assert!(server.apply(&mut ctx,&command).is_err());command.sender_team_id=Some(7);assert!(server.apply(&mut ctx,&command).is_err());assert_eq!(h.writes,0);}

 unsafe extern "C" fn ids(_s:*const c_void,kind:u32,out:*mut usize,cap:usize)->usize{if kind!=1{return 0;}if !out.is_null(){for(i,v)in [11,12,13].into_iter().take(cap).enumerate(){*out.add(i)=v;}}3}
 unsafe extern "C" fn contract(_s:*const c_void,id:usize,_p:*const u8,n:usize,out:*mut u8,cap:usize,len:*mut usize)->bool{if n!=8{return false;}let data=if id==11{b"{\"InContract\":{\"team_id\":7}}".as_slice()}else if id==12{b"{\"InContract\":{\"team_id\":9}}".as_slice()}else{b"{\"FreeAgent\":{\"requests\":[{\"team_id\":7}]}}".as_slice()};*len=data.len();if !out.is_null(){std::ptr::copy_nonoverlapping(data.as_ptr(),out,cap.min(data.len()));}true}
 #[test]fn development_server_filters_current_team_and_charges_setup(){let(mut h,mut t)=setup();t.record_ids=Some(ids);t.athlete_get_json=Some(contract);let mut raw=ServerCtxV1{size:std::mem::size_of::<ServerCtxV1>(),vtable:&t,state:(&mut h as *mut Host).cast()};let mut ctx=unsafe{StableServerCtx::from_raw(&mut raw)}.unwrap();let server=Server::default();let bytes=json!({"mode":"new","count":100,"discount":0.0,"date":"2026-02-01","nonce":"new"}).to_string();let command=StableCommand{command:"mgmt_restock",payload:bytes.as_bytes(),sender_player_id:None,sender_team_id:Some(7)};assert!(server.apply(&mut ctx,&command).unwrap().contains("1종류"));let v:Value=serde_json::from_str(&h.root).unwrap();assert_eq!(h.writes,1);assert_eq!(v["merchandise_products"].as_array().unwrap().len(),2);assert_eq!(v["merchandise_products"][1]["athlete_id"],11);assert_eq!(v["total_balance"],10_200_000);}

 #[test]fn tier_commit_is_team_scoped_and_preserves_other_record_fields(){let(mut h,t)=setup();let mut root:Value=serde_json::from_str(&h.root).unwrap();root["champion_tiers"]=json!({"unlisted_mod_champion":"C"});h.root=root.to_string();let before:Value=serde_json::from_str(&h.root).unwrap();let mut raw=ServerCtxV1{size:std::mem::size_of::<ServerCtxV1>(),vtable:&t,state:(&mut h as *mut Host).cast()};let mut ctx=unsafe{StableServerCtx::from_raw(&mut raw)}.unwrap();let bytes=json!({"config":{"weights":[1,0,0,0,0,0,0],"cuts":[15,35,65,85],"level":6.5,"overall":false,"live_weight":0},"champions":[{"name":"strong","category":0,"base":[100,0,1,1,1,1],"growth":[0,0,0,0,0,0],"speed":1,"range":23000},{"name":"middle","category":0,"base":[50,0,1,1,1,1],"growth":[0,0,0,0,0,0],"speed":1,"range":23000},{"name":"weak","category":0,"base":[1,0,1,1,1,1],"growth":[0,0,0,0,0,0],"speed":1,"range":23000}]}).to_string();let command=StableCommand{command:"mgmt_tier",payload:bytes.as_bytes(),sender_player_id:None,sender_team_id:Some(7)};assert!(tier::apply(&mut ctx,&command).is_ok());let after:Value=serde_json::from_str(&h.root).unwrap();assert_eq!(h.writes,1);assert_eq!(after["champion_tiers"]["strong"],"A");assert_eq!(after["champion_tiers"]["unlisted_mod_champion"],"C");assert_eq!(after["total_balance"],before["total_balance"]);assert_eq!(after["merchandise_products"],before["merchandise_products"]);assert_eq!(after["name"],before["name"]);}
}
