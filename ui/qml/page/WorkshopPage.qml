pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQml
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    readonly property string workshopUrl: "https://steamcommunity.com/app/431960/workshop/"
    property Item embeddedBrowser: null

    function openWithSteam() {
        MD.Util.openUrlExternally("steam://openurl/" + encodeURIComponent(root.workshopUrl));
    }

    function openWithSystemBrowser() {
        MD.Util.openUrlExternally(root.workshopUrl);
    }

    function tryOpenEmbedded() {
        if (root.embeddedBrowser) {
            return true;
        }

        const component = Qt.createComponent("qrc:/waywallen/ui/qml/component/EmbeddedWorkshop.qml");
        if (component.status === Component.Error) {
            console.warn("QtWebEngine is not available; opening Workshop externally:", component.errorString());
            root.openWithSystemBrowser();
            return false;
        }

        if (component.status === Component.Ready) {
            const object = component.createObject(root, { "workshopUrl": root.workshopUrl });
            if (object) {
                root.embeddedBrowser = object;
                return true;
            }

            console.warn("Failed to create embedded Workshop view; opening Workshop externally");
            root.openWithSystemBrowser();
            return false;
        }

        component.statusChanged.connect(function () {
            if (component.status === Component.Ready) {
                const object = component.createObject(root, { "workshopUrl": root.workshopUrl });
                if (object) {
                    root.embeddedBrowser = object;
                } else {
                    root.openWithSystemBrowser();
                }
            } else if (component.status === Component.Error) {
                console.warn("QtWebEngine is not available; opening Workshop externally:", component.errorString());
                root.openWithSystemBrowser();
            }
        });
        return true;
    }

    Component.onCompleted: {
        if (W.Global.useEmbeddedWorkshopBrowser) {
            root.tryOpenEmbedded();
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        visible: !root.embeddedBrowser

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Wallpaper Engine Workshop")
            typescale: MD.Token.typescale.title_large
        }

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            Layout.maximumWidth: 420
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("Open the Wallpaper Engine workshop in Steam, in the system browser, or in the embedded browser when QtWebEngine is installed.")
            typescale: MD.Token.typescale.body_medium
            wrapMode: Text.WordWrap
        }

        MD.Button {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Open in Steam")
            onClicked: root.openWithSteam()
        }

        MD.Button {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Open in browser")
            onClicked: root.openWithSystemBrowser()
        }

        MD.Button {
            Layout.alignment: Qt.AlignHCenter
            text: qsTr("Embedded browser")
            onClicked: root.tryOpenEmbedded()
        }
    }
}
