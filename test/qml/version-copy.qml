// Regression probe for the version affordance in Panel.qml. Quickshell owns
// the Wayland clipboard, so this checks the same assignment used by the real
// button instead of replacing it with a fake `wl-copy` process.
import QtQuick
import Quickshell

ShellRoot {
  property string toolVersion: "0.2.0"
  property bool copied: false

  function copyToolVersion() {
    Quickshell.clipboardText = toolVersion
    copied = Quickshell.clipboardText === toolVersion
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: {
      copyToolVersion()
      Qt.exit(copied ? 0 : 1)
    }
  }
}
