// Regression probe for Panel.qml's externalRecoveryTimer.onTriggered
// dispatching a best-effort `omabackup log-event` call when the wrapper
// goes silent -- added after a real incident (panel showed "config: terminal
// did not report completion; status refreshed" with nothing in the log to
// explain it), a design consultation (herdr-ask, round omabackup-12), and a
// code review (round omabackup-30) that found the `timeout` bound was
// placed INSIDE Util.execArgv's login shell instead of around it.
//
// Util.execArgv (qs.Commons) is Quickshell.execDetached under a fixed
// 'exec "$@"' shell wrapper -- truly fire-and-forget, no exit code or output
// ever observable from the caller (confirmed against its own source,
// /usr/share/omarchy/shell/Commons/Util.qml). This probe therefore cannot
// assert on execArgv's own return value; instead the "CLI" it launches is a
// stub script, built at runtime by this probe itself (not qs.Commons, kept
// self-contained per this file's own hand-maintained-mirror convention),
// that RECORDS its own invocation argv to a file.
//
// workDir lives under $TMPDIR (Quickshell.env, matching this shell's own
// established pattern -- see shell.qml's own Quickshell.env("HOME") use),
// the same directory test/run.sh scopes and tears down for the whole suite
// -- found by review (round omabackup-30) that a bare "/tmp/..." path
// escapes that cleanup and leaks one directory per run.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/panel-logs-recovery-timeout.qml
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property string cli: ""
  property string externalAction: "config"
  property string externalToken: "1788124236-1"
  property bool externalBusy: true
  property bool configuring: true
  property string lastError: ""
  // Shortened from the real 900000ms default -- the mechanism being tested
  // does not depend on the exact interval, only that it fires and dispatches
  // correctly, matching this test suite's own precedent (killgroup-backstop
  // probes shorten killGroupBackstopMs the same way).
  readonly property int externalRecoveryMs: 1200

  property string tmpBase: Quickshell.env("TMPDIR") || "/tmp"
  property string workDir: tmpBase + "/omabackup-panel-probe-recovery-" + Date.now() + "-" + Math.floor(Math.random() * 100000)
  property string recordFile: workDir + "/record.log"
  property string cliPath: workDir + "/cli"
  readonly property string stubScript:
    "#!/bin/bash\n" +
    "printf '%s\\n' \"$@\" >> \"" + recordFile + "\"\n" +
    "printf -- '---\\n' >> \"" + recordFile + "\"\n"

  // Mirrors Panel.qml's own logEventDetached exactly: `timeout` OUTSIDE the
  // login shell, so a hung profile is bounded too, not just the exec after
  // it (round omabackup-30's own P3 finding against the first draft, which
  // had `timeout` as part of execArgv's own argv -- INSIDE the shell).
  function logEventDetached(argv) {
    Quickshell.execDetached(["timeout", "--kill-after=2s", "10s",
                              "bash", "-lc", 'exec "$@"', "bash"].concat(argv))
  }

  function refresh(force) {}

  // Mirrors Panel.qml's externalRecoveryTimer.onTriggered exactly (see its
  // own comment there for why this dispatch exists and why it is ordered
  // after, not before, the state recovery above it).
  Timer {
    id: externalRecoveryTimer
    interval: root.externalRecoveryMs
    repeat: false
    running: false
    onTriggered: {
      if (root.externalAction === "") return
      var action = root.externalAction
      var token = root.externalToken
      root.externalAction = ""
      root.externalToken = ""
      root.externalBusy = false
      root.configuring = false
      root.lastError = action + ": terminal did not report completion; status refreshed"
      root.refresh(true)
      if (root.cli !== "")
        try {
          root.logEventDetached([root.cli, "log-event",
                          action + " (interactive)", "failed (no heartbeat)",
                          "gave up after " + Math.round(root.externalRecoveryMs / 1000) +
                          "s with no heartbeat or completion callback (token " + token + ")"])
        } catch (e) {}
    }
  }

  Process {
    id: setupProc
    running: true
    command: ["bash", "-c", 'mkdir -p "$1"', "bash", root.workDir]
    onExited: function(code) {
      if (code !== 0) { console.log("[result] setup mkdir failed"); Qt.exit(1); return }
      writeStub.running = true
    }
  }

  Process {
    id: writeStub
    command: ["bash", "-c", 'printf %s "$1" > "$2" && chmod +x "$2"', "bash", root.stubScript, root.cliPath]
    onExited: function(code) {
      if (code !== 0) { console.log("[result] setup stub write failed"); Qt.exit(1); return }
      root.cli = root.cliPath
      externalRecoveryTimer.running = true
    }
  }

  // Polls for the stub's own record file rather than asserting immediately
  // -- execDetached gives no completion signal to wait on instead. Waits an
  // extra fixed grace window past the point externalBusy clears before
  // reading, so a second, unwanted dispatch (there should be none) has time
  // to land in the same file before "exactly one call" is asserted.
  Timer {
    interval: 100
    repeat: true
    running: true
    property int tries: 0
    property int graceTicks: -1
    onTriggered: {
      tries++
      if (tries > 100) {  // 10s ceiling
        console.log("[result] timed out waiting for the record file")
        Qt.exit(1)
        return
      }
      if (root.externalBusy) return
      if (graceTicks < 0) graceTicks = 0
      graceTicks++
      if (graceTicks < 15) return  // ~1.5s grace past recovery for the dispatch to land
      if (checkProc.running) return
      checkProc.running = true
    }
  }

  Process {
    id: checkProc
    command: ["bash", "-c", 'test -s "$1" && cat "$1"', "bash", root.recordFile]
    stdout: StdioCollector {
      id: checkCollector
      onStreamFinished: {
        var out = checkCollector.text
        if (out === "") { console.log("[result] record file empty"); Qt.exit(1); return }
        // `timeout` itself consumes "timeout"/"--kill-after=2s"/"10s"/
        // "bash"/"-lc"/'exec "$@"'/"bash"/cliPath from the argv before
        // exec-ing the stub with the remainder -- the stub's own "$@" is
        // only what actually reached it (log-event and its 3 arguments),
        // confirmed by running this probe and reading back what landed.
        var lines = out.split("\n")
        var ok =
          lines.length === 6 &&  // exactly one call recorded, not more
          lines[0] === "log-event" &&
          lines[1] === "config (interactive)" &&
          lines[2] === "failed (no heartbeat)" &&
          lines[3].indexOf("gave up after") === 0 &&
          lines[3].indexOf("token 1788124236-1") !== -1 &&
          lines[4] === "---"
        console.log("[result] recordedArgv=" + JSON.stringify(lines) + " ok=" + ok)
        Qt.exit(ok ? 0 : 1)
      }
    }
  }
}
