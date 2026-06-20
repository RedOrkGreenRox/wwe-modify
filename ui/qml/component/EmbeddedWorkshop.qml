pragma ComponentBehavior: Bound
import QtCore
import QtQuick
import QtWebEngine

Item {
    id: root
    anchors.fill: parent

    required property url workshopUrl

    signal loginRequired()
    signal loadFailed(string reason)
    signal statusMessage(string message)

    // Keep Steam cookies outside the AppImage mount and outside any temporary
    // runtime directory.  This is stable across AppImage rebuilds/restarts.
    readonly property string profileStoragePath: StandardPaths.writableLocation(StandardPaths.GenericDataLocation) + "/waywallen/steam-workshop-webengine"
    property bool loginSignalEmitted: false

    function reload() {
        web.reload();
    }

    function looksLikeLoginUrl(url) {
        const s = String(url).toLowerCase();
        return s.indexOf("/login") !== -1
            || s.indexOf("login.steampowered.com") !== -1
            || s.indexOf("steamcommunity.com/openid/login") !== -1;
    }

    function checkLoginState() {
        web.runJavaScript(`
            (() => {
                const text = document.body ? document.body.innerText : "";
                const loginLink = document.querySelector('a[href*="/login"], a[href*="login.steampowered.com"], #global_action_menu a[href*="login"]');
                const account = document.querySelector('#global_actions .playerAvatar, #account_pulldown, .user_avatar');
                return {
                    href: location.href,
                    title: document.title || "",
                    hasLoginLink: !!loginLink,
                    hasAccount: !!account,
                    text: text.slice(0, 2000)
                };
            })();
        `, function(result) {
            if (!result)
                return;

            const href = String(result.href || "").toLowerCase();
            const title = String(result.title || "").toLowerCase();
            const text = String(result.text || "").toLowerCase();
            const loginPage = root.looksLikeLoginUrl(href)
                || title.indexOf("sign in") !== -1
                || title.indexOf("login") !== -1
                || text.indexOf("sign in with steam") !== -1
                || text.indexOf("войти через steam") !== -1;

            if (!result.hasAccount && (result.hasLoginLink || loginPage)) {
                root.statusMessage(qsTr("Sign in to Steam in the embedded browser. Your session will be saved for future launches."));
                if (!root.loginSignalEmitted) {
                    root.loginSignalEmitted = true;
                    root.loginRequired();
                }
            } else {
                root.statusMessage("");
            }
        });
    }

    WebEngineProfile {
        id: steamProfile
        storageName: "waywallen-steam-workshop"
        persistentStoragePath: root.profileStoragePath
        cachePath: root.profileStoragePath + "/cache"
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
        httpCacheType: WebEngineProfile.DiskHttpCache
        httpUserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    }

    WebEngineView {
        id: web
        anchors.fill: parent
        profile: steamProfile
        url: root.workshopUrl
        settings.javascriptEnabled: true
        settings.localStorageEnabled: true

        onUrlChanged: {
            if (root.looksLikeLoginUrl(url) && !root.loginSignalEmitted) {
                root.loginSignalEmitted = true;
                root.statusMessage(qsTr("Sign in to Steam in the embedded browser. Your session will be saved for future launches."));
                root.loginRequired();
            }
        }

        onLoadingChanged: function(loadRequest) {
            if (loadRequest.status === WebEngineView.LoadSucceededStatus) {
                root.checkLoginState();
            } else if (loadRequest.status === WebEngineView.LoadFailedStatus) {
                root.loadFailed(loadRequest.errorString || qsTr("unknown error"));
            }
        }
    }
}
