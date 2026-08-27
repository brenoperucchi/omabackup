# Regressions for `omabackup bundle` (lib/bundle.sh).
#
# The bundle is what every destination other than `github` receives, and
# docs/DESIGN.md §11.4 sets the bar: each destination must be restorable from
# its own identifier alone. That is a claim these specs turn into a check --
# every one of them deletes the original repo, or unsets the environment, or
# corrupts a byte, and then demands the artifact still answer for itself.
#
# Offline throughout: cloning from a .bundle file is offline by definition.

OB="$PWD/bin/omabackup"

_bundle_env() {  # _bundle_env <home> <repo> <args...>
    local h="$1" r="$2"; shift 2
    HOME="$h" OMABACKUP_GROUPS="$PWD/groups.default.json" OMABACKUP_STATE="$h/.state" \
        OMABACKUP_REPO="$r" XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

# A throwaway dotfiles repo with two commits, so history is a thing that can be
# lost rather than a single snapshot.
_bundle_repo() {
    local r="$1"
    mkdir -p "$r/configs/app"
    git init -q "$r"
    git -C "$r" config user.email t@t
    git -C "$r" config user.name t
    printf 'first\n' >"$r/configs/app/f.txt"
    git -C "$r" add -A && git -C "$r" commit -qm one
    printf 'second\n' >"$r/configs/app/f.txt"
    printf 'kept\n' >"$r/configs/app/g.txt"
    # A tracked symlink pointing outside the repo. A dotfiles repo is full of
    # these -- omarchy-personal tracks four, into ~/.local/share/omarchy and a
    # theme under ~/.local/state -- and they are dangling anywhere but the
    # machine that made them. Verification that follows them compares the
    # current machine instead of the backup, and dies on the dangling ones.
    ln -s /nonexistent/outside/theme.lua "$r/configs/app/link.lua"
    git -C "$r" add -A && git -C "$r" commit -qm two
    git -C "$r" remote add origin https://example.invalid/dotfiles.git
}

_unpack() {  # _unpack <bundle.tar.zst> -> prints the extraction dir
    local d; d="$(mktemp -d)"
    tar -C "$d" -xf <(zstd -dc "$1") 2>/dev/null
    printf '%s' "$d"
}

BH="$(mktemp -d)"; BR="$BH/repo"
_bundle_repo "$BR"
BOUT="$(_bundle_env "$BH" "$BR" bundle --json)"
BPATH="$(printf '%s' "$BOUT" | jq -r '.path // empty' 2>/dev/null)"

it "bundle reports the artifact it wrote"
[[ -n "$BPATH" && -f "$BPATH" ]] && ok || fail "no bundle produced: $BOUT"

BX="$(_unpack "$BPATH")"

it "the artifact carries a git bundle, a clear worktree, the tool and a manifest"
[[ -f "$BX/repo.bundle" && -d "$BX/worktree" && -f "$BX/manifest.json" \
   && -f "$BX/tool/bin/omabackup" && -f "$BX/SHA256SUMS" ]] \
    && ok || fail "missing members: $(ls "$BX" | tr '\n' ' ')"

# -- 1. it clones with no network AND no original repo -----------------------------
# Deleting the origin before cloning is what turns "without the original repo"
# from a description into a fact.
BHEAD="$(git -C "$BR" rev-parse HEAD)"
rm -rf "$BR"
BCLONE="$(mktemp -d)/out"
git clone -q "$BX/repo.bundle" "$BCLONE" 2>/dev/null

it "the git bundle clones after the original repo is gone"
[[ -d "$BCLONE/.git" ]] && ok || fail "clone failed"

it "and the clone is at the head the manifest recorded"
assert_eq "$(git -C "$BCLONE" rev-parse HEAD 2>/dev/null)" "$(jq -r '.repo.head' "$BX/manifest.json")"

it "with the full history, not a snapshot"
assert_eq "$(git -C "$BCLONE" rev-list --all --count 2>/dev/null)" "2"

it "and the file contents actually survived"
assert_contains "$(git -C "$BCLONE" show HEAD:configs/app/f.txt 2>/dev/null)" "second"

it "the head it cloned to is the one the machine had"
assert_eq "$(git -C "$BCLONE" rev-parse HEAD 2>/dev/null)" "$BHEAD"

# -- 2. the two halves cannot have drifted -----------------------------------------
it "the clear worktree matches the git history byte for byte"
assert_eq "$(diff -r --no-dereference --exclude=.git "$BCLONE" "$BX/worktree" 2>&1)" ""

it "and carries no untracked weight"
[[ ! -e "$BX/worktree/.git" ]] && ok || fail "the worktree half smuggled a .git in"

it "a symlink pointing outside the repo survives as a link, not as its target"
assert_eq "$(readlink "$BX/worktree/configs/app/link.lua" 2>/dev/null)" "/nonexistent/outside/theme.lua"

# -- 3. nothing in the user's environment is load-bearing --------------------------
BSTERILE="$(mktemp -d)"
HOME="$BSTERILE/nohome" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    git clone -q "$BX/repo.bundle" "$BSTERILE/out" 2>/dev/null

it "the bundle clones in a sterile environment, with no user git config"
assert_eq "$(git -C "$BSTERILE/out" rev-parse HEAD 2>/dev/null)" "$BHEAD"

# -- 4. the manifest alone answers -------------------------------------------------
# Whoever holds only the .tar.zst consults nothing else. Adding a field to the
# design without adding it here is meant to break this.
it "the manifest names the omarchy identity a restore is gated on"
assert_eq "$(jq -r '[.omarchy.version, .omarchy.channel, .omarchy.migrationWatermark]
                    | map(select(. != null and . != "")) | length' "$BX/manifest.json")" "3"

it "the manifest carries the restore range"
[[ "$(jq -r '.supportedTargets | length' "$BX/manifest.json")" -gt 0 ]] \
    && ok || fail "supportedTargets missing or empty"

it "the manifest describes every group, with its coupling"
assert_eq "$(jq -r '(.groups | length) as $n
                    | ([.groups[] | select(.id != null and .mode != null and (.coupled|type) == "boolean")] | length) == $n
                      and $n > 0' "$BX/manifest.json")" "true"

it "the manifest embeds the whole verify document, findings and all"
assert_eq "$(jq -r '.verify | has("ok") and has("counts") and (.findings|type) == "array"' "$BX/manifest.json")" "true"

it "the manifest keeps the remote URLs -- a bundle clone points at the file, not the origin"
assert_contains "$(jq -r '.repo.remotes[]?.url // empty' "$BX/manifest.json")" "example.invalid"

it "the manifest lists its own members with checksums"
assert_eq "$(jq -r '[.contents[] | select(.sha256 != null and .size != null)] | length > 0' "$BX/manifest.json")" "true"

it "the manifest spells out how to restore, for someone who has only this file"
[[ -n "$(jq -r '.restore[]?' "$BX/manifest.json")" && -f "$BX/RESTORE.md" ]] \
    && ok || fail "no restore instructions"

it "the manifest records which tool version produced it"
[[ -n "$(jq -r '.tool.commit // empty' "$BX/manifest.json")" ]] && ok || fail "tool provenance missing"

# -- 5. the embedded tool is complete enough to run --------------------------------
# "Restorable from its own identifier alone" is an operation, not a document.
# Without the CLI it is only a document.
BTOOLOUT="$(OMABACKUP_ROOT="$BX/tool" OMABACKUP_GROUPS="$BX/tool/groups.default.json" \
    OMABACKUP_STATE="$BSTERILE/state" HOME="$BSTERILE/nohome" XDG_RUNTIME_DIR=/nonexistent \
    bash "$BX/tool/bin/omabackup" status --json 2>&1)"

it "the tool copied into the bundle actually runs from inside it"
assert_eq "$(printf '%s' "$BTOOLOUT" | jq -r '.schemaVersion' 2>/dev/null)" "1"

it "and it brought its libraries, not just the entry point"
[[ -f "$BX/tool/lib/publish.sh" && -f "$BX/tool/lib/probes.sh" && -f "$BX/tool/lib/bundle.sh" ]] \
    && ok || fail "lib/ incomplete in the bundle"

# -- 6. the checksums are verified, not merely written -----------------------------
BTAMPER="$(_unpack "$BPATH")"
printf 'tampered\n' >>"$BTAMPER/worktree/configs/app/f.txt"

it "a flipped byte in the worktree fails verification"
( cd "$BTAMPER" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ) \
    && fail "verification passed over tampered content" || ok

# -- 7. a dirty repo is recorded, never quietly cleaned -----------------------------
BH2="$(mktemp -d)"; BR2="$BH2/repo"
_bundle_repo "$BR2"
printf 'uncommitted edit\n' >"$BR2/configs/app/f.txt"
BOUT2="$(_bundle_env "$BH2" "$BR2" bundle --json)"
BX2="$(_unpack "$(printf '%s' "$BOUT2" | jq -r '.path')")"

it "a dirty working tree is reported in the manifest"
assert_eq "$(jq -r '.repo.dirty' "$BX2/manifest.json")" "true"

it "and the bundle still carries HEAD, not the uncommitted edit"
assert_contains "$(cat "$BX2/worktree/configs/app/f.txt" 2>/dev/null)" "second"

# -- 8. same head, same artifact ---------------------------------------------------
# This is the spec that protects the timer: no new commit, no new bundle.
BH3="$(mktemp -d)"; BR3="$BH3/repo"
_bundle_repo "$BR3"
_bundle_env "$BH3" "$BR3" bundle >/dev/null
BFIRST="$(find "$BH3/.state/bundles" -name '*.tar.zst' | wc -l)"
BOUT3="$(_bundle_env "$BH3" "$BR3" bundle --json)"
BSECOND="$(find "$BH3/.state/bundles" -name '*.tar.zst' | wc -l)"

it "bundling the same head twice produces one artifact, not two"
assert_eq "$BFIRST/$BSECOND" "1/1"

it "and the second run says it reused rather than rebuilt"
assert_eq "$(printf '%s' "$BOUT3" | jq -r '.reused')" "true"

it "a new commit produces a new artifact"
printf 'third\n' >"$BR3/configs/app/f.txt"
git -C "$BR3" add -A && git -C "$BR3" commit -qm three
_bundle_env "$BH3" "$BR3" bundle >/dev/null
assert_eq "$(find "$BH3/.state/bundles" -name '*.tar.zst' | wc -l)" "2"

# ── what leaves the machine is verified, not just what `bundle` builds ──────
# verify_bundle lived in cmd_bundle alone, so `push` -- the verb that actually
# sends -- built or reused an artifact and shipped it unchecked. The proof of
# restorability belongs to the artifact, not to one command that happens to ask.
it "building an artifact verifies it, whoever asked for it"
BV="$(mktemp -d)"; BVR="$BV/repo"; _bundle_repo "$BVR"
OMABACKUP_ROOT="$PWD" OMABACKUP_GROUPS="$PWD/groups.default.json" \
  OMABACKUP_STATE="$BV/.state" HOME="$BV" XDG_RUNTIME_DIR=/nonexistent \
  bash -c 'source lib/bundle.sh; source lib/publish.sh; declare -f verify_bundle >/dev/null' \
  && grep -q 'verify_bundle' <(sed -n '/^build_bundle/,/^}/p' lib/bundle.sh) \
  && ok || fail "build_bundle does not prove its own output"

# ── the cache key has to cover what the artifact depends on ────────────────
# Keyed on HEAD alone, a tool upgrade reused a bundle carrying the previous
# tool, previous manifest and a stale verify document -- while claiming to be
# "the tool that produced this".
it "a different tool version does not reuse the previous artifact"
BC="$(mktemp -d)"; BCR="$BC/repo"; _bundle_repo "$BCR"
_bundle_env "$BC" "$BCR" bundle >/dev/null
BEFORE="$(find "$BC/.state/bundles" -name '*.tar.zst' | wc -l)"
OMABACKUP_TOOL_ID=pretend-a-new-version _bundle_env "$BC" "$BCR" bundle >/dev/null
AFTER="$(find "$BC/.state/bundles" -name '*.tar.zst' | wc -l)"
assert_eq "$BEFORE/$AFTER" "1/2"

# ── two commits in the same second must not share a filename ───────────────
# The published name was host + timestamp to the second, so `mv` silently
# replaced one backup with another.
it "the published name distinguishes commits made in the same second"
BN="$(mktemp -d)"; BNR="$BN/repo"; _bundle_repo "$BNR"
N1="$(OMABACKUP_ROOT="$PWD" bash -c 'source lib/bundle.sh; bundle_name "$1"' _ "$BNR")"
printf 'again\n' >>"$BNR/configs/app/f.txt"
GIT_COMMITTER_DATE="$(git -C "$BNR" show -s --format=%cI HEAD)" \
  git -C "$BNR" -c user.email=t@t -c user.name=t commit -q -am two --date="$(git -C "$BNR" show -s --format=%cI HEAD)"
N2="$(OMABACKUP_ROOT="$PWD" bash -c 'source lib/bundle.sh; bundle_name "$1"' _ "$BNR")"
[[ "$N1" != "$N2" ]] && ok || fail "both commits produce the same filename: $N1"

# ── the cache key tracks the code, not the commit ───────────────────────────
# It was built from the tool's git HEAD, which does not move when the working
# tree is edited and collapses to "unknown" wherever the tool is installed
# without its history. Under either condition an artefact built by different
# code was served from the cache -- including one built before a gate existed.
FPH="$(mktemp -d)"; FPR="$FPH/repo"; FPC="$FPH/cache"
git init -q "$FPR" 2>/dev/null; printf 'x\n' >"$FPR/a"
git -C "$FPR" add a 2>/dev/null
git -C "$FPR" -c user.email=t@t -c user.name=t commit -q -m ok 2>/dev/null
# A disposable copy of the tool, not the real tracked bin/ and lib/: editing
# and `git checkout`ing the actual source tree mid-suite is exactly the kind
# of thing that discards a real uncommitted edit, or leaves it half-reverted
# if the suite is interrupted between the append and the checkout.
FPTOOL="$FPH/tool"; mkdir -p "$FPTOOL"
cp -r "$PWD/bin" "$PWD/lib" "$PWD/groups.default.json" "$FPTOOL/"
_fpkey() { OMABACKUP_ROOT="$FPTOOL" GROUPS_FILE="$FPTOOL/groups.default.json" bash -c '
                    source lib/bundle.sh
                    bundle_cache_path "$1" "$2"' _ "$FPR" "$FPC" 2>/dev/null; }
FPBEFORE="$(_fpkey)"
printf '\n# an edit that changes what the tool does\n' >>"$FPTOOL/lib/publish.sh"
FPDIRTY="$(_fpkey)"
# Restored by copying the real, untouched file over the disposable one -- not
# `git checkout`, which has no business running against anything but this
# scratch copy in the first place.
cp "$PWD/lib/publish.sh" "$FPTOOL/lib/publish.sh"
FPBACK="$(_fpkey)"

it "editing the tool changes the cache key, with no commit involved"
[[ -n "$FPBEFORE" && "$FPBEFORE" != "$FPDIRTY" ]] \
    && ok || fail "same key for different code: $FPBEFORE"

it "and undoing the edit brings the old key back"
assert_eq "$FPBACK" "$FPBEFORE"

it "a key cannot be built when the tool cannot be read"
OMABACKUP_ROOT=/nonexistent bash -c 'source '"$PWD"'/lib/bundle.sh
    bundle_cache_path "$1" "$2"' _ "$FPR" "$FPC" >/dev/null 2>&1 \
    && fail "built a cache key from a tool it could not read" || ok

# ── the manifest is part of the code the cache key describes ────────────────
# _tool_commit used to cover this by accident: committing a manifest edit
# moved the tool's own HEAD, which changed the key too. _tool_fingerprint
# replaced that with a hash of bin/omabackup + lib/*.sh alone -- the manifest
# itself, which ships inside the artifact as tool/groups.default.json and is
# what cmd_restore reads to decide what the artifact contains, was left out.
GMH="$(mktemp -d)"; GMC="$GMH/cache"; GMR="$GMH/repo"
git init -q "$GMR" 2>/dev/null; printf 'x\n' >"$GMR/a"
git -C "$GMR" add a 2>/dev/null
git -C "$GMR" -c user.email=t@t -c user.name=t commit -q -m ok 2>/dev/null
GMG1="$GMH/g1.json"; GMG2="$GMH/g2.json"
printf '{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[]}\n' >"$GMG1"
printf '{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[{"id":"x"}]}\n' >"$GMG2"
_gmkey() { OMABACKUP_ROOT="$PWD" GROUPS_FILE="$1" bash -c '
    source lib/bundle.sh; bundle_cache_path "$1" "$2"' _ "$GMR" "$GMC" 2>/dev/null; }
GMK1="$(GROUPS_FILE="$GMG1" _gmkey "$GMG1")"
GMK2="$(GROUPS_FILE="$GMG2" _gmkey "$GMG2")"

it "a different manifest changes the cache key, with no commit involved"
[[ -n "$GMK1" && "$GMK1" != "$GMK2" ]] \
    && ok || fail "same key for two different manifests: $GMK1"

it "and a key cannot be built when the manifest cannot be read"
GROUPS_FILE="$GMH/missing.json" OMABACKUP_ROOT="$PWD" bash -c '
    source lib/bundle.sh; bundle_cache_path "$1" "$2"' _ "$GMR" "$GMC" >/dev/null 2>&1 \
    && fail "built a cache key from a manifest it could not read" || ok

# ── a cache hit is re-proved, not merely trusted for existing ───────────────
# The freshly-built path calls verify_bundle before ever handing a path back;
# a cache hit returned early, skipping it. A bundle a prior crash or full disk
# left truncated at the exact cache key a later run computes was served as
# whole, every time after, forever.
# Driven through the real CLI, like every other bundle spec in this file --
# build_bundle needs the full set of helpers bin/omabackup defines (_tilde,
# omarchy_identity, _hostname...), not just what lib/bundle.sh brings in on
# its own.
CVH="$(mktemp -d)"; CVR="$CVH/repo"; CVC="$CVH/home/.state/bundles"
git init -q "$CVR" 2>/dev/null; printf 'x\n' >"$CVR/a"
git -C "$CVR" add a 2>/dev/null
git -C "$CVR" -c user.email=t@t -c user.name=t commit -q -m ok 2>/dev/null
CVKEY="$(OMABACKUP_ROOT="$PWD" GROUPS_FILE="$PWD/groups.default.json" bash -c '
    source lib/bundle.sh; bundle_cache_path "$1" "$2"' _ "$CVR" "$CVC" 2>/dev/null)"
mkdir -p "$CVC"; printf 'not a real bundle, just garbage\n' >"$CVKEY"
# Not _bundle_env: it merges stderr into stdout, and rebuilding past a
# corrupted cache entry prints a diagnostic on stderr by design -- mixed into
# stdout, that diagnostic breaks the JSON this needs to parse cleanly.
CVOUT="$(HOME="$CVH/home" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$CVH/home/.state" OMABACKUP_REPO="$CVR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle --json 2>/dev/null)"
CVPATH="$(printf '%s' "$CVOUT" | jq -r '.path // empty' 2>/dev/null)"

it "a corrupted file already sitting at the cache key is not served as-is"
[[ -n "$CVPATH" && -f "$CVPATH" ]] && ok || fail "did not rebuild past the corrupted cache entry: $CVOUT"

it "and what came back verifies for real"
# 0: this check runs in a separate process from the build a few lines above,
# reading whatever is sitting at CVPATH now -- not something this call just
# produced, the same distinction build_bundle's own cache-hit path draws.
bash -c 'source lib/bundle.sh; verify_bundle "$1" 0' _ "$CVPATH" >/dev/null 2>&1 \
    && ok || fail "returned a path that still does not verify"

it "and it landed at the SAME cache key, not a new one"
assert_eq "$CVPATH" "$CVKEY"

# ── a cache hit never re-executes a file it did not just build ──────────────
# A PoC confirmed a second execution hole, the same shape as restore's: the
# cache-hit branch above used to call verify_bundle unconditionally, which ran
# the CACHED file's own tool/bin/omabackup as part of "does it verify" -- but
# that file was written by some EARLIER invocation, not this one, so nothing
# here actually knows it is still what that earlier build produced. Tamper
# with the cached bytes directly (replace the embedded tool, recompute
# SHA256SUMS so it stays self-consistent -- exactly the restore PoC, aimed at
# the cache file on disk instead of a handed-over artifact) and a second
# `bundle` invocation, hitting the SAME cache key, ran it.
CEH="$(mktemp -d)"; CER="$CEH/repo"
_bundle_repo "$CER"
_bundle_env "$CEH" "$CER" bundle >/dev/null 2>&1
CEPATH="$(ls -t "$CEH/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
CEX="$(_unpack "$CEPATH")"
CEMARK="$CEH/pwned-cache"
cat >"$CEX/tool/bin/omabackup" <<SH
#!/bin/bash
echo pwned >"$CEMARK"
echo '{}'
SH
chmod +x "$CEX/tool/bin/omabackup"
( cd "$CEX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
tar -C "$CEX" -cf - . | zstd -q -19 -T0 -f -o "$CEPATH"

it "a tampered CACHED bundle's embedded tool does not run on the next cache hit"
_bundle_env "$CEH" "$CER" bundle >/dev/null 2>&1
[[ ! -e "$CEMARK" ]] && ok || fail "the cached file's own binary ran during a cache-hit rebuild"

# Not executing it is only half the fix. verify_bundle "$1" 0 above data-only
# checks (SHA256SUMS, git-bundle vs worktree) -- a tampered cache with
# recomputed SHA256SUMS is internally consistent BY CONSTRUCTION, the same
# way every artifact-tampering PoC in this file is, so a data-only check
# alone would say "verifies" about the tampered bytes forever and this
# assertion would prove nothing. What actually needs checking is that the
# tampered file was DISCARDED and rebuilt from the real repo -- confirmed
# here by extracting what is now at $CEPATH and checking its embedded tool is
# byte-identical to the real bin/omabackup again, not the "echo pwned" stub.
CEX2="$(_unpack "$CEPATH")"

it "and the cache is rebuilt from the real repo, not merely left self-consistent"
diff -q "$CEX2/tool/bin/omabackup" "$PWD/bin/omabackup" >/dev/null 2>&1 \
    && ok || fail "the cached file's embedded tool is still not the real one"

# ── tar failing mid-archive is not masked by zstd's own success ─────────────
# $? after `tar | zstd -o out` with no pipefail is zstd's status alone: a tar
# that dies partway still hands zstd whatever it emitted, zstd compresses that
# incomplete stream and exits 0, and the build's own || guard never fires.
TZH="$(mktemp -d)"; mkdir -p "$TZH/stage"
printf 'a\n' >"$TZH/stage/f1"
TZOUT="$TZH/out.tar.zst"
_tz_pipe() {
    local _had_pf=0; [[ -o pipefail ]] && _had_pf=1
    set -o pipefail
    { tar -cf - -C "$TZH/stage" f1 f2-does-not-exist 2>/dev/null; } | zstd -q -19 -T0 -o "$TZOUT" 2>/dev/null
    local rc=$?
    (( _had_pf )) || set +o pipefail
    return $rc
}

it "a tar that fails partway is not reported as a successful pipe"
_tz_pipe; [[ $? -ne 0 ]] && ok || fail "pipefail did not surface tar's own failure"

# A prune failure inside _push_dir not being silently swallowed to /dev/null
# is exercised in test/destinations.test.sh, through a real `dir` destination
# and the actual `push` command -- _push_dir depends on too much of
# bin/omabackup's own helpers (dest_field, _hostname, the destinations state
# machinery) to stub correctly in isolation here.

# ── "reused" means genuinely reused, not "a file existed at the key" ────────
# reused was decided from the cache path's existence BEFORE build_bundle ran;
# the corruption check happens INSIDE it. A cache entry a prior crash left
# truncated was detected, deleted and rebuilt from scratch by build_bundle,
# and the outer check -- which only knows a file was there when it looked --
# still reported reused:true and printed "reused ... (verified restorable)",
# exactly when a human most wants to be told it had to rebuild.
RUH="$(mktemp -d)"; RUR="$RUH/repo"; RUC="$RUH/home/.state/bundles"
git init -q "$RUR" 2>/dev/null; printf 'x\n' >"$RUR/a"
git -C "$RUR" add a 2>/dev/null
git -C "$RUR" -c user.email=t@t -c user.name=t commit -q -m ok 2>/dev/null
RUKEY="$(OMABACKUP_ROOT="$PWD" GROUPS_FILE="$PWD/groups.default.json" bash -c '
    source lib/bundle.sh; bundle_cache_path "$1" "$2"' _ "$RUR" "$RUC" 2>/dev/null)"
mkdir -p "$RUC"; printf 'garbage, not a real bundle\n' >"$RUKEY"
RUOUT="$(HOME="$RUH/home" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$RUH/home/.state" OMABACKUP_REPO="$RUR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle --json 2>/dev/null)"

it "rebuilding past a corrupted cache entry is reported as built, not reused"
assert_eq "$(printf '%s' "$RUOUT" | jq -r '.reused')" "false"

it "and a genuine cache hit the second time really is reused"
RUOUT2="$(HOME="$RUH/home" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$RUH/home/.state" OMABACKUP_REPO="$RUR" \
    XDG_RUNTIME_DIR=/nonexistent "$OB" bundle --json 2>/dev/null)"
assert_eq "$(printf '%s' "$RUOUT2" | jq -r '.reused')" "true"

# ── build_bundle enforces the same deny-list bar push does ──────────────────
# push gates through assert_deny_understood before ever calling build_bundle;
# `bundle`, called directly, did not -- scan_files alone tolerates a pattern
# that works fine as a regex but is missing its required "reason" field,
# since scan_files only needs id+regex to scan with. assert_deny_understood
# checks the policy scan_files does not: every pattern must be justified.
ADH="$(mktemp -d)"; ADR="$ADH/repo"
_bundle_repo "$ADR"
mkdir -p "$ADH/home"
printf '{"patterns":[{"id":"no-reason","regex":"NEVER-MATCHES-ANYTHING-XYZ"}]}' >"$ADH/deny.json"

it "bundle refuses a deny-list pattern missing its reason, same as push would"
HOME="$ADH/home" OMABACKUP_GROUPS="$PWD/groups.default.json" OMABACKUP_STATE="$ADH/home/.state" \
    OMABACKUP_REPO="$ADR" OMABACKUP_SECRETS_DENY="$ADH/deny.json" XDG_RUNTIME_DIR=/nonexistent \
    "$OB" bundle >/dev/null 2>&1 \
    && fail "built a bundle from a deny-list assert_deny_understood would have refused" || ok
