// Regression probe for Panel.qml's externalProc.onExited (code !== 0 branch)
// dispatching a best-effort `omabackup log-event` call -- see
// panel-logs-recovery-timeout.qml for the shared background (real incident,
// herdr-ask round omabackup-12) and why the target here is a recording stub
// rather than asserting on execArgv's own return.
//
// Five scenarios, sequenced:
// 1. A normal launch failure (non-zero exit, some stderr) -- the log-event
//    argv must carry the exit code, the stderr, and the token, with the
//    "failed (launch)" outcome.
// 2. A REAL race: session A's externalProc is still running (a deliberate
//    sleep before it exits non-zero) when root's own session identity
//    moves on to session B while A is still in flight -- proving the
//    launchAction/launchToken guard (found missing in review, round
//    omabackup-30, `omabackup-rev`) actually stops A's late, stale exit
//    from touching B's state or logging on A's behalf under B's fields.
// 3. The same failure shape, but with `externalAction` already empty when
//    the (fast) exit arrives -- proving the guard also covers the simpler
//    empty-action case, which by itself already reopened an already-fixed
//    bug elsewhere (round omabackup-23) before this guard existed.
// 4. A short stderr blob with an embedded NUL -- proving the NUL is
//    actually stripped (both halves survive, joined) rather than merely
//    assuming Qt/QProcess itself would have truncated the stream there.
//    Kept apart from scenario 5's truncation test on purpose: combining
//    both in one oversized blob would not distinguish "the code stripped
//    the NUL" from "something upstream already truncated at the NUL",
//    since both produce an identical final result once the content is
//    long enough for the 2000-char cut to also apply on its own.
// 5. A pure-ASCII stderr blob over 2000 characters, no NUL at all --
//    proving the truncation itself actually happens, isolated from
//    scenario 4's NUL-stripping.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/panel-logs-launch-failure.qml
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property string cli: ""
  property string externalAction: "restore"
  property string externalToken: "1788124999-2"
  property bool externalBusy: true
  property bool configuring: false
  property string lastError: ""

  property string tmpBase: Quickshell.env("TMPDIR") || "/tmp"
  property string workDir: tmpBase + "/omabackup-panel-probe-launch-" + Date.now() + "-" + Math.floor(Math.random() * 100000)
  property string recordFile: workDir + "/record.log"
  property string cliPath: workDir + "/cli"
  readonly property string stubScript:
    "#!/bin/bash\n" +
    "printf '%s\\n' \"$@\" >> \"" + recordFile + "\"\n" +
    "printf -- '---\\n' >> \"" + recordFile + "\"\n"

  // Mirrors Panel.qml's own logEventDetached exactly -- `timeout` OUTSIDE
  // the login shell (round omabackup-30's P3 finding against the first
  // draft, where `timeout` sat inside execArgv's own argv).
  function logEventDetached(argv) {
    Quickshell.execDetached(["timeout", "--kill-after=2s", "10s",
                              "bash", "-lc", 'exec "$@"', "bash"].concat(argv))
  }

  function refresh(force) {}

  // phase: 0=setup, 1=normal failure, 2=stale-substitution race,
  // 3=empty-action, 4=truncation+NUL, 5=done
  property int phase: 0

  // Mirrors Panel.qml's externalProc + its onExited(code !== 0) branch
  // exactly, including the launchAction/launchToken stale-callback guard
  // added in review (round omabackup-30) -- see its own comment there for
  // the full reasoning.
  Process {
    id: externalProc
    property string errBuffer: ""
    property string launchAction: ""
    property string launchToken: ""
    command: ["true"]
    stderr: StdioCollector { onStreamFinished: externalProc.errBuffer = text }
    onExited: function(code) {
      if (externalProc.launchAction === "" || externalProc.launchAction !== root.externalAction
          || externalProc.launchToken !== root.externalToken) return
      var action = externalProc.launchAction
      var token = externalProc.launchToken
      if (code !== 0) {
        root.externalAction = ""
        root.externalToken = ""
        root.externalBusy = false
        root.configuring = false
        root.lastError = action + ": " + (externalProc.errBuffer.trim() || ("exit " + code))
        root.refresh(true)
        if (root.cli !== "" && action !== "") {
          var errText = externalProc.errBuffer.trim().replace(/\x00/g, "")
          if (errText.length > 2000) errText = errText.slice(0, 2000) + " …(truncated)"
          try {
            root.logEventDetached([root.cli, "log-event",
                            action + " (interactive)", "failed (launch)",
                            "exit " + code + (errText ? "; stderr=" + errText : "") +
                            " (token " + token + ")"])
          } catch (e) {}
        }
      }
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
      startPhase1()
    }
  }

  function startPhase1() {
    root.phase = 1
    root.externalAction = "restore"
    root.externalToken = "1788124999-2"
    root.externalBusy = true
    externalProc.launchAction = root.externalAction
    externalProc.launchToken = root.externalToken
    externalProc.command = ["bash", "-c", "printf 'boom: could not open display' >&2; exit 7"]
    externalProc.running = true
  }

  function startPhase2() {
    root.phase = 2
    root.externalAction = "restore"
    root.externalToken = "1788125000-3"
    root.externalBusy = true
    externalProc.launchAction = root.externalAction
    externalProc.launchToken = root.externalToken
    // Deliberately slow: gives phase2SwitchTimer a real window to move
    // root's own session identity to "session B" WHILE this exit is still
    // in flight -- the exact race the launchAction/launchToken guard
    // exists to close.
    // 0.8s, not 0.4s -- widened after review (round omabackup-31,
    // `omabackup-rev`) flagged the original 300ms margin between
    // phase2SwitchTimer's 100ms firing and this exit as tight enough to
    // flake under a starved event loop. A flake here fails in the SAFE
    // direction (a spurious red, not a false green -- confirmed by
    // `omabackup-rev-2`), but more margin costs nothing but a little
    // wall-clock time.
    externalProc.command = ["bash", "-c", "sleep 0.8; printf 'late failure' >&2; exit 5"]
    externalProc.running = true
    phase2SwitchTimer.start()
  }

  // Fires well before phase2's own externalProc exits (0.8s), simulating
  // session B becoming active while session A's launch failure is still
  // pending -- e.g. B's own wrapper completed via IPC and freed the UI, or
  // (per canOpenExternalTui's own gating) some future caller that does not
  // go through openExternalTui's busy check.
  Timer {
    id: phase2SwitchTimer
    interval: 100
    repeat: false
    onTriggered: {
      root.externalAction = "config"
      root.externalToken = "1788125001-4"
      root.externalBusy = true
    }
  }

  function startPhase3() {
    root.phase = 3
    root.externalAction = "restore"
    root.externalToken = "1788125002-5"
    root.externalBusy = true
    externalProc.launchAction = root.externalAction
    externalProc.launchToken = root.externalToken
    externalProc.command = ["bash", "-c", "printf 'second failure' >&2; exit 9"]
    externalProc.running = true
    // Empty the action immediately, before this fast-exiting process's own
    // onExited can possibly deliver -- same guard, different trigger than
    // phase 2's token substitution.
    root.externalAction = ""
  }

  // Fired only after externalProc.running has gone back to false (the
  // real OS-level completion signal for phase 3's own suppressed attempt,
  // not a guessed delay) -- proves absence relative to a KNOWN, later,
  // observed write instead of a fixed time window. Found by review (round
  // omabackup-31, `omabackup-rev-2`): the log-event write path goes
  // through execDetached -> timeout -> a LOGIN shell that sources the
  // user's profile -> the CLI -> _log_write, which is exactly the latency
  // this same round's own P3 fix (logEventDetached) exists to bound, not
  // eliminate -- a fixed ~800ms window asserting "nothing showed up yet"
  // could pass for the wrong reason (the write just had not landed yet),
  // not because it was genuinely suppressed. Dispatching a real,
  // known-valid sentinel call and waiting for IT with the same retry loop
  // phase 1 already uses proves the write pipeline had every chance to
  // deliver something by the time absence is actually checked.
  function armPhase3Sentinel() {
    if (root.cli !== "")
      try {
        root.logEventDetached([root.cli, "log-event", "phase3-sentinel", "ok", "proves-write-pipeline-caught-up"])
      } catch (e) {}
  }

  function startPhase4() {
    root.phase = 4
    root.externalAction = "restore"
    root.externalToken = "1788125003-6"
    root.externalBusy = true
    externalProc.launchAction = root.externalAction
    externalProc.launchToken = root.externalToken
    // Short content (well under the 2000-char truncation budget) with an
    // embedded NUL -- deliberately kept apart from phase 5's truncation
    // scenario. Combining both properties in one oversized blob would not
    // actually distinguish "the code strips the NUL and joins what's on
    // both sides" from "something upstream already truncated the buffer
    // AT the NUL, and truncation just happens to land in the same place
    // either way" -- both produce an identical final result once the
    // content is long enough for the 2000-char cut to also apply. "MORE"
    // surviving, correctly joined with the leading "BEFORE" (not "BEFORE"
    // alone), only happens if the NUL was actually stripped by this code
    // -- Qt/QProcess itself, if it already truncated the stream at a raw
    // NUL byte (a real risk with C-string-oriented APIs), would leave
    // "MORE" unreachable regardless of anything in Panel.qml.
    externalProc.command = ["bash", "-c", "printf 'BEFORE\\0MORE' >&2; exit 4"]
    externalProc.running = true
  }

  function startPhase5() {
    root.phase = 5
    root.externalAction = "restore"
    root.externalToken = "1788125004-7"
    root.externalBusy = true
    externalProc.launchAction = root.externalAction
    externalProc.launchToken = root.externalToken
    // Pure ASCII, no NUL at all, 2500 characters -- isolates the >2000
    // truncation property from phase 4's NUL-stripping one.
    externalProc.command = ["bash", "-c",
      "printf 'A%.0s' $(seq 1 2500) >&2; printf 'TAIL' >&2; exit 3"]
    externalProc.running = true
  }

  // One polling timer drives all four phases in sequence.
  Timer {
    interval: 100
    repeat: true
    running: true
    property int tries: 0
    onTriggered: {
      tries++
      if (tries > 150) {  // 15s overall ceiling
        console.log("[result] timed out in phase " + root.phase)
        Qt.exit(1)
        return
      }
      if (root.phase === 1) {
        if (root.externalBusy) return
        tries = 0
        checkPhase1.running = true
        root.phase = -1  // pause polling until checkPhase1 advances us
      } else if (root.phase === 2) {
        // Real completion signal (the OS process actually exited, so its
        // onExited -- and the stale-callback guard inside it -- has
        // already had its chance to run), not a guessed delay -- found by
        // review (round omabackup-31, `omabackup-rev`): a fixed tick count
        // could check before the exit was even delivered, passing for the
        // wrong reason rather than proving the guard actually fired.
        if (externalProc.running) return
        tries = 0
        checkPhase2.running = true
        root.phase = -1
      } else if (root.phase === 3) {
        // Real completion signal (the OS process actually exited), not a
        // guessed delay -- `running` reflects the process lifecycle
        // regardless of what onExited's own guard logic does with it.
        if (externalProc.running) return
        tries = 0
        armPhase3Sentinel()
        root.phase = 30  // now wait for the sentinel itself to land
      } else if (root.phase === 30) {
        if (checkPhase3.running) return
        checkPhase3.running = true
      } else if (root.phase === 4) {
        if (root.externalBusy) return
        tries = 0
        checkPhase4.running = true
        root.phase = -1
      } else if (root.phase === 5) {
        if (root.externalBusy) return
        tries = 0
        checkPhase5.running = true
        root.phase = -1
      }
    }
  }

  Process {
    id: checkPhase1
    command: ["bash", "-c", 'test -s "$1" && cat "$1"', "bash", root.recordFile]
    stdout: StdioCollector {
      id: c1
      onStreamFinished: {
        var out = c1.text
        if (out === "") { root.phase = 1; return }  // not written yet, retry
        var lines = out.split("\n")
        var ok =
          lines.length === 6 &&
          lines[0] === "log-event" &&
          lines[1] === "restore (interactive)" &&
          lines[2] === "failed (launch)" &&
          lines[3].indexOf("exit 7") === 0 &&
          lines[3].indexOf("stderr=boom: could not open display") !== -1 &&
          lines[3].indexOf("token 1788124999-2") !== -1 &&
          lines[4] === "---"
        console.log("[phase1] " + JSON.stringify(lines) + " ok=" + ok)
        if (!ok) { Qt.exit(1); return }
        startPhase2()
      }
    }
  }

  Process {
    id: checkPhase2
    command: ["bash", "-c", 'cat "$1"', "bash", root.recordFile]
    stdout: StdioCollector {
      id: c2
      onStreamFinished: {
        var lines = c2.text.split("\n")
        var stillJustPhase1 = lines.length === 6 && c2.text.indexOf("late failure") === -1
        var bStillActive = root.externalAction === "config" && root.externalToken === "1788125001-4" && root.externalBusy === true
        var ok = stillJustPhase1 && bStillActive
        console.log("[phase2] recordUnchanged=" + stillJustPhase1 +
          " sessionB_action=" + root.externalAction + " sessionB_token=" + root.externalToken +
          " sessionB_busy=" + root.externalBusy + " ok=" + ok)
        if (!ok) { Qt.exit(1); return }
        startPhase3()
      }
    }
  }

  Process {
    id: checkPhase3
    command: ["bash", "-c", 'test -s "$1" && cat "$1"', "bash", root.recordFile]
    stdout: StdioCollector {
      id: c3
      onStreamFinished: {
        var out = c3.text
        var sentinelAt = out.indexOf("phase3-sentinel")
        if (sentinelAt === -1) return  // sentinel has not landed yet -- next tick retries
        // The sentinel's own job is narrower than it might look: it is a
        // real, later, actually-observed write to wait for INSTEAD OF a
        // guessed time window (see armPhase3Sentinel's own comment) -- it
        // does NOT formally fence the suppressed attempt's own write
        // against it, since the two are independent `execDetached` chains
        // with no ordering guarantee between them (found in review, round
        // omabackup-32, `omabackup-rev`/`omabackup-rev-2`, converging on
        // the same fact: a leak could in principle still land AFTER the
        // sentinel). What actually proves absence is `lines.length === 11`
        // below -- it catches a leak WHEREVER in the file it lands, not
        // only before the sentinel. `beforeSentinel` is kept only as a
        // more readable diagnostic on failure; do not simplify this check
        // down to just the `beforeSentinel` clause, or the proof goes with
        // it silently.
        var beforeSentinel = out.slice(0, sentinelAt)
        var lines = out.split("\n")
        var ok = lines.length === 11 && beforeSentinel.indexOf("second failure") === -1
        console.log("[phase3] beforeSentinel=" + JSON.stringify(beforeSentinel) +
          " totalLines=" + lines.length + " ok=" + ok)
        if (!ok) { Qt.exit(1); return }
        startPhase4()
      }
    }
  }

  Process {
    id: checkPhase4
    command: ["bash", "-c", 'cat "$1"', "bash", root.recordFile]
    stdout: StdioCollector {
      id: c4
      onStreamFinished: {
        var lines = c4.text.split("\n")
        // Three recorded calls total now (phase 1, the phase-3 sentinel,
        // then this one) -- phase 2 and phase 3's own suppressed attempt
        // recorded nothing.
        var last = lines.slice(10)  // this call's own block, after phase1's + the sentinel's 5 lines each
        var detail = last.length > 3 ? last[3] : ""
        var hasNul = c4.text.indexOf("\x00") !== -1
        // "BEFOREMORE" (joined, NUL gone) proves the code actually
        // stripped the NUL -- not merely that Qt/QProcess itself truncated
        // the stream at the NUL upstream, which would leave "MORE"
        // unreachable regardless of anything in Panel.qml and "BEFORE"
        // alone in the detail instead.
        var joinedOk = detail.indexOf("stderr=BEFOREMORE") !== -1
        var noMarker = detail.indexOf("…(truncated)") === -1  // short content, no truncation expected
        var ok = lines.length === 16 && last[0] === "log-event" && last[1] === "restore (interactive)" &&
          last[2] === "failed (launch)" && !hasNul && joinedOk && noMarker &&
          detail.indexOf("token 1788125003-6") !== -1
        console.log("[phase4] lastLine=" + JSON.stringify(last) + " hasNul=" + hasNul +
          " joinedOk=" + joinedOk + " noMarker=" + noMarker + " ok=" + ok)
        if (!ok) { Qt.exit(1); return }
        startPhase5()
      }
    }
  }

  Process {
    id: checkPhase5
    command: ["bash", "-c", 'cat "$1"', "bash", root.recordFile]
    stdout: StdioCollector {
      id: c5
      onStreamFinished: {
        var lines = c5.text.split("\n")
        // Four recorded calls total now (phase 1, the phase-3 sentinel,
        // phase 4, phase 5) -- phase 5's own block starts after the first
        // three (5 lines each).
        var last = lines.slice(15)
        var detail = last.length > 3 ? last[3] : ""
        var hasMarker = detail.indexOf("…(truncated)") !== -1
        var hasTail = detail.indexOf("TAIL") !== -1  // must be gone -- past the 2000-char cut
        var stderrStart = detail.indexOf("stderr=")
        var afterStderr = stderrStart >= 0 ? detail.slice(stderrStart + "stderr=".length) : ""
        var stderrPart = afterStderr.split(" …(truncated)")[0]
        var lengthOk = stderrPart.length === 2000
        var allA = /^A+$/.test(stderrPart)
        var ok = lines.length === 21 && last[0] === "log-event" && last[1] === "restore (interactive)" &&
          last[2] === "failed (launch)" && hasMarker && !hasTail && lengthOk && allA &&
          detail.indexOf("token 1788125004-7") !== -1
        console.log("[phase5] lastLine=" + JSON.stringify(last) +
          " hasMarker=" + hasMarker + " hasTail=" + hasTail + " stderrLen=" + stderrPart.length +
          " allA=" + allA + " ok=" + ok)
        Qt.exit(ok ? 0 : 1)
      }
    }
  }
}
