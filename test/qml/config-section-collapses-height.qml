// Regression probe for Panel.qml's Config section collapse -- mirrors the
// `configExpanded` property, the clickable header Item with its MouseArea,
// and `cfgGrid`'s `visible: root.configExpanded` binding, all under
// "── config ──" in Panel.qml.
//
// A review round found that measuring this needs an actual window: a
// ShellRoot with no window never runs a render/layout pass, so a
// positioner's implicitHeight looks frozen even when the collapse logic
// itself is correct -- confirmed directly, it cost that round two attempts.
// A FloatingWindow makes the Column really relayout.
//
// A later round's own reviewers appeared to disagree about this same
// mechanism -- one measured the Column relaying out correctly (matching
// this probe), the other reported expanding Config changing nothing
// visible. Both were right, about different layers: the Column DOES
// relayout (what THIS probe asserts, and always did), but Panel.qml's real
// KeyboardPanel caps contentHeight at Style.space(560) via
// fittedContentHeight -- and the overview's own content already exceeds
// that cap before Config ever expands. Above the cap, expanding Config
// changes how much there is to SCROLL, not the rendered panel height. This
// probe intentionally does not model that cap (it is a Panel.qml/
// KeyboardPanel-host concern, not a Column-vs-Grid one); it exists to keep
// the one fact it asserts -- Column relayouts a dynamically-shown sibling --
// from ever being relitigated as if it were still in doubt.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/config-section-collapses-height.qml
import QtQuick
import Quickshell
import Quickshell.Widgets

FloatingWindow {
  visible: true
  implicitWidth: 300
  implicitHeight: 200

  property bool configExpanded: false

  Column {
    id: col
    width: 300
    spacing: 10

    Rectangle { id: header; width: 100; height: 20 }
    Rectangle { id: grid; visible: configExpanded; width: 100; height: 60 }
    Rectangle { id: footer; width: 100; height: 20 }
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: {
      console.log("[collapsed] height=" + col.implicitHeight + " footer.y=" + footer.y)
      configExpanded = true
      collapseCheck.start()
    }
  }

  Timer {
    id: collapseCheck
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      console.log("[result] expanded height=" + col.implicitHeight + " footer.y=" + footer.y)
      // Expanding must grow the column and push the footer down -- proving
      // the invisible Grid was excluded from layout while collapsed, and
      // included once visible.
      var grew = col.implicitHeight > 100 && footer.y > 40
      Qt.exit(grew ? 0 : 1)
    }
  }
}
