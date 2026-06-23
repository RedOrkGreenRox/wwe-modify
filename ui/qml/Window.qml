pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtCore
import QtQuick
import QtQml
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Templates as T

import Qcm.Material as MD
import waywallen.ui as W

MD.ApplicationWindow {
    id: win
    MD.MProp.size.width: width
    MD.MProp.backgroundColor: {
        return MD.MProp.color.surface_container;
    }
    MD.MProp.textColor: MD.MProp.color.getOn(MD.MProp.backgroundColor)

    color: MD.MProp.backgroundColor
    height: 600
    visible: true
    width: 900
    title: "waywallen"

    // Persist the window size across runs. Wayland doesn't let clients
    // restore their own position, so only width/height are stored.
    Settings {
        category: "window"
        property alias width: win.width
        property alias height: win.height
    }

    W.HealthQuery {
        id: healthQuery
    }

    W.HotkeyRuntime {
        id: hotkeys
    }

    function openHotkeysPopup() {
        if (win.currentPage !== 5)
            win.currentPage = 5;
        MD.Util.showPopup('waywallen.ui/PagePopup', {
            source: 'waywallen.ui/HotkeysSettingsPage',
            fillWidth: true,
            fillHeight: true
        }, win);
    }

    function reloadCurrentPage() {
        m_content.switchTo(pageComponents[currentPage], {}, false);
        m_content.forceActiveFocus();
    }

    Connections {
        target: W.Notify
        function onDaemonReady() {
            healthQuery.reload();
        }
    }

    Connections {
        target: W.Global
        function onWorkshopRequestNonceChanged() {
            win.currentPage = 1
        }
    }

    property int currentPage: 0

    readonly property bool isCompact: MD.MProp.size.isCompact

    readonly property var pageModel: [
        { icon: MD.Token.icon.wallpaper, name: qsTr("Wallpapers") },
        { icon: MD.Token.icon.extension, name: qsTr("Workshop") },
        { icon: MD.Token.icon.monitor, name: qsTr("Displays") },
        { icon: MD.Token.icon.monitor_heart, name: qsTr("Status") },
        { icon: MD.Token.icon.extension, name: qsTr("Plugins") },
        { icon: MD.Token.icon.settings, name: qsTr("Settings") }
    ]

    readonly property var pageComponents: [
        "qrc:/waywallen/ui/qml/page/WallpaperPage.qml",
        "qrc:/waywallen/ui/qml/page/WorkshopPage.qml",
        "qrc:/waywallen/ui/qml/page/DisplaysPage.qml",
        "qrc:/waywallen/ui/qml/page/StatusPage.qml",
        "qrc:/waywallen/ui/qml/page/PluginManagePage.qml",
        "qrc:/waywallen/ui/qml/page/SettingsPage.qml"
    ]

    // Keep Workshop alive while switching tabs so the embedded WebEngine page
    // does not reload or lose scroll/navigation state until the app exits.
    readonly property var pageCacheable: [true, true, false, false, false, false]


    onCurrentPageChanged: {
        m_content.switchTo(pageComponents[currentPage], {}, pageCacheable[currentPage]);
        // Qt.WidgetWithChildrenShortcut fires only when focus is inside the page.
        // PageContainer does not forward focus on switch — do it explicitly.
        m_content.forceActiveFocus();
    }

    Component.onCompleted: {
        currentPageChanged();
        // Level-check for the case where the daemon is already Ready
        // before this window finishes constructing (UI launched
        // standalone against a running daemon, page reload, etc.)
        // — `daemonReady` is edge-triggered and won't fire then.
        if (W.Notify.daemonPhase === W.Notify.DaemonPhase.Ready) {
            healthQuery.reload();
        }
    }

    MD.SnakeView {
        id: m_snake
        parent: T.Overlay.overlay
        anchors.fill: parent
    }

    Connections {
        target: W.Action
        function onToast(text, duration, flags, action) {
            m_snake.show(text, duration, flags, action);
        }
    }

    // Global daemon-event toasts. Notify mirrors `GlobalEvent` from the
    // daemon; library additions surface here so the toast fires no
    // matter which page triggered the add (manual vs auto-detect).
    Connections {
        target: W.Notify
        function onLibrariesAdded(paths) {
            const n = paths.length;
            W.Action.toast(n === 1 ? "Library added" : (n + " libraries added"));
        }
        function onDisplayConnectionFailed(clientName, clientProtocolVersion, errorCode, reason) {
            const who = clientName.length > 0 ? clientName : qsTr("Display client");
            // flag=1 → close button; 6s gives the user time to read.
            W.Action.toast(qsTr("%1 connection failed: %2").arg(who).arg(reason), 6000, 1, null);
        }
    }

    W.DaemonNotRunDialog {}

    Shortcut {
        sequences: hotkeys.sequences("open_wallpapers")
        context: Qt.ApplicationShortcut
        onActivated: win.currentPage = 0
    }

    Shortcut {
        sequences: hotkeys.sequences("open_workshop")
        context: Qt.ApplicationShortcut
        onActivated: win.currentPage = 1
    }

    Shortcut {
        sequences: hotkeys.sequences("open_displays")
        context: Qt.ApplicationShortcut
        onActivated: win.currentPage = 2
    }

    Shortcut {
        sequences: hotkeys.sequences("open_status")
        context: Qt.ApplicationShortcut
        onActivated: win.currentPage = 3
    }

    Shortcut {
        sequences: hotkeys.sequences("open_plugins")
        context: Qt.ApplicationShortcut
        onActivated: win.currentPage = 4
    }

    Shortcut {
        sequences: hotkeys.sequences("open_settings")
        context: Qt.ApplicationShortcut
        onActivated: win.currentPage = 5
    }

    Shortcut {
        sequences: hotkeys.sequences("open_hotkeys")
        context: Qt.ApplicationShortcut
        onActivated: win.openHotkeysPopup()
    }

    Shortcut {
        sequences: hotkeys.sequences("reload_ui")
        context: Qt.ApplicationShortcut
        onActivated: win.reloadCurrentPage()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // --- Navigation rail (collapses to 96dp; auto-expands when
            // the window is wide enough to embed) ---
            Loader {
                id: m_drawer_loader
                Layout.fillHeight: true
                active: !win.isCompact
                visible: active

                sourceComponent: MD.NavigationRail {
                    id: m_rail
                    model: win.pageModel
                    currentIndex: win.currentPage

                    autoExpand: W.Global.sidebarAutoExpand
                    // The rail only re-syncs `expanded` on window-class
                    // changes; apply a runtime toggle of the setting at once.
                    onAutoExpandChanged: if (autoExpand) expanded = useEmbed

                    onClicked: function (model) {
                        win.currentPage = model.index;
                    }

                    // Logo + a menu-toggle button (the rail's default header
                    // is just the toggle; we add branding alongside it).
                    header: Item {
                        implicitWidth: m_rail.useLarge ? m_rail.expandedWidth : m_rail.collapsedWidth
                        implicitHeight: m_flavor_badge.y + m_flavor_badge.implicitHeight + 12

                        MD.StandardIconButton {
                            id: m_menu_btn
                            x: m_rail.useLarge ? (32 - (width - 24) / 2) : (m_rail.collapsedWidth - width) / 2
                            y: 4
                            icon.name: m_rail.useLarge ? MD.Token.icon.menu_open : MD.Token.icon.menu
                            onClicked: m_rail.toggle()

                            Behavior on x {
                                NumberAnimation {
                                    duration: MD.Token.duration.long2
                                    easing: MD.Token.easing.emphasized
                                }
                            }
                        }

                        Image {
                            id: m_logo
                            width: 32
                            height: 32
                            x: m_rail.useLarge ? 32 : (m_rail.collapsedWidth - width) / 2
                            y: m_menu_btn.y + m_menu_btn.height + 16
                            source: "qrc:/waywallen/ui/assets/waywallen-ui.svg"
                            fillMode: Image.PreserveAspectFit
                            sourceSize.width: 64
                            sourceSize.height: 64

                            Behavior on x {
                                NumberAnimation {
                                    duration: MD.Token.duration.long2
                                    easing: MD.Token.easing.emphasized
                                }
                            }
                        }

                        MD.Label {
                            visible: m_rail.useLarge
                            anchors.left: m_logo.right
                            anchors.leftMargin: 12
                            anchors.verticalCenter: m_logo.verticalCenter
                            text: "waywallen"
                            typescale: MD.Token.typescale.title_large
                        }

                        // Build flavor badge: "Lite" or "Full".
                        // Keep it directly under the logo and visible even when
                        // the rail is collapsed, so the build variant is always
                        // discoverable.
                        MD.Label {
                            id: m_flavor_badge
                            anchors.horizontalCenter: m_logo.horizontalCenter
                            anchors.top: m_logo.bottom
                            anchors.topMargin: 2
                            text: W.Notify.buildFlavor === "full" ? qsTr("Full") : qsTr("Lite")
                            typescale: MD.Token.typescale.label_small
                            color: MD.Token.color.on_surface_variant
                            opacity: 0.75
                        }
                    }

                    footer: MD.RailItem {
                        expand: m_rail.useLarge
                        checked: false
                        icon.name: MD.Token.icon.info
                        text: "About"
                        onClicked: MD.Util.showPopup('waywallen.ui/PagePopup', {
                            source: 'waywallen.ui/AboutPage'
                        }, win)
                    }
                }
            }

            // --- Page content ---
            MD.PageContainer {
                id: m_content
                Layout.fillHeight: true
                Layout.fillWidth: true
                clip: true
                initialItem: Item {}

                MD.MProp.page: m_page_ctx

                MD.PageContext {
                    id: m_page_ctx
                    showHeader: false
                    backgroundRadius: win.isCompact ? 0 : MD.Token.shape.corner.large
                    showBackground: !win.isCompact
                }
            }
        }

        // --- Bottom navigation bar (compact mode) ---
        Loader {
            id: m_bar_loader
            Layout.fillWidth: true
            active: win.isCompact
            visible: active

            sourceComponent: MD.Pane {
                padding: 0
                backgroundColor: MD.MProp.color.surface_container
                elevation: MD.Token.elevation.level2

                contentItem: RowLayout {
                    Repeater {
                        model: win.pageModel

                        Item {
                            Layout.fillWidth: true
                            implicitHeight: 12 + children[0].implicitHeight + 16
                            required property var modelData
                            required property int index

                            MD.BarItem {
                                anchors.fill: parent
                                anchors.topMargin: 12
                                anchors.bottomMargin: 16
                                icon.name: parent.modelData.icon
                                text: parent.modelData.name
                                checked: win.currentPage === parent.index
                                onClicked: win.currentPage = parent.index
                            }
                        }
                    }
                }
            }
        }
    }
}
