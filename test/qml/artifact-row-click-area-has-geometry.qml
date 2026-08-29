// Regression probe for Panel.qml's artifact-row structure -- mirrors the
// Item{implicitHeight}/inner Column/sibling MouseArea pattern used inside
// the artifact Repeater (the "S1: artifact list" screen, under
// "── restore ──" in Panel.qml).
//
// A review round found the ORIGINAL structure invalid: the MouseArea's
// `anchors.fill: parent` had a Column itself as its parent -- a Column
// being positioned by the outer Repeater's own parent Column. Qt Quick
// explicitly refuses fill/top/bottom/verticalCenter/centerIn anchors on a
// Positioner's own direct children ("Column will not function"), and the
// result was every valid artifact rendering normally but with a
// zero-geometry click target -- visible, permanently unselectable. This
// probe asserts the FIXED shape (Item wrapper, inner Column positioned
// normally, MouseArea anchored to the Item) actually produces a clickable
// area sized to match its content.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/artifact-row-click-area-has-geometry.qml
import QtQuick
import Quickshell
import Quickshell.Widgets

FloatingWindow {
  visible: true
  implicitWidth: 300
  implicitHeight: 200

  Column {
    id: outerCol
    width: 300

    // The FIXED pattern: Item wrapper + inner Column + sibling MouseArea.
    Item {
      id: row
      width: parent.width
      implicitHeight: innerCol.implicitHeight
      Column {
        id: innerCol
        width: parent.width
        Text { text: "line one"; height: 20 }
        Text { text: "line two"; height: 20 }
      }
      MouseArea {
        id: ma
        anchors.fill: parent
        onClicked: clicked = true
      }
    }
  }

  property bool clicked: false

  Timer {
    interval: 150
    running: true
    repeat: false
    onTriggered: {
      console.log("[geometry] row.width=" + row.width + " row.height=" + row.height
        + " ma.width=" + ma.width + " ma.height=" + ma.height)
      var ok = ma.width > 0 && ma.height > 0
      Qt.exit(ok ? 0 : 1)
    }
  }
}
