//! Two read-only axes from the actual native ChampionInfo UI labels.
//! These compare the displayed precision, not unrounded internal action values.
//! Source SHA3bbc9632...; banpick0x101db435c/4370 and0x101db5a58..5dc0.
//! Shared speed formatting0x100079938; management corroboration0x1018a100c.
use mod_api_stable::StableClient;
#[derive(Clone,Debug)]
pub struct Extra{pub base:[f64;2],pub current:[f64;2]}
fn numeric(s:&str)->Option<f64>{
    let s=s.trim();let s=s.strip_prefix('+').unwrap_or(s);
    if s.is_empty()||s.len()>24||!s.bytes().all(|c|c.is_ascii_digit()||c==b'.'){return None;}
    let n=s.parse::<f64>().ok()?;(n.is_finite()&&n>=0.0&&n<1_000_000.0).then_some(n)
}
fn labels(speed:[&str;3],range:[&str;3])->Option<[f64;2]>{
    let s=[numeric(speed[0])?,numeric(speed[1])?,numeric(speed[2])?];
    let r=[numeric(range[0])?,numeric(range[1])?,numeric(range[2])?];
    // Native UI has constant basic attack speed with literal0 growth. Range
    // writes floor(base/1000), floor(growth/1000), floor((base+11growth)/1000).
    // Reject rounded/nonlinear endpoints that cannot support this projection.
    if s[0]<=0.0||s[0]!=s[2]||s[1]!=0.0||r[0]<=0.0||r.iter().any(|x|x.fract()!=0.0)||r[2]!=r[0]+11.0*r[1]{return None;}
    Some([s[0],r[0]+5.5*r[1]])
}
include!("extra_baseline.rs");
pub fn read(ctx:&StableClient<'_>,id:&str)->Option<Extra>{
    let b=baseline(id)?;
    let values=|field:&str|->Option<[String;3]>{Some([
        ctx.ui_text(&format!("main.champion_info.stat.stats.{field}.values.lv1"))?,
        ctx.ui_text(&format!("main.champion_info.stat.stats.{field}.values.lvup"))?,
        ctx.ui_text(&format!("main.champion_info.stat.stats.{field}.values.lvmax"))?,
    ])};
    let s=values("attack_speed")?;let r=values("range")?;
    let current=labels([&s[0],&s[1],&s[2]],[&r[0],&r[1],&r[2]])?;
    // Native f64 formatter explicitly uses precision2; compare the baseline
    // at that same displayed precision so unchanged sheets show no false delta.
    let speed=format!("{:.2}",60.0/b[0]).parse().ok()?;
    Some(Extra{base:[speed,b[1]+5.5*b[2]],current})
}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn native_ui_text_abi_selects_eight_only_when_both_axes_are_present(){
        use mod_api_stable::{UiVtableV1,ClientCtxV1};
        use std::{collections::BTreeMap,ffi::c_void};
        unsafe extern "C" fn text(state:*const c_void,path:*const u8,n:usize,out:*mut u8,cap:usize,len:*mut usize)->bool{
            let data=&*(state as *const BTreeMap<String,String>);
            let Ok(path)=std::str::from_utf8(std::slice::from_raw_parts(path,n)) else {return false};
            let Some(value)=data.get(path) else {return false};*len=value.len();
            if !out.is_null(){if cap<value.len(){return false;}std::ptr::copy_nonoverlapping(value.as_ptr(),out,value.len());}true
        }
        let mut values=BTreeMap::<String,String>::new();
        for (field,row) in [("attack_speed",["1.00","0","1.00"]),("range",["60","3","93"]) ]{
            for (part,value) in ["lv1","lvup","lvmax"].into_iter().zip(row){values.insert(format!("main.champion_info.stat.stats.{field}.values.{part}"),value.into());}
        }
        let mut ui:UiVtableV1=unsafe{std::mem::zeroed()};ui.size=std::mem::size_of::<UiVtableV1>();ui.get_text=Some(text);
        let mut raw:ClientCtxV1=unsafe{std::mem::zeroed()};raw.size=std::mem::size_of::<ClientCtxV1>();raw.ui=&ui;raw.state=&mut values as *mut _ as *mut c_void;
        let ctx=unsafe{StableClient::from_raw(&mut raw)}.unwrap();
        assert_eq!(read(&ctx,"soldier").unwrap().current,[1.0,76.5]);
        values.remove("main.champion_info.stat.stats.range.values.lvmax");
        assert!(read(&ctx,"soldier").is_none());
    }
    #[test]fn soldier_growth_is_projected_at_six_and_a_half(){
        assert_eq!(baseline("soldier"),Some([60.0,60.0,3.0]));
        assert_eq!(labels(["1.00","0","1.00"],["60","3","93"]),Some([1.0,76.5]));
        assert_eq!(labels(["1.00","0","1.00"],["60","+3","93"]),Some([1.0,76.5]));
    }
    #[test]fn missing_unknown_or_incoherent_values_fall_back(){
        assert!(baseline("spirit_caller").is_none());assert!(baseline("custom").is_none());
        assert!(labels(["—","0","1"],["60","0","60"]).is_none());
        assert!(labels(["0","0","0"],["0","0","0"]).is_none());
        assert!(labels(["1","0","1.1"],["60","0","60"]).is_none());
        assert!(labels(["1","0","1"],["60","3","94"]).is_none());
        for bad in ["NaN","inf","1,23","1.00/s","-1","1%"]{assert!(numeric(bad).is_none());}
    }
    #[test]fn native_precision_does_not_invent_an_unchanged_speed_buff(){
        let b=baseline("fighter").unwrap();let displayed=format!("{:.2}",60.0/b[0]);
        assert_eq!(displayed,"0.86");assert_eq!(labels([&displayed,"0",&displayed],["23","0","23"]).unwrap()[0],0.86);
    }
}
