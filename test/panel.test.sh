# Regressions for Panel.qml, run against real headless QuickShell.
#
# There is no QML test harness in this project, but there does not need to
# be a bespoke one: `QT_QPA_PLATFORM=offscreen qs -p <file>.qml` runs a real
# QuickShell process with no display, which is enough to exercise Process/
# Timer state machines -- exactly the class of bug this file's own probes
# were written against (a timeout message getting overwritten by the very
# process it just killed; a startup Process with no timeout at all). A
# review round found and confirmed both bugs this way, empirically, rather
# than by reading the code and reasoning about QML's signal-delivery order.
#
# A later round corrected this: what cannot be tested headless is
# APPEARANCE (perceived colour, legibility, whether something "reads" as
# secondary), not geometry. A FloatingWindow (not a bare ShellRoot, which
# never runs a layout pass at all) makes positioners really relayout, so
# implicitHeight/x/y are real, measurable numbers -- used below for the
# Config section's collapse and for confirming a MouseArea's click target
# actually has nonzero size, not just that its handler fires in isolation.

it "quickshell is available for QML process/timer probes"
command -v qs >/dev/null 2>&1 && ok || fail "qs (quickshell) not found on PATH -- cannot run these probes"

_qml_probe() {  # _qml_probe <file> -> runs it headless, returns its exit code
    QT_QPA_PLATFORM=offscreen timeout 10 qs -p "$1" >/dev/null 2>&1
}

it "a timed-out Process's timeout message survives its own onExited handler"
_qml_probe test/qml/timeout-message-not-overwritten.qml \
    && ok || fail "the timeout message was overwritten by the killed process's own exit handling"

it "a hung startup resolveProc still ends in cliMissing:true, not silence"
_qml_probe test/qml/resolve-proc-gets-its-own-timeout.qml \
    && ok || fail "a hung resolveProc left cliMissing false -- the widget would stay visible and inert forever"

it "an error message set by a failed operation survives its own trailing refresh()"
_qml_probe test/qml/error-message-survives-followup-refresh.qml \
    && ok || fail "refresh() cleared the error message the operation had just set, one line after setting it"

it "an operation's error also survives the periodic background refresh, not just its own"
_qml_probe test/qml/periodic-refresh-keeps-operation-error.qml \
    && ok || fail "the periodic Timer's own refresh() call cleared an operation error verify can never rediscover"

it "an invisible Grid inside a Column does not occupy layout space, and expanding it does"
_qml_probe test/qml/config-section-collapses-height.qml \
    && ok || fail "the collapsed/expanded Config section did not actually change the column's layout height"

it "restoreCommand() includes --into only for the test-directory target, never for this machine"
_qml_probe test/qml/restore-command-matches-target-mode.qml \
    && ok || fail "the restore command's --into flag did not match the chosen target mode"

it "an unexpected target mode is treated as the safe test-directory target, everywhere"
_qml_probe test/qml/target-mode-polarity-agrees.qml \
    && ok || fail "the displayed target and the actual restore command disagreed on an unexpected mode"

it "an artifact row's click target has real, nonzero geometry"
_qml_probe test/qml/artifact-row-click-area-has-geometry.qml \
    && ok || fail "the artifact row's MouseArea had zero-size geometry -- an invalid anchors.fill inside a Column"
