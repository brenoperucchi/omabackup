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

OB="$PWD/bin/omabackup"

_dest_env() {  # _dest_env <home> <repo> <args...>
    local h="$1" r="$2"; shift 2
    HOME="$h" OMABACKUP_GROUPS="$PWD/groups.default.json" OMABACKUP_STATE="$h/.state" \
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
