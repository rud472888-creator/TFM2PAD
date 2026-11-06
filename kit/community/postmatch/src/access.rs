//! Context-only access. No global management overlay or per-frame record scan.
use crate::{button_caption,render,State};
use mod_api_stable::{StableClient,ClientSceneKindV1 as Scene};
use std::sync::{Arc,Mutex};
const CHAT:&str="main.top.right.messenger.background";
const NEWS:&str="main.top.right.news";
fn spawn(ctx:&mut StableClient<'_>,parent:&str,id:&str,x:f32,y:f32,width:f32,state:Arc<Mutex<State>>){
    let path=format!("{parent}.{id}");
    if ctx.ui_exists(&path){return;}
    let src=format!("{id}:color_icon_button {{ @\"asset/base/style/main#tertiary_button\"; z:1500; x:{x}px; y:{y}px; width:{width}px; height:44px; {} }}",button_caption("경기 후 평가"));
    if ctx.ui_spawn_source(parent,&src){ctx.ui_register_click(&path,"",move|c|render(c,state.clone()));}
}
pub fn reachable(ctx:&StableClient<'_>)->bool{
    match ctx.client_scene_kind(){
        Some(Scene::Main|Scene::MatchResult)=>true,
        Some(_)=>false,
        None=>ctx.ui_exists("main.top.right"),
    }
}
fn footer(news:(f32,f32,f32,f32),contents:(f32,f32,f32,f32),scroll:(f32,f32,f32,f32))->Option<(f32,f32)>{
    let (nx,ny,nw,nh)=news;let (x,y,w,h)=contents;
    let (sx,sy,sw,sh)=scroll;
    if [nx,ny,nw,nh,x,y,w,h,sx,sy,sw,sh].iter().any(|v|!v.is_finite())||w<224.0||h<52.0{return None;}
    let bx=x+w-212.0;let by=y+h-48.0;
    (sx>=x-1.0&&sx+sw<=x+w+1.0&&sy>=y-1.0&&sy+sh+4.0<=by&&bx>=nx&&by>=ny&&bx+200.0<=nx+nw&&by+44.0<=ny+nh).then_some((bx-nx,by-ny))
}
pub fn update(ctx:&mut StableClient<'_>,state:Arc<Mutex<State>>){
    if ctx.ui_exists(CHAT)&&!ctx.ui_exists(&format!("{CHAT}.pm_ipad_chat_button")){
        // Each shipped variant reserves a different header and bottom inset.
        if let Some((_,_,w,h))=ctx.ui_node_rect(CHAT){
            let (button_y, bottom_inset) = if w == 560.0 { (96.0, 8.0) } else { (72.0, 10.0) };
            let list_y = button_y + 52.0;
            if w>=230.0&&h>=200.0&&ctx.ui_exists(&format!("{CHAT}.list"))&&ctx.ui_set_properties(&format!("{CHAT}.list"),&format!("y:{list_y}px; height:{}px;",h-list_y-bottom_inset)){
                spawn(ctx,CHAT,"pm_ipad_chat_button",12.0,button_y,200.0,state.clone());
            }
        }
    }
    if ctx.client_scene_kind()==Some(Scene::MatchResult){
        if let Some((_,_,w,h))=ctx.ui_node_rect("main.header"){
            if w>=620.0&&h>=68.0 {spawn(ctx,"main.header","pm_ipad_result_button",20.0,20.0,180.0,state.clone());}
        }
    }
    let news_button=format!("{NEWS}.pm_ipad_news_button");
    let room=ctx.ui_node_rect(NEWS).and_then(|nr|{
        let contents=format!("{NEWS}.contents");let cr=ctx.ui_node_rect(&contents)?;
        for child in ctx.ui_child_names(&contents).into_iter().take(8){
            let report=format!("{contents}.{child}");
            // This is the actual match_report_content asset shape, not a
            // guessed article/footer. Other news content never gets an overlay.
            if ctx.ui_exists(&format!("{report}.scroll.contents.score_header")){
                if let Some(sr)=ctx.ui_node_rect(&format!("{report}.scroll")){
                    if let Some(p)=footer(nr,cr,sr){return Some(p);}
                }
            }
        }
        None
    });
    if let Some((x,y))=room{spawn(ctx,NEWS,"pm_ipad_news_button",x,y,200.0,state);}
    else if ctx.ui_exists(&news_button){ctx.ui_remove_node(&news_button);}
}
#[cfg(test)]mod tests{
    use super::*;
    #[test]fn news_access_requires_real_free_footer_inside_its_viewport(){
        assert_eq!(footer((32.0,24.0,1600.0,1328.0),(534.0,24.0,1098.0,1328.0),(548.0,100.0,1080.0,1190.0)),Some((1388.0,1280.0)));
        assert!(footer((0.0,0.0,1600.0,1328.0),(502.0,0.0,1098.0,1328.0),(516.0,76.0,1080.0,1230.0)).is_none());
        assert!(footer((0.0,0.0,1600.0,968.0),(502.0,0.0,1098.0,1328.0),(516.0,76.0,1080.0,830.0)).is_none());
    }
}
