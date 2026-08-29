// Regression probe for Panel.qml's resolveProc -- mirrors the resolveProc
// Process block and its own dedicated Timer (both under "── the CLI ──" in
// Panel.qml). If either is edited, re-check this probe still reflects the
// real structure. Panel.qml also sets a separate `resolveTimedOut` flag
// alongside `cliMissing` on this path (so the widget stays visible with a
// "check failed" headline instead of disappearing the same way a genuinely
// absent CLI does) -- this probe only checks the cliMissing half, since
// resolveTimedOut's effect is on visible/headline bindings this standalone
// harness does not reproduce.
//
// resolveProc runs once at startup, before root.cli exists, and is
// deliberately NOT covered by the shared busyTimeoutTimer (every one of
// that timer's restarts refuses to run until root.cli is non-empty). A
// review round found that a hung resolveProc left `cli` empty and
// `cliMissing` false forever -- neither is ever set except in
// onStreamFinished or onExited, and a hung process reaches neither -- so
// the widget stayed visible, looking normal, permanently inert, with no
// error the operator could see. The fix is a short one-shot timer of its
// own that declares "not configured" if resolution has not finished by the
// time it fires. This probe reproduces that structure standalone and
// exits 0 only if cliMissing ends up true.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/resolve-proc-gets-its-own-timeout.qml
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  property string cli: ""
  property bool cliMissing: false

  Process {
    id: resolveProc
    running: true
    command: ["sleep", "5"]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text).trim()
        if (path === "") { cliMissing = true; return }
        cli = path
      }
    }
    onExited: function(code) { if (cli === "") cliMissing = true }
  }

  Timer {
    interval: 800
    running: true
    repeat: false
    onTriggered: {
      if (cli === "" && !cliMissing) {
        if (resolveProc.running) resolveProc.running = false
        cliMissing = true
      }
    }
  }

  Timer {
    interval: 3000
    running: true
    repeat: false
    onTriggered: {
      console.log("[result] cli=[" + cli + "] cliMissing=[" + cliMissing + "]")
      Qt.exit(cliMissing === true ? 0 : 1)
    }
  }
}
