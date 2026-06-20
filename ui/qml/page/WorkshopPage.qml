pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQml
import Qcm.Material as MD

Item {
    id: root

    readonly property string workshopUrl: "https://steamcommunity.com/app/431960/workshop/"

    property Item embeddedBrowser: null
    property string statusText: qsTr("Opening embedded Steam Workshop…")
    property bool compactStatus: false

    function openWithSystemBrowser(url) {
        MD.Util.openUrlExternally(url || root.workshopUrl);
    }

    function reloadEmbedded() {
        if (root.embeddedBrowser && root.embeddedBrowser.reload) {
            root.statusText = qsTr("Reloading embedded Steam Workshop…");
            root.compactStatus = true;
            root.embeddedBrowser.reload();
        } else {
            root.tryOpenEmbedded();
        }
    }

    function tryOpenEmbedded() {
        if (root.embeddedBrowser) {
            return true;
        }

        root.statusText = qsTr("Opening embedded Steam Workshop…");
        root.compactStatus = false;

        const component = Qt.createComponent("qrc:/waywallen/ui/qml/component/EmbeddedWorkshop.qml");
        if (component.status === Component.Error) {
            console.warn("QtWebEngine is not available; opening Workshop externally:", component.errorString());
            root.statusText = qsTr("Embedded browser is not available. Opening Workshop in your default browser…");
            root.openWithSystemBrowser(root.workshopUrl);
            return false;
        }

        if (component.status === Component.Ready) {
            return root.createEmbedded(component);
        }

        component.statusChanged.connect(function () {
            if (component.status === Component.Ready) {
                root.createEmbedded(component);
            } else if (component.status === Component.Error) {
                console.warn("QtWebEngine is not available; opening Workshop externally:", component.errorString());
                root.statusText = qsTr("Embedded browser is not available. Opening Workshop in your default browser…");
                root.openWithSystemBrowser(root.workshopUrl);
            }
        });
        return true;
    }

    function createEmbedded(component) {
        const object = component.createObject(root, { "workshopUrl": root.workshopUrl });
        if (!object) {
            console.warn("Failed to create embedded Workshop view; opening Workshop externally");
            root.statusText = qsTr("Could not start embedded browser. Opening Workshop in your default browser…");
            root.openWithSystemBrowser(root.workshopUrl);
            return false;
        }

        root.embeddedBrowser = object;
        root.statusText = "";
        root.compactStatus = true;
        object.forceActiveFocus();

        object.loginRequired.connect(function () {
            root.statusText = qsTr("Sign in to Steam in the embedded browser. Your session will be saved for future launches.");
            root.compactStatus = true;
        });
        object.loadFailed.connect(function (reason) {
            console.warn("Embedded Workshop load failed:", reason);
            root.statusText = qsTr("Embedded Workshop failed to load. Opening Workshop in your default browser…");
            root.compactStatus = false;
            root.openWithSystemBrowser(root.workshopUrl);
        });
        object.statusMessage.connect(function (message) {
            root.statusText = message;
            root.compactStatus = message.length > 0;
        });
        return true;
    }

    Component.onCompleted: {
        // Full AppImage: creates the bundled QtWebEngine browser immediately.
        // Lite AppImage: component is absent, so it falls back to system browser.
        root.tryOpenEmbedded();
    }

    Rectangle {
        anchors.fill: parent
        visible: !root.embeddedBrowser
        color: "transparent"
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        visible: !root.embeddedBrowser
        z: 10

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Wallpaper Engine Workshop")
            typescale: MD.Token.typescale.title_large
        }

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: 520
            horizontalAlignment: Text.AlignHCenter
            text: root.statusText
            typescale: MD.Token.typescale.body_medium
            wrapMode: Text.WordWrap
        }

        MD.Button {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Open in browser")
            onClicked: root.openWithSystemBrowser(root.workshopUrl)
        }
    }

    MD.Pane {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 12
        visible: root.embeddedBrowser && root.statusText.length > 0
        z: 20
        padding: 12

        contentItem: RowLayout {
            spacing: 8

            MD.Label {
                Layout.fillWidth: true
                text: root.statusText
                typescale: MD.Token.typescale.body_medium
                wrapMode: Text.WordWrap
            }

            MD.Button {
                text: qsTr("Reload")
                onClicked: root.reloadEmbedded()
            }

            MD.Button {
                text: qsTr("Open externally")
                onClicked: root.openWithSystemBrowser(root.workshopUrl)
            }
        }
    }
}
