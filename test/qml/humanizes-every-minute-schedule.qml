// Regression probe for Panel.qml's user-facing schedule humanizer.
import QtQuick
import Quickshell

ShellRoot {
  function humanSchedule(c) {
    if (typeof c !== "string" || c === "") return "not scheduled"
    if (c === "* * * * *" || c === "*/1 * * * *") return "every minute"
    if (c === "*:*:00" || c === "*-*-* *:*:00") return "every minute"
    var m = c.match(/^\*\/(\d+) \* \* \* \*$/)
    if (m) return "every " + m[1] + " min"
    return c
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: Qt.exit(humanSchedule("* * * * *") === "every minute"
                          && humanSchedule("*/1 * * * *") === "every minute"
                          && humanSchedule("*:*:00") === "every minute"
                          && humanSchedule("*-*-* *:*:00") === "every minute"
                          ? 0 : 1)
  }
}
