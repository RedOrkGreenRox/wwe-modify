pragma ComponentBehavior: Bound
import QtQuick

// Static catalogue of every hotkey action the UI knows about.
// Mirrors `src/hotkeys.rs::HotkeyAction` — keep in sync.
// Each entry: { id, section, label, defaultSequences }
//
// `id` is the wire-format string from `HotkeyAction.as_str()`.
// `defaultSequences` is a fallback displayed when the settings
// query hasn't completed yet — once SettingsGet returns, the actual
// per-user binding list overrides it.
QtObject {
    id: catalog

    readonly property var all: [
        // ----- Global -----
        { id: "quit", section: qsTr("Global"), label: qsTr("Quit application"),
          defaults: ["Ctrl+Q"] },
        { id: "open_wallpapers", section: qsTr("Global"), label: qsTr("Open Wallpapers tab"),
          defaults: ["Ctrl+1"] },
        { id: "open_workshop", section: qsTr("Global"), label: qsTr("Open Workshop tab"),
          defaults: ["Ctrl+2"] },
        { id: "open_displays", section: qsTr("Global"), label: qsTr("Open Displays tab"),
          defaults: ["Ctrl+3"] },
        { id: "open_status", section: qsTr("Global"), label: qsTr("Open Status tab"),
          defaults: ["Ctrl+4"] },
        { id: "open_plugins", section: qsTr("Global"), label: qsTr("Open Plugins tab"),
          defaults: ["Ctrl+5"] },
        { id: "open_settings", section: qsTr("Global"), label: qsTr("Open Settings tab"),
          defaults: ["Ctrl+6"] },
        { id: "open_hotkeys", section: qsTr("Global"), label: qsTr("Open Hotkeys tab"),
          defaults: ["Ctrl+7"] },
        { id: "reload_ui", section: qsTr("Global"), label: qsTr("Reload UI"),
          defaults: ["Ctrl+Shift+R"] },
        { id: "cheatsheet", section: qsTr("Global"), label: qsTr("Toggle cheatsheet"),
          defaults: ["Ctrl+?"] },

        // ----- Wallpaper grid navigation -----
        { id: "navigate_left", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Navigate left"), defaults: ["Left"] },
        { id: "navigate_right", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Navigate right"), defaults: ["Right"] },
        { id: "navigate_up", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Navigate up"), defaults: ["Up"] },
        { id: "navigate_down", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Navigate down"), defaults: ["Down"] },
        { id: "jump_left", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Jump to row/col boundary (left)"), defaults: ["Ctrl+Left"] },
        { id: "jump_right", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Jump to row/col boundary (right)"), defaults: ["Ctrl+Right"] },
        { id: "jump_up", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Jump to row/col boundary (up)"), defaults: ["Ctrl+Up"] },
        { id: "jump_down", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Jump to row/col boundary (down)"), defaults: ["Ctrl+Down"] },
        { id: "home", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("First item in row"), defaults: ["Home"] },
        { id: "end", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Last item in row"), defaults: ["End"] },
        { id: "home_all", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("First item overall"), defaults: ["Ctrl+Home"] },
        { id: "end_all", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Last item overall"), defaults: ["Ctrl+End"] },
        { id: "page_up", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Page up"), defaults: ["PageUp"] },
        { id: "page_down", section: qsTr("Wallpaper grid navigation"),
          label: qsTr("Page down"), defaults: ["PageDown"] },

        // ----- Wallpaper actions -----
        { id: "refresh_scan", section: qsTr("Wallpaper actions"),
          label: qsTr("Refresh / rescan library"), defaults: ["F5", "Ctrl+R"] },
        { id: "focus_search", section: qsTr("Wallpaper actions"),
          label: qsTr("Focus search"), defaults: ["Ctrl+F"] },
        { id: "select_all", section: qsTr("Wallpaper actions"),
          label: qsTr("Select all wallpapers"), defaults: ["Ctrl+A"] },
        { id: "cancel", section: qsTr("Wallpaper actions"),
          label: qsTr("Cancel selection / close detail"),
          defaults: ["Delete", "Backspace", "Escape"] },
        { id: "apply_wallpaper", section: qsTr("Wallpaper actions"),
          label: qsTr("Apply focused wallpaper"),
          defaults: ["Enter", "Return"] },
        { id: "toggle_selection", section: qsTr("Wallpaper actions"),
          label: qsTr("Toggle selection of focused wallpaper"),
          defaults: ["Space"] },
        { id: "toggle_filters", section: qsTr("Wallpaper actions"),
          label: qsTr("Open filters dialog"),
          defaults: ["Ctrl+Shift+F"] },

        // ----- Workshop -----
        { id: "workshop_reload", section: qsTr("Workshop"),
          label: qsTr("Reload Workshop"), defaults: ["F5", "Ctrl+R"] },
        { id: "workshop_open_in_steam", section: qsTr("Workshop"),
          label: qsTr("Open current URL in Steam"), defaults: [] },
        { id: "workshop_open_in_browser", section: qsTr("Workshop"),
          label: qsTr("Open current URL in browser"), defaults: ["Ctrl+O"] },
        { id: "workshop_clear_session", section: qsTr("Workshop"),
          label: qsTr("Clear Workshop session"), defaults: ["Ctrl+Shift+Delete"] },
        { id: "workshop_retry", section: qsTr("Workshop"),
          label: qsTr("Retry Workshop load"), defaults: ["Ctrl+Shift+R"] },

        // ----- Displays -----
        { id: "displays_refresh", section: qsTr("Displays"),
          label: qsTr("Refresh displays"), defaults: ["F5"] },
        { id: "displays_rename", section: qsTr("Displays"),
          label: qsTr("Rename focused display"), defaults: ["F2"] },
        { id: "displays_layout", section: qsTr("Displays"),
          label: qsTr("Edit focused display layout"), defaults: ["F4"] },

        // ----- Status -----
        { id: "status_refresh", section: qsTr("Status"),
          label: qsTr("Refresh status"), defaults: ["F5"] },

        // ----- Plugins -----
        { id: "plugins_refresh", section: qsTr("Plugins"),
          label: qsTr("Refresh plugin list"), defaults: ["F5"] },
        { id: "plugins_install", section: qsTr("Plugins"),
          label: qsTr("Install plugin from zip"), defaults: ["Ctrl+I"] },
        { id: "plugins_toggle", section: qsTr("Plugins"),
          label: qsTr("Enable / disable focused plugin"), defaults: ["Space"] },

        // ----- Settings -----
        { id: "settings_save", section: qsTr("Settings"),
          label: qsTr("Save settings"), defaults: ["Ctrl+S"] },
        { id: "settings_reset_tab", section: qsTr("Settings"),
          label: qsTr("Reset current tab to defaults"), defaults: [] },
    ]

    /// Look up an action by id; returns null if not found.
    function find(id) {
        for (let i = 0; i < all.length; ++i) {
            if (all[i].id === id) return all[i];
        }
        return null;
    }

    /// Default bindings keyed by action id. Mirrors the Rust
    /// `default_bindings()` so the UI can show "Default: F5, Ctrl+R"
    /// when the user has cleared all custom bindings.
    readonly property var defaultsByAction: makeDefaultsByAction()

    /// Unique section labels in display order. Used to group the
    /// Repeater by section in the UI.
    readonly property var sections: makeSections()

    function makeDefaultsByAction() {
        const out = {};
        for (let i = 0; i < all.length; ++i) {
            out[all[i].id] = all[i].defaults;
        }
        return out;
    }

    function makeSections() {
        const seen = {};
        const out = [];
        for (let i = 0; i < all.length; ++i) {
            const s = all[i].section;
            if (!seen[s]) {
                seen[s] = true;
                out.push(s);
            }
        }
        return out;
    }

    /// Items filtered by section. Returns a new array (QML can't
    /// share array references across sections).
    function itemsInSection(section) {
        const out = [];
        for (let i = 0; i < all.length; ++i) {
            if (all[i].section === section) out.push(all[i]);
        }
        return out;
    }
}
