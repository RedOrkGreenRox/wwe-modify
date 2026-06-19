pragma ComponentBehavior: Bound
import QtQuick
import QtWebEngine

Item {
    anchors.fill: parent

    WebEngineView {
        anchors.fill: parent
        url: "https://steamcommunity.com/app/431960/workshop/"
        settings {
            javascriptEnabled: true
            localStorageEnabled: true
        }
    }
}