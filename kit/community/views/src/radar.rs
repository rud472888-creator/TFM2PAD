//! Six public fields plus two conditional native UI display axes.
//! Missing/incoherent attack labels or unknown baselines retain six axes.
use crate::{
    button,
    json::{parse, Json},
    label, log, register_action, State,
};
use mod_api_stable::{StableClient, StatV1, TextAlignXV1 as X, TextAlignYV1 as Y};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
const LABELS: [&str; 8] = ["공격력", "주문력", "체력", "방어력", "마법저항", "이동속도", "공격속도", "사거리"];
#[derive(Clone, Debug)]
struct Comparison {
    base: [f64; 6],
    current: [f64; 6],
    name: String,
    extra:Option<crate::extra_radar::Extra>,
}
#[derive(Default)]
pub struct Radar {
    pub visible: bool,
    pub colors: bool,
    baseline: BTreeMap<String, [f64; 6]>,
    current: Option<Comparison>,
    names: Vec<(String, String, u32)>,
    aliases: BTreeMap<String, String>,
}
fn line(ctx: &mut StableClient<'_>, a: (f32, f32), b: (f32, f32), width: f32, z: i32, color: u32) {
    ctx.draw_line("UI", a.0, a.1, b.0, b.1, width, z, color);
}
fn array(j: &Json) -> Option<[f64; 6]> {
    let Json::Array(values) = j else {
        return None;
    };
    if values.len() != 6 {
        return None;
    }
    let mut out = [0.0; 6];
    for (i, v) in values.iter().enumerate() {
        out[i] = v.number()?;
    }
    Some(out)
}
fn at_level(stat: StatV1, growth: StatV1) -> [f64; 6] {
    let a = [
        stat.attack,
        stat.magic_power,
        stat.hp,
        stat.defence,
        stat.magic_resistance,
        stat.move_speed,
    ];
    let b = [
        growth.attack,
        growth.magic_power,
        growth.hp,
        growth.defence,
        growth.magic_resistance,
        growth.move_speed,
    ];
    std::array::from_fn(|i| a[i] as f64 + b[i] as f64 * 5.5)
}
fn change_color(base: &[f64], current: &[f64]) -> u32 {
    let positive = (0..base.len()).any(|i| current[i] > base[i] + 0.0001);
    let negative = (0..base.len()).any(|i| current[i] < base[i] - 0.0001);
    match (positive, negative) {
        (true, false) => 0x57db78ff,
        (false, true) => 0xf7666bff,
        (true, true) => 0xf2c14eff,
        _ => 0xe8e8e8ff,
    }
}
impl Radar {
    pub fn new() -> Self {
        let mut baseline = BTreeMap::new();
        if let Some(root) = parse(include_str!("base-champions.json")) {
            if let Some(champions) = root.get("champions").and_then(Json::object) {
                for (id, value) in champions {
                    let Some(a) = value.get("stat").and_then(array) else {
                        continue;
                    };
                    let Some(b) = value.get("growth").and_then(array) else {
                        continue;
                    };
                    baseline.insert(id.clone(), std::array::from_fn(|i| a[i] + b[i] * 5.5));
                }
            }
        }
        log(&format!(
            "radar-baseline champions={} axes=6 reference-level=6.5",
            baseline.len()
        ));
        Self {
            baseline,
            colors: true,
            ..Self::default()
        }
    }
    pub fn update(&mut self, ctx: &mut StableClient<'_>, state: Arc<Mutex<State>>) {
        if !ctx.ui_exists("main.champions.contents") || !ctx.ui_exists("main.champion_info") {
            self.current = None;
            self.names.clear();
            self.aliases.clear();
            return;
        }
        if self.aliases.is_empty() {
            self.aliases = crate::art::Art::localized_ids(ctx, self.baseline.keys());
        }
        if !ctx.ui_exists("main.champion_info.vp_radar_toggle") {
            let src = button("vp_radar_toggle", 0.0, -44.0, 150.0, "능력치 변화")
                .replace("x: 0px;", "anchor_x:1; pivot_x:1; x:0px;");
            if ctx.ui_spawn_source("main.champion_info", src.trim_start_matches('#')) {
                register_action(
                    ctx,
                    "main.champion_info.vp_radar_toggle",
                    state.clone(),
                    |s| {
                        s.radar.visible = !s.radar.visible;
                    },
                );
            }
        }
        if !ctx.ui_exists("main.champion_info.vp_radar") {
            let mut src=String::from("vp_radar:color { visible:false; anchor_x:1; pivot_x:1; x:0px; y:-314px; width:360px; height:260px; z:850; color:#161721f5; rounding:Uniform { rounding:12; }");
            src += &button("close", 306.0, 5.0, 46.0, "닫기");
            src += &label(
                "title",
                12.0,
                7.0,
                290.0,
                30.0,
                "Lv6.5 · 공개 스탯 6개 변화",
                16,
                "#e8e8e8ff",
            );
            src += &label(
                "note",
                12.0,
                229.0,
                335.0,
                24.0,
                "기준 회색 / 현재 색 · 사거리·공속 제외",
                12,
                "#a8a8b3ff",
            );
            src.push('}');
            if ctx.ui_spawn_source("main.champion_info", &src) {
                register_action(
                    ctx,
                    "main.champion_info.vp_radar.close",
                    state.clone(),
                    |s| {
                        s.radar.visible = false;
                    },
                );
            }
        }
        let inside=ctx.ui_node_rect("main").zip(ctx.ui_node_rect("main.champion_info.vp_radar")).is_some_and(|((vx,vy,vw,vh),(x,y,w,h))|{
            [vx,vy,vw,vh,x,y,w,h].iter().all(|v|v.is_finite())&&x>=vx&&y>=vy&&x+w<=vx+vw&&y+h<=vy+vh&&w>=360.0&&h>=260.0
        });
        ctx.ui_set_visible("main.champion_info.vp_radar", self.visible&&inside);
        // Actual asset nesting is stat.name; support the legacy companion
        // layout only when that independently visible path exists.
        let hover = ["main.champion_info.stat.name", "main.champion_info.name"]
            .iter()
            .filter_map(|path| ctx.ui_text(path))
            .find(|name| !name.is_empty());
        self.current = hover.and_then(|name| {
            let id = self.aliases.get(&name)?.clone();
            let brief = ctx.champion_brief(&id)?;
            Some(Comparison {
                base: *self.baseline.get(&id)?,
                current: at_level(brief.stat, brief.growth),
                extra:crate::extra_radar::read(ctx,&id),
                name,
            })
        });
        let axes=if self.current.as_ref().is_some_and(|c|c.extra.is_some()){8}else{6};
        let title=format!("Lv6.5 · {axes}축 변화");
        let note=if axes==8{"공속·사거리: 정보창 표시값 기준"}else{"기준 회색 / 현재 색 · 사거리·공속 제외"};
        for (path,text) in [("title",title.as_str()),("note",note)]{
            let path=format!("main.champion_info.vp_radar.{path}");
            if ctx.ui_text(&path).as_deref()!=Some(text){ctx.ui_set_text(&path,text);}
        }
        self.names.clear();
        for child in ctx.ui_child_names("main.champions.contents") {
            let row = format!("main.champions.contents.{child}");
            if ctx.ui_visible(&format!("{row}.ban")) == Some(true) {
                continue;
            }
            let path = format!("{row}.name");
            let Some(name) = ctx.ui_text(&path) else {
                continue;
            };
            let Some(id) = self.aliases.get(&name).cloned() else {
                continue;
            };
            let Some(brief) = ctx.champion_brief(&id) else {
                continue;
            };
            let Some(base) = self.baseline.get(&id) else {
                continue;
            };
            let color = change_color(base, &at_level(brief.stat, brief.growth));
            if color != 0xe8e8e8ff {
                self.names.push((path, name, color));
            }
        }
    }
    pub fn render(&self, ctx: &mut StableClient<'_>) {
        if !ctx.ui_exists("main.champions.contents") {
            return;
        }
        if self.colors {
            for (path, name, color) in &self.names {
                if ctx.ui_text(path).as_deref() != Some(name) {
                    continue;
                }
                let Some((x, y, w, h)) = ctx.ui_node_rect(path) else {
                    continue;
                };
                let Some((gx, gy, gw, gh)) = ctx.ui_node_rect("main.champions") else {
                    continue;
                };
                if x < gx - 1.0 || y < gy - 1.0 || x + w > gx + gw + 1.0 || y + h > gy + gh + 1.0 {
                    continue;
                }

                let row = path.strip_suffix(".name").unwrap_or(path);
                if ctx.ui_visible(&format!("{row}.ban")) == Some(true) {
                    continue;
                }
                ctx.draw_text(
                    "UI",
                    name,
                    "asset/base/font/set/regular",
                    (x, y, w, h),
                    349,
                    14.0,
                    *color,
                    X::Center,
                    Y::Center,
                );
            }
        }
        if !self.visible {
            return;
        }
        let Some((x, y, w, h)) = ctx.ui_node_rect("main.champion_info.vp_radar") else {
            return;
        };
        // Never draw beyond the actual UI viewport, including shortened
        // or unknown layouts. The260px panel fits both6 and8 labels.
        let Some((vx,vy,vw,vh))=ctx.ui_node_rect("main") else {return};
        if [x,y,w,h,vx,vy,vw,vh].iter().any(|v|!v.is_finite())||x<vx||y<vy||x+w>vx+vw||y+h>vy+vh||w<360.0||h<260.0{return;}
        let Some(current) = &self.current else {
            ctx.draw_text(
                "UI",
                "챔피언을 가리키거나 선택해 주세요.",
                "asset/base/font/set/regular",
                (x + 12.0, y + 70.0, w - 24.0, 100.0),
                870,
                16.0,
                0xa8a8b3ff,
                X::Center,
                Y::Center,
            );
            return;
        };
        let mut base=current.base.to_vec();let mut values=current.current.to_vec();
        if let Some(extra)=&current.extra{base.extend(extra.base);values.extend(extra.current);}
        let axes=base.len();
        let center = (x + w / 2.0, y + 147.0);
        let radius = 52.0;
        let points:Vec<(f32,f32)>=(0..axes).map(|i|{
            let a=i as f32*std::f32::consts::TAU/axes as f32-std::f32::consts::FRAC_PI_2;
            (a.cos(),a.sin())
        }).collect();
        let to_point = |i: usize, r: f32| (center.0 + points[i].0 * r, center.1 + points[i].1 * r);
        let tone = change_color(&base,&values);
        for i in 0..axes {
            let end = to_point(i, radius);
            line(ctx, center, end, 1.0, 870, 0x4a4c56ff);
            let next = (i + 1) % axes;
            line(
                ctx,
                to_point(i, radius * 0.6),
                to_point(next, radius * 0.6),
                1.0,
                871,
                0x858d9dff,
            );
            let ratio = |j: usize| {
                if base[j] > 0.0 {
                    (values[j] / base[j]).clamp(0.0, 1.65)
                } else if values[j] > 0.0 {
                    1.65
                } else {
                    1.0
                }
            };
            line(
                ctx,
                to_point(i, radius * 0.6 * ratio(i) as f32),
                to_point(next, radius * 0.6 * ratio(next) as f32),
                2.0,
                872,
                tone,
            );
            let p=(center.0+points[i].0*105.0,center.1+points[i].1*70.0);
            let delta = values[i] - base[i];
            let change = if base[i] > 0.0 {
                format!("{:+.1}%", delta / base[i] * 100.0)
            } else {
                format!("{delta:+.0}")
            };
            ctx.draw_text(
                "UI",
                &format!("{} {}", LABELS[i], change),
                "asset/base/font/set/regular",
                (p.0 - 60.0, p.1 - 12.0, 120.0, 24.0),
                873,
                11.0,
                0xe8e8e8ff,
                X::Center,
                Y::Center,
            );
        }
        ctx.draw_text(
            "UI",
            &current.name,
            "asset/base/font/set/bold",
            (x + 65.0, y + 38.0, w - 130.0, 24.0),
            874,
            15.0,
            tone,
            X::Center,
            Y::Center,
        );
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]fn six_and_eight_axis_labels_stay_inside_the260px_panel(){
        for axes in [6,8]{for i in 0..axes{
            let a=i as f32*std::f32::consts::TAU/axes as f32-std::f32::consts::FRAC_PI_2;
            let (x,y)=(180.0+a.cos()*105.0,147.0+a.sin()*70.0);
            assert!(x-60.0>=0.0&&x+60.0<=360.0);
            assert!(y-12.0>=65.0&&y+12.0<=229.0);
        }}
    }
    #[test]
    fn tradeoffs_are_not_claimed_as_a_pure_buff_or_nerf() {
        let b = [10.0; 6];
        assert_eq!(change_color(&b, &[11.0; 6]), 0x57db78ff);
        assert_eq!(change_color(&b, &[9.0; 6]), 0xf7666bff);
        assert_eq!(
            change_color(&b, &[11.0, 9.0, 10.0, 10.0, 10.0, 10.0]),
            0xf2c14eff
        );
        assert_eq!(change_color(&b, &b), 0xe8e8e8ff);
    }
    #[test]
    fn pinned_baseline_covers_all_72_shipped_champions() {
        assert_eq!(Radar::new().baseline.len(), 72);
    }
}
