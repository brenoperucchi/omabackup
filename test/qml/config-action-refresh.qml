// Regression probe for the detached Config/Restore handoff. The launcher
// exits before the terminal-owned TUI does; reopening the panel in between
// must not refresh the old state. Only the TUI completion may do that.
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  property bool opened: true
  property bool configuring: false
  property bool externalBusy: false
  property string externalAction: ""
  property string externalToken: ""
  property int externalGeneration: 0
  property bool refreshed: false
  property bool prematureRefresh: false
  property bool staleCallbackIgnored: false

  function openConfig() {
    configuring = true
    externalBusy = true
    externalAction = "config"
    externalGeneration += 1
    externalToken = String(Date.now()) + "-" + String(externalGeneration)
    opened = false
    launcherProc.running = true
  }

  function finishExternalTui(action, token) {
    if (action !== externalAction || token !== externalToken) {
      staleCallbackIgnored = true
      return
    }
    externalAction = ""
    externalToken = ""
    externalBusy = false
    configuring = false
    refreshed = true
  }

  Process {
    id: launcherProc
    command: ["bash", "-c", "exit 0"]
    onExited: function(code) {
      if (code === 0) tuiProc.running = true
    }
  }

  Process {
    id: tuiProc
    command: ["bash", "-c", "sleep 0.25"]
    onExited: function(code) {
      if (code === 0) finishExternalTui("config", launchedToken)
    }
    property string launchedToken: ""
    onRunningChanged: if (running) launchedToken = externalToken
  }

  Timer {
    interval: 50
    running: true
    repeat: false
    onTriggered: openConfig()
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: finishExternalTui("config", "stale-token")
  }

  Timer {
    interval: 150
    running: true
    repeat: false
    onTriggered: {
      opened = true
      if (refreshed) prematureRefresh = true
    }
  }

  Timer {
    interval: 600
    running: true
    repeat: false
    onTriggered: Qt.exit(!prematureRefresh && staleCallbackIgnored
                         && !configuring && !externalBusy
                         && externalAction === "" && externalToken === "" && refreshed ? 0 : 1)
  }
}
