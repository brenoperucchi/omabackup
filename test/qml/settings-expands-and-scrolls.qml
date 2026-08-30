// Regression probe for the real Settings interaction: the overview is taller
// than KeyboardPanel's cap, so expanding the last section must also reveal its
// rows instead of growing below the viewport where the user cannot see them.
import QtQuick
import Quickshell
import Quickshell.Widgets

FloatingWindow {
  visible: true
  implicitWidth: 300
  implicitHeight: 120

  property bool configExpanded: false

  Flickable {
    id: flick
    width: 300
    height: 80
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true

    Column {
      id: column
      width: flick.width
      spacing: 10
      Rectangle { width: 300; height: 100 }
      Item {
        width: 300
        height: 20
        Rectangle { width: 300; height: 20 }
        MouseArea {
          anchors.fill: parent
          onClicked: toggleSettings()
        }
      }
      Grid {
        id: settingsRows
        width: 300
        visible: configExpanded
        columns: 2
        columnSpacing: 10
        rowSpacing: 2
        Repeater {
          model: 6
          delegate: Rectangle {
            required property int index
            width: 145
            height: 20
            color: "transparent"
          }
        }
      }
    }
  }

  function toggleSettings() {
    configExpanded = !configExpanded
    if (configExpanded) reveal.start()
  }

  Timer {
    id: reveal
    interval: 50
    repeat: false
    onTriggered: {
      flick.contentY = Math.max(0, flick.contentHeight - flick.height)
    }
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: {
      toggleSettings()
      check.start()
    }
  }

  Timer {
    id: check
    interval: 100
    repeat: false
    onTriggered: {
      var top = settingsRows.y - flick.contentY
      var bottom = top + settingsRows.implicitHeight
      Qt.exit(configExpanded && flick.contentY > 0
              && top >= 0 && bottom <= flick.height ? 0 : 1)
    }
  }
}
