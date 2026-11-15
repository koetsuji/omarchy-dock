import QtQuick
import QtTest

Item {
  id: root
  width: 400; height: 200
  // the structure I had: the handler on a sibling below, the tile above with hoverEnabled
  Item { id: oldS; x: 0; y: 0; width: 200; height: 200
    Item { anchors.fill: parent; HoverHandler { id: oldHandler } }
    Item { x: 50; y: 50; width: 100; height: 100
      MouseArea { anchors.fill: parent; hoverEnabled: true }
    }
  }
  // the structure now: tiles without hover, the handler in an item on top
  Item { id: newS; x: 200; y: 0; width: 200; height: 200
    Item { x: 50; y: 50; width: 100; height: 100
      MouseArea { id: tileArea; anchors.fill: parent; onPressed: root.pressed = true }
    }
    Item { anchors.fill: parent; z: 1000; HoverHandler { id: newHandler } }
  }
  property bool pressed: false
  TestCase {
    name: "hover2"; when: windowShown
    function test_it() {
      mouseMove(root, 100, 100); wait(50)
      console.log("OLD structure (sibling handler under a hoverEnabled tile): hovered=" + oldHandler.hovered)
      mouseMove(root, 250, 20); wait(50)
      console.log("NEW structure, pointer on empty card area: hovered=" + newHandler.hovered)
      mouseMove(root, 300, 100); wait(50)
      console.log("NEW structure, pointer over a tile: hovered=" + newHandler.hovered)
      mousePress(root, 300, 100); wait(20); mouseRelease(root, 300, 100)
      console.log("NEW structure, a press on the tile still reaches its MouseArea: " + root.pressed)
    }
  }
}
