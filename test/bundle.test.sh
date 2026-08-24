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
