pragma ComponentBehavior: Bound
import QtQuick
import QtQml as Qml
import QtQuick.Layouts
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    property string wallpaperId: ""
    property bool showApply: true

    signal back

    readonly property var wp: wallpaperGetQuery.wallpaper

    property var applyTargetIds: []
    property int rendererIndex: 0

    function isTargetAll() { return root.applyTargetIds.length === 0; }
    function toggleTarget(id) {
        const next = root.applyTargetIds.slice();
        const i = next.indexOf(id);
        if (i >= 0) next.splice(i, 1);
        else next.push(id);
        root.applyTargetIds = next;
    }

    readonly property var rendererCandidates: {
        const w = root.wp;
        if (!w) return [];
        const t = w.wpType || "";
        if (!t) return [];
        const list = (pluginQuery.renderers || []).filter(r => (r.types || []).indexOf(t) >= 0);
        list.sort((a, b) => (b.priority || 0) - (a.priority || 0));
        return list;
    }
    onRendererCandidatesChanged: root.rendererIndex = 0

    W.WallpaperGetQuery {
        id: wallpaperGetQuery
        wallpaperId: root.wallpaperId
    }

    W.WallpaperListQuery { id: m_list }
    W.RendererPluginListQuery { id: pluginQuery }
    W.WallpaperApplyQuery { id: applyQuery }
    W.WallpaperApplyViaPortalQuery { id: portalApplyQuery }

    W.WallpaperPropertySetQuery {
        id: setQuery
        wallpaperId: root.wallpaperId
    }

    W.UserPropertyListModel {
        id: userPropModel
        schemaJson: wallpaperGetQuery.wallpaper?.userPropertiesSchema ?? ""
        overridesJson: wallpaperGetQuery.wallpaper?.userPropertyOverrides ?? ""
    }

    Component.onCompleted: pluginQuery.reload()

    QtObject {
        id: m_pending_writes
        property var entries: ({})
    }

    Qml.Timer {
        id: m_flush_timer
        interval: 200
        repeat: false
        onTriggered: {
            const e = m_pending_writes.entries;
            for (const k in e) {
                setQuery.propertyKey = k;
                setQuery.propertyValue = e[k];
                setQuery.reload();
            }
            m_pending_writes.entries = {};
        }
    }

    Connections {
        target: userPropModel
        function onValueChanged(key, value) {
            const e = m_pending_writes.entries;
            e[key] = value;
            m_pending_writes.entries = e;
            m_flush_timer.restart();
        }
    }

    MD.Action {
        id: applyAction
        text: "Apply"
        busy: applyQuery.querying
        enabled: (W.App.displayManager.displays || []).length > 0
        onTriggered: {
            if (busy) return;
            if (!root.wp) return;
            applyQuery.wallpaper = root.wp;
            applyQuery.displayIds = root.applyTargetIds;
            if (root.rendererCandidates.length >= 2) {
                const pick = root.rendererCandidates[root.rendererIndex];
                applyQuery.rendererName = pick ? (pick.name || "") : "";
            } else {
                applyQuery.rendererName = "";
            }
            applyQuery.reload();
        }
    }

    MD.Action {
        id: applyViaPortalAction
        text: "Apply via desktop portal"
        busy: portalApplyQuery.querying
        onTriggered: {
            if (busy) return;
            if (!root.wp) return;
            portalApplyQuery.wallpaperId = root.wallpaperId;
            portalApplyQuery.reload();
        }
    }

    readonly property MD.Action activeApplyAction:
        ((root.wp?.wpType ?? "") === "image"
            && (W.App.displayManager.displays || []).length === 0)
        ? applyViaPortalAction : applyAction

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 8
            Layout.leftMargin: 8
            Layout.rightMargin: 8

            MD.IconButton {
                action: MD.Action {
                    icon.name: MD.Token.icon.arrow_back
                    onTriggered: root.back()
                }
            }
            Item { Layout.fillWidth: true }
        }

        MD.VerticalListView {
            id: m_detail_view
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: userPropModel
            spacing: 8
            leftMargin: 16
            rightMargin: 16
            topMargin: 0
            bottomMargin: 8

            header: ColumnLayout {
                width: m_detail_view.contentWidth
                spacing: 12

                W.ThumbnailImage {
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? 200 : 0
                    Layout.topMargin: 4
                    visible: (root.wp?.preview ?? "") !== ""
                             || (["video", "image"].indexOf(root.wp?.wpType ?? "") >= 0
                                 && (root.wp?.resource ?? "") !== "")
                    source: root.wp?.preview ?? ""
                    resource: root.wp?.resource ?? ""
                    wpType: root.wp?.wpType ?? ""
                    fillMode: Image.PreserveAspectFit
                }

                MD.Text {
                    Layout.fillWidth: true
                    text: root.wp?.name || "Untitled"
                    typescale: MD.Token.typescale.title_large
                    color: MD.Token.color.on_surface
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }

                MD.Text {
                    text: root.wp?.wpType || ""
                    typescale: MD.Token.typescale.label_large
                    color: MD.Token.color.on_surface_variant
                }

                GridLayout {
                    id: m_meta
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 12
                    rowSpacing: 4

                    readonly property real sizeBytes: m_list.data && root.wp
                                                      ? m_list.data.sizeOf(root.wp)
                                                      : 0
                    readonly property bool hasPath: (root.wp?.resource ?? "") !== ""
                    readonly property bool hasResolution: Number(root.wp?.width ?? 0) > 0 && Number(root.wp?.height ?? 0) > 0
                    readonly property bool hasSize: sizeBytes > 0
                    readonly property bool hasFormat: (root.wp?.format ?? "") !== ""

                    function shortPath(p) {
                        const parts = (p || "").split("/").filter(s => s.length > 0);
                        return parts.slice(-2).join("/");
                    }
                    function formatSize(b) {
                        let v = Number(b ?? 0);
                        if (!(v > 0)) return "";
                        const u = ["B", "KB", "MB", "GB", "TB"];
                        let i = 0;
                        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
                        return v.toFixed(i === 0 ? 0 : 1) + " " + u[i];
                    }

                    MD.Text {
                        visible: m_meta.hasPath
                        text: "Path"
                        typescale: MD.Token.typescale.label_medium
                        color: MD.Token.color.on_surface_variant
                    }
                    MD.Text {
                        visible: m_meta.hasPath
                        Layout.fillWidth: true
                        text: m_meta.shortPath(root.wp?.resource)
                        typescale: MD.Token.typescale.body_medium
                        color: MD.Token.color.on_surface
                        elide: Text.ElideMiddle
                        maximumLineCount: 1
                        wrapMode: Text.NoWrap
                    }

                    MD.Text {
                        visible: m_meta.hasResolution
                        text: "Resolution"
                        typescale: MD.Token.typescale.label_medium
                        color: MD.Token.color.on_surface_variant
                    }
                    MD.Text {
                        visible: m_meta.hasResolution
                        text: (root.wp?.width ?? 0) + "×" + (root.wp?.height ?? 0)
                        typescale: MD.Token.typescale.body_medium
                        color: MD.Token.color.on_surface
                    }

                    MD.Text {
                        visible: m_meta.hasSize
                        text: "Size"
                        typescale: MD.Token.typescale.label_medium
                        color: MD.Token.color.on_surface_variant
                    }
                    MD.Text {
                        visible: m_meta.hasSize
                        text: m_meta.formatSize(m_meta.sizeBytes)
                        typescale: MD.Token.typescale.body_medium
                        color: MD.Token.color.on_surface
                    }

                    MD.Text {
                        visible: m_meta.hasFormat
                        text: "Format"
                        typescale: MD.Token.typescale.label_medium
                        color: MD.Token.color.on_surface_variant
                    }
                    MD.Text {
                        visible: m_meta.hasFormat
                        text: (root.wp?.format ?? "").toLowerCase()
                        typescale: MD.Token.typescale.body_medium
                        color: MD.Token.color.on_surface
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    visible: (root.wp?.tags?.length ?? 0) > 0
                    Repeater {
                        model: root.wp?.tags ?? []
                        delegate: MD.AssistChip {
                            required property string modelData
                            text: modelData
                        }
                    }
                }

                ColumnLayout {
                    id: m_description
                    Layout.fillWidth: true
                    spacing: 4
                    visible: (root.wp?.description ?? "") !== ""

                    property bool expanded: false
                    readonly property int collapsedLines: 3

                    MD.Divider { Layout.fillWidth: true }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        MD.Text {
                            Layout.fillWidth: true
                            text: "Description"
                            typescale: MD.Token.typescale.label_large
                            color: MD.Token.color.on_surface_variant
                        }
                        MD.IconButton {
                            icon.name: m_description.expanded ? MD.Token.icon.expand_less : MD.Token.icon.expand_more
                            visible: m_descText.lineCount > m_description.collapsedLines || m_description.expanded
                            onClicked: m_description.expanded = !m_description.expanded
                        }
                    }

                    MD.Text {
                        id: m_descText
                        Layout.fillWidth: true
                        text: W.Util.bbcodeToHtml(root.wp?.description ?? "")
                        textFormat: Text.StyledText
                        typescale: MD.Token.typescale.body_medium
                        color: MD.Token.color.on_surface
                        wrapMode: Text.WordWrap
                        maximumLineCount: m_description.expanded ? Number.MAX_SAFE_INTEGER : m_description.collapsedLines
                        elide: m_description.expanded ? Text.ElideNone : Text.ElideRight
                        onLinkActivated: link => MD.Util.openUrlExternally(link)
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    visible: userPropModel.count > 0

                    MD.Divider { Layout.fillWidth: true }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        MD.Text {
                            Layout.fillWidth: true
                            text: "Properties"
                            typescale: MD.Token.typescale.label_large
                            color: MD.Token.color.on_surface_variant
                        }
                        MD.IconButton {
                            icon.name: MD.Token.icon.restart_alt
                            mdState.size: MD.Enum.XS
                            onClicked: userPropModel.resetAll()
                        }
                    }
                }
            }

            delegate: ColumnLayout {
                id: m_prop_delegate
                required property string key
                required property string label
                required property string type
                required property bool   supported
                required property real   minVal
                required property real   maxVal
                required property string currentValue
                required property bool   hasAlpha

                width: ListView.view ? (ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin) : 0
                spacing: 2

                MD.Text {
                    text: m_prop_delegate.label
                    textFormat: Text.StyledText
                    typescale: MD.Token.typescale.label_medium
                    color: MD.Token.color.on_surface
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    onLinkActivated: link => MD.Util.openUrlExternally(link)
                }

                MD.Switch {
                    id: m_switch
                    visible: m_prop_delegate.type === "bool"
                    onToggled: userPropModel.setValue(m_prop_delegate.key, checked ? "true" : "false")
                }
                Binding {
                    target: m_switch
                    property: "checked"
                    value: m_prop_delegate.currentValue === "true"
                }

                RowLayout {
                    visible: m_prop_delegate.type === "slider"
                    Layout.fillWidth: true
                    spacing: 8
                    MD.Slider {
                        id: m_slider
                        Layout.fillWidth: true
                        from: m_prop_delegate.minVal
                        to: m_prop_delegate.maxVal
                        onMoved: userPropModel.setValue(m_prop_delegate.key, String(value))
                    }
                    MD.Text {
                        text: Number(m_prop_delegate.currentValue).toFixed(3)
                        typescale: MD.Token.typescale.body_small
                        color: MD.Token.color.on_surface_variant
                        Layout.preferredWidth: 56
                        horizontalAlignment: Text.AlignRight
                    }
                }
                Binding {
                    target: m_slider
                    property: "value"
                    value: Number(m_prop_delegate.currentValue)
                }

                MD.ColorPickerButton {
                    id: m_color
                    visible: m_prop_delegate.type === "color"
                    Layout.preferredWidth: 80
                    Layout.preferredHeight: 32
                    showAlpha: m_prop_delegate.hasAlpha
                    onAccepted: c => userPropModel.setValue(m_prop_delegate.key, W.Util.colorToWire(c, showAlpha))
                }
                Binding {
                    target: m_color
                    property: "color"
                    value: W.Util.colorFromWire(m_prop_delegate.currentValue)
                }

                MD.Text {
                    visible: !m_prop_delegate.supported
                    text: "(" + m_prop_delegate.type + " — not yet supported)"
                    typescale: MD.Token.typescale.body_small
                    color: MD.Token.color.on_surface_variant
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            Layout.topMargin: 8
            Layout.bottomMargin: 8
            spacing: 8
            visible: root.showApply

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                visible: (W.App.displayManager.displays || []).length > 0

                MD.Text {
                    text: "Apply to"
                    typescale: MD.Token.typescale.label_medium
                    color: MD.Token.color.on_surface_variant
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 6

                    MD.FilterChip {
                        text: "All"
                        checked: root.isTargetAll()
                        onClicked: root.applyTargetIds = []
                    }

                    Repeater {
                        model: W.App.displayManager.displays
                        MD.FilterChip {
                            required property var modelData
                            text: (modelData?.displayLabel ?? "") || (modelData?.name ?? "").replace(/^waywallen-[a-z]+-[a-z]+-/, "") || ("Display " + modelData?.id)
                            checked: root.applyTargetIds.indexOf(modelData?.id) >= 0
                            onClicked: root.toggleTarget(modelData?.id)
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                visible: root.rendererCandidates.length >= 2

                MD.Text {
                    text: "Renderer"
                    typescale: MD.Token.typescale.label_medium
                    color: MD.Token.color.on_surface_variant
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: root.rendererCandidates
                        MD.FilterChip {
                            required property var modelData
                            required property int index
                            text: modelData?.name || ""
                            checked: root.rendererIndex === index
                            onClicked: root.rendererIndex = index
                        }
                    }
                }
            }

            MD.BusyButton {
                id: applyBtn
                Layout.fillWidth: true
                action: root.activeApplyAction
                mdState.type: MD.Enum.BtFilled
            }

            RowLayout {
                visible: applyQuery.status === 3
                spacing: 8
                MD.Icon {
                    name: MD.Token.icon.check
                    size: 20
                    color: MD.Token.color.primary
                }
                MD.Text {
                    text: "Applied"
                    typescale: MD.Token.typescale.label_large
                    color: MD.Token.color.primary
                }
            }
        }
    }
}
