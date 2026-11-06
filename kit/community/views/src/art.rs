//! Optional, explicitly inventoried PNG art; never references missing assets.
use crate::{
    button,
    json::{parse, Json},
    log, q, register_action, State,
};
use mod_api_stable::StableClient;
use std::io::Read;
use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::{Arc, Mutex},
};
const PREFIX: &str = "asset/tfm2_view_plus_ios/illust/";
#[derive(Default)]
pub struct Art {
    pub images: BTreeMap<String, Vec<String>>,
    pub red: BTreeMap<String, Vec<String>>,
    pub red_noflip: BTreeMap<String, Vec<String>>,
    pub mode: usize,
    pub selected: Option<String>,
    pub variant: usize,
    pub enabled: bool,
    last_source: String,
    sizes: BTreeMap<String, (f32, f32)>,
    aliases: BTreeMap<String, String>,
}
pub fn mod_dir() -> Option<PathBuf> {
    let p = PathBuf::from(std::env::var_os("HOME")?)
        .join("Documents/GameRuntime/mods/tfm2_view_plus_ios");
    p.is_dir().then_some(p)
}
impl Art {
    pub fn load() -> Self {
        let Some(dir) = mod_dir() else {
            return Self::default();
        };
        let Some(raw) = std::fs::read_to_string(dir.join("illust-manifest.json")).ok() else {
            return Self::default();
        };
        let Some(root) = parse(&raw) else {
            log("art-manifest-invalid");
            return Self::default();
        };
        let images = Self::inventory(&root, &dir, "champions");
        let red = Self::inventory(&root, &dir, "red");
        let red_noflip = Self::inventory(&root, &dir, "red_noflip");
        log(&format!(
            "art-inventory champions={} variants={} red={} red_noflip={}",
            images.len(),
            images.values().map(Vec::len).sum::<usize>(),
            red.len(),
            red_noflip.len()
        ));
        let sizes = images
            .values()
            .chain(red.values())
            .chain(red_noflip.values())
            .flatten()
            .filter_map(|path| Some((path.clone(), Self::image_size(&dir, path)?)))
            .collect();
        Self {
            sizes,
            images,
            red,
            red_noflip,
            enabled: true,
            ..Self::default()
        }
    }
    fn image_size(dir: &std::path::Path, path: &str) -> Option<(f32, f32)> {
        let relative = Self::relative(path)?;
        let mut header = [0u8; 24];
        std::fs::File::open(dir.join("illust").join(format!("{relative}.png")))
            .ok()?
            .read_exact(&mut header)
            .ok()?;
        if &header[..8] != b"\x89PNG\r\n\x1a\n" || &header[12..16] != b"IHDR" {
            return None;
        }
        let w = u32::from_be_bytes(header[16..20].try_into().ok()?);
        let h = u32::from_be_bytes(header[20..24].try_into().ok()?);
        (w > 0 && h > 0 && w <= 8192 && h <= 8192).then_some((w as f32, h as f32))
    }
    fn relative(path: &str) -> Option<&str> {
        let relative = path.strip_prefix(PREFIX)?;
        if relative.is_empty()
            || relative.contains("..")
            || !relative
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'-' | b'/'))
        {
            return None;
        }
        Some(relative)
    }
    fn inventory(root: &Json, dir: &std::path::Path, key: &str) -> BTreeMap<String, Vec<String>> {
        let mut images = BTreeMap::new();
        if let Some(entries) = root.get(key).and_then(Json::object) {
            for (champion, paths) in entries {
                if !champion
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'_')
                {
                    continue;
                }
                let Json::Array(paths) = paths else {
                    continue;
                };
                let mut valid = Vec::new();
                for path in paths.iter().take(32).filter_map(Json::string) {
                    let Some(_relative) = Self::relative(path) else {
                        continue;
                    };
                    if Self::image_size(dir, path).is_some() {
                        valid.push(path.to_owned());
                    }
                }
                if !valid.is_empty() {
                    images.insert(champion.clone(), valid);
                }
            }
        }
        images
    }
    pub(crate) fn localized_ids<'a>(
        ctx: &StableClient<'_>,
        ids: impl Iterator<Item = &'a String>,
    ) -> BTreeMap<String, String> {
        let mut aliases = BTreeMap::new();
        let mut ambiguous = std::collections::BTreeSet::new();
        for id in ids {
            aliases.insert(id.clone(), id.clone());
            let localized = ctx
                .i18n(&format!("#asset/base/text/champion?description.{id}.name"))
                .or_else(|| ctx.i18n(&format!("asset/base/text/champion?description.{id}.name")));
            if let Some(name) = localized {
                if ambiguous.contains(&name) {
                    continue;
                }
                if aliases.get(&name).is_some_and(|old| old != id) {
                    aliases.remove(&name);
                    ambiguous.insert(name);
                } else {
                    aliases.insert(name, id.clone());
                }
            }
        }
        aliases
    }
    pub fn update(&mut self, ctx: &mut StableClient<'_>, state: Arc<Mutex<State>>) {
        if self.images.is_empty()
            || !ctx.ui_exists("main.champions.contents")
            || !ctx.ui_exists("main.background")
        {
            self.last_source.clear();
            self.selected = None;
            self.aliases.clear();
            return;
        }
        if self.aliases.is_empty() {
            self.aliases = Self::localized_ids(ctx, self.images.keys());
        }
        if !ctx.ui_exists("main.header.vp_art_toggle") {
            let src = button("vp_art_toggle", 0.0, 5.0, 110.0, "그림 ON/OFF")
                .replace("x: 0px;", "anchor_x:1; pivot_x:1; x:-8px;");
            if ctx.ui_spawn_source("main.header", src.trim_start_matches('#')) {
                register_action(ctx, "main.header.vp_art_toggle", state.clone(), |s| {
                    s.art.enabled = !s.art.enabled;
                    s.art.last_source.clear();
                });
            }
        }
        if !ctx.ui_exists("main.header.vp_art_next") {
            let src = button("vp_art_next", 0.0, 5.0, 90.0, "다음 그림")
                .replace("x: 0px;", "anchor_x:1; pivot_x:1; x:-128px;");
            if ctx.ui_spawn_source("main.header", src.trim_start_matches('#')) {
                register_action(ctx, "main.header.vp_art_next", state.clone(), |s| {
                    s.art.variant = s.art.variant.wrapping_add(1);
                    s.art.last_source.clear();
                });
            }
        }
        if !ctx.ui_exists("main.header.vp_art_direction")
            && (!self.red.is_empty() || !self.red_noflip.is_empty())
        {
            let src = button("vp_art_direction", 0.0, 5.0, 120.0, "그림 방향")
                .replace("x: 0px;", "anchor_x:1; pivot_x:1; x:-228px;");
            if ctx.ui_spawn_source("main.header", src.trim_start_matches('#')) {
                register_action(ctx, "main.header.vp_art_direction", state.clone(), |s| {
                    let mut modes = vec![0];
                    if s.art
                        .selected
                        .as_ref()
                        .is_some_and(|c| s.art.red.contains_key(c))
                    {
                        modes.push(1);
                    }
                    if s.art
                        .selected
                        .as_ref()
                        .is_some_and(|c| s.art.red_noflip.contains_key(c))
                    {
                        modes.push(2);
                    }
                    let i = modes.iter().position(|m| *m == s.art.mode).unwrap_or(0);
                    s.art.mode = modes[(i + 1) % modes.len()];
                    s.art.last_source.clear();
                });
            }
        }
        let caption = match self.mode {
            1 => "그림: 적팀",
            2 => "적팀: 반전 없음",
            _ => "그림: 청팀",
        };
        ctx.ui_set_properties("main.header.vp_art_direction",&format!("text: {{ font: \"asset/base/font/set/bold\"; size:14; align_x:Center; align_y:Center; text:{}; }}",q(caption)));
        // Native pointer/selection handling already updates this label; an
        // exact localized name match avoids inferring champion identity from
        // the current order of a filtered or sorted grid.
        if let Some(name) = ctx
            .ui_text("main.champion_info.stat.name")
            .or_else(|| ctx.ui_text("main.champion_info.name"))
        {
            if let Some(id) = self.aliases.get(&name).cloned() {
                self.selected = Some(id);
            }
        }
        for child in ctx.ui_child_names("main.champions.contents") {
            let row = format!("main.champions.contents.{child}");
            let marker = format!("{row}.vp_art_marker");
            if ctx.ui_exists(&marker) {
                continue;
            }
            let Some(label) = ctx.ui_text(&format!("{row}.name")) else {
                continue;
            };
            let Some(champion) = self.aliases.get(&label).cloned() else {
                continue;
            };
            if ctx.ui_spawn_source(
                &row,
                "vp_art_marker:empty { visible:false; ignore_event:true; width:0px; height:0px; }",
            ) {
                register_action(ctx, &row, state.clone(), move |s| {
                    s.art.selected = Some(champion.clone());
                    s.art.last_source.clear();
                });
            }
        }
        if !self.enabled {
            ctx.ui_set_visible("main.background.vp_art", false);

            self.last_source.clear();
            return;
        }
        let Some(champion) = self.selected.as_ref() else {
            return;
        };
        let selected_pack = match self.mode {
            1 => &self.red,
            2 => &self.red_noflip,
            _ => &self.images,
        };
        let Some(paths) = selected_pack
            .get(champion)
            .or_else(|| self.images.get(champion))
        else {
            return;
        };
        ctx.ui_set_properties(
            "main.header.vp_art_next",
            if paths.len() > 1 {
                "disable:false;"
            } else {
                "disable:true;"
            },
        );
        let source = paths[self.variant % paths.len()].clone();
        // A root rebuild can destroy the image without changing its source.
        if self.last_source == source && ctx.ui_exists("main.background.vp_art") {
            return;
        }
        let Some((sw, sh)) = self.sizes.get(&source).copied() else {
            return;
        };
        let (_, _, bw, bh) = ctx
            .ui_node_rect("main.background")
            .unwrap_or((0.0, 0.0, 1920.0, 1440.0));
        let scale = (bw / sw).max(bh / sh);
        let props = format!(
            "source:{}; anchor_x:0.5; pivot_x:0.5; anchor_y:0.5; pivot_y:0.5; width:{}px; height:{}px; color:#ffffff70; ignore_event:true;",
            q(&source),sw*scale,sh*scale
        );
        let ok = if ctx.ui_exists("main.background.vp_art") {
            ctx.ui_set_properties("main.background.vp_art", &props)
        } else {
            ctx.ui_spawn_source("main.background", &format!("vp_art:image {{ {props} }}"))
        };
        if ok {
            ctx.ui_set_visible("main.background.vp_art", true);
            self.last_source = source;
            log(&format!(
                "art-applied champion={champion} direction={} variant={}",
                self.mode,
                self.variant % paths.len()
            ));
        }
        // Only backgrounds become slightly translucent. Existing controls,
        // labels, events, draft order and draft simulation remain native.
    }
}
#[cfg(test)]
mod tests {
    #[test]
    fn manifest_paths_cannot_escape_or_name_other_assets() {
        assert_eq!(
            super::Art::relative("asset/tfm2_view_plus_ios/illust/blue/fighter-2"),
            Some("blue/fighter-2")
        );
        for path in [
            "asset/base/secret",
            "asset/tfm2_view_plus_ios/illust/../../x",
            "asset/tfm2_view_plus_ios/illust/x.png",
            "asset/tfm2_view_plus_ios/illust/",
        ] {
            assert!(super::Art::relative(path).is_none());
        }
    }
}
