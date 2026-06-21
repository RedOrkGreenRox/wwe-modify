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
    signal currentUrlChanged(string url)

    // Keep Steam cookies outside the AppImage mount and outside any temporary
    // runtime directory.  StandardPaths returns a file:// URL in QML; WebEngine
    // needs a plain filesystem path, otherwise cookies/cache may not persist.
    readonly property string profileBasePath: decodeURIComponent(String(StandardPaths.writableLocation(StandardPaths.GenericDataLocation)).replace(/^file:\/\//, "")) + "/waywallen/steam-workshop-webengine"
    readonly property string profileStoragePath: profileBasePath + "/profile"
    readonly property string profileCachePath: profileBasePath + "/cache"
    property bool loginSignalEmitted: false

    function reload() {
        web.reload();
    }

    function focusWorkshopSearch() {
        web.runJavaScript(`
            (() => {
                const selectors = [
                    '#workshopSearchText',
                    'input[name="searchtext"]',
                    'input[name="term"]',
                    'input[type="search"]',
                    'input[placeholder*="Search" i]'
                ];
                for (const selector of selectors) {
                    const el = document.querySelector(selector);
                    if (el) {
                        el.focus();
                        if (el.select) el.select();
                        return true;
                    }
                }
                return false;
            })();
        `);
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
                || text.indexOf("войти через steam") !== -1
                || text.indexOf("anmelden mit steam") !== -1
                || text.indexOf("se connecter avec steam") !== -1
                || text.indexOf("iniciar sesión con steam") !== -1
                || text.indexOf("entrar com steam") !== -1
                || text.indexOf("accedi con steam") !== -1
                || text.indexOf("steam’da oturum aç") !== -1
                || text.indexOf("スティームでサインイン") !== -1
                || text.indexOf("steam으로 로그인") !== -1
                || text.indexOf("使用steam登录") !== -1
                || text.indexOf("zaloguj się przez steam") !== -1;

            if (!result.hasAccount && (result.hasLoginLink || loginPage)) {
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
        // Set explicit disk paths before storageName/page creation; otherwise
        // QtWebEngine may initialize the profile in its generated default path.
        offTheRecord: false
        persistentStoragePath: root.profileStoragePath
        cachePath: root.profileCachePath
        storageName: "waywallen-steam-workshop"
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
        httpCacheType: WebEngineProfile.DiskHttpCache
        httpUserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    }

    WebEngineView {
        id: web
        anchors.fill: parent
        profile: steamProfile
        url: root.workshopUrl
        backgroundColor: "#121212"
        focus: true
        settings.javascriptEnabled: true
        settings.localStorageEnabled: true

        Keys.onPressed: event => {
            if (event.key === Qt.Key_F5 || (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier))) {
                web.reload();
                event.accepted = true;
            } else if (event.key === Qt.Key_F && (event.modifiers & Qt.ControlModifier)) {
                root.focusWorkshopSearch();
                event.accepted = true;
            } else if (event.key === Qt.Key_Back || (event.key === Qt.Key_Left && (event.modifiers & Qt.AltModifier))) {
                if (web.canGoBack)
                    web.goBack();
                event.accepted = true;
            } else if (event.key === Qt.Key_Forward || (event.key === Qt.Key_Right && (event.modifiers & Qt.AltModifier))) {
                if (web.canGoForward)
                    web.goForward();
                event.accepted = true;
            }
        }

        onUrlChanged: {
            root.currentUrlChanged(url.toString());
            if (root.looksLikeLoginUrl(url) && !root.loginSignalEmitted) {
                root.loginSignalEmitted = true;
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
