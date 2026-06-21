pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Qcm.Material as MD

// One row in the HotkeysSettingsPage. Lists an action and its current
// bindings; provides buttons to Record (capture a new combo), add a
// free-text sequence, remove individual bindings, or clear the
// action entirely.
Rectangle {
    id: root

    property string actionId
    property string actionLabel
    property var defaultSequences
    property var pendingFor
    property bool isCapturing
    property string captureBuffer
    property var actionsUsing: function(seq) { return []; }

    signal startCapture(string id)
    signal stopCapture()
    signal commitCapture()
    signal removeBindingAt(int index)
    signal addBinding(string seq)
    signal clearAction()

    implicitHeight: 64
    Layout.preferredHeight: implicitHeight
    Layout.fillWidth: true
    Layout.leftMargin: 16
    Layout.rightMargin: 16
    Layout.bottomMargin: 4
    color: "transparent"

    RowLayout {
        anchors.fill: parent
        spacing: 12

        // ----- Label -----
        MD.Text {
            Layout.preferredWidth: 240
            Layout.alignment: Qt.AlignVCenter
            text: root.actionLabel
            typescale: MD.Token.typescale.body_large
            elide: Text.ElideRight
        }

        // ----- Binding chips -----
        Flow {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 6

            Repeater {
                model: root.pendingFor
                delegate: BindingChip {
                    sequence: modelData
                    conflicts: root.actionsUsing(modelData).filter(
                        function(otherId) { return otherId !== root.actionId; }
                    )
                    onRemove: root.removeBindingAt(index)
                }
            }

            // Empty-state hint when no bindings yet.
            MD.Text {
                visible: root.pendingFor.length === 0
                text: qsTr("No binding")
                typescale: MD.Token.typescale.body_medium
                color: MD.Token.color.on_surface_variant
                font.italic: true
            }

            // Capture-mode prompt.
            MD.Pane {
                visible: root.isCapturing
                radius: 16
                padding: 6
                showBackground: true
                backgroundColor: MD.Token.color.primary_container
                contentItem: MD.Text {
                    text: root.captureBuffer || qsTr("Press a key…")
                    color: MD.Token.color.on_primary_container
                    typescale: MD.Token.typescale.label_large
                    font.bold: true
                }
            }
        }

        // ----- Action buttons -----
        RowLayout {
            Layout.alignment: Qt.AlignVCenter
            spacing: 4

            MD.IconButton {
                visible: !root.isCapturing
                icon.name: MD.Token.icon.keyboard
                tooltip: qsTr("Record key combination")
                onClicked: root.startCapture(root.actionId)
            }
            MD.IconButton {
                visible: root.isCapturing
                icon.name: MD.Token.icon.close
                tooltip: qsTr("Cancel recording")
                onClicked: root.stopCapture()
            }
            MD.IconButton {
                icon.name: MD.Token.icon.delete_outline
                tooltip: qsTr("Clear all bindings for this action")
                enabled: root.pendingFor.length > 0
                onClicked: root.clearAction()
            }
            MD.IconButton {
                icon.name: MD.Token.icon.add
                tooltip: qsTr("Add a manual binding (e.g. Ctrl+Alt+R)")
                onClicked: {
                    // Focus the inline text input on the next paint.
                    m_add_field.visible = true;
                    m_add_field.forceActiveFocus();
                    m_add_field.selectAll();
                }
            }
        }
    }

    // Inline text input for free-form bindings (e.g. user types "Ctrl+Alt+R"
    // instead of pressing it). Hidden by default; pops up when the
    // "+" button is clicked.
    MD.TextField {
        id: m_add_field
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 16
        visible: false
        width: 200
        placeholderText: qsTr("e.g. Ctrl+Alt+R")
        onAccepted: {
            const t = text.trim();
            if (t.length > 0) {
                root.addBinding(t);
                text = "";
                visible = false;
            }
        }
        onActiveFocusChanged: {
            if (!activeFocus && text.length === 0) visible = false;
        }
    }
}
