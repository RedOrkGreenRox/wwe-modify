pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtQuick
import QtQml as Qml
import QtQuick.Layouts
import Qcm.Material as MD
import waywallen.control as WC
import waywallen.ui as W

import "../component" as HK

MD.Page {
    id: root

    padding: 0
    showHeader: true
    showBackground: false
    title: qsTr("Keyboard")
    scrolling: !m_flick.atYBeginning

    HK.HotkeyActionCatalog {
        id: hotkeyCatalog
    }

    // -------------------------------------------------------------
    // Settings pipeline (reuses the existing SettingsGet/Set RPC).
    // We piggy-back on the global settings because hotkey bindings
    // are global; per-plugin keymaps would warrant a separate
    // proto field but the user only asked for global hotkeys.
    // -------------------------------------------------------------

    W.SettingsGetQuery {
        id: settingsGet
        // Don't fire on global settings changes — we're already the
        // source of those writes via settingsSet, so a SettingsChanged
        // echo would clobber the local pending state.
        Component.onCompleted: reload()
    }

    W.SettingsSetQuery {
        id: settingsSet
        // Query status values used elsewhere in the UI:
        // 2 = Finished, 3 = Error.
        onStatusChanged: {
            if (status === 2) {
                W.Action.toast(qsTr("Hotkey settings saved"));
            } else if (status === 3) {
                W.Action.toast(qsTr("Failed to save hotkey settings"));
            }
        }
    }

    // Local working copy of the bindings map. Changes flow through
    // `pendingBinding(actionId, index, value)` and `removeBinding(...)`.
    // On Reset-to-defaults we refill it from `HotkeyActionCatalog.defaultsByAction`.
    // On Save we push it into the daemon via settingsSet.
    property var pending: ({})

    function loadFromSettings() {
        const global = settingsGet.global || {};
        const bindings = global.hotkeyBindings || {};
        const next = {};
        for (const id in bindings) {
            if (!Object.prototype.hasOwnProperty.call(bindings, id)) continue;
            const seqs = bindings[id].sequences || [];
            next[id] = seqs.slice();
        }
        root.pending = next;
    }

    onVisibleChanged: {
        if (visible) loadFromSettings();
    }

    Connections {
        target: settingsGet
        function onGlobalChanged() {
            // Only refresh from daemon on the *initial* load. After
            // that, the local `pending` is the source of truth until
            // the user hits Save.
            if (Object.keys(root.pending).length === 0) {
                root.loadFromSettings();
            }
        }
    }

    function pendingFor(id) {
        return root.pending[id] || [];
    }

    function setPendingFor(id, seqs) {
        const next = Object.assign({}, root.pending);
        if (!seqs || seqs.length === 0) {
            delete next[id];
        } else {
            next[id] = seqs.slice();
        }
        root.pending = next;
    }

    function removeBindingAt(id, index) {
        const cur = root.pendingFor(id).slice();
        if (index < 0 || index >= cur.length) return;
        cur.splice(index, 1);
        root.setPendingFor(id, cur);
    }

    function addBinding(id, seq) {
        if (!seq || seq.length === 0) return;
        const cur = root.pendingFor(id).slice();
        // Insertion sort by display label so the list stays tidy.
        let pos = cur.length;
        for (let i = 0; i < cur.length; ++i) {
            if (cur[i] > seq) { pos = i; break; }
        }
        cur.splice(pos, 0, seq);
        root.setPendingFor(id, cur);
    }

    function actionsUsing(seq) {
        const hits = [];
        for (const id in root.pending) {
            if (!Object.prototype.hasOwnProperty.call(root.pending, id)) continue;
            if (root.pending[id].indexOf(seq) >= 0) hits.push(id);
        }
        return hits;
    }

    // -------------------------------------------------------------
    // Capture mode
    //
    // `m_captureFor` is the action id currently listening for a key
    // combo. While set, every key press turns into a candidate
    // sequence. The user hits Escape or clicks "Cancel" to abort.
    // Hitting Enter / Return commits the captured combo.
    // -------------------------------------------------------------

    property string m_captureFor: ""
    property string m_captureBuffer: ""  // pretty "Ctrl+Shift+F5"
    property var m_captureModifiers: ({})
    property int m_captureKey: 0

    function startCapture(actionId) {
        root.m_captureFor = actionId;
        root.m_captureBuffer = qsTr("Press a key combination…");
        root.m_captureModifiers = ({});
        root.m_captureKey = 0;
    }

    function stopCapture() {
        root.m_captureFor = "";
        root.m_captureBuffer = "";
    }

    function commitCapture() {
        if (!root.m_captureFor || !root.m_captureKey) {
            root.stopCapture();
            return;
        }
        const seq = root.m_captureBuffer;
        if (seq && seq.length > 0) {
            root.addBinding(root.m_captureFor, seq);
        }
        root.stopCapture();
    }

    function handleCaptureKey(event) {
        if (!root.m_captureFor) return false;
        // Cancel without commit.
        if (event.key === Qt.Key_Escape) {
            root.stopCapture();
            event.accepted = true;
            return true;
        }
        // Plain modifier presses don't count as a combo.
        if ([Qt.Key_Control, Qt.Key_Shift, Qt.Key_Alt, Qt.Key_Meta].indexOf(event.key) >= 0) {
            event.accepted = true;
            return true;
        }
        root.m_captureKey = event.key;
        const parts = [];
        const mods = {
            ctrl: (event.modifiers & Qt.ControlModifier) !== 0,
            shift: (event.modifiers & Qt.ShiftModifier) !== 0,
            alt: (event.modifiers & Qt.AltModifier) !== 0,
            meta: (event.modifiers & Qt.MetaModifier) !== 0,
        };
        if (mods.ctrl) parts.push("Ctrl");
        if (mods.alt) parts.push("Alt");
        if (mods.shift) parts.push("Shift");
        if (mods.meta) parts.push("Meta");
        parts.push(prettyKeyName(event.key));
        root.m_captureBuffer = parts.join("+");
        // Auto-commit on the first non-modifier keypress.
        root.commitCapture();
        event.accepted = true;
        return true;
    }

    function prettyKeyName(key) {
        // Qt.Key_* integer → portable string. Keep this as a plain switch:
        // older Qt/QML parsers used by AppImage builds can be picky about
        // JavaScript computed object-property names in QML files.
        switch (key) {
        case Qt.Key_Space: return "Space";
        case Qt.Key_Return: return "Return";
        case Qt.Key_Enter: return "Enter";
        case Qt.Key_Escape: return "Escape";
        case Qt.Key_Tab: return "Tab";
        case Qt.Key_Backspace: return "Backspace";
        case Qt.Key_Delete: return "Delete";
        case Qt.Key_Home: return "Home";
        case Qt.Key_End: return "End";
        case Qt.Key_PageUp: return "PageUp";
        case Qt.Key_PageDown: return "PageDown";
        case Qt.Key_Left: return "Left";
        case Qt.Key_Right: return "Right";
        case Qt.Key_Up: return "Up";
        case Qt.Key_Down: return "Down";
        case Qt.Key_F1: return "F1";
        case Qt.Key_F2: return "F2";
        case Qt.Key_F3: return "F3";
        case Qt.Key_F4: return "F4";
        case Qt.Key_F5: return "F5";
        case Qt.Key_F6: return "F6";
        case Qt.Key_F7: return "F7";
        case Qt.Key_F8: return "F8";
        case Qt.Key_F9: return "F9";
        case Qt.Key_F10: return "F10";
        case Qt.Key_F11: return "F11";
        case Qt.Key_F12: return "F12";
        default: return "Key_" + key;
        }
    }

    // -------------------------------------------------------------
    // Save flow
    // -------------------------------------------------------------

    function resetToDefaults() {
        const next = {};
        const defs = hotkeyCatalog.defaultsByAction;
        for (const id in defs) {
            if (!Object.prototype.hasOwnProperty.call(defs, id)) continue;
            const seqs = defs[id];
            if (seqs && seqs.length > 0) next[id] = seqs.slice();
        }
        root.pending = next;
    }

    function save() {
        // Snapshot current global settings, then merge hotkeyBindings.
        const global = settingsGet.global || {};
        const nextGlobal = Object.assign({}, global);
        // The proto uses map<string, HotkeyBinding> where HotkeyBinding
        // has { sequences: [string] }. The QML side mirrors that as
        // an object map id → { sequences: [...] }.
        const out = {};
        for (const id in root.pending) {
            if (!Object.prototype.hasOwnProperty.call(root.pending, id)) continue;
            const seqs = root.pending[id];
            if (seqs && seqs.length > 0) {
                out[id] = { sequences: seqs.slice() };
            }
        }
        nextGlobal.hotkeyBindings = out;
        // Pass the full global snapshot so unrelated fields stay intact.
        settingsSet.global = nextGlobal;
        settingsSet.plugins = settingsGet.plugins || {};
        settingsSet.reload();
        // After save, refresh from the daemon (the SettingsChanged
        // event will arrive a moment later, so the UI stays consistent).
        W.Notify.settingsChanged.connect(function onAfterSave() {
            W.Notify.settingsChanged.disconnect(onAfterSave);
            settingsGet.reload();
        });
    }

    // -------------------------------------------------------------
    // UI
    // -------------------------------------------------------------

    contentItem: MD.Flickable {
        id: m_flick
        implicitHeight: Math.min(contentHeight, 640)
        contentWidth: width
        contentHeight: m_col.implicitHeight
        clip: true

        ColumnLayout {
            id: m_col
            width: parent.width
            spacing: 0

            // Toolbar
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                Layout.leftMargin: 16
                Layout.rightMargin: 16

                RowLayout {
                    anchors.fill: parent
                    spacing: 8

                    MD.Button {
                        text: qsTr("Reset to defaults")
                        icon.name: MD.Token.icon.restart_alt
                        mdState.type: MD.Enum.BtFilledTonal
                        onClicked: root.resetToDefaults()
                    }
                    Item { Layout.fillWidth: true }
                    MD.Button {
                        text: qsTr("Save")
                        icon.name: MD.Token.icon.check
                        mdState.type: MD.Enum.BtFilled
                        enabled: !settingsSet.querying
                        onClicked: root.save()
                    }
                }
            }

            // Hint
            MD.Text {
                Layout.fillWidth: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.topMargin: 8
                Layout.bottomMargin: 8
                typescale: MD.Token.typescale.body_medium
                color: MD.Token.color.on_surface_variant
                wrapMode: Text.WordWrap
                text: qsTr("Each action can have any number of bindings. "
                         + "Click Record then press the desired key combination — modifiers and the key are captured together. "
                         + "Conflicts (the same combination on multiple actions) are highlighted in red but can still be saved.")
            }

            Repeater {
                model: hotkeyCatalog.sections

                delegate: ColumnLayout {
                    required property var modelData
                    readonly property string sectionName: String(modelData || "")

                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    spacing: 4

                    // Section title
                    MD.Text {
                        Layout.fillWidth: true
                        Layout.leftMargin: 16
                        Layout.rightMargin: 16
                        Layout.topMargin: 16
                        text: sectionName
                        typescale: MD.Token.typescale.title_small
                        color: MD.Token.color.on_surface_variant
                    }

                    // Action rows in this section
                    Repeater {
                        model: hotkeyCatalog.itemsInSection(sectionName)
                        delegate: HK.HotkeyActionRow {
                            required property var modelData
                            readonly property string actionIdValue: String((modelData && modelData.id) || "")

                            width: parent.width
                            actionId: actionIdValue
                            actionLabel: String((modelData && modelData.label) || "")
                            defaultSequences: (modelData && modelData.defaults) || []
                            pendingFor: root.pendingFor(actionIdValue)
                            isCapturing: root.m_captureFor === actionIdValue
                            captureBuffer: root.m_captureBuffer
                            actionsUsing: function(seq) { return root.actionsUsing(seq); }
                            onStartCapture: id => root.startCapture(id)
                            onStopCapture: root.stopCapture()
                            onCommitCapture: root.commitCapture()
                            onRemoveBindingAt: idx => root.removeBindingAt(actionIdValue, idx)
                            onAddBinding: seq => root.addBinding(actionIdValue, seq)
                            onClearAction: root.setPendingFor(actionIdValue, [])
                        }
                    }
                }
            }

            // Bottom spacer so the last row can scroll fully into view.
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 32
            }
        }
    }

    // Top-level key filter — only active when capture mode is on,
    // so we don't steal keystrokes from other UI elements.
    Item {
        anchors.fill: parent
        focus: root.m_captureFor.length > 0
        Keys.onPressed: event => {
            if (root.handleCaptureKey(event)) {
                // handled
            }
        }
    }
}
