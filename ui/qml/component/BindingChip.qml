pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Qcm.Material as MD

// One chip representing a single keybinding for an action. Highlights
// red when another action uses the same sequence.
MD.Pane {
    id: root

    property string sequence
    property var conflicts: []  // other action ids sharing this sequence
    signal remove()

    radius: 12
    padding: 4
    showBackground: true
    backgroundColor: conflicts.length > 0
        ? MD.Token.color.error_container
        : MD.Token.color.secondary_container

    contentItem: RowLayout {
        spacing: 4

        MD.Text {
            text: root.sequence
            color: root.conflicts.length > 0
                ? MD.Token.color.on_error_container
                : MD.Token.color.on_secondary_container
            typescale: MD.Token.typescale.label_medium
            font.family: "monospace"
        }
        MD.IconButton {
            icon.name: MD.Token.icon.close
            icon.width: 14
            icon.height: 14
            padding: 0
            topInset: 0
            bottomInset: 0
            leftInset: 0
            rightInset: 0
            background.implicitWidth: 18
            background.implicitHeight: 18
            onClicked: root.remove()
        }
    }

    ToolTip.visible: conflicts.length > 0 && m_hover.containsMouse
    ToolTip.text: root.conflicts.length === 0
        ? ""
        : qsTr("Conflict — also used by: %1").arg(root.conflicts.join(", "))

    HoverHandler {
        id: m_hover
    }
}
