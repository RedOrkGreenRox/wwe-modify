pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import waywallen.control as WC
import waywallen.ui as W
import Qcm.Material as MD

MD.Dialog {
    id: root
    title: qsTr("Filters")
    property var model
    property var supportedTypes: []
    horizontalPadding: 16
    implicitWidth: Math.min(440, parent ? parent.width - 48 : 440)
    standardButtons: T.Dialog.Cancel | T.Dialog.Reset | T.Dialog.Apply

    onApplied: {
        model.apply();
        accept();
    }
    onReset: model.reset()

    Component.onCompleted: {
        let button = standardButton(T.Dialog.Reset);
        if (button)
            button.enabled = Qt.binding(() => !!model && model.dirty);
        button = standardButton(T.Dialog.Apply);
        if (button)
            button.enabled = Qt.binding(() => !!model && model.dirty);
    }

    contentItem: ColumnLayout {
        RowLayout {
            MD.Label {
                Layout.fillWidth: true
                text: qsTr("Rules")
                typescale: MD.Token.typescale.title_medium
            }
            Row {
                spacing: 0
                MD.IconButton {
                    icon.name: MD.Token.icon.clear_all
                    onClicked: root.model.removeRows(0, root.model.rowCount())
                }
                MD.IconButton {
                    icon.name: MD.Token.icon.add
                    onClicked: root.model.appendNewGroup()
                }
            }
        }

        MD.VerticalListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: -16
            Layout.rightMargin: -16
            model: root.model
            delegate: W.WallpaperFilter {
                width: ListView.view.contentWidth
                supportedTypes: root.supportedTypes
            }
            implicitHeight: contentHeight
            spacing: 2
            leftMargin: 16
            rightMargin: 16

            section.property: "group"
            section.criteria: ViewSection.FullString
            section.delegate: RowLayout {
                id: sectionRow
                width: ListView.view.contentWidth
                spacing: 8
                required property string section
                readonly property int groupId: parseInt(section, 10)
                readonly property int sectionIndex: root.model ? root.model.sectionIndexForGroup(groupId) : -1
                readonly property int currentOp: root.model && sectionIndex > 0 ? root.model.logicOpAt(sectionIndex) : -1

                MD.Label {
                    Layout.fillWidth: true
                    text: qsTr("Group %1").arg(sectionRow.sectionIndex + 1)
                    typescale: MD.Token.typescale.label_medium
                }

                MD.SegmentedButtonGroup {
                    visible: sectionRow.sectionIndex > 0

                    MD.SegmentedButton {
                        mdState.size: MD.Enum.XS
                        text: qsTr("AND")
                        checked: sectionRow.currentOp !== WC.LogicOp.LOGIC_OP_OR
                        onClicked: root.model.setLogicOpAt(sectionRow.sectionIndex, WC.LogicOp.LOGIC_OP_AND)
                    }

                    MD.SegmentedButton {
                        mdState.size: MD.Enum.XS
                        text: qsTr("OR")
                        checked: sectionRow.currentOp === WC.LogicOp.LOGIC_OP_OR
                        onClicked: root.model.setLogicOpAt(sectionRow.sectionIndex, WC.LogicOp.LOGIC_OP_OR)
                    }
                }

                MD.SmallIconButton {
                    icon.name: MD.Token.icon.add
                    onClicked: root.model.appendRuleInGroup(sectionRow.groupId)
                }
                MD.SmallIconButton {
                    icon.name: MD.Token.icon.delete
                    onClicked: root.model.deleteGroup(sectionRow.groupId)
                }
            }
        }
    }
}
