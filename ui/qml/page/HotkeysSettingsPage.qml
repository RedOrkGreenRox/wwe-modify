pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtQuick
import QtQml as Qml
import QtQuick.Layouts
import Qcm.Material as MD
import waywallen.control as WC
import waywallen.ui as W

import "../component/HotkeyActionCatalog.qml" as HKCat

MD.Page {
    id: root

    padding: 0
    showHeader: true
    showBackground: false
    title: qsTr("Keyboard")
    scrolling: !m_flick.atYBeginning

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
        onDone: {
            if (settingsSet.status === 3) {
                W.Action.toast(qsTr("Failed to save hotkey settings"));
            } else {
                W.Action.toast(qsTr("Hotkey settings saved"));
            }
        }
    }

    // Local working copy of the bindings map. Changes flow through
    // `pendingBinding(actionId, index, value)` and `removeBinding(...)`.
    // On Reset-to-defaults we refill it from `HotkeyActionCatalog.defaultsByAction`.
    // On Save we push it into the daemon via settingsSet.
    property var pending: ({})

    function loadFromSettings() {
        const bindings = settingsGet.global.hotkeyBindings || {};
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
        // Qt.Key_* integer → portable string. We can't enumerate
        // every Qt key, so cover common cases and fall back to
        // QKeySequence-like "Key_<n>" so the daemon still parses it
        // through its normal pipeline.
        const map = {
            [Qt.Key_Space]: "Space",
            [Qt.Key_Return]: "Return",
            [Qt.Key_Enter]: "Enter",
            [Qt.Key_Escape]: "Escape",
            [Qt.Key_Tab]: "Tab",
            [Qt.Key_Backspace]: "Backspace",
            [Qt.Key_Delete]: "Delete",
            [Qt.Key_Home]: "Home",
            [Qt.Key_End]: "End",
            [Qt.Key_PageUp]: "PageUp",
            [Qt.Key_PageDown]: "PageDown",
            [Qt.Key_Left]: "Left",
            [Qt.Key_Right]: "Right",
            [Qt.Key_Up]: "Up",
            [Qt.Key_Down]: "Down",
            [Qt.Key_F1]: "F1", [Qt.Key_F2]: "F2", [Qt.Key_F3]: "F3",
            [Qt.Key_F4]: "F4", [Qt.Key_F5]: "F5", [Qt.Key_F6]: "F6",
            [Qt.Key_F7]: "F7", [Qt.Key_F8]: "F8", [Qt.Key_F9]: "F9",
            [Qt.Key_F10]: "F10", [Qt.Key_F11]: "F11", [Qt.Key_F12]: "F12",
        };
        return map[key] || ("Key_" + key);
    }

    // -------------------------------------------------------------
    // Save flow
    // -------------------------------------------------------------

    function resetToDefaults() {
        const next = {};
        const defs = HKCat.HotkeyActionCatalog.defaultsByAction;
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

    MD.Flickable {
        id: m_flick
        anchors.fill: parent
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
                        mdState.type: MD.Enum.BtTonal
                        onClicked: root.resetToDefaults()
                    }
                    Item { Layout.fillWidth: true }
                    MD.Button {
                        text: qsTr("Save")
                        icon.name: MD.Token.icon.check
                        mdState.type: MD.Enum.BtFilled
                        busy: settingsSet.querying
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
                model: HKCat.HotkeyActionCatalog.sections

                delegate: ColumnLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    spacing: 4

                    // Section title
                    MD.Text {
                        Layout.fillWidth: true
                        Layout.leftMargin: 16
                        Layout.rightMargin: 16
                        Layout.topMargin: 16
                        text: modelData
                        typescale: MD.Token.typescale.title_small
                        color: MD.Token.color.on_surface_variant
                    }

                    // Action rows in this section
                    Repeater {
                        model: HKCat.HotkeyActionCatalog.itemsInSection(modelData)
                        delegate: HotkeyActionRow {
                            width: parent.width
                            actionId: modelData.id
                            actionLabel: modelData.label
                            defaultSequences: modelData.defaults
                            pendingFor: root.pendingFor(modelData.id)
                            isCapturing: root.m_captureFor === modelData.id
                            captureBuffer: root.m_captureBuffer
                            actionsUsing: function(seq) { return root.actionsUsing(seq); }
                            onStartCapture: id => root.startCapture(id)
                            onStopCapture: root.stopCapture
                            onCommitCapture: root.commitCapture
                            onRemoveBindingAt: (idx) => root.removeBindingAt(modelData.id, idx)
                            onAddBinding: seq => root.addBinding(modelData.id, seq)
                            onClearAction: () => root.setPendingFor(modelData.id, [])
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
