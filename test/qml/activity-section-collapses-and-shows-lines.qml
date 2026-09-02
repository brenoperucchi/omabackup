// Regression probe for Panel.qml's "Recent activity" section -- mirrors
// `activityExpanded`, `toggleActivity()`, the clickable header Item with its
// MouseArea, and the Repeater's `statusDoc.recentLog` binding, all added
// alongside the Settings TUI's own "View log" item (same underlying
// lib/log.sh `_log_tail` read side, two different surfaces).
//
// A FloatingWindow, not a bare ShellRoot, for the same reason
// config-section-collapses-height.qml already documents: a window with no
// render pass never actually relayouts a Column when a sibling's visibility
// changes, so implicitHeight would look frozen even with correct logic.
//
// Four properties, in one probe rather than four, since they share the
// same collapsed/expanded state machine and fixture:
// 1. Collapsed: zero-height contribution, matching cfgGrid's own established
//    "invisible still occupies nothing" behavior.
// 2. Expanded with no log data: the "Nothing logged yet." placeholder shows,
//    and nothing else does.
// 3. Expanded with real log lines (a fixture statusDoc, matching the shape
//    cmd_status --json actually emits): a Text item per line, in order.
// 4. Expanded with recentLogError:true (a real day-file read failure,
//    round omabackup-35): a distinct "Could not read the log." message,
//    not the plain-empty placeholder, and no log lines rendered.
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

  function toggleActivity() {
    root.activityExpanded = !root.activityExpanded
  }

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
        text: "Nothing logged yet."
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
      // No statusDoc/recentLog set yet -- expanded, but empty.
      var placeholderOk = emptyPlaceholder.visible && activityRepeater.count === 0
      var footerMoved = footer.y > 60  // the section now occupies real space
      console.log("[phase2] placeholderOk=" + placeholderOk + " repeaterCount=" + activityRepeater.count +
        " footerY=" + footer.y)
      if (!placeholderOk || !footerMoved) {
        console.log("[result] empty-expanded state did not render the placeholder correctly")
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
      console.log("[phase3] placeholderGone=" + placeholderGone + " count=" + activityRepeater.count +
        " firstLineOk=" + firstLineOk + " lastLineOk=" + lastLineOk)
      var ok = placeholderGone && countOk && firstLineOk && lastLineOk
      if (!ok) { Qt.exit(1); return }

      // recentLogError case, added round omabackup-35 alongside making
      // the underlying day-file read failure a real, checked condition
      // in cmd_status instead of one silently masked as an empty
      // recentLog. recentLog stays [] (round omabackup-33/34's own
      // settled principle: this field must never break the rest of the
      // document), but the panel must now show a DIFFERENT message than
      // "Nothing logged yet." when the failure flag is set -- not treat
      // an unreadable log identically to a genuinely empty one.
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
      console.log("[phase3b] errorShown=" + errorShown + " placeholderHidden=" + placeholderHidden +
        " repeaterCount=" + activityRepeater.count)
      if (!errorShown || !placeholderHidden || !noLines) {
        console.log("[result] the read-failure state did not render its own distinct message correctly")
        Qt.exit(1)
        return
      }

      // Collapsing again must remove the delegates from layout, matching
      // the "model gated on activityExpanded too" reasoning in Panel.qml's
      // own comment -- not just hide them via `visible`.
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
      var recollapsed = activityRepeater.count === 0 && footer.y <= 60 && !errorMessage.visible
      console.log("[result] recollapsed=" + recollapsed + " repeaterCount=" + activityRepeater.count +
        " footerY=" + footer.y)
      Qt.exit(recollapsed ? 0 : 1)
    }
  }
}
