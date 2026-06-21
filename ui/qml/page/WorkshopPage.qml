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

    // Workshop page state machine:
    //   "idle"            — initial, nothing attempted yet
    //   "embeddedLoading" — Full: QtWebEngine component is being created
    //   "embeddedReady"   — Full: browser is live
    //   "embeddedFailed"  — Full: browser failed to load, showed fallback
    //   "externalOnly"    — Lite: no embedded browser available
    property string workshopState: "idle"
    property string statusText: ""

    // Current URL inside the embedded browser (empty for Lite).
    property string currentEmbeddedUrl: ""
    property Item embeddedBrowser: null

    // -----------------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------------

    function openWithSteam() {
        MD.Util.openUrlExternally(root.steamDeepLink);
    }

    function openWithSystemBrowser(url) {
        MD.Util.openUrlExternally(url || root.workshopUrl);
    }

    function openCurrentPageExternally() {
        const url = root.currentEmbeddedUrl.length > 0
            ? root.currentEmbeddedUrl
            : root.workshopUrl;
        root.openWithSystemBrowser(url);
    }

    function clearWorkshopCache() {
        // Drop the embedded browser so its profile is released, then
        // delete the cache directory and reload.
        if (root.embeddedBrowser) {
            root.embeddedBrowser.destroy();
            root.embeddedBrowser = null;
        }
        root.workshopState = "idle";
        root.statusText = qsTr("Workshop session cleared. Reloading…");

        // Remove the on-disk profile via Qt's FileSelector is not directly
        // available in QML; open a folder action as a practical shortcut so
        // the user can clear manually if needed. A future daemon RPC can
        // handle this more cleanly.
        const profilePath = StandardPaths.writableLocation(
            StandardPaths.GenericDataLocation) + "/waywallen/steam-workshop-webengine";
        MD.Util.openUrlExternally("file://" + profilePath);

        // Restart the embedded browser after a short delay.
        Qt.callLater(() => { root.tryOpenEmbedded(); });
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
        if (root.embeddedBrowser) {
            return true;
        }

        root.workshopState = "embeddedLoading";
        root.statusText = qsTr("Opening embedded Steam Workshop…");

        const component = Qt.createComponent(
            "qrc:/waywallen/ui/qml/component/EmbeddedWorkshop.qml");

        if (component.status === Component.Error) {
            root._onEmbeddedUnavailable(component.errorString());
            return false;
        }

        if (component.status === Component.Ready) {
            return root.createEmbedded(component);
        }

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
        const object = component.createObject(root, { "workshopUrl": root.workshopUrl });
        if (!object) {
            root._onEmbeddedUnavailable("createObject returned null");
            return false;
        }

        root.embeddedBrowser = object;
        root.workshopState = "embeddedReady";
        root.statusText = "";
        object.forceActiveFocus();

        object.loginRequired.connect(function () {
            // Steam login page is shown inside the browser itself.
        });
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

    Component.onCompleted: {
        // Full build: try embedded browser immediately.
        // Lite build: EmbeddedWorkshop.qml is absent → falls to externalOnly.
        root.tryOpenEmbedded();
    }

    // -----------------------------------------------------------------------
    // Embedded browser area
    // -----------------------------------------------------------------------

    Rectangle {
        anchors.fill: parent
        visible: root.workshopState !== "embeddedReady"
        color: "transparent"
    }

    // -----------------------------------------------------------------------
    // Lite / fallback launcher panel (externalOnly or embeddedFailed or idle)
    // -----------------------------------------------------------------------

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 20
        width: Math.min(480, parent.width - 48)
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
            text: qsTr(
                "Subscribe to wallpapers through Steam or your browser.\n" +
                "New subscriptions are imported automatically after Steam syncs."
            )
        }

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            typescale: MD.Token.typescale.body_medium
            wrapMode: Text.WordWrap
            visible: root.workshopState === "embeddedFailed" && root.statusText.length > 0
            text: root.statusText
            color: MD.Token.color.error
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
                visible: root.workshopState === "embeddedFailed"
                text: qsTr("Retry")
                onClicked: {
                    root.embeddedBrowser = null;
                    root.workshopState = "idle";
                    root.tryOpenEmbedded();
                }
            }
        }

        MD.Label {
            visible: root.workshopState === "externalOnly"
            Layout.alignment: Qt.AlignHCenter
            typescale: MD.Token.typescale.label_small
            color: MD.Token.color.on_surface_variant
            text: qsTr("Lite build · embedded browser not included")
            opacity: 0.7
        }
    }

    // Loading spinner (embeddedLoading state)
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        visible: root.workshopState === "embeddedLoading"
        z: 10

        MD.CircularIndicator {
            Layout.alignment: Qt.AlignHCenter
        }

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            text: root.statusText
            typescale: MD.Token.typescale.body_medium
        }
    }

    // -----------------------------------------------------------------------
    // Bottom action bar — visible when embedded browser is live
    // -----------------------------------------------------------------------

    MD.Pane {
        id: m_action_bar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 12
        visible: root.workshopState === "embeddedReady"
        z: 20
        padding: 8

        contentItem: RowLayout {
            spacing: 4

            MD.Label {
                Layout.fillWidth: true
                text: root.statusText
                typescale: MD.Token.typescale.body_small
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                color: MD.Token.color.on_surface_variant
                visible: root.statusText.length > 0
            }

            Item { Layout.fillWidth: true; visible: root.statusText.length === 0 }

            MD.Button {
                text: qsTr("Reload")
                mdState.type: MD.Enum.BtTonal
                onClicked: root.reloadEmbedded()
            }

            MD.Button {
                text: qsTr("Open in Steam")
                mdState.type: MD.Enum.BtTonal
                onClicked: root.openWithSteam()
            }

            MD.Button {
                text: qsTr("Open externally")
                mdState.type: MD.Enum.BtTonal
                onClicked: root.openCurrentPageExternally()
            }

            MD.Button {
                text: qsTr("Clear session")
                mdState.type: MD.Enum.BtTonal
                onClicked: root.clearWorkshopCache()
            }
        }
    }
}
