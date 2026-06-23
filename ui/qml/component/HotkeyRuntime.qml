pragma ComponentBehavior: Bound
import QtQuick
import waywallen.ui as W

Item {
    id: root
    visible: false
    width: 0
    height: 0

    property var bindings: ({})

    W.SettingsGetQuery {
        id: settingsGet
        Component.onCompleted: reload()
    }

    Connections {
        target: settingsGet
        function onGlobalChanged() {
            root.rebuildBindings();
        }
    }

    Connections {
        target: W.Notify
        function onSettingsChanged() {
            settingsGet.reload();
        }
        function onDaemonReady() {
            settingsGet.reload();
        }
    }

    function rebuildBindings() {
        const global = settingsGet.global || {};
        const raw = global.hotkeyBindings || {};
        const next = {};
        for (const id in raw) {
            if (!Object.prototype.hasOwnProperty.call(raw, id))
                continue;
            const seqs = raw[id] && raw[id].sequences ? raw[id].sequences : [];
            if (seqs && seqs.length > 0)
                next[id] = seqs.slice();
        }
        root.bindings = next;
    }

    function sameSequenceSet(a, b) {
        const left = (a || []).slice().sort();
        const right = (b || []).slice().sort();
        if (left.length !== right.length)
            return false;
        for (let i = 0; i < left.length; ++i) {
            if (String(left[i]) !== String(right[i]))
                return false;
        }
        return true;
    }

    function upgradedLegacyDefaults(actionId, current) {
        // Migrate old persisted defaults to the newer defaults shipped by the app.
        // This keeps existing configs working after default hotkeys changed.
        const legacy = {
            "navigate_left": ["Left"],
            "navigate_right": ["Right"],
            "navigate_up": ["Up"],
            "navigate_down": ["Down"],
            "jump_left": ["Ctrl+Left"],
            "jump_right": ["Ctrl+Right"],
            "jump_up": ["Ctrl+Up"],
            "jump_down": ["Ctrl+Down"],
            "select_all": ["Ctrl+A"]
        };
        const oldSeqs = legacy[actionId];
        if (!oldSeqs)
            return null;
        if (!root.sameSequenceSet(current, oldSeqs))
            return null;
        const defaults = root.defaultSequences(actionId);
        return defaults.slice ? defaults.slice() : defaults;
    }

    function defaultSequences(actionId) {
        const m = {
            "open_wallpapers": ["Ctrl+1"],
            "open_workshop": ["Ctrl+2"],
            "open_displays": ["Ctrl+3"],
            "open_status": ["Ctrl+4"],
            "open_plugins": ["Ctrl+5"],
            "open_settings": ["Ctrl+6"],
            "open_hotkeys": ["Ctrl+7"],
            "reload_ui": ["Ctrl+Shift+R"],
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
            "page_down": ["PageDown"],
            "refresh_scan": ["F5", "Ctrl+R"],
            "focus_search": ["Ctrl+F"],
            "select_all": ["Ctrl+Alt+A"],
            "cancel": ["Delete", "Backspace", "Escape"],
            "apply_wallpaper": ["Enter", "Return"],
            "toggle_selection": ["Space"],
            "toggle_filters": ["Ctrl+Shift+F"],
            "workshop_reload": ["F5", "Ctrl+R"],
            "workshop_clear_session": ["Ctrl+Shift+Delete"],
            "status_refresh": ["F5"],
            "settings_save": ["Ctrl+S"]
        };
        const out = m[actionId] || [];
        return out.slice ? out.slice() : out;
    }

    function sequences(actionId) {
        const current = root.bindings[actionId];
        if (current && current.length > 0) {
            const upgraded = root.upgradedLegacyDefaults(actionId, current);
            return upgraded ? upgraded : current.slice();
        }
        const defaults = root.defaultSequences(actionId);
        return defaults.slice ? defaults.slice() : defaults;
    }

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
