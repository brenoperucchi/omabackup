// Regression probe for Panel.qml's Groups tooltip -- mirrors the
// HoverHandler + custom-styled ToolTip (rounded background, custom
// contentItem) added as direct children of groupRow, a Row (a Positioner),
// under "── what is saved ──" in Panel.qml.
//
// A review round already found ONE anchors.fill-inside-a-Positioner bug in
// this file (the artifact list's MouseArea); before adding a second
// pointer-related child to a Row, this probe confirms a real ToolTip
// instance (not just the attached-property form used at first) is also
// safe there -- Popup-derived types are not laid out by Row the way
// ordinary Items are, so this does not hit the same restriction. Confirmed
// headless: no "Row will not function" warning, and the Row's own geometry
// stays correct with the tooltip machinery present.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/group-row-tooltip-is-safe-in-row.qml
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets

FloatingWindow {
  visible: true
  implicitWidth: 300
  implicitHeight: 100

  Row {
    id: r
    width: 200
    spacing: 7
    HoverHandler { id: hh }
    readonly property string tooltipText: "~/.config/hypr  ·  ~/.config/foo"
    ToolTip {
      visible: hh.hovered && r.tooltipText !== ""
      text: r.tooltipText
      delay: 400
      padding: 8
      background: Rectangle { color: "black"; radius: height / 2; border.color: "gray"; border.width: 1 }
      contentItem: Text { text: r.tooltipText; color: "white" }
    }
    Rectangle { width: 3; height: 30; color: "gray" }
    Column {
      width: 150
      Text { text: "Hyprland"; height: 15 }
      Text { text: "29 files"; height: 15 }
    }
  }

  Timer {
    interval: 150
    running: true
    repeat: false
    onTriggered: {
      console.log("[geometry] r.width=" + r.width + " r.height=" + r.height)
      Qt.exit(r.height > 0 ? 0 : 1)
    }
  }
}
