pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    property var entries: []

    property var m_pendingRemove: ({})

    signal back
    signal addRequested
    signal infoRequested(var entryId)

    function pendingList() {
        var out = [];
        for (var k in root.m_pendingRemove)
            out.push(root.m_pendingRemove[k]);
        return out;
    }

    function clearPending() { root.m_pendingRemove = ({}); }

    function markRemove(id) {
        var next = Object.assign({}, root.m_pendingRemove);
        next[String(id)] = id;
        root.m_pendingRemove = next;
    }

    function unmarkRemove(id) {
        var next = Object.assign({}, root.m_pendingRemove);
        delete next[String(id)];
        root.m_pendingRemove = next;
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4

            MD.IconButton {
                action: MD.Action {
                    icon.name: MD.Token.icon.arrow_back
                    onTriggered: root.back()
                }
            }

            MD.Text {
                text: qsTr("Wallpapers")
                typescale: MD.Token.typescale.title_medium
                color: MD.Token.color.on_surface
            }

            Item { Layout.fillWidth: true }

            MD.IconButton {
                action: MD.Action {
                    icon.name: MD.Token.icon.add_photo_alternate
                    onTriggered: root.addRequested()
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            MD.Text {
                anchors.centerIn: parent
                visible: (root.entries || []).length === 0
                text: qsTr("No wallpapers found")
                typescale: MD.Token.typescale.body_large
                color: MD.Token.color.on_surface_variant
            }

            MD.VerticalGridView {
                id: grid
                anchors.fill: parent
                visible: (root.entries || []).length > 0
                clip: true
                cacheBuffer: 200
                topMargin: 2
                bottomMargin: 4
                leftMargin: 4
                rightMargin: 4
                model: root.entries

                readonly property int _cols: Math.max(1, Math.floor(width / 130))
                cellWidth: Math.floor((width - leftMargin - rightMargin) / _cols)
                cellHeight: cellWidth

                delegate: Item {
                    id: cell
                    required property var modelData
                    required property int index
                    width: GridView.view ? GridView.view.cellWidth : 0
                    height: GridView.view ? GridView.view.cellHeight : 0

                    readonly property bool pending: root.m_pendingRemove[String(cell.modelData.id)] !== undefined
                    readonly property string m_id: String(cell.modelData.id)

                    W.WallpaperGetQuery {
                        id: wq
                        wallpaperId: cell.m_id
                    }
                    readonly property var wp: wq.wallpaper

                    HoverHandler { id: hh }

                    Rectangle {
                        id: card
                        anchors.fill: parent
                        anchors.margins: 4
                        radius: MD.Token.shape.corner.small
                        color: MD.Token.color.surface_container
                        clip: true

                        W.ThumbnailImage {
                            id: thumb
                            anchors.fill: parent
                            visible: (cell.wp?.preview ?? "") !== ""
                                || (cell.wp?.resource ?? "") !== ""
                            source: cell.wp?.preview ?? ""
                            resource: cell.wp?.resource ?? ""
                            wpType: ""
                            fillMode: Image.PreserveAspectCrop
                        }

                        MD.Icon {
                            anchors.centerIn: parent
                            visible: !thumb.visible
                            name: MD.Token.icon.hide_image
                            size: 28
                            color: MD.Token.color.on_surface_variant
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: "#000000"
                            opacity: 0.55
                            visible: cell.pending && thumb.visible
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: Math.max(0, parent.height - cellName.y)
                            visible: (cell.wp?.name ?? "") !== ""
                            radius: MD.Token.shape.corner.small
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "transparent" }
                                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
                            }
                        }

                        MD.Text {
                            id: cellName
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 4
                            leftPadding: 6
                            rightPadding: 6
                            text: cell.wp?.name ?? ""
                            typescale: MD.Token.typescale.label_small
                            color: "white"
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!cell.pending)
                                    root.infoRequested(cell.modelData.id);
                            }
                        }

                        Rectangle {
                            id: removeBtn
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: 6
                            width: 26
                            height: 26
                            radius: 4
                            readonly property bool shown: hh.hovered || cell.pending
                            visible: opacity > 0.01
                            opacity: shown ? 1 : 0
                            color: cell.pending ? "#E8CF35" : "#1f2020"

                            transform: Translate {
                                y: removeBtn.shown ? 0 : -16
                                Behavior on y {
                                    NumberAnimation { duration: 220; easing.type: Easing.OutBack }
                                }
                            }
                            Behavior on opacity {
                                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                            }

                            MD.Icon {
                                anchors.centerIn: parent
                                visible: !cell.pending
                                name: MD.Token.icon.close
                                size: 22
                                color: "#e53935"
                            }

                            Text {
                                anchors.centerIn: parent
                                visible: cell.pending
                                text: "↩"
                                font.pixelSize: 18
                                color: "#222222"
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (cell.pending)
                                        root.unmarkRemove(cell.modelData.id);
                                    else
                                        root.markRemove(cell.modelData.id);
                                }
                            }
                        }

                    }
                }
            }
        }
    }
}
