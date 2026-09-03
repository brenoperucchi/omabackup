// Regression probe for Panel.qml's title row after the version/Omarchy
// merge (panel reorg round, herdr-ask omabackup-13, corrected in review
// round omabackup-38): headRow (status dot + "OmaBackup" + version button)
// has no fixed width of its own -- it grows to fit its content -- while the
// ToggleSwitch is a sibling anchored independently to the parent Item's
// right edge. Nothing in that pair alone reserves space for the other.
//
// First fix (omabackup-13) anchored the trailing Omarchy-version Text
// between headRow's own right edge and the toggle's left edge
// (elide: Text.ElideRight). Review round omabackup-38 found that alone was
// incomplete: it protects the TEXT, but the version Button now lives
// *inside* headRow as its rightmost child, so headRow itself -- not just
// the text -- could still reach the toggle under a wide enough font-token
// override. Fixed by wrapping headRow + the Omarchy text together in one
// `titleGroup` Item, itself anchored between the parent's left edge and the
// toggle's left edge with `clip: true` -- the common case still elides the
// Omarchy text gracefully (unchanged), and the pathological case (headRow
// itself too wide) degrades to an abrupt clip instead of ever visually
// overlapping the toggle.
//
// This probe proves both the elide contract (the failure mode
// `omabackup-rev-2` traced: a `shell.toml` font-size override widens the
// trailing content without widening the panel -- Style.fontToken() returns
// the raw override, unscaled, while Style.space() -- the panel's own width
// -- scales by a different factor) and the clip backstop for headRow itself.
// Simulated by shrinking the container width directly rather than by wiring
// up the real Style singleton, which is not importable standalone -- same
// "hand-maintained mirror of the real shape" convention this suite already
// uses (see config-section-collapses-height.qml,
// activity-section-collapses-and-shows-lines.qml).
//
// Run with: QT_QPA_PLATFORM=offscreen qs -p test/qml/title-row-version-elides.qml
import QtQuick
import Quickshell

FloatingWindow {
  id: root
  visible: true
  implicitWidth: 500
  implicitHeight: 80

  property bool versionCopied: false
  property string toolVersion: "0.4.0"
  property string omarchyVersion: "4.0.0.alpha"

  Item {
    id: container
    width: 500
    height: 40

    Item {
      id: titleGroup
      anchors.left: parent.left
      anchors.right: toggleSwitch.left
      anchors.rightMargin: 8
      anchors.verticalCenter: parent.verticalCenter
      height: headRow.implicitHeight
      clip: true

      Row {
        id: headRow
        spacing: 6
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter

        Rectangle { width: 8; height: 8; radius: 4; anchors.verticalCenter: parent.verticalCenter }

        Text {
          id: titleText
          text: "OmaBackup"
          font.pixelSize: 18
        }

        Text {
          id: versionButton
          anchors.verticalCenter: parent.verticalCenter
          text: root.versionCopied ? root.toolVersion + "  ✓ copied" : root.toolVersion
          font.pixelSize: 10
        }
      }

      Text {
        id: omarchyText
        anchors.left: headRow.right
        anchors.leftMargin: 6
        anchors.right: parent.right
        anchors.verticalCenter: headRow.verticalCenter
        text: "·  Omarchy " + root.omarchyVersion
        font.pixelSize: 10
        elide: Text.ElideRight
      }
    }

    // anchors.verticalCenter: titleGroup.verticalCenter, not
    // headRow.verticalCenter -- QML anchors only resolve against a parent
    // or a true sibling, and headRow is titleGroup's child, not this
    // Rectangle's sibling, once titleGroup exists. Review round
    // omabackup-39 caught the stale reference at this exact spot: it
    // failed silently at runtime ("Cannot anchor to an item that isn't a
    // parent or sibling"), leaving the toggle unaligned, while this
    // probe's own horizontal-only assertions stayed green regardless.
    Rectangle {
      id: toggleSwitch
      width: 36
      height: 18
      anchors.right: parent.right
      anchors.verticalCenter: titleGroup.verticalCenter
    }
  }

  function noOverlap() {
    // The trailing text's own right edge (its x plus its actual painted
    // width, contentWidth -- NOT the anchored `width`, which stays fixed
    // at the reserved budget even when elided) must never reach the
    // toggle's left edge. paintedWidth is what elide actually shrinks.
    // titleGroup's coordinate space is the same as container's (both plain
    // Items, no transforms), so titleGroup-relative and container-relative
    // x values compare directly.
    var textRight = titleGroup.x + omarchyText.x + omarchyText.paintedWidth
    var toggleLeft = toggleSwitch.x
    return textRight <= toggleLeft + 0.5  // small epsilon for float rounding
  }

  function groupNeverOverlapsToggle() {
    // Guaranteed by the anchors.right: toggleSwitch.left construction
    // itself, but asserted explicitly (not just trusted) -- this is the
    // backstop the clip depends on: titleGroup's own right edge must never
    // cross the toggle's left edge, regardless of what headRow's content
    // does inside it.
    return (titleGroup.x + titleGroup.width) <= toggleSwitch.x + 0.5
  }

  function toggleVerticallyCentered() {
    // Proves the anchor actually resolved, not just that it was written.
    // A silently-rejected anchor ("Cannot anchor to an item that isn't a
    // parent or sibling" -- exactly what headRow.verticalCenter produced
    // here before review round omabackup-39) leaves the item at its
    // default y (0, top-anchored in this container), not centered --
    // this would catch that even though every horizontal assertion above
    // stays green regardless, which is exactly how the real bug hid.
    var toggleCenterY = toggleSwitch.y + toggleSwitch.height / 2
    var groupCenterY = titleGroup.y + titleGroup.height / 2
    // Epsilon wider than the strict half-pixel used elsewhere in this file:
    // Qt Quick's anchor engine rounds a `verticalCenter` resolution to the
    // nearest whole pixel to avoid blurry sub-pixel rendering, and this
    // fixture's own odd/even height mismatch (titleGroup ends up 21px,
    // toggleSwitch is a fixed 18px) makes that rounding land up to 1px off
    // a raw floating-point half-sum -- confirmed empirically, not assumed.
    // A genuinely broken/rejected anchor (the actual bug this checks for)
    // leaves the item at its unrelated default position, tens of pixels
    // off, not within a rounding error -- 1.5px stays a real discriminator.
    return Math.abs(toggleCenterY - groupCenterY) < 1.5
  }

  Timer {
    interval: 100
    running: true
    repeat: false
    onTriggered: {
      // Phase 1: wide container, short version -- everything fits, nothing
      // should even need to elide.
      var elidedWide = omarchyText.truncated
      var overlapOkWide = noOverlap()
      var groupOkWide = groupNeverOverlapsToggle()
      var vCenterOkWide = toggleVerticallyCentered()
      console.log("[phase1] elided=" + elidedWide + " overlapOk=" + overlapOkWide +
        " groupOk=" + groupOkWide + " vCenterOk=" + vCenterOkWide + " omarchyX=" + omarchyText.x +
        " omarchyPaintedWidth=" + omarchyText.paintedWidth + " toggleX=" + toggleSwitch.x +
        " toggleY=" + toggleSwitch.y + " toggleHeight=" + toggleSwitch.height +
        " titleGroupY=" + titleGroup.y + " titleGroupHeight=" + titleGroup.height +
        " headRowImplicitHeight=" + headRow.implicitHeight)
      if (elidedWide || !overlapOkWide || !groupOkWide || !vCenterOkWide) {
        console.log("[result] the wide/default case should not need to elide, already overlaps, or the toggle is not vertically centered")
        Qt.exit(1)
        return
      }
      phase2.start()
    }
  }

  Timer {
    id: phase2
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      // Phase 2: the versionCopied state widens the button label
      // ("0.4.0  ✓ copied") -- still must not overlap.
      root.versionCopied = true
      phase2check.start()
    }
  }

  Timer {
    id: phase2check
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var overlapOk = noOverlap()
      var groupOk = groupNeverOverlapsToggle()
      var vCenterOk = toggleVerticallyCentered()
      console.log("[phase2] versionCopied=true overlapOk=" + overlapOk + " groupOk=" + groupOk +
        " vCenterOk=" + vCenterOk + " omarchyX=" + omarchyText.x + " omarchyPaintedWidth=" + omarchyText.paintedWidth +
        " toggleX=" + toggleSwitch.x + " toggleY=" + toggleSwitch.y)
      if (!overlapOk || !groupOk || !vCenterOk) {
        console.log("[result] the versionCopied state overlapped the toggle or broke its vertical centering")
        Qt.exit(1)
        return
      }
      root.versionCopied = false
      phase3.start()
    }
  }

  Timer {
    id: phase3
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      // Phase 3: simulate the traced failure mode -- available space tight
      // enough that the Omarchy text WOULD overlap the toggle without
      // eliding. Shrinking the container directly stands in for "a
      // shell.toml font override widened the content without widening the
      // panel." 260px specifically leaves headRow itself (~141-190px
      // depending on versionCopied) comfortably intact -- this phase
      // targets the trailing text's own budget, not the pathological case
      // phase 4 covers below.
      container.width = 260
      phase3check.start()
    }
  }

  Timer {
    id: phase3check
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var elidedNarrow = omarchyText.truncated
      var overlapOkNarrow = noOverlap()
      var groupOkNarrow = groupNeverOverlapsToggle()
      console.log("[phase3] narrow width=260 elided=" + elidedNarrow + " overlapOk=" + overlapOkNarrow +
        " groupOk=" + groupOkNarrow + " omarchyX=" + omarchyText.x +
        " omarchyPaintedWidth=" + omarchyText.paintedWidth + " toggleX=" + toggleSwitch.x)
      if (!elidedNarrow || !overlapOkNarrow || !groupOkNarrow) {
        console.log("[result] the trailing text did not elide or overlapped the toggle")
        Qt.exit(1)
        return
      }
      // Phase 4: pathologically narrow -- even headRow's own content
      // (dot + title + button) alone no longer fits before the toggle.
      // This is the exact gap review round omabackup-38 found: the FIRST
      // fix protected the text but not headRow itself. The clip on
      // titleGroup is what closes it now -- proven here by asserting
      // titleGroup's own bounds still respect the toggle (never overlap)
      // and that clipping is actually enabled, not just present in source.
      container.width = 150
      phase4.start()
    }
  }

  Timer {
    id: phase4
    interval: 100
    running: false
    repeat: false
    onTriggered: {
      var groupOkPathological = groupNeverOverlapsToggle()
      var clipEnabled = titleGroup.clip === true
      // Review round omabackup-39's own P3: proving clip is *enabled* is
      // not the same as proving it was *exercised*. If headRow's content
      // happened to still fit inside titleGroup at this width, the clip
      // would never actually crop anything and this phase would pass for
      // the wrong reason. Assert the precondition explicitly: headRow's
      // own implicit width must genuinely exceed what titleGroup has to
      // give it, or this phase proves nothing.
      var clipActuallyNeeded = headRow.implicitWidth > titleGroup.width
      var vCenterOkPathological = toggleVerticallyCentered()
      console.log("[phase4] pathological width=150 groupOk=" + groupOkPathological +
        " clipEnabled=" + clipEnabled + " clipActuallyNeeded=" + clipActuallyNeeded +
        " vCenterOk=" + vCenterOkPathological + " headRowImplicitWidth=" + headRow.implicitWidth +
        " titleGroupWidth=" + titleGroup.width + " toggleX=" + toggleSwitch.x + " toggleY=" + toggleSwitch.y)
      if (!clipActuallyNeeded) {
        console.log("[result] headRow's content still fit inside titleGroup at this width -- the clip was never exercised, this phase proves nothing")
        Qt.exit(1)
        return
      }
      // The whole point of this round's fix: titleGroup's own bounds must
      // never cross the toggle regardless of how wide headRow's content
      // wants to be, clip must actually be on so that width contract is
      // what gets painted (not just what is anchored), and the toggle
      // must stay vertically centered throughout.
      Qt.exit((groupOkPathological && clipEnabled && vCenterOkPathological) ? 0 : 1)
    }
  }
}
