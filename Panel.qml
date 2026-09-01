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
  readonly property int passCount: report && report.counts ? (report.counts.pass || 0) : 0
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
    verifyProc.running = true
    if (!statusProc.running) { statusProc.buffer = ""; statusProc.running = true }
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
    try {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed) && parsed.schemaVersion === 1
          && Array.isArray(parsed.destinations)
          && parsed.scheduler && typeof parsed.scheduler === "object" && !Array.isArray(parsed.scheduler)) {
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
    switchProc.command = [root.cli, on ? "enable" : "disable"]
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
      if (verifyProc.running) {
        verifyProc.timedOut = true
        verifyProc.running = false
      }
      if (statusProc.running) {
        statusProc.timedOut = true
        statusProc.running = false
      }
      if (syncProc.running) {
        syncProc.timedOut = true
        root.lastError = "sync timed out after " + Math.round(root.busyTimeoutMs / 1000) + "s"
        syncProc.running = false
      }
      if (collectProc.running) {
        collectProc.timedOut = true
        root.lastError = "collect timed out after " + Math.round(root.busyTimeoutMs / 1000) + "s"
        collectProc.running = false
      }
      if (switchProc.running) {
        switchProc.timedOut = true
        root.lastError = "enable/disable timed out after " + Math.round(root.busyTimeoutMs / 1000) + "s"
        switchProc.running = false
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
    command: root.cli === "" ? ["true"] : [root.cli, "verify", "--json"]
    stdout: StdioCollector { onStreamFinished: verifyProc.buffer = text }
    stderr: StdioCollector { onStreamFinished: verifyProc.errBuffer = text }
    // verify exits non-zero when coverage fails, which is a result, not an
    // error. Only an empty document -- the CLI itself never answered -- means
    // the run went wrong, and now says what it printed to stderr rather than
    // a bare "no output" that swallowed the actual reason. The timedOut
    // branch returns before any of that: the timer already set the message
    // this run's actual outcome would otherwise immediately overwrite.
    onExited: function(code) {
      root.checking = false
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
    command: root.cli === "" ? ["true"] : [root.cli, "status", "--json"]
    stdout: StdioCollector { onStreamFinished: statusProc.buffer = text }
    stderr: StdioCollector { onStreamFinished: statusProc.errBuffer = text }
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
    // now, the same way the failure branch already is.
    onExited: function(code) {
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
    command: ["true"]
    stderr: StdioCollector { onStreamFinished: switchProc.errBuffer = text }
    onExited: function(code) {
      root.switching = false
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
    command: root.cli === "" ? ["true"] : [root.cli, "sync", "--commit"]
    stderr: StdioCollector { onStreamFinished: syncProc.errBuffer = text }
    // The exit code used to be thrown away entirely -- a sync that failed and
    // one that worked produced the exact same UI sequence (syncing -> false,
    // refresh). The refresh alone did not compensate: the next verify checks
    // COVERAGE, not whether the commit this button asked for actually landed,
    // so a push that failed for its own reason (a git error, a hook, a lock)
    // said nothing was wrong. A review round then caught the refresh() call
    // itself erasing that same message a line later (refresh() used to clear
    // lastError unconditionally) -- keepError=true on the failure path is
    // what stops that.
    onExited: function(code) {
      root.syncing = false
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
    command: root.cli === "" ? ["true"] : [root.cli, "collect", "--json"]
    stderr: StdioCollector { onStreamFinished: collectProc.errBuffer = text }
    onExited: function(code) {
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
      externalProc.command = ["omarchy-launch-tui",
                              "--app-id=org.omarchy.omabackup-" + root.externalAction,
                              root.tuiCli, root.cli, root.externalAction, root.externalToken]
      externalProc.running = true
    }
  }

  Process {
    id: externalProc
    property string errBuffer: ""
    command: ["true"]
    stderr: StdioCollector { onStreamFinished: externalProc.errBuffer = text }
    onExited: function(code) {
      var action = root.externalAction
      if (code !== 0) {
        externalRecoveryTimer.stop()
        root.externalAction = ""
        root.externalToken = ""
        root.externalBusy = false
        root.configuring = false
        root.lastError = action + ": " + (externalProc.errBuffer.trim() || ("exit " + code))
        root.refresh(true)
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
      root.externalAction = ""
      root.externalToken = ""
      root.externalBusy = false
      root.configuring = false
      root.lastError = action + ": terminal did not report completion; status refreshed"
      root.refresh(true)
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
    // Icons' md-sync_circle otherwise -- sync arrows inside a ring, for the
    // actual cycle this tool runs (collect -> publish -> verify -> commit),
    // not the generic fa-save floppy disk this used to be. Picked from a
    // different icon family than either other Omarchy backup plugin: Time
    // Machine (restic) uses Font Awesome's fa-history, OmaVault uses
    // Material Design's own md-safe. Codepoints for candidate glyphs
    // (fa-layer-group, fa-code-commit, fa-shield-halved -- all FA5+ solid
    // icons above roughly U+F2FF) were checked with fontTools'
    // getBestCmap()/getGlyphOrder() against the actual installed
    // JetBrainsMono Nerd Font .ttf (resolved via `fc-match monospace`, which
    // is what the bar's font actually renders through) before settling
    // here, after fa-layer-group (U+F5FD) rendered as a blank box -- that
    // build only carries the classic Font Awesome block. md-sync_circle is
    // U+F1378, above the Basic Multilingual Plane, so it needs the `\u{...}`
    // code point escape rather than `\uXXXX`.
    text: root.failCount > 0 ? "\uf071" : "\u{F1378}"
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
    // legibility problem opacity alone did not explain. iconLarge (18px)
    // still leaves headroom under both the slot and the bar height.
    fontSize: Style.font.iconLarge
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
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(
      column.implicitHeight + footerBar.height,
      Style.space(560))

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

            Row {
              id: headRow
              spacing: Style.space(6)
              anchors.left: parent.left

              // One glance, one colour. Omarchy's palette has no green on
              // purpose and neither does this: "fine" is muted ink rather than
              // a reassuring tick, so colour here always means work to do.
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
            }

            // The one control on this panel that actually sets something.
            ToggleSwitch {
              anchors.right: parent.right
              anchors.verticalCenter: headRow.verticalCenter
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

          Row {
            width: parent.width
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

          // Runtime identity is compact and sits between the primary actions
          // and the detailed sections. The OmaBackup version is a real button
          // because it is useful when reporting a bug; the copy action writes
          // only to Quickshell's Wayland clipboard.
          Row {
            width: parent.width
            spacing: Style.space(4)

            Button {
              id: versionButton
              text: root.versionCopied ? "OmaBackup " + root.toolVersion + "  ✓ copied"
                                       : "OmaBackup " + root.toolVersion
              bordered: false
              focusable: true
              enabled: root.toolVersion !== "?"
              foreground: root.versionCopied ? Color.foreground : Color.accent
              onClicked: root.copyToolVersion()
            }

            Text {
              anchors.verticalCenter: versionButton.verticalCenter
              text: "·  Omarchy " + root.omarchyVersion + "  ·  migration " + root.watermark
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width - versionButton.width - Style.space(4)
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
            visible: root.alerts.length === 0 && root.report !== null
            width: parent.width
            text: passCount + " checks passed. The backup covers every file the "
                  + "system reads right now."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
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
            visible: root.destinations.length > 0 || root.statusDoc === null
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
              model: root.destinations
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
