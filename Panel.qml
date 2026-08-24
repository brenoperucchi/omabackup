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

  readonly property int failCount: report && report.counts ? (report.counts.fail || 0) : 0
  readonly property int warnCount: report && report.counts ? (report.counts.warn || 0) : 0
  readonly property int passCount: report && report.counts ? (report.counts.pass || 0) : 0
  readonly property bool covered: report !== null && failCount === 0 && warnCount === 0
  readonly property string omarchyVersion: report && report.omarchy ? (report.omarchy.version || "?") : "?"
  readonly property string watermark: report && report.omarchy ? (report.omarchy.migrationWatermark || "?") : "?"

  // Omarchy's palette has no green on purpose, and neither does this widget:
  // "up to date" is the absence of colour. Colour means there is something to do.
  readonly property color barText: bar ? bar.barForeground : Color.foreground
  readonly property string headline: cliMissing ? "not configured"
                                   : lastError !== "" ? "check failed"
                                   : report === null ? "not checked yet"
                                   : failCount > 0 ? failCount + (failCount === 1 ? " failure" : " failures")
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
  }

  function collect() {
    if (root.cliMissing || collectProc.running) return
    collectProc.running = true
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

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

          Text {
            width: parent.width
            text: root.headline
            color: root.failCount > 0 ? Color.urgent : Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
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
            text: "Needs attention"
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

          PanelSectionHeader { text: "Keys" }

          Text {
            width: parent.width
            text: "r  check coverage again\nc  collect into staging"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
