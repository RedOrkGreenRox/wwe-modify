pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQml
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    readonly property string workshopUrl: "https://steamcommunity.com/app/431960/workshop/"
    readonly property string steamDeepLink: "steam://url/SteamWorkshopPage/431960"

    // State machine kept local to the Workshop page:
    //   idle            — initial state before any strategy is attempted
    //   embeddedLoading — QtWebEngine component is being created
    //   embeddedReady   — embedded browser is live
    //   embeddedFailed  — embedded browser exists but failed to load a page
    //   externalOnly    — QtWebEngine component is not available or external mode is preferred
    property string workshopState: W.Global.workshopOpenMode === "embedded" ? "embeddedLoading" : "externalOnly"
    property string statusText: W.Global.workshopOpenMode === "embedded" ? qsTr("Opening embedded Steam Workshop…") : ""
    property string activeWorkshopUrl: root.workshopUrl
    property string currentEmbeddedUrl: ""
    property Item embeddedBrowser: null

    W.HotkeyRuntime {
        id: hotkeys
    }

    Shortcut {
        sequences: hotkeys.sequences("workshop_reload")
        context: Qt.WindowShortcut
        enabled: root.visible
        onActivated: root.reloadPreferred()
    }

    Connections {
        target: W.Global
        function onWorkshopRequestNonceChanged() {
            if (root.visible)
                root.activatePreferred(true);
        }
        function onWorkshopOpenModeChanged() {
            root.activatePreferred(false);
        }
    }

    function openWithSteam() {
        MD.Util.openUrlExternally(root.steamDeepLink);
    }

    function openWithSystemBrowser(url) {
        MD.Util.openUrlExternally(url || root.activeWorkshopUrl || root.workshopUrl);
    }

    function openCurrentPageExternally() {
        root.openWithSystemBrowser(root.currentEmbeddedUrl.length > 0
                                   ? root.currentEmbeddedUrl
                                   : root.activeWorkshopUrl);
    }

    function destroyEmbedded() {
        if (root.embeddedBrowser) {
            root.embeddedBrowser.destroy();
            root.embeddedBrowser = null;
        }
        root.currentEmbeddedUrl = "";
    }

    function activatePreferred(force) {
        const requestedUrl = String(W.Global.workshopRequestUrl || "");
        if (requestedUrl.length > 0)
            root.activeWorkshopUrl = requestedUrl;
        else if (root.activeWorkshopUrl.length === 0)
            root.activeWorkshopUrl = root.workshopUrl;

        const mode = String(W.Global.workshopOpenMode || "embedded");
        if (mode === "steam") {
            root.destroyEmbedded();
            root.workshopState = "externalOnly";
            root.statusText = qsTr("Opening Steam…");
            root.openWithSteam();
            return;
        }
        if (mode === "browser") {
            root.destroyEmbedded();
            root.workshopState = "externalOnly";
            root.statusText = qsTr("Opening system browser…");
            root.openWithSystemBrowser(root.activeWorkshopUrl);
            return;
        }

        // Embedded browser mode: first activation creates the WebEngine view;
        // repeated activations reload it instead of showing/duplicating buttons.
        if (root.embeddedBrowser) {
            if (force)
                root.reloadEmbedded();
            else
                root.workshopState = "embeddedReady";
            return;
        }
        root.tryOpenEmbedded();
    }

    function reloadPreferred() {
        if (String(W.Global.workshopOpenMode || "embedded") === "embedded")
            root.reloadEmbedded();
        else
            root.activatePreferred(true);
    }

    function retryEmbeddedLoad() {
        root.destroyEmbedded();
        root.workshopState = "embeddedLoading";
        root.statusText = qsTr("Opening embedded Steam Workshop…");
        root.tryOpenEmbedded();
    }

    function reloadEmbedded() {
        if (root.embeddedBrowser && root.embeddedBrowser.reload) {
            root.statusText = qsTr("Reloading…");
            root.embeddedBrowser.reload();
        } else {
            root.tryOpenEmbedded();
        }
    }

    function tryOpenEmbedded() {
        if (root.embeddedBrowser)
            return true;

        root.workshopState = "embeddedLoading";
        root.statusText = qsTr("Opening embedded Steam Workshop…");

        const component = Qt.createComponent("qrc:/waywallen/ui/qml/component/EmbeddedWorkshop.qml");
        if (component.status === Component.Error) {
            root._onEmbeddedUnavailable(component.errorString());
            return false;
        }

        if (component.status === Component.Ready)
            return root.createEmbedded(component);

        component.statusChanged.connect(function () {
            if (component.status === Component.Ready) {
                root.createEmbedded(component);
            } else if (component.status === Component.Error) {
                root._onEmbeddedUnavailable(component.errorString());
            }
        });
        return true;
    }

    function createEmbedded(component) {
        const object = component.createObject(root, { "workshopUrl": root.activeWorkshopUrl });
        if (!object) {
            root._onEmbeddedUnavailable("createObject returned null");
            return false;
        }

        root.embeddedBrowser = object;
        root.workshopState = "embeddedReady";
        root.statusText = "";
        object.forceActiveFocus();

        object.loadFailed.connect(function (reason) {
            console.warn("Embedded Workshop load failed:", reason);
            root.workshopState = "embeddedFailed";
            root.statusText = qsTr("Failed to load Workshop. Try reloading or open externally.");
        });
        object.statusMessage.connect(function (message) {
            root.statusText = message;
        });
        object.currentUrlChanged.connect(function(url) {
            root.currentEmbeddedUrl = url;
        });
        return true;
    }

    function _onEmbeddedUnavailable(reason) {
        console.warn("QtWebEngine unavailable:", reason);
        root.workshopState = "externalOnly";
        root.statusText = "";
    }

    Component.onCompleted: root.activatePreferred(false)

    Rectangle {
        anchors.fill: parent
        visible: root.workshopState !== "embeddedReady"
        color: "transparent"
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 20
        width: Math.min(560, parent.width - 48)
        visible: root.workshopState === "externalOnly"
                 || root.workshopState === "embeddedFailed"
                 || root.workshopState === "idle"
        z: 10

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Wallpaper Engine Workshop")
            typescale: MD.Token.typescale.title_large
        }

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            typescale: MD.Token.typescale.body_medium
            wrapMode: Text.WordWrap
            visible: root.workshopState === "externalOnly"
            text: qsTr("Use Settings → Workshop opening to choose the preferred target. Subscribed items are handled by Steam and the installed wallpaper source plugins.")
        }

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            typescale: MD.Token.typescale.body_medium
            wrapMode: Text.WordWrap
            visible: root.statusText.length > 0
            text: root.statusText
            color: root.workshopState === "embeddedFailed" ? MD.Token.color.error : MD.Token.color.on_surface_variant
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 12

            MD.Button {
                text: qsTr("Open in Steam")
                onClicked: root.openWithSteam()
            }

            MD.Button {
                text: qsTr("Open in browser")
                onClicked: root.openWithSystemBrowser(root.workshopUrl)
            }

            MD.Button {
                text: root.workshopState === "embeddedFailed" ? qsTr("Retry app browser") : qsTr("Open app browser")
                onClicked: root.retryEmbeddedLoad()
            }
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        visible: root.workshopState === "embeddedLoading"
        z: 10

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            text: root.statusText
            typescale: MD.Token.typescale.body_medium
        }
    }

    HoverHandler {
        id: pageHover
    }

    MD.Pane {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 12
        visible: root.workshopState === "embeddedReady"
        opacity: pageHover.hovered || root.statusText.length > 0 ? 1.0 : 0.12
        z: 20
        padding: 6

        Behavior on opacity { NumberAnimation { duration: 120 } }

        contentItem: RowLayout {
            spacing: 6

            MD.Label {
                Layout.maximumWidth: 360
                text: root.statusText
                typescale: MD.Token.typescale.body_small
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                color: MD.Token.color.on_surface_variant
                visible: root.statusText.length > 0
            }

            MD.Button {
                text: qsTr("Reload")
                mdState.type: MD.Enum.BtFilledTonal
                onClicked: root.reloadEmbedded()
            }

            MD.Button {
                text: qsTr("Steam")
                mdState.type: MD.Enum.BtFilledTonal
                onClicked: root.openWithSteam()
            }

            MD.Button {
                text: qsTr("External")
                mdState.type: MD.Enum.BtFilledTonal
                onClicked: root.openCurrentPageExternally()
            }
        }
    }
}
