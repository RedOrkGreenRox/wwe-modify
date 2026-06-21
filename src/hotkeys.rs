//! User-configurable keyboard shortcut bindings.
//!
//! Every page-level and global action that responds to a key press
//! is enumerated here. The UI side reads [`HotkeySettings`] from the
//! daemon via the existing `SettingsGet` / `SettingsSet` RPC, and the
//! daemon's `SettingsStore` persists them as a TOML section under
//! `[hotkeys]`.
//!
//! Defaults are chosen to match what was previously hardcoded in
//! `WallpaperPage.qml` so a fresh install behaves identically to the
//! pre-bindings build.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// All actions that can be triggered by a key combination. The order
/// here is also the order the settings UI shows them — keep the most
/// frequently used actions at the top.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize,
)]
pub enum HotkeyAction {
    // --- Global (any page) ---
    /// Quit the application. Default: Ctrl+Q.
    Quit,
    /// Open Wallpapers tab. Default: Ctrl+1.
    OpenWallpapers,
    /// Open Workshop tab. Default: Ctrl+2.
    OpenWorkshop,
    /// Open Displays tab. Default: Ctrl+3.
    OpenDisplays,
    /// Open Status tab. Default: Ctrl+4.
    OpenStatus,
    /// Open Plugins tab. Default: Ctrl+5.
    OpenPlugins,
    /// Open Settings tab. Default: Ctrl+6.
    OpenSettings,
    /// Open Hotkeys tab. Default: Ctrl+7.
    OpenHotkeys,
    /// Reload UI (recreates QML). Default: Ctrl+Shift+R.
    ReloadUi,
    /// Toggle hotkey cheatsheet overlay. Default: Ctrl+Shift+Slash.
    Cheatsheet,

    // --- WallpaperPage: grid navigation + selection ---
    /// Move grid selection left. Default: Left.
    NavigateLeft,
    /// Move grid selection right. Default: Right.
    NavigateRight,
    /// Move grid selection up. Default: Up.
    NavigateUp,
    /// Move grid selection down. Default: Down.
    NavigateDown,
    /// Jump to row/column boundary (left). Default: Ctrl+Left.
    JumpLeft,
    /// Jump to row/column boundary (right). Default: Ctrl+Right.
    JumpRight,
    /// Jump to row/column boundary (up). Default: Ctrl+Up.
    JumpUp,
    /// Jump to row/column boundary (down). Default: Ctrl+Down.
    JumpDown,
    /// First item in current row. Default: Home.
    Home,
    /// Last item in current row. Default: End.
    End,
    /// First item overall. Default: Ctrl+Home.
    HomeAll,
    /// Last item overall. Default: Ctrl+End.
    EndAll,
    /// Page up. Default: PageUp.
    PageUp,
    /// Page down. Default: PageDown.
    PageDown,

    // --- WallpaperPage: actions ---
    /// Refresh / rescan the library. Default: F5, Ctrl+R.
    RefreshScan,
    /// Focus the search field. Default: Ctrl+F.
    FocusSearch,
    /// Select all wallpapers in current view. Default: Ctrl+A.
    SelectAll,
    /// Clear selection OR close detail panel. Default: Delete, Backspace, Escape.
    Cancel,
    /// Apply the currently focused wallpaper. Default: Enter, Return.
    ApplyWallpaper,
    /// Toggle selection state of the focused wallpaper. Default: Space.
    ToggleSelection,
    /// Toggle filters dialog. Default: Ctrl+Shift+F.
    ToggleFilters,

    // --- WorkshopPage ---
    /// Reload Workshop (reloads WebEngine). Default: F5, Ctrl+R.
    WorkshopReload,
    /// Open current URL in Steam. Default: none.
    WorkshopOpenInSteam,
    /// Open current URL in browser. Default: Ctrl+O.
    WorkshopOpenInBrowser,
    /// Clear WebEngine cookies / cache. Default: Ctrl+Shift+Delete.
    WorkshopClearSession,
    /// Retry loading Workshop after failure. Default: Ctrl+Shift+R.
    WorkshopRetry,

    // --- DisplaysPage ---
    /// Refresh displays. Default: F5.
    DisplaysRefresh,
    /// Rename the focused display. Default: F2.
    DisplaysRename,
    /// Layout settings for the focused display. Default: F4.
    DisplaysLayout,

    // --- StatusPage ---
    /// Refresh status. Default: F5.
    StatusRefresh,

    // --- PluginsPage ---
    /// Refresh installed plugin list. Default: F5.
    PluginsRefresh,
    /// Install a plugin from a zip file. Default: Ctrl+I.
    PluginsInstall,
    /// Enable / disable the focused plugin. Default: Space.
    PluginsToggle,

    // --- SettingsPage ---
    /// Save pending settings. Default: Ctrl+S.
    SettingsSave,
    /// Reset current tab to defaults. Default: none.
    SettingsResetTab,
}

impl HotkeyAction {
    /// Stable string identifier used in TOML / proto / UI model.
    /// **Never change these — they are persisted.**
    pub fn as_str(&self) -> &'static str {
        match self {
            // Global
            Self::Quit => "quit",
            Self::OpenWallpapers => "open_wallpapers",
            Self::OpenWorkshop => "open_workshop",
            Self::OpenDisplays => "open_displays",
            Self::OpenStatus => "open_status",
            Self::OpenPlugins => "open_plugins",
            Self::OpenSettings => "open_settings",
            Self::OpenHotkeys => "open_hotkeys",
            Self::ReloadUi => "reload_ui",
            Self::Cheatsheet => "cheatsheet",
            // Grid nav
            Self::NavigateLeft => "navigate_left",
            Self::NavigateRight => "navigate_right",
            Self::NavigateUp => "navigate_up",
            Self::NavigateDown => "navigate_down",
            Self::JumpLeft => "jump_left",
            Self::JumpRight => "jump_right",
            Self::JumpUp => "jump_up",
            Self::JumpDown => "jump_down",
            Self::Home => "home",
            Self::End => "end",
            Self::HomeAll => "home_all",
            Self::EndAll => "end_all",
            Self::PageUp => "page_up",
            Self::PageDown => "page_down",
            // Wallpaper actions
            Self::RefreshScan => "refresh_scan",
            Self::FocusSearch => "focus_search",
            Self::SelectAll => "select_all",
            Self::Cancel => "cancel",
            Self::ApplyWallpaper => "apply_wallpaper",
            Self::ToggleSelection => "toggle_selection",
            Self::ToggleFilters => "toggle_filters",
            // Workshop
            Self::WorkshopReload => "workshop_reload",
            Self::WorkshopOpenInSteam => "workshop_open_in_steam",
            Self::WorkshopOpenInBrowser => "workshop_open_in_browser",
            Self::WorkshopClearSession => "workshop_clear_session",
            Self::WorkshopRetry => "workshop_retry",
            // Displays
            Self::DisplaysRefresh => "displays_refresh",
            Self::DisplaysRename => "displays_rename",
            Self::DisplaysLayout => "displays_layout",
            // Status
            Self::StatusRefresh => "status_refresh",
            // Plugins
            Self::PluginsRefresh => "plugins_refresh",
            Self::PluginsInstall => "plugins_install",
            Self::PluginsToggle => "plugins_toggle",
            // Settings
            Self::SettingsSave => "settings_save",
            Self::SettingsResetTab => "settings_reset_tab",
        }
    }

    /// Reverse lookup for parsing TOML / proto strings back to enum.
    pub fn from_str(s: &str) -> Option<Self> {
        Some(match s {
            // Global
            "quit" => Self::Quit,
            "open_wallpapers" => Self::OpenWallpapers,
            "open_workshop" => Self::OpenWorkshop,
            "open_displays" => Self::OpenDisplays,
            "open_status" => Self::OpenStatus,
            "open_plugins" => Self::OpenPlugins,
            "open_settings" => Self::OpenSettings,
            "open_hotkeys" => Self::OpenHotkeys,
            "reload_ui" => Self::ReloadUi,
            "cheatsheet" => Self::Cheatsheet,
            // Grid nav
            "navigate_left" => Self::NavigateLeft,
            "navigate_right" => Self::NavigateRight,
            "navigate_up" => Self::NavigateUp,
            "navigate_down" => Self::NavigateDown,
            "jump_left" => Self::JumpLeft,
            "jump_right" => Self::JumpRight,
            "jump_up" => Self::JumpUp,
            "jump_down" => Self::JumpDown,
            "home" => Self::Home,
            "end" => Self::End,
            "home_all" => Self::HomeAll,
            "end_all" => Self::EndAll,
            "page_up" => Self::PageUp,
            "page_down" => Self::PageDown,
            // Wallpaper actions
            "refresh_scan" => Self::RefreshScan,
            "focus_search" => Self::FocusSearch,
            "select_all" => Self::SelectAll,
            "cancel" => Self::Cancel,
            "apply_wallpaper" => Self::ApplyWallpaper,
            "toggle_selection" => Self::ToggleSelection,
            "toggle_filters" => Self::ToggleFilters,
            // Workshop
            "workshop_reload" => Self::WorkshopReload,
            "workshop_open_in_steam" => Self::WorkshopOpenInSteam,
            "workshop_open_in_browser" => Self::WorkshopOpenInBrowser,
            "workshop_clear_session" => Self::WorkshopClearSession,
            "workshop_retry" => Self::WorkshopRetry,
            // Displays
            "displays_refresh" => Self::DisplaysRefresh,
            "displays_rename" => Self::DisplaysRename,
            "displaysRename" => Self::DisplaysRename,
            "displays_layout" => Self::DisplaysLayout,
            "status_refresh" => Self::StatusRefresh,
            // Plugins
            "plugins_refresh" => Self::PluginsRefresh,
            "plugins_install" => Self::PluginsInstall,
            "plugins_toggle" => Self::PluginsToggle,
            // Settings
            "settings_save" => Self::SettingsSave,
            "settings_reset_tab" => Self::SettingsResetTab,
            _ => return None,
        })
    }

    /// Section label for the UI (translated at render time).
    pub fn section(&self) -> &'static str {
        match self {
            Self::Quit
            | Self::OpenWallpapers
            | Self::OpenWorkshop
            | Self::OpenDisplays
            | Self::OpenStatus
            | Self::OpenPlugins
            | Self::OpenSettings
            | Self::OpenHotkeys
            | Self::ReloadUi
            | Self::Cheatsheet => "Global",
            Self::NavigateLeft
            | Self::NavigateRight
            | Self::NavigateUp
            | Self::NavigateDown
            | Self::JumpLeft
            | Self::JumpRight
            | Self::JumpUp
            | Self::JumpDown
            | Self::Home
            | Self::End
            | Self::HomeAll
            | Self::EndAll
            | Self::PageUp
            | Self::PageDown => "Wallpaper grid navigation",
            Self::RefreshScan
            | Self::FocusSearch
            | Self::SelectAll
            | Self::Cancel
            | Self::ApplyWallpaper
            | Self::ToggleSelection
            | Self::ToggleFilters => "Wallpaper actions",
            Self::WorkshopReload
            | Self::WorkshopOpenInSteam
            | Self::WorkshopOpenInBrowser
            | Self::WorkshopClearSession
            | Self::WorkshopRetry => "Workshop",
            Self::DisplaysRefresh | Self::DisplaysRename | Self::DisplaysLayout => "Displays",
            Self::StatusRefresh => "Status",
            Self::PluginsRefresh | Self::PluginsInstall | Self::PluginsToggle => "Plugins",
            Self::SettingsSave | Self::SettingsResetTab => "Settings",
        }
    }

    /// Human-readable label (translated at render time).
    pub fn label(&self) -> &'static str {
        match self {
            Self::Quit => "Quit application",
            Self::OpenWallpapers => "Open Wallpapers tab",
            Self::OpenWorkshop => "Open Workshop tab",
            Self::OpenDisplays => "Open Displays tab",
            Self::OpenStatus => "Open Status tab",
            Self::OpenPlugins => "Open Plugins tab",
            Self::OpenSettings => "Open Settings tab",
            Self::OpenHotkeys => "Open Hotkeys tab",
            Self::ReloadUi => "Reload UI",
            Self::Cheatsheet => "Toggle cheatsheet",
            Self::NavigateLeft => "Navigate left",
            Self::NavigateRight => "Navigate right",
            Self::NavigateUp => "Navigate up",
            Self::NavigateDown => "Navigate down",
            Self::JumpLeft => "Jump to row/col boundary (left)",
            Self::JumpRight => "Jump to row/col boundary (right)",
            Self::JumpUp => "Jump to row/col boundary (up)",
            Self::JumpDown => "Jump to row/col boundary (down)",
            Self::Home => "First item in row",
            Self::End => "Last item in row",
            Self::HomeAll => "First item overall",
            Self::EndAll => "Last item overall",
            Self::PageUp => "Page up",
            Self::PageDown => "Page down",
            Self::RefreshScan => "Refresh / rescan library",
            Self::FocusSearch => "Focus search",
            Self::SelectAll => "Select all wallpapers",
            Self::Cancel => "Cancel selection / close detail",
            Self::ApplyWallpaper => "Apply focused wallpaper",
            Self::ToggleSelection => "Toggle selection of focused wallpaper",
            Self::ToggleFilters => "Open filters dialog",
            Self::WorkshopReload => "Reload Workshop",
            Self::WorkshopOpenInSteam => "Open current URL in Steam",
            Self::WorkshopOpenInBrowser => "Open current URL in browser",
            Self::WorkshopClearSession => "Clear Workshop session",
            Self::WorkshopRetry => "Retry Workshop load",
            Self::DisplaysRefresh => "Refresh displays",
            Self::DisplaysRename => "Rename focused display",
            Self::DisplaysLayout => "Edit focused display layout",
            Self::StatusRefresh => "Refresh status",
            Self::PluginsRefresh => "Refresh plugin list",
            Self::PluginsInstall => "Install plugin from zip",
            Self::PluginsToggle => "Enable / disable focused plugin",
            Self::SettingsSave => "Save settings",
            Self::SettingsResetTab => "Reset current tab to defaults",
        }
    }
}

/// The full set of user-customisable key bindings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotkeySettings {
    /// `action.as_str()` → ordered list of sequence strings
    /// (QKeySequence portable form, e.g. `"Ctrl+R"`, `"F5"`).
    /// Empty list = action has no binding. Keys are owned strings so
    /// the struct round-trips through serde; callers go through the
    /// typed accessors below to keep the action enum the source of
    /// truth.
    #[serde(default)]
    pub bindings: BTreeMap<String, Vec<String>>,
}

impl Default for HotkeySettings {
    fn default() -> Self {
        Self {
            bindings: default_bindings(),
        }
    }
}

impl HotkeySettings {
    /// Return the binding list for one action. Empty if unset.
    pub fn get(&self, action: HotkeyAction) -> &[String] {
        self.bindings
            .get(action.as_str())
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// Set the binding list for one action.
    pub fn set(&mut self, action: HotkeyAction, seqs: Vec<String>) {
        if seqs.is_empty() {
            self.bindings.remove(action.as_str());
        } else {
            self.bindings.insert(action.as_str().to_owned(), seqs);
        }
    }

    /// Replace the entire binding map. Unknown action keys are dropped.
    /// Returns the number of dropped entries (sanity check).
    pub fn replace_from(&mut self, raw: BTreeMap<String, Vec<String>>) -> usize {
        let mut dropped = 0;
        let mut next: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (k, v) in raw {
            match HotkeyAction::from_str(&k) {
                Some(act) => {
                    next.insert(act.as_str().to_owned(), v);
                }
                None => {
                    dropped += 1;
                    log::warn!("hotkeys: dropping unknown action key '{k}'");
                }
            }
        }
        self.bindings = next;
        dropped
    }

    /// Find every action that includes `seq` in its binding list.
    /// Used by the UI to highlight conflicts.
    pub fn actions_for_sequence(&self, seq: &str) -> Vec<HotkeyAction> {
        let mut hits = Vec::new();
        for (key, seqs) in &self.bindings {
            if seqs.iter().any(|s| s == seq) {
                if let Some(act) = HotkeyAction::from_str(key) {
                    hits.push(act);
                }
            }
        }
        hits
    }
}

/// Defaults used by a fresh install or the "Reset to defaults" button.
pub fn default_bindings() -> BTreeMap<String, Vec<String>> {
    use HotkeyAction as A;
    let mut m: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let set = |m: &mut BTreeMap<String, Vec<String>>, act: A, seqs: &[&str]| {
        m.insert(
            act.as_str().to_owned(),
            seqs.iter().map(|s| s.to_string()).collect(),
        );
    };
    // Global
    set(&mut m, A::Quit, &["Ctrl+Q"]);
    set(&mut m, A::OpenWallpapers, &["Ctrl+1"]);
    set(&mut m, A::OpenWorkshop, &["Ctrl+2"]);
    set(&mut m, A::OpenDisplays, &["Ctrl+3"]);
    set(&mut m, A::OpenStatus, &["Ctrl+4"]);
    set(&mut m, A::OpenPlugins, &["Ctrl+5"]);
    set(&mut m, A::OpenSettings, &["Ctrl+6"]);
    set(&mut m, A::OpenHotkeys, &["Ctrl+7"]);
    set(&mut m, A::ReloadUi, &["Ctrl+Shift+R"]);
    set(&mut m, A::Cheatsheet, &["Ctrl+?"]);
    // Grid nav
    set(&mut m, A::NavigateLeft, &["Left"]);
    set(&mut m, A::NavigateRight, &["Right"]);
    set(&mut m, A::NavigateUp, &["Up"]);
    set(&mut m, A::NavigateDown, &["Down"]);
    set(&mut m, A::JumpLeft, &["Ctrl+Left"]);
    set(&mut m, A::JumpRight, &["Ctrl+Right"]);
    set(&mut m, A::JumpUp, &["Ctrl+Up"]);
    set(&mut m, A::JumpDown, &["Ctrl+Down"]);
    set(&mut m, A::Home, &["Home"]);
    set(&mut m, A::End, &["End"]);
    set(&mut m, A::HomeAll, &["Ctrl+Home"]);
    set(&mut m, A::EndAll, &["Ctrl+End"]);
    set(&mut m, A::PageUp, &["PageUp"]);
    set(&mut m, A::PageDown, &["PageDown"]);
    // Wallpaper actions
    set(&mut m, A::RefreshScan, &["F5", "Ctrl+R"]);
    set(&mut m, A::FocusSearch, &["Ctrl+F"]);
    set(&mut m, A::SelectAll, &["Ctrl+A"]);
    set(&mut m, A::Cancel, &["Delete", "Backspace", "Escape"]);
    set(&mut m, A::ApplyWallpaper, &["Enter", "Return"]);
    set(&mut m, A::ToggleSelection, &["Space"]);
    set(&mut m, A::ToggleFilters, &["Ctrl+Shift+F"]);
    // Workshop
    set(&mut m, A::WorkshopReload, &["F5", "Ctrl+R"]);
    set(&mut m, A::WorkshopOpenInSteam, &[]);
    set(&mut m, A::WorkshopOpenInBrowser, &["Ctrl+O"]);
    set(&mut m, A::WorkshopClearSession, &["Ctrl+Shift+Delete"]);
    set(&mut m, A::WorkshopRetry, &["Ctrl+Shift+R"]);
    // Displays
    set(&mut m, A::DisplaysRefresh, &["F5"]);
    set(&mut m, A::DisplaysRename, &["F2"]);
    set(&mut m, A::DisplaysLayout, &["F4"]);
    // Status
    set(&mut m, A::StatusRefresh, &["F5"]);
    // Plugins
    set(&mut m, A::PluginsRefresh, &["F5"]);
    set(&mut m, A::PluginsInstall, &["Ctrl+I"]);
    set(&mut m, A::PluginsToggle, &["Space"]);
    // Settings
    set(&mut m, A::SettingsSave, &["Ctrl+S"]);
    set(&mut m, A::SettingsResetTab, &[]);
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_default_bindings() {
        let defaults = HotkeySettings::default();
        let json = serde_json::to_string(&defaults).unwrap();
        let parsed: HotkeySettings = serde_json::from_str(&json).unwrap();
        assert_eq!(defaults.bindings, parsed.bindings);
    }

    #[test]
    fn all_actions_have_a_label_and_section() {
        // Compile-time check that every variant has a match arm.
        for act in all_actions() {
            assert!(!act.label().is_empty(), "{act:?} missing label");
            assert!(!act.section().is_empty(), "{act:?} missing section");
            assert!(!act.as_str().is_empty(), "{act:?} missing as_str");
        }
    }

    #[test]
    fn from_str_round_trips_every_action() {
        for act in all_actions() {
            let s = act.as_str();
            assert_eq!(HotkeyAction::from_str(s), Some(act));
        }
    }

    #[test]
    fn from_str_returns_none_for_unknown() {
        assert_eq!(HotkeyAction::from_str("not_a_real_action"), None);
        assert_eq!(HotkeyAction::from_str(""), None);
    }

    #[test]
    fn actions_for_sequence_lists_every_match() {
        let mut s = HotkeySettings::default();
        // F5 is bound to RefreshScan, WorkshopReload, DisplaysRefresh,
        // StatusRefresh, PluginsRefresh — five hits.
        let hits = s.actions_for_sequence("F5");
        assert!(hits.contains(&HotkeyAction::RefreshScan));
        assert!(hits.contains(&HotkeyAction::WorkshopReload));
        assert!(hits.contains(&HotkeyAction::DisplaysRefresh));
        assert!(hits.contains(&HotkeyAction::StatusRefresh));
        assert!(hits.contains(&HotkeyAction::PluginsRefresh));
        assert_eq!(hits.len(), 5);
        // A sequence we did not bind is empty.
        s.set(HotkeyAction::WorkshopOpenInSteam, vec!["Ctrl+Alt+S".into()]);
        let steam_hits = s.actions_for_sequence("Ctrl+Alt+S");
        assert_eq!(steam_hits, vec![HotkeyAction::WorkshopOpenInSteam]);
    }

    #[test]
    fn replace_from_drops_unknown_keys() {
        let mut s = HotkeySettings::default();
        let mut raw = BTreeMap::new();
        raw.insert(
            "refresh_scan".to_owned(),
            vec!["Ctrl+Alt+R".to_owned()],
        );
        raw.insert(
            "this_is_not_an_action".to_owned(),
            vec!["Ctrl+Whatever".to_owned()],
        );
        let dropped = s.replace_from(raw);
        assert_eq!(dropped, 1);
        assert_eq!(s.get(HotkeyAction::RefreshScan), &["Ctrl+Alt+R"]);
    }

    fn all_actions() -> Vec<HotkeyAction> {
        vec![
            HotkeyAction::Quit,
            HotkeyAction::OpenWallpapers,
            HotkeyAction::OpenWorkshop,
            HotkeyAction::OpenDisplays,
            HotkeyAction::OpenStatus,
            HotkeyAction::OpenPlugins,
            HotkeyAction::OpenSettings,
            HotkeyAction::OpenHotkeys,
            HotkeyAction::ReloadUi,
            HotkeyAction::Cheatsheet,
            HotkeyAction::NavigateLeft,
            HotkeyAction::NavigateRight,
            HotkeyAction::NavigateUp,
            HotkeyAction::NavigateDown,
            HotkeyAction::JumpLeft,
            HotkeyAction::JumpRight,
            HotkeyAction::JumpUp,
            HotkeyAction::JumpDown,
            HotkeyAction::Home,
            HotkeyAction::End,
            HotkeyAction::HomeAll,
            HotkeyAction::EndAll,
            HotkeyAction::PageUp,
            HotkeyAction::PageDown,
            HotkeyAction::RefreshScan,
            HotkeyAction::FocusSearch,
            HotkeyAction::SelectAll,
            HotkeyAction::Cancel,
            HotkeyAction::ApplyWallpaper,
            HotkeyAction::ToggleSelection,
            HotkeyAction::ToggleFilters,
            HotkeyAction::WorkshopReload,
            HotkeyAction::WorkshopOpenInSteam,
            HotkeyAction::WorkshopOpenInBrowser,
            HotkeyAction::WorkshopClearSession,
            HotkeyAction::WorkshopRetry,
            HotkeyAction::DisplaysRefresh,
            HotkeyAction::DisplaysRename,
            HotkeyAction::DisplaysLayout,
            HotkeyAction::StatusRefresh,
            HotkeyAction::PluginsRefresh,
            HotkeyAction::PluginsInstall,
            HotkeyAction::PluginsToggle,
            HotkeyAction::SettingsSave,
            HotkeyAction::SettingsResetTab,
        ]
    }
}
