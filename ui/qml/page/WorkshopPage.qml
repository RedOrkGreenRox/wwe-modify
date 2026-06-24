pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQml
import Qcm.Material as MD

Item {
    id: root

    readonly property string workshopUrl: "https://steamcommunity.com/app/431960/workshop/"
    readonly property string steamDeepLink: "steam://url/SteamWorkshopPage/431960"

    // State machine kept local to the Workshop page:
    //   idle            — initial state before any strategy is attempted
    //   embeddedLoading — QtWebEngine component is being created
    //   embeddedReady   — embedded browser is live
    //   embeddedFailed  — embedded browser exists but failed to load a page
    //   externalOnly    — QtWebEngine component is not available in this build
    property string workshopState: "idle"
    property string statusText: ""
    property string activeWorkshopUrl: root.workshopUrl
    property string currentEmbeddedUrl: ""
    property Item embeddedBrowser: null

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

    function retryEmbeddedLoad() {
        if (root.embeddedBrowser) {
            root.embeddedBrowser.destroy();
            root.embeddedBrowser = null;
        }
        root.workshopState = "idle";
        root.statusText = "";
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

    Component.onCompleted: root.tryOpenEmbedded()

    Rectangle {
        anchors.fill: parent
        visible: root.workshopState !== "embeddedReady"
        color: "transparent"
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 20
        width: Math.min(520, parent.width - 48)
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
            text: qsTr("Open the Steam Workshop in Steam or in your browser. Subscribed items are handled by Steam and the installed wallpaper source plugins.")
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

    MD.Pane {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 12
        visible: root.workshopState === "embeddedReady"
        z: 20
        padding: 8

        contentItem: RowLayout {
            spacing: 8

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
                mdState.type: MD.Enum.BtFilledTonal
                onClicked: root.reloadEmbedded()
            }

            MD.Button {
                text: qsTr("Open in Steam")
                mdState.type: MD.Enum.BtFilledTonal
                onClicked: root.openWithSteam()
            }

            MD.Button {
                text: qsTr("Open externally")
                mdState.type: MD.Enum.BtFilledTonal
                onClicked: root.openCurrentPageExternally()
            }
        }
    }
}
