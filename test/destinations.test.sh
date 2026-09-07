# Regressions for destinations and `omabackup push` (lib/destinations.sh).
#
# Two things here are dangerous in a way nothing else in this tool is: deletion
# (retention), and a config file naming paths on a machine nobody is watching.
# Most of these specs exist to pin down what must NOT happen.
#
# `github` is a destination driver like the others rather than a step inside
# `sync`, because DESIGN.md §3 defines it as "commit + push" and pushing is the
# slow, fallible half. A NAS being down must never change whether the commit
# happened.

OB="$(realpath "$PWD/bin/omabackup")"
GROUPS_FILE="$(realpath "$PWD/groups.default.json")"

_dest_env() {  # _dest_env <home> <repo> <args...>
    local h="$1" r="$2"; shift 2
    HOME="$h" OMABACKUP_GROUPS="$GROUPS_FILE" OMABACKUP_STATE="$h/.state" \
        OMABACKUP_REPO="$r" OMABACKUP_DESTINATIONS="$h/destinations.json" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

_dest_repo() {
    local r="$1"
    mkdir -p "$r/configs/app"
    git init -q "$r"; git -C "$r" config user.email t@t; git -C "$r" config user.name t
    printf 'one\n' >"$r/configs/app/f.txt"
    git -C "$r" add -A && git -C "$r" commit -qm one
}

_state_of() { jq -r "$2" "$1/.state/destinations/$3.json" 2>/dev/null; }

# ── the config is validated the way the group manifest is ────────────────────
DH="$(mktemp -d)"; DR="$DH/repo"; _dest_repo "$DR"
cat >"$DH/destinations.json" <<'JSON'
{"schemaVersion":1,"destinations":[
 {"id":"nas","type":"dir","path":"/tmp/x","keep":3,"fieldNobodyImplemented":true}]}
JSON
DOUT="$(_dest_env "$DH" "$DR" push)"

it "an unknown field in destinations.json aborts instead of being ignored"
assert_contains "$DOUT" "fieldNobodyImplemented"

cat >"$DH/destinations.json" <<'JSON'
{"schemaVersion":1,"destinations":[{"id":"nas","type":"telepathy","path":"/tmp/x","keep":3}]}
JSON

it "an unknown destination type aborts"
assert_contains "$(_dest_env "$DH" "$DR" push)" "telepathy"

cat >"$DH/destinations.json" <<'JSON'
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"/tmp/x","keep":0}]}
JSON

it "keep:0 is refused -- retention that keeps nothing is not retention"
assert_contains "$(_dest_env "$DH" "$DR" push)" "keep"

cat >"$DH/destinations.json" <<'JSON'
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"/tmp/x","keep":18446744073709551617}]}
JSON

it "an oversized retention is refused before prune arithmetic can wrap"
assert_contains "$(_dest_env "$DH" "$DR" push)" "supported integer range"

# A hand-edited destinations file must satisfy the same path/id boundary as
# config. Otherwise a malformed id can create nested state paths, and a
# relative path makes push write from whichever directory invoked the timer.
DH_LEGACY="$(mktemp -d)"; DR_LEGACY="$DH_LEGACY/repo"; _dest_repo "$DR_LEGACY"
cat >"$DH_LEGACY/destinations.json" <<'JSON'
{"schemaVersion":1,"destinations":[
 {"id":"legacy/id","type":"dir","path":"relative-target","keep":1}]}
JSON
LEGACY_OUT="$(cd "$DH_LEGACY" && _dest_env "$DH_LEGACY" "$DR_LEGACY" push)"
LEGACY_RC=$?

it "push rejects legacy destination ids and relative paths before writing"
[[ $LEGACY_RC -ne 0 ]] && ok || fail "push accepted a legacy destination outside config invariants"
assert_contains "$LEGACY_OUT" "what push cannot honor"
assert_not_contains "$LEGACY_OUT" "sent"

# Explicit targets are user input too. The state filename must never be a path
# traversal surface, even when destinations.json itself is valid.
DH_TRAVERSAL="$(mktemp -d)"; DR_TRAVERSAL="$DH_TRAVERSAL/repo"; _dest_repo "$DR_TRAVERSAL"
printf '%s\n' '{"schemaVersion":1,"destinations":[]}' >"$DH_TRAVERSAL/destinations.json"
mkdir -p "$DH_TRAVERSAL/.state/destinations"
printf '%s\n' 'keep-me' >"$DH_TRAVERSAL/.state/escape.json"
TRAVERSAL_OUT="$(_dest_env "$DH_TRAVERSAL" "$DR_TRAVERSAL" push ../escape)"
TRAVERSAL_RC=$?

it "push rejects traversal in an explicit destination before state writes"
[[ $TRAVERSAL_RC -ne 0 ]] && ok || fail "push accepted a traversal destination"
assert_eq "$(cat "$DH_TRAVERSAL/.state/escape.json")" "keep-me"

DH_ROOT_FIELD="$(mktemp -d)"; DR_ROOT_FIELD="$DH_ROOT_FIELD/repo"; _dest_repo "$DR_ROOT_FIELD"
mkdir -p "$DH_ROOT_FIELD/nas"
cat >"$DH_ROOT_FIELD/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$DH_ROOT_FIELD/nas","keep":1}],"enabled":false}
JSON
ROOT_FIELD_OUT="$(_dest_env "$DH_ROOT_FIELD" "$DR_ROOT_FIELD" push nas)"
ROOT_FIELD_RC=$?

it "push rejects unknown root fields instead of ignoring them"
[[ $ROOT_FIELD_RC -ne 0 ]] && ok || fail "push accepted an unknown destinations root field"
assert_contains "$ROOT_FIELD_OUT" "enabled"
assert_not_contains "$ROOT_FIELD_OUT" "sent"
[[ -z "$(find "$DH_ROOT_FIELD/nas" -maxdepth 1 -name 'omabackup-*.tar.zst' -print -quit)" ]] \
    && ok || fail "push wrote a bundle from an invalid destinations document"

DH_GITHUB_DUP="$(mktemp -d)"; DR_GITHUB_DUP="$DH_GITHUB_DUP/repo"; _dest_repo "$DR_GITHUB_DUP"
GITHUB_DUP_REMOTE="$DH_GITHUB_DUP/remote.git"; git init -q --bare "$GITHUB_DUP_REMOTE"
git -C "$DR_GITHUB_DUP" remote add origin "$GITHUB_DUP_REMOTE"
cat >"$DH_GITHUB_DUP/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"github","type":"dir","path":"$DH_GITHUB_DUP/pretend-github","keep":1}]}
JSON
GITHUB_DUP_OUT="$(_dest_env "$DH_GITHUB_DUP" "$DR_GITHUB_DUP" push)"

it "rejects a legacy github destination before it can duplicate the implicit origin"
assert_contains "$GITHUB_DUP_OUT" "implicit"
assert_eq "$(git -C "$GITHUB_DUP_REMOTE" rev-list --all --count 2>/dev/null)" "0"

# ── a dir destination receives the bundle ────────────────────────────────────
DH2="$(mktemp -d)"; DR2="$DH2/repo"; _dest_repo "$DR2"
DNAS="$DH2/nas"
cat >"$DH2/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$DNAS","keep":2}]}
JSON
_dest_env "$DH2" "$DR2" push nas >/dev/null

it "push copies the bundle into the destination directory"
assert_eq "$(find "$DNAS" -maxdepth 1 -name 'omabackup-*.tar.zst' | wc -l)" "1"

it "and the copy is a real bundle, restorable on its own"
DB="$(find "$DNAS" -maxdepth 1 -name 'omabackup-*.tar.zst' | head -1)"
DX="$(mktemp -d)"; tar -C "$DX" -xf <(zstd -dc "$DB") 2>/dev/null
DC="$(mktemp -d)/out"; git clone -q "$DX/repo.bundle" "$DC" 2>/dev/null
assert_contains "$(git -C "$DC" show HEAD:configs/app/f.txt 2>/dev/null)" "one"

it "the destination is stamped, so retention knows it owns the directory"
[[ -f "$DNAS/.omabackup-destination" ]] && ok || fail "no stamp file written"

it "success is recorded in the destination's own state file"
[[ -n "$(_state_of "$DH2" '.lastSuccess' nas)" ]] && ok || fail "no lastSuccess recorded"

it "and a successful destination carries no error"
assert_eq "$(_state_of "$DH2" '.lastError // ""' nas)" ""

# ── retention deletes only what it owns ──────────────────────────────────────
# A NAS folder is shared with other data and with other machines' bundles.
DH3="$(mktemp -d)"; DR3="$DH3/repo"; _dest_repo "$DR3"
DN3="$DH3/nas"; mkdir -p "$DN3"
HOSTN="$(hostname)"
printf 'stamped\n' >"$DN3/.omabackup-destination"
printf 'x\n' >"$DN3/omabackup-$HOSTN-20200101-000000.tar.zst"   # ours, old
printf 'x\n' >"$DN3/omabackup-$HOSTN-20200102-000000.tar.zst"   # ours, newer
printf 'x\n' >"$DN3/omabackup-otherbox-20200101-000000.tar.zst" # another machine
printf 'x\n' >"$DN3/notes.txt"                                   # not ours at all
cat >"$DH3/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$DN3","keep":1}]}
JSON
_dest_env "$DH3" "$DR3" push nas >/dev/null

it "retention keeps only the newest N of this host's bundles"
assert_eq "$(find "$DN3" -maxdepth 1 -name "omabackup-$HOSTN-*.tar.zst" | wc -l)" "1"

it "and the one it kept is the newest, not whatever mtime said"
[[ ! -e "$DN3/omabackup-$HOSTN-20200101-000000.tar.zst" ]] && ok || fail "deleted the wrong one"

it "another machine's bundle in the same folder is untouched"
[[ -f "$DN3/omabackup-otherbox-20200101-000000.tar.zst" ]] && ok || fail "deleted another host's backup"

it "an unrelated file in the same folder is untouched"
[[ -f "$DN3/notes.txt" ]] && ok || fail "deleted a file that was never ours"

# ── an unstamped directory is never pruned ───────────────────────────────────
# This is the rule that turns "wrong path in a config file" from data loss into
# a no-op with an error.
DH4="$(mktemp -d)"; DR4="$DH4/repo"; _dest_repo "$DR4"
DN4="$DH4/somebodys-documents"; mkdir -p "$DN4"
printf 'x\n' >"$DN4/omabackup-$HOSTN-20200101-000000.tar.zst"
printf 'x\n' >"$DN4/omabackup-$HOSTN-20200102-000000.tar.zst"
# Called directly, with no stamp anywhere: the point is that prune itself
# refuses, not that push happens to stamp the directory before reaching it.
DPRUNE="$(OMABACKUP_ROOT="$PWD" bash -c '
    source lib/bundle.sh; source lib/destinations.sh
    prune_bundles "$1" "$2" 1 2>&1' _ "$DN4" "$HOSTN")"

it "pruning a directory with no stamp deletes nothing"
assert_eq "$(find "$DN4" -maxdepth 1 -name 'omabackup-*.tar.zst' | wc -l)" "2"

it "and says why instead of failing silently"
assert_contains "$DPRUNE" "stamp"

# ── one destination failing does not take the others down ────────────────────
DH5="$(mktemp -d)"; DR5="$DH5/repo"; _dest_repo "$DR5"
DGOOD="$DH5/good"
cat >"$DH5/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[
 {"id":"broken","type":"dir","path":"/proc/cannot/write/here","keep":2},
 {"id":"good","type":"dir","path":"$DGOOD","keep":2}]}
JSON
DOUT5="$(_dest_env "$DH5" "$DR5" push)"
DRC5=$?

it "a destination that cannot be written records an error"
[[ -n "$(_state_of "$DH5" '.lastError // ""' broken)" ]] && ok || fail "no error recorded for the broken destination"

it "and gets a backoff so the timer stops hammering it"
[[ "$(_state_of "$DH5" '.nextAttemptAt // 0' broken)" -gt 0 ]] && ok || fail "no backoff recorded"

it "while the healthy destination still received its bundle"
assert_eq "$(find "$DGOOD" -maxdepth 1 -name 'omabackup-*.tar.zst' 2>/dev/null | wc -l)" "1"

it "push reports overall failure rather than a cheerful zero"
[[ $DRC5 -ne 0 ]] && ok || fail "push exited 0 with a destination in error"

# ── backoff is honoured by the timer, ignored by a human ─────────────────────
it "a destination still in backoff is skipped by a bare push"
assert_contains "$(_dest_env "$DH5" "$DR5" push)" "backoff"

it "but naming it explicitly retries immediately"
assert_not_contains "$(_dest_env "$DH5" "$DR5" push broken)" "backoff"

# ── github is a driver, not a step inside sync ───────────────────────────────
DH6="$(mktemp -d)"; DR6="$DH6/repo"; _dest_repo "$DR6"
DREMOTE="$DH6/remote.git"; git init -q --bare "$DREMOTE"
git -C "$DR6" remote add origin "$DREMOTE"
cat >"$DH6/destinations.json" <<'JSON'
{"schemaVersion":1,"destinations":[]}
JSON
_dest_env "$DH6" "$DR6" push github >/dev/null

it "the github driver actually pushes -- the half sync never did"
assert_eq "$(git -C "$DREMOTE" rev-list --all --count 2>/dev/null)" "1"

it "and records the push in its state file"
[[ -n "$(_state_of "$DH6" '.lastSuccess' github)" ]] && ok || fail "no lastSuccess for github"

# A remote URL may contain a credential, and a failed Git transport commonly
# repeats that URL in stderr. `_push_github` captures stderr as its destination
# detail, so this fixture makes sure the captured detail cannot become a
# persistent lastError or a terminal leak.
DH6E="$(mktemp -d)"; DR6E="$DH6E/repo"; _dest_repo "$DR6E"
git -C "$DR6E" remote add origin 'https://breno:ghp_ERROR_TOKEN@github.com/user/dotfiles.git'
printf '{"schemaVersion":1,"destinations":[]}\n' >"$DH6E/destinations.json"
GH_FAIL_BIN="$DH6E/fake-bin"; mkdir -p "$GH_FAIL_BIN"
REAL_GIT="$(command -v git)"
cat >"$GH_FAIL_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    printf "fatal: unable to access 'https://breno:ghp_ERROR_TOKEN@github.com/user/dotfiles.git/': network down\\n"
    exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GH_FAIL_BIN/git"
GH_ERROR_OUT="$(PATH="$GH_FAIL_BIN:$PATH" HOME="$DH6E" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$DH6E/.state" OMABACKUP_REPO="$DR6E" \
    OMABACKUP_DESTINATIONS="$DH6E/destinations.json" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" push github 2>&1)"

it "redacts credentials from a failed GitHub push before terminal or state output"
assert_not_contains "$GH_ERROR_OUT" "ghp_ERROR_TOKEN"
assert_not_contains "$(_state_of "$DH6E" '.lastError.message // ""' github)" "ghp_ERROR_TOKEN"

GH_CONTROL_BIN="$DH6E/fake-control-bin"; mkdir -p "$GH_CONTROL_BIN"
cat >"$GH_CONTROL_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    printf '\033[2J\033[31mnetwork down\033[0m\n'
    exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GH_CONTROL_BIN/git"
GH_CONTROL_OUT="$(PATH="$GH_CONTROL_BIN:$PATH" HOME="$DH6E" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$DH6E/.state-control" OMABACKUP_REPO="$DR6E" \
    OMABACKUP_DESTINATIONS="$DH6E/destinations.json" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" push github 2>&1)"

# Round omabackup-43: git's own output is no longer surfaced live at all
# (see _push_github's own comment for why three rounds of pipe-order
# tuning could not make memory-bound + credential-safe + live-diagnostic
# hold simultaneously, and the user's own call to drop the third
# property). This test's original concern -- git's own control characters
# must never reach a terminal unsanitized -- now applies to the LOG entry
# _push_github writes instead, since that is the only place git's own
# text still goes.
it "the terminal push failure message is now the fixed, generic form -- git's own text does not reach it"
assert_not_contains "$GH_CONTROL_OUT" "network down"
assert_contains "$GH_CONTROL_OUT" "see log for details"

it "sanitizes Git transport controls before writing a push failure to the log"
GH_CONTROL_LOG="$DH6E/.state-control/log/omabackup-$(date +%F).log"
[[ -f "$GH_CONTROL_LOG" ]] && ok || fail "expected a log entry for the failed push at $GH_CONTROL_LOG"
GH_CONTROL_LINE="$(command grep -F 'network down' -- "$GH_CONTROL_LOG" || true)"
assert_not_contains "$GH_CONTROL_LINE" $'\033'
assert_contains "$GH_CONTROL_LINE" "network down"

# ── review round omabackup-43 (both reviewers): three prior designs each
# leaked a credential through a different mechanism -- swept across the
# exact cap range where each one broke, to prove this design does not ──────
#
# Round omabackup-44 (both reviewers, independently): this sweep originally
# inspected `$GHSWEEP_OUT` (the CLI's own stdout) and `.lastError.message`
# -- but the round-43 redesign already made both of those safe BY
# CONSTRUCTION (the terminal only ever prints the fixed generic string; see
# "the terminal push failure message is now the fixed, generic form" above).
# The sweep passed at every cap while the real bug -- the truncation guard
# using `${#raw}` instead of the file's own `stat` size, so it never fired
# on git's always-newline-terminated output -- put the full token in the
# LOG at caps 33-37 the whole time. Fixed the same way the guard itself
# was fixed: inspect where git's text actually goes now.
GHSWEEPH="$(mktemp -d)"; GHSWEEPR="$GHSWEEPH/repo"; _dest_repo "$GHSWEEPR"
git -C "$GHSWEEPR" remote add origin 'https://example.invalid/nonexistent.git'
printf '{"schemaVersion":1,"destinations":[]}\n' >"$GHSWEEPH/destinations.json"
GHSWEEP_BIN="$GHSWEEPH/fake-bin"; mkdir -p "$GHSWEEP_BIN"
cat >"$GHSWEEP_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    printf "fatal: 'https://u:ghp_FULLTOKEN@github.com/a/b.git'\\n"
    exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GHSWEEP_BIN/git"
GHSWEEP_LEAKED=0
GHSWEEP_LOGGED_REDACTED=0
for GHSWEEP_CAP in 5 10 20 30 33 34 35 36 37 38 39 40 41 42 50 60 100; do
    PATH="$GHSWEEP_BIN:$PATH" HOME="$GHSWEEPH" OMABACKUP_GROUPS="$PWD/groups.default.json" \
        OMABACKUP_STATE="$GHSWEEPH/.state-$GHSWEEP_CAP" OMABACKUP_REPO="$GHSWEEPR" \
        OMABACKUP_DESTINATIONS="$GHSWEEPH/destinations.json" XDG_RUNTIME_DIR=/nonexistent \
        OMABACKUP_PUSH_OUTPUT_MAX_BYTES="$GHSWEEP_CAP" "$OB" push github >/dev/null 2>&1
    GHSWEEP_LOG="$GHSWEEPH/.state-$GHSWEEP_CAP/log/omabackup-$(date +%F).log"
    if [[ -f "$GHSWEEP_LOG" ]]; then
        command grep -qF 'ghp_FULLTOKEN' -- "$GHSWEEP_LOG" && GHSWEEP_LEAKED="$GHSWEEP_CAP"
        command grep -qF 'github.com/a/b.git' -- "$GHSWEEP_LOG" && GHSWEEP_LOGGED_REDACTED=1
    fi
done

it "no cap in the 5-100 byte range leaks the credential token into the log, through the real CLI"
[[ "$GHSWEEP_LEAKED" == 0 ]] && ok || fail "credential leaked into the log at cap=$GHSWEEP_LEAKED"

it "the logging path is genuinely exercised -- at least one cap preserves the redacted diagnostic"
[[ "$GHSWEEP_LOGGED_REDACTED" == 1 ]] && ok || fail "expected at least one cap to log the redacted (credential-free) URL, proving the log write path actually ran"

# ── review round omabackup-43 (`omabackup-rev`): head -c on git's own live
# stdout could cut git itself off via SIGPIPE before it finishes writing --
# a completed marker written by git AFTER a lot of chatter proves git ran
# to natural completion despite a cap much smaller than its own output ────
GHDRAINH="$(mktemp -d)"; GHDRAINR="$GHDRAINH/repo"; _dest_repo "$GHDRAINR"
git -C "$GHDRAINR" remote add origin 'https://example.invalid/nonexistent.git'
GHDRAIN_BIN="$GHDRAINH/fake-bin"; mkdir -p "$GHDRAIN_BIN"
GHDRAIN_MARKER="$(mktemp -u)"
cat >"$GHDRAIN_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    for i in \$(seq 1 400); do printf 'remote: progress chatter line %d\n' "\$i"; done
    printf 'reached-the-end\n' >"$GHDRAIN_MARKER"
    exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GHDRAIN_BIN/git"
rm -f "$GHDRAIN_MARKER"
PATH="$GHDRAIN_BIN:$PATH" OMABACKUP_REPO="$GHDRAINR" OMABACKUP_PUSH_OUTPUT_MAX_BYTES=100 bash -c '
    source lib/destinations.sh
    _log_write() { :; }
    _push_github >/dev/null
'

it "git itself is never cut off mid-write by a small output cap -- it always runs to its own natural completion"
[[ -f "$GHDRAIN_MARKER" ]] && ok || fail "expected git's own completion marker to exist; a cap that interrupts git via SIGPIPE would prevent it from ever being written"
rm -f "$GHDRAIN_MARKER"

# ── review round omabackup-43 (`omabackup-rev`): unvalidated arithmetic on
# a user-supplied cap can silently reproduce the exact head-c-negative-count
# bug this project already closed once for OMABACKUP_RESTORE_MAX_BYTES ─────
GHOVERFLOW_VAL="$(OMABACKUP_PUSH_OUTPUT_MAX_BYTES=18446744073709551614 bash -c '
    source lib/destinations.sh
    printf %s "$DEST_PUSH_OUTPUT_MAX_BYTES"
')"

it "an OMABACKUP_PUSH_OUTPUT_MAX_BYTES near the 64-bit boundary falls back to the safe default instead of wrapping negative"
assert_eq "$GHOVERFLOW_VAL" "8192"

mkdir -p "$DH6E/.state/destinations"
printf '{"schemaVersion":1,"id":"github","lastError":{"at":"now","message":"old https://breno:ghp_ERROR_TOKEN@github.com/user/dotfiles.git error"}}\n' \
    >"$DH6E/.state/destinations/github.json"
GH_OLD_STATE="$(_dest_env "$DH6E" "$DR6E" status --json)"

it "redacts credentials already present in a legacy destination state"
assert_not_contains "$GH_OLD_STATE" "ghp_ERROR_TOKEN"

# ── review round omabackup-41 (`omabackup-rev`): truncating output before
# redacting it can leak a credential fragment when the cut falls inside the
# URL's own userinfo ────────────────────────────────────────────────────────
# dest_redact_output's own regex requires the `scheme://` prefix to
# recognize a credential at all -- a truncation that removes that prefix
# while keeping `TOKEN@host/path` leaves the fragment unredacted. A long
# enough failure message ahead of the real error (git's own verbose output,
# or a wrapping shell's own noise) is all it takes.
# Found by review (round omabackup-42, `omabackup-rev`): the FIRST version of
# this test used an 8000-byte prefix under an 8192-byte cap, so the whole
# credentialed URL (~58 bytes) always fit inside what `tail -c` keeps -- it
# passed against BOTH the fixed order and the original vulnerable
# tail-then-redact order, proving nothing. The prefix and cap below are
# chosen precisely, not roughly: 500 bytes of noise + the exact URL below
# sum to 558 bytes; a 40-byte cap keeps only `CRETTOKEN@example.com/repo:
# fatal error\n` -- inside the token, past the `https://user:` prefix
# `dest_redact_output`'s own regex needs to recognize a credential at all.
# Confirmed live before landing this: run against the OLD
# `tail -c | dest_redact_output` order, this exact fixture leaks
# `CRETTOKEN` in the clear; against the fixed order, it does not.
GHTRUNCH="$(mktemp -d)"; GHTRUNCR="$GHTRUNCH/repo"; _dest_repo "$GHTRUNCR"
git -C "$GHTRUNCR" remote add origin 'https://example.invalid/nonexistent.git'
printf '{"schemaVersion":1,"destinations":[]}\n' >"$GHTRUNCH/destinations.json"
GHTRUNC_BIN="$GHTRUNCH/fake-bin"; mkdir -p "$GHTRUNC_BIN"
cat >"$GHTRUNC_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    printf '%s' "\$(head -c 500 /dev/zero | tr '\\0' x)"
    printf 'https://user:TOPSECRETTOKEN@example.com/repo: fatal error\\n'
    exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GHTRUNC_BIN/git"
PATH="$GHTRUNC_BIN:$PATH" HOME="$GHTRUNCH" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$GHTRUNCH/.state" OMABACKUP_REPO="$GHTRUNCR" \
    OMABACKUP_DESTINATIONS="$GHTRUNCH/destinations.json" XDG_RUNTIME_DIR=/nonexistent \
    OMABACKUP_PUSH_OUTPUT_MAX_BYTES=40 "$OB" push github >/dev/null 2>&1

# Round omabackup-44 (both reviewers, independently): the terminal and
# .lastError.message are now safe by construction (round-43's redesign),
# so asserting against them here proves nothing about redaction -- the log
# is the only surface git's own text still reaches. Checked there instead.
GHTRUNC_LOG="$GHTRUNCH/.state/log/omabackup-$(date +%F).log"
GHTRUNC_LOG_CONTENT="$([[ -f "$GHTRUNC_LOG" ]] && cat -- "$GHTRUNC_LOG" || printf '')"

it "a credential is redacted even when it sits inside output that would otherwise be truncated mid-URL"
assert_not_contains "$GHTRUNC_LOG_CONTENT" "TOPSECRETTOKEN"
assert_not_contains "$GHTRUNC_LOG_CONTENT" "CRETTOKEN"

# ── review round omabackup-41 (`omabackup-rev-2`): the push's own failure
# detection silently depended on the caller's `pipefail` setting ───────────
# With `pipefail` off, `tail` (the pipe's own last stage) almost never fails
# on its own, so `$?` reflected `tail`'s harmless success instead of a
# genuinely timed-out `git`. `bin/omabackup:9` sets `set -uo pipefail`
# globally today, so this was never live in production -- but `_push_github`
# itself should not depend on that global staying true forever, the same
# self-contained standard `_artifact_manifest_file` already holds itself to.
GHPFH="$(mktemp -d)"; GHPFR="$GHPFH/repo"; _dest_repo "$GHPFR"
git -C "$GHPFR" remote add origin 'https://example.invalid/nonexistent.git'
GHPF_BIN="$GHPFH/fake-bin"; mkdir -p "$GHPF_BIN"
cat >"$GHPF_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    sleep 30
    exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GHPF_BIN/git"
# _push_github's own stdout ("0" on success, its error text on failure) must
# be redirected away here -- found by review (round omabackup-42,
# `omabackup-rev`): capturing it inline ahead of the trailing `printf %s $?`
# concatenates the two with no separator, so a SUCCESS ("0" printed by the
# function) followed by rc=0 ("0" printed by `printf`) produced the string
# "00" -- which `[[ "$GHPF_RC" != 0 ]]` reads as "not equal to the string 0"
# and passes, on exactly the false-success this test exists to catch.
GHPF_RC="$(PATH="$GHPF_BIN:$PATH" OMABACKUP_REPO="$GHPFR" OMABACKUP_PUSH_TIMEOUT_SEC=2 bash -c '
    set +o pipefail
    source lib/destinations.sh
    _push_github >/dev/null
    printf %s $?
')"

it "_push_github correctly reports a timed-out push as a failure even with pipefail explicitly disabled"
[[ "$GHPF_RC" == 1 ]] && ok || fail "expected exactly rc=1 with pipefail off; got '$GHPF_RC' (a silent false-success would read '00' here)"

# ── review round omabackup-42 (`omabackup-rev`): redacting before truncating
# reopened the memory bound the byte cap exists to hold ────────────────────
# `dest_redact_output` is `sed`, which must buffer a complete line before it
# can emit any of it -- running it before the byte cap meant a single,
# unterminated pathological line was no longer bounded by that cap at all.
# `ulimit -v` makes this deterministic instead of "probably fine on a big
# enough machine": a real OOM here, not a slow one. 200MB, not a smaller
# size: measured directly that a 5MB line sits in a flaky boundary zone
# under this same 20MB virtual-memory limit -- sometimes `sed` allocates it
# without issue depending on process/heap layout on the day, sometimes not.
# 200MB reliably reproduces the OOM against the OLD (pre-omabackup-42)
# redact-then-truncate design across repeated runs, with no flakiness
# margin to worry about.
GHMEMH="$(mktemp -d)"; GHMEMR="$GHMEMH/repo"; _dest_repo "$GHMEMR"
git -C "$GHMEMR" remote add origin 'https://example.invalid/nonexistent.git'
GHMEM_BIN="$GHMEMH/fake-bin"; mkdir -p "$GHMEM_BIN"
cat >"$GHMEM_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    head -c 200000000 /dev/zero | tr '\\0' x
    exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GHMEM_BIN/git"
GHMEM_RC="$(
    ulimit -v 20000
    PATH="$GHMEM_BIN:$PATH" OMABACKUP_REPO="$GHMEMR" bash -c '
        source lib/destinations.sh
        _push_github >/dev/null
        printf %s $?
    '
)"

it "_push_github stays bounded under a tight memory limit against a single 200MB unterminated line"
[[ "$GHMEM_RC" == 1 ]] && ok || fail "expected a clean rc=1 under ulimit -v 20000; got '$GHMEM_RC' (empty means the subshell itself was killed -- OOM)"

# ── marketplace security review, 2026-09-06: `git push` had no timeout, and
# no cap on how much of its output this tool would hold in memory ──────────
# https://github.com/omacom/omarchy-plugin-marketplace/issues/3968#issuecomment-5560428690:
# an unavailable or hostile configured remote could hold the scheduled push
# service indefinitely, and an unbounded sideband stream grows the shell's
# own memory. Same fake-git PATH-shadow technique already established above
# in this file for the credential-redaction tests.
GHTMH="$(mktemp -d)"; GHTMR="$GHTMH/repo"; _dest_repo "$GHTMR"
git -C "$GHTMR" remote add origin 'https://example.invalid/nonexistent.git'
printf '{"schemaVersion":1,"destinations":[]}\n' >"$GHTMH/destinations.json"
GHTM_BIN="$GHTMH/fake-bin"; mkdir -p "$GHTM_BIN"
cat >"$GHTM_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    sleep 30
    exit 0
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GHTM_BIN/git"
GHTM_START="$(date +%s)"
GHTM_OUT="$(PATH="$GHTM_BIN:$PATH" HOME="$GHTMH" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$GHTMH/.state" OMABACKUP_REPO="$GHTMR" \
    OMABACKUP_DESTINATIONS="$GHTMH/destinations.json" XDG_RUNTIME_DIR=/nonexistent \
    OMABACKUP_PUSH_TIMEOUT_SEC=2 "$OB" push github 2>&1)"; GHTM_RC=$?
GHTM_ELAPSED="$(( $(date +%s) - GHTM_START ))"

it "a hanging git push is killed by OMABACKUP_PUSH_TIMEOUT_SEC rather than hanging push itself"
(( GHTM_ELAPSED < 10 )) && ok || fail "expected well under 10s for a 2s timeout plus kill-after, took ${GHTM_ELAPSED}s"

it "and push reports the failure, not a false success, when the git push step timed out"
[[ "$GHTM_RC" != 0 ]] && ok || fail "expected a non-zero exit; got 0 with output: $GHTM_OUT"

GHOUTH="$(mktemp -d)"; GHOUTR="$GHOUTH/repo"; _dest_repo "$GHOUTR"
git -C "$GHOUTR" remote add origin 'https://example.invalid/nonexistent.git'
printf '{"schemaVersion":1,"destinations":[]}\n' >"$GHOUTH/destinations.json"
GHOUT_BIN="$GHOUTH/fake-bin"; mkdir -p "$GHOUT_BIN"
cat >"$GHOUT_BIN/git" <<EOF
#!/bin/bash
if [[ " \$* " == *" push origin HEAD "* ]]; then
    head -c 50000 /dev/zero | tr '\\0' x
    exit 1
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GHOUT_BIN/git"
GHOUT_OUT="$(PATH="$GHOUT_BIN:$PATH" HOME="$GHOUTH" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$GHOUTH/.state" OMABACKUP_REPO="$GHOUTR" \
    OMABACKUP_DESTINATIONS="$GHOUTH/destinations.json" XDG_RUNTIME_DIR=/nonexistent \
    OMABACKUP_PUSH_OUTPUT_MAX_BYTES=1000 "$OB" push github 2>&1)"

it "a failed push's captured output stays bounded near OMABACKUP_PUSH_OUTPUT_MAX_BYTES, not the full 50000-byte stream"
(( ${#GHOUT_OUT} < 3000 )) && ok || fail "expected well under 3000 chars for a 1000-byte cap, got ${#GHOUT_OUT}"

# The default timer path includes the implicit origin alongside configured
# destinations. Naming a destination is an intentional narrow retry and must
# not silently add GitHub back to that operation.
DH6D="$(mktemp -d)"; DR6D="$DH6D/repo"; _dest_repo "$DR6D"
DREMOTE6D="$DH6D/remote.git"; git init -q --bare "$DREMOTE6D"
git -C "$DR6D" remote add origin "$DREMOTE6D"
DLOCAL6D="$DH6D/local"
cat >"$DH6D/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"$DLOCAL6D","keep":2}]}
JSON
_dest_env "$DH6D" "$DR6D" push >/dev/null

it "the default push set includes the implicit GitHub origin"
assert_eq "$(git -C "$DREMOTE6D" rev-list --all --count 2>/dev/null)" "1"
assert_eq "$(find "$DLOCAL6D" -maxdepth 1 -name 'omabackup-*.tar.zst' 2>/dev/null | wc -l)" "1"

DH6X="$(mktemp -d)"; DR6X="$DH6X/repo"; _dest_repo "$DR6X"
DREMOTE6X="$DH6X/remote.git"; git init -q --bare "$DREMOTE6X"
git -C "$DR6X" remote add origin "$DREMOTE6X"
DLOCAL6X="$DH6X/local"; mkdir -p "$DLOCAL6X"
cat >"$DH6X/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"local","type":"dir","path":"$DLOCAL6X","keep":2}]}
JSON
_dest_env "$DH6X" "$DR6X" push local >/dev/null

it "an explicitly named local destination skips the implicit GitHub origin"
assert_eq "$(git -C "$DREMOTE6X" rev-list --all --count 2>/dev/null)" "0"
assert_eq "$(find "$DLOCAL6X" -maxdepth 1 -name 'omabackup-*.tar.zst' 2>/dev/null | wc -l)" "1"


# ── status --json is where the panel reads this, never verify --json ─────────
# A stale NAS must never be able to fail verify: cmd_sync refuses to commit when
# verify fails, so a disconnected drive would block the source of truth itself.
DSTATUS="$(_dest_env "$DH2" "$DR2" status --json)"

it "status --json reports each destination"
assert_contains "$(printf '%s' "$DSTATUS" | jq -r '.destinations[]?.id' 2>/dev/null)" "nas"

it "with the state the panel needs to draw it"
assert_eq "$(printf '%s' "$DSTATUS" | jq -r '[.destinations[] | select(has("lastSuccess") and has("enabled"))] | length > 0' 2>/dev/null)" "true"

it "verify --json stays clear of destinations -- a dead NAS cannot fail coverage"
assert_eq "$(_dest_env "$DH5" "$DR5" verify --json | jq -r '.findings[]? | select(.group=="push" or .group=="destinations") | .group' 2>/dev/null)" ""

# A manifest that passes on its own merits, so the only thing under test is
# whether the broken destination above can drag verify down with it. cmd_sync
# refuses to commit when verify fails, so if it could, a disconnected drive
# would block the source of truth -- the inverse of what §3 promises.
DG7="$DH5/minimal.json"
mkdir -p "$DH5/.config/app"; printf 'x\n' >"$DH5/.config/app/f.txt"
cat >"$DG7" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
HOME="$DH5" OMABACKUP_GROUPS="$DG7" OMABACKUP_STATE="$DH5/.state" OMABACKUP_REPO="$DR5" \
    OMABACKUP_DESTINATIONS="$DH5/destinations.json" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" verify >/dev/null 2>&1
DRC7=$?

it "and a destination in error leaves verify's exit code alone"
[[ $DRC7 -eq 0 ]] && ok || fail "a broken destination made verify fail (exit $DRC7)"

# ── the stamp has to survive contact with _push_dir ─────────────────────────
# It did not. `_push_dir` created `.omabackup-destination` in whatever directory
# the config named, and *then* pruned -- so the protection documented as "the
# rule that matters most" stamped its own permission on the way in. The spec
# above never caught it because it calls prune_bundles directly and never goes
# through the driver, which is the same green-but-proves-nothing failure this
# suite has hit three times now.
#
# The rule now: a directory holding files this tool did not put there is never
# stamped, so it is never pruned. A NAS folder shared with real data keeps
# receiving bundles and simply never has anything deleted from it.
PH="$(mktemp -d)"; PR="$PH/repo"; _dest_repo "$PR"
PDOCS="$PH/somebodys-documents"; mkdir -p "$PDOCS"
printf 'a thesis\n' >"$PDOCS/thesis.odt"
printf 'x\n' >"$PDOCS/omabackup-$HOSTN-20200101-000000.tar.zst"
printf 'x\n' >"$PDOCS/omabackup-$HOSTN-20200102-000000.tar.zst"
cat >"$PH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"oops","type":"dir","path":"$PDOCS","keep":1}]}
JSON
_dest_env "$PH" "$PR" push oops >/dev/null

it "a directory with unrelated content is never stamped"
[[ ! -f "$PDOCS/.omabackup-destination" ]] \
    && ok || fail "the driver stamped its own permission to delete"

it "so nothing in a wrongly-configured directory is deleted"
assert_eq "$(find "$PDOCS" -maxdepth 1 -name "omabackup-$HOSTN-*.tar.zst" | wc -l)" "3"

it "and the unrelated file is untouched"
[[ -f "$PDOCS/thesis.odt" ]] && ok || fail "deleted a file that was never ours"

it "the bundle still arrives -- refusing to prune is not refusing to back up"
[[ -n "$(find "$PDOCS" -maxdepth 1 -newer "$PDOCS/thesis.odt" -name 'omabackup-*.tar.zst' 2>/dev/null)" ]] \
    && ok || fail "nothing was written"

# ── an empty directory is ours to own ───────────────────────────────────────
QH="$(mktemp -d)"; QR="$QH/repo"; _dest_repo "$QR"
QNAS="$QH/nas"
cat >"$QH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$QNAS","keep":1}]}
JSON
_dest_env "$QH" "$QR" push nas >/dev/null

it "a fresh directory is stamped and managed normally"
[[ -f "$QNAS/.omabackup-destination" ]] && ok || fail "a directory we created was not stamped"

# ── a hostname is not a regular expression ─────────────────────────────────
# ${host} went raw into the ERE, so a dot -- ordinary in a hostname -- matches
# any character and widens retention to other machines' bundles.
it "a hostname with a regex metacharacter does not match another host"
MH="$(mktemp -d)/nas"; mkdir -p "$MH"
printf 'stamped\n' >"$MH/.omabackup-destination"
printf 'x\n' >"$MH/omabackup-my.box-20200101-000000.tar.zst"
printf 'x\n' >"$MH/omabackup-my.box-20200102-000000.tar.zst"
printf 'x\n' >"$MH/omabackup-myxbox-20200101-000000.tar.zst"   # a DIFFERENT machine
OMABACKUP_ROOT="$PWD" bash -c '
  source lib/bundle.sh; source lib/destinations.sh
  prune_bundles "$1" "my.box" 1' _ "$MH" >/dev/null 2>&1
[[ -f "$MH/omabackup-myxbox-20200101-000000.tar.zst" ]] \
    && ok || fail "the dot matched any character and ate another host's backup"

# ── the two regexes must agree on our own filename ─────────────────────────
# They did not. Adding the short sha to the published name updated the pattern
# retention deletes by and left the one _dir_is_ours uses to decide ownership
# behind, so a folder holding this tool's own bundles read as foreign: never
# stamped, therefore never pruned, therefore growing forever. The realistic
# case is the one the specs above already promise -- two machines sharing a
# NAS folder, the second arriving to find the first's bundles.
SH2="$(mktemp -d)"; SR2="$SH2/repo"; _dest_repo "$SR2"
SNAS2="$SH2/nas"; mkdir -p "$SNAS2"
printf 'x\n' >"$SNAS2/omabackup-otherbox-20200101-000000-0123456789ab.tar.zst"
cat >"$SH2/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$SNAS2","keep":1}]}
JSON
_dest_env "$SH2" "$SR2" push nas >/dev/null

it "a folder holding only omabackup bundles is recognised as ours"
[[ -f "$SNAS2/.omabackup-destination" ]] \
    && ok || fail "our own sha-suffixed filename read as a foreign file"

it "and the other machine's bundle is still not deleted"
[[ -f "$SNAS2/omabackup-otherbox-20200101-000000-0123456789ab.tar.zst" ]] \
    && ok || fail "pruned another host"

# ── our own leftovers must not lock us out of our own directory ────────────
# _push_dir writes "<name>.tmp" and then renames. An interrupted push leaves
# that .tmp behind, and _dir_is_ours counted it as a foreign file -- so the
# directory read as somebody else's forever after, and retention silently
# stopped running there. The tool poisoning its own destination.
TH="$(mktemp -d)"; TR="$TH/repo"; _dest_repo "$TR"
TNAS="$TH/nas"; mkdir -p "$TNAS"
printf 'half-written\n' >"$TNAS/omabackup-$HOSTN-20200101-000000-abc123456789.tar.zst.tmp"
cat >"$TH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$TNAS","keep":1}]}
JSON
_dest_env "$TH" "$TR" push nas >/dev/null

it "an interrupted write of our own does not make the directory foreign"
[[ -f "$TNAS/.omabackup-destination" ]] \
    && ok || fail "our own .tmp locked us out of our own destination"

it "and the stale .tmp is cleaned up rather than left to accumulate"
[[ -z "$(find "$TNAS" -maxdepth 1 -name '*.tar.zst.tmp' 2>/dev/null)" ]] \
    && ok || fail "the leftover is still there"

# ── filesystem machinery is not somebody's documents ───────────────────────
# A NAS share or a synced folder carries .snapshots, .Trash-1000, .stfolder.
# Treating those as foreign content meant retention never ran on exactly the
# kind of directory this feature exists for.
UH="$(mktemp -d)"; UR="$UH/repo"; _dest_repo "$UR"
UNAS="$UH/nas"; mkdir -p "$UNAS/.snapshots" "$UNAS/.stfolder"
cat >"$UH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$UNAS","keep":1}]}
JSON
_dest_env "$UH" "$UR" push nas >/dev/null

it "hidden filesystem machinery does not mark the directory as somebody else's"
[[ -f "$UNAS/.omabackup-destination" ]] \
    && ok || fail ".snapshots blocked a legitimate NAS destination"

# ── but visible content someone put there still does ──────────────────────
VH="$(mktemp -d)"; VR="$VH/repo"; _dest_repo "$VR"
VDOCS="$VH/documents"; mkdir -p "$VDOCS/holiday-photos"
cat >"$VH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"oops","type":"dir","path":"$VDOCS","keep":1}]}
JSON
_dest_env "$VH" "$VR" push oops >/dev/null

it "a directory holding someone's own folders is still refused"
[[ ! -f "$VDOCS/.omabackup-destination" ]] \
    && ok || fail "stamped a directory full of somebody's work"

# ── nothing is deleted before we know the directory is ours ────────────────
# _push_dir cleared `*.tar.zst.tmp` right after mkdir -- before _dir_is_ours had
# said anything. Point the config at somebody's folder and the tool deleted
# their half-written archives on the way in, which is the exact failure the
# stamp exists to prevent, happening one line above the stamp.
WH="$(mktemp -d)"; WR="$WH/repo"; _dest_repo "$WR"
WDOCS="$WH/somebodys-folder"; mkdir -p "$WDOCS"
printf 'their work\n' >"$WDOCS/thesis.odt"
printf 'their partial download\n' >"$WDOCS/something.tar.zst.tmp"
cat >"$WH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"oops","type":"dir","path":"$WDOCS","keep":1}]}
JSON
_dest_env "$WH" "$WR" push oops >/dev/null

it "a stranger's .tmp file is not deleted from an unowned directory"
[[ -f "$WDOCS/something.tar.zst.tmp" ]] \
    && ok || fail "deleted a half-written file belonging to somebody else"

it "and their real file is untouched too"
[[ -f "$WDOCS/thesis.odt" ]] && ok || fail "deleted their work"

# ── but our own leftovers are still cleared where we do own the place ──────
OH="$(mktemp -d)"; OR="$OH/repo"; _dest_repo "$OR"
ONAS="$OH/nas"; mkdir -p "$ONAS"
printf 'ours, interrupted\n' >"$ONAS/omabackup-$HOSTN-20200101-000000-abc123456789.tar.zst.tmp"
cat >"$OH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$ONAS","keep":1}]}
JSON
_dest_env "$OH" "$OR" push nas >/dev/null

it "our own interrupted write is still cleaned up in a directory we own"
[[ -z "$(find "$ONAS" -maxdepth 1 -name '*.tar.zst.tmp' 2>/dev/null)" ]] \
    && ok || fail "our leftover survived"

# ── two bundles in the same second: keep the newer format ──────────────────
# Retention sorts by filename descending. Within one second that decides by the
# suffix, and a legacy name (written before bundles carried a short sha) sorts
# AFTER the sha'd one -- so `sort -r` kept the legacy file and pruned the newer.
SSH="$(mktemp -d)/nas"; mkdir -p "$SSH"
printf 'stamped\n' >"$SSH/.omabackup-destination"
printf 'older format\n' >"$SSH/omabackup-h-20260101-120000.tar.zst"
printf 'newer format\n' >"$SSH/omabackup-h-20260101-120000-aaaaaaaaaaaa.tar.zst"
OMABACKUP_ROOT="$PWD" bash -c '
  source lib/bundle.sh; source lib/destinations.sh
  prune_bundles "$1" "h" 1' _ "$SSH" >/dev/null 2>&1

it "the one kept in a tie is the sha-suffixed name, not the legacy one"
[[ -f "$SSH/omabackup-h-20260101-120000-aaaaaaaaaaaa.tar.zst" ]] \
    && ok || fail "pruned the newer format and kept the older"

it "and the older one is the one removed"
[[ ! -e "$SSH/omabackup-h-20260101-120000.tar.zst" ]] \
    && ok || fail "kept both, or removed the wrong one"

# ── a hostname that looks like a timestamp ─────────────────────────────────
# The sort key took the FIRST `-YYYYMMDD-HHMMSS` in the filename, so a host
# whose own name carries that shape hijacked the extraction and retention
# ordered by the wrong field.
#
# The formats have to be MIXED for this to discriminate. Two legacy names sort
# correctly on the whole filename even with the key broken -- the first version
# of this spec used two, so it passed against the bug it was written for. With
# one legacy and one sha'd name every entry shares the hostname's stamp, the
# tie falls to the format column, and the older sha'd bundle wins.
HNH="$(mktemp -d)/nas"; mkdir -p "$HNH"
printf 'stamped\n' >"$HNH/.omabackup-destination"
HN='box-20200101-000000'
printf 'older\n' >"$HNH/omabackup-$HN-20260101-120000-aaaaaaaaaaaa.tar.zst"
printf 'newer\n' >"$HNH/omabackup-$HN-20260102-120000.tar.zst"
OMABACKUP_ROOT="$PWD" bash -c '
  source lib/bundle.sh; source lib/destinations.sh
  prune_bundles "$1" "$2" 1' _ "$HNH" "$HN" >/dev/null 2>&1

it "a host whose name contains a timestamp still prunes by the real one"
[[ -f "$HNH/omabackup-$HN-20260102-120000.tar.zst" ]] \
    && ok || fail "kept the older bundle -- the hostname hijacked the sort key"

it "and the older one is what went"
[[ ! -e "$HNH/omabackup-$HN-20260101-120000-aaaaaaaaaaaa.tar.zst" ]] \
    && ok || fail "removed the wrong file, or neither"

# ── a walk that stopped partway is not a listing ────────────────────────────
# mapfile through a process substitution threw find's status away, so a walk
# that stopped -- an unreadable subdirectory, a mount going away -- produced a
# partial list, and retention then decided which files were "oldest" from a
# fraction of what was there. Deleting on a partial reading of a backup
# directory is the one thing this function must never do.
PWH="$(mktemp -d)/dest"; mkdir -p "$PWH"
printf 'stamped\n' >"$PWH/.omabackup-destination"
printf 'older\n' >"$PWH/omabackup-h-20260101-120000.tar.zst"
printf 'newer\n' >"$PWH/omabackup-h-20260102-120000.tar.zst"
mkdir -p "$PWH/../stub"; PWSTUB="$(cd "$PWH/.." && pwd)/stub"
printf '#!/bin/bash\nexit 1\n' >"$PWSTUB/find"; chmod +x "$PWSTUB/find"
PWRC=0
PATH="$PWSTUB:$PATH" bash -c 'source lib/bundle.sh; source lib/destinations.sh
    prune_bundles "$1" h 1' _ "$PWH" >/dev/null 2>&1 || PWRC=$?

it "a find that fails makes prune refuse rather than report nothing removed"
[[ $PWRC -ne 0 ]] && ok || fail "reported success on a directory it could not list"

it "and nothing was deleted on the strength of a listing it never got"
assert_eq "$(ls "$PWH" | grep -c 'tar.zst')" "2"

# ── a prune failure during push is not swallowed to /dev/null ───────────────
# `removed="$(prune_bundles ... 2>/dev/null)" || removed=0` treated a real
# retention failure exactly like "nothing needed pruning" -- the new copy
# still lands (correctly: a retention hiccup should not turn into a backup
# outage), but the failure itself vanished with no diagnostic anywhere.
PFH="$(mktemp -d)"; PFR="$PFH/repo"; _dest_repo "$PFR"
PFNAS="$PFH/nas"; mkdir -p "$PFNAS"
printf 'stamped\n' >"$PFNAS/.omabackup-destination"
printf 'old\n' >"$PFNAS/omabackup-$(hostname 2>/dev/null || echo host)-20260101-120000.tar.zst"
cat >"$PFH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$PFNAS","keep":1}]}
JSON
mkdir -p "$PFH/stub"
printf '#!/bin/bash\nexit 2\n' >"$PFH/stub/sort"; chmod +x "$PFH/stub/sort"
PFOUT="$(PATH="$PFH/stub:$PATH" _dest_env "$PFH" "$PFR" push nas)"

it "the push itself still succeeds -- a retention hiccup is not a backup outage"
assert_contains "$PFOUT" "✓"

it "and the prune failure is visible, not silently discarded"
assert_contains "$PFOUT" "could not order"

# ── _push_dir must not follow a pre-planted symlink at its own temp path ────
# cp, given an existing symlink at the destination, follows it and writes
# THROUGH to whatever it points at -- confirmed directly. A `dir` destination
# is exactly the kind of path another process could plant something at
# first: a NAS mount, a removable drive, anything shared. A symlink
# pre-planted at the exact "<name>.tar.zst.tmp" path this function is about
# to write to, pointing anywhere this process can write, had its target
# silently overwritten with bundle content instead of the destination
# gaining a bundle.
PDH="$(mktemp -d)"
mkdir -p "$PDH/dir" "$PDH/outside"
printf 'sensitive\n' >"$PDH/outside/victim.txt"
ln -s "$PDH/outside/victim.txt" "$PDH/dir/omabackup-test-bundle.tar.zst.tmp"
printf 'bundle-content\n' >"$PDH/bundle.tar.zst"
cat >"$PDH/destinations.json" <<JSON
{"schemaVersion":1,"destinations":[{"id":"nas","type":"dir","path":"$PDH/dir","keep":5}]}
JSON

it "_push_dir does not write through a symlink planted at its temp path"
DESTINATIONS_FILE="$PDH/destinations.json" bash -c '
    source lib/bundle.sh; source lib/destinations.sh
    _push_dir "nas" "$1" "omabackup-test-bundle.tar.zst"
' _ "$PDH/bundle.tar.zst" >/dev/null 2>&1
assert_eq "$(cat "$PDH/outside/victim.txt")" "sensitive"

it "and the destination gained a real bundle, not a redirected write"
assert_eq "$(cat "$PDH/dir/omabackup-test-bundle.tar.zst" 2>/dev/null)" "bundle-content"

# ── _dir_is_ours must not answer "yes" from a walk that stopped partway ─────
# `done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)` had no
# `wait "$!"` afterward -- a walk that stopped early (an unreadable entry, a
# vanishing mount) enumerated fewer entries than the directory actually
# holds, and everything seen up to that point reading as "ours" answered yes
# for the whole directory. This gates the retention stamp -- described two
# functions away as "the rule that matters most" -- so a false yes here is
# not a smaller mistake than a false no.
DIH="$(mktemp -d)/nas"; mkdir -p "$DIH"
printf 'x\n' >"$DIH/omabackup-my.box-20200101-000000-abc123456789.tar.zst"
DISTUB="$(mktemp -d)"
cat >"$DISTUB/find" <<STUB
#!/bin/bash
printf '%s\0' "$DIH/omabackup-my.box-20200101-000000-abc123456789.tar.zst"
exit 9
STUB
chmod +x "$DISTUB/find"

it "_dir_is_ours refuses when its own walk fails, rather than answering yes"
PATH="$DISTUB:$PATH" bash -c '
    source lib/bundle.sh; source lib/destinations.sh
    _dir_is_ours "$1" "irrelevant"
' _ "$DIH" >/dev/null 2>&1 \
    && fail "answered yes from a walk that stopped partway" || ok

# ── an unparseable destinations.json is refused, not read as "nothing wrong" ─
# `bad="$(jq ... 2>/dev/null)"` had its own status discarded -- a
# destinations.json this cannot even PARSE (not just an unknown field)
# produced the same empty $bad a genuinely clean file does, and
# `[[ -z "$bad" ]] && return 0` read "could not check" as "checked fine".
# A PoC ({not-json) confirmed assert_destinations_understood returned 0
# silently.
DJH="$(mktemp -d)"
printf '{not-json' >"$DJH/destinations.json"

it "assert_destinations_understood refuses when destinations.json is not valid JSON"
bash -c '
    source lib/destinations.sh
    DESTINATIONS_FILE="$1"
    assert_destinations_understood
' _ "$DJH/destinations.json" >/dev/null 2>&1 \
    && fail "returned success against unparseable JSON" || ok

# ── prune_bundles' own rm failure is reflected in its return status ─────────
# `rm -f -- "$dir/$f" && removed=$((removed + 1))` only ever counted a
# SUCCESSFUL removal; the function's own return status, falling through to
# `printf '%s' "$removed"`, was always 0 regardless of whether a removal
# that SHOULD have happened actually failed. A PoC (rm stubbed to always
# fail, three bundles, keep=1) confirmed the result: removed=0, rc=0 --
# indistinguishable from "nothing needed pruning".
PBH="$(mktemp -d)"
touch "$PBH/.omabackup-destination"
touch -d "2020-01-01 00:00:00" "$PBH/omabackup-myhost-20200101-000000-abc111111111.tar.zst"
touch -d "2020-01-02 00:00:00" "$PBH/omabackup-myhost-20200102-000000-abc222222222.tar.zst"
touch -d "2020-01-03 00:00:00" "$PBH/omabackup-myhost-20200103-000000-abc333333333.tar.zst"
mkdir -p "$PBH/stub"
printf '#!/bin/bash\nexit 1\n' >"$PBH/stub/rm"; chmod +x "$PBH/stub/rm"

it "prune_bundles refuses when its own rm fails, rather than reporting a clean prune"
PATH="$PBH/stub:$PATH" bash -c '
    source lib/destinations.sh
    prune_bundles "$1" myhost 1 >/dev/null
' _ "$PBH" \
    && fail "prune_bundles reported success despite rm failing" || ok
