pragma ComponentBehavior: Bound
pragma ValueTypeBehavior: Assertable
import QtQuick
import Qcm.Material as MD
import waywallen.ui as W

// Wallpaper thumbnail view.
//
// When `source` (daemon-supplied preview file) is set, render it directly
// so animated formats (GIF/APNG/WebP) actually animate — the thumbnail
// pipeline transcodes to a single-frame PNG and would kill animation.
// When `source` is empty (typically video wallpapers), fall back to
// `W.ThumbnailRequest` which extracts a still frame from `resource`.
Item {
    id: root

    property string source
    property string resource
    property string wpType
    property int    fillMode: Image.PreserveAspectFit

    readonly property bool _useDirect: root.source.length > 0
    readonly property url  _displayUrl: _useDirect
                                        ? Qt.url("file://" + root.source)
                                        : req.cachePath

    readonly property int    state    : _useDirect ? W.ThumbnailRequest.Ready : req.state
    readonly property url    cachePath: _displayUrl

    property alias paintedWidth     : m_image.paintedWidth
    property alias paintedHeight    : m_image.paintedHeight
    property alias status           : m_image.status
    property alias sourceSize       : m_image.sourceSize
    property alias verticalAlignment: m_image.verticalAlignment

    W.ThumbnailRequest {
        id: req
        source  : ""
        resource: root._useDirect ? "" : root.resource
        wpType  : root._useDirect ? "" : root.wpType
    }

    AnimatedImage {
        id: m_image
        anchors.fill: parent
        source: root._displayUrl
        fillMode: root.fillMode
        asynchronous: true
        cache: true
        playing: true
        // Loading a non-animated image flips `playing` to false; re-arm
        // it on every Ready so a later animated source resumes playback.
        onStatusChanged: if (status === AnimatedImage.Ready) playing = true
        layer.enabled: true
        layer.effect: MD.RoundClip {
            corners: MD.Util.corners(MD.Token.shape.corner.extra_small)
            size: Qt.vector2d(m_image.width, m_image.height)
        }
    }
}
