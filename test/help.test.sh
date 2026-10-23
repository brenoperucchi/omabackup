# The usage text names every verb a person can run.
#
# `omabackup help` listed eleven verbs and left out four that the dispatch
# `case` accepts and a person runs by hand: `install` (the README's own setup
# step), `sync`, `bundle` and `push` (what the timers run, and what to run to
# retry one). The list was written by hand and nothing compared it with the
# dispatch, so each verb added since was one more line to forget. The verbs are
# cut out of the real `case "$CMD" in` block, so a verb added there without a
# usage line fails here, unless it is named below as internal on purpose.

OB="$PWD/bin/omabackup"

# Called by the panel, the TUI wrapper or a timer, never typed: each one's
# comment in bin/omabackup says it is left out of the usage text. `__*` verbs
# are hidden by their name.
HELP_INTERNAL=" log-event kill-group "

# Two blocks open with `case "$CMD" in`; the log policy comes first. The
# dispatch is the one whose arms call a cmd_ function.
HELP_VERBS="$(sed -n '/^case "\$CMD" in$/,/^esac$/p' "$OB" \
    | sed -nE 's/^    ([a-z][a-z-]*)\) +.*cmd_[a-z_]+.*/\1/p' | sort -u)"
HH="$(mktemp -d)"
HELP_OUT="$(HOME="$HH" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$HH/.state" XDG_RUNTIME_DIR=/nonexistent "$OB" help 2>&1)"

it "the verb list could be cut out of the dispatch case"
[[ "$(printf '%s\n' "$HELP_VERBS" | grep -c .)" -ge 15 ]] \
    && ok || fail "found only: $(printf '%s ' $HELP_VERBS)"

it "the usage text names every verb the dispatch accepts, except the internal ones"
HELP_MISSING=""
for v in $HELP_VERBS; do
    [[ "$HELP_INTERNAL" == *" $v "* ]] && continue
    printf '%s\n' "$HELP_OUT" | grep -qE "^  $v( |$)" || HELP_MISSING+=" $v"
done
[[ -z "$HELP_MISSING" ]] && ok || fail "not in the usage text:$HELP_MISSING"

it "and every verb it names is one the dispatch accepts"
HELP_EXTRA=""
for v in $(printf '%s\n' "$HELP_OUT" | sed -nE 's/^  ([a-z][a-z-]*) .*/\1/p'); do
    printf '%s\n' "$HELP_VERBS" | grep -qx "$v" || HELP_EXTRA+=" $v"
done
[[ -z "$HELP_EXTRA" ]] && ok || fail "named but not dispatched:$HELP_EXTRA"
