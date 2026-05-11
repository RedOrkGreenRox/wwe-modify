pragma ComponentBehavior: Bound
import QtQml
import QtQuick

QtObject {
    id: root
    property var filter: null
    property int condition: 0
    readonly property var conditionModel: [
        { name: qsTr("any"), value: 0 }
    ]

    readonly property Component valueDelegate: null
}
