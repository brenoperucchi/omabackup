// Regression probe for Panel.qml's busyTimeoutTimer / verifyProc pairing --
// mirrors the busyTimeoutTimer Timer and the verifyProc Process block (both
// under "── the CLI ──" in Panel.qml). If either is edited, re-check this
// probe still reflects the real onExited/onTriggered shape.
//
// A review round found that the timer's own timeout message ("verify timed
// out after Ns") was overwritten by the process's own onExited handler
// ("verify: no output, exit 15") once that eventually ran -- `running =
// false` delivers `exited` ASYNCHRONOUSLY (measured in a later round, not
// assumed), so this is not a same-tick race, just an eventual one. The fix
// is a per-process `timedOut` flag, set before `running = false` and
// checked first thing in onExited -- the flag is what protects the message,
// not the order those two lines are written in. This probe reproduces the
// exact structure (a Process, a Timer that kills it, the same onExited
// shape) standalone, headless, and exits 0 only if the timeout message
// survives.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/timeout-message-not-overwritten.qml
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  property string lastError: ""
  property bool checking: false

  Process {
    id: verifyProc
    property string buffer: ""
    property string errBuffer: ""
    property bool timedOut: false
    running: true
    command: ["sleep", "5"]
    stdout: StdioCollector { onStreamFinished: verifyProc.buffer = text }
    stderr: StdioCollector { onStreamFinished: verifyProc.errBuffer = text }
    onExited: function(code) {
      checking = false
      if (verifyProc.timedOut) { verifyProc.timedOut = false; return }
      if (verifyProc.buffer.trim() === "") {
        lastError = "verify: " + (verifyProc.errBuffer.trim() || ("no output, exit " + code))
      } else {
        lastError = "applied report"
      }
    }
  }

  Timer {
    interval: 800
    running: true
    repeat: false
    onTriggered: {
      if (verifyProc.running) {
        verifyProc.timedOut = true
        verifyProc.running = false
        checking = false
        lastError = "verify timed out after 1s"
      }
    }
  }

  Timer {
    interval: 3000
    running: true
    repeat: false
    onTriggered: {
      console.log("[result] lastError = [" + lastError + "]")
      Qt.exit(lastError === "verify timed out after 1s" ? 0 : 1)
    }
  }
}
