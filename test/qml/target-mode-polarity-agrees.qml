// Regression probe for Panel.qml's target-mode polarity -- mirrors
// targetPath, chooseTarget()'s --into logic, and restoreCommand()'s --into
// logic (all under "── restore ──" in Panel.qml).
//
// A review round found the three places that read targetMode used two
// different tests: targetPath (what the operator READS) checked
// `=== "home"`, defaulting an unexpected value to the safe preview
// directory; chooseTarget/restoreCommand (what actually WRITES) checked
// `=== "into"`, defaulting an unexpected value to a real-home apply. Not
// reachable today -- only the two target buttons ever set targetMode, and
// selectArtifact() always resets it to "into" -- but the two functions
// that act disagreed with the one the operator reads before deciding,
// which is exactly the "the screen says test directory, the command
// writes home" shape of bug this whole slice exists to prevent. Fixed by
// giving all three the same polarity (`!== "home"` is the safe branch
// everywhere); this probe asserts an unexpected mode value produces the
// SAME target the display would have shown for it.
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/target-mode-polarity-agrees.qml
import QtQuick
import Quickshell

ShellRoot {
  property string cli: "/usr/local/bin/omabackup"
  property string selectedArtifactPath: "/mnt/nas/art.tar.zst"
  property string targetMode: "some-unexpected-value"
  readonly property string targetPath:
    targetMode === "home" ? "/home/operator"
                           : "/home/operator/.local/state/omabackup/restore-preview"

  function restoreCommand() {
    var parts = [cli, "restore", selectedArtifactPath]
    if (targetMode !== "home") parts = parts.concat(["--into", targetPath])
    parts.push("--apply")
    return parts
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: {
      // With an unexpected targetMode, the DISPLAY shows the preview
      // directory (targetPath's own "home" branch is the only dangerous
      // one). The command must agree: --into must be present, pointing at
      // that same path -- never a bare --apply against the real home.
      var cmd = restoreCommand()
      var idx = cmd.indexOf("--into")
      console.log("[result] targetPath=" + targetPath + " cmd=" + JSON.stringify(cmd))
      var agrees = idx !== -1 && cmd[idx + 1] === targetPath
      Qt.exit(agrees ? 0 : 1)
    }
  }
}
