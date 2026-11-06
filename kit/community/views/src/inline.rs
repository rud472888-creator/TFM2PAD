//! Read-only, noninteractive overlays on the actual native rows. Rendering
//! never replaces their IDs, event handlers, list order or layout geometry.
use crate::{
    button, color, log, parse, proficiency, proficiency_entries, register_action, stat, Row, State,
    View,
};
use mod_api_stable::{RecordKindV1 as Kind, StableClient, TextAlignXV1 as X, TextAlignYV1 as Y};
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};
#[derive(Default)]
pub struct Inline {
    pub roster: bool,
    pub recruitment: bool,
    pub rows: Vec<(View, String, Row)>,
    names: BTreeMap<(u32, String), Vec<usize>>,
    indexed: bool,
    elapsed: u64,
    last_counts: [usize; 3],
}
impl Inline {
    fn index(&mut self, ctx: &StableClient<'_>) {
        if self.indexed {
            return;
        }
        self.indexed = true;
        for kind in [Kind::Athlete, Kind::Staff] {
            for id in ctx.record_ids(kind) {
                let name = if kind == Kind::Athlete {
                    ctx.athlete_name(id)
                } else {
                    ctx.record_get_string(kind, id, "name")
                };
                if let Some(name) = name {
                    self.names.entry((kind.code(), name)).or_default().push(id);
                }
            }
        }
    }
    pub fn list(ctx: &StableClient<'_>, view: View) -> Option<(String, String)> {
        let root = view.root();
        if !ctx.ui_exists(root) || ctx.ui_visible(root) == Some(false) {
            return None;
        }
        if view == View::Recruitment {
            for tab in ["search_list", "interested", "released", "all_players"] {
                let section = format!("{root}.contents.{tab}");
                if ctx.ui_visible(&section) == Some(true)
                    && ctx.ui_exists(&format!("{section}.list.contents"))
                {
                    return Some((
                        format!("{section}.list.contents"),
                        format!("{section}.header"),
                    ));
                }
            }
            None
        } else {
            Some((
                format!("{root}.data.contents"),
                format!("{root}.data.category"),
            ))
        }
    }
    pub fn name(ctx: &StableClient<'_>, row: &str) -> Option<String> {
        ["name_slot.name", "name.text", "name"]
            .into_iter()
            .filter_map(|part| ctx.ui_text(&format!("{row}.{part}")))
            .find(|name| !name.is_empty())
    }
    pub fn identify(&mut self, ctx: &StableClient<'_>, view: View, row: &str) -> Option<usize> {
        let name = Self::name(ctx, row)?;
        let kind = view.kind();
        if let Some(id) = row
            .rsplit('.')
            .next()?
            .rsplit('_')
            .next()?
            .parse::<usize>()
            .ok()
        {
            let expected = if kind == Kind::Athlete {
                ctx.athlete_name(id)
            } else {
                ctx.record_get_string(kind, id, "name")
            };
            if expected.as_ref() == Some(&name) {
                return Some(id);
            }
        }
        self.index(ctx);
        let ids = self.names.get(&(kind.code(), name))?;
        (ids.len() == 1).then_some(ids[0])
    }
    pub fn current_ids(&mut self, ctx: &StableClient<'_>, view: View) -> Vec<usize> {
        let Some((list, _)) = Self::list(ctx, view) else {
            return Vec::new();
        };
        ctx.ui_child_names(&list)
            .into_iter()
            .filter_map(|child| self.identify(ctx, view, &format!("{list}.{child}")))
            .collect()
    }
    pub fn update(&mut self, ctx: &mut StableClient<'_>, state: Arc<Mutex<State>>, dt: u64) {
        self.elapsed = self.elapsed.saturating_add(dt);
        if self.elapsed < 1_000_000 {
            return;
        }
        self.elapsed = 0;
        self.rows.clear();
        for view in [View::Roster, View::Coaches, View::Recruitment] {
            let Some((list, _)) = Self::list(ctx, view) else {
                continue;
            };
            if view != View::Coaches {
                let path = format!("{}.vp_inline_toggle", view.root());
                if !ctx.ui_exists(&path) {
                    let source = button("vp_inline_toggle", 0.0, 0.0, 250.0, "능력치 ↔ 기본 열")
                        .replace("x: 0px;", "anchor_x:1; pivot_x:1; x:-270px;")
                        .replace("y: 0px;", "anchor_y:1; pivot_y:1; y:-4px;");
                    if ctx.ui_spawn_source(view.root(), source.trim_start_matches('#')) {
                        register_action(ctx, &path, state.clone(), move |s| {
                            if view == View::Roster {
                                s.inline.roster = !s.inline.roster;
                            } else {
                                s.inline.recruitment = !s.inline.recruitment;
                            }
                        });
                    }
                }
            }
            if view == View::Roster && !self.roster {
                for child in ctx.ui_child_names(&list) {
                    let base = format!("{list}.{child}.name_slot");
                    if ctx.ui_exists(&format!("{base}.vp_faces")) {
                        ctx.ui_set_visible(&format!("{base}.vp_faces"), false);
                        ctx.ui_set_properties(
                            &format!("{base}.name"),
                            "height:40px; y:0px; width:249px; size:18;",
                        );
                    }
                }
            }
            if (view == View::Roster && !self.roster)
                || (view == View::Recruitment && !self.recruitment)
            {
                continue;
            }
            for child in ctx.ui_child_names(&list) {
                let path = format!("{list}.{child}");
                let Some(id) = self.identify(ctx, view, &path) else {
                    continue;
                };
                let Some(name) = Self::name(ctx, &path) else {
                    continue;
                };
                let Some(raw) = ctx.record_get_json(view.kind(), id, "stat") else {
                    continue;
                };
                let Some(stat_doc) = parse(&raw) else {
                    continue;
                };
                let root = crate::Json::Object(BTreeMap::from([("stat".into(), stat_doc)]));
                let stats: Vec<_> = view.fields().iter().map(|key| stat(&root, key)).collect();
                if !stats.iter().any(Option::is_some) {
                    continue;
                }
                let prof_doc = if view == View::Roster {
                    ctx.record_get_json(view.kind(), id, "champion_proficiency")
                        .and_then(|v| parse(&v))
                        .map(|v| {
                            crate::Json::Object(BTreeMap::from([(
                                "champion_proficiency".into(),
                                v,
                            )]))
                        })
                } else {
                    None
                };
                let tops = prof_doc
                    .as_ref()
                    .map(proficiency_entries)
                    .unwrap_or_default();
                let prof = prof_doc.as_ref().map(proficiency).unwrap_or_default();
                if view == View::Roster {
                    Self::faces(ctx, &path, &tops);
                }
                self.rows.push((
                    view,
                    path,
                    Row {
                        id,
                        name,
                        stats,
                        proficiency: prof,
                        tops,
                    },
                ));
            }
        }
        for (i, view) in [View::Roster, View::Coaches, View::Recruitment]
            .into_iter()
            .enumerate()
        {
            let count = self.rows.iter().filter(|(v, _, _)| v == &view).count();
            if count != self.last_counts[i] {
                self.last_counts[i] = count;
                log(&format!("inline-ready view={view:?} verified_rows={count}"));
            }
        }
    }
    fn faces(ctx: &mut StableClient<'_>, row: &str, tops: &[(String, f64)]) {
        let parent = format!("{row}.name_slot");
        if !ctx.ui_exists(&parent) {
            return;
        }
        let path = format!("{parent}.vp_faces");
        if tops.is_empty() {
            ctx.ui_set_visible(&path, false);
            ctx.ui_set_properties(
                &format!("{parent}.name"),
                "height:40px; y:0px; width:249px; size:18;",
            );
            return;
        }
        if !ctx.ui_exists(&path) {
            let mut src = String::from(
                "vp_faces:empty { x:29px; y:22px; width:196px; height:24px; ignore_event:true;",
            );
            for i in 0..4 {
                let x = i * 46;
                src+=&format!("#c{i}:image {{ x:{x}px; width:22px; height:22px; ignore_event:true; }} #v{i}:label {{ @\"asset/base/style/main#label\"; x:{}px; width:22px; height:22px; size:10; ignore_event:true; align_y:Center; text:\"\"; }}",x+23);
            }
            src.push('}');
            if !ctx.ui_spawn_source(&parent, &src) {
                return;
            }
        }
        ctx.ui_set_visible(&path, true);
        ctx.ui_set_properties(
            &format!("{parent}.name"),
            "height:22px; y:-4px; width:180px; size:16; fit_width:true;",
        );
        for i in 0..4 {
            let image = format!("{path}.c{i}");
            let text = format!("{path}.v{i}");
            if let Some((champion, value)) = tops.get(i) {
                let ok = ctx.ui_set_champion_icon(&image, champion, 22.0, 22.0, 2.0);
                ctx.ui_set_visible(&image, ok);
                ctx.ui_set_visible(&text, ok);
                ctx.ui_set_text(&text, &format!("{value:.0}"));
            } else {
                ctx.ui_set_visible(&image, false);
                ctx.ui_set_visible(&text, false);
            }
        }
    }
    fn region(ctx: &StableClient<'_>, view: View, row: &str) -> Option<(f32, f32, f32, f32)> {
        let (rx, ry, rw, rh) = ctx.ui_node_rect(row)?;
        let start = match view {
            View::Roster => ctx.ui_node_rect(&format!("{row}.game"))?.0,
            View::Coaches => {
                let (x, _, w, _) = ctx.ui_node_rect(&format!("{row}.role"))?;
                x + w + 8.0
            }
            View::Recruitment => ctx.ui_node_rect(&format!("{row}.team"))?.0,
        };
        // Keep recommendation/delete and other native fixed columns visible.
        let end = if view == View::Recruitment {
            ctx.ui_node_rect(&format!("{row}.recommendation"))
                .map(|v| v.0)
                .unwrap_or(rx + rw - 180.0)
        } else {
            rx + rw - 10.0
        };
        ((end - start) > 400.0).then_some((start, ry, end - start, rh))
    }
    pub fn render(&self, ctx: &mut StableClient<'_>, open: Option<View>) {
        let mut headers = std::collections::BTreeSet::new();
        for (view, path, row) in &self.rows {
            if open == Some(*view)
                || ctx.ui_visible(view.root()) == Some(false)
                || !ctx.ui_exists(path)
            {
                continue;
            }
            if Self::name(ctx, path).as_deref() != Some(&row.name) {
                continue;
            }
            if (*view == View::Roster && !self.roster)
                || (*view == View::Recruitment && !self.recruitment)
            {
                continue;
            }
            let Some((x, y, w, h)) = Self::region(ctx, *view, path) else {
                continue;
            };
            let Some((list, header)) = Self::list(ctx, *view) else {
                continue;
            };
            let Some((_, ly, _, lh)) =
                ctx.ui_node_rect(list.strip_suffix(".contents").unwrap_or(&list))
            else {
                continue;
            };
            if y < ly - 1.0 || y + h > ly + lh + 1.0 {
                continue;
            }
            ctx.draw_rect("UI", x, y, w, h, 350, 0.0, 0x161721ff);
            let col = w / (view.fields().len() as f32);
            for (i, value) in row.stats.iter().enumerate() {
                let text = value
                    .map(|v| format!("{v:.0}"))
                    .unwrap_or_else(|| "—".into());
                let rgba = u32::from_str_radix(color(*value).trim_start_matches('#'), 16)
                    .unwrap_or(0xe8e8e8ff);
                ctx.draw_text(
                    "UI",
                    &text,
                    "asset/base/font/set/regular",
                    (x + i as f32 * col, y, col, h),
                    351,
                    17.0,
                    rgba,
                    X::Center,
                    Y::Center,
                );
            }
            if headers.insert(view.root()) {
                if let Some((_, hy, _, hh)) = ctx.ui_node_rect(&header) {
                    ctx.draw_rect("UI", x, hy, w, hh, 350, 0.0, 0x161721ff);
                    for (i, label) in view.labels().iter().enumerate() {
                        ctx.draw_text(
                            "UI",
                            label,
                            "asset/base/font/set/regular",
                            (x + i as f32 * col, hy, col, hh),
                            351,
                            12.0,
                            0xa8a8b3ff,
                            X::Center,
                            Y::Center,
                        );
                    }
                }
            }
        }
    }
}
