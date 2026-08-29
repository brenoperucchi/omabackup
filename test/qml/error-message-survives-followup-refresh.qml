// Regression probe for Panel.qml's refresh(keepError) / syncProc pairing --
// mirrors the `function refresh(keepError)` definition and syncProc's
// onExited (both under "── the CLI ──" in Panel.qml). If either is edited,
// re-check this probe still reflects the real logic. Note: this does NOT
// cover the periodic Timer at the bottom of the file, which a later round
// found calling refresh() with no argument -- its own separate fix
// (`onTriggered: root.refresh(true)`) has no probe of its own yet.
//
// A review round found that syncProc's onExited set root.lastError on
// failure and then unconditionally called root.refresh() -- and refresh()
// unconditionally cleared root.lastError as its second line, before the
// panel ever rendered the message. A sync that failed and one that
// succeeded went back to looking identical after the trailing refresh,
// defeating the entire point of capturing stderr/exit code. This probe
// reproduces the exact sequence (set lastError, call refresh(keepError))
// standalone and exits 0 only if the message survives.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/error-message-survives-followup-refresh.qml
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

  function syncFailed() {
    lastError = "sync: something broke"
    refresh(true)  // the fix: preserve what was just set
  }

  Component.onCompleted: syncFailed()

  // Qt.exit() called synchronously inside Component.onCompleted fires before
  // the engine has a receiver wired up for it ("emitted, but no receivers
  // connected") and the process just hangs -- confirmed directly. A Timer,
  // even a short one, defers it to a point where it actually terminates the
  // process, same as this project's other two QML probes already do.
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
