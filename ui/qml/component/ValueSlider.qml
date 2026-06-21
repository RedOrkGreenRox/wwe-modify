pragma ComponentBehavior: Bound
import QtQuick
import Qcm.Material as MD

MD.Slider {
    id: root

    property bool showValue: true
    property string valueText: Math.round(value).toString()
    property string valueMaxText: valueText
    property real valueSpacing: 8
    property MD.typescale valueTypescale: MD.Token.typescale.label_medium
    property color valueColor: MD.Token.color.on_surface_variant
    property int valueHorizontalAlignment: Text.AlignRight
    readonly property real valueTextWidth: Math.ceil(Math.max(valueTextMetric.width, valueMaxTextMetric.width)) + 2

    tailingSpacing: valueSpacing
    tailing: showValue ? valueLabel : null

    MD.TextMetrics {
        id: valueTextMetric
        typescale: root.valueTypescale
        text: root.valueText
        elide: Text.ElideNone
    }

    MD.TextMetrics {
        id: valueMaxTextMetric
        typescale: root.valueTypescale
        text: root.valueMaxText
        elide: Text.ElideNone
    }

    Component {
        id: valueLabel

        MD.Text {
            width: root.valueTextWidth
            horizontalAlignment: root.valueHorizontalAlignment
            typescale: root.valueTypescale
            color: root.valueColor
            text: root.valueText
            wrapMode: Text.NoWrap
            elide: Text.ElideNone
        }
    }
}
