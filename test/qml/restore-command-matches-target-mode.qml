// Regression probe for Panel.qml's restoreCommand() -- mirrors the function
// verbatim (under "── restore ──" in Panel.qml). This is the single most
// safety-critical function in the restore flow: it is both what the plan
// screen PREVIEWS and what openTerminalForRestore() actually launches, by
// design ("the preview and the command launched must be the same string,
// or the preview is theatre"). A bug here could omit --into and point an
// --apply at the real home without the operator ever choosing that.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/restore-command-matches-target-mode.qml
import QtQuick
import Quickshell

ShellRoot {
  property string cli: "/usr/local/bin/omabackup"
  property string selectedArtifactPath: "/mnt/nas/omabackup/omabackup-host-20260101-000000.tar.zst"
  property string targetMode: "into"
  readonly property string targetPath:
    targetMode === "home" ? "/home/operator"
                           : "/home/operator/.local/state/omabackup/restore-preview"

  function restoreCommand() {
    var parts = [cli, "restore", selectedArtifactPath]
    if (targetMode === "into") parts = parts.concat(["--into", targetPath])
    parts.push("--apply")
    return parts
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: {
      var intoCmd = restoreCommand()
      console.log("[into] " + JSON.stringify(intoCmd))
      var intoOk = intoCmd.indexOf("--into") !== -1
                && intoCmd[intoCmd.indexOf("--into") + 1] === targetPath
                && intoCmd[intoCmd.length - 1] === "--apply"
                && intoCmd.indexOf(cli) === 0

      targetMode = "home"
      var homeCmd = restoreCommand()
      console.log("[home] " + JSON.stringify(homeCmd))
      // The one property that matters most: --into must NEVER appear when
      // the operator chose "this machine" -- its presence here would mean
      // a real-home restore silently landed somewhere else instead, or
      // (worse, the reverse bug) a real-home write happened without the
      // operator ever seeing --into omitted as the signal that it would.
      var homeOk = homeCmd.indexOf("--into") === -1
                && homeCmd[homeCmd.length - 1] === "--apply"
                && homeCmd.indexOf(selectedArtifactPath) !== -1

      console.log("[result] intoOk=" + intoOk + " homeOk=" + homeOk)
      Qt.exit((intoOk && homeOk) ? 0 : 1)
    }
  }
}
