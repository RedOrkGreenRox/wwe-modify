pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Qcm.Material as MD
import waywallen.ui as W

import "../component" as HK

// Editor for the QML hotkey runtime. Bindings are edited as comma-separated
// QKeySequence strings (e.g. "Ctrl+R, F5"). The page groups actions by
// `HotkeyRuntime.sections` so the user can find what they want quickly.
MD.Page {
    id: root
    title: qsTr("Keyboard shortcuts")

    HK.HotkeyRuntime {
        id: hotkeys
    }

    property var draft: ({})

    Component.onCompleted: root.draft = hotkeys.bindings()

    function parseSequences(text) {
        return String(text || "")
            .split(",")
            .map(s => s.trim())
            .filter(s => s.length > 0);
    }

    function save() {
        hotkeys.setBindings(root.draft);
        W.Action.toast(qsTr("Keyboard shortcuts saved"));
    }

    // Group action ids by their section so the list reads as
    // "Navigation / Global / Wallpapers / Grid".
    readonly property var groupedSections: {
        const order = [];
        const byName = {};
        for (const id of hotkeys.actionIds) {
            const sec = hotkeys.sections[id] || qsTr("Other");
            if (!byName[sec]) {
                byName[sec] = [];
                order.push(sec);
            }
            byName[sec].push(id);
        }
        return order.map(name => ({ name, ids: byName[name] }));
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: m_layout.implicitHeight
        clip: true

        ColumnLayout {
            id: m_layout
            width: parent.width
            spacing: 16
            anchors.margins: 24

            MD.Text {
                Layout.fillWidth: true
                text: qsTr("Edit shortcuts as comma-separated Qt key sequences, for example: Ctrl+R, F5")
                typescale: MD.Token.typescale.body_medium
                color: MD.Token.color.on_surface_variant
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: root.groupedSections

                delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 6

                    MD.Text {
                        text: modelData.name
                        typescale: MD.Token.typescale.title_small
                        color: MD.Token.color.primary
                        Layout.topMargin: 8
                    }

                    Repeater {
                        model: modelData.ids

                        delegate: RowLayout {
                            required property string modelData
                            Layout.fillWidth: true
                            spacing: 12

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                MD.Text {
                                    text: hotkeys.labels[modelData] || modelData
                                    typescale: MD.Token.typescale.body_medium
                                }
                                MD.Text {
                                    text: (hotkeys.defaults[modelData] || []).join(", ")
                                    typescale: MD.Token.typescale.label_small
                                    color: MD.Token.color.on_surface_variant
                                    opacity: 0.6
                                }
                            }

                            MD.TextField {
                                Layout.preferredWidth: 260
                                mdState.dense: true
                                text: (root.draft[modelData] || []).join(", ")
                                onEditingFinished: {
                                    const next = Object.assign({}, root.draft);
                                    next[modelData] = root.parseSequences(text);
                                    root.draft = next;
                                }
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                Layout.topMargin: 16
                spacing: 8
                MD.Button {
                    text: qsTr("Reset to defaults")
                    onClicked: {
                        hotkeys.resetDefaults();
                        root.draft = hotkeys.bindings();
                    }
                }
                MD.Button {
                    text: qsTr("Save")
                    mdState.type: MD.Enum.BtFilled
                    onClicked: root.save()
                }
            }
        }
    }
}
