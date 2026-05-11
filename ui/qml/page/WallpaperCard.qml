pragma ValueTypeBehavior: Assertable
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    required property var model
    required property int index
    property var wallpaper: model

    width: GridView.view ? GridView.view.cellWidth : 0
    height: GridView.view ? GridView.view.cellHeight : 0

    focusPolicy: Qt.StrongFocus

    signal clicked

    readonly property int _radius: MD.Token.shape.corner.extra_small

    Item {
        id: m_cell
        anchors.fill: parent
        anchors.margins: 6

        W.ThumbnailImage {
            id: m_thumb
            anchors.fill: parent
            source  : root.wallpaper?.preview ?? ""
            resource: root.wallpaper?.resource ?? ""
            wpType  : root.wallpaper?.wpType ?? ""
            fillMode: Image.PreserveAspectCrop
        }

        // Scrim aligns to the image control's bounds; spans the
        // title-top → image-bottom overlap.
        Rectangle {
            anchors.left  : m_thumb.left
            anchors.right : m_thumb.right
            anchors.bottom: m_thumb.bottom
            height: Math.max(0, m_thumb.height - m_title.y)
            visible: height > 0
            radius: root._radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.6) }
            }
        }

        MD.Text {
            id: m_title
            anchors.left  : parent.left
            anchors.right : parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            text: root.wallpaper?.name || "Untitled"
            typescale: MD.Token.typescale.title_small
            color: "white"
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
            maximumLineCount: 2
            leftPadding: 8
            rightPadding: 8
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.clicked()
        }
    }
}
