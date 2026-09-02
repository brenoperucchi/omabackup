// Regression probe for the process-group containment fix in Panel.qml's
// busyTimeoutTimer / verifyProc-and-siblings pairing (marketplace security
// review, issue #3968): QuickShell's own Process has no group-kill --
// `running = false` and `signal()` both call a bare, single-PID kill(2)
// (confirmed against quickshell-mirror/quickshell's process.cpp) -- so a
// timed-out CLI verb that was itself blocked on a child (git, rsync) used
// to leave that child running, orphaned, after the panel gave up on it.
//
// This probe reproduces the exact shape Panel.qml uses: the command wrapped
// in `setsid --`, a Timer that times it out, and root.killGroup(pid) --
// called with the PID captured before running could possibly change -- to
// spawn the REAL `bin/omabackup kill-group <pid>` subcommand, not a
// simplified stand-in. Found by review (round omabackup-25): an earlier
// version of this probe used an inline `sh -c 'kill -TERM -"$1"'` in place
// of the real subcommand, which starts and signals near-instantly -- too
// fast to exercise the actual timing this fix depends on. The real
// subcommand has to start bash, source lib/*.sh, and run its own `ps`
// lookup before it ever signals anything, which is slow enough that a
// SEPARATE direct kill of the target (an earlier version of the QML fix
// itself) could win the race and reap the target first -- leaving the
// subcommand's own `ps -o pgid= -p <already-dead-pid>` lookup empty, and
// the descendant never reached at all. The current fix removes that
// competing direct kill entirely (see root.killGroup's own comment in
// Panel.qml): the subcommand is the ONLY thing that ever signals the
// target, so there is nothing left to race against, at any speed.
//
// The subcommand's own safety guards (refuse a pgid that is not really the
// target's own, refuse this process's own group, refuse pid <= 1) are
// covered directly and thoroughly at the shell level in test/panel.test.sh,
// not here -- this probe exists only to prove the QML wiring, end to end
// with the real subcommand, actually reaches a live descendant.
//
// The target process spawns a child (`sleep 300 &`) and writes both PIDs to
// files before blocking on `wait`, exactly like a CLI verb blocked on git/
// rsync. Exits 0 only if BOTH the target and its child are gone after the
// timeout fires and the real kill-group subcommand runs.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/timeout-kills-descendant.qml
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  // Unique per run, not a fixed name -- found by review (round
  // omabackup-26, `omabackup-rev`): a fixed /tmp path risks reading a
  // STALE pid file left behind by an interrupted earlier run (this
  // process, or a concurrent one) instead of this run's own, which could
  // make a broken probe pass by accident on leftover state rather than
  // what it actually just did.
  property string runId: Date.now() + "-" + Math.floor(Math.random() * 1000000)
  property string parentPidFile: "/tmp/omabackup-qml-probe-parent-" + runId + ".pid"
  property string childPidFile: "/tmp/omabackup-qml-probe-child-" + runId + ".pid"

  // "bin/omabackup", relative: qs -p is invoked from the repo root by
  // test/panel.test.sh's own _qml_probe helper, the same way every other
  // probe in this directory already assumes.
  function killGroup(pid) {
    if (pid === null || pid === undefined) return
    var killer = Qt.createQmlObject(
      'import Quickshell.Io; Process { }', root, "killerHelper")
    killer.command = ["bin/omabackup", "kill-group", String(pid)]
    killer.exited.connect(function() { killer.destroy() })
    killer.running = true
  }

  // Wraps the target exactly like Panel.qml's verifyProc/statusProc/
  // syncProc/collectProc/switchProc after the fix: setsid so the tracked
  // PID becomes its own process-group leader.
  Process {
    id: targetProc
    property bool timedOut: false
    running: true
    command: ["setsid", "--", "sh", "-c",
      "echo $$ >\"$1\"; { sleep 300 & echo $! >\"$2\"; }; wait",
      "--", root.parentPidFile, root.childPidFile]
  }

  Timer {
    interval: 500
    running: true
    repeat: false
    onTriggered: {
      // No `targetProc.running = false` here -- see the comment above.
      // killGroup()'s own eventual TERM reaches the target too.
      if (targetProc.running) {
        targetProc.timedOut = true
        root.killGroup(targetProc.processId)
      }
    }
  }

  // Longer than the stand-in version needed: the real subcommand sources
  // several lib/*.sh files and runs `ps` before it signals anything.
  Timer {
    interval: 4000
    running: true
    repeat: false
    onTriggered: {
      var checkProc = Qt.createQmlObject(
        'import Quickshell.Io; Process { }', root, "checker")
      var collector = Qt.createQmlObject(
        'import Quickshell.Io; StdioCollector { }', checkProc, "checkerStdout")
      checkProc.stdout = collector
      // Requires both pid files to actually hold a decimal pid before
      // treating either as meaningful -- found by review (round
      // omabackup-26, `omabackup-rev`): `kill -0 ""` on an empty/missing
      // pid file fails too, which used to read identically to "GONE"
      // (correctly dead) instead of "the setup never actually ran". A
      // probe that silently passed on a precondition failure -- the
      // target never starting, or the pid files never being written --
      // would prove nothing about the fix.
      checkProc.command = ["sh", "-c",
        'p="$(cat "$1" 2>/dev/null)"; c="$(cat "$2" 2>/dev/null)"; ' +
        'case "$p" in ""|*[!0-9]*) echo PARENT_PID_MISSING; exit 0 ;; esac; ' +
        'case "$c" in ""|*[!0-9]*) echo CHILD_PID_MISSING; exit 0 ;; esac; ' +
        'kill -0 "$p" 2>/dev/null && echo PARENT_ALIVE || echo PARENT_GONE; ' +
        'kill -0 "$c" 2>/dev/null && echo CHILD_ALIVE || echo CHILD_GONE',
        "--", root.parentPidFile, root.childPidFile]
      collector.streamFinished.connect(function() {
        var text = collector.text
        console.log("[result] " + text.trim().replace(/\n/g, " / "))
        var ok = text.indexOf("PARENT_GONE") !== -1 && text.indexOf("CHILD_GONE") !== -1
        Qt.exit(ok ? 0 : 1)
      })
      checkProc.running = true
    }
  }
}
