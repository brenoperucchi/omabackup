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
# (found in review of #8 and reproduced with both shapes). Every arm label at
# the dispatch's four-space indent is read instead: a leading `(` and the
# spaces around each `|` are dropped, quotes are taken off, and so are `""`,
# `*` and the hidden `__*` verbs. A comment line is not an arm, and neither is
# a line whose labels are not all a name or a glob (letters, digits, `_`, `-`,
# `.` and `*?[]!`), so prose or a command with a `)` at that indent is not
# taken, while `log-*)` or `self.update)` still is and fails loud.
_help_verbs() {
    awk '
        /^case "\$CMD" in$/ { n = 0; on = 1; next }
        on && /^esac$/      { on = 0; next }
        on && /^    [^ #]/ && match($0, /^    \(?[^()]*\)/) {
            s = substr($0, 5, RLENGTH - 5)
            sub(/^\(/, "", s)
            k = split(s, p, "|")
            for (i = 1; i <= k; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", p[i])
                if (p[i] ~ /^".*"$/ || p[i] ~ /^\047.*\047$/)
                    p[i] = substr(p[i], 2, length(p[i]) - 2)
                if (p[i] !~ /^[][A-Za-z0-9_.*?!-]*$/) next
            }
            for (i = 1; i <= k; i++) v[++n] = p[i]
        }
        END { for (i = 1; i <= n; i++) print v[i] }
    ' "$1" | grep -vE '^(\*|__.*)?$' | sort -u
}
HELP_VERBS="$(_help_verbs "$OB")"
HH="$(mktemp -d)"
HELP_OUT="$(HOME="$HH" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$HH/.state" XDG_RUNTIME_DIR=/nonexistent "$OB" help 2>&1)"

# _help_missing <verbs> <usage>: each verb, internal ones aside, that the usage
# text does not name. _help_extra <verbs> <usage>: each name in the usage text
# that is not a verb. A name is the first word of a line indented by exactly
# two spaces, so the `sync` line's continuation is not one. Every comparison is
# a fixed string and the lists are read line by line, so a label with `.` or a
# glob character is neither a pattern nor expanded against the disk.
_help_named() { printf '%s\n' "$1" | sed -nE 's/^  ([^ ]+)( .*)?$/\1/p'; }
_help_missing() {
    local v named
    named="$(_help_named "$2")"
    while IFS= read -r v; do
        [[ -z "$v" || "$HELP_INTERNAL" == *" $v "* ]] && continue
        printf '%s\n' "$named" | grep -Fqx -- "$v" || printf ' %s' "$v"
    done <<<"$1"
}
_help_extra() {
    local v
    while IFS= read -r v; do
        printf '%s\n' "$1" | grep -Fqx -- "$v" || printf ' %s' "$v"
    done < <(_help_named "$2")
}

it "the verb list could be cut out of the dispatch case"
[[ "$(printf '%s\n' "$HELP_VERBS" | grep -c .)" -ge 15 ]] \
    && ok || fail "found only: $(printf '%s\n' "$HELP_VERBS" | tr '\n' ' ')"

it "the usage text names every verb the dispatch accepts, except the internal ones"
HELP_MISSING="$(_help_missing "$HELP_VERBS" "$HELP_OUT")"
[[ -z "$HELP_MISSING" ]] && ok || fail "not in the usage text:$HELP_MISSING"

it "and every verb it names is one the dispatch accepts"
HELP_EXTRA="$(_help_extra "$HELP_VERBS" "$HELP_OUT")"
[[ -z "$HELP_EXTRA" ]] && ok || fail "named but not dispatched:$HELP_EXTRA"

# Bash takes an arm written with spaces around `|` or before `)`, with a leading
# `(`, or with its label in quotes, and runs it the same. Review 101 showed the
# first awk skipped the spaced and `(` forms in silence, so a verb added that
# way missed the usage text with every check green. A comment is not an arm,
# and review 102 showed that prose or a command at the same indent, with a `)`
# in it, was read as a verb; a label must be a name or a glob. Review 103
# showed that a narrower class dropped a glob or dotted label in silence.
it "an arm with spaces, a leading paren, quotes or its body on the next line is read"
cat >"$HH/dispatch" <<'EOF'
case "$CMD" in
    first) : ;;
esac
case "$CMD" in
    plain) cmd_x ;;
    alias|other) cmd_x ;;
    log-*|dot.ted|x_1-y) cmd_x ;;
    spaced | around ) cmd_x ;;
    (paren) cmd_x ;;
    "quoted"|'single') cmd_x ;;
    twoline)
        cmd_x ;;
    # commented) not an arm
    a line of prose)
    printf '%s\n' 'done)'
    __hidden) cmd_x ;;
    ""|help) cmd_x ;;
    *) cmd_x ;;
esac
EOF
assert_eq "$(_help_verbs "$HH/dispatch" | tr '\n' ' ')" \
    "alias around dot.ted help log-* other paren plain quoted single spaced twoline x_1-y "

# A label can now hold `.` or a glob character, and the checks first took each
# one as a regular expression: `sta.us)` or `status?)` passed as documented by
# the `status` line, and `te*` was expanded against the files in the working
# directory (found in review 104). Both directions compare fixed strings.
it "a verb is matched against the usage text as a string, never as a pattern"
assert_eq "$(_help_missing $'status\nsta.us\nstatus?\nte*' '  status    x')" \
    " sta.us status? te*"

it "and so is a name the usage text gives"
assert_eq "$(_help_extra 'status' $'  status    x\n  sta.us    y')" " sta.us"
