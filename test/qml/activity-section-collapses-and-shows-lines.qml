// Regression probe for Panel.qml's "Recent activity" section -- mirrors
// `activityExpanded`, `toggleActivity()`, the clickable header Item with its
// MouseArea, the GitHub status line, and the Repeater's `statusDoc.recentLog`
// binding.
//
// Extended this round (panel reorg: version into the title row, this
// section promoted and defaulted to expanded) to also mirror the GitHub
// status line that now lives as this Column's first child -- a design
// consultation (herdr-ask round omabackup-13) found the section's original
// empty-placeholder text ("Nothing logged yet.") would render directly
// under a GitHub status line and read as contradictory (true of the log,
// false-reading in context). Fixed by renaming the placeholder to "No
// activity logged yet." -- this probe proves that combination specifically,
// not just the individual states in isolation.
//
// A FloatingWindow, not a bare ShellRoot, for the same reason
// config-section-collapses-height.qml already documents: a window with no
// render pass never actually relayouts a Column when a sibling's visibility
// changes, so implicitHeight would look frozen even with correct logic.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/activity-section-collapses-and-shows-lines.qml
import QtQuick
import Quickshell
import Quickshell.Widgets

FloatingWindow {
  id: root
  visible: true
  implicitWidth: 300
  implicitHeight: 200

  property bool activityExpanded: false
  property var statusDoc: null
  property var githubDestination: null

  function toggleActivity() {
    root.activityExpanded = !root.activityExpanded
  }

  // Trivial stand-in for Panel.qml's own agoFromIso() -- that helper's own
  // logic is unrelated to what this probe verifies (the GitHub line's
  // visibility/text/colour wiring), so it is not reimplemented here.
  function agoFromIso(iso) { return "3h ago" }

  Column {
    id: column
    width: 300
    spacing: 10

    Rectangle { id: header; width: 100; height: 20 }

    Item {
      width: parent.width
      implicitHeight: aHdrText.implicitHeight
      Text { id: aHdrText; text: "Recent activity" }
      MouseArea {
        anchors.fill: parent
        onClicked: root.toggleActivity()
      }
    }

    Column {
      id: activityList
      visible: root.activityExpanded
      width: column.width
      spacing: 2

      Text {
        id: githubStatus
        visible: root.activityExpanded && root.githubDestination !== null
        width: activityList.width
        text: "GitHub " + (root.githubDestination && root.githubDestination.failed
                ? root.githubDestination.errorMessage
                : root.githubDestination && root.githubDestination.lastSuccess !== ""
                  ? "sent " + root.agoFromIso(root.githubDestination.lastSuccess) : "never sent")
        // A plain string, not the real `color` property -- QML coerces
        // whatever is assigned to `color` into an actual QColor when read
        // back, so comparing it against a JS string like "urgent" would
        // never match regardless of which branch fired. This probe only
        // needs to prove the CONDITIONAL picks the right role, mirroring
        // Panel.qml's Color.urgent/Color.muted without importing that
        // singleton.
        property string colorRole: root.githubDestination && root.githubDestination.failed ? "urgent" : "muted"
      }

      Repeater {
        id: activityRepeater
        model: root.activityExpanded && root.statusDoc && Array.isArray(root.statusDoc.recentLog)
          ? root.statusDoc.recentLog : []
        Text {
          required property var modelData
          width: activityList.width
          text: modelData
        }
      }

      Text {
        id: errorMessage
        visible: root.activityExpanded && root.statusDoc && root.statusDoc.recentLogError === true
        width: activityList.width
        text: "Could not read the log."
      }

      Text {
        id: emptyPlaceholder
        visible: root.activityExpanded &&
          !(root.statusDoc && root.statusDoc.recentLogError === true) &&
          !(root.statusDoc && Array.isArray(root.statusDoc.recentLog) && root.statusDoc.recentLog.length > 0)
        width: activityList.width
        text: "No activity logged yet."
      }
    }

    Rectangle { id: footer; width: 100; height: 20 }
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: {
      var collapsedHeight = column.implicitHeight
      var collapsedFooterY = footer.y
      console.log("[phase1] collapsedHeight=" + collapsedHeight + " footerY=" + collapsedFooterY)
      if (collapsedFooterY > 60) {
        console.log("[result] collapsed section already occupied layout space")
        Qt.exit(1)
        return
      }
      root.activityExpanded = true
      phase2.start()
    }
  }

  Timer {
    id: phase2
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      // No statusDoc/recentLog, no githubDestination yet -- expanded, but
      // fully empty. Neither the GitHub line nor the log placeholder's
      // contradiction case applies here; this is the baseline.
      var placeholderOk = emptyPlaceholder.visible && activityRepeater.count === 0
      var githubHidden = !githubStatus.visible
      var footerMoved = footer.y > 60  // the section now occupies real space
      console.log("[phase2] placeholderOk=" + placeholderOk + " githubHidden=" + githubHidden +
        " repeaterCount=" + activityRepeater.count + " footerY=" + footer.y)
      if (!placeholderOk || !githubHidden || !footerMoved) {
        console.log("[result] empty-expanded state did not render the placeholder correctly")
        Qt.exit(1)
        return
      }
      // A configured GitHub destination with a genuinely empty log is the
      // normal first-run state, not an exotic one -- the exact combination
      // the design consultation flagged as contradictory under the OLD
      // "Nothing logged yet." text. Both lines must be visible together,
      // and the placeholder's reworded text must still make sense.
      root.githubDestination = { failed: false, lastSuccess: "", errorMessage: "" }
      phase2b.start()
    }
  }

  Timer {
    id: phase2b
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var githubShown = githubStatus.visible && githubStatus.text === "GitHub never sent"
      var placeholderStillShown = emptyPlaceholder.visible
      console.log("[phase2b] githubShown=" + githubShown + " githubText=" + githubStatus.text +
        " placeholderStillShown=" + placeholderStillShown)
      if (!githubShown || !placeholderStillShown) {
        console.log("[result] the GitHub-configured-but-log-empty combination did not render both lines")
        Qt.exit(1)
        return
      }
      // Success state: "sent <age>", muted.
      root.githubDestination = { failed: false, lastSuccess: "2026-09-01T10:00:00Z", errorMessage: "" }
      phase2c.start()
    }
  }

  Timer {
    id: phase2c
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var textOk = githubStatus.text === "GitHub sent 3h ago"
      var colorOk = githubStatus.colorRole === "muted"
      console.log("[phase2c] textOk=" + textOk + " colorOk=" + colorOk + " text=" + githubStatus.text)
      if (!textOk || !colorOk) {
        console.log("[result] the GitHub success state did not render the right text/colour")
        Qt.exit(1)
        return
      }
      // Failure state: the destination's own error message, urgent colour.
      root.githubDestination = { failed: true, lastSuccess: "", errorMessage: "connection refused" }
      phase2d.start()
    }
  }

  Timer {
    id: phase2d
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var textOk = githubStatus.text === "GitHub connection refused"
      var colorOk = githubStatus.colorRole === "urgent"
      console.log("[phase2d] textOk=" + textOk + " colorOk=" + colorOk + " text=" + githubStatus.text)
      if (!textOk || !colorOk) {
        console.log("[result] the GitHub failure state did not render the right text/colour")
        Qt.exit(1)
        return
      }
      root.statusDoc = { recentLog: ["07:00:21  sync  ok  7s", "07:15:33  push  ok  4s", "10:02:10  config  exit=0  3s"] }
      phase3.start()
    }
  }

  Timer {
    id: phase3
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var placeholderGone = !emptyPlaceholder.visible
      var countOk = activityRepeater.count === 3
      var firstLineOk = countOk && activityRepeater.itemAt(0).text === "07:00:21  sync  ok  7s"
      var lastLineOk = countOk && activityRepeater.itemAt(2).text === "10:02:10  config  exit=0  3s"
      // The GitHub line (still in its failure state from phase2d) must
      // coexist with real log lines without interfering with either.
      var githubStillShown = githubStatus.visible && githubStatus.text === "GitHub connection refused"
      console.log("[phase3] placeholderGone=" + placeholderGone + " count=" + activityRepeater.count +
        " firstLineOk=" + firstLineOk + " lastLineOk=" + lastLineOk + " githubStillShown=" + githubStillShown)
      var ok = placeholderGone && countOk && firstLineOk && lastLineOk && githubStillShown
      if (!ok) { Qt.exit(1); return }

      // recentLogError case, added round omabackup-35 alongside making
      // the underlying day-file read failure a real, checked condition
      // in cmd_status instead of one silently masked as an empty
      // recentLog. recentLog stays [] (round omabackup-33/34's own
      // settled principle: this field must never break the rest of the
      // document), but the panel must now show a DIFFERENT message than
      // "No activity logged yet." when the failure flag is set -- not
      // treat an unreadable log identically to a genuinely empty one. The
      // GitHub status line is independent of log readability and must
      // stay visible regardless.
      root.statusDoc = { recentLog: [], recentLogError: true }
      phase3b.start()
    }
  }

  Timer {
    id: phase3b
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var errorShown = errorMessage.visible
      var placeholderHidden = !emptyPlaceholder.visible
      var noLines = activityRepeater.count === 0
      var githubStillShown = githubStatus.visible
      console.log("[phase3b] errorShown=" + errorShown + " placeholderHidden=" + placeholderHidden +
        " repeaterCount=" + activityRepeater.count + " githubStillShown=" + githubStillShown)
      if (!errorShown || !placeholderHidden || !noLines || !githubStillShown) {
        console.log("[result] the read-failure state did not render its own distinct message correctly")
        Qt.exit(1)
        return
      }

      // Collapsing again must remove the delegates from layout, matching
      // the "model gated on activityExpanded too" reasoning in Panel.qml's
      // own comment -- not just hide them via `visible`. The GitHub line
      // is gated the same way and must disappear too.
      root.activityExpanded = false
      phase4.start()
    }
  }

  Timer {
    id: phase4
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var recollapsed = activityRepeater.count === 0 && footer.y <= 60 &&
        !errorMessage.visible && !githubStatus.visible
      console.log("[result] recollapsed=" + recollapsed + " repeaterCount=" + activityRepeater.count +
        " footerY=" + footer.y + " githubVisible=" + githubStatus.visible)
      Qt.exit(recollapsed ? 0 : 1)
    }
  }
}
