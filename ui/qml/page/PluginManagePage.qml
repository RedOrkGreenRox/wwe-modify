pragma ValueTypeBehavior: Assertable
import QtQuick
import QtQuick.Layouts
import Qcm.Material as MD
import waywallen.ui as W

MD.Page {
    id: root
    title: 'Plugins'
    scrolling: !m_flick.atYBeginning

    actions: [
        MD.Action {
            icon.name: MD.Token.icon.add
            text: qsTr("Install from .zip")
            enabled: !installQuery.querying
            onTriggered: zipDialog.open()
        }
    ]

    W.PluginListQuery {
        id: pluginListQuery
    }

    W.PluginInstallQuery {
        id: installQuery
    }

    Connections {
        target: W.Notify
        function onDaemonReady() {
            pluginListQuery.reload();
        }
    }

    Connections {
        target: installQuery
        function onInstalled(pluginId, needsRestart) {
            W.Action.toast(needsRestart
                ? qsTr("Installed \"%1\" — restart waywallen to load it").arg(pluginId)
                : qsTr("Installed \"%1\"").arg(pluginId));
            pluginListQuery.reload();
        }
    }

    Component.onCompleted: {
        if (W.Notify.daemonPhase === W.Notify.DaemonPhase.Ready)
            pluginListQuery.reload();
    }

    Shortcut {
        sequences: [StandardKey.Refresh, "F5", "Ctrl+R"]
        context: Qt.WidgetWithChildrenShortcut
        enabled: root.visible && !installQuery.querying
        onActivated: pluginListQuery.reload()
    }

    MD.FileDialog {
        id: zipDialog
        title: qsTr("Choose plugin package")
        fileMode: MD.FileDialog.OpenFile
        nameFilters: ["Plugin package (*.zip)", "All files (*)"]
        onAccepted: {
            installQuery.zipPath = selectedFile.toString().replace(/^file:\/\//, "");
            installQuery.reload();
        }
    }

    contentItem: MD.VerticalFlickable {
        id: m_flick
        topMargin: 4
        leftMargin: 12
        rightMargin: 12
        bottomMargin: 12

        ColumnLayout {
            width: m_flick.contentWidth
            spacing: 8

            MD.Text {
                Layout.fillWidth: true
                visible: !pluginListQuery.plugins || pluginListQuery.plugins.length === 0
                text: "No plugins installed"
                typescale: MD.Token.typescale.body_medium
                color: MD.Token.color.on_surface_variant
                wrapMode: Text.WordWrap
            }

            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: contentHeight
                implicitHeight: contentHeight
                interactive: false
                spacing: 4

                model: pluginListQuery.plugins

                delegate: MD.ListItem {
                    id: pluginItem
                    required property var modelData

                    width: ListView.view.width
                    radius: 12
                    mdState.backgroundColor: MD.Token.color.surface_container
                    text: modelData.name || modelData.id || ""
                    supportText: modelData.id
                    leader: MD.Icon {
                        name: MD.Token.icon.extension
                        size: 24
                        color: MD.Token.color.on_surface_variant
                    }
                    trailing: RowLayout {
                        spacing: 6
                        W.Tag {
                            Layout.alignment: Qt.AlignVCenter
                            visible: pluginItem.modelData.system === true
                            text: qsTr("system")
                            bgColor: MD.Token.color.tertiary_container
                            fgColor: MD.Token.color.on_tertiary_container
                        }
                        W.Tag {
                            Layout.alignment: Qt.AlignVCenter
                            text: "v" + (pluginItem.modelData.version || "0.0.0")
                        }
                    }
                    below: Flow {
                        spacing: 6
                        bottomPadding: 8
                        Repeater {
                            model: pluginItem.modelData.renderers
                            delegate: W.Tag {
                                required property var modelData
                                text: modelData.name || ""
                            }
                        }
                    }
                }
            }
        }
    }
}
