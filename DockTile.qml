import QtQuick
import qs.Commons
import qs.Commons as Commons

// One item on the dock. `x` and `magnify` are set by the window's layout (hover
// magnification, section 10.2): the item grows upwards from its baseline, its hit
// area is the grown icon, and what is in `fixed` (the running dots) keeps its size
// and moves with the item.
//
// A press answers at once. The action comes on release over the same item; moving
// more than 8 px while pressed starts a drag (a later milestone) and cancels the
// click. There is no long press.
Item {
  id: tile

  property int size: 56
  // The grow factor from the layout, around the bottom centre.
  property real magnify: 1
  // The hit area also reaches down to the screen edge (a click on the bottom pixel
  // row under an item is a click on it); in unscaled units.
  property real bottomReach: 0
  // With magnification off, hovering lights a highlight behind the icon instead.
  property bool highlightOnHover: false
  // Set by the window from its single pointer handler: a MouseArea with hoverEnabled would
  // swallow the hover that handler needs, so the tiles do not track hover themselves.
  property bool hovered: false
  readonly property bool pressed: area.pressed
  property alias mouse: area
  property bool moved: false
  property point pressAt
  property real wheelAccumulated: 0
  property real lastStep: 0
  default property alias content: face.data
  property alias fixed: overlay.data

  // Dragging (section 10.4): a pointer gesture past 8 px. The points are in window coordinates.
  property bool dragEnabled: false
  property bool dragging: false
  property bool leftPress: false
  property bool ignoreRelease: false
  signal dragStarted(real x, real y)
  signal dragMoved(real x, real y)
  signal dragFinished(real x, real y)
  signal dragCanceled()

  // A click: the button and the keyboard modifiers.
  signal activated(int button, int modifiers)
  signal contextRequested()
  // One step of scrolling, -1 (up) or +1 (down).
  signal scrolled(int direction)
  // A line for the debug event log.
  signal event(string what)

  width: size
  height: size

  Item {
    id: scaler
    anchors.fill: parent
    scale: tile.magnify
    transformOrigin: Item.Bottom

    Rectangle {
      anchors.fill: parent
      radius: Math.round(tile.size * 0.225)
      color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.10)
      visible: tile.highlightOnHover && tile.hovered && !tile.pressed
    }

    Item {
      id: face
      anchors.fill: parent
      // Pressing answers in the same frame: the spring starts moving at once and
      // settles with a little give instead of jumping.
      scale: tile.pressed ? 0.88 : 1
      opacity: tile.pressed ? 0.85 : 1
      transformOrigin: Item.Center
      Behavior on scale {
        enabled: !Style.reduceMotion
        SpringAnimation { spring: 6; damping: 0.28; mass: 0.5; epsilon: 0.001 }
      }
      Behavior on opacity { enabled: !Style.reduceMotion; NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
    }

    MouseArea {
      id: area
      anchors.fill: parent
      anchors.bottomMargin: -tile.bottomReach
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

      function buttonName(button) { return button === Qt.LeftButton ? "left" : button === Qt.RightButton ? "right" : "middle" }

      onPressed: function(event) {
        tile.ignoreRelease = false
        tile.leftPress = event.button === Qt.LeftButton
        tile.moved = false
        tile.pressAt = Qt.point(event.x, event.y)
        tile.event("press " + buttonName(event.button))
      }
      onPositionChanged: function(event) {
        if (!area.pressed) return
        if (tile.dragging) {
          var at = area.mapToItem(null, event.x, event.y)
          tile.dragMoved(at.x, at.y)
          return
        }
        if (!tile.moved && Math.hypot(event.x - tile.pressAt.x, event.y - tile.pressAt.y) > 8) {
          tile.moved = true
          tile.event("drag start")
          if (tile.dragEnabled && tile.leftPress) {
            tile.dragging = true
            var start = area.mapToItem(null, event.x, event.y)
            tile.dragStarted(start.x, start.y)
          }
        }
      }
      // A right click while dragging cancels the drag.
      onPressedButtonsChanged: {
        if (tile.dragging && (area.pressedButtons & Qt.RightButton)) {
          tile.dragging = false
          tile.ignoreRelease = true
          tile.event("drag canceled by right click")
          tile.dragCanceled()
        }
      }
      onReleased: function(event) {
        if (tile.ignoreRelease) { tile.moved = false; tile.event("release ignored after cancel"); return }
        if (tile.dragging) {
          var end = area.mapToItem(null, event.x, event.y)
          tile.dragging = false
          tile.moved = false
          tile.event("release after drag")
          tile.dragFinished(end.x, end.y)
          return
        }
        var inside = event.x >= 0 && event.y >= 0 && event.x <= tile.width && event.y <= tile.height + tile.bottomReach
        var moved = tile.moved
        tile.moved = false
        tile.event("release " + buttonName(event.button) + (inside ? "" : " outside") + (moved ? " after drag" : ""))
        if (moved || !inside) return
        tile.event("click " + buttonName(event.button))
        if (event.button === Qt.RightButton) tile.contextRequested()
        else tile.activated(event.button, event.modifiers)
      }
      onCanceled: {
        tile.moved = false
        tile.event("press canceled")
        if (tile.dragging) { tile.dragging = false; tile.dragCanceled() }
      }
      onWheel: function(wheel) {
        tile.wheelAccumulated += wheel.angleDelta.y
        if (Math.abs(tile.wheelAccumulated) < 120) return
        var direction = tile.wheelAccumulated > 0 ? -1 : 1
        tile.wheelAccumulated = 0
        // A trackpad flick sends many events: one step per 200 ms.
        if (Date.now() - tile.lastStep < 200) return
        tile.lastStep = Date.now()
        tile.event("scroll " + direction)
        tile.scrolled(direction)
      }
    }
  }

  // Not scaled: the running dots.
  Item {
    id: overlay
    anchors.fill: parent
  }
}
