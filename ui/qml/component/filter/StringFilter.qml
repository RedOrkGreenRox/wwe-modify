pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import waywallen.control as WC
import Qcm.Material as MD

QtObject {
    id: root
    property var filter: null
    property string value: ""
    property int condition: WC.StringCondition.STRING_CONDITION_UNSPECIFIED
    property WC.wallpaperStringFilter subfilter
    property bool _syncing: false

    readonly property var conditionModel: [
        { name: qsTr("contains"),     value: WC.StringCondition.STRING_CONDITION_CONTAINS },
        { name: qsTr("not contains"), value: WC.StringCondition.STRING_CONDITION_CONTAINS_NOT },
        { name: qsTr("is"),           value: WC.StringCondition.STRING_CONDITION_IS },
        { name: qsTr("is not"),       value: WC.StringCondition.STRING_CONDITION_IS_NOT },
        { name: qsTr("any"),          value: WC.StringCondition.STRING_CONDITION_UNSPECIFIED }
    ]

    readonly property Component valueDelegate: Component {
        MD.InputChip {
            id: valueChip
            visible: root.condition !== WC.StringCondition.STRING_CONDITION_UNSPECIFIED
            text: root.value
            onClicked: edit = true
            editDelegate: MD.TextInput {
                text: root.value
                onAccepted: {
                    root.value = text;
                    valueChip.edit = false;
                }
            }
        }
    }

    function syncFromFilter() {
        if (!filter)
            return;
        if (!filter.hasStringFilter)
            filter.stringFilter = subfilter;
        const active = filter.hasStringFilter ? filter.stringFilter : subfilter;
        _syncing = true;
        condition = active.condition;
        value = active.value;
        _syncing = false;
    }

    function commitToFilter() {
        if (!filter || _syncing)
            return;
        subfilter.condition = condition;
        subfilter.value = value;
        filter.stringFilter = subfilter;
    }

    onFilterChanged: syncFromFilter()
    onConditionChanged: commitToFilter()
    onValueChanged: commitToFilter()
}
