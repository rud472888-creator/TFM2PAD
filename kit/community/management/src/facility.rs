use serde_json::{Value,json};
// Generated privately from the purchaser's hash-verified base-game settings.
// scripts/facility_inputs.py preserves the product_type order; no data table
// is distributed with the source crate. The public mods builder stages it.
include!("facility_products.rs");
#[derive(Debug,Clone)]pub struct Plan {pub team:Value,pub changed:usize,pub total:u64,pub stopped:bool}
pub fn restock(root:&Value,count:u64,discount:f64,date:&str)->Result<Plan,String>{
 if !(100..=100_000).contains(&count)||!discount.is_finite()||!(0.0..=1.0).contains(&discount){return Err("수량 또는 할인율을 확인해 주세요.".into());}
 if date.is_empty(){return Err("게임 날짜를 읽을 수 없습니다.".into());}
 let mut team=root.clone();let balance=root.get("total_balance").and_then(Value::as_f64).filter(|v|v.is_finite()&&*v<=9_007_199_254_740_991.0).ok_or("팀 잔액 형식을 확인할 수 없습니다.")?;
 if balance<0.0{return Err("팀 잔액이 부족합니다.".into());}
 let products=team.get_mut("merchandise_products").and_then(Value::as_array_mut).ok_or("상품 목록을 읽을 수 없습니다.")?;
 let mut remaining=balance;let mut changed=0;let mut stopped=false;
 for p in products {
  let typ=p.get("product_type").and_then(Value::as_u64).ok_or("상품 종류 형식을 확인할 수 없습니다.")? as usize;
  let Some((_,unit,_,_))=PRODUCT.get(typ) else {continue;};
  let stock=p.get("stock").and_then(Value::as_u64).ok_or("상품 재고 형식을 확인할 수 없습니다.")?;
  let unit=(*unit as f64*(1.0-discount)).round() as u64;
  let cost=unit.checked_mul(count).ok_or("생산 비용이 너무 큽니다.")?;
  if cost as f64>remaining{stopped=true;break;}
  let stock=stock.checked_add(count).ok_or("재고가 너무 큽니다.")?;
  if !p.is_object(){return Err("상품 형식이 올바르지 않습니다.".into());}
  p["stock"]=json!(stock);p["last_produced_date"]=json!(date);remaining-=cost as f64;changed+=1;
 }
 if changed==0{return Err("추가 생산할 상품이 없거나 잔액이 부족합니다.".into());}
 team["total_balance"]=if root["total_balance"].is_i64(){json!(remaining as i64)}else{json!(remaining)};
 Ok(Plan{team,changed,total:(balance-remaining) as u64,stopped})
}
#[cfg(test)]mod tests{
 use super::*;
 fn team()->Value{json!({"total_balance":30_000_000,"name":"preserve","merchandise_products":[{"product_type":0,"stock":3,"last_produced_date":"2026-01-01","sell_price":20000},{"product_type":1,"stock":8,"last_produced_date":"2026-01-01"}]})}
 #[test]fn restock_preserves_other_fields(){let a=team();let p=restock(&a,1000,0.1,"2026-02-01").unwrap();assert_eq!(p.total,20_700_000);assert_eq!(p.changed,2);assert!(!p.stopped);assert_eq!(p.team["total_balance"],9_300_000);assert_eq!(p.team["merchandise_products"][0]["stock"],1003);assert_eq!(p.team["merchandise_products"][0]["sell_price"],20000);assert_eq!(p.team["name"],"preserve");assert_eq!(a["merchandise_products"][0]["stock"],3);}
 #[test]fn insufficient_funds_stops_in_original_order(){let mut a=team();a["total_balance"]=json!(10_000_000);let p=restock(&a,1000,0.0,"2026-02-01").unwrap();assert_eq!(p.changed,1);assert!(p.stopped);assert_eq!(p.total,8_000_000);assert_eq!(p.team["merchandise_products"][1]["stock"],8);}
 #[test]fn malformed_or_excessive_inputs_refused(){let a=team();for d in [f64::NAN,-0.1,1.1]{assert!(restock(&a,1000,d,"2026-01-01").is_err());}assert!(restock(&a,99,0.0,"x").is_err());assert!(restock(&a,100001,0.0,"x").is_err());let mut b=a.clone();b["merchandise_products"][1]["stock"]=json!(-1);assert!(restock(&b,1000,0.0,"x").is_err());assert_eq!(b["merchandise_products"][0]["stock"],3);}
}

/// Develop only missing (athlete_id,product_type) pairs. The caller supplies
/// authoritative current-team athlete ids, never arbitrary client ids.
pub fn develop(root:&Value,count:u64,discount:f64,date:&str,athletes:&[usize])->Result<Plan,String>{
 if !(100..=100_000).contains(&count)||!discount.is_finite()||!(0.0..=1.0).contains(&discount)||date.is_empty(){return Err("수량·할인율·날짜를 확인해 주세요.".into());}
 let mut team=root.clone();let balance=root.get("total_balance").and_then(Value::as_f64).filter(|v|v.is_finite()&&(0.0..=9_007_199_254_740_991.0).contains(v)).ok_or("팀 잔액을 읽을 수 없습니다.")?;
 let products=team.get_mut("merchandise_products").and_then(Value::as_array_mut).ok_or("상품 목록을 읽을 수 없습니다.")?;
 let mut existing=std::collections::BTreeSet::new();let mut demand=[None::<u64>;10];
 for p in products.iter(){
  let kind=p["product_type"].as_u64().ok_or("상품 종류를 확인할 수 없습니다.")? as usize;
  if let Some(id)=p["athlete_id"].as_u64(){existing.insert((id as usize,kind));}
  if kind<10&&demand[kind].is_none(){demand[kind]=Some(p["anchor_purchase_rate"].as_u64().unwrap_or(0));}
 }
 let mut remaining=balance;let mut changed=0;let mut stopped=false;
 'outer:for &athlete in athletes{
  for (kind,(development,base,markup,rate)) in PRODUCT.into_iter().enumerate(){
   if existing.contains(&(athlete,kind)){continue;}
   let unit=(base as f64*(1.0-discount)).round() as u64;
   let cost=development+unit*count;if cost as f64>remaining{stopped=true;break 'outer;}
   let sell=unit+unit*markup/100;let demand=demand[kind].unwrap_or((rate*20/100).max(1));
   let p=json!({"product_type":kind,"stock":count,"sell_price":sell,"yearly_sales":0,"yearly_revenue":0,"total_sales":0,"total_revenue":0,"daily_purchase_rate":demand,"last_produced_date":date,"last_sold_date":null,"base_player_daily_purchase_rate":20,"athlete_id":athlete,"base_team_daily_purchase_rate":1,"price_elasticity_x100":200,"daily_sales_remainder":0,"anchor_sell_price":sell,"anchor_purchase_rate":demand});
   products.push(p);existing.insert((athlete,kind));changed+=1;remaining-=cost as f64;
  }
 }
 if changed==0{return Err("새로 제작할 상품이 없거나 잔액이 부족합니다.".into());}
 team["total_balance"]=if root["total_balance"].is_i64(){json!(remaining as i64)}else{json!(remaining)};
 Ok(Plan{team,changed,total:(balance-remaining) as u64,stopped})
}
#[cfg(test)]mod development_tests{
 use super::*;
 #[test]fn missing_products_are_unique_and_source_fields_match(){let root=json!({"name":"keep","total_balance":1_000_000_000,"merchandise_products":[{"athlete_id":11,"product_type":0,"stock":9,"daily_purchase_rate":999,"anchor_purchase_rate":42}]});let p=develop(&root,100,0.0,"2026-02-01",&[11,11]).unwrap();assert_eq!(p.changed,9);assert_eq!(p.team["merchandise_products"].as_array().unwrap().len(),10);assert_eq!(p.team["merchandise_products"][0]["stock"],9);let first=&p.team["merchandise_products"][1];assert_eq!(first["product_type"],1);assert_eq!(first["sell_price"],34500);assert_eq!(first["daily_purchase_rate"],8);assert_eq!(first["price_elasticity_x100"],200);assert_eq!(first["last_sold_date"],Value::Null);assert_eq!(p.team["name"],"keep");let second=develop(&root,100,0.0,"2026-02-01",&[12]).unwrap();assert_eq!(second.team["merchandise_products"][1]["daily_purchase_rate"],42);}
 #[test]fn development_charges_setup_plus_discounted_units_and_stops(){let root=json!({"total_balance":10_000_000,"merchandise_products":[]});let p=develop(&root,100,0.5,"2026-02-01",&[3]).unwrap();assert_eq!(p.changed,1);assert!(p.stopped);assert_eq!(p.total,9_400_000);assert_eq!(p.team["merchandise_products"][0]["sell_price"],10000);assert_eq!(root["merchandise_products"],json!([]));}
}
