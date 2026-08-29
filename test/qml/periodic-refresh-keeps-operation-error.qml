// Regression probe for Panel.qml's periodic Timer -- mirrors the bottom
// Timer under "── the CLI ──" (interval refreshIntervalSec, onTriggered:
// root.refresh(true)).
//
// A review round found that keepError's own fix (an operation's error
// surviving ITS OWN trailing refresh) still lost to the periodic tick: it
// called refresh() with no argument, defaulting keepError to falsy, which
// cleared root.lastError on the next tick regardless. Unlike verify/status,
// which rederive their own error every tick, an operation error (sync,
// collect, enable/disable) is never rediscovered by a plain check -- verify
// only reads coverage, not whether the last push actually landed. This
// probe sets an error the way a failed sync would, then fires a periodic-
// style tick, and exits 0 only if the message survives it.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/periodic-refresh-keeps-operation-error.qml
import QtQuick
import Quickshell

ShellRoot {
  property string lastError: ""
  property bool checking: false
  property bool busy: false

  function refresh(keepError) {
    if (checking || busy) return
    checking = true
    if (!keepError) lastError = ""
    checking = false
  }

  Component.onCompleted: {
    lastError = "sync: something broke"
    // The periodic Timer's own call, verbatim.
    refresh(true)
  }

  Timer {
    interval: 200
    running: true
    repeat: false
    onTriggered: {
      console.log("[result] lastError = [" + lastError + "]")
      Qt.exit(lastError === "sync: something broke" ? 0 : 1)
    }
  }
}
