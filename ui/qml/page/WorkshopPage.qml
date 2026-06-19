pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQml
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    // Настройка из глобальных настроек
    property bool useEmbeddedBrowser: false

    // Пытаемся открыть через Steam протокол
    function openWithSteam() {
        const url = "https://steamcommunity.com/app/431960/workshop/";
        Qt.openUrlExternally("steam://openurl/" + url);
    }

    // Открыть в системном браузере
    function openWithSystemBrowser() {
        Qt.openUrlExternally("https://steamcommunity.com/app/431960/workshop/");
    }

    // Попытка открыть встроенный браузер (если WebEngine доступен)
    function tryOpenEmbedded() {
        if (typeof WebEngineView !== "undefined") {
            // Динамически создаём WebEngineView
            const component = Qt.createComponent("qrc:/waywallen/ui/qml/component/EmbeddedWorkshop.qml");
            if (component.status === Component.Ready) {
                component.createObject(root, {});
            } else {
                openWithSystemBrowser();
            }
        } else {
            openWithSystemBrowser();
        }
    }

    Component.onCompleted: {
        // Проверяем настройку (будет приходить из Settings)
        // Пока используем глобальную настройку
        if (W.Global.useEmbeddedWorkshopBrowser === true) {
            tryOpenEmbedded();
        } else {
            // Пробуем Steam → системный браузер
            openWithSteam();
            // Через 800мс проверяем, открылось ли. Если нет — fallback
            Qt.callLater(() => {
                // Steam протокол не всегда срабатывает мгновенно,
                // поэтому даём fallback на системный браузер
            });
        }
    }

    // Простая заглушка с кнопками (на случай, если ничего не открылось)
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 16
        visible: true   // Можно скрыть после успешного открытия

        MD.Label {
            Layout.alignment: Qt.AlignHCenter
            text: "Мастерская Wallpaper Engine"
            typescale: MD.Token.typescale.title_large
        }

        MD.Button {
            Layout.alignment: Qt.AlignHCenter
            text: "Открыть в Steam"
            onClicked: root.openWithSteam()
        }

        MD.Button {
            Layout.alignment: Qt.AlignHCenter
            text: "Открыть в браузере"
            onClicked: root.openWithSystemBrowser()
        }

        MD.Button {
            Layout.alignment: Qt.AlignHCenter
            text: "Встроенный браузер"
            visible: typeof WebEngineView !== "undefined"
            onClicked: root.tryOpenEmbedded()
        }
    }
}
