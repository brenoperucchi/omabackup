import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmaBackup's bar surface: an icon that stays quiet while coverage holds, and a
// panel listing what the last check found.
//
// This file reads two JSON documents from the `omabackup` CLI and, from its
// buttons, asks that same CLI to act -- exactly as the systemd timer does. It
// never writes a file itself and never runs git itself (DESIGN.md §1); the
// distinction is that the work happens in the CLI, where it is testable and
// where a failure cannot take the desktop with it.
// An error in this file would take down the bar, the dock and the menu at once
// (docs/CONTEXT.md §2), so every boundary is guarded and the worst case is a
// widget that hides itself.
Panel {
  id: root
  moduleName: "brenoperucchi.omabackup"
  ipcTarget: "brenoperucchi.omabackup"
  manageIpc: false

  // ── state, all of it derived from `omabackup verify --json` ──────────────
  property bool cliMissing: false
  // Set alongside cliMissing only by the resolve-timeout Timer, never by a
  // clean "not installed" result. A review round found that routing a
  // HUNG resolve through the same cliMissing=true path as a genuinely
  // absent CLI collapsed them into the same `visible: false` outcome --
  // the widget's own "not configured" headline exists specifically so a
  // real problem is not silence, and `visible: false` hides that text from
  // ever being seen. "Not installed" staying quiet is the deliberate,
  // pre-existing design (see the comment at `visible` below); a hang is a
  // different fact -- something IS there and did not answer -- and deserves
  // to say so rather than degrade to the exact same invisible result.
  property bool resolveTimedOut: false
  property bool checking: false
  property string lastError: ""
  property var report: null

  // ── and from `omabackup status --json`, deliberately a second document ────
  // Not folded into verify: verify's exit code is meaningful -- non-zero means
  // coverage broke, and cmd_sync refuses to commit on it. A destination in
  // there would let an unplugged drive block the git commit, the inverse of
  // DESIGN.md §3's "one destination failing does not invalidate the others".
  // status always exits 0 and never probes the network, so polling it is free.
  property var statusDoc: null

  readonly property var destinations: cleanDestinations(statusDoc)
  // github is always the implicit destination derived from OMABACKUP_REPO's
  // own `origin` remote (DESIGN.md §3) -- it gets its own button up top,
  // next to the other primary actions, instead of sitting in the generic
  // Destinations list below with whatever `dir` destinations exist.
  readonly property var githubDestination: {
    for (var i = 0; i < destinations.length; i++)
      if (destinations[i].id === "github") return destinations[i]
    return null
  }
  readonly property var otherDestinations: destinations.filter(function(d) { return d.id !== "github" })
  // Absent scheduler key means an older CLI, not an unscheduled machine: do not
  // invent an alarm out of a missing field.
  // §4: the badge does not clear itself. "nothing is scheduled" was already
  // here; this is the worse sibling -- a timer that exists and has been failing
  // quietly, which leaves every other number on this panel out of date while
  // the panel stays green.
  readonly property bool staleKnown:
    statusDoc !== null && statusDoc.stale !== undefined && statusDoc.stale !== null
  readonly property bool stale: staleKnown ? (statusDoc.stale === true) : false
  readonly property var lastSyncAge:
    statusDoc && statusDoc.lastSyncAgeSec !== undefined ? statusDoc.lastSyncAgeSec : null
  readonly property bool neverSynced: staleKnown && statusDoc.lastSync === null

  readonly property string staleText: {
    if (!stale) return ""
    if (neverSynced) return "No backup has ever completed on this machine."
    if (lastSyncAge === null) return "The last backup is out of date."
    var h = Math.floor(lastSyncAge / 3600)
    if (h < 48) return "Last successful backup was " + h + "h ago."
    return "Last successful backup was " + Math.floor(h / 24) + " days ago."
  }

  // Where this machine is pointed. All of it is machine identity rather than
  // project data -- the repo receiving the backup, the destinations file, the
  // deny-list, the schedule -- so none of it is in the public manifest, and the
  // only other way to know is to read four files in three directories.
  readonly property var config: statusDoc && statusDoc.config ? statusDoc.config : null
  readonly property string syncSchedule:
    statusDoc && statusDoc.scheduler
      ? (statusDoc.scheduler.syncCron || statusDoc.scheduler.sync || "") : ""
  readonly property string pushSchedule:
    statusDoc && statusDoc.scheduler
      ? (statusDoc.scheduler.pushCron || statusDoc.scheduler.push || "") : ""

  // "last backup 8m ago", the way the mockup's header reads it.
  function agoText(sec) {
    if (typeof sec !== "number" || !isFinite(sec) || sec < 0) return "never"
    if (sec < 90) return "just now"
    if (sec < 5400) return Math.round(sec / 60) + "m ago"
    if (sec < 172800) return Math.round(sec / 3600) + "h ago"
    return Math.round(sec / 86400) + "d ago"
  }

  readonly property string summaryLine: {
    var bits = []
    bits.push("last backup " + agoText(lastSyncAge))
    if (groups.length > 0) bits.push(groups.length + " groups")
    if (coveredFiles > 0) bits.push(coveredFiles + " files")
    return bits.join("  ·  ")
  }

  // "2m ago" from the ISO stamp the CLI writes. A wall-clock UTC string is
  // precise and useless at a glance -- "2026-08-25 01:03:51 UTC" makes you do
  // subtraction to answer "is this current?".
  function agoFromIso(iso) {
    if (!iso) return ""
    var t = Date.parse(String(iso))
    if (isNaN(t)) return ""
    return agoText(Math.max(0, (Date.now() - t) / 1000))
  }

  function shortPath(p) {
    if (typeof p !== "string" || p === "") return "—"
    var h = Quickshell.env("HOME")
    return (h && p.indexOf(h) === 0) ? "~" + p.substring(h.length) : p
  }
  // The CLI exposes the user-facing five-field crontab form. Keep the calendar
  // fallback for an older installed CLI, but never make the systemd expression
  // the normal thing a person has to understand.
  function humanSchedule(c) {
    if (typeof c !== "string" || c === "") return "not scheduled"
    if (c === "* * * * *" || c === "*/1 * * * *"
        || c === "*:*:00" || c === "*-*-* *:*:00") return "every minute"
    var m = c.match(/^\*\/(\d+) \* \* \* \*$/)
    if (m) return "every " + m[1] + " min"
    if (c === "0 * * * *" || c.indexOf("*:00:00") >= 0) return "hourly"
    m = c.match(/^(\d+) \* \* \* \*$/)
    if (m) return "hourly at :" + ("0" + m[1]).slice(-2)
    m = c.match(/^(\d+) (\d+) \* \* \*$/)
    if (m) return "daily at " + ("0" + m[2]).slice(-2) + ":" + ("0" + m[1]).slice(-2)
    m = c.match(/^(\d+) (\d+) \* \* ([0-7])$/)
    if (m) {
      var days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
      return days[Number(m[3]) === 7 ? 0 : Number(m[3])] + " at "
             + ("0" + m[2]).slice(-2) + ":" + ("0" + m[1]).slice(-2)
    }
    m = c.match(/\*:00\/(\d+):00/)
    if (m) return "every " + m[1] + " min"
    return c
  }

  readonly property bool schedulerKnown:
    statusDoc !== null && statusDoc.scheduler !== undefined && statusDoc.scheduler !== null
  readonly property bool scheduled: schedulerKnown ? (statusDoc.scheduler.active === true) : true

  // A destination that has errored, or that has never once succeeded, is the
  // "committed but never left the machine" state nothing used to report.
  readonly property var destAlerts: {
    var out = []
    for (var i = 0; i < destinations.length; i++) {
      var d = destinations[i]
      if (!d) continue
      if (d.failed || d.lastSuccess === "") out.push(d)
    }
    return out
  }

  // ── what is covered, per group ───────────────────────────────────────────
  // From verify --json, counted by collect rather than recomputed here: collect
  // is what decides which files enter the backup, and a second implementation
  // of that decision would eventually disagree with the first.
  readonly property var groups: cleanGroups(report)
  readonly property int coveredFiles: {
    var t = 0
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      if (g && typeof g.files === "number") t += g.files
    }
    return t
  }
  readonly property real coveredBytes: {
    var t = 0
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      if (g && typeof g.bytes === "number") t += g.bytes
    }
    return t
  }

  function humanSize(b) {
    if (typeof b !== "number" || !isFinite(b) || b < 0) return "?"
    if (b < 1024) return b + " B"
    if (b < 1048576) return Math.round(b / 1024) + " KB"
    return (Math.round(b / 104857.6) / 10) + " MB"
  }

  function copyToolVersion() {
    if (root.toolVersion === "?" || root.toolVersion === "") return
    Quickshell.clipboardText = root.toolVersion
    root.versionCopied = true
    versionCopiedTimer.restart()
  }

  // "not collected yet" is not "covers nothing". Zero means collect ran and
  // found nothing there, which is the phantom coverage this tool exists to
  // catch; unknown means it has not looked.
  function groupDetail(g) {
    if (!g) return ""
    if (typeof g.files !== "number") return "not collected yet"
    if (g.files === 0) return "covers nothing"
    return g.files + (g.files === 1 ? " file · " : " files · ") + humanSize(g.bytes)
  }

  // A mode:gen group's tooltip fallback names the generator field
  // ("packages", "systemd") -- accurate, but only meaningful to someone who
  // already knows what those two commands in bin/omabackup actually run.
  // This says what each one produces instead. Unlisted/future generator
  // names fall back to the raw name rather than showing nothing.
  function generatorDescription(gen) {
    if (gen === "packages") return "Installed packages (pacman -Qqe/-Qqem/-Qqen)"
    if (gen === "systemd") return "Enabled systemd services (user + system)"
    return gen
  }

  readonly property int failCount: report && report.counts ? (report.counts.fail || 0) : 0
  readonly property int warnCount: report && report.counts ? (report.counts.warn || 0) : 0
  // report.ok is now consulted explicitly, not only the finding counts -- a
  // review round's PoC ({"ok":false,"counts":[]}) passed applyReport's shape
  // check (ok was checked for TYPE, not VALUE) and still rendered as
  // covered:true, since this binding never looked at ok at all. The CLI's
  // own top-level verdict is the more authoritative signal; failCount/
  // warnCount stay in the expression too; both being clean is still
  // required, but it is no longer sufficient on its own.
  readonly property bool covered: report !== null && report.ok === true && failCount === 0 && warnCount === 0
  readonly property string toolVersion:
    statusDoc && statusDoc.tool && typeof statusDoc.tool.version === "string"
      ? statusDoc.tool.version : "?"
  readonly property string omarchyVersion: report && report.omarchy ? (report.omarchy.version || "?") : "?"
  readonly property string watermark: report && report.omarchy ? (report.omarchy.migrationWatermark || "?") : "?"
  property bool versionCopied: false

  // Omarchy's palette has no green on purpose, and neither does this widget:
  // "up to date" is the absence of colour. Colour means there is something to do.
  readonly property color barText: bar ? bar.barForeground : Color.foreground
  // Ordered by how badly it needs a human. "not scheduled" ranks above a
  // warning count because nothing running the backup makes every other number
  // on this panel stale -- it is the August incident one level up.
  // report.ok is checked here too now, not only in `covered` -- a review
  // round found the two disagreeing: `covered` already required
  // report.ok === true, but headline fell through to its LAST branch
  // ("covered") for a document like {"ok":false,"counts":{}} that
  // applyReport's shape check still accepts (well-formed JSON, zero
  // findings, but the CLI's own top-level verdict says something is wrong).
  // The icon would dim as though healthy while the text next to it said
  // "covered" for a report that says the opposite of itself.
  readonly property string headline: resolveTimedOut ? "check failed"
                                   : cliMissing ? "not configured"
                                   : lastError !== "" ? "check failed"
                                   : report === null ? "not checked yet"
                                   : report.ok !== true ? "check failed"
                                   : failCount > 0 ? failCount + (failCount === 1 ? " failure" : " failures")
                                   : !scheduled ? "not scheduled"
                                   : neverSynced ? "never run"
                                   : stale ? "out of date"
                                   : destAlerts.length > 0 ? "not sent"
                                   : warnCount > 0 ? warnCount + (warnCount === 1 ? " warning" : " warnings")
                                   : "covered"

  // Findings worth a human's attention. `pass` and `info` stay out of the list
  // so a healthy system shows an empty panel rather than a wall of green ticks.
  readonly property var alerts: {
    if (!report || !report.findings) return []
    var out = []
    for (var i = 0; i < report.findings.length; i++) {
      var f = report.findings[i]
      if (f && (f.level === "fail" || f.level === "warn")) out.push(f)
    }
    return out
  }

  // QuickShell.Io.Process has no group-kill of its own: `running = false`
  // sends SIGTERM to a single tracked PID (QProcess::terminate()), and
  // `signal()` calls a bare, single-PID kill(2) -- confirmed directly
  // against quickshell-mirror/quickshell's own process.cpp, the source for
  // the 0.3.1-1 build this machine has installed. verify/status/sync/
  // collect/enable-disable's own `command` is wrapped in `setsid --` for
  // exactly this reason (see each Process below): it makes the tracked
  // PID its own process-group leader, so THIS PID also names the whole
  // tree -- including a `git`/`rsync` child a timed-out verb was blocked
  // on, which used to survive as an orphan after busyTimeoutTimer gave up
  // on the parent alone. Flagged in marketplace security review
  // (https://github.com/omacom/omarchy-plugin-marketplace/issues/3968).
  //
  // Spawns `omabackup kill-group <pid>` rather than reimplementing
  // process-group signal handling here (design consultation, herdr-ask
  // round omabackup-11, both reviewers independently converged on this):
  // this project already spent several review rounds getting that logic
  // right once, in bin/omabackup-tui's own _group_pgid_wait/_stop_group --
  // a second implementation, in QML, with no test suite exercising it,
  // invites a third. The dynamically created Process is disposable and
  // self-destroys once it exits.
  //
  // Takes the whole `proc`, not just its pid -- needed for the backstop
  // below, and safer than reading `proc.processId` a second time later:
  // it reads back null once `running` goes false, so the pid this
  // function itself needs is captured once, up front, the same instant
  // the caller decided to kill something.
  //
  // Backstop timer, added by explicit decision (design consultation,
  // herdr-ask, after round omabackup-25/26's own review cycle):
  // `killGroup` becoming the ONLY thing that ever stops a timed-out or
  // output-capped process (round omabackup-25's fix for a real race --
  // see busyTimeoutTimer's own comment) removed the old guarantee that
  // SOMETHING always signals the target. If this helper Process fails to
  // even start, nothing recovers on its own: `onExited` never fires, and
  // `busy` stays stuck permanently -- every panel action disabled, no
  // path out short of restarting the panel (`omabackup-rev-2`'s finding,
  // round omabackup-26). A short one-shot Timer checks back after giving
  // the helper every reasonable chance, and falls back to a direct
  // `proc.running = false` ONLY if the target is somehow still running by
  // then. This does NOT reopen the race the direct kill used to cause:
  // that race was specifically "a direct kill wins IMMEDIATELY, before
  // the helper's own ps/kill sequence ever runs" -- a fallback emitted
  // seconds later, after the helper (round omabackup-26's own fix: no
  // longer even needs `ps` to find the group, since it trusts the
  // setsid-captured pid as the group's own id directly) has had its full
  // ~1s TERM-then-KILL window, is not competing with anything.
  //
  // Checked against the CAPTURED pid, not just `proc.running` -- found by
  // review (round omabackup-27, `omabackup-rev`): `verifyProc`/
  // `statusProc`/`syncProc`/`collectProc`/`switchProc` are singleton
  // Process objects, reused across runs (`refresh()`/`syncNow()`/etc. all
  // set `running = true` again on the SAME object). If the helper killed
  // the OLD run quickly and the operator started a brand new run of that
  // same process within the backstop's own window, a stale backstop that
  // only checked `proc.running` would see the NEW run as "still running"
  // and kill IT directly -- a single-PID kill, capable of reopening the
  // exact descendant-orphaning problem this whole mechanism exists to
  // close, on a run this backstop was never armed for. Comparing against
  // the pid captured when THIS backstop was created makes it a no-op for
  // any run other than the one it was actually watching.
  readonly property int killGroupBackstopMs: 3000
  function killGroup(proc) {
    var pid = proc.processId
    if (pid === null || pid === undefined || root.cli === "") return
    var killer = Qt.createQmlObject(
      'import Quickshell.Io; Process { }', root, "killGroupHelper")
    killer.command = [root.cli, "kill-group", String(pid)]
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

  // A producer-side byte ceiling belongs in bin/omabackup, not here (it is
  // the actual producer; this is the consumer) -- but StdioCollector's own
  // unbounded internal buffer is a real, separate problem this CAN fix:
  // it appends every chunk to one QByteArray with no size check at all
  // (confirmed against quickshell-mirror/quickshell's datastream.cpp), so
  // a misbehaving or compromised CLI process could grow the panel's own
  // memory without bound. Applied uniformly to both stdout and stderr,
  // across all five CLI-launched processes below -- found by review
  // (round omabackup-25, `omabackup-rev`): the declared threat model (a
  // compromised or malfunctioning CLI) does not distinguish stdout from
  // stderr, and a `git`/`rsync`/hook writing rapidly to stderr can exhaust
  // memory before a timeout would ever catch it, same as stdout could.
  // Every collector below uses `SplitParser { splitMarker: "" }` instead
  // of `StdioCollector`: confirmed directly in datastream.cpp that an
  // empty marker makes SplitParser emit every chunk immediately via
  // `read()` and never append to its own internal buffer -- true
  // incremental delivery, not a delimiter this JSON/text payload happens
  // to lack. This function is what actually bounds memory: it owns the
  // accumulation and the cap, past which it stops appending, marks a
  // reason distinct from a timeout, and kills the process (group and
  // all, same as a timeout would) rather than only stopping this
  // function's OWN accumulation while the process keeps running and
  // writing into a pipe buffer nobody reads. `field` names which property
  // to accumulate into ("buffer" or "errBuffer") -- stdout and stderr on
  // the SAME process share one `outputCapped` latch, since the message
  // shown to the operator does not need to distinguish which channel
  // overflowed.
  //
  // 256 KiB: generous for what these commands actually produce (a JSON
  // finding per declared group and a handful of config fields on stdout;
  // a few lines of human-readable error text on stderr), while still
  // bounding the worst case to a fixed number. Measured in JS string
  // length (UTF-16 code units), not raw bytes -- an exact byte count
  // would need to live in bin/omabackup, the actual producer; this is an
  // honest approximation, not a byte-exact guarantee, and said so here
  // rather than presented as more precise than it is.
  //
  // KNOWN, documented limitation (found by review, round omabackup-25,
  // `omabackup-rev`), not fixed here: `SplitParser`'s empty-marker branch
  // converts each raw chunk to a QString independently and does not
  // retain incomplete trailing bytes for the next chunk (confirmed
  // against datastream.cpp's own empty-marker code path) -- so a
  // multi-byte UTF-8 character split across two separate reads can arrive
  // as replacement characters before this function ever sees it. `jq`
  // does not ASCII-escape non-ASCII output by default, so a real path,
  // hostname, or label containing one could, in principle, be corrupted
  // this way in the two JSON stdout channels (verify/status). Since round
  // omabackup-25, this function is ALSO used for all five processes'
  // stderr (`omabackup-rev-2`'s own point, same round, on why the split
  // was triage not a boundary) -- stderr is where human-readable error
  // text carrying real user paths lives, and non-ASCII is if anything
  // MORE likely there than in jq's own JSON, not less. The exposure
  // quintupled in the very round that documented it; noted here so the
  // two decisions (extend the cap everywhere, defer the UTF-8 fix) don't
  // read as unrelated. Fixing this correctly needs the cap to live in the
  // producer (bin/omabackup itself, operating on whole, already-decoded
  // strings) rather than the consumer -- a larger change than either
  // round of fixes took on; see "Open questions" in docs/PLAN.md.
  //
  // Does NOT set `proc.running = false` itself -- found by review (round
  // omabackup-25): the killGroup() helper is its own separate Process,
  // still starting up (launching bash, sourcing lib/*.sh) when this
  // returns. If this ALSO terminated the leader directly and the leader
  // happened to die first, the helper's own `ps -o pgid= -p <pid>` lookup
  // (bin/omabackup:2882) would then find nothing for an already-reaped
  // pid, fall through to a no-op single-pid signal, and never reach the
  // group at all -- orphaning exactly the descendant this whole mechanism
  // exists to catch. Letting killGroup()'s own eventual TERM (to the
  // group, since a setsid-wrapped leader IS a member of its own group)
  // be the ONLY thing that kills the leader removes the race outright:
  // QuickShell's own `exited`/`runningChanged` still fire once the OS
  // process actually dies, whoever signaled it.
  readonly property int maxOutputBytes: 262144
  function accumulateCapped(proc, field, chunk) {
    if (proc.outputCapped) return
    if (proc[field].length + chunk.length > root.maxOutputBytes) {
      proc.outputCapped = true
      root.killGroup(proc)
      return
    }
    proc[field] = proc[field] + chunk
  }

  // keepError: a review round caught this call itself erasing the message an
  // operation had JUST set. sync/collect/switch's onExited sets root.lastError
  // on failure and then, unconditionally, called refresh() to pick up a fresh
  // report -- and this function unconditionally cleared lastError as its
  // SECOND line, before the panel ever rendered it. A sync that failed and
  // one that succeeded went back to looking identical, defeating the whole
  // point of capturing stderr/exit code in the first place. Callers that are
  // reporting their OWN just-set failure pass keepError=true; the periodic
  // timer, the manual "Check again" button, and the startup call all want the
  // normal behaviour -- a fresh check clears whatever was stale.
  function refresh(keepError) {
    // Reading while the CLI is mid-write reports a half-finished state as
    // though it were the answer.
    if (root.checking || root.cliMissing || root.cli === "" || root.busy) return
    root.checking = true
    if (!keepError) root.lastError = ""
    verifyProc.buffer = ""
    // errBuffer reset too, not just buffer/outputCapped -- found while
    // wiring stderr into the same accumulateCapped incremental append:
    // StdioCollector's old `onStreamFinished: proc.errBuffer = text`
    // replaced the whole string every run, so it never needed a reset;
    // accumulateCapped's `proc[field] += chunk` does, or a failed run
    // would show the PREVIOUS run's stderr text prepended to its own.
    verifyProc.errBuffer = ""
    verifyProc.outputCapped = false
    verifyProc.running = true
    if (!statusProc.running) {
      statusProc.buffer = ""
      statusProc.errBuffer = ""
      statusProc.outputCapped = false
      statusProc.running = true
    }
    busyTimeoutTimer.restart()
  }

  // Whatever the CLI returned becomes a known shape HERE, once, instead of a
  // guard at every binding. A newer CLI, a half-written document, a field that
  // is a number where a string was expected: reproduced four binding TypeErrors
  // that way -- a null entry in `groups`, a numeric `mode`, a null destination,
  // a numeric `config.repo`. Guarding each site would have been the same fact
  // written a dozen times.
  function asText(v) { return (typeof v === "string") ? v : "" }
  function asCount(v) {
    return (typeof v === "number" && isFinite(v) && v >= 0) ? Math.floor(v) : null
  }
  function asList(v) { return (v && Array.isArray(v)) ? v : [] }

  function cleanGroups(doc) {
    var out = []
    var raw = doc ? asList(doc.groups) : []
    for (var i = 0; i < raw.length; i++) {
      var g = raw[i]
      if (!g || typeof g !== "object") continue
      out.push({
        id: asText(g.id), label: asText(g.label) || asText(g.id),
        mode: asText(g.mode),
        coupled: g.coupled === true, critical: g.critical === true,
        enabled: g.enabled !== false,
        files: asCount(g.files), bytes: asCount(g.bytes),
        paths: asList(g.paths).filter(function(p) { return typeof p === "string" }),
        generator: asText(g.generator)
      })
    }
    return out
  }

  function cleanDestinations(doc) {
    var out = []
    var raw = doc ? asList(doc.destinations) : []
    for (var i = 0; i < raw.length; i++) {
      var d = raw[i]
      if (!d || typeof d !== "object") continue
      var msg = (d.lastError && typeof d.lastError === "object")
                ? asText(d.lastError.message) : ""
      out.push({
        id: asText(d.id), type: asText(d.type),
        lastSuccess: asText(d.lastSuccess),
        errorMessage: msg, failed: !!d.lastError
      })
    }
    return out
  }

  function applyStatus(text) {
    // Destinations must never be able to break the coverage view. An older CLI
    // with no `destinations` key, a half-written document, anything: the rest
    // of the panel (verify's own report) is entirely unaffected by whatever
    // happens here.
    //
    // On a genuinely unparseable document the PREVIOUS statusDoc is kept
    // (not nulled out), the same "stale but known-good beats nothing"
    // decision statusProc's own empty-buffer handling already makes --
    // paired with lastError, so the panel says this happened instead of
    // quietly presenting old data as current.
    //
    // A review round found this accepted ANYTHING that parsed as an object --
    // "{}", or an array (typeof [] is also "object" in JS) -- as a genuine
    // status document, silently replacing whatever was there before with an
    // empty one and never touching lastError. schemaVersion is the one field
    // `status --json` has carried unconditionally since it existed; requiring
    // it is a cheap, real check that this is actually the document it claims
    // to be, not proof by parsing alone.
    //
    // A follow-up round found schemaVersion alone still let a minimal,
    // truncated document through -- "{\"schemaVersion\":1}" passed, replaced
    // the real statusDoc, and the panel then read the missing destinations/
    // scheduler as genuine (empty) state rather than "could not read
    // status." cmd_status's own jq -n ALWAYS emits destinations (array) and
    // scheduler (object), unconditionally, regardless of what the rest of
    // the machine's state is -- requiring both present in their real shape
    // is still cheap and now actually distinguishes a genuine (if minimal)
    // v1 document from a truncated one.
    //
    // recentLog is NOT required the same way -- found in review (round
    // omabackup-33, both reviewers independently): unlike destinations/
    // scheduler, which the panel cannot render around at all,
    // destinations/scheduler are structurally essential while recentLog is
    // a 5-line cosmetic preview whose absence already has a defined
    // meaning ("[] = nothing logged yet"). resolveProc prefers any
    // `omabackup` already on PATH over this checkout's own binary -- an
    // updated panel talking to an older CLI still on PATH would emit a v1
    // document with no recentLog key at all, and requiring it here would
    // reject the WHOLE document (destinations, scheduler, config, all of
    // it) over one decorative field, turning an additive change into a
    // breaking one for that skew. A field that is PRESENT but the wrong
    // shape still means something is actually wrong, so that case is still
    // rejected -- only "absent" is treated as "not logged yet" rather than
    // "corrupt." recentLogError (added round omabackup-35, alongside
    // making the underlying read failure it reports on a real, checked
    // condition in cmd_status rather than a silently-swallowed one) is
    // optional for the exact same skew reason and defaults to false --
    // "no error reported" is the right reading of an older CLI that does
    // not know this field exists yet, not "an error, unreported."
    try {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed) && parsed.schemaVersion === 1
          && Array.isArray(parsed.destinations)
          && parsed.scheduler && typeof parsed.scheduler === "object" && !Array.isArray(parsed.scheduler)
          && (parsed.recentLog === undefined || Array.isArray(parsed.recentLog))
          && (parsed.recentLogError === undefined || typeof parsed.recentLogError === "boolean")) {
        if (!Array.isArray(parsed.recentLog)) parsed.recentLog = []
        if (typeof parsed.recentLogError !== "boolean") parsed.recentLogError = false
        root.statusDoc = parsed
        return
      }
      root.lastError = "status: unreadable document"
    } catch (e) {
      root.lastError = "status: unreadable document"
    }
  }

  function collect() {
    if (root.cli === "" || root.cliMissing || root.busy) return
    collectProc.errBuffer = ""
    collectProc.outputCapped = false
    collectProc.running = true
    busyTimeoutTimer.restart()
  }

  // "Fazer backup agora" from the mockup. The plugin still writes nothing and
  // runs no git itself (DESIGN.md §1) -- it asks the CLI, exactly as the timer
  // does, and re-reads when the CLI is done.
  // The master switch. Unlike the group toggles, this one sets: `enable` and
  // `disable` start and stop the timers, which is what "is omabackup on" means
  // -- with them stopped nothing collects, commits or is sent.
  // One notion of busy, not one guard per process. Each Process only checked
  // whether IT was already running, so a sync, a collect, an enable and the
  // refresh timer could all be in flight over the same repository at once --
  // and the panel would then read state from the middle of its own write.
  //
  // verifyProc/statusProc are included here too, not only in refresh()'s own
  // `checking` guard: syncNow()/collect()/setEnabled() only ever checked
  // `busy`, never `checking`, so any of them could start WHILE a refresh was
  // still in flight -- and each one restarts the shared busyTimeoutTimer,
  // which would then reset the window a still-running verify/status was
  // being timed against, silently extending how long a hang in either could
  // go unnoticed every time another button was pressed.
  readonly property bool busy:
    syncing || switching || configuring || externalBusy || collectProc.running || verifyProc.running || statusProc.running
  readonly property bool canOpenExternalTui:
    root.cli !== "" && !root.cliMissing && !root.busy
  property bool switching: false
  property bool configuring: false
  property bool externalBusy: false
  property string externalAction: ""
  property int externalGeneration: 0
  property string externalToken: ""

  // Config is reference material -- six paths and two schedules, consulted
  // once per install and otherwise just occupying permanent space above
  // Groups/Destinations, which is what a human actually opens this panel
  // to see. Collapsed by default; the click target is the section header
  // itself, matching the affordance a chevron already implies.
  property bool configExpanded: false

  function toggleSettings() {
    root.configExpanded = !root.configExpanded
    if (root.configExpanded) settingsRevealTimer.restart()
  }

  // Open by default, unlike configExpanded above: this section now sits
  // near the top (right after the primary actions), carries the GitHub
  // destination's status text as its first line, and a keyboard-only user
  // has no other path to that text (see docs/PLAN.md's own writeup on
  // this round) -- collapsing it by default would silently reopen that
  // gap. A user can still collapse it manually; that is an honest,
  // accepted residual, not something this default tries to prevent.
  property bool activityExpanded: true

  // No settingsRevealTimer.restart() here, unlike toggleSettings() above:
  // that timer always scrolls to the BOTTOM of the Flickable
  // (Panel.qml:~1145), which only made sense while this section lived
  // there too. Now that it sits above the fold, restarting it on expand
  // would scroll the panel away from the section a user just opened
  // whenever Current settings also happens to be expanded.
  function toggleActivity() {
    root.activityExpanded = !root.activityExpanded
  }

  // Restore is intentionally terminal-owned, just like Settings: the CLI
  // lists artifacts, explains targets, previews the plan, and asks for the
  // final confirmation in the same ANSI surface used over SSH/recovery TTY.
  function openRestore() { openExternalTui("restore") }

  function setEnabled(on) {
    // `cli === ""` is not the same as `cliMissing`: between startup and the
    // resolver answering, neither is true, and the command would have gone out
    // as ["", "enable"].
    if (root.cli === "" || root.cliMissing || root.busy) return
    root.switching = true
    switchProc.errBuffer = ""
    switchProc.outputCapped = false
    // setsid: see verifyProc/root.killGroup() above.
    switchProc.command = ["setsid", "--", root.cli, on ? "enable" : "disable"]
    switchProc.running = true
    busyTimeoutTimer.restart()
  }

  function openExternalTui(action) {
    if (!root.canOpenExternalTui) return
    root.externalGeneration += 1
    // Include wall-clock entropy so a callback from a TUI launched before a
    // QuickShell reload cannot collide with the first token in the new panel
    // process. The generation still distinguishes launches in one process.
    root.externalToken = String(Date.now()) + "-" + String(root.externalGeneration)
    root.externalAction = action
    root.externalBusy = true
    root.configuring = action === "config"
    // KeyboardPanel owns the fade-out. Waiting for it to finish prevents the
    // terminal window and the Omarchy panel from occupying the same visual
    // space for one frame during the handoff.
    root.close()
    externalLaunchTimer.restart()
  }

  function openConfig() { openExternalTui("config") }

  // The GitHub button opens the LOCAL backup repository (OMABACKUP_REPO) in
  // the file manager -- "where the files were saved" before `push` sends
  // them on. Not github.com: that would start a network trip from what is
  // otherwise a read-only status button, and the panel never does that on a
  // click it did not ask to confirm. Util.execArgv (qs.Commons) is the
  // shared, injection-safe way first-party plugins already launch xdg-open.
  function openRepoInFileManager() {
    if (!root.config || !root.config.repo) return
    Util.execArgv(["xdg-open", root.config.repo])
  }

  // omarchy-launch-tui only reports that the terminal was launched. The small
  // wrapper inside that terminal calls this IPC method after the actual CLI
  // returns, so reopening the panel cannot race the still-running TUI.
  function finishExternalTui(payload) {
    var parts = typeof payload === "string" ? payload.split(":") : []
    var action = parts.length === 3 ? parts[0] : ""
    var exitText = parts.length === 3 ? parts[1] : ""
    var token = parts.length === 3 ? parts[2] : ""
    if (!/^[0-9]+$/.test(exitText) || !/^[0-9]+-[0-9]+$/.test(token)) return "ignored"
    var exitCode = Number(exitText)
    if (!isFinite(exitCode) || exitCode < 0 || exitCode > 255 || Math.floor(exitCode) !== exitCode
        || (action !== "config" && action !== "restore")
        || root.externalAction !== action || root.externalToken !== token)
      return "ignored"
    externalRecoveryTimer.stop()
    root.externalAction = ""
    root.externalToken = ""
    root.externalBusy = false
    root.configuring = false
    if (exitCode !== null && exitCode !== 0) {
      root.lastError = action + ": terminal command exited with status " + exitCode
      root.refresh(true)
    } else {
      root.refresh(false)
    }
    return "ok"
  }

  function heartbeatExternalTui(token) {
    if (typeof token !== "string" || root.externalAction === "" || root.externalToken !== token)
      return "ignored"
    externalRecoveryTimer.restart()
    return "ok"
  }

  property bool syncing: false
  function syncNow() {
    if (root.cli === "" || root.cliMissing || root.busy) return
    root.syncing = true
    syncProc.errBuffer = ""
    syncProc.outputCapped = false
    syncProc.running = true
    busyTimeoutTimer.restart()
  }

  function applyReport(text) {
    // A CLI that dies mid-write, an empty stdout, a future schema: none of
    // these may throw out of here.
    //
    // A review round found this accepted ANY parseable JSON object -- "{}",
    // even an array -- as a genuine report. Bindings throughout this file
    // read missing counts as zero, so "{}" rendered as failCount:0,
    // warnCount:0, covered:true: a truncated-but-parseable response, or a
    // future incompatible schema, produced a false "covered" instead of the
    // refusal this project's own CLI is built to insist on for exactly this
    // shape of failure. `verify --json`'s actual document always carries
    // `schemaVersion:1`, `ok` (boolean) and `counts` (object) -- requiring
    // them is a real, cheap check that this is that document, not proof by
    // successful JSON.parse alone.
    //
    // A follow-up round found this first attempt still had a gap:
    // `typeof [] === "object"` in JS, so `counts` could itself be an array
    // and still pass; and `ok` was checked for TYPE (boolean) but never
    // VALUE, so `{"ok":false,"counts":[]}` -- an artifact reporting its own
    // failure -- was still accepted and, downstream, rendered as covered
    // (the `covered` binding never consulted `ok` either). Both are closed
    // now: counts must not be an array, and `covered` below requires
    // `report.ok === true` explicitly, not just an absence of nonzero
    // counts.
    try {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)
          && parsed.schemaVersion === 1
          && typeof parsed.ok === "boolean"
          && parsed.counts && typeof parsed.counts === "object" && !Array.isArray(parsed.counts)) {
        root.report = parsed
        return
      }
      root.lastError = "unreadable report"
    } catch (e) {
      root.lastError = "unreadable report"
    }
  }

  // ── the CLI ──────────────────────────────────────────────────────────────
  // Resolved once: on PATH when installed, otherwise straight out of the plugin
  // directory, so the widget works before anyone runs an install step.
  readonly property string fallbackCli:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/brenoperucchi.omabackup/bin/omabackup"
  readonly property string tuiCli:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/brenoperucchi.omabackup/bin/omabackup-tui"
  property string cli: ""

  // A stuck CLI used to leave `busy` true forever: none of the machine-action
  // Processes below had a timeout, so a stale NAS mount or held lock left
  // every button dead and the panel silently mute. One shared timer covers
  // refresh/sync/collect/enable; the terminal handoff is deliberately not in
  // that set because omarchy-launch-tui is fire-and-forget. Its Process only
  // reports that the terminal opened; the detached wrapper reports the real
  // TUI completion through IPC.
  readonly property int busyTimeoutMs: Math.max(10, root.setting("busyTimeoutSec", 45)) * 1000
  // IPC is the normal completion path, but a closed terminal or an older
  // Omarchy without `omarchy-shell` must not deadlock every panel action. This
  // is deliberately much longer than an ordinary TUI session; it is a safety
  // valve, not the session timeout used by CLI operations.
  readonly property int externalRecoveryMs:
    Math.max(60, root.setting("externalTuiRecoverySec", 900)) * 1000

  Timer {
    id: busyTimeoutTimer
    interval: root.busyTimeoutMs
    repeat: false
    // Each branch sets that CLI Process's own `timedOut` flag before setting
    // `running = false`. The protection is the FLAG, checked first thing in
    // onExited -- not the order these two lines are written in. A review
    // round measured (not inferred) the actual delivery order with a real
    // headless QuickShell run and found it IS asynchronous: `running`
    // itself is still `true` immediately after this line runs, and the
    // process's own `exited` signal is delivered later, on the event loop.
    // An earlier version of this comment claimed the opposite (synchronous
    // delivery, "before this function returns") to justify writing
    // `timedOut` first -- that claim was wrong, though the code it
    // described was correct anyway, for the real reason: `timedOut` is set
    // and later CHECKED before anything about the outcome is read, and that
    // ordering holds regardless of when onExited actually fires. Without the
    // flag, whenever onExited eventually runs it would overwrite this
    // timeout message with its own "no output, exit 15"/"failed, exit 15" --
    // the exact distinction ("I gave up waiting" vs "the CLI died
    // strangely") this timeout exists to give the operator, lost to a
    // number nobody but a SIGTERM table decodes.
    //
    // Deliberately does NOT clear checking/syncing/switching itself, even
    // though an earlier version did: a review round found that this timer
    // clearing them here made `busy` read false the instant this function
    // returned, decoupled from whether the real OS process had actually
    // finished dying -- a narrow but real window where a brand new operation
    // could start over the same repository while the killed one was still
    // being reaped. Every onExited below already clears its own flag,
    // unconditionally, as its first line, timeout or not; that is now the
    // ONLY place any of them are cleared, so `busy` stays true for exactly as
    // long as the Process genuinely is.
    onTriggered: {
      // verify and status are the one pair that can be running together
      // (both started from the same refresh()) -- a review round found that
      // when both time out at once, the two `if`s below each overwrite
      // root.lastError unconditionally, so the operator only ever sees
      // whichever one happened to run second ("status timed out"), with no
      // mention that verify -- the check that actually matters -- also
      // died. Built as one combined message when both apply, rather than
      // two sequential writes racing each other.
      var timedOutSec = Math.round(root.busyTimeoutMs / 1000)
      var vTimedOut = verifyProc.running
      var sTimedOut = statusProc.running
      if (vTimedOut && sTimedOut) {
        root.lastError = "verify and status both timed out after " + timedOutSec + "s"
      } else if (vTimedOut) {
        root.lastError = "verify timed out after " + timedOutSec + "s"
      } else if (sTimedOut) {
        root.lastError = "status timed out after " + timedOutSec + "s"
      }
      // root.killGroup(proc) reads proc.processId internally, in the
      // SAME statement as timedOut being set -- before `running` could
      // possibly change, which reads `processId` back as null once it
      // does. Each of these five commands is wrapped in `setsid --` so
      // this PID also names the whole process group, not just the one
      // process QuickShell tracked.
      //
      // None of these branches sets `proc.running = false` itself
      // anymore -- found by review (round omabackup-25), same reasoning
      // as accumulateCapped's own comment above: killGroup() is a
      // separate, still-starting Process, and directly terminating the
      // leader here too could win the race and reap it before the
      // helper's own PGID lookup runs, orphaning the very descendant
      // this exists to catch. killGroup()'s own eventual TERM reaches
      // the leader too (it is a member of its own group), and QuickShell
      // still detects the real exit and fires onExited whoever signaled
      // it -- busy stays true for exactly as long as the OS process
      // genuinely is, not until this handler decided to say otherwise.
      // killGroup() now also arms its own backstop timer (see its own
      // comment) for the case where its helper Process never manages to
      // signal anything at all.
      if (verifyProc.running) {
        verifyProc.timedOut = true
        root.killGroup(verifyProc)
      }
      if (statusProc.running) {
        statusProc.timedOut = true
        root.killGroup(statusProc)
      }
      if (syncProc.running) {
        syncProc.timedOut = true
        root.lastError = "sync timed out after " + Math.round(root.busyTimeoutMs / 1000) + "s"
        root.killGroup(syncProc)
      }
      if (collectProc.running) {
        collectProc.timedOut = true
        root.lastError = "collect timed out after " + Math.round(root.busyTimeoutMs / 1000) + "s"
        root.killGroup(collectProc)
      }
      if (switchProc.running) {
        switchProc.timedOut = true
        root.lastError = "enable/disable timed out after " + Math.round(root.busyTimeoutMs / 1000) + "s"
        root.killGroup(switchProc)
      }
    }
  }

  Process {
    id: resolveProc
    running: true
    command: ["sh", "-c",
      "command -v omabackup 2>/dev/null || { [ -x \"$1\" ] && printf %s \"$1\"; }", "--", root.fallbackCli]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text).trim()
        if (path === "") { root.cliMissing = true; return }
        root.cli = path
        root.refresh()
      }
    }
    onExited: function(code) { if (root.cli === "") root.cliMissing = true }
  }

  // resolveProc runs once, at startup, before root.cli exists -- so it is
  // deliberately NOT covered by busyTimeoutTimer, which every one of its
  // restarts (refresh/syncNow/collect/setEnabled) itself refuses to run
  // until root.cli is non-empty. A review round found the failure mode this
  // leaves open is worse than silence: a hung resolveProc leaves root.cli
  // "" and root.cliMissing false (that only gets set in onStreamFinished or
  // onExited, neither of which a hung process ever reaches) -- so `visible:
  // !root.cliMissing` shows the widget, `headline` reads as though nothing
  // were wrong, and every control stays inert forever with no error anyone
  // can see. This is what invariant #1's own "not configured", never a
  // silent husk, is supposed to prevent. A short one-shot timer, unrelated
  // to the shared one: if resolution has not finished by the time it fires,
  // something is installed and simply did not answer -- resolveTimedOut
  // marks that distinctly from a clean "not installed" (see its own
  // declaration above), so `visible`/`headline` can still say "check
  // failed" instead of the widget disappearing with the same silence a
  // hang was supposed to stop causing.
  Timer {
    interval: Math.max(5, root.setting("resolveTimeoutSec", 10)) * 1000
    running: true
    repeat: false
    onTriggered: {
      if (root.cli === "" && !root.cliMissing) {
        if (resolveProc.running) resolveProc.running = false
        root.resolveTimedOut = true
        root.cliMissing = true
      }
    }
  }

  Process {
    id: verifyProc
    property string buffer: ""
    property string errBuffer: ""
    property bool timedOut: false
    property bool outputCapped: false
    // setsid: see root.killGroup()'s own comment -- makes this process its
    // own group leader, so a timeout can reach a git/rsync child too.
    command: root.cli === "" ? ["true"] : ["setsid", "--", root.cli, "verify", "--json"]
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(verifyProc, "buffer", data) } }
    stderr: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(verifyProc, "errBuffer", data) } }
    // verify exits non-zero when coverage fails, which is a result, not an
    // error. Only an empty document -- the CLI itself never answered -- means
    // the run went wrong, and now says what it printed to stderr rather than
    // a bare "no output" that swallowed the actual reason. The timedOut
    // branch returns before any of that: the timer already set the message
    // this run's actual outcome would otherwise immediately overwrite.
    // outputCapped is checked FIRST, ahead of timedOut -- found by review
    // (round omabackup-25): `running` does not update synchronously (this
    // file's own busyTimeoutTimer comment already measured that, headless,
    // for the exited signal), so accumulateCapped setting `running = false`
    // does not stop busyTimeoutTimer's own `if (verifyProc.running)` guard
    // from still reading true in that narrow window, setting timedOut too.
    // The kill that follows is harmless either way (a second kill-group
    // against an already-dead group is a no-op), but checking timedOut
    // first would report "verify timed out after Ns" for a run that
    // actually failed because its output exceeded the panel's own limit --
    // losing exactly the distinction this flag exists to preserve. A
    // truncated buffer is not valid JSON either way, so root.applyReport
    // must never see one. Reset on every run's exit, same as timedOut, so
    // a later normal run is not permanently shown as capped.
    onExited: function(code) {
      root.checking = false
      if (verifyProc.outputCapped) {
        verifyProc.outputCapped = false
        verifyProc.timedOut = false
        root.lastError = "verify: output exceeded the panel's limit"
        return
      }
      if (verifyProc.timedOut) { verifyProc.timedOut = false; return }
      if (verifyProc.buffer.trim() === "") {
        root.lastError = "verify: " + (verifyProc.errBuffer.trim() || ("no output, exit " + code))
      } else {
        root.applyReport(verifyProc.buffer)
      }
    }
  }

  Process {
    id: statusProc
    property string buffer: ""
    property string errBuffer: ""
    property bool timedOut: false
    property bool outputCapped: false
    // setsid: see verifyProc/root.killGroup() above.
    command: root.cli === "" ? ["true"] : ["setsid", "--", root.cli, "status", "--json"]
    stdout: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(statusProc, "buffer", data) } }
    stderr: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(statusProc, "errBuffer", data) } }
    // An empty buffer used to be silently ignored: the PREVIOUS statusDoc
    // stayed exactly where it was, rendered as though it were current, with
    // no sign the query itself had just failed. The stale document is still
    // the most useful thing to show while this is broken, so it is kept --
    // but now root.lastError says the refresh itself did not happen, the
    // same distinction verify already draws between "checked and clean" and
    // "did not manage to check".
    //
    // A review round found this only checked whether stdout was non-empty,
    // never `code` -- a process that printed a stale-but-parseable document
    // and THEN exited non-zero was accepted as a good status read. Checked
    // now, the same way the failure branch already is. outputCapped is
    // checked FIRST, same reasoning as verifyProc (see its own onExited
    // comment): `running` does not update synchronously, so a narrow
    // window can leave both flags set, and checking timedOut first would
    // report the wrong reason for a run that actually failed on output
    // size. A truncated buffer is not valid JSON either way, so it must
    // never reach applyStatus.
    onExited: function(code) {
      if (statusProc.outputCapped) {
        statusProc.outputCapped = false
        statusProc.timedOut = false
        root.lastError = "status: output exceeded the panel's limit"
        return
      }
      if (statusProc.timedOut) { statusProc.timedOut = false; return }
      if (statusProc.buffer.trim() !== "" && code === 0) {
        root.applyStatus(statusProc.buffer)
      } else {
        root.lastError = "status: " + (statusProc.errBuffer.trim() ||
          (statusProc.buffer.trim() === "" ? ("no output, exit " + code) : ("failed, exit " + code)))
      }
    }
  }

  Process {
    id: switchProc
    property string errBuffer: ""
    property bool timedOut: false
    property bool outputCapped: false
    command: ["true"]
    stderr: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(switchProc, "errBuffer", data) } }
    // outputCapped checked before timedOut -- same reasoning as verifyProc/
    // statusProc's own onExited (see their comments): `running` does not
    // update synchronously, so both flags can end up set for one run, and
    // checking timedOut first would report the wrong reason.
    onExited: function(code) {
      root.switching = false
      if (switchProc.outputCapped) {
        switchProc.outputCapped = false
        switchProc.timedOut = false
        root.lastError = "enable/disable: output exceeded the panel's limit"
        root.refresh(true)
        return
      }
      if (switchProc.timedOut) { switchProc.timedOut = false; root.refresh(true); return }
      if (code !== 0) {
        root.lastError = "enable/disable: " + (switchProc.errBuffer.trim() || ("failed, exit " + code))
        root.refresh(true)
      } else {
        root.refresh(false)
      }
    }
  }

  Process {
    id: syncProc
    property string errBuffer: ""
    property bool timedOut: false
    property bool outputCapped: false
    // setsid: see verifyProc/root.killGroup() above.
    command: root.cli === "" ? ["true"] : ["setsid", "--", root.cli, "sync", "--commit"]
    stderr: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(syncProc, "errBuffer", data) } }
    // The exit code used to be thrown away entirely -- a sync that failed and
    // one that worked produced the exact same UI sequence (syncing -> false,
    // refresh). The refresh alone did not compensate: the next verify checks
    // COVERAGE, not whether the commit this button asked for actually landed,
    // so a push that failed for its own reason (a git error, a hook, a lock)
    // said nothing was wrong. A review round then caught the refresh() call
    // itself erasing that same message a line later (refresh() used to clear
    // lastError unconditionally) -- keepError=true on the failure path is
    // what stops that. outputCapped checked before timedOut -- see
    // verifyProc's own onExited comment for why.
    onExited: function(code) {
      root.syncing = false
      if (syncProc.outputCapped) {
        syncProc.outputCapped = false
        syncProc.timedOut = false
        root.lastError = "sync: output exceeded the panel's limit"
        root.refresh(true)
        return
      }
      if (syncProc.timedOut) { syncProc.timedOut = false; root.refresh(true); return }
      if (code !== 0) {
        root.lastError = "sync: " + (syncProc.errBuffer.trim() || ("failed, exit " + code))
        root.refresh(true)
      } else {
        root.refresh(false)
      }
    }
  }

  Process {
    id: collectProc
    property string errBuffer: ""
    property bool timedOut: false
    property bool outputCapped: false
    // setsid: see verifyProc/root.killGroup() above.
    command: root.cli === "" ? ["true"] : ["setsid", "--", root.cli, "collect", "--json"]
    stderr: SplitParser { splitMarker: ""; onRead: function(data) { root.accumulateCapped(collectProc, "errBuffer", data) } }
    // outputCapped checked before timedOut -- see verifyProc's own
    // onExited comment for why.
    onExited: function(code) {
      if (collectProc.outputCapped) {
        collectProc.outputCapped = false
        collectProc.timedOut = false
        root.lastError = "collect: output exceeded the panel's limit"
        root.refresh(true)
        return
      }
      if (collectProc.timedOut) { collectProc.timedOut = false; root.refresh(true); return }
      if (code !== 0) {
        root.lastError = "collect: " + (collectProc.errBuffer.trim() || ("failed, exit " + code))
        root.refresh(true)
      } else {
        root.refresh(false)
      }
    }
  }

  Timer {
    id: settingsRevealTimer
    interval: 50
    repeat: false
    onTriggered: {
      if (root.configExpanded && flick.contentHeight > flick.height)
        flick.contentY = flick.contentHeight - flick.height
    }
  }

  Timer {
    id: externalLaunchTimer
    interval: 180
    repeat: false
    onTriggered: {
      if (root.externalAction === "") return
      externalProc.errBuffer = ""
      // Captured here, not re-read from root.externalAction/externalToken
      // inside onExited below -- found in review (round omabackup-30,
      // `omabackup-rev`): those two root properties are the CURRENT
      // session's mutable state, not this specific launch's own identity.
      // canOpenExternalTui already refuses a second openExternalTui() while
      // externalBusy is set, so no caller can reach this today with a
      // different session already active -- but a callback that reads
      // mutable shared state instead of its own captured identity is a
      // latent bug waiting for the NEXT caller who doesn't realize that
      // gating is load-bearing here. Capturing at launch time removes the
      // dependency on that invariant entirely.
      externalProc.launchAction = root.externalAction
      externalProc.launchToken = root.externalToken
      externalProc.command = ["omarchy-launch-tui",
                              "--app-id=org.omarchy.omabackup-" + root.externalAction,
                              root.tuiCli, root.cli, root.externalAction, root.externalToken]
      externalProc.running = true
    }
  }

  // Prefixes `timeout` OUTSIDE Util.execArgv's own login shell, not inside
  // it -- Util.execArgv's real implementation is
  // `Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash"].concat(argv))`
  // (`/usr/share/omarchy/shell/Commons/Util.qml`, confirmed by direct
  // read): whatever `argv` is only starts running AFTER `bash -lc` has
  // already sourced the user's login profile. Passing `timeout` as part of
  // that `argv` (this file's first attempt, found wrong in review, round
  // omabackup-30, `omabackup-rev`) bounds only the exec after the profile
  // finishes -- a hung profile itself is never bounded at all. Building the
  // full argv here and driving `Quickshell.execDetached` directly, with
  // `timeout` as the true outermost element, bounds the profile-sourcing
  // too. Still injection-safe: every value stays a literal argv element
  // through `"$@"`, never interpolated into the `bash -lc` string itself
  // (that string is the fixed constant `'exec "$@"'`, unchanged from
  // Util.execArgv's own).
  function logEventDetached(argv) {
    Quickshell.execDetached(["timeout", "--kill-after=2s", "10s",
                              "bash", "-lc", 'exec "$@"', "bash"].concat(argv))
  }

  Process {
    id: externalProc
    property string errBuffer: ""
    property string launchAction: ""
    property string launchToken: ""
    command: ["true"]
    stderr: StdioCollector { onStreamFinished: externalProc.errBuffer = text }
    onExited: function(code) {
      // Stale-callback guard, ahead of everything else in this handler --
      // found in review (round omabackup-30, `omabackup-rev`): the launch
      // and token this specific exit belongs to are `launchAction`/
      // `launchToken`, captured once at launch time, NOT whatever
      // root.externalAction/root.externalToken currently hold. If they no
      // longer match the session this Process object is CURRENTLY tracking,
      // this callback is for a launch attempt the panel has already moved
      // on from -- clearing state, setting lastError, or logging on its
      // behalf would attribute this outcome to whatever session root's
      // fields now describe instead.
      if (externalProc.launchAction === "" || externalProc.launchAction !== root.externalAction
          || externalProc.launchToken !== root.externalToken) return
      var action = externalProc.launchAction
      var token = externalProc.launchToken
      if (code !== 0) {
        externalRecoveryTimer.stop()
        root.externalAction = ""
        root.externalToken = ""
        root.externalBusy = false
        root.configuring = false
        root.lastError = action + ": " + (externalProc.errBuffer.trim() || ("exit " + code))
        root.refresh(true)
        // The wrapper never started -- there is no bin/omabackup-tui process
        // to log this session's outcome for itself, so the panel is the only
        // thing that ever will. Best-effort, fire-and-forget: recover the UI
        // first (above), dispatch the log line second, so a synchronous
        // throw from execArgv can never leave the panel stuck. `action`
        // guarded separately from `root.cli`, not folded into one check --
        // found in design consultation (herdr-ask, round omabackup-12) that
        // this branch, unlike externalRecoveryTimer's own onTriggered, has
        // no existing empty-action guard, which would reopen the blank-
        // action log line already fixed elsewhere (round omabackup-23).
        // `action` cannot be empty here regardless (the stale-callback
        // guard above already refused an empty launchAction), kept anyway
        // as a direct, self-contained condition rather than relying on
        // that guard's own reasoning holding forever.
        if (root.cli !== "" && action !== "") {
          // errBuffer is an unbounded StdioCollector (see its own
          // declaration above) -- truncate before it becomes an argv
          // element and strip embedded NULs, so an oversized or NUL-
          // containing stderr blob cannot silently fail the very call
          // meant to explain the failure (E2BIG or a truncated C string).
          // NUL-stripped BEFORE truncating, so the 2000-char budget counts
          // surviving characters, not ones about to be discarded anyway.
          var errText = externalProc.errBuffer.trim().replace(/\x00/g, "")
          if (errText.length > 2000) errText = errText.slice(0, 2000) + " …(truncated)"
          // The exit code must survive even when stderr is present -- keep
          // both, not the `errBuffer || ("exit " + code)` shape used for
          // lastError above, which silently drops the code whenever stderr
          // is non-empty.
          try {
            root.logEventDetached([root.cli, "log-event",
                            action + " (interactive)", "failed (launch)",
                            "exit " + code + (errText ? "; stderr=" + errText : "") +
                            " (token " + token + ")"])
          } catch (e) {}
        }
      }
      else if (action !== "") {
        externalRecoveryTimer.restart()
      }
    }
  }

  Timer {
    id: externalRecoveryTimer
    interval: root.externalRecoveryMs
    repeat: false
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
      // Same reasoning as externalProc's own log-event call above: the
      // wrapper may still be alive but unreachable, so this is the only
      // record of the panel giving up. Deliberately NOT deduplicated
      // against a possible later, real log-event call from the wrapper
      // itself (if it eventually recovers and exits normally) -- design
      // consultation (herdr-ask, round omabackup-12) settled this as two
      // different true facts worth keeping, not a duplicate to suppress:
      // "the panel stopped waiting" and "the wrapper finished, and how"
      // together reveal a slow-not-dead wrapper that a single line
      // couldn't distinguish. The shared token (also in the wrapper's own
      // _on_exit log-event calls, bin/omabackup-tui:190,192) is what lets
      // a reader connect the two lines for the same session -- both
      // reviewers independently found this comment's claim was false on
      // the wrapper's side at the time it was written (round omabackup-30);
      // bin/omabackup-tui's own two log-event calls now include the token
      // too, so this correlation is real, not aspirational.
      //
      // `token` read directly from root.externalToken (not captured at an
      // earlier point the way externalProc's launchAction/launchToken are)
      // -- safe here because this Timer's own onTriggered firing IS this
      // specific session's own event: openExternalTui assigns
      // externalToken before externalAction, so a non-empty action (the
      // guard above) already implies a non-empty token, and every path
      // that resolves a session before this timer fires also calls this
      // timer's own .stop() (finishExternalTui, externalProc's
      // launch-failure branch) -- unlike a spawned OS process's onExited,
      // which cannot be un-fired once the process has already exited, so
      // externalProc needs its own captured-identity guard and this timer
      // does not.
      if (root.cli !== "")
        try {
          root.logEventDetached([root.cli, "log-event",
                          action + " (interactive)", "failed (no heartbeat)",
                          "gave up after " + Math.round(root.externalRecoveryMs / 1000) +
                          "s with no heartbeat or completion callback (token " + token + ")"])
        } catch (e) {}
    }
  }

  Timer {
    interval: Math.max(60, root.setting("refreshIntervalSec", 900)) * 1000
    running: root.cli !== ""
    repeat: true
    // keepError=true: a review round caught this call as the one place
    // keepError's own fix (an operation's error surviving ITS OWN trailing
    // refresh) still lost the battle -- this periodic tick calls refresh()
    // with no argument, which defaults keepError to falsy and clears
    // lastError same as before. And unlike verify/status, which rederive
    // their own error on every tick regardless, an operation error (sync,
    // collect, enable/disable) is never rediscovered by a plain check --
    // verify only reads COVERAGE, not "did the last push actually land." A
    // sync that failed and one that worked went back to looking identical
    // after one interval instead of one line, the same defect this whole
    // slice exists to fix. This is not a user asking "forget what happened"
    // -- unlike the explicit "Check again" call sites, which do pass the
    // default (false) on purpose, because that IS the user asking for a
    // clean slate.
    onTriggered: root.refresh(true)
  }

  Timer {
    id: versionCopiedTimer
    interval: 1800
    repeat: false
    onTriggered: root.versionCopied = false
  }

  IpcHandler {
    target: "brenoperucchi.omabackup"
    function refresh(): void { root.refresh() }
    function collect(): void { root.collect() }
    function toggle(): void { root.toggle() }
    function tuiFinished(action: string): string { return root.finishExternalTui(action) }
    function tuiHeartbeat(token: string): string { return root.heartbeatExternalTui(token) }
    function status(): string {
      return JSON.stringify({ covered: root.covered, fail: root.failCount,
                              warn: root.warnCount, headline: root.headline })
    }
  }

  // ── the bar ──────────────────────────────────────────────────────────────
  // Always visible now -- a product decision, made explicitly by the
  // operator after a review round flagged the conflict this used to have
  // with the stated invariant ("the widget shows 'not configured', never a
  // silent hide"). The previous version hid the widget entirely while the
  // CLI was absent, on the reasoning that a backup plugin nagging about not
  // being installed is worse than one waiting quietly -- true, but
  // `visible: false` also hid the ALREADY-CORRECT "not configured" headline
  // text, so the invariant's own promised behaviour was unreachable. The
  // operator chose literal compliance: always show the icon, dimmed, with
  // whatever headline is true (including "not configured"), over a widget
  // that can vanish with no visible explanation.
  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // fa-exclamation-triangle when something needs doing, Material Design
    // Icons' md-sync otherwise -- two circling arrows for the actual cycle
    // this tool runs (collect -> publish -> verify -> commit), not the
    // generic fa-save floppy disk this used to be. Picked from a different
    // icon family than either other Omarchy backup plugin: Time Machine
    // (restic) uses Font Awesome's fa-history, OmaVault uses Material
    // Design's own md-safe. Codepoints for candidate glyphs (fa-layer-group,
    // fa-code-commit, fa-shield-halved -- all FA5+ solid icons above
    // roughly U+F2FF) were checked with fontTools'
    // getBestCmap()/getGlyphOrder() against the actual installed
    // JetBrainsMono Nerd Font .ttf (resolved via `fc-match monospace`, which
    // is what the bar's font actually renders through) before settling
    // here, after fa-layer-group (U+F5FD) rendered as a blank box -- that
    // build only carries the classic Font Awesome block. md-sync is
    // U+F04E6, above the Basic Multilingual Plane, so it needs the `\u{...}`
    // code point escape rather than `\uXXXX`.
    text: root.failCount > 0 ? "\uf071" : "\u{F04E6}"
    // WidgetButton colours through `foreground`, and `active` swaps in
    // `activeColor` (the theme's urgent). No green anywhere: a healthy backup
    // is dimmed, not celebrated -- but `dimmed: true` alone hands the exact
    // opacity to WidgetButton's own fixed 0.45, which is calm on an opaque
    // dark bar and unreadable everywhere else: nearly black on a dark theme,
    // barely there at all against a transparent one (confirmed live: the
    // user's own bar is transparent). Overriding opacity directly, instead
    // of setting `dimmed`, keeps the "quiet when healthy" intent at a level
    // that is still legible against both.
    foreground: root.warnCount > 0 ? Color.accent : root.barText
    active: root.failCount > 0
    opacity: root.covered ? 0.75 : 1.0
    slotSize: Style.bar.statusSlot
    // Style.font.caption (10px) inside a 21px statusSlot, on a 26px bar --
    // most of the available space was going unused, compounding the
    // legibility problem opacity alone did not explain. Style.font.heading
    // (not the iconLarge token, 18px) defaults to the same 16px but scales
    // with the shell's own fontBaseSize -- a literal 16 would stay fixed
    // while Style.bar.statusSlot grows under it, recreating the exact
    // too-small-for-its-slot problem this line exists to fix.
    fontSize: Style.font.heading
    tooltipText: "OmaBackup - " + root.headline
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Sized against omarchy's own info panel, which is the house reference for
    // a panel with this much to say: it uses 430 wide and 560 tall. A little
    // wider here because the group list runs in two columns.
    //
    // Height raised from that 560 reference to 700 -- still within the same
    // family other real Omarchy panels use (most cap at 560, the `agents`
    // plugin's own panel already caps at 640) -- after a real screenshot
    // showed "Recent activity" defaulting open pushed the Flickable below
    // into a scroll that did not exist before that section was promoted
    // near the top. `fittedContentHeight` still clamps to the available
    // screen space first, so this only matters when the screen has the room
    // to give; it does not force the panel taller than it needs to be.
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(
      column.implicitHeight + footerBar.height,
      Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "c" || t === "C") root.collect()
      }

      Flickable {
        id: flick
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footerBar.top
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(10)

          // The header the mockup opens with: who this is, then the state, then
          // one line summarising the machine. Without the name the panel drops
          // you straight into a verdict with nothing saying whose verdict it is.
          Item {
            width: parent.width
            implicitHeight: headRow.implicitHeight

            // Review round omabackup-38 found the anchored Omarchy Text below
            // protects itself, but not headRow -- headRow itself still has no
            // fixed width, and the version Button living inside it is now its
            // rightmost child, so under a wide enough font-token override
            // headRow's OWN content (not just the trailing text) could reach
            // the toggle. Wrapping the whole left-hand group in one clipped,
            // bounded Item closes that: the common case still elides the
            // Omarchy text gracefully (unchanged), and the pathological case
            // (headRow itself too wide) degrades to an abrupt clip instead of
            // visually overlapping the toggle -- the toggle is declared after
            // this Item, so it always paints on top and stays clickable
            // either way, but this keeps the panel from drawing over its own
            // content, not just over the one control that matters.
            Item {
              id: titleGroup
              anchors.left: parent.left
              anchors.right: toggleSwitch.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              height: headRow.implicitHeight
              clip: true

              Row {
                id: headRow
                spacing: Style.space(6)
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter

                // One glance, one colour. Omarchy's palette has no green on
                // purpose and neither does this: "fine" is muted ink rather
                // than a reassuring tick, so colour here always means work
                // to do.
                Rectangle {
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.failCount > 0 ? Color.urgent
                       : (!root.scheduled || root.stale || root.destAlerts.length > 0) ? Color.accent
                       : root.warnCount > 0 ? Color.accent
                       : Color.muted
                }

                Text {
                  text: "OmaBackup"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                }

                // The version button used to sit in its own row further
                // down, in body-sized text. Relocated here alongside the
                // title; sized down to caption on purpose (it was never
                // caption before), not a reuse -- see docs/PLAN.md's own
                // note on this. qs.Ui.Button exposes `fontFamily`/`fontSize`
                // (it is a BorderSurface/Rectangle, not Text -- no grouped
                // `font` property exists on it), not `font.family`/
                // `font.pixelSize` -- review round omabackup-38 caught this
                // as an invalid property assignment that would have
                // silently failed to apply.
                Button {
                  id: versionButton
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.versionCopied ? root.toolVersion + "  ✓ copied" : root.toolVersion
                  bordered: false
                  focusable: true
                  // Pre-existing gap, caught by review round omabackup-38
                  // while this button was already being touched: "?" is not
                  // the only failure value in play. _tool_version()
                  // (bin/omabackup) falls back to the literal string
                  // "unknown" when the manifest can't be read -- a real
                  // string, so it never hits Panel.qml's "?" fallback
                  // (root.toolVersion === "?" only fires when the whole
                  // `tool` object is missing from the status document, not
                  // when its version field says "unknown"). Guard against
                  // both so this button doesn't stay clickable-and-copyable
                  // for a value that was never a real version.
                  enabled: root.toolVersion !== "?" && root.toolVersion !== "unknown"
                  foreground: root.versionCopied ? Color.foreground : Color.accent
                  fontFamily: Style.font.family
                  fontSize: Style.font.caption
                  onClicked: root.copyToolVersion()
                }
              }

              // Anchored between headRow's own right edge and this group's
              // own right edge, rather than folded into headRow's Row
              // layout, so it gets a real bounded width and elides instead
              // of ever growing further -- the same protection the
              // runtime-identity row this replaced already had (width:
              // parent.width - versionButton.width - ...), just expressed
              // with anchors since headRow itself has no fixed width to
              // subtract from.
              Text {
                anchors.left: headRow.right
                anchors.leftMargin: Style.space(6)
                anchors.right: parent.right
                anchors.verticalCenter: headRow.verticalCenter
                text: "·  Omarchy " + root.omarchyVersion
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            // The one control on this panel that actually sets something.
            //
            // anchors.verticalCenter: titleGroup.verticalCenter, not
            // headRow.verticalCenter -- QML anchors only resolve against a
            // parent or a true sibling, and headRow stopped being
            // toggleSwitch's sibling once it moved inside titleGroup.
            // Review round omabackup-39 caught the stale reference: it
            // silently failed at runtime ("Cannot anchor to an item that
            // isn't a parent or sibling"), leaving the toggle at its
            // default vertical position instead of centered. titleGroup's
            // own height equals headRow's implicitHeight and is itself
            // centered in this Item, so titleGroup.verticalCenter and
            // headRow.verticalCenter are the same Y coordinate -- this is
            // the valid way to express the same intent.
            ToggleSwitch {
              id: toggleSwitch
              anchors.right: parent.right
              anchors.verticalCenter: titleGroup.verticalCenter
              checked: root.scheduled
              busy: root.switching
              interactive: root.cli !== "" && !root.cliMissing && !root.busy
              onToggled: root.setEnabled(!root.scheduled)
            }
          }

          // Promoted from a dimmed caption to the panel's own second line of
          // weight: this is the answer to the question opening the panel
          // exists to answer ("is the backup good, and since when"), and it
          // used to sit between the header and the buttons at the same
          // visual rank as version/migration trivia below it. bodySmall, not
          // caption; full foreground, not 0.62 opacity.
          //
          // Always visible now, not gated on statusDoc -- a review round
          // caught the entire promoted block (this line, plus the two
          // alerts right below) disappearing together exactly in the case
          // promoting them was meant to help: a CLI that resolves but whose
          // very first status --json fails (empty output, non-zero exit, or
          // a document that no longer passes the shape checks this same
          // slice tightened). At startup there is no previous statusDoc to
          // fall back on, so the whole block vanished and the only sign
          // anything was wrong was root.lastError, buried after the finding
          // list further down. headline alone already covers "check failed"
          // and "not checked yet" without needing statusDoc; only
          // summaryLine (groups/files counts) actually depends on it, so
          // that part alone is omitted when there is nothing to summarise.
          Text {
            width: parent.width
            text: root.statusDoc !== null ? (root.headline + "  ·  " + root.summaryLine) : root.headline
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          // The two alerts that most need a human moved up from the bottom
          // of a scrollable column, where a panel opened for a quick glance
          // might never reach them, to right under the verdict they qualify.
          // A stale backup or a machine with nothing scheduled make every
          // number below this point -- groups, destinations, config -- a
          // description of a system that has since moved on; they rank
          // above the routine action buttons for that reason.
          Text {
            visible: root.stale
            width: parent.width
            text: "!  " + root.staleText
                  + (root.neverSynced ? "\nRun  omabackup sync --commit  to start."
                                      : "\nCheck  systemctl --user status omabackup-sync")
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.schedulerKnown && !root.scheduled
            width: parent.width
            text: "!  Nothing is scheduled to run the backup.\n"
                  + "Run  omabackup install  to start the timers."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Item {
            width: parent.width
            implicitHeight: primaryActions.implicitHeight

            Row {
              id: primaryActions
              anchors.left: parent.left
              spacing: Style.space(6)

              Button {
                text: root.syncing ? "backing up…" : "Back up now"
                bordered: true
                focusable: true
                enabled: root.cli !== "" && !root.cliMissing && !root.busy
                onClicked: root.syncNow()
              }
              Button {
                text: "Check again"
                bordered: true
                focusable: true
                enabled: root.cli !== "" && !root.cliMissing && !root.checking && !root.busy
                onClicked: root.refresh()
              }
            }

            // github is the implicit destination derived from OMABACKUP_REPO's
            // own `origin` remote (DESIGN.md §3), so it earns a spot next to
            // the primary actions instead of the generic Destinations chips
            // below, which are now only about `dir` destinations. Clicking it
            // opens the local repository it pushes from -- "where the files
            // were saved" -- not github.com itself, since that is a network
            // trip a quiet status button should not silently start.
            Button {
              visible: root.githubDestination !== null
              anchors.right: parent.right
              text: "GitHub"
              bordered: true
              focusable: true
              selected: root.githubDestination
                        ? (root.githubDestination.lastSuccess !== "" && !root.githubDestination.failed)
                        : false
              foreground: root.githubDestination && root.githubDestination.failed ? Color.urgent
                        : root.githubDestination && root.githubDestination.lastSuccess !== "" ? Color.foreground
                        : Color.accent
              enabled: root.config && root.config.repo
              tooltipText: root.githubDestination
                  ? (root.githubDestination.failed ? root.githubDestination.errorMessage
                     : root.githubDestination.lastSuccess !== ""
                       ? "sent " + root.agoFromIso(root.githubDestination.lastSuccess) : "never sent")
                  : ""
              onClicked: root.openRepoInFileManager()
            }
          }

          // ── recent activity, expanded by default ──────────────────────────
          // Relocated here (was near the bottom, past Groups/Destinations/
          // Current settings) and defaulted to open: this is now the panel's
          // only source of the GitHub destination's status text once a mouse
          // is not available (see docs/PLAN.md's writeup on this round for
          // why). Same Item + header + "+"/"-" Text + full-Item MouseArea
          // shape as "Current settings" below; no Behavior on height anywhere
          // in this file, so this section does not invent that pattern only
          // for itself -- the enclosing Flickable's own relayout is what
          // makes expansion visible. Content is a flat list of lines (the
          // Verification alerts Repeater's own shape), not a 2-column Grid --
          // log lines are not key/value pairs. Fed by statusDoc.recentLog,
          // already fetched on every status poll this panel already makes --
          // no second Process/onExited block needed for this section alone.
          Item {
            width: parent.width
            implicitHeight: aHdr.implicitHeight + Style.space(5)
            PanelSectionHeader { id: aHdr; anchors.left: parent.left; text: "Recent activity" }
            Text {
              anchors.left: aHdr.right
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: aHdr.verticalCenter
              text: root.activityExpanded ? "-" : "+"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            PanelSeparator { anchors.bottom: parent.bottom; width: parent.width }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleActivity()
            }
          }

          Column {
            id: activityList
            visible: root.activityExpanded
            width: column.width
            spacing: Style.space(2)

            // Live status, not a log line: same GitHub text the panel used
            // to show as its own standalone row (removed round omabackup-37,
            // relocated here this round). Colour follows this column's own
            // existing convention -- Color.muted/Color.urgent already mark
            // "Could not read the log."/the empty placeholder below as
            // meta/status rather than log content, so this fits the same
            // register without a new sub-label or divider.
            Text {
              visible: root.activityExpanded && root.githubDestination !== null
              width: activityList.width
              text: "GitHub " + (root.githubDestination && root.githubDestination.failed
                      ? root.githubDestination.errorMessage
                      : root.githubDestination && root.githubDestination.lastSuccess !== ""
                        ? "sent " + root.agoFromIso(root.githubDestination.lastSuccess) : "never sent")
              color: root.githubDestination && root.githubDestination.failed ? Color.urgent : Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            // Model gated on activityExpanded too, not just this Column's
            // own visibility -- an empty-when-collapsed model keeps the
            // Repeater from instantiating delegates for content nobody can
            // see, the same "invisible still occupies nothing" reasoning
            // this file's own collapsed-Grid test already established for
            // cfgGrid above.
            Repeater {
              model: root.activityExpanded && root.statusDoc && Array.isArray(root.statusDoc.recentLog)
                ? root.statusDoc.recentLog : []
              Text {
                required property var modelData
                width: activityList.width
                text: modelData
                color: Color.foreground
                opacity: 0.7
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            // Distinguished from "no activity logged yet" -- added round
            // omabackup-35, alongside making the underlying day-file read
            // failure a real, reported condition in cmd_status
            // (recentLogError) instead of one silently indistinguishable
            // from an empty log. Checked ahead of the plain-empty message
            // below, since an unreadable log is never ALSO genuinely
            // empty in a way worth saying so about.
            Text {
              visible: root.activityExpanded && root.statusDoc && root.statusDoc.recentLogError === true
              width: activityList.width
              text: "Could not read the log."
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            // "No activity logged yet.", not "Nothing logged yet." -- the
            // GitHub status line above is not itself a log entry, and stays
            // true even while it is visible (a configured GitHub
            // destination with a genuinely empty command log is the normal
            // first-run state, not an exotic one).
            Text {
              visible: root.activityExpanded &&
                !(root.statusDoc && root.statusDoc.recentLogError === true) &&
                !(root.statusDoc && Array.isArray(root.statusDoc.recentLog) && root.statusDoc.recentLog.length > 0)
              width: activityList.width
              text: "No activity logged yet."
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSectionHeader {
            visible: root.alerts.length > 0
            text: "Verification"
          }

          Repeater {
            model: root.alerts
            Column {
              required property var modelData
              width: column.width
              spacing: Style.space(1)

              Text {
                width: parent.width
                text: (modelData.level === "fail" ? "✗  " : "!  ") + (modelData.group || "")
                color: modelData.level === "fail" ? Color.urgent : Color.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width
                text: modelData.message || ""
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          Text {
            visible: root.lastError !== ""
            width: parent.width
            text: root.lastError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ── what is saved ─────────────────────────────────────────────────
          // The question the interface could not answer: you had to open
          // groups.default.json to find out what this tool actually keeps.
          // The section rule sits UNDER the header, not above it: it belongs to
          // the header as an underline rather than floating between sections.
          // Visible when there is something to show OR when there has never
          // been an answer at all (report === null): a review round pointed
          // out that a `visible:` gated purely on data length does not
          // communicate "could not check" -- it erases the section, which is
          // the quietest possible way of saying nothing. groups.length === 0
          // with a non-null report (a real manifest that genuinely declares
          // no groups) stays hidden; that is a fact, not an unknown.
          Item {
            visible: root.groups.length > 0 || root.report === null
            width: parent.width
            implicitHeight: gHdr.implicitHeight + Style.space(5)
            PanelSectionHeader { id: gHdr; anchors.left: parent.left; text: "Groups" }
            Text {
              anchors.right: parent.right
              anchors.verticalCenter: gHdr.verticalCenter
              visible: root.coveredFiles > 0
              text: root.coveredFiles + " files  ·  " + root.humanSize(root.coveredBytes)
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            PanelSeparator { anchors.bottom: parent.bottom; width: parent.width }
          }

          // Two columns: eleven groups in one made the panel a scroll with
          // nothing else visible at once, which defeats a panel whose job is
          // showing several answers side by side.
          Grid {
            id: groupGrid
            width: column.width
            columns: 2
            columnSpacing: Style.space(14)
            rowSpacing: Style.space(3)
            readonly property real cellWidth: (width - columnSpacing) / 2

            Repeater {
              model: root.groups
              Row {
                id: groupRow
                required property var modelData
                width: groupGrid.cellWidth
                spacing: Style.space(7)

                // A tooltip naming what the group actually covers: its
                // declared paths, joined onto one line -- or, for a mode:gen
                // group (Packages, Services), which has no `paths` at all,
                // the generator command that stands in for them. Without
                // this fallback the two gen-mode groups showed no tooltip at
                // all, which a user noticed immediately.
                //
                // A plain HoverHandler + a real `ToolTip { }` instance, not
                // the attached-property form: the attached form styles
                // through whatever the global QQC2 style provides, and the
                // operator asked for a specific rounded-pill look this
                // project's own tokens can match instead. Both are safe as
                // direct children of a Row (a Positioner) -- HoverHandler is
                // a pointer handler, not a positioned Item, and ToolTip is a
                // Popup, which Row never tries to lay out either; confirmed
                // headless, no "Row will not function" warning either way.
                // A plain MouseArea/Item child with anchors.fill here WOULD
                // hit that restriction -- the same one a review round found
                // and fixed once already, in the artifact list.
                HoverHandler { id: groupHover }
                readonly property string tooltipText:
                  (groupRow.modelData.paths && groupRow.modelData.paths.length > 0)
                    ? groupRow.modelData.paths.join("  ·  ")
                    : (groupRow.modelData.generator ? root.generatorDescription(groupRow.modelData.generator) : "")
                ToolTip {
                  visible: groupHover.hovered && groupRow.tooltipText !== ""
                  text: groupRow.tooltipText
                  delay: 400
                  padding: Style.space(8)
                  background: Rectangle {
                    color: Color.background
                    radius: height / 2
                    border.color: Color.muted
                    border.width: 1
                  }
                  contentItem: Text {
                    text: groupRow.tooltipText
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                // A 3px rail, not a toggle. This reports state; it does not set
                // it, and a switch that cannot be switched invites the click it
                // then ignores. Red when the group covers nothing -- zero
                // coverage is the failure this project was built after.
                Rectangle {
                  width: Style.space(3)
                  height: cellCol.implicitHeight
                  color: (typeof groupRow.modelData.files === "number"
                          && groupRow.modelData.files === 0) ? Color.urgent
                       : groupRow.modelData.enabled === false ? Color.muted
                       : Color.foreground
                  opacity: groupRow.modelData.enabled === false ? 0.35 : 0.55
                }

                Column {
                  id: cellCol
                  width: parent.width - Style.space(10)
                  spacing: Style.space(1)

                  // Name and mode share one line, so the badge cannot float
                  // loose in a corner of the cell.
                  Item {
                    width: parent.width
                    implicitHeight: nameText.implicitHeight
                    Text {
                      id: nameText
                      anchors.left: parent.left
                      anchors.right: modeText.left
                      anchors.rightMargin: Style.space(5)
                      text: groupRow.modelData.label || groupRow.modelData.id || ""
                      color: groupRow.modelData.enabled === false
                             ? Color.muted : Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                    Text {
                      id: modeText
                      anchors.right: parent.right
                      anchors.baseline: nameText.baseline
                      text: (groupRow.modelData.mode || "").toUpperCase()
                      color: Color.muted
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      opacity: 0.75
                    }
                  }

                  Text {
                    width: parent.width
                    text: root.groupDetail(groupRow.modelData)
                          + (groupRow.modelData.coupled ? "  ·  tied" : "")
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }

          Text {
            visible: root.report === null
            width: parent.width
            text: root.lastError !== "" ? "Could not check -- see the error below."
                                         : "Not checked yet."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // ── where it goes ──────────────────────────────────────────────────
          // Coverage says the backup holds the right files. This says whether
          // any of it ever left the machine -- the question nothing answered
          // before, and the one a dead disk asks.
          // Same reasoning as Groups above: visible when there is something
          // to show OR when status has never been read at all
          // (statusDoc === null), so an unknown state gets its own header
          // rather than the whole section quietly not existing.
          Item {
            // github moved to its own button in the top action row (below);
            // this section is now only about `dir` destinations, so it hides
            // once there is nothing else -- an unknown state still gets its
            // own header rather than quietly not existing.
            visible: root.otherDestinations.length > 0 || root.statusDoc === null
            width: parent.width
            implicitHeight: dHdr.implicitHeight + Style.space(5)
            PanelSectionHeader { id: dHdr; anchors.left: parent.left; text: "Destinations" }
            PanelSeparator { anchors.bottom: parent.bottom; width: parent.width }
          }

          // Each destination is a chip -- omarchy's Button carries `selected`,
          // which is exactly "this one is live". A row of them reads at a
          // glance: what exists, and which are working.
          Flow {
            width: column.width
            spacing: Style.space(6)

            Repeater {
              model: root.otherDestinations
              Row {
                id: destRow
                required property var modelData
                spacing: Style.space(6)

                Button {
                  text: destRow.modelData.id || ""
                  bordered: true
                  // Not clickable: pushing to one destination on demand needs
                  // `push <id>`, and a chip that looks pressable but does
                  // nothing is worse than one that plainly reports.
                  selected: destRow.modelData.lastSuccess !== "" && !destRow.modelData.failed
                  foreground: destRow.modelData.failed ? Color.urgent
                            : destRow.modelData.lastSuccess !== "" ? Color.foreground
                            : Color.accent
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  // The type only earns space when it says something the id
                  // does not -- for github the two are the same word, which is
                  // how the panel came to read "github  github".
                  text: {
                    var d = destRow.modelData
                    var bits = []
                    if (d.type && d.type !== d.id) bits.push(d.type)
                    if (d.errorMessage !== "") bits.push(d.errorMessage)
                    else if (d.lastSuccess !== "") bits.push("sent " + root.agoFromIso(d.lastSuccess))
                    else bits.push("never sent")
                    return bits.join("  ·  ")
                  }
                  color: destRow.modelData.failed ? Color.urgent : Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            visible: root.statusDoc !== null && root.destinations.length === 0
            width: parent.width
            text: "No destination configured. The backup exists only on this machine."
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.statusDoc === null
            width: parent.width
            text: root.lastError !== "" ? "Could not check -- see the error below."
                                         : "Not checked yet."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // (stale / not-scheduled alerts now live right under the verdict,
          // near the top of the column -- see the reorganised block above)

          // ── current settings, collapsed by default ───────────────────────
          Item {
            width: parent.width
            implicitHeight: cHdr.implicitHeight + Style.space(5)
            PanelSectionHeader { id: cHdr; anchors.left: parent.left; text: "Current settings" }
            Text {
              anchors.left: cHdr.right
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: cHdr.verticalCenter
              text: root.configExpanded ? "-" : "+"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            PanelSeparator { anchors.bottom: parent.bottom; width: parent.width }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleSettings()
            }
          }

          Grid {
            id: cfgGrid
            visible: root.configExpanded
            width: column.width
            columns: 2
            columnSpacing: Style.space(10)
            rowSpacing: Style.space(2)

            component CfgRow: Row {
              property string k: ""
              property string v: ""
              width: (cfgGrid.width - cfgGrid.columnSpacing) / 2
              spacing: Style.space(4)
              Text {
                id: keyLabel
                // A fixed label column, not a binding onto a sibling's implicit
                // width: that reads the child list positionally and breaks the
                // moment anything is inserted before it.
                width: Style.space(52)
                text: parent.k
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Text {
                width: parent.width - parent.spacing - keyLabel.width
                horizontalAlignment: Text.AlignRight
                text: parent.v
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
              }
            }

            CfgRow { k: "backup";   v: root.humanSchedule(root.syncSchedule) }
            CfgRow { k: "send";     v: root.humanSchedule(root.pushSchedule) }
            CfgRow { k: "repo";     v: root.config ? root.shortPath(root.config.repo) : "—" }
            CfgRow { k: "state";    v: root.config ? root.shortPath(root.config.state) : "—" }
            CfgRow { k: "folders";  v: root.config ? root.shortPath(root.config.destinationsFile) : "—" }
            CfgRow { k: "deny list"; v: root.config ? root.shortPath(root.config.denyList) : "—" }
          }

          Text {
            width: parent.width
            text: "r  check again      c  collect into staging"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ── the fixed footer: navigation actions ────────────────────────────
      // Never scrolls out of view and is present only in "overview";
      // the restore screens get their own back-navigation instead.
      Item {
        id: footerBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: footerActions.implicitHeight + Style.space(12)

        PanelSeparator { anchors.top: parent.top; width: parent.width }

        Row {
          id: footerActions
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Button {
            id: restoreButton
            text: "↻ Restore…"
            bordered: false
            focusable: true
            // Was hardcoded to Color.muted regardless of state -- a leftover
            // from a pre-Button-component `color: cond ? Color.muted :
            // Color.muted` no-op (9e5f0ed and its predecessor), never
            // actually distinguishing enabled from disabled by color the way
            // settingsButton below always has. Opacity alone made a fully
            // enabled Restore read as faded next to Settings.
            foreground: root.canOpenExternalTui ? Color.accent : Color.muted
            opacity: root.canOpenExternalTui ? 1.0 : 0.45
            enabled: root.canOpenExternalTui
            onClicked: root.openRestore()
          }

          Button {
            id: settingsButton
            text: root.configuring ? "Settings…" : "⚙ Settings…"
            bordered: false
            focusable: true
            foreground: root.canOpenExternalTui ? Color.accent : Color.muted
            opacity: root.canOpenExternalTui ? 1.0 : 0.45
            enabled: root.canOpenExternalTui
            onClicked: root.openConfig()
          }
        }
      }

    }
  }
}
