#include <QGuiApplication>
#include <QCommandLineParser>
#include <QtQml/QQmlExtensionPlugin>
#include <QIcon>
Q_IMPORT_QML_PLUGIN(waywallen_uiPlugin)

import ncrequest;
import waywallen;

int main(int argc, char** argv) {
    ncrequest::global_init();
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
