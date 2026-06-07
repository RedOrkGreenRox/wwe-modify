pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import QtQuick.Dialogs
import Qcm.Material as MD
import waywallen.ui as W

MD.Page {
    id: root
    showBackground: false
    padding: 12

    property var current: null
    property bool m_picking: false
    property bool m_displaysOpen: false
    property string m_detailWallpaperId: ""
    property string m_playlistSearch: ""
    property int m_exportId: 0
    property var m_pendingSelectId: 0

    readonly property var m_filteredPlaylists: {
        var arr = listQuery.playlists || [];
        var q = root.m_playlistSearch.toLowerCase();
        if (q.length === 0) return arr;
        return arr.filter(function(p) {
            return (p.name || "").toLowerCase().indexOf(q) !== -1;
        });
    }

    component SectionTitle: MD.Text {
        typescale: MD.Token.typescale.title_medium
        color: MD.Token.color.on_surface
    }

    component FieldLabel: MD.Text {
        typescale: MD.Token.typescale.label_medium
        color: MD.Token.color.on_surface_variant
    }

    component SectionPane: MD.Pane {
        Layout.fillWidth: true
        padding: 0
        showBackground: false
    }

    W.PlaylistListQuery { id: listQuery }
    W.PlaylistStatusQuery { id: statusQuery }
    W.PlaylistMutationQuery {
        id: mut
        onDone: {
            listQuery.reload();
            statusQuery.reload();
        }
        onCreatedIdChanged: {
            if (mut.createdId > 0)
                root.m_pendingSelectId = mut.createdId;
        }
        onExported: W.Action.toast(qsTr("Playlist exported"))
        onImported: function(id, missingCount) {
            if (id > 0)
                root.m_pendingSelectId = id;
            listQuery.reload();
            if (missingCount > 0)
                W.Action.toast(qsTr("Imported, but %1 wallpaper(s) not found").arg(missingCount));
            else
                W.Action.toast(qsTr("Playlist imported"));
        }
    }

    function urlToPath(u) {
        return u.toString().replace(/^file:\/\//, "");
    }

    FileDialog {
        id: exportDialog
        fileMode: FileDialog.SaveFile
        nameFilters: ["Playlist JSON (*.json)"]
        defaultSuffix: "json"
        onAccepted: {
            if (root.m_exportId > 0)
                mut.exportPlaylist(root.m_exportId, root.urlToPath(selectedFile));
        }
    }

    property int m_importInto: 0

    FileDialog {
        id: importDialog
        fileMode: FileDialog.OpenFile
        nameFilters: ["Playlist JSON (*.json)", "All files (*)"]
        onAccepted: mut.importPlaylist(root.urlToPath(selectedFile), root.m_importInto)
    }

    MD.Dialog {
        id: overwriteDialog
        title: qsTr("Overwrite playlist?")
        modal: true
        anchors.centerIn: T.Overlay.overlay
        standardButtons: T.Dialog.Cancel | T.Dialog.Ok
        onAccepted: {
            root.m_importInto = root.current ? root.current.id : 0;
            importDialog.open();
        }
        contentItem: MD.Label {
            text: qsTr("This will replace the current playlist's contents. Continue?")
            wrapMode: Text.WordWrap
            padding: 16
        }
    }

    function startImport() {
        if (root.current && root.entryCount() > 0) {
            overwriteDialog.open();
        } else {
            root.m_importInto = root.current ? root.current.id : 0;
            importDialog.open();
        }
    }

    Connections {
        target: listQuery
        function onPlaylistsChanged() {
            var arr = listQuery.playlists || [];
            if (root.m_pendingSelectId > 0) {
                for (var i = 0; i < arr.length; i++) {
                    if (arr[i].id === root.m_pendingSelectId) {
                        root.current = arr[i];
                        root.m_pendingSelectId = 0;
                        return;
                    }
                }
            }
            if (root.current) {
                for (var j = 0; j < arr.length; j++) {
                    if (arr[j].id === root.current.id) {
                        root.current = arr[j];
                        return;
                    }
                }
                root.current = null;
            }
        }
    }

    function reloadAll() {
        listQuery.reload();
        statusQuery.reload();
    }

    function indexOfCurrent() {
        if (!root.current) return -1;
        var arr = root.m_filteredPlaylists || [];
        for (var i = 0; i < arr.length; i++)
            if (arr[i].id === root.current.id) return i;
        return -1;
    }

    function ivalH() { return root.current ? Math.floor(root.current.intervalSecs / 3600) : 0; }
    function ivalM() { return root.current ? Math.floor((root.current.intervalSecs % 3600) / 60) : 0; }
    function ivalS() { return root.current ? (root.current.intervalSecs % 60) : 0; }
    function applyInterval() {
        if (!root.current) return;
        var h = parseInt(fieldH.text) || 0;
        var m = parseInt(fieldM.text) || 0;
        var s = parseInt(fieldS.text) || 0;
        var total = h * 3600 + m * 60 + s;
        if (total < 10) total = 10;
        mut.setInterval(root.current.id, total);
    }

    function entryCount() { return root.current ? (root.current.entryIds || []).length : 0; }

    function commitPendingRemovals() {
        if (!root.current) return;
        var rem = membersView.pendingList();
        membersView.clearPending();
        if (rem.length === 0) return;
        var remSet = {};
        for (var i = 0; i < rem.length; i++)
            remSet[String(rem[i])] = true;
        var ids = (root.current.entryIds || []).filter(function(x) {
            return remSet[String(x)] === undefined;
        });
        mut.setItems(root.current.id, ids);
    }

    readonly property var m_memberList: {
        if (!root.current) return [];
        var ids = root.current.entryIds || [];
        var out = [];
        for (var i = 0; i < ids.length; i++)
            out.push({ id: ids[i] });
        return out;
    }

    function displayList() { return W.App.displayManager.displays || []; }

    readonly property bool m_autoAttach: root.current && statusQuery.autoAttachId === root.current.id

    readonly property bool m_anyActive: {
        if (!root.current) return false;
        if (root.m_autoAttach) return true;
        var d = statusQuery.displays || [];
        for (var i = 0; i < d.length; i++)
            if (d[i].activeId === root.current.id) return true;
        return false;
    }

    function isActiveOn(displayId) {
        if (!root.current) return false;
        var d = statusQuery.displays || [];
        for (var i = 0; i < d.length; i++)
            if (String(d[i].displayId) === String(displayId) && d[i].activeId === root.current.id)
                return true;
        return false;
    }

    function activeDisplayIds() {
        var out = [];
        if (!root.current) return out;
        var d = statusQuery.displays || [];
        for (var i = 0; i < d.length; i++)
            if (d[i].activeId === root.current.id)
                out.push(d[i].displayId);
        return out;
    }

    function displaysSummary() {
        if (root.m_autoAttach) return qsTr("All displays");
        var n = root.activeDisplayIds().length;
        if (n === 0) return qsTr("No displays");
        return n === 1 ? qsTr("1 display") : (n + " " + qsTr("displays"));
    }

    property int m_lastCurrentId: 0
    onCurrentChanged: {
        if (root.current)
            statusQuery.reload();
        var newId = root.current ? root.current.id : 0;
        if (newId !== root.m_lastCurrentId) {
            root.m_picking = false;
            root.m_detailWallpaperId = "";
            membersView.clearPending();
            root.m_lastCurrentId = newId;
        }
    }

    onM_pickingChanged: if (root.m_picking) root.m_detailWallpaperId = ""

    Connections {
        target: W.Notify
        function onDaemonReady() { root.reloadAll(); }
    }
    Component.onCompleted: {
        if (W.Notify.daemonPhase === W.Notify.DaemonPhase.Ready) reloadAll();
    }

    MD.Dialog {
        id: deleteDialog
        title: qsTr("Delete playlist?")
        modal: true
        anchors.centerIn: T.Overlay.overlay
        standardButtons: T.Dialog.Cancel | T.Dialog.Ok

        property int entryCount: 0

        onAccepted: {
            if (root.current) mut.remove(root.current.id);
            root.current = null;
        }

        contentItem: MD.Label {
            text: qsTr("This playlist has %1 wallpapers. Delete it?").arg(deleteDialog.entryCount)
            wrapMode: Text.WordWrap
            padding: 16
        }
    }

    contentItem: RowLayout {
        spacing: 12

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: !root.current ? 0 : (root.m_picking ? 1 : 2)

            ColumnLayout {
                spacing: 8
                Layout.fillWidth: true
                Layout.fillHeight: true

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    MD.IconButton {
                        action: MD.Action {
                            icon.name: MD.Token.icon.playlist_add
                            onTriggered: mut.create(qsTr("New playlist"), 1, 300, [])
                        }
                    }

                    W.SearchChip {
                        Layout.preferredWidth: 120
                        placeholderText: qsTr("Search")
                        onTextEdited: root.m_playlistSearch = text
                    }

                    Item { Layout.fillWidth: true }
                }

                MD.Text {
                    visible: (root.m_filteredPlaylists || []).length === 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    text: (listQuery.playlists || []).length === 0
                        ? qsTr("No playlists found.\nCreate one with the + button")
                        : qsTr("No playlists found")
                    typescale: MD.Token.typescale.body_large
                    color: MD.Token.color.on_surface_variant
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                MD.VerticalGridView {
                    id: playlistGrid
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.m_filteredPlaylists
                    visible: (root.m_filteredPlaylists || []).length > 0

                    readonly property int _cols: Math.max(2, Math.floor(width / 170))
                    cellWidth: Math.floor(width / _cols)
                    cellHeight: Math.floor(cellWidth * 0.85)

                    currentIndex: root.indexOfCurrent()
                    highlightFollowsCurrentItem: true
                    highlightMoveDuration: 150
                    highlight: Component {
                        Item {
                            z: 2
                            visible: root.current !== null && root.indexOfCurrent() >= 0
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 2
                                color: "transparent"
                                border.color: MD.Token.color.primary
                                border.width: 3
                                radius: MD.Token.shape.corner.small + 2
                            }
                        }
                    }

                    delegate: Item {
                        id: cardDelegate
                        required property var modelData
                        required property int index

                        width: GridView.view.cellWidth
                        height: GridView.view.cellHeight

                        readonly property bool isSelected: root.current !== null && root.current.id === cardDelegate.modelData.id

                        Item {
                            anchors.fill: parent
                            anchors.margins: 4

                            Rectangle {
                                id: cardRect
                                anchors.fill: parent
                                scale: cardDelegate.isSelected ? 0.96 : 1.0
                                radius: MD.Token.shape.corner.small
                                color: MD.Token.color.surface_container
                                clip: true

                                Behavior on scale {
                                    NumberAnimation { duration: 150; easing.type: Easing.InOutCubic }
                                }

                                MD.Icon {
                                    anchors.centerIn: parent
                                    name: MD.Token.icon.queue_music
                                    size: 40
                                    color: MD.Token.color.on_surface_variant
                                }

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: Math.max(0, cardRect.height - cardName.y)
                                    visible: height > 0
                                    radius: MD.Token.shape.corner.small
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "transparent" }
                                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
                                    }
                                }

                                MD.Text {
                                    id: cardName
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: 6
                                    leftPadding: 6
                                    rightPadding: 6
                                    text: cardDelegate.modelData.name
                                    typescale: MD.Token.typescale.title_medium
                                    color: "white"
                                    wrapMode: Text.WordWrap
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                    horizontalAlignment: Text.AlignHCenter
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.current = cardDelegate.modelData
                                }
                            }
                        }
                    }
                }
            }

            PlaylistWallpaperPicker {
                id: inlinePicker
                members: root.current ? (root.current.entryIds || []) : []
                memberEntries: root.m_memberList
                onDone: function(ids) {
                    if (root.current) {
                        var cur = root.current.entryIds || [];
                        var changed = cur.length !== ids.length;
                        if (!changed)
                            for (var i = 0; i < cur.length; i++)
                                if (String(cur[i]) !== String(ids[i])) { changed = true; break; }
                        if (changed)
                            mut.setItems(root.current.id, ids);
                    }
                    root.m_picking = false;
                }
            }

            PlaylistMembersView {
                id: membersView
                entries: root.m_memberList
                onBack: {
                    root.commitPendingRemovals();
                    root.current = null;
                }
                onAddRequested: {
                    root.commitPendingRemovals();
                    root.m_picking = true;
                }
                onInfoRequested: function(entryId) {
                    root.m_detailWallpaperId = String(entryId);
                }
            }
        }

        MD.Pane {
            Layout.preferredWidth: root.current !== null ? 340 : 0
            Layout.maximumWidth: Layout.preferredWidth
            Layout.fillHeight: true
            visible: Layout.preferredWidth > 1
            opacity: root.current !== null ? 1 : 0
            clip: true
            radius: root.MD.MProp.page.backgroundRadius
            padding: 0
            showBackground: true

            Behavior on Layout.preferredWidth {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
            }
            Behavior on opacity {
                NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
            }

            contentItem: StackLayout {
                currentIndex: root.m_detailWallpaperId !== "" ? 1 : 0

              ColumnLayout {
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    Layout.leftMargin: 8
                    Layout.rightMargin: 8
                    Item { Layout.fillWidth: true }
                    MD.IconButton {
                        action: MD.Action {
                            icon.name: MD.Token.icon.close
                            onTriggered: root.current = null
                        }
                    }
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.leftMargin: 16
                    Layout.rightMargin: 16
                    Layout.bottomMargin: 16
                    clip: true
                    contentWidth: width
                    contentHeight: m_detail.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: m_detail
                        width: parent.width
                        spacing: 12

                        SectionPane {
                            contentItem: ColumnLayout {
                                spacing: 12

                                SectionTitle { text: qsTr("General") }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    FieldLabel { text: qsTr("Name") }
                                    MD.TextField {
                                        Layout.fillWidth: true
                                        text: root.current ? root.current.name : ""
                                        onEditingFinished: if (root.current) mut.rename(root.current.id, text)
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    FieldLabel { text: qsTr("Mode") }
                                    MD.ComboBox {
                                        id: modeBox
                                        Layout.fillWidth: true
                                        model: [qsTr("Sequential"), qsTr("Shuffle"), qsTr("Random")]
                                        currentIndex: root.current ? Math.max(0, root.current.mode - 1) : 0
                                        onActivated: if (root.current) mut.setMode(root.current.id, currentIndex + 1)
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    FieldLabel { text: qsTr("Rotation interval") }
                                    RowLayout {
                                        spacing: 8
                                        MD.TextField {
                                            id: fieldH
                                            implicitWidth: 48
                                            inputMethodHints: Qt.ImhDigitsOnly
                                            validator: IntValidator { bottom: 0; top: 999 }
                                            text: String(root.ivalH())
                                            onEditingFinished: {
                                                if (text.length === 0) text = "0";
                                                root.applyInterval();
                                            }
                                        }
                                        MD.Text { text: "h"; typescale: MD.Token.typescale.body_small; color: MD.Token.color.on_surface_variant }
                                        MD.TextField {
                                            id: fieldM
                                            implicitWidth: 48
                                            inputMethodHints: Qt.ImhDigitsOnly
                                            validator: IntValidator { bottom: 0; top: 59 }
                                            text: String(root.ivalM())
                                            onEditingFinished: {
                                                if (text.length === 0) text = "0";
                                                root.applyInterval();
                                            }
                                        }
                                        MD.Text { text: "m"; typescale: MD.Token.typescale.body_small; color: MD.Token.color.on_surface_variant }
                                        MD.TextField {
                                            id: fieldS
                                            implicitWidth: 48
                                            inputMethodHints: Qt.ImhDigitsOnly
                                            validator: IntValidator { bottom: 0; top: 59 }
                                            text: String(root.ivalS())
                                            onEditingFinished: {
                                                if (text.length === 0) text = "0";
                                                root.applyInterval();
                                            }
                                        }
                                        MD.Text { text: "s"; typescale: MD.Token.typescale.body_small; color: MD.Token.color.on_surface_variant }
                                        Item { Layout.fillWidth: true }
                                    }
                                }
                            }
                        }

                        SectionPane {
                            contentItem: ColumnLayout {
                                spacing: 4
                                SectionTitle { text: qsTr("Wallpapers") }
                                MD.Text {
                                    text: root.entryCount() + " " + qsTr("wallpapers")
                                    typescale: MD.Token.typescale.body_medium
                                    color: MD.Token.color.on_surface_variant
                                }
                            }
                        }

                        SectionPane {
                            contentItem: ColumnLayout {
                                spacing: 8
                                SectionTitle { text: qsTr("Displays") }

                                MD.Text {
                                    Layout.fillWidth: true
                                    visible: root.entryCount() === 0
                                    text: qsTr("Add wallpapers before activating")
                                    typescale: MD.Token.typescale.body_small
                                    color: MD.Token.color.on_surface_variant
                                    wrapMode: Text.WordWrap
                                }

                                MD.Button {
                                    Layout.fillWidth: true
                                    enabled: root.entryCount() > 0
                                    text: root.displaysSummary()
                                    icon.name: root.m_displaysOpen ? MD.Token.icon.expand_less : MD.Token.icon.expand_more
                                    onClicked: root.m_displaysOpen = !root.m_displaysOpen
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 4
                                    visible: root.m_displaysOpen
                                    spacing: 4

                                    MD.CheckBox {
                                        id: allBox
                                        Layout.fillWidth: true
                                        enabled: root.entryCount() > 0
                                        text: qsTr("All displays")
                                        checked: root.m_autoAttach
                                        onToggled: {
                                            if (!root.current) return;
                                            if (checked)
                                                mut.activate(root.current.id, [], true);
                                            else
                                                mut.deactivate(root.activeDisplayIds(), root.current.id);
                                            checked = Qt.binding(function() { return root.m_autoAttach; });
                                        }
                                    }

                                    Repeater {
                                        model: root.displayList()
                                        delegate: MD.CheckBox {
                                            id: dispBox
                                            required property var modelData
                                            Layout.fillWidth: true
                                            enabled: root.entryCount() > 0 && !root.m_autoAttach
                                            text: dispBox.modelData.displayLabel || dispBox.modelData.name || ("Display " + dispBox.modelData.id)
                                            checked: root.isActiveOn(dispBox.modelData.id)
                                            onToggled: {
                                                if (!root.current) return;
                                                if (checked)
                                                    mut.activate(root.current.id, [dispBox.modelData.id], false);
                                                else
                                                    mut.deactivate([dispBox.modelData.id], 0);
                                                checked = Qt.binding(function() { return root.isActiveOn(dispBox.modelData.id); });
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        SectionPane {
                            contentItem: ColumnLayout {
                                spacing: 8
                                SectionTitle { text: qsTr("Backup") }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    MD.Button {
                                        Layout.fillWidth: true
                                        text: qsTr("Export")
                                        icon.name: MD.Token.icon.file_upload
                                        onClicked: {
                                            root.m_exportId = root.current ? root.current.id : 0;
                                            if (root.m_exportId > 0)
                                                exportDialog.open();
                                        }
                                    }
                                    MD.Button {
                                        Layout.fillWidth: true
                                        text: qsTr("Import")
                                        icon.name: MD.Token.icon.file_download
                                        onClicked: root.startImport()
                                    }
                                }
                            }
                        }

                        SectionPane {
                            contentItem: ColumnLayout {
                                spacing: 8
                                MD.Button {
                                    Layout.fillWidth: true
                                    text: qsTr("Delete playlist")
                                    icon.name: MD.Token.icon.delete
                                    mdState.type: MD.Enum.BtTonal
                                    onClicked: {
                                        if (!root.current) return;
                                        if (root.entryCount() > 0) {
                                            deleteDialog.entryCount = root.entryCount();
                                            deleteDialog.open();
                                        } else {
                                            mut.remove(root.current.id);
                                            root.current = null;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
              }

              ColumnLayout {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  spacing: 8

                  WallpaperDetailPanel {
                      Layout.fillWidth: true
                      Layout.fillHeight: true
                      showApply: false
                      wallpaperId: root.m_detailWallpaperId
                      onBack: root.m_detailWallpaperId = ""
                  }

                  MD.Button {
                      Layout.fillWidth: true
                      Layout.leftMargin: 16
                      Layout.rightMargin: 16
                      Layout.bottomMargin: 8
                      visible: root.m_anyActive && root.m_detailWallpaperId !== ""
                      text: qsTr("Apply")
                      mdState.type: MD.Enum.BtFilled
                      onClicked: if (root.current) mut.jumpTo(root.current.id, root.m_detailWallpaperId)
                  }
              }
            }
        }
    }
}
