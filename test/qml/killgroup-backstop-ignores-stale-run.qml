// Regression probe for a real bug in killGroup()'s backstop timer (Panel.qml),
// found by review (round omabackup-27, `omabackup-rev`): verifyProc/
// statusProc/syncProc/collectProc/switchProc are singleton Process objects,
// reused across runs -- refresh()/syncNow()/etc. all set `running = true`
// again on the SAME object for a new run. The backstop timer armed for one
// run's kill only checked `proc.running`, not which run it was watching: if
// the helper killed the OLD run quickly and a NEW run started on the same
// object before the backstop's own window elapsed, the stale backstop would
// see the new run as "still running" and kill IT directly -- a single-PID
// kill capable of reopening the exact descendant-orphaning problem the whole
// mechanism exists to close, on a run it was never armed for.
//
// This probe reproduces the sequence directly, driven by `runningChanged`
// rather than fixed delays (so it does not depend on exactly how fast a
// real kill(2) happens to land): killGroup() is called for a first run
// (capturing its pid, arming an 800ms backstop for it), a real, working
// helper kills that run almost immediately, and the INSTANT that death is
// observed, a second run is started on the SAME Process object -- well
// within the stale backstop's own 800ms window. The probe then waits past
// that window. Exits 0 only if the second run is still alive when checked
// -- i.e. the stale backstop did nothing, because it correctly recognized
// the process it is now looking at is not the one it was armed for.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/killgroup-backstop-ignores-stale-run.qml
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  readonly property int killGroupBackstopMs: 800
  property int killGroupCallCount: 0
  property int deathCount: 0

  // Mirrors Panel.qml's own root.killGroup(proc) exactly, including the
  // round-omabackup-27 fix (compares against the captured pid, not just
  // proc.running).
  function killGroup(proc) {
    root.killGroupCallCount++
    var pid = proc.processId
    if (pid === null || pid === undefined) return
    var killer = Qt.createQmlObject(
      'import Quickshell.Io; Process { }', root, "killerHelper")
    killer.command = ["kill", String(pid)]
    killer.exited.connect(function() { killer.destroy() })
    killer.running = true

    var backstop = Qt.createQmlObject(
      'import QtQuick; Timer { interval: ' + root.killGroupBackstopMs + '; repeat: false; running: true }',
      root, "killGroupBackstop")
    backstop.triggered.connect(function() {
      if (proc.running && proc.processId === pid) proc.running = false
      backstop.destroy()
    })
  }

  Process {
    id: target
    running: true
    command: ["sleep", "300"]
    onRunningChanged: {
      if (!running) {
        root.deathCount++
        // Only the FIRST death starts a second run -- the instant it is
        // observed, well before the stale backstop's own 800ms window
        // could elapse. A second death (the real, correct kill this
        // probe is proving does NOT happen) must not loop forever.
        if (root.deathCount === 1) target.running = true
      }
    }
  }

  // t=50ms: kill the first run -- a real, working kill, not a broken
  // helper. Its backstop is armed here for THIS run's pid.
  Timer {
    interval: 50
    running: true
    repeat: false
    onTriggered: root.killGroup(target)
  }

  // t=2000ms: comfortably past the stale backstop's own ~800ms-after-death
  // firing, however long the real kill(2) actually took to land. The
  // second run must still be alive, and killGroup() must have been called
  // only once (for the first run) -- no legitimate reason for it to fire
  // again here.
  Timer {
    interval: 2000
    running: true
    repeat: false
    onTriggered: {
      var ok = target.running === true && root.deathCount === 1 && root.killGroupCallCount === 1
      console.log("[result] secondRunAlive=" + target.running +
        " deathCount=" + root.deathCount + " killGroupCallCount=" + root.killGroupCallCount)
      if (target.running) target.running = false
      Qt.exit(ok ? 0 : 1)
    }
  }
}
