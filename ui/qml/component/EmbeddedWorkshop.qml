pragma ComponentBehavior: Bound
import QtQuick
import QtWebEngine

Item {
    id: root
    anchors.fill: parent

    required property url workshopUrl

    // Dedicated persistent Chromium profile: Steam login/session cookies must
    // survive AppImage restarts, otherwise the Workshop integration feels
    // broken even if the embedded browser itself starts correctly.
    WebEngineProfile {
        id: steamProfile
        storageName: "waywallen-steam-workshop"
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
        httpCacheType: WebEngineProfile.DiskHttpCache
    }

    WebEngineView {
        anchors.fill: parent
        profile: steamProfile
        url: root.workshopUrl
        settings.javascriptEnabled: true
        settings.localStorageEnabled: true
    }
}
