pragma ValueTypeBehavior: Assertable
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

Item {
    id: root

    required property var model
    required property int index
    property var wallpaper: model
    property bool selected: false
    property real itemWidth: width
    property real itemHeight: height
    property int waveNonce: 0
    property int waveOriginIndex: -1
    property int waveColumns: 1

    width: GridView.view ? GridView.view.cellWidth : 0
    height: GridView.view ? GridView.view.cellHeight : 0

    focusPolicy: Qt.StrongFocus

    signal clicked(int modifiers)
    signal selectionRequested(int modifiers)
    signal applyRequested()

    readonly property int _baseRadius: MD.Token.shape.corner.extra_small
    readonly property int _selectedRadius: MD.Token.shape.corner.large
    readonly property int _radius: root.selected ? root._selectedRadius : root._baseRadius
    readonly property real _selectedInset: root._selectedRadius / 2
    readonly property real cardWidth: Math.min(root.itemWidth, root.width)
    readonly property real cardHeight: Math.min(root.itemHeight, root.height)
    readonly property int _waveCols: Math.max(1, root.waveColumns)
    readonly property int _waveOriginRow: root.waveOriginIndex >= 0 ? Math.floor(root.waveOriginIndex / root._waveCols) : 0
    readonly property int _waveOriginCol: root.waveOriginIndex >= 0 ? root.waveOriginIndex % root._waveCols : 0
    readonly property int _waveRow: Math.floor(root.index / root._waveCols)
    readonly property int _waveCol: root.index % root._waveCols
    readonly property real _waveDistance: Math.sqrt(Math.pow(root._waveRow - root._waveOriginRow, 2)
                                                   + Math.pow(root._waveCol - root._waveOriginCol, 2))

    onWaveNonceChanged: {
        if (root.waveOriginIndex >= 0)
            m_apply_wave.restart();
    }

    Rectangle {
        anchors.fill: parent
        visible: root.selected
        color: MD.Token.color.primary_container
    }

    Item {
        id: m_card
        width: root.cardWidth
        height: root.cardHeight
        anchors.centerIn: parent

        Item {
            id: m_cell
            anchors.fill: parent
            anchors.margins: 6 + (root.selected ? root._selectedInset : 0)

            W.ThumbnailImage {
                id: m_thumb
                anchors.fill: parent
                source  : root.wallpaper?.preview ?? ""
                resource: root.wallpaper?.resource ?? ""
                wpType  : root.wallpaper?.wpType ?? ""
                fillMode: Image.PreserveAspectCrop
                radius: root._radius
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

            Rectangle {
                id: m_apply_wave_overlay
                anchors.fill: m_thumb
                radius: root._radius
                color: MD.Token.color.primary
                opacity: 0
            }

            SequentialAnimation {
                id: m_apply_wave
                running: false
                PauseAnimation { duration: Math.min(700, Math.round(root._waveDistance * 70)) }
                NumberAnimation {
                    target: m_apply_wave_overlay
                    property: "opacity"
                    from: 0
                    to: 0.38
                    duration: 120
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: m_apply_wave_overlay
                    property: "opacity"
                    from: 0.38
                    to: 0
                    duration: 520
                    easing.type: Easing.OutCubic
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
                property bool selectionRequestedByHold: false

                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onPressed: selectionRequestedByHold = false
                onCanceled: selectionRequestedByHold = false
                onPressAndHold: mouse => {
                    if (mouse.button !== Qt.LeftButton)
                        return;
                    selectionRequestedByHold = true;
                    root.selectionRequested(mouse.modifiers);
                }
                onClicked: mouse => {
                    if (selectionRequestedByHold) {
                        selectionRequestedByHold = false;
                        return;
                    }
                    if (mouse.button === Qt.RightButton) {
                        root.selectionRequested(mouse.modifiers);
                        return;
                    }
                    if (mouse.button === Qt.MiddleButton) {
                        root.applyRequested();
                        return;
                    }
                    root.clicked(mouse.modifiers);
                }
            }
        }
    }

    Rectangle {
        anchors.top: m_card.top
        anchors.left: m_card.left
        anchors.margins: 8
        width: 32
        height: 32
        radius: width / 2
        visible: root.selected
        color: MD.Token.color.primary
        border.color: MD.Token.color.primary_container
        border.width: 3

        MD.Icon {
            anchors.centerIn: parent
            name: MD.Token.icon.check
            size: 20
            color: MD.Token.color.on_primary
        }
    }
}
