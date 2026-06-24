pragma Singleton
import QtQml

// Frontend page registry.
//
// This is intentionally a QML singleton rather than a plain JavaScript array:
// assigning a new array to `pages` emits `pagesChanged`, so Window.qml and
// other consumers update when a module registers a page.  It is still a
// prototype/static registry, but it has the same shape that real UI modules can
// target later: each module contributes one descriptor with a stable id,
// display metadata and a component URL.
QtObject {
    id: root

    // Stable page descriptors.  Keep `id` values immutable: hotkey bindings and
    // deep-link helpers refer to them.
    property var pages: [
        {
            id: "wallpapers",
            name: qsTr("Wallpapers"),
            icon: "wallpaper",
            component: "qrc:/waywallen/ui/qml/page/WallpaperPage.qml",
            cacheable: true,
            openAction: "open_wallpapers",
            order: 10
        },
        {
            id: "workshop",
            name: qsTr("Workshop"),
            icon: "extension",
            component: "qrc:/waywallen/ui/qml/page/WorkshopPage.qml",
            // Keep WebEngine alive while switching tabs; otherwise it reloads
            // and loses navigation/scroll state on every page change.
            cacheable: true,
            openAction: "open_workshop",
            order: 20
        },
        {
            id: "displays",
            name: qsTr("Displays"),
            icon: "monitor",
            component: "qrc:/waywallen/ui/qml/page/DisplaysPage.qml",
            cacheable: false,
            openAction: "open_displays",
            order: 30
        },
        {
            id: "status",
            name: qsTr("Status"),
            icon: "monitor_heart",
            component: "qrc:/waywallen/ui/qml/page/StatusPage.qml",
            cacheable: false,
            openAction: "open_status",
            order: 40
        },
        {
            id: "plugins",
            name: qsTr("Plugins"),
            icon: "extension",
            component: "qrc:/waywallen/ui/qml/page/PluginManagePage.qml",
            cacheable: false,
            openAction: "open_plugins",
            order: 50
        },
        {
            id: "settings",
            name: qsTr("Settings"),
            icon: "settings",
            component: "qrc:/waywallen/ui/qml/page/SettingsPage.qml",
            cacheable: false,
            openAction: "open_settings",
            order: 60
        }
    ]

    function sortedPages(list) {
        const copy = (list || []).slice();
        copy.sort(function(a, b) {
            const ao = Number(a.order || 0);
            const bo = Number(b.order || 0);
            if (ao !== bo)
                return ao - bo;
            return String(a.id || "").localeCompare(String(b.id || ""));
        });
        return copy;
    }

    function normalizePage(page) {
        if (!page || !page.id || !page.component) {
            console.warn("PageRegistry.addPage: invalid page descriptor", page);
            return null;
        }
        return {
            id: String(page.id),
            name: String(page.name || page.id),
            icon: String(page.icon || "help"),
            component: String(page.component),
            cacheable: page.cacheable === true,
            openAction: String(page.openAction || ("open_" + page.id)),
            order: Number(page.order || 1000)
        };
    }

    // Register or replace a page. Replacing by id lets a future external module
    // override a built-in descriptor without duplicating navigation entries.
    function addPage(page) {
        const nextPage = normalizePage(page);
        if (!nextPage)
            return false;

        const next = [];
        let replaced = false;
        for (let i = 0; i < root.pages.length; ++i) {
            if (root.pages[i].id === nextPage.id) {
                next.push(nextPage);
                replaced = true;
            } else {
                next.push(root.pages[i]);
            }
        }
        if (!replaced)
            next.push(nextPage);
        root.pages = sortedPages(next);
        return true;
    }

    function removePage(id) {
        const key = String(id || "");
        const next = root.pages.filter(function(p) { return p.id !== key; });
        if (next.length === root.pages.length)
            return false;
        root.pages = next;
        return true;
    }

    function indexOf(id) {
        const key = String(id || "");
        for (let i = 0; i < root.pages.length; ++i) {
            if (root.pages[i].id === key)
                return i;
        }
        return -1;
    }

    function pageById(id) {
        const idx = indexOf(id);
        return idx >= 0 ? root.pages[idx] : null;
    }
}
