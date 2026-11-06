use super::*;
use mod_api_stable::{ClientCtxV1,DataVtableV1,ServerCtxV1,ServerVtableV1};
use std::{collections::BTreeMap,ffi::c_void};

#[test]
fn real_contract_variants_exclude_free_agents_offers_and_malformed_ownership(){
 assert_eq!(contract_team_id(&json!({"InContract":{"team_id":0}})),Some(0));
 assert_eq!(contract_team_id(&json!({"InContract":{"team_id":9}})),Some(9));
 for v in [json!({"FreeAgent":{"requests":[{"team_id":0}]}}),json!({"team_id":0}),json!({"InContract":{"team_id":-1}}),json!({"InContract":{"team_id":"0"}}),json!({"InContract":{"team_id":0},"FreeAgent":{}}),Value::Null]{assert_eq!(contract_team_id(&v),None);}
}

struct Host{contracts:BTreeMap<usize,Value>,team:Value,writes:usize}
unsafe fn output(data:&str,out:*mut u8,cap:usize,len:*mut usize)->bool{*len=data.len();if !out.is_null(){std::ptr::copy_nonoverlapping(data.as_ptr(),out,cap.min(data.len()));}true}
unsafe extern "C" fn player_team(_: *const c_void,out:*mut usize)->bool{*out=0;true}
unsafe extern "C" fn athletes(s:*const c_void,out:*mut usize,cap:usize)->usize{let h=&*(s as *const Host);if !out.is_null(){for(i,id)in h.contracts.keys().take(cap).enumerate(){*out.add(i)=*id;}}h.contracts.len()}
unsafe extern "C" fn ids(s:*const c_void,kind:u32,out:*mut usize,cap:usize)->usize{if kind==1{athletes(s,out,cap)}else{0}}
unsafe extern "C" fn contract(s:*const c_void,id:usize,path:*const u8,n:usize,out:*mut u8,cap:usize,len:*mut usize)->bool{let h=&*(s as *const Host);if std::slice::from_raw_parts(path,n)!=b"contract"{return false;}let Some(v)=h.contracts.get(&id)else{return false;};output(&v.to_string(),out,cap,len)}
unsafe extern "C" fn record(s:*const c_void,kind:u32,id:usize,path:*const u8,n:usize,out:*mut u8,cap:usize,len:*mut usize)->bool{kind==1&&contract(s,id,path,n,out,cap,len)}
unsafe extern "C" fn team_get(s:*const c_void,id:usize,_p:*const u8,n:usize,out:*mut u8,cap:usize,len:*mut usize)->bool{let h=&*(s as *const Host);if id!=0||n!=0{return false;}output(&h.team.to_string(),out,cap,len)}
unsafe extern "C" fn team_set(s:*mut c_void,id:usize,_p:*const u8,n:usize,b:*const u8,len:usize)->bool{let h=&mut*(s as *mut Host);assert_eq!((id,n),(0,0));h.team=serde_json::from_slice(std::slice::from_raw_parts(b,len)).unwrap();h.writes+=1;true}

#[test]
#[ignore="requires private original-reader athlete contract corpus"]
fn private_backup_team0_client_and_server_have_eleven_eligible_athletes(){
 let path=std::env::var("TFM_MANAGEMENT_CONTRACT_CORPUS").expect("private contract corpus required");let mut contracts=BTreeMap::new();
 for line in std::fs::read_to_string(path).unwrap().lines(){let row:Value=serde_json::from_str(line).unwrap();assert_eq!(row["kind"],1);contracts.insert(row["id"].as_u64().unwrap()as usize,row["value"].clone());}
 assert_eq!(contracts.len(),2102);assert_eq!(contracts.values().filter(|v|v.get("FreeAgent").is_some()).count(),421);
 let mut h=Host{contracts,team:json!({"total_balance":1_000_000_000_000u64,"merchandise_products":[],"name":"preserve","champion_tiers":{"keep":"A"}}),writes:0};
 let mut table:DataVtableV1=unsafe{std::mem::zeroed()};table.size=std::mem::size_of::<DataVtableV1>();table.player_team_id=Some(player_team);table.athlete_ids=Some(athletes);table.record_get_json=Some(record);
 let mut raw:ClientCtxV1=unsafe{std::mem::zeroed()};raw.size=std::mem::size_of::<ClientCtxV1>();raw.data=&table;raw.state=(&mut h as *mut Host).cast();
 let client=unsafe{StableClient::from_raw(&mut raw)}.unwrap();let client_ids=client_athletes(&client);assert_eq!(client_ids.len(),11);
 let mut table:ServerVtableV1=unsafe{std::mem::zeroed()};table.size=std::mem::size_of::<ServerVtableV1>();table.record_ids=Some(ids);table.athlete_get_json=Some(contract);table.team_get_json=Some(team_get);table.team_set_json=Some(team_set);
 let mut raw=ServerCtxV1{size:std::mem::size_of::<ServerCtxV1>(),vtable:&table,state:(&mut h as *mut Host).cast()};let mut server=unsafe{StableServerCtx::from_raw(&mut raw)}.unwrap();
 let server_ids=eligible_athletes(0,server.record_ids(Kind::Athlete),|id|server.athlete_get_json(id,"contract"));assert_eq!(server_ids,client_ids);
 let before=h.team.clone();let payload=json!({"mode":"new","count":100,"discount":0,"date":"2026-01-01","nonce":"actual-contracts"}).to_string();let command=StableCommand{command:"mgmt_restock",payload:payload.as_bytes(),sender_player_id:None,sender_team_id:Some(0)};
 let result=Server::default().apply(&mut server,&command).unwrap();assert!(result.contains("110종류"));assert_eq!(h.writes,1);
 let products=h.team["merchandise_products"].as_array().unwrap();assert_eq!(products.len(),110);let product_athletes:BTreeSet<_>=products.iter().map(|v|v["athlete_id"].as_u64().unwrap()as usize).collect();assert_eq!(product_athletes,client_ids.iter().copied().collect());
 assert_eq!(h.team["name"],before["name"]);assert_eq!(h.team["champion_tiers"],before["champion_tiers"]);
 println!("original-reader contracts: 2102 athletes / 1681 InContract / 421 FreeAgent; actual team0 client=11 server=11; isolated new-product command=110 products / one atomic mock-host write; no save written");
}
