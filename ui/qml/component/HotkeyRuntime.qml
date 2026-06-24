pragma ComponentBehavior: Bound
import QtCore
import QtQuick

// QML-only hotkey runtime.
//
// Stores bindings as JSON in QSettings under the "hotkeys" group so changes
// survive restarts and can be edited externally. Exposes:
//
//   * sequences(actionId)            — array of QKeySequence strings to feed
//                                      into a Shortcut.sequences binding.
//   * eventMatches(id, evt, opts)    — predicate for Keys.onPressed handlers
//                                      that need to react to a configured
//                                      action without going through Shortcut
//                                      (typical for grid navigation, where
//                                      the focus context differs).
//   * setBindings(map) / resetDefaults()
//
// Action ids cover three roles:
//
//   1. Top-level navigation         (open_wallpapers / open_displays / …)
//   2. Wallpaper grid actions       (refresh_scan / focus_search / cancel /
//                                    apply_wallpaper / toggle_selection /
//                                    select_all / toggle_filters)
//   3. Grid cursor movement         (navigate_*, jump_*, home, end, home_all,
//                                    end_all, page_up, page_down)
//
// `eventMatches` understands Cyrillic JCUKEN so WASD / HJKL bindings keep
// working when the user is typing in Russian.
QtObject {
    id: root

    // Defaults are intentionally aligned with the wwe-modify monolith so
    // user muscle memory transfers between forks without surprises.
    readonly property var defaults: ({
        "open_wallpapers": ["Ctrl+1"],
        "open_workshop": ["Ctrl+2"],
        "open_displays": ["Ctrl+3"],
        "open_status": ["Ctrl+4"],
        "open_plugins": ["Ctrl+5"],
        "open_settings": ["Ctrl+6"],
        "open_hotkeys": ["Ctrl+7", "Ctrl+,"],
        "reload_ui": ["Ctrl+Shift+R"],

        "refresh_scan": ["F5", "Ctrl+R"],
        "focus_search": ["Ctrl+F"],
        "apply_wallpaper": ["Return", "Enter"],
        "toggle_selection": ["Space"],
        "cancel": ["Delete", "Backspace", "Escape"],
        "select_all": ["Ctrl+Alt+A"],
        "toggle_filters": ["Ctrl+Shift+F"],
        "workshop_reload": ["F5", "Ctrl+R"],
        "workshop_clear_session": ["Ctrl+Shift+Delete"],
        "status_refresh": ["F5"],
        "settings_save": ["Ctrl+S"],

        "navigate_left": ["Left", "A"],
        "navigate_right": ["Right", "D"],
        "navigate_up": ["Up", "W"],
        "navigate_down": ["Down", "S"],
        "jump_left": ["Ctrl+Left", "Ctrl+A"],
        "jump_right": ["Ctrl+Right", "Ctrl+D"],
        "jump_up": ["Ctrl+Up", "Ctrl+W"],
        "jump_down": ["Ctrl+Down", "Ctrl+S"],

        "home": ["Home"],
        "end": ["End"],
        "home_all": ["Ctrl+Home"],
        "end_all": ["Ctrl+End"],
        "page_up": ["PageUp"],
        "page_down": ["PageDown"]
    })

    readonly property var labels: ({
        "open_wallpapers": qsTr("Open Wallpapers"),
        "open_workshop": qsTr("Open Workshop"),
        "open_displays": qsTr("Open Displays"),
        "open_status": qsTr("Open Status"),
        "open_plugins": qsTr("Open Plugins"),
        "open_settings": qsTr("Open Settings"),
        "open_hotkeys": qsTr("Open keyboard settings"),
        "reload_ui": qsTr("Reload current UI page"),

        "refresh_scan": qsTr("Refresh wallpapers"),
        "focus_search": qsTr("Focus search field"),
        "apply_wallpaper": qsTr("Apply / open selected wallpaper"),
        "toggle_selection": qsTr("Toggle wallpaper selection"),
        "cancel": qsTr("Cancel / clear selection"),
        "select_all": qsTr("Select all wallpapers"),
        "toggle_filters": qsTr("Toggle filters panel"),
        "workshop_reload": qsTr("Reload Workshop"),
        "workshop_clear_session": qsTr("Clear Workshop session"),
        "status_refresh": qsTr("Refresh status"),
        "settings_save": qsTr("Save settings"),

        "navigate_left": qsTr("Cursor left"),
        "navigate_right": qsTr("Cursor right"),
        "navigate_up": qsTr("Cursor up"),
        "navigate_down": qsTr("Cursor down"),
        "jump_left": qsTr("Jump to row start"),
        "jump_right": qsTr("Jump to row end"),
        "jump_up": qsTr("Jump page up by row"),
        "jump_down": qsTr("Jump page down by row"),

        "home": qsTr("First in row"),
        "end": qsTr("Last in row"),
        "home_all": qsTr("First wallpaper"),
        "end_all": qsTr("Last wallpaper"),
        "page_up": qsTr("Page up"),
        "page_down": qsTr("Page down")
    })

    readonly property var sections: ({
        "open_wallpapers": qsTr("Navigation"),
        "open_workshop": qsTr("Navigation"),
        "open_displays": qsTr("Navigation"),
        "open_status": qsTr("Navigation"),
        "open_plugins": qsTr("Navigation"),
        "open_settings": qsTr("Navigation"),
        "open_hotkeys": qsTr("Navigation"),
        "reload_ui": qsTr("Global"),

        "refresh_scan": qsTr("Wallpapers"),
        "focus_search": qsTr("Wallpapers"),
        "apply_wallpaper": qsTr("Wallpapers"),
        "toggle_selection": qsTr("Wallpapers"),
        "cancel": qsTr("Wallpapers"),
        "select_all": qsTr("Wallpapers"),
        "toggle_filters": qsTr("Wallpapers"),
        "workshop_reload": qsTr("Workshop"),
        "workshop_clear_session": qsTr("Workshop"),
        "status_refresh": qsTr("Status"),
        "settings_save": qsTr("Settings"),

        "navigate_left": qsTr("Grid"),
        "navigate_right": qsTr("Grid"),
        "navigate_up": qsTr("Grid"),
        "navigate_down": qsTr("Grid"),
        "jump_left": qsTr("Grid"),
        "jump_right": qsTr("Grid"),
        "jump_up": qsTr("Grid"),
        "jump_down": qsTr("Grid"),

        "home": qsTr("Grid"),
        "end": qsTr("Grid"),
        "home_all": qsTr("Grid"),
        "end_all": qsTr("Grid"),
        "page_up": qsTr("Grid"),
        "page_down": qsTr("Grid")
    })

    readonly property var actionIds: Object.keys(defaults)

    property Settings store: Settings {
        category: "hotkeys"
        property string bindingsJson: "{}"
    }

    function _customBindings() {
        try {
            const parsed = JSON.parse(store.bindingsJson || "{}");
            return parsed && typeof parsed === "object" ? parsed : {};
        } catch (e) {
            console.warn("invalid hotkey settings:", e);
            return {};
        }
    }

    function bindings() {
        const custom = _customBindings();
        const out = {};
        for (const id of actionIds) {
            const seqs = custom[id];
            out[id] = Array.isArray(seqs) ? seqs.slice() : defaults[id].slice();
        }
        return out;
    }

    function sequences(actionId) {
        const all = bindings();
        return all[actionId] || defaults[actionId] || [];
    }

    function setBindings(map) {
        const out = {};
        for (const id of actionIds) {
            const seqs = map[id];
            out[id] = Array.isArray(seqs)
                ? seqs.filter(s => String(s).trim().length > 0)
                : defaults[id].slice();
        }
        store.bindingsJson = JSON.stringify(out);
    }

    function resetDefaults() {
        store.bindingsJson = "{}";
    }

    // -------------------------------------------------------------
    // Manual event-matching helpers (for in-grid Keys.onPressed).
    // Kept compatible with the wwe-modify monolith.
    // -------------------------------------------------------------

    function eventMatches(actionId, event, options) {
        const seqs = root.sequences(actionId);
        for (let i = 0; i < seqs.length; ++i) {
            if (root.sequenceMatchesEvent(seqs[i], event, options))
                return true;
        }
        return false;
    }

    function sequenceMatchesEvent(seq, event, options) {
        const parsed = root.parseSequence(seq);
        if (!parsed)
            return false;
        if (!root.modifiersMatch(event, parsed, options || {}))
            return false;
        const candidates = root.eventKeyCandidates(event);
        return candidates[parsed.key] === true;
    }

    function modifiersMatch(event, parsed, options) {
        const hasCtrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const hasAlt = (event.modifiers & Qt.AltModifier) !== 0;
        const hasShift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const hasMeta = (event.modifiers & Qt.MetaModifier) !== 0;

        const needShift = options.extraShift === true ? true : parsed.shift;

        return hasCtrl === parsed.ctrl
            && hasAlt === parsed.alt
            && hasMeta === parsed.meta
            && hasShift === needShift;
    }

    function parseSequence(seq) {
        const text = String(seq || "").trim();
        if (text.length === 0)
            return null;

        const parts = text.split("+").map(function(part) {
            return String(part || "").trim();
        }).filter(function(part) {
            return part.length > 0;
        });
        if (parts.length === 0)
            return null;

        const out = {
            ctrl: false,
            alt: false,
            shift: false,
            meta: false,
            key: ""
        };

        for (let i = 0; i < parts.length; ++i) {
            const up = parts[i].toUpperCase();
            if (i < parts.length - 1) {
                if (up === "CTRL" || up === "CONTROL") {
                    out.ctrl = true;
                    continue;
                }
                if (up === "ALT") {
                    out.alt = true;
                    continue;
                }
                if (up === "SHIFT") {
                    out.shift = true;
                    continue;
                }
                if (up === "META" || up === "SUPER" || up === "WIN") {
                    out.meta = true;
                    continue;
                }
            }
            out.key = root.normalizeKeyName(parts.slice(i).join("+"));
            break;
        }

        if (out.key.length === 0)
            out.key = root.normalizeKeyName(parts[parts.length - 1]);
        return out;
    }

    function normalizeKeyName(name) {
        const up = String(name || "").trim().toUpperCase();
        switch (up) {
        case "ESC": return "ESCAPE";
        case "DEL": return "DELETE";
        case "PGUP": return "PAGEUP";
        case "PGDOWN": return "PAGEDOWN";
        case "INS": return "INSERT";
        default: return up;
        }
    }

    function eventKeyCandidates(event) {
        const out = {};
        function add(name) {
            const key = root.normalizeKeyName(name);
            if (key.length > 0)
                out[key] = true;
        }

        switch (event.key) {
        case Qt.Key_Space: add("Space"); break;
        case Qt.Key_Return: add("Return"); break;
        case Qt.Key_Enter: add("Enter"); break;
        case Qt.Key_Escape: add("Escape"); break;
        case Qt.Key_Tab: add("Tab"); break;
        case Qt.Key_Backspace: add("Backspace"); break;
        case Qt.Key_Delete: add("Delete"); break;
        case Qt.Key_Home: add("Home"); break;
        case Qt.Key_End: add("End"); break;
        case Qt.Key_PageUp: add("PageUp"); break;
        case Qt.Key_PageDown: add("PageDown"); break;
        case Qt.Key_Left: add("Left"); break;
        case Qt.Key_Right: add("Right"); break;
        case Qt.Key_Up: add("Up"); break;
        case Qt.Key_Down: add("Down"); break;
        case Qt.Key_F1: add("F1"); break;
        case Qt.Key_F2: add("F2"); break;
        case Qt.Key_F3: add("F3"); break;
        case Qt.Key_F4: add("F4"); break;
        case Qt.Key_F5: add("F5"); break;
        case Qt.Key_F6: add("F6"); break;
        case Qt.Key_F7: add("F7"); break;
        case Qt.Key_F8: add("F8"); break;
        case Qt.Key_F9: add("F9"); break;
        case Qt.Key_F10: add("F10"); break;
        case Qt.Key_F11: add("F11"); break;
        case Qt.Key_F12: add("F12"); break;
        }

        if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z)
            add(String.fromCharCode(event.key));
        if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9)
            add(String.fromCharCode(event.key));

        const text = String(event.text || "");
        if (text.length === 1) {
            add(text);
            const mapped = root.russianToLatinKey(text);
            if (mapped.length > 0)
                add(mapped);
        }

        return out;
    }

    function russianToLatinKey(char) {
        switch (String(char || "").toLowerCase()) {
        case "й": return "Q";
        case "ц": return "W";
        case "у": return "E";
        case "к": return "R";
        case "е": return "T";
        case "н": return "Y";
        case "г": return "U";
        case "ш": return "I";
        case "щ": return "O";
        case "з": return "P";
        case "ф": return "A";
        case "ы": return "S";
        case "в": return "D";
        case "а": return "F";
        case "п": return "G";
        case "р": return "H";
        case "о": return "J";
        case "л": return "K";
        case "д": return "L";
        case "я": return "Z";
        case "ч": return "X";
        case "с": return "C";
        case "м": return "V";
        case "и": return "B";
        case "т": return "N";
        case "ь": return "M";
        default: return "";
        }
    }
}
