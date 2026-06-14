use std::collections::HashMap;

use crate::display::layout::{FillMode, Location, Rotation};
use crate::settings::ResolvedLayout;

const SCHEME_COLOR_KEY: &str = "waywallen.scheme_color";
const FILL_MODE_KEY: &str = "waywallen.fill_mode";
const ROTATION_KEY: &str = "waywallen.rotation";
const LOCATION_X_KEY: &str = "waywallen.location_x";
const LOCATION_Y_KEY: &str = "waywallen.location_y";

const LEGACY_SCHEME_COLOR_KEY: &str = "schemecolor";

const PREDEFINED_SCHEMA_KEYS: &[&str] = &[
    SCHEME_COLOR_KEY,
    LEGACY_SCHEME_COLOR_KEY,
    FILL_MODE_KEY,
    ROTATION_KEY,
    LOCATION_X_KEY,
    LOCATION_Y_KEY,
];

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct WallpaperLayoutOverride {
    pub fillmode: Option<FillMode>,
    pub location: Option<Location>,
    pub rotation: Option<Rotation>,
}

impl WallpaperLayoutOverride {
    pub fn apply_to(self, base: ResolvedLayout) -> ResolvedLayout {
        ResolvedLayout {
            fillmode: self.fillmode.unwrap_or(base.fillmode),
            location: self.location.unwrap_or(base.location),
            rotation: self.rotation.unwrap_or(base.rotation),
        }
    }

    pub fn is_empty(self) -> bool {
        self.fillmode.is_none() && self.location.is_none() && self.rotation.is_none()
    }
}

pub fn is_daemon_display_property_key(key: &str) -> bool {
    matches!(
        key,
        FILL_MODE_KEY | ROTATION_KEY | LOCATION_X_KEY | LOCATION_Y_KEY
    )
}

pub fn is_predefined_property_key(key: &str) -> bool {
    PREDEFINED_SCHEMA_KEYS.contains(&key)
}

pub fn canonical_user_property_key(key: &str) -> &str {
    match key {
        LEGACY_SCHEME_COLOR_KEY => SCHEME_COLOR_KEY,
        _ => key,
    }
}

pub fn dedupe_predefined_schema(raw: &str) -> String {
    let raw = raw.trim();
    if raw.is_empty() {
        return String::new();
    }
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(raw) else {
        return raw.to_string();
    };
    let Some(map) = value.as_object_mut() else {
        return raw.to_string();
    };
    map.retain(|key, _| !is_predefined_property_key(key));
    if map.is_empty() {
        String::new()
    } else {
        serde_json::to_string(map).unwrap_or_else(|_| raw.to_string())
    }
}

pub fn normalize_user_property_overrides(map: HashMap<String, String>) -> HashMap<String, String> {
    let mut out = HashMap::with_capacity(map.len());
    for (key, value) in map {
        let canonical = canonical_user_property_key(&key);
        if key == canonical || !out.contains_key(canonical) {
            out.insert(canonical.to_string(), value);
        }
    }
    out
}

pub fn normalize_user_property_overrides_json(raw: &str) -> String {
    let raw = raw.trim();
    if raw.is_empty() {
        return String::new();
    }
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(raw) else {
        return raw.to_string();
    };
    let Some(map) = value.as_object_mut() else {
        return raw.to_string();
    };

    let mut remapped = serde_json::Map::new();
    let old = std::mem::take(map);
    for (key, value) in old {
        let canonical = canonical_user_property_key(&key);
        if key == canonical || !remapped.contains_key(canonical) {
            remapped.insert(canonical.to_string(), value);
        }
    }
    *map = remapped;
    serde_json::to_string(&value).unwrap_or_else(|_| raw.to_string())
}

pub fn split_renderer_properties(raw: Option<&str>) -> (Option<String>, WallpaperLayoutOverride) {
    let Some(raw) = raw.filter(|v| !v.trim().is_empty()) else {
        return (None, WallpaperLayoutOverride::default());
    };
    let Ok(map) = serde_json::from_str::<HashMap<String, String>>(raw) else {
        return (Some(raw.to_string()), WallpaperLayoutOverride::default());
    };

    let mut renderer = HashMap::new();
    let mut fillmode = None;
    let mut rotation = None;
    let mut location_x = None;
    let mut location_y = None;

    for (key, value) in map {
        match key.as_str() {
            FILL_MODE_KEY => fillmode = parse_fillmode(&value),
            ROTATION_KEY => rotation = parse_rotation(&value),
            LOCATION_X_KEY => location_x = parse_percent(&value),
            LOCATION_Y_KEY => location_y = parse_percent(&value),
            _ => {
                renderer.insert(key, value);
            }
        }
    }

    let location = if location_x.is_some() || location_y.is_some() {
        Some(Location::new(
            location_x.unwrap_or(50),
            location_y.unwrap_or(50),
        ))
    } else {
        None
    };
    let layout = WallpaperLayoutOverride {
        fillmode,
        location,
        rotation,
    };
    let renderer_json = if renderer.is_empty() {
        None
    } else {
        serde_json::to_string(&renderer).ok()
    };
    (renderer_json, layout)
}

fn parse_fillmode(value: &str) -> Option<FillMode> {
    match value {
        "stretched" => Some(FillMode::Stretched),
        "preserve_aspect_fit" => Some(FillMode::PreserveAspectFit),
        "preserve_aspect_crop" => Some(FillMode::PreserveAspectCrop),
        "centered" => Some(FillMode::Centered),
        _ => None,
    }
}

fn parse_rotation(value: &str) -> Option<Rotation> {
    match value {
        "normal" => Some(Rotation::Normal),
        "cw_90" => Some(Rotation::Cw90),
        "cw_180" => Some(Rotation::Cw180),
        "cw_270" => Some(Rotation::Cw270),
        _ => None,
    }
}

fn parse_percent(value: &str) -> Option<u8> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    let parsed = value.parse::<f32>().ok()?;
    if !parsed.is_finite() {
        return None;
    }
    Some(parsed.round().clamp(0.0, 100.0) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_daemon_display_properties_from_renderer_properties() {
        let raw = r#"{
            "waywallen.fill_mode": "centered",
            "waywallen.location_x": "25",
            "waywallen.location_y": "75",
            "speed": "2"
        }"#;
        let (renderer, layout) = split_renderer_properties(Some(raw));
        assert_eq!(layout.fillmode, Some(FillMode::Centered));
        assert_eq!(layout.location, Some(Location::new(25, 75)));
        assert_eq!(renderer.as_deref(), Some(r#"{"speed":"2"}"#));
    }

    #[test]
    fn removes_predefined_properties_from_schema() {
        let raw = r#"{
            "waywallen.scheme_color": { "type": "color" },
            "ui_browse_properties_scheme_color": { "type": "color" },
            "schemecolor": { "type": "color" },
            "waywallen.fill_mode": { "type": "combo" },
            "speed": { "type": "slider" }
        }"#;
        let filtered = dedupe_predefined_schema(raw);
        let value: serde_json::Value = serde_json::from_str(&filtered).unwrap();
        let obj = value.as_object().unwrap();
        assert!(!obj.contains_key("waywallen.scheme_color"));
        assert!(!obj.contains_key("schemecolor"));
        assert!(!obj.contains_key("waywallen.fill_mode"));
        assert!(obj.contains_key("ui_browse_properties_scheme_color"));
        assert!(obj.contains_key("speed"));
    }

    #[test]
    fn normalizes_legacy_scheme_color_override_key() {
        let raw = r#"{
            "schemecolor": "0.1 0.2 0.3",
            "speed": "2"
        }"#;
        let normalized = normalize_user_property_overrides_json(raw);
        let value: serde_json::Value = serde_json::from_str(&normalized).unwrap();
        let obj = value.as_object().unwrap();
        assert_eq!(
            obj.get("waywallen.scheme_color").and_then(|v| v.as_str()),
            Some("0.1 0.2 0.3")
        );
        assert!(!obj.contains_key("schemecolor"));
        assert_eq!(obj.get("speed").and_then(|v| v.as_str()), Some("2"));
    }

    #[test]
    fn canonical_scheme_color_override_wins_over_legacy_alias() {
        let map = HashMap::from([
            (
                "waywallen.scheme_color".to_string(),
                "0.4 0.5 0.6".to_string(),
            ),
            ("schemecolor".to_string(), "0.1 0.2 0.3".to_string()),
        ]);
        let normalized = normalize_user_property_overrides(map);
        assert_eq!(
            normalized.get("waywallen.scheme_color").map(String::as_str),
            Some("0.4 0.5 0.6")
        );
        assert!(!normalized.contains_key("schemecolor"));
    }
}
