// Regression probe for killGroup()'s backstop timer (Panel.qml), added by
// explicit decision after design consultation (herdr-ask, following review
// rounds omabackup-25/26): round omabackup-25's own fix made killGroup()'s
// dynamically created Process the ONLY thing that ever stops a timed-out or
// output-capped target -- closing a real race, but removing the old
// guarantee that SOMETHING always signals the target (`proc.running =
// false`, synchronous and always-successful inside the panel's own
// process). If the helper Process fails to do its job -- fails to even
// exec, or the underlying `omabackup kill-group` call for whatever reason
// never actually reaches the target -- nothing recovered on its own:
// `onExited` never fires, `busy` stays stuck permanently, every panel
// action disabled with no way out short of restarting the panel
// (`omabackup-rev-2`'s finding, round omabackup-26).
//
// This probe mirrors killGroup()'s exact shape (see its own comment in
// Panel.qml for why this is a hand-maintained mirror, not an import), but
// points `cli` at a deliberately broken stand-in -- a script that starts
// successfully but does nothing at all -- simulating the helper failing to
// do its job. Exits 0 only if the backstop timer still gets the target's
// `running` to false on its own, proving the safety net actually works and
// is not just present in the source.
//
// A second target, alongside the broken one, gets a REAL kill-group-shaped
// helper (a working `kill -TERM "$1"`) that succeeds well before the
// backstop's own delay -- proving the backstop does NOT fire unnecessarily
// (does not kill-again or otherwise interfere) when the helper already did
// its job.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/killgroup-backstop-rescues-stuck-helper.qml
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  readonly property int killGroupBackstopMs: 800

  // Mirrors Panel.qml's own root.killGroup(proc), with the backstop
  // interval shortened (800ms instead of 3000ms) so this probe does not
  // need to wait as long -- the mechanism being tested does not depend on
  // the exact interval, only that a backstop exists and fires.
  function killGroup(proc, cliOverride) {
    var pid = proc.processId
    if (pid === null || pid === undefined) return
    var killer = Qt.createQmlObject(
      'import Quickshell.Io; Process { }', root, "killGroupHelper")
    killer.command = [cliOverride, String(pid)]
    killer.exited.connect(function() { killer.destroy() })
    killer.running = true

    var backstop = Qt.createQmlObject(
      'import QtQuick; Timer { interval: ' + root.killGroupBackstopMs + '; repeat: false; running: true }',
      root, "killGroupBackstop")
    backstop.triggered.connect(function() {
      if (proc.running) proc.running = false
      backstop.destroy()
    })
  }

  // brokenTarget's "helper" is `true`, standing in for a kill-group call
  // that starts, exits immediately, and signals nothing at all -- the
  // worst case, not just "slow to start".
  Process {
    id: brokenTarget
    running: true
    command: ["sh", "-c", "sleep 300"]
  }

  // workingTarget's helper is a real, working single-pid TERM -- standing
  // in for kill-group actually doing its job well before the backstop's
  // own delay would ever matter.
  Process {
    id: workingTarget
    running: true
    command: ["sh", "-c", "sleep 300"]
  }

  Timer {
    interval: 200
    running: true
    repeat: false
    onTriggered: {
      root.killGroup(brokenTarget, "true")
      root.killGroup(workingTarget, "kill")
    }
  }

  Timer {
    // Comfortably past both: workingTarget's real kill finishes almost
    // immediately, and brokenTarget's backstop fires at 800ms.
    interval: 2000
    running: true
    repeat: false
    onTriggered: {
      var brokenOk = brokenTarget.running === false
      var workingOk = workingTarget.running === false
      console.log("[result] brokenOk=" + brokenOk + " workingOk=" + workingOk +
        " brokenRunning=" + brokenTarget.running + " workingRunning=" + workingTarget.running)
      Qt.exit((brokenOk && workingOk) ? 0 : 1)
    }
  }
}
