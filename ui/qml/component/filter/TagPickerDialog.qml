pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Qcm.Material as MD

// Multi-select tag picker. `selected` seeds the current selection on open;
// edits are pending until Apply, which emits `commit(newTags)`.
MD.Dialog {
    id: control

    property var allTags: []
    property var selected: []
    signal commit(var tags)

    title: qsTr("Select tags")
    parent: T.Overlay.overlay
    horizontalPadding: 16
    implicitWidth: Math.min(330, parent ? parent.width - 48 : 330)
    standardButtons: T.Dialog.Cancel | T.Dialog.Reset | T.Dialog.Apply

    property var pending: []
    function togglePending(tag) {
        const next = (control.pending || []).slice();
        const i = next.indexOf(tag);
        if (i >= 0)
            next.splice(i, 1);
        else
            next.push(tag);
        control.pending = next;
    }

    onAboutToShow: control.pending = (control.selected || []).slice()
    onApplied: {
        control.commit(control.pending);
        control.accept();
    }
    onReset: control.pending = (control.selected || []).slice()

    contentItem: MD.VerticalFlickable {
        id: tagFlick
        contentWidth: width
        contentHeight: m_col.implicitHeight
        implicitHeight: Math.min(m_col.implicitHeight, 360)

        ColumnLayout {
            id: m_col
            width: tagFlick.contentWidth
            spacing: 8

            MD.Text {
                Layout.fillWidth: true
                visible: !control.allTags || control.allTags.length === 0
                text: qsTr("No tags in library")
                typescale: MD.Token.typescale.body_medium
                color: MD.Token.color.on_surface_variant
                wrapMode: Text.WordWrap
            }

            Flow {
                Layout.fillWidth: true
                visible: control.allTags && control.allTags.length > 0
                spacing: 8
                Repeater {
                    model: control.allTags
                    delegate: MD.FilterChip {
                        required property var modelData
                        checkable: false
                        text: modelData
                        checked: (control.pending || []).indexOf(modelData) >= 0
                        onClicked: control.togglePending(modelData)
                    }
                }
            }
        }
    }
}
