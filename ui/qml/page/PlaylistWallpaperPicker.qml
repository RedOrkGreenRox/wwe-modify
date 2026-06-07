pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQml.Models
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    property var members: []
    property var memberEntries: []

    signal done(var ids)

    property var m_selected: ({})
    property var m_selectedEntries: []

    component SectionSep: RowLayout {
        property string title: ""
        Layout.fillWidth: true
        Layout.topMargin: 8
        Layout.bottomMargin: 4
        spacing: 10

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: MD.Token.color.outline_variant
        }
        MD.Text {
            text: title
            typescale: MD.Token.typescale.label_large
            color: MD.Token.color.on_surface_variant
            horizontalAlignment: Text.AlignHCenter
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: MD.Token.color.outline_variant
        }
    }
    property string m_searchText: ""

    readonly property var m_shownAdded: root.m_selectedEntries || []

    function isSelected(id) { return root.m_selected[String(id)] !== undefined; }

    function addSel(id) {
        if (root.isSelected(id)) return;
        var sel = Object.assign({}, root.m_selected);
        sel[String(id)] = id;
        root.m_selected = sel;
        var arr = (root.m_selectedEntries || []).slice();
        arr.push({ id: id });
        root.m_selectedEntries = arr;
    }

    function removeSel(id) {
        var sel = Object.assign({}, root.m_selected);
        delete sel[String(id)];
        root.m_selected = sel;
        var arr = [];
        var src = root.m_selectedEntries || [];
        for (var i = 0; i < src.length; i++)
            if (String(src[i].id) !== String(id))
                arr.push(src[i]);
        root.m_selectedEntries = arr;
    }

    function selectedIds() {
        var out = [];
        for (var k in root.m_selected)
            out.push(root.m_selected[k]);
        return out;
    }

    onM_selectedChanged: availDM.reclassify()

    W.WallpaperListQuery { id: pickQuery }

    Connections {
        target: pickQuery
        function onTotalChanged() { availDM.reclassify(); }
    }

    onVisibleChanged: {
        if (visible) {
            var sel = {};
            var ids = root.members || [];
            for (var i = 0; i < ids.length; i++)
                sel[String(ids[i])] = ids[i];
            root.m_selected = sel;
            root.m_selectedEntries = (root.memberEntries || []).slice();
            root.m_searchText = "";
            m_search.text = "";
            pickQuery.searchText = "";
            pickQuery.reload();
            Qt.callLater(availDM.reclassify);
        }
    }

    DelegateModel {
        id: availDM
        model: pickQuery.data
        filterOnGroup: "shown"

        property bool m_busy: false

        groups: [
            DelegateModelGroup {
                id: shownGroup
                name: "shown"
                includeByDefault: false
            }
        ]

        items.onChanged: availDM.reclassify()

        function reclassify() {
            if (availDM.m_busy) return;
            availDM.m_busy = true;
            for (let i = 0; i < availDM.items.count; i++) {
                const it = availDM.items.get(i);
                const sel = root.m_selected[String(it.model.id_proto)] !== undefined;
                it.inShown = !sel;
            }
            availDM.m_busy = false;
        }

        delegate: Item {
            id: cell
            required property var model
            required property int index
            width: grid.cellWidth
            height: grid.cellHeight

            WallpaperCard {
                anchors.fill: parent
                model: cell.model
                index: cell.index
                onClicked: root.addSel(cell.model.id_proto)
            }
        }
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
                    onTriggered: root.done(root.selectedIds())
                }
            }

            MD.Text {
                text: qsTr("Add wallpapers")
                typescale: MD.Token.typescale.title_medium
                color: MD.Token.color.on_surface
                Layout.fillWidth: true
            }
        }

        MD.TextField {
            id: m_search
            Layout.fillWidth: true
            placeholderText: qsTr("Search")
            onTextEdited: {
                root.m_searchText = text;
                pickQuery.searchText = text;
            }
        }

        MD.VerticalGridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            cacheBuffer: 200
            topMargin: 2
            bottomMargin: 4
            leftMargin: 4
            rightMargin: 4
            model: availDM

            readonly property int _cols: Math.max(1, Math.floor(width / 130))
            cellWidth: Math.floor((width - leftMargin - rightMargin) / _cols)
            cellHeight: cellWidth

            header: ColumnLayout {
                width: grid.width - grid.leftMargin - grid.rightMargin
                spacing: 4

                SectionSep {
                    visible: (root.m_shownAdded || []).length > 0
                    title: qsTr("Your Collection") + " (" + (root.m_selectedEntries || []).length + ")"
                }

                Flow {
                    Layout.fillWidth: true
                    visible: (root.m_shownAdded || []).length > 0
                    spacing: 0

                    Repeater {
                        model: root.m_shownAdded
                        delegate: Item {
                            id: addedCell
                            required property var modelData
                            width: grid.cellWidth
                            height: grid.cellHeight

                            W.WallpaperGetQuery {
                                id: addedWq
                                wallpaperId: String(addedCell.modelData.id)
                            }
                            readonly property var wp: addedWq.wallpaper

                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 6
                                radius: MD.Token.shape.corner.small
                                color: MD.Token.color.surface_container
                                clip: true

                                W.ThumbnailImage {
                                    id: addedThumb
                                    anchors.fill: parent
                                    visible: (addedCell.wp?.preview ?? "") !== ""
                                        || (addedCell.wp?.resource ?? "") !== ""
                                    source: addedCell.wp?.preview ?? ""
                                    resource: addedCell.wp?.resource ?? ""
                                    wpType: ""
                                    fillMode: Image.PreserveAspectCrop
                                }

                                MD.Icon {
                                    anchors.centerIn: parent
                                    visible: !addedThumb.visible
                                    name: MD.Token.icon.hide_image
                                    size: 24
                                    color: MD.Token.color.on_surface_variant
                                }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: Math.max(0, parent.height - addedName.y)
                                    visible: (addedCell.wp?.name ?? "") !== ""
                                    radius: MD.Token.shape.corner.small
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "transparent" }
                                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
                                    }
                                }

                                MD.Text {
                                    id: addedName
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: 4
                                    leftPadding: 6
                                    rightPadding: 6
                                    text: addedCell.wp?.name ?? ""
                                    typescale: MD.Token.typescale.label_small
                                    color: "white"
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                    wrapMode: Text.WordWrap
                                    horizontalAlignment: Text.AlignHCenter
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    color: "transparent"
                                    border.color: MD.Token.color.primary
                                    border.width: 3
                                    radius: MD.Token.shape.corner.small
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.removeSel(addedCell.modelData.id)
                                }
                            }
                        }
                    }
                }

                SectionSep {
                    title: qsTr("Not Included")
                }
            }
        }
    }
}
