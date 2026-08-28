# Regressions for per-group coverage -- the numbers the panel's "Grupos" section
# shows (docs/DESIGN.md §1: panel -> groups, destinations, schedule, diff).
#
# Counted by `collect`, not recomputed by `verify`. Collect already decides what
# enters the backup, excludes and tracked-only rules included; counting live
# would mean a second implementation of that decision, and a fact stated twice
# is the mistake this project has made four times.

OB="$PWD/bin/omabackup"

_cov_env() {
    local h="$1"; shift
    HOME="$h" OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$h/g.json" \
        OMABACKUP_STATE="$h/.state" XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

CH="$(mktemp -d)"
mkdir -p "$CH/.config/app/src" "$CH/.config/app/node_modules/junk" "$CH/.config/solo"
printf 'aaaa\n' >"$CH/.config/app/src/one.lua"
printf 'bbbb\n' >"$CH/.config/app/src/two.lua"
printf 'ignore me\n' >"$CH/.config/app/node_modules/junk/big.js"
printf 'cc\n' >"$CH/.config/solo/only.conf"
cat >"$CH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":true,"critical":true,
  "paths":["~/.config/app"],"exclude":["node_modules/**"]},
 {"id":"solo","label":"Solo","mode":"link","coupled":false,"critical":false,
  "paths":["~/.config/solo"]}]}
JSON
_cov_env "$CH" collect >/dev/null

it "collect records what each group actually covers"
assert_eq "$(_cov_env "$CH" verify --json | jq -r '[.groups[] | select(.id=="app")] | length')" "1"

it "the count is what was staged, so an excluded directory is not in it"
assert_eq "$(_cov_env "$CH" verify --json | jq -r '.groups[] | select(.id=="app") | .files')" "2"

it "and the byte total matches the files that were staged"
[[ "$(_cov_env "$CH" verify --json | jq -r '.groups[] | select(.id=="app") | .bytes')" -eq 10 ]] \
    && ok || fail "bytes did not match the two 5-byte files"

it "each group carries what the panel needs to draw its badge"
assert_eq "$(_cov_env "$CH" verify --json | jq -r '
    .groups[] | select(.id=="app")
    | [(.label != null), (.mode != null), (.coupled|type=="boolean"), (.critical|type=="boolean")]
    | all')" "true"

it "a second group is counted separately, not lumped in"
assert_eq "$(_cov_env "$CH" verify --json | jq -r '.groups[] | select(.id=="solo") | .files')" "1"

it "the label comes from the manifest, not from the id"
assert_eq "$(_cov_env "$CH" verify --json | jq -r '.groups[] | select(.id=="solo") | .label')" "Solo"

# ── verify still works where nothing has been collected ──────────────────────
# It has to run inside a bundle and on a recovery tty, where no staging exists.
DH="$(mktemp -d)"; mkdir -p "$DH/.config/app"
printf 'x\n' >"$DH/.config/app/f.txt"
cp "$CH/g.json" "$DH/g.json"

it "verify runs with no coverage recorded at all"
_cov_env "$DH" verify >/dev/null 2>&1
[[ $? -eq 0 ]] && ok || fail "verify needed a collect to have happened"

it "and reports the groups with unknown counts rather than omitting them"
assert_eq "$(_cov_env "$DH" verify --json | jq -r '.groups[] | select(.id=="app") | .files')" "null"

# ── a group that stopped covering anything is visible ────────────────────────
# Zero is a different answer from unknown: the first means collect ran and found
# nothing, which is the phantom-coverage failure this project was built after.
EH="$(mktemp -d)"; mkdir -p "$EH/.config/app"
printf 'x\n' >"$EH/.config/app/f.txt"
cat >"$EH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]},
 {"id":"ghost","label":"Ghost","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/gone"]}]}
JSON
_cov_env "$EH" collect >/dev/null

it "a group covering nothing reports zero, not unknown"
assert_eq "$(_cov_env "$EH" verify --json | jq -r '.groups[] | select(.id=="ghost") | .files')" "0"

# ── generated groups share one directory and must not share its count ──────
# collect_generated writes every generator's output into .generated/, so
# counting that directory attributed the whole of it to each group: packages and
# systemd both reported the same total, neither of them true.
GH="$(mktemp -d)"
mkdir -p "$GH/.config/app"; printf 'x\n' >"$GH/.config/app/f.txt"
cat >"$GH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"packages","label":"Packages","mode":"gen","coupled":false,"critical":true,"generator":"packages"},
 {"id":"systemd","label":"Services","mode":"gen","coupled":false,"critical":false,"generator":"systemd"}]}
JSON
# systemctl --user has no session bus to talk to under this suite's own
# XDG_RUNTIME_DIR=/nonexistent (deliberate, to keep tests from touching the
# real user's systemd) -- genuinely fails here, which collect_generated now
# refuses on rather than silently staging empty lists. Stubbed so this spec
# tests count attribution, not whether a login session bus exists.
mkdir -p "$GH/stub"
{ printf '#!/bin/bash\n'
  printf 'case "$*" in\n'
  printf '  *--user*) echo "a.service enabled enabled" ;;\n'
  printf '  *)        echo "b.service enabled enabled" ;;\n'
  printf 'esac\n'
} >"$GH/stub/systemctl"; chmod +x "$GH/stub/systemctl"
PATH="$GH/stub:$PATH" _cov_env "$GH" collect >/dev/null
GP="$(_cov_env "$GH" verify --json | jq -r '.groups[] | select(.id=="packages") | .files')"
GS="$(_cov_env "$GH" verify --json | jq -r '.groups[] | select(.id=="systemd") | .files')"

it "each generated group counts only the lists its own generator wrote"
[[ "$GP" != "$GS" || "$GP" == "0" ]] \
    && ok || fail "packages and systemd both reported $GP -- the shared directory"

it "and packages counts the three lists it produces"
assert_eq "$GP" "3"

it "while systemd counts its two"
assert_eq "$GS" "2"

# ── counts belong to the manifest that produced them ───────────────────────
# coverage.json recorded numbers keyed by group id and nothing else, so a
# manifest edit that kept an id but changed what it covers left the old numbers
# on screen as if they described the new definition. Reproduced: a group
# repointed from a five-file directory to a one-file one still reported five.
MFH="$(mktemp -d)"
mkdir -p "$MFH/.config/wide" "$MFH/.config/narrow"
for i in 1 2 3 4 5; do printf 'x\n' >"$MFH/.config/wide/f$i"; done
printf 'y\n' >"$MFH/.config/narrow/f1"
cat >"$MFH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/wide"]}]}
JSON
_cov_env "$MFH" collect >/dev/null

it "a fresh collect reports what it staged"
assert_eq "$(_cov_env "$MFH" verify --json | jq -r '.groups[0].files')" "5"

cat >"$MFH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/narrow"]}]}
JSON

it "after the manifest changes, the old counts are not presented as current"
assert_eq "$(_cov_env "$MFH" verify --json | jq -r '.groups[0].files')" "null"

it "and collecting again under the new manifest restores real numbers"
_cov_env "$MFH" collect >/dev/null
assert_eq "$(_cov_env "$MFH" verify --json | jq -r '.groups[0].files')" "1"

# ── coverage that could not be written must not keep reading as current ─────
# Every failure branch returned 0 and the caller discarded the status, so a
# write that failed left the previous collect's numbers in place and collect
# printed its ticks over them. Nothing downstream tells a stale record from a
# fresh one: unknown prints as "--", stale prints as fact.
WFH="$(mktemp -d)"; mkdir -p "$WFH/.config/solo"
printf 'cc\n' >"$WFH/.config/solo/only.conf"
cat >"$WFH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"solo","label":"Solo","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/solo"]}]}
JSON
_cov_env "$WFH" collect >/dev/null

it "a first collect records real counts"
assert_eq "$(_cov_env "$WFH" verify --json | jq -r '.groups[0].files')" "1"

# The coverage directory is made unwritable, so the replacement cannot land.
COVDIR="$WFH/.state/coverage"
[[ -d "$COVDIR" ]] || COVDIR="$(dirname "$(find "$WFH/.state" -name 'coverage*' | head -1)")"
printf 'extra\n' >"$WFH/.config/solo/second.conf"
chmod a-w "$COVDIR"
WFOUT="$(_cov_env "$WFH" collect 2>&1)"; WFRC=$?
chmod u+w "$COVDIR"

it "a coverage write that fails says so"
assert_contains "$WFOUT" "could not record coverage"

it "and the collect itself still succeeds -- what it staged is on disk"
[[ $WFRC -eq 0 ]] && ok || fail "aborted a collect that worked"

it "while the counts read as unknown rather than as last time's numbers"
assert_eq "$(_cov_env "$WFH" verify --json | jq -r '.groups[0].files')" "null"

# ── a size that could not be measured is not a size of zero ─────────────────
# _staged_size returns non-zero when find's walk was partial. Two of the three
# call sites threw that status away and the third returned before the old record
# was retired, so a measurement failure and a clean collect looked alike -- and
# the previous run's numbers stayed on screen as though they described this one.
SZH="$(mktemp -d)"; mkdir -p "$SZH/.config/app"
printf 'x\n' >"$SZH/.config/app/one.conf"
cat >"$SZH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/app"]}]}
JSON
_cov_env "$SZH" collect >/dev/null

it "the first collect records a real count"
assert_eq "$(_cov_env "$SZH" verify --json | jq -r '.groups[0].files')" "1"

# An empty directory the walk cannot enter. It survives the copy -- there is
# nothing inside to read -- and stops find at the far end.
mkdir -p "$SZH/.config/app/sealed"; chmod 000 "$SZH/.config/app/sealed"
SZOUT="$(_cov_env "$SZH" collect 2>&1)"; SZRC=$?
chmod 755 "$SZH/.config/app/sealed"

it "a walk that could not finish says so instead of counting what it reached"
assert_contains "$SZOUT" "could not measure what was staged"

it "and the collect still succeeds -- what it staged is on disk"
[[ $SZRC -eq 0 ]] && ok || fail "aborted a collect that worked: $SZOUT"

it "while last run's numbers are retired rather than left standing"
assert_eq "$(_cov_env "$SZH" verify --json | jq -r '.groups[0].files')" "null"

# ── a hash that could not be computed is not a hash ─────────────────────────
# The manifest hash tells a later read whether these counts still describe the
# same question. Computed inline, a sha256sum that failed wrote an empty one --
# and the reader, computing it the same way and failing the same way, compared
# "" against "" and accepted stale counts as current. Two failures agreeing is
# not agreement.
MHH="$(mktemp -d)"; mkdir -p "$MHH/.config/solo" "$MHH/stub"
printf 'c\n' >"$MHH/.config/solo/one.conf"
cat >"$MHH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"solo","label":"Solo","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/solo"]}]}
JSON
_cov_env "$MHH" collect >/dev/null

it "a first collect records a real count"
assert_eq "$(_cov_env "$MHH" verify --json | jq -r '.groups[0].files')" "1"

printf '#!/bin/bash\nexit 1\n' >"$MHH/stub/sha256sum"; chmod +x "$MHH/stub/sha256sum"
printf 'extra\n' >"$MHH/.config/solo/two.conf"
MHOUT="$(PATH="$MHH/stub:$PATH" _cov_env "$MHH" collect 2>&1)"

it "a manifest that cannot be hashed is said out loud"
assert_contains "$MHOUT" "could not hash"

it "and the counts are retired rather than left to match an empty hash"
assert_eq "$(_cov_env "$MHH" verify --json | jq -r '.groups[0].files')" "null"

# ── groups_json's own read-time hash comparison, not just write_coverage's ──
# A valid coverage record already on disk, read back while sha256sum is broken
# -- not a write failing (that path retires the record and is covered above),
# but the SEPARATE comparison groups_json makes every time status/verify --json
# runs. Before _manifest_hash existed, both sides of "recorded == live" were
# computed inline with sha256sum's own status unchecked: a broken sha256sum
# made BOTH sides equally empty, "" == "" passed, and a stale record read as
# current -- files=2 for a manifest that no longer described two files.
GJH="$(mktemp -d)"; mkdir -p "$GJH/.config/solo" "$GJH/stub"
printf 'c\n' >"$GJH/.config/solo/one.conf"
cat >"$GJH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"solo","label":"Solo","mode":"copy","coupled":false,"critical":false,"paths":["~/.config/solo"]}]}
JSON
_cov_env "$GJH" collect >/dev/null

it "the record is readable right after a normal collect"
assert_eq "$(_cov_env "$GJH" verify --json | jq -r '.groups[0].files')" "1"

printf '#!/bin/bash\nexit 1\n' >"$GJH/stub/sha256sum"; chmod +x "$GJH/stub/sha256sum"

it "and reads as unknown, not as a match, once sha256sum breaks at read time"
assert_eq "$(PATH="$GJH/stub:$PATH" _cov_env "$GJH" verify --json | jq -r '.groups[0].files')" "null"

# ── write_coverage's own generator-field query failing is not a real zero ───
# gen_id="$(group_field "$id" generator)" had its status discarded -- a
# failed query produced the same empty string _generated_files returns for
# an id with no entry, the for loop over it ran zero times, and this
# group's coverage line was written with files=0 bytes=0 as though that
# were a genuine measurement of an actually-empty group, not one that
# could not be measured at all. Called directly (not through collect,
# which now refuses this same query failure earlier, before
# write_coverage ever runs) to isolate write_coverage's own check.
WGH="$(mktemp -d)"
mkdir -p "$WGH/.state/staging/.generated"
printf 'pkg1\npkg2\n' >"$WGH/.state/staging/.generated/pkgs-explicit.txt"
cat >"$WGH/g.json" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"packages","label":"Packages","mode":"gen","coupled":false,"critical":true,"generator":"packages"}]}
JSON
mkdir -p "$WGH/stub"
{ printf '#!/bin/bash\n'
  printf 'for a in "$@"; do [[ "$a" == *"generator"* ]] && exit 9; done\n'
  printf 'exec %s "$@"\n' "$(command -v jq)"
} >"$WGH/stub/jq"; chmod +x "$WGH/stub/jq"

it "write_coverage refuses when a generated group's own generator field cannot be queried"
WGOUT="$(PATH="$WGH/stub:$PATH" HOME="$WGH" OMABACKUP_GROUPS="$WGH/g.json" OMABACKUP_STATE="$WGH/.state" bash -c '
    source bin/omabackup >/dev/null 2>&1
    write_coverage
    echo "rc=$?"
')"
[[ "$WGOUT" == *"rc=1"* ]] \
    && ok || fail "expected rc=1, got: $WGOUT"

it "and no false zero-count record was written"
[[ ! -s "$WGH/.state/coverage.json" ]] \
    && ok || fail "a coverage record was written despite the measurement having failed"
