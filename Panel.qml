import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmaBackup's bar surface: an icon that stays quiet while coverage holds, and a
// panel listing what the last check found.
//
// Everything this file does is read one JSON document produced by the
// `omabackup` CLI. No file is written here, no git runs here, nothing blocks.
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

  readonly property var destinations: {
    if (!statusDoc || !statusDoc.destinations) return []
    return statusDoc.destinations
  }
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
    statusDoc && statusDoc.scheduler && statusDoc.scheduler.sync ? statusDoc.scheduler.sync : ""
  readonly property string pushSchedule:
    statusDoc && statusDoc.scheduler && statusDoc.scheduler.push ? statusDoc.scheduler.push : ""

  // "last backup 8m ago", the way the mockup's header reads it.
  function agoText(sec) {
    if (typeof sec !== "number") return "never"
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
    if (!p) return "—"
    var h = Quickshell.env("HOME")
    return (h && p.indexOf(h) === 0) ? "~" + p.substring(h.length) : p
  }
  // systemd's calendar syntax is precise and unreadable. The panel says what it
  // means; `systemctl --user list-timers` is there for the exact expression.
  function humanSchedule(c) {
    if (!c) return "not scheduled"
    var m = c.match(/\*:00\/(\d+):00/)
    if (m) return "every " + m[1] + " min"
    if (c.indexOf("*:00:00") >= 0) return "hourly"
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
      if (d.lastError || !d.lastSuccess) out.push(d)
    }
    return out
  }

  // ── what is covered, per group ───────────────────────────────────────────
  // From verify --json, counted by collect rather than recomputed here: collect
  // is what decides which files enter the backup, and a second implementation
  // of that decision would eventually disagree with the first.
  readonly property var groups: {
    if (!report || !report.groups) return []
    return report.groups
  }
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
    if (typeof b !== "number") return "?"
    if (b < 1024) return b + " B"
    if (b < 1048576) return Math.round(b / 1024) + " KB"
    return (Math.round(b / 104857.6) / 10) + " MB"
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

  readonly property int failCount: report && report.counts ? (report.counts.fail || 0) : 0
  readonly property int warnCount: report && report.counts ? (report.counts.warn || 0) : 0
  readonly property int passCount: report && report.counts ? (report.counts.pass || 0) : 0
  readonly property bool covered: report !== null && failCount === 0 && warnCount === 0
  readonly property string omarchyVersion: report && report.omarchy ? (report.omarchy.version || "?") : "?"
  readonly property string watermark: report && report.omarchy ? (report.omarchy.migrationWatermark || "?") : "?"

  // Omarchy's palette has no green on purpose, and neither does this widget:
  // "up to date" is the absence of colour. Colour means there is something to do.
  readonly property color barText: bar ? bar.barForeground : Color.foreground
  // Ordered by how badly it needs a human. "not scheduled" ranks above a
  // warning count because nothing running the backup makes every other number
  // on this panel stale -- it is the August incident one level up.
  readonly property string headline: cliMissing ? "not configured"
                                   : lastError !== "" ? "check failed"
                                   : report === null ? "not checked yet"
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

  function refresh() {
    if (root.checking || root.cliMissing) return
    root.checking = true
    root.lastError = ""
    verifyProc.buffer = ""
    verifyProc.running = true
    if (!statusProc.running) { statusProc.buffer = ""; statusProc.running = true }
  }

  function applyStatus(text) {
    // Destinations must never be able to break the coverage view. An older CLI
    // with no `destinations` key, a half-written document, anything: the panel
    // loses the destination section and keeps everything else.
    try {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object") root.statusDoc = parsed
    } catch (e) {
      root.statusDoc = null
    }
  }

  function collect() {
    if (root.cliMissing || collectProc.running) return
    collectProc.running = true
  }

  // "Fazer backup agora" from the mockup. The plugin still writes nothing and
  // runs no git itself (DESIGN.md §1) -- it asks the CLI, exactly as the timer
  // does, and re-reads when the CLI is done.
  // The master switch. Unlike the group toggles, this one sets: `enable` and
  // `disable` start and stop the timers, which is what "is omabackup on" means
  // -- with them stopped nothing collects, commits or is sent.
  property bool switching: false
  function setEnabled(on) {
    if (root.cliMissing || root.switching) return
    root.switching = true
    switchProc.command = [root.cli, on ? "enable" : "disable"]
    switchProc.running = true
  }

  property bool syncing: false
  function syncNow() {
    if (root.cliMissing || root.syncing) return
    root.syncing = true
    syncProc.running = true
  }

  function applyReport(text) {
    // A CLI that dies mid-write, an empty stdout, a future schema: none of
    // these may throw out of here.
    try {
      var parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object") {
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
  property string cli: ""

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

  Process {
    id: verifyProc
    property string buffer: ""
    command: root.cli === "" ? ["true"] : [root.cli, "verify", "--json"]
    stdout: StdioCollector { onStreamFinished: verifyProc.buffer = text }
    // verify exits non-zero when coverage fails, which is a result, not an
    // error. Only an empty document means the run itself went wrong.
    onExited: function(code) {
      root.checking = false
      if (verifyProc.buffer.trim() === "") root.lastError = "no output from " + root.cli
      else root.applyReport(verifyProc.buffer)
    }
  }

  Process {
    id: statusProc
    property string buffer: ""
    command: root.cli === "" ? ["true"] : [root.cli, "status", "--json"]
    stdout: StdioCollector { onStreamFinished: statusProc.buffer = text }
    onExited: function(code) {
      if (statusProc.buffer.trim() !== "") root.applyStatus(statusProc.buffer)
    }
  }

  Process {
    id: switchProc
    command: ["true"]
    onExited: function(code) {
      root.switching = false
      root.refresh()
    }
  }

  Process {
    id: syncProc
    command: root.cli === "" ? ["true"] : [root.cli, "sync", "--commit"]
    onExited: function(code) {
      root.syncing = false
      root.refresh()
    }
  }

  Process {
    id: collectProc
    command: root.cli === "" ? ["true"] : [root.cli, "collect", "--json"]
    onExited: function(code) { root.refresh() }
  }

  Timer {
    interval: Math.max(60, root.setting("refreshIntervalSec", 900)) * 1000
    running: root.cli !== ""
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: "brenoperucchi.omabackup"
    function refresh(): void { root.refresh() }
    function collect(): void { root.collect() }
    function toggle(): void { root.toggle() }
    function status(): string {
      return JSON.stringify({ covered: root.covered, fail: root.failCount,
                              warn: root.warnCount, headline: root.headline })
    }
  }

  // ── the bar ──────────────────────────────────────────────────────────────
  // Hidden while the CLI is absent: a backup plugin that nags about not being
  // installed is worse than one that waits quietly.
  visible: !root.cliMissing
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: visible ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // fa-exclamation-triangle when something needs doing, fa-save otherwise.
    // Both are BMP codepoints, like the first-party widgets use.
    text: root.failCount > 0 ? "\uf071" : "\uf0c7"
    // WidgetButton colours through `foreground`, and `active` swaps in
    // `activeColor` (the theme's urgent). No green anywhere: a healthy backup
    // is dimmed, not celebrated.
    foreground: root.warnCount > 0 ? Color.accent : root.barText
    active: root.failCount > 0
    dimmed: root.covered
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
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
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

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
        anchors.fill: parent
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
              interactive: !root.cliMissing && !root.switching
              onToggled: root.setEnabled(!root.scheduled)
            }
          }

          Text {
            visible: root.statusDoc !== null
            width: parent.width
            // The status word moved here from the header, where the switch now
            // sits. Color.muted was too dark to read at caption size against
            // the panel ground -- this is the foreground, dimmed, which stays
            // legible while still reading as secondary.
            text: root.headline + "  ·  " + root.summaryLine
            color: Color.foreground
            opacity: 0.62
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: root.syncing ? "backing up…" : "Back up now"
              bordered: true
              focusable: true
              enabled: !root.cliMissing && !root.syncing
              onClicked: root.syncNow()
            }
            Button {
              text: "Check again"
              bordered: true
              focusable: true
              enabled: !root.cliMissing && !root.checking
              onClicked: root.refresh()
            }
          }

          Text {
            width: parent.width
            text: "Omarchy " + root.omarchyVersion + "  -  migration " + root.watermark
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
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
          Item {
            visible: root.groups.length > 0
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

          // ── where it goes ──────────────────────────────────────────────────
          // Coverage says the backup holds the right files. This says whether
          // any of it ever left the machine -- the question nothing answered
          // before, and the one a dead disk asks.
          Item {
            visible: root.destinations.length > 0
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
                  selected: destRow.modelData.lastSuccess && !destRow.modelData.lastError
                  foreground: destRow.modelData.lastError ? Color.urgent
                            : destRow.modelData.lastSuccess ? Color.foreground
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
                    if (d.lastError && d.lastError.message) bits.push(d.lastError.message)
                    else if (d.lastSuccess) bits.push("sent " + root.agoFromIso(d.lastSuccess))
                    else bits.push("never sent")
                    return bits.join("  ·  ")
                  }
                  color: destRow.modelData.lastError ? Color.urgent : Color.muted
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

          // A stale backup outranks the destination list below it: if nothing
          // has completed for a day, every timestamp under Destinations is
          // describing a machine that has since moved on.
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

          // ── and whether anything runs it ───────────────────────────────────
          // omarchy runs no hook on plugin install, so the timers cannot install
          // themselves. A fresh machine shows the widget and backs up nothing;
          // that has to be visible here rather than discovered later.
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

          // ── config ────────────────────────────────────────────────────────
          Item {
            width: parent.width
            implicitHeight: cHdr.implicitHeight + Style.space(5)
            PanelSectionHeader { id: cHdr; anchors.left: parent.left; text: "Config" }
            PanelSeparator { anchors.bottom: parent.bottom; width: parent.width }
          }

          Grid {
            id: cfgGrid
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

            CfgRow { k: "sync";     v: root.humanSchedule(root.syncSchedule) }
            CfgRow { k: "push";     v: root.humanSchedule(root.pushSchedule) }
            CfgRow { k: "repo";     v: root.config ? root.shortPath(root.config.repo) : "—" }
            CfgRow { k: "state";    v: root.config ? root.shortPath(root.config.state) : "—" }
            CfgRow { k: "targets";  v: root.config ? root.shortPath(root.config.destinationsFile) : "—" }
            CfgRow { k: "secrets";  v: root.config ? root.shortPath(root.config.denyList) : "—" }
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
    }
  }
}
