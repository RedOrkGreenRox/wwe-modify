#include <QGuiApplication>
#include <QCoreApplication>
#include <QCommandLineParser>
#include <QLoggingCategory>
#include <QtQml/QQmlExtensionPlugin>
#include <QIcon>
#include <QByteArray>
#include <QString>
#include <cstdlib>
#include <cstdio>
#ifdef WAYWALLEN_HAS_WEBENGINE
#    include <QtWebEngineQuick/QtWebEngineQuick>
#endif
Q_IMPORT_QML_PLUGIN(waywallen_uiPlugin)

import ncrequest;
import waywallen;

namespace {

// Capture the default handler so we can chain into it after filtering.
QtMessageHandler g_default_qt_handler = nullptr;

// Filter for noisy / benign Qt diagnostics that we can't fix upstream and
// that would otherwise drown out useful output on stderr:
//
//   * "Mutable view on type already registered from type QHash<QString,...>
//      to type QProtobufRepeatedIterator" — emitted by Qt Protobuf every
//      time a `map<string, T>` field is materialised into QML and re-
//      registers the same mutable view (control.proto has several
//      `map<string,string>` and `map<string,PluginSettings>` fields, hence
//      the duplicate registrations). The first registration wins; the
//      repeats are no-ops. Tracked upstream against qtgrpc.
//
//   * "qt.qpa.services: Failed to register with host portal ... Connection
//      already associated with an application ID" — the embedded Chromium
//      inside QtWebEngine tries to (re-)register a portal app id over a
//      bus connection that the host process has already claimed. Benign;
//      nothing requires the portal app id to be owned twice.
//
//   * "QML VerticalFlickable: Binding loop detected for property
//      \"contentHeight\"" originating from Qcm.Material's NavigationRail.
//      We fix the structural cause in Window.qml (the rail header's
//      implicitHeight no longer depends on a child whose y depends on a
//      sibling), but any stray occurrence from third-party imports we
//      can't reach should not panic users.
bool message_is_suppressed(QtMsgType type, const QMessageLogContext& ctx, const QString& msg) {
    if (type != QtWarningMsg) {
        return false;
    }
    if (msg.startsWith(QStringLiteral("Mutable view on type already registered"))) {
        return true;
    }
    if (ctx.category && qstrcmp(ctx.category, "qt.qpa.services") == 0 &&
        msg.contains(QStringLiteral("Connection already associated with an application ID"))) {
        return true;
    }
    if (msg.contains(QStringLiteral("VerticalFlickable")) &&
        msg.contains(QStringLiteral("Binding loop"))) {
        return true;
    }
    return false;
}

void waywallen_qt_message_handler(QtMsgType type, const QMessageLogContext& ctx,
                                  const QString& msg) {
    if (message_is_suppressed(type, ctx, msg)) {
        return;
    }
    if (g_default_qt_handler) {
        g_default_qt_handler(type, ctx, msg);
    } else {
        std::fputs(qPrintable(msg), stderr);
        std::fputc('\n', stderr);
    }
}

#ifdef WAYWALLEN_HAS_WEBENGINE
// Tune Chromium's command line *before* QtWebEngineQuick::initialize().
// Two concrete problems we hit on Wayland sessions:
//
//   1. "ERROR: ui/ozone/platform/wayland/gpu/wayland_surface_factory.cc:249
//       '--ozone-platform=wayland' is not compatible with Vulkan."
//      Chromium's Ozone/Wayland path refuses to use Vulkan. Our renderer
//      uses Vulkan in a separate process; the embedded WebView only needs
//      GL, so disable Vulkan inside Chromium and pin GL to EGL.
//
//   2. "qt.qpa.services: Failed to register with host portal ... Connection
//       already associated with an application ID."
//      The embedded Chromium tries to register its own portal app id on a
//      bus connection already owned by waywallen. Disabling the Wayland
//      portal-window-decorations feature stops the duplicate registration.
//
// Respect any value the user already exported through the environment.
void prepare_webengine_environment() {
    QByteArray current = qgetenv("QTWEBENGINE_CHROMIUM_FLAGS");
    auto append_if_missing = [&](const char* flag) {
        if (! current.contains(flag)) {
            if (! current.isEmpty() && ! current.endsWith(' ')) {
                current.append(' ');
            }
            current.append(flag);
        }
    };
    append_if_missing("--disable-features=Vulkan");
    append_if_missing("--use-gl=egl");
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS", current);
}
#endif

} // namespace

int main(int argc, char** argv) {
    // Install message filter *before* anything else touches qWarning so the
    // very first Qt Protobuf registration call doesn't sneak past us.
    g_default_qt_handler = qInstallMessageHandler(waywallen_qt_message_handler);

    ncrequest::global_init();
#ifdef WAYWALLEN_HAS_WEBENGINE
    prepare_webengine_environment();
    QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);
    QtWebEngineQuick::initialize();
#endif
    QGuiApplication gui_app(argc, argv);
    gui_app.setDesktopFileName(APP_ID);
    gui_app.setOrganizationName("waywallen");
    gui_app.setOrganizationDomain("waywallen.org");
    gui_app.setApplicationName(APP_NAME);
    gui_app.setApplicationVersion(APP_VERSION);

    // Set the window/app icon for Wayland / X11.
    // The QML module resource prefix moved between Qt versions, so try both.
    QIcon app_icon(QStringLiteral(":/qt/qml/waywallen/ui/assets/waywallen-ui.svg"));
    if (app_icon.isNull()) {
        app_icon = QIcon(QStringLiteral(":/waywallen/ui/assets/waywallen-ui.svg"));
    }
    gui_app.setWindowIcon(app_icon);

    QCommandLineParser parser;
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addOption(
        { "ws-port", "Override the WebSocket port (normally discovered via DBus).", "port" });
    parser.process(gui_app);

    quint16 ws_port = 0;
    if (parser.isSet("ws-port")) {
        bool ok = false;
        ws_port = parser.value("ws-port").toUShort(&ok);
        if (! ok) {
            qCritical("invalid --ws-port value: %s", qPrintable(parser.value("ws-port")));
            return 1;
        }
    }

    waywallen::App app(ws_port, {});
    app.init();

    return gui_app.exec();
}
