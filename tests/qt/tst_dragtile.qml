import QtQuick
import QtTest

// The drag gesture of DockTile, with real (synthetic) mouse events: a press, a move past 8 px, moves,
// a release; a right click during the drag; a short wobble that is only a click; dragEnabled off.
Item {
  id: root
  width: 300; height: 200
  property var log: []
  DockTile {
    id: tile
    x: 100; y: 100; size: 56
    dragEnabled: true
    onDragStarted: function(x, y) { root.log.push("start") }
    onDragMoved: function(x, y) { root.log.push("move") }
    onDragFinished: function(x, y) { root.log.push("finish") }
    onDragCanceled: root.log.push("cancel")
    onActivated: function(button, modifiers) { root.log.push("click") }
    onContextRequested: root.log.push("context")
  }
  TestCase {
    name: "dragtile"; when: windowShown
    function reset() { root.log = []; tile.dragEnabled = true }
    function summary() { var seen = []; for (var i = 0; i < root.log.length; i++) if (seen[seen.length - 1] !== root.log[i]) seen.push(root.log[i]); return seen.join(",") }
    function test_drag() {
      reset()
      mousePress(root, 120, 130, Qt.LeftButton); mouseMove(root, 124, 130, 0, Qt.LeftButton)
      console.log("RESULT 4 px: " + summary())
      mouseMove(root, 140, 130, 0, Qt.LeftButton); mouseMove(root, 170, 120, 0, Qt.LeftButton)
      mouseRelease(root, 170, 120, Qt.LeftButton)
      console.log("RESULT drag: " + summary())
    }
    function test_wobble_is_a_click() {
      reset()
      mousePress(root, 120, 130, Qt.LeftButton); mouseMove(root, 124, 132, 0, Qt.LeftButton); mouseRelease(root, 124, 132, Qt.LeftButton)
      console.log("RESULT wobble: " + summary())
    }
    function test_right_click_cancels() {
      reset()
      mousePress(root, 120, 130, Qt.LeftButton); mouseMove(root, 150, 130, 0, Qt.LeftButton); mouseMove(root, 170, 130, 0, Qt.LeftButton)
      mousePress(root, 170, 130, Qt.RightButton); mouseRelease(root, 170, 130, Qt.RightButton); mouseRelease(root, 170, 130, Qt.LeftButton)
      console.log("RESULT right click: " + summary())
    }
    function test_not_enabled() {
      reset(); tile.dragEnabled = false
      mousePress(root, 120, 130, Qt.LeftButton); mouseMove(root, 150, 130, 0, Qt.LeftButton); mouseMove(root, 180, 130, 0, Qt.LeftButton); mouseRelease(root, 180, 130, Qt.LeftButton)
      console.log("RESULT disabled: " + summary())
    }
  }
}
