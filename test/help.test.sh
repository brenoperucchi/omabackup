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
# comment in bin/omabackup says it is left out of the usage text. `help` is the
# usage text itself. `__*` verbs are hidden by their name.
HELP_INTERNAL=" log-event kill-group help "

# Two blocks open with `case "$CMD" in`; the log policy comes first and the
# dispatch is the last. The first version of this spec kept only an arm written
# on one line with a single label and a `cmd_` call on that line, so an alias
# (`foo|bar)`) or an arm whose body starts on the next line was skipped, and a
# verb added that way could miss the usage text with both checks still green
# (found in review of #8 and reproduced with both shapes). Every arm label of
# the last block is read instead, split on `|`; only `""`, `*` and the hidden
# `__*` verbs are dropped.
HELP_VERBS="$(awk '
    /^case "\$CMD" in$/ { n = 0; on = 1; next }
    on && /^esac$/      { on = 0; next }
    on && match($0, /^    [^ ()]+\)/) {
        k = split(substr($0, 5, RLENGTH - 5), p, "|")
        for (i = 1; i <= k; i++) v[++n] = p[i]
    }
    END { for (i = 1; i <= n; i++) print v[i] }
' "$OB" | grep -vE '^(""|\*|__.*)$' | sort -u)"
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
