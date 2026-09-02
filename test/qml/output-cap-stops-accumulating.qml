// Regression probe for Panel.qml's output cap (marketplace security
// review, issue #3968: StdioCollector buffers complete CLI output with no
// size limit at all -- confirmed against quickshell-mirror/quickshell's
// datastream.cpp, which just appends every chunk to one QByteArray
// forever). Mirrors the exact shape Panel.qml uses after the fix:
// `SplitParser { splitMarker: "" }` (confirmed, also from datastream.cpp,
// to never buffer internally with an empty marker -- every chunk is
// emitted immediately via `read()`) feeding accumulateCapped, which owns
// the actual cap and stops appending once it is crossed.
//
// accumulateCapped/killGroup below are a synced MIRROR of Panel.qml's own
// (root.accumulateCapped, root.killGroup), not an import of them -- QML
// has no clean way to pull a single function out of another component's
// file. Found by review (round omabackup-26, `omabackup-rev`): an EARLIER
// version of this mirror had drifted out of sync with a prior shape of
// the real function (still called `proc.running = false` directly, still
// took a 2-argument signature) -- silently passing while testing
// behavior Panel.qml no longer has. If Panel.qml's own accumulateCapped/
// killGroup ever change again, this file must be updated to match, by
// hand, or it will go stale the same way again; there is no automated
// check that catches this drift, only re-reading Panel.qml when either
// changes. Kept as a mirror rather than moved to a shared .js module
// Panel.qml would import, since that refactor was judged out of scope
// for this round of fixes.
//
// Two processes, two outcomes in one run: `under` writes well below the cap
// and must come through byte-for-byte; `over` writes well past it and must
// latch outputCapped, stop growing its buffer, and have running flip to
// false once the (stand-in) killer actually runs -- accumulateCapped
// itself does NOT set running=false directly anymore, matching Panel.qml's
// own round-omabackup-25 fix for the race that caused.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/output-cap-stops-accumulating.qml
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  readonly property int maxOutputBytes: 1000
  property bool killGroupCalled: false

  // Mirrors Panel.qml's own root.killGroup(), simplified: a real `sh -c
  // 'kill -TERM -"$1"'` stand-in, not the actual bin/omabackup kill-group
  // subcommand (that end-to-end path, including its own safety guards, is
  // covered by test/qml/timeout-kills-descendant.qml and the shell-level
  // kill-group tests in test/panel.test.sh) -- this probe only needs the
  // killer to actually run and actually kill the target, so `running`
  // transitions to false the same way it would for real: because the OS
  // process died, not because this code said so directly.
  function killGroup(pid) {
    root.killGroupCalled = true
    if (pid === null || pid === undefined) return
    var killer = Qt.createQmlObject(
      'import Quickshell.Io; Process { }', root, "killerHelper")
    killer.command = ["sh", "-c", 'kill -TERM "$1" 2>/dev/null', "--", String(pid)]
    killer.exited.connect(function() { killer.destroy() })
    killer.running = true
  }

  // Mirrors Panel.qml's own root.accumulateCapped(proc, field, chunk)
  // exactly, including NOT setting proc.running = false itself (round
  // omabackup-25's own fix for the race that caused -- see Panel.qml's
  // own comment on this function for the full reasoning).
  function accumulateCapped(proc, field, chunk) {
    if (proc.outputCapped) return
    if (proc[field].length + chunk.length > root.maxOutputBytes) {
      proc.outputCapped = true
      root.killGroup(proc.processId)
      return
    }
    proc[field] = proc[field] + chunk
  }

  Process {
    id: underProc
    property string buffer: ""
    property bool outputCapped: false
    running: true
    // Well under the 1000-byte cap: prints a short, fixed line.
    command: ["sh", "-c", "printf 'a small json line, under the cap\\n'"]
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(underProc, "buffer", data) } }
  }

  Process {
    id: overProc
    property string buffer: ""
    property bool outputCapped: false
    running: true
    // 4000 bytes of 'x', four times the cap -- and no newline anywhere in
    // it, the exact single-unbroken-line shape a delimiter-based parser
    // would not have helped with.
    command: ["sh", "-c", "printf 'x%.0s' $(seq 1 4000)"]
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(overProc, "buffer", data) } }
  }

  Timer {
    interval: 2000
    running: true
    repeat: false
    onTriggered: {
      var underOk = underProc.buffer.trim() === "a small json line, under the cap"
        && !underProc.outputCapped
      var overOk = overProc.outputCapped === true
        && overProc.buffer.length <= root.maxOutputBytes
        && overProc.running === false
        && root.killGroupCalled === true
      console.log("[result] underOk=" + underOk + " overOk=" + overOk +
        " underBuf=[" + underProc.buffer.trim() + "] overCapped=" + overProc.outputCapped +
        " overLen=" + overProc.buffer.length + " overRunning=" + overProc.running +
        " killCalled=" + root.killGroupCalled)
      Qt.exit((underOk && overOk) ? 0 : 1)
    }
  }
}
