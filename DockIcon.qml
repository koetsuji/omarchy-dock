import QtQuick

// A dock logo: the cached normalized PNG, drawn at the full cell. Until it is
// ready the raw icon shows in the same box and cross-fades into it.
Item {
  id: icon

  property string raw: ""
  property string normalized: ""
  // The last picture that was ready: a theme or style change asks for new ones,
  // and this keeps the old one on screen until they arrive instead of flashing
  // the raw icon.
  property string lastGood: ""
  onNormalizedChanged: if (normalized) lastGood = normalized
  readonly property string shownSource: normalized || lastGood
  property real fade: 1
  // The raw icon is only a last resort, for an icon the normalizer failed on. While a new icon is
  // being made nothing is drawn, so only the finished version is ever seen.
  property bool showRaw: false
  // The size factor from iconScaleOverrides.
  property real factor: 1
  // The cached PNG's canvas as a multiple of this item (squircle tiles carry
  // a shadow margin).
  property real canvas: 1
  scale: factor

  readonly property bool ready: norm.status === Image.Ready
  readonly property real canvasWidth: norm.width

  Image {
    anchors.centerIn: parent
    width: Math.round(icon.width * 0.7)
    height: width
    sourceSize: Qt.size(icon.width * 4, icon.height * 4)
    source: icon.showRaw ? icon.raw : ""
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
    mipmap: true
    opacity: icon.ready || !icon.showRaw ? 0 : icon.fade
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
  }

  Image {
    id: norm
    anchors.centerIn: parent
    width: icon.width * icon.canvas
    height: icon.height * icon.canvas
    // 256 px sources, drawn at twice the logical size for the HiDPI panel.
    // The PNG at its own resolution (256 px): magnification draws it up to 1.8x on a 1.6x display.
    sourceSize: Qt.size(256, 256)
    source: icon.shownSource
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
    mipmap: true
    opacity: icon.ready ? icon.fade : 0
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
  }
}
