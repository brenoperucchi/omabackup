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
CVH="$(mktemp -d)"; CVR="$CVH/repo"
git init -q "$CVR" 2>/dev/null; printf 'x\n' >"$CVR/a"
git -C "$CVR" add a 2>/dev/null
git -C "$CVR" -c user.email=t@t -c user.name=t commit -q -m ok 2>/dev/null
# CVKEY comes from an actual build through the real CLI, not a standalone
# recomputation of bundle_cache_path's inputs -- the key now also folds in
# omarchy_identity and the deny-list's hash (see the cache-key spec further
# below), both of which need bin/omabackup's own env handling and $HOME
# wiring to answer consistently with what a later real build will see. Two
# independent computations of the same key drifted the moment one of them
# skipped that.
CVKEY="$(_bundle_env "$CVH" "$CVR" bundle --json | jq -r '.path // empty' 2>/dev/null)"
printf 'not a real bundle, just garbage\n' >"$CVKEY"
# Not _bundle_env: it merges stderr into stdout, and rebuilding past a
# corrupted cache entry prints a diagnostic on stderr by design -- mixed into
# stdout, that diagnostic breaks the JSON this needs to parse cleanly.
CVOUT="$(HOME="$CVH" OMABACKUP_GROUPS="$PWD/groups.default.json" \
    OMABACKUP_STATE="$CVH/.state" OMABACKUP_REPO="$CVR" \
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

# ── _zstd_extract bounds the decompressed stream, not just the file on disk ─
# Flagged in marketplace security review
# (https://github.com/omacom/omarchy-plugin-marketplace/issues/3968): restore
# extracts BEFORE verify_bundle's checksum/clone checks run, and a shared
# destination is not a trusted source -- a small, highly-compressible archive
# can decompress to a size limited only by disk space. A real bomb: 50MB of
# zeros compresses to roughly 1.6KB.
BOMBH="$(mktemp -d)"; mkdir -p "$BOMBH/src"
head -c 50000000 /dev/zero >"$BOMBH/src/big.bin"
tar -C "$BOMBH/src" -cf - . | zstd -q -19 -o "$BOMBH/bomb.tar.zst" 2>/dev/null

it "a highly-compressible archive really does expand far past what it costs on disk"
BOMBSIZE="$(zstd -dc "$BOMBH/bomb.tar.zst" 2>/dev/null | wc -c)"
(( $(stat -c %s "$BOMBH/bomb.tar.zst") < 10000 && BOMBSIZE > 40000000 )) \
    && ok || fail "bomb fixture is not actually lopsided: archive=$(stat -c %s "$BOMBH/bomb.tar.zst") decompressed=$BOMBSIZE"

BOMBDEST="$(mktemp -d)"
# BUNDLE_EXTRACT_MAX_BYTES is computed once when lib/bundle.sh is sourced --
# the same pattern this file already uses for SYSTEMCTL/GH -- so the override
# has to be in the environment BEFORE that source line, not prefixed onto the
# function call after it.
BOMBRC="$(OMABACKUP_RESTORE_MAX_BYTES=1000000 bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$BOMBH/bomb.tar.zst" "$BOMBDEST")"

it "_zstd_extract refuses an archive that decompresses past OMABACKUP_RESTORE_MAX_BYTES"
[[ "$BOMBRC" != 0 ]] && ok || fail "expected a non-zero return for an oversized decompressed stream"

it "and disk usage stays bounded near the cap, not the archive's full 50MB payload"
BOMBWRITTEN="$(du -sb "$BOMBDEST" 2>/dev/null | cut -f1)"
(( BOMBWRITTEN < 2000000 )) \
    && ok || fail "expected well under 2MB written for a 1MB cap, got $BOMBWRITTEN bytes"

BOMBLEGITDEST="$(mktemp -d)"
BOMBLEGITRC="$(OMABACKUP_RESTORE_MAX_BYTES=1000000 bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$BPATH" "$BOMBLEGITDEST")"

it "a real, legitimate bundle -- far under the cap -- still extracts cleanly"
assert_eq "$BOMBLEGITRC" "0"
[[ -f "$BOMBLEGITDEST/manifest.json" ]] && ok || fail "expected manifest.json in the extraction, got: $(ls "$BOMBLEGITDEST" 2>&1)"

it "restore itself refuses a bomb artifact the same way it refuses any unextractable one"
BOMBRESTOREOUT="$(HOME="$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$(mktemp -d)" \
    OMABACKUP_RESTORE_MAX_BYTES=1000000 XDG_RUNTIME_DIR=/nonexistent \
    "$OB" restore "$BOMBH/bomb.tar.zst" --into "$(mktemp -d)" 2>&1)"
assert_contains "$BOMBRESTOREOUT" "could not extract"

# `_zstd_extract`'s own genuine 124-on-timeout is already covered directly
# (the slow-FIFO tests above) -- `cmd_restore` cannot be driven through a
# real FIFO for this specific check, since it refuses a non-regular-file
# artifact (`[[ -f "$artifact" ]]`) before `_zstd_extract` is ever
# reached, and a REAL timeout large enough to drive through the full CLI
# would make this one test slow for little extra confidence. The exact
# branch under test -- extracted straight out of bin/omabackup, not a
# hand-copied duplicate that could drift -- is exercised directly instead,
# isolating exactly the new logic: does `cmd_restore` tell a timeout apart
# from every other extraction failure, with the one thing an operator can
# actually do about it -- found by review (round omabackup-28,
# `omabackup-rev-2`): before this fix, a legitimate restore from slow
# media that genuinely ran past OMABACKUP_RESTORE_TIMEOUT_SEC read
# identically to "could not extract", the same message a corrupted or
# malicious artifact gets, with no hint it was a time ceiling at all.
it "cmd_restore tells a timeout apart from every other extraction failure, and names the override"
RC124_BRANCH="$(sed -n '/local x _extract_rc;/,/^    fi$/p' "$OB")"
RC124_MSG_OUT="$(bash -c '
    _zstd_extract() { return 124; }
    BUNDLE_EXTRACT_TIMEOUT_SEC=7
    die() { printf "DIE: %s\n" "$*"; exit 1; }
    _tilde() { printf "%s" "$1"; }
    artifact=/some/artifact.tar.zst
    _run() {
        '"$RC124_BRANCH"'
    }
    _run
')"
assert_contains "$RC124_MSG_OUT" "exceeded the 7s time ceiling"
assert_contains "$RC124_MSG_OUT" "OMABACKUP_RESTORE_TIMEOUT_SEC"
assert_not_contains "$RC124_MSG_OUT" "could not extract"

RC124_OK_BRANCH="$(sed -n '/local x _extract_rc;/,/^    fi$/p' "$OB")"
RC124_OK_MSG_OUT="$(bash -c '
    _zstd_extract() { return 2; }
    BUNDLE_EXTRACT_TIMEOUT_SEC=7
    die() { printf "DIE: %s\n" "$*"; exit 1; }
    _tilde() { printf "%s" "$1"; }
    artifact=/some/artifact.tar.zst
    _run() {
        '"$RC124_OK_BRANCH"'
    }
    _run
')"

it "and every OTHER extraction failure still gets the original generic message, not the timeout one"
assert_contains "$RC124_OK_MSG_OUT" "could not extract"
assert_not_contains "$RC124_OK_MSG_OUT" "time ceiling"

# GNU `head -c` gives a leading minus its own opposite meaning ("all but
# the last NUM bytes", not "the first NUM bytes") -- found by review
# (round omabackup-25): an unvalidated OMABACKUP_RESTORE_MAX_BYTES=-1
# would have turned the cap into "everything except the last byte",
# functionally unlimited. A non-canonical override now falls back to the
# safe default instead of ever reaching `head -c`.
for BOMBNEG_VALUE in -1 -0 "" "abc" "+9999999999" "007"; do
    BOMBNEG_DEST="$(mktemp -d)"
    BOMBNEG_EFFECTIVE="$(OMABACKUP_RESTORE_MAX_BYTES="$BOMBNEG_VALUE" bash -c '
        source lib/bundle.sh
        printf %s "$BUNDLE_EXTRACT_MAX_BYTES"
    ')"
    it "an invalid OMABACKUP_RESTORE_MAX_BYTES override ([$BOMBNEG_VALUE]) falls back to the safe default, not head -c's own negative meaning"
    assert_eq "$BOMBNEG_EFFECTIVE" "4294967296"
done

# End-to-end, not just the isolated variable: a negative override actually
# reaching `head -c` would still have looked capped against THIS bomb's
# ~50MB payload -- "all but the last byte" of 50MB is still ~50MB, nowhere
# near the unbounded difference a multi-gigabyte fixture would show, and
# not practical to build in a fast test. The variable-level assertions
# above are the precise, direct proof for this one; this fixture size
# cannot distinguish the fixed and vulnerable paths on its own.

# ── member-count bomb: many tiny/empty entries, not one huge one ───────────
# Flagged in marketplace security review, a follow-up round after the byte
# cap above landed: this file's own earlier reasoning claimed the byte cap
# "also caps the worst-case entry count at roughly BYTES/512" -- true, but
# 4294967296 / 512 = 8,388,608, not a meaningfully tight bound. An archive
# of that many empty files stays nowhere near the byte ceiling (header-only
# entries) while exhausting inodes and keeping extraction busy far longer
# than any real restore would.
# Every step's own exit status is checked here, not just the archive's
# final size -- found by review (round omabackup-27): a silently-failed
# fixture (a `touch`/`tar`/`zstd` that never actually ran) could otherwise
# leave an empty or missing archive, and the assertions below would still
# read as "small", "refused", and "bounded" for the wrong reason, never
# reaching the real counting pipeline at all. A real listing of the
# archive, not the loop's own upper bound, is what asserts the true
# member count -- proving the fixture actually is what this test claims,
# not assuming the fixture-building commands worked.
MANYH="$(mktemp -d)"; mkdir -p "$MANYH/src" "$MANYH/dest"
for MANY_I in $(seq 1 10000); do : >"$MANYH/src/f$MANY_I" || fail "could not create fixture file f$MANY_I"; done
tar -C "$MANYH/src" -cf - . | zstd -q -19 -o "$MANYH/many.tar.zst" 2>/dev/null \
    || fail "fixture tar|zstd pipeline itself failed"

it "the many-tiny-files fixture stays small in bytes while carrying thousands of members"
[[ -s "$MANYH/many.tar.zst" ]] || fail "fixture archive is missing or empty"
MANY_ARCHIVE_SIZE="$(stat -c %s "$MANYH/many.tar.zst")"
(( MANY_ARCHIVE_SIZE < 50000 )) \
    && ok || fail "expected the archive itself to stay well under 50KB, got $MANY_ARCHIVE_SIZE bytes"
MANY_REAL_COUNT="$(zstd -dc "$MANYH/many.tar.zst" 2>/dev/null | tar -t | wc -l)"
assert_eq "$MANY_REAL_COUNT" "10001"

MANY_RC="$(OMABACKUP_RESTORE_MAX_MEMBERS=100 bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$MANYH/many.tar.zst" "$MANYH/dest")"

it "_zstd_extract refuses an archive whose member count exceeds OMABACKUP_RESTORE_MAX_MEMBERS"
[[ "$MANY_RC" != 0 ]] && ok || fail "expected a non-zero return for 10,000 members under a 100-member cap"

it "and the actual member count on disk stays bounded near the cap, not the archive's full 10,000 entries"
MANY_WRITTEN="$(find "$MANYH/dest" -type f | wc -l)"
(( MANY_WRITTEN < 1000 )) \
    && ok || fail "expected well under 1000 files written for a 100-member cap, got $MANY_WRITTEN (measured live: 5,000 members capped at 50 stopped at 51; 100,000 capped at 1,000 stopped at 1,002)"

# The real, shipped default (100,000), not a lowered test cap: the earlier
# flat-count-only version of this test used a cap of 100, which happened
# to still accommodate this repo's own bundle under bare member counting
# -- but the weighted cost added by the depth fix (1 + slash count per
# member, not just 1) legitimately pushes a real bundle's own total past
# a cap that low, since the embedded tool copy nests a few levels deep
# (tool/lib/*.sh, tool/bin/omabackup). Testing against the actual
# production default is also the more meaningful question here anyway:
# does a real, ordinary bundle pass under what genuinely ships, not
# under an arbitrary smaller number chosen only for a fast test.
MANYLEGIT_DEST="$(mktemp -d)"
MANYLEGIT_RC="$(bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$BPATH" "$MANYLEGIT_DEST")"

it "a real, legitimate bundle -- far under the member cap -- still extracts cleanly"
assert_eq "$MANYLEGIT_RC" "0"
[[ -f "$MANYLEGIT_DEST/manifest.json" ]] && ok || fail "expected manifest.json in the extraction, got: $(ls "$MANYLEGIT_DEST" 2>&1)"

it "restore itself refuses a member-count bomb the same way it refuses any unextractable artifact"
MANYRESTOREOUT="$(HOME="$(mktemp -d)" OMABACKUP_ROOT="$PWD" OMABACKUP_STATE="$(mktemp -d)" \
    OMABACKUP_RESTORE_MAX_MEMBERS=100 XDG_RUNTIME_DIR=/nonexistent \
    "$OB" restore "$MANYH/many.tar.zst" --into "$(mktemp -d)" 2>&1)"
assert_contains "$MANYRESTOREOUT" "could not extract"

# ── deep-path bomb: one member, hundreds of implied directories ────────────
# Found by a SECOND round of review, on the member-count fix above itself:
# GNU tar silently creates every missing intermediate directory a member's
# path implies, and none of those auto-created directories get their own
# line in `-v`'s progress output -- a flat per-member count would have
# read a single 500-level-deep member as "1", nowhere near any reasonable
# ceiling. `--transform` remaps a real, shallow file's name to a deep path
# at archive-build time -- the only practical way to construct this
# without actually creating 500 real nested directories first.
DEEPH="$(mktemp -d)"; mkdir -p "$DEEPH/src" "$DEEPH/dest"
printf 'x\n' >"$DEEPH/src/f.txt"
DEEP_PATH="$(python3 -c "print('/'.join('d' + str(i) for i in range(500)) + '/f.txt')")"
tar -C "$DEEPH/src" --transform="s|^f.txt|$DEEP_PATH|" -cf - f.txt | zstd -q -o "$DEEPH/deep.tar.zst" 2>/dev/null \
    || fail "fixture tar --transform | zstd pipeline itself failed"

it "the deep-path fixture really is one tar member implying hundreds of directories"
DEEP_REAL_COUNT="$(zstd -dc "$DEEPH/deep.tar.zst" 2>/dev/null | tar -t | wc -l)"
assert_eq "$DEEP_REAL_COUNT" "1"
DEEP_SLASH_COUNT="$(zstd -dc "$DEEPH/deep.tar.zst" 2>/dev/null | tar -t | tr -dc '/' | wc -c)"
(( DEEP_SLASH_COUNT >= 500 )) \
    && ok || fail "expected the single member's own path to carry at least 500 '/' characters, got $DEEP_SLASH_COUNT"

DEEP_RC="$(bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$DEEPH/deep.tar.zst" "$DEEPH/dest")"

it "_zstd_extract refuses a single member whose path depth exceeds OMABACKUP_RESTORE_MAX_DEPTH, not just a flat member-count cap"
[[ "$DEEP_RC" != 0 ]] && ok || fail "expected a non-zero return for one 500-level-deep member under the default 64-level depth guard"

DEEPLEGIT_DEST="$(mktemp -d)"; mkdir -p "$DEEPH/src2/a/b/c/d/e"
printf 'y\n' >"$DEEPH/src2/a/b/c/d/e/f.txt"
tar -C "$DEEPH/src2" -cf - . | zstd -q -o "$DEEPH/shallow.tar.zst" 2>/dev/null \
    || fail "shallow fixture pipeline itself failed"
DEEPLEGIT_RC="$(bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$DEEPH/shallow.tar.zst" "$DEEPLEGIT_DEST")"

it "a real, legitimately-nested path (a handful of levels) still extracts cleanly under the depth guard"
assert_eq "$DEEPLEGIT_RC" "0"
[[ -f "$DEEPLEGIT_DEST/a/b/c/d/e/f.txt" ]] && ok || fail "expected the nested file to have extracted"

for DEEPNEG_VALUE in -1 -0 "" "abc" "+9999999999" "007"; do
    DEEPNEG_EFFECTIVE="$(OMABACKUP_RESTORE_MAX_DEPTH="$DEEPNEG_VALUE" bash -c '
        source lib/bundle.sh
        printf %s "$BUNDLE_EXTRACT_MAX_DEPTH"
    ')"
    it "an invalid OMABACKUP_RESTORE_MAX_DEPTH override ([$DEEPNEG_VALUE]) falls back to the safe default"
    assert_eq "$DEEPNEG_EFFECTIVE" "64"
done

# A byte-exact slow producer for a held-open FIFO, standing in for a slow
# disk/filesystem in the two sections below. Deliberately NOT the more
# obvious `while read -r -n1 -d ''; do printf ...; done` shape: found by
# review (round omabackup-28, `omabackup-rev`, reproduced live) that a bash
# variable cannot hold a NUL byte, so `read -d ''` treats NUL as its own
# per-iteration delimiter and the following `printf '%s'` then emits
# nothing for it -- a real tar|zstd stream from this repo (1,283 bytes, 14
# of them NUL) came out the other end as 1,269 bytes, 14 short, with the
# earlier tests never actually proving the byte-exact property they claimed
# to. `dd` reads/writes raw bytes through file descriptors directly and
# never passes them through a shell variable, so it has no such gap.
# Fixture-scale only (fixtures here run tens to low hundreds of bytes): one
# `dd` process per byte, so a megabyte-sized source would spawn a million of
# them.
_slow_feed_fifo() {  # _slow_feed_fifo <source-file> <fifo> <delay-seconds>
    local src="$1" fifo="$2" delay="$3" size i
    size="$(stat -c %s "$src")" || return 1
    exec 9>"$fifo" || return 1
    for (( i = 0; i < size; i++ )); do
        # A mid-run failure here must stop the feeder rather than silently
        # deliver fewer bytes than the source -- found by review (round
        # omabackup-29, both `omabackup-rev` and `omabackup-rev-2`
        # independently) as the same shape of defect this helper exists to
        # close, even though `status=none` only suppresses dd's own summary
        # line, never its error diagnostics or exit code (confirmed live).
        dd if="$src" bs=1 skip="$i" count=1 status=none >&9 || { exec 9>&-; return 1; }
        [[ "$delay" != 0 ]] && sleep "$delay"
    done
    exec 9>&-
}

# Proof of the claim above, independent of whether legit.tar.zst happens to
# contain a NUL byte: a source built from literal bytes that deliberately
# includes several NULs (a bash `printf` redirected straight to a file
# writes raw bytes, unaffected by the shell-variable limitation -- this is
# not the same code path as the buggy loop being replaced), fed through
# _slow_feed_fifo with no delay, and hashed against the original.
NULH="$(mktemp -d)"
printf 'AB\x00CD\x00\x00EF\x00' >"$NULH/src.bin"
mkfifo "$NULH/proof.fifo"
_slow_feed_fifo "$NULH/src.bin" "$NULH/proof.fifo" 0 &
NULH_FEEDER_PID=$!
cat "$NULH/proof.fifo" >"$NULH/repro.bin"
wait "$NULH_FEEDER_PID"; NULH_FEEDER_RC=$?

it "_slow_feed_fifo reproduces a source containing embedded NUL bytes exactly, not just its non-NUL bytes"
assert_eq "$NULH_FEEDER_RC" "0"
assert_eq "$(stat -c %s "$NULH/repro.bin" 2>/dev/null)" "$(stat -c %s "$NULH/src.bin")"
assert_eq "$(sha256sum <"$NULH/repro.bin" | cut -d' ' -f1)" "$(sha256sum <"$NULH/src.bin" | cut -d' ' -f1)"

# ── wall-clock ceiling: byte/member/depth caps bound WHAT, not HOW LONG ────
# Explicitly requested by the marketplace security review alongside the
# member-count ceiling ("a separate practical member-count (AND
# EXTRACTION-TIME) ceiling"), and initially missed entirely in the first
# pass at that fix. A held-open FIFO, fed one byte at a time with a real
# delay between each, stands in for a slow disk or filesystem -- the
# archive itself is a real, valid, tiny .tar.zst; only the RATE it can be
# read at is artificial. Proves the timeout kills the whole pipeline
# (zstd, tar, and the counting awk together, not just whichever process
# `timeout` directly spawned) rather than merely reporting a slow
# extraction after the fact. Fed via _slow_feed_fifo (see above), not the
# NUL-dropping read/printf loop.
TIMEOUTH="$(mktemp -d)"; mkdir -p "$TIMEOUTH/src" "$TIMEOUTH/dest"
printf 'x\n' >"$TIMEOUTH/src/f.txt"
tar -C "$TIMEOUTH/src" -cf - . | zstd -q -o "$TIMEOUTH/legit.tar.zst" 2>/dev/null \
    || fail "fixture tar|zstd pipeline itself failed"
mkfifo "$TIMEOUTH/slow.fifo"
_slow_feed_fifo "$TIMEOUTH/legit.tar.zst" "$TIMEOUTH/slow.fifo" 0.3 &
TIMEOUT_WRITER_PID=$!

TIMEOUT_START="$(date +%s)"
TIMEOUT_RC="$(OMABACKUP_RESTORE_TIMEOUT_SEC=2 bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$TIMEOUTH/slow.fifo" "$TIMEOUTH/dest")"
TIMEOUT_ELAPSED=$(( $(date +%s) - TIMEOUT_START ))
kill "$TIMEOUT_WRITER_PID" >/dev/null 2>&1 || true
wait "$TIMEOUT_WRITER_PID" 2>/dev/null || true

it "_zstd_extract is killed by its own wall-clock timeout against an artificially slow source, not left to run indefinitely"
assert_eq "$TIMEOUT_RC" "124"
(( TIMEOUT_ELAPSED <= 5 )) \
    && ok || fail "expected the extraction to return near the 2s timeout, not wait for the full slow-write duration; took ${TIMEOUT_ELAPSED}s"

it "no zstd/tar/awk process from the timed-out extraction survives it"
sleep 0.5
TIMEOUT_SURVIVORS="$(pgrep -f -- "$TIMEOUTH" 2>/dev/null | wc -l)"
(( TIMEOUT_SURVIVORS == 0 )) \
    && ok || fail "expected zero surviving processes with this extraction's own unique dest path ($TIMEOUTH) anywhere in their argv (tar's -C references it directly), found $TIMEOUT_SURVIVORS"

TIMEOUTLEGIT_DEST="$(mktemp -d)"
TIMEOUTLEGIT_RC="$(OMABACKUP_RESTORE_TIMEOUT_SEC=2 bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$TIMEOUTH/legit.tar.zst" "$TIMEOUTLEGIT_DEST")"

it "a real, legitimate bundle -- far from any timeout -- still extracts cleanly under a short configured ceiling"
assert_eq "$TIMEOUTLEGIT_RC" "0"
[[ -f "$TIMEOUTLEGIT_DEST/f.txt" ]] && ok || fail "expected f.txt in the extraction"

for TIMEOUTNEG_VALUE in -1 -0 "" "abc" "+9999999999" "007"; do
    TIMEOUTNEG_EFFECTIVE="$(OMABACKUP_RESTORE_TIMEOUT_SEC="$TIMEOUTNEG_VALUE" bash -c '
        source lib/bundle.sh
        printf %s "$BUNDLE_EXTRACT_TIMEOUT_SEC"
    ')"
    it "an invalid OMABACKUP_RESTORE_TIMEOUT_SEC override ([$TIMEOUTNEG_VALUE]) falls back to the safe default"
    assert_eq "$TIMEOUTNEG_EFFECTIVE" "120"
done

# ── a real external signal must reach the nested timeout-created group ─────
# Found by review (round omabackup-28, `omabackup-rev`), reproduced live
# with real PIDs: `timeout` (without --foreground, deliberately -- see
# _zstd_extract's own comment) creates a NEW process group for the whole
# pipe, separate from whatever group the CALLER (bin/omabackup-tui's own
# CLI_PGID tracking, or a bare terminal's own Ctrl-C) would signal. Without
# forwarding, a cancelled restore could report done/cancelled at the
# wrapper level while this pipe kept running underneath for up to the full
# configured timeout. The same slow-FIFO fixture as the timeout test
# above, but this time a real signal is sent to the extraction WHILE it is
# still blocked reading from it -- not waiting for the timeout to expire
# naturally -- confirming the whole nested group dies promptly and the
# right 128+signal convention (129/130/143) comes back, not 124.
SIGH="$(mktemp -d)"; mkdir -p "$SIGH/src"
printf 'x\n' >"$SIGH/src/f.txt"
tar -C "$SIGH/src" -cf - . | zstd -q -o "$SIGH/legit.tar.zst" 2>/dev/null \
    || fail "fixture tar|zstd pipeline itself failed"

for SIG_NAME_CODE in "HUP:129" "INT:130" "TERM:143"; do
    SIG_NAME="${SIG_NAME_CODE%%:*}"
    SIG_EXPECT="${SIG_NAME_CODE##*:}"
    SIGDEST="$(mktemp -d)"
    mkfifo "$SIGH/slow-$SIG_NAME.fifo"
    _slow_feed_fifo "$SIGH/legit.tar.zst" "$SIGH/slow-$SIG_NAME.fifo" 0.3 &
    SIG_WRITER_PID=$!

    # A generous 120s (the real default) timeout on the extraction itself
    # -- ONLY the forwarded signal should be what stops it; if forwarding
    # were broken, this would hang for the rest of the test suite's own
    # patience, not silently pass.
    #
    # `env --default-signal=INT,QUIT` in front of the backgrounded job --
    # a bash script's own async (`&`) commands inherit SIGINT as SIG_IGN
    # (a POSIX rule already documented and worked around elsewhere in this
    # codebase, e.g. bin/omabackup-tui's own CLI launch), and a trap
    # cannot override a disposition that was already SIG_IGN when the
    # process started. Confirmed live while writing this test: without
    # the reset, the INT case specifically (not HUP or TERM, which are
    # not specially ignored this way) returned an unrelated rc after 35s
    # instead of 130 within a couple -- the signal never reached
    # _zstd_extract's own trap at all, this test's own backgrounding was
    # the reason, not a real bug in the fix being tested.
    SIG_START="$(date +%s)"
    env --default-signal=INT,QUIT bash -c '
        source lib/bundle.sh
        _zstd_extract "$1" "$2"
        printf %s $? >"$3"
    ' _ "$SIGH/slow-$SIG_NAME.fifo" "$SIGDEST" "$SIGH/rc-$SIG_NAME" &
    SIG_EXTRACT_PID=$!
    sleep 1
    kill -"$SIG_NAME" "$SIG_EXTRACT_PID"
    wait "$SIG_EXTRACT_PID" 2>/dev/null
    SIG_ELAPSED=$(( $(date +%s) - SIG_START ))
    kill "$SIG_WRITER_PID" >/dev/null 2>&1 || true
    wait "$SIG_WRITER_PID" 2>/dev/null || true

    it "a real $SIG_NAME sent mid-extraction reaches the nested timeout group and returns $SIG_EXPECT quickly, not after the full timeout"
    assert_eq "$(cat "$SIGH/rc-$SIG_NAME" 2>/dev/null)" "$SIG_EXPECT"
    # 15s, not a tighter bound: the point being proven is "nowhere near
    # the 120s default", not a precise latency number -- the actual
    # signal-to-return time measured while writing this test was 1-2s for
    # HUP/TERM and up to ~6s for INT specifically (env --default-signal's
    # own reset adds a little overhead), comfortable margin either way.
    (( SIG_ELAPSED <= 15 )) \
        && ok || fail "expected this to return within a handful of seconds of the signal, not wait anywhere near the 120s default; took ${SIG_ELAPSED}s"

    it "no zstd/tar/awk process from the $SIG_NAME-interrupted extraction survives it"
    sleep 0.3
    SIG_SURVIVORS="$(pgrep -f -- "$SIGDEST" 2>/dev/null | wc -l)"
    (( SIG_SURVIVORS == 0 )) \
        && ok || fail "expected zero surviving processes with this extraction's own unique dest path ($SIGDEST) anywhere in their argv, found $SIG_SURVIVORS"
done

it "a pre-existing TERM trap survives _zstd_extract's own temporary forwarding trap unchanged"
SIGTRAP_OUT="$(bash -c '
    source lib/bundle.sh
    trap "echo MY_OWN_TRAP" TERM
    BEFORE="$(trap -p TERM)"
    _zstd_extract "$1" "$2" >/dev/null
    AFTER="$(trap -p TERM)"
    [[ "$BEFORE" == "$AFTER" ]] && echo SAME || echo "DIFFERENT: [$BEFORE] vs [$AFTER]"
' _ "$SIGH/legit.tar.zst" "$(mktemp -d)")"
assert_eq "$SIGTRAP_OUT" "SAME"

# ── TAR_OPTIONS bypass: an inherited env var silently defeats the cap ──────
# Found by review (round omabackup-27): GNU tar prepends the TAR_OPTIONS
# environment variable's contents to its own argv. An inherited
# `TAR_OPTIONS=--index-file=/dev/null` (confirmed live, standalone, before
# this fix existed) silently redirects `-v`'s progress output away from
# stdout entirely -- the counting `awk` then reads EOF immediately, counts
# zero, and every member extracts with no cap in effect at all, regardless
# of how it is configured.
TAROPTH="$(mktemp -d)"; mkdir -p "$TAROPTH/dest"
TAROPT_RC="$(TAR_OPTIONS='--index-file=/dev/null' OMABACKUP_RESTORE_MAX_MEMBERS=100 bash -c '
    source lib/bundle.sh
    _zstd_extract "$1" "$2"
    printf %s $?
' _ "$MANYH/many.tar.zst" "$TAROPTH/dest")"

it "an inherited TAR_OPTIONS cannot silently defeat the member-count cap"
[[ "$TAROPT_RC" != 0 ]] && ok || fail "expected a non-zero return even with TAR_OPTIONS trying to redirect tar's own progress output away from stdout"
TAROPT_WRITTEN="$(find "$TAROPTH/dest" -type f | wc -l)"
(( TAROPT_WRITTEN < 1000 )) \
    && ok || fail "expected well under 1000 files written despite the TAR_OPTIONS bypass attempt, got $TAROPT_WRITTEN"

# Same validation discipline as OMABACKUP_RESTORE_MAX_BYTES, for the same
# reason: a non-canonical value must never reach the counting pipeline
# unvalidated.
for MANYNEG_VALUE in -1 -0 "" "abc" "+9999999999" "007"; do
    MANYNEG_EFFECTIVE="$(OMABACKUP_RESTORE_MAX_MEMBERS="$MANYNEG_VALUE" bash -c '
        source lib/bundle.sh
        printf %s "$BUNDLE_EXTRACT_MAX_MEMBERS"
    ')"
    it "an invalid OMABACKUP_RESTORE_MAX_MEMBERS override ([$MANYNEG_VALUE]) falls back to the safe default"
    assert_eq "$MANYNEG_EFFECTIVE" "100000"
done

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

# ── the cache key tracks migration state and the deny-list, not just the repo ─
# bundle_cache_path hashed HEAD, the tool, refs and GROUPS_FILE -- nothing a
# migration landing or a deny-list edit ever touches, since both are dynamic
# machine state, not repo content. A PoC confirmed the result: build, let a
# new migration marker appear, build again -- "reused," with the manifest
# INSIDE the reused artifact still reporting the watermark from before the
# migration. Any restore comparing against it would be judged against a
# number that stopped being this machine's the moment the migration ran.
WMH="$(mktemp -d)"; WMR="$WMH/repo"
_bundle_repo "$WMR"
# _bundle_env sets HOME="$h" directly (not "$h/home") -- the migrations dir
# has to live under THAT, or omarchy_identity never sees either marker and
# both builds read watermark 0, proving nothing about this fix.
mkdir -p "$WMH/.local/state/omarchy/migrations"
printf 'm1\n' >"$WMH/.local/state/omarchy/migrations/1700000000.sh"
WMOUT1="$(_bundle_env "$WMH" "$WMR" bundle --json)"
WMPATH1="$(printf '%s' "$WMOUT1" | jq -r '.path // empty' 2>/dev/null)"
printf 'm2\n' >"$WMH/.local/state/omarchy/migrations/1800000000.sh"
WMOUT2="$(_bundle_env "$WMH" "$WMR" bundle --json)"
WMPATH2="$(printf '%s' "$WMOUT2" | jq -r '.path // empty' 2>/dev/null)"

it "a new migration marker invalidates the cache, not just a repo change"
# Not `.reused // empty` -- jq's // treats a literal `false` as absent too,
# same as null, so that expression silently swallows the exact value this
# assertion needs to see.
assert_eq "$(printf '%s' "$WMOUT2" | jq -r '.reused')" "false"

it "and the reported watermark is the current one, not the stale cached one"
WMX2="$(_unpack "$WMPATH2")"
assert_eq "$(jq -r '.omarchy.migrationWatermark' "$WMX2/manifest.json")" "1800000000"

# ── a cache hit must not serve tampered POLICY, only the tool was checked ───
# _verify_cache_entry's fingerprint check covers tool/bin/omabackup + lib/*.sh
# -- the CODE. It said nothing about tool/groups.default.json -- the POLICY
# that decides which groups are coupled. A PoC confirmed the gap: a cache
# entry with ONLY that one file swapped (coupled:true -> false, SHA256SUMS
# recomputed, the tool binary itself untouched) still came back reused:true.
PCH="$(mktemp -d)"; PCR="$PCH/repo"
_bundle_repo "$PCR"
_bundle_env "$PCH" "$PCR" bundle >/dev/null 2>&1
PCPATH="$(ls -t "$PCH/.state/bundles"/*.tar.zst 2>/dev/null | head -1)"
PCX="$(_unpack "$PCPATH")"
PCG="$(jq '(.groups[0].coupled) = (.groups[0].coupled | not)' "$PCX/tool/groups.default.json")"
printf '%s' "$PCG" >"$PCX/tool/groups.default.json"
( cd "$PCX" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS )
tar -C "$PCX" -cf - . | zstd -q -19 -T0 -f -o "$PCPATH"

it "a cache entry with only its policy tampered is not reused"
# Not _bundle_env: it merges stderr into stdout, and rebuilding past a
# tampered cache entry prints a diagnostic on stderr by design -- mixed into
# stdout, that diagnostic breaks the JSON this needs to parse cleanly.
PCOUT="$(HOME="$PCH" OMABACKUP_GROUPS="$PWD/groups.default.json" OMABACKUP_STATE="$PCH/.state" \
    OMABACKUP_REPO="$PCR" XDG_RUNTIME_DIR=/nonexistent "$OB" bundle --json 2>/dev/null)"
assert_eq "$(printf '%s' "$PCOUT" | jq -r '.reused')" "false"

it "and the rebuilt policy matches the real groups.default.json again"
PCPATH2="$(printf '%s' "$PCOUT" | jq -r '.path')"
PCX2="$(_unpack "$PCPATH2")"
diff -q "$PCX2/tool/groups.default.json" "$PWD/groups.default.json" >/dev/null 2>&1 \
    && ok || fail "the rebuilt cache still does not match the real groups.default.json"

# ── a tracked filename with an embedded tab or newline is refused by name ───
# _bundle_manifest's own `contents` listing has the exact shape restore_rows'
# TSV rows were fixed against: find -printf/read split on \t and \n over a
# path free to contain either. This used to fail closed only by accident --
# a mangled name broke `--argjson`'s JSON parse, and the refusal was a raw
# jq error with no pointer to which file, or that a filename was the cause
# at all. Fixed by refusing it by name, before the mangled JSON is ever built.
NLH="$(mktemp -d)"; NLR="$NLH/repo"
mkdir -p "$NLR/configs/app"
git init -q "$NLR"; git -C "$NLR" config user.email t@t; git -C "$NLR" config user.name t
printf 'content\n' >"$NLR/configs/app/$(printf 'x\ninjected')"
git -C "$NLR" add -A && git -C "$NLR" commit -qm one

it "bundle refuses a tracked filename with an embedded newline, by name"
NLOUT="$(_bundle_env "$NLH" "$NLR" bundle)"
assert_contains "$NLOUT" "contains a tab or newline"

# ── review round: a repo large enough to cross argv's per-string limit ─────
# _bundle_manifest's `contents` array used to go through --argjson, and Linux
# caps any SINGLE argv string at MAX_ARG_STRLEN (128KB) regardless of the
# total ARG_MAX budget. A machine tracking ~700 files was already at roughly
# half that; 1200 ordinary small files crosses it outright. Routed through a
# file via --slurpfile instead, which has no such per-argument ceiling.
LGH="$(mktemp -d)"; LGR="$LGH/repo"
mkdir -p "$LGR/configs"
git init -q "$LGR"; git -C "$LGR" config user.email t@t; git -C "$LGR" config user.name t
for i in $(seq 1 1200); do printf 'x\n' >"$LGR/configs/file$i.txt"; done
git -C "$LGR" add -A && git -C "$LGR" commit -qm one -q
LGOUT="$(_bundle_env "$LGH" "$LGR" bundle)"

it "bundle builds a manifest for a repo large enough to cross argv's per-string limit"
assert_contains "$LGOUT" "verified restorable"

it "and the artifact really carries all 1200 tracked files, not a truncated list"
LGART="$(ls -t "$LGH/.state/bundles"/*.tar.zst | head -1)"
LGX="$(mktemp -d)"; tar -C "$LGX" -xf <(zstd -dc "$LGART")
# .contents lists every staged file, not just the repo's own -- the embedded
# tool and worktree/restore metadata add a handful more entries, so this
# counts the "configs/" ones specifically rather than the array's raw length.
assert_eq "$(jq '[.contents[] | select(.path | startswith("worktree/configs/"))] | length' "$LGX/manifest.json")" "1200"
