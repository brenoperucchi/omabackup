#!/bin/bash
# The bundle: what every destination other than `github` receives.
#
# docs/DESIGN.md §3 makes git the source of truth for content and hands the
# other destinations an artifact derived from it, so there are never three
# divergent formats to reconcile. §11.4 sets the bar that shapes everything
# here: each destination must be restorable from its own identifier alone.
# Whoever holds only the .tar.zst consults nothing else -- not the repo, not
# the network, not this file.
#
# Which is why the bundle carries the tool that produced it. Without the CLI,
# "restorable" is a document rather than an operation, and a thousand lines of
# bash costs nothing next to being unable to act.
#
# Both halves come from HEAD by construction: the history from `git bundle` and
# the readable copy from `git archive`, never from the working tree. Measured
# on this machine, archive is 1.0MB against 66MB for the directory, because the
# difference is untracked caches -- a user's .gitignore would otherwise become
# backup weight, which is the bug docs/CONTEXT.md §4 already records once.

# bundle_name <repo>
# The published name uses HEAD's own commit timestamp, not the moment of the
# push: the same head then yields the same name at every destination, and
# rebuilding after a wipe reproduces it exactly.
bundle_name() {
    local repo="$1" ts
    ts="$(git -C "$repo" show -s --format=%cd --date=format-local:%Y%m%d-%H%M%S HEAD 2>/dev/null)"
    local sha; sha="$(git -C "$repo" rev-parse --short=12 HEAD 2>/dev/null)"
    # The short sha is not decoration: the timestamp resolves to one second, so
    # two commits made inside the same second produced the same filename and the
    # destination's `mv` replaced one backup with the other. The name stays
    # deterministic -- same head, same name at every destination.
    printf 'omabackup-%s-%s-%s.tar.zst' "$(_hostname)" "${ts:-00000000-000000}" "${sha:-unknown}"
}

# What the tool is, recorded in the manifest: its commit when there is one.
_tool_commit() {
    printf '%s' "${OMABACKUP_TOOL_ID:-$(git -C "$OMABACKUP_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')}"
}

# What the tool's CODE is, which is a different question and the one the cache
# key needs. A commit does not move when the working tree is edited, and it
# collapses to "unknown" wherever the tool is installed without its history --
# so an artefact built by different code was served from the cache under both
# conditions. Hashing the files answers it directly.
_tool_fingerprint() {
    # The override still wins: a caller that names the tool version is naming
    # the thing the key is meant to distinguish.
    if [[ -n "${OMABACKUP_TOOL_ID:-}" ]]; then printf '%s' "$OMABACKUP_TOOL_ID"; return; fi
    # cat's status, read. Piped straight into sha256sum, a cat that could not
    # open a single file still produced the hash of empty input -- a stable,
    # confident-looking fingerprint meaning "I read nothing", which every
    # unreadable installation would have shared.
    local blob h
    [[ -r "$OMABACKUP_ROOT/bin/omabackup" ]] || return 1
    blob="$(cat "$OMABACKUP_ROOT/bin/omabackup" "$OMABACKUP_ROOT"/lib/*.sh 2>/dev/null)" || return 1
    [[ -n "$blob" ]] || return 1
    h="$(printf '%s' "$blob" | sha256sum 2>/dev/null | cut -c1-16)" || return 1
    [[ -n "$h" ]] || return 1
    printf '%s' "$h"
}

# The same hash, computed instead from an already-extracted artifact's own
# embedded copy at <dir>/tool -- used to check a CACHED bundle's actual bytes
# against what _tool_fingerprint() says $OMABACKUP_ROOT would produce right
# now, since the cache key committing to a fingerprint is not the same as the
# file on disk still matching it.
_tool_fingerprint_of() {
    local dir="$1" blob h
    [[ -r "$dir/tool/bin/omabackup" ]] || return 1
    blob="$(cat "$dir/tool/bin/omabackup" "$dir/tool"/lib/*.sh 2>/dev/null)" || return 1
    [[ -n "$blob" ]] || return 1
    h="$(printf '%s' "$blob" | sha256sum 2>/dev/null | cut -c1-16)" || return 1
    [[ -n "$h" ]] || return 1
    printf '%s' "$h"
}

# _bundle_manifest <repo> <staging> — everything a restore needs, in one file.
_bundle_manifest() {
    local repo="$1" stage="$2" dirty ov oc om
    IFS=$'\t' read -r ov oc om <<<"$(omarchy_identity)"
    # Refused here, not merely defaulted at restore time. A bundle built while
    # this machine could not confirm its own migration state would otherwise
    # ship with migrationWatermark: "unreadable" baked in, silently -- and
    # every future restore from it would inherit a compatibility question
    # nobody could ever actually answer. Build time is the moment this is
    # fixable (check the migrations directory); a restore months later, on a
    # different machine, is not.
    # Not just the "unreadable" sentinel: a migrations directory holding a
    # stray file whose name is not a number once `.sh` is stripped (a
    # `junk.sh`, say) makes omarchy_identity's own scan return that name
    # verbatim, neither "unreadable" nor a real watermark. Refused the same
    # way -- a bundle built from it would embed a migrationWatermark no
    # future restore could compare against anything.
    if [[ "$om" == unreadable || ! "$om" =~ ^[0-9]+$ ]]; then
        printf 'omabackup: this machine'"'"'s own migration state could not be confirmed -- refusing to build a bundle nobody could ever restore with confidence\n' \
            >&2
        return 1
    fi
    dirty="$(git -C "$repo" status --porcelain 2>/dev/null)"

    # verify's whole document, verbatim. A boolean does not serve: whoever
    # restores this needs to know *what* was broken when it was taken.
    local vdoc; vdoc="$(FINDINGS=(); JSON=1 cmd_verify 2>/dev/null)"
    [[ -n "$vdoc" ]] || vdoc='{}'

    jq -n \
        --arg host "$(_hostname)" \
        --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg toolcommit "$(_tool_commit)" \
        --arg head "$(git -C "$repo" rev-parse HEAD 2>/dev/null)" \
        --arg branch "$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
        --arg name "$(bundle_name "$repo")" \
        --argjson dirty "$([[ -n "$dirty" ]] && echo true || echo false)" \
        --argjson dirtyCount "$(printf '%s' "$dirty" | grep -c . || true)" \
        --argjson remotes "$(git -C "$repo" remote -v 2>/dev/null \
            | awk '$3=="(fetch)"{print $1"\t"$2}' \
            | jq -R -s 'split("\n") | map(select(length>0) | split("\t") | {name:.[0], url:.[1]})')" \
        --arg ov "$ov" --arg oc "$oc" --arg om "$om" \
        --argjson targets "$(jq '.supportedTargets' "$GROUPS_FILE")" \
        --argjson groups "$(jq '[.groups[] | {id, mode, coupled: (.coupled // false),
                                             critical: (.critical // false),
                                             enabled: (.enabled != false)}]' "$GROUPS_FILE")" \
        --argjson verify "$vdoc" \
        --argjson contents "$(cd "$stage" \
            && find . -type f ! -name manifest.json ! -name SHA256SUMS -printf '%s\t%P\n' 2>/dev/null \
            | while IFS=$'\t' read -r sz p; do
                  printf '%s\t%s\t%s\n' "$(sha256sum "$p" 2>/dev/null | cut -d' ' -f1)" "$sz" "$p"
              done \
            | jq -R -s 'split("\n") | map(select(length>0) | split("\t")
                        | {path:.[2], sha256:.[0], size:(.[1]|tonumber)})')" \
        '{schemaVersion: 1,
          tool: {name: "omabackup", commit: $toolcommit},
          host: $host, createdAt: $created, name: $name,
          repo: {head: $head, branch: $branch, dirty: $dirty, dirtyPaths: $dirtyCount, remotes: $remotes},
          omarchy: {version: $ov, channel: $oc, migrationWatermark: $om},
          supportedTargets: $targets,
          groups: $groups,
          verify: $verify,
          contents: $contents,
          destinations: [],
          restore: [
            "zstd -dc <this file> | tar -x -C <somewhere>",
            "git clone <somewhere>/repo.bundle restored-repo",
            "# or read <somewhere>/worktree/ directly -- no git required",
            "# the tool that made this is at <somewhere>/tool/bin/omabackup",
            "cd restored-repo && git remote set-url origin <the URL under .repo.remotes>"
          ]}'
}

_restore_readme() {
    cat <<'DOC'
# Restoring from this bundle

Everything needed is in this archive. No network, no other copy, no account.

    zstd -dc omabackup-<host>-<stamp>.tar.zst | tar -x -C /tmp/restore
    cd /tmp/restore

Three ways in, in order of preference:

1. **Clone the history.** Full history, every branch, clonable offline:

       git clone repo.bundle restored-repo

   The clone's `origin` will point at `repo.bundle`, not at the original
   forge -- that is how git bundles work. The real URLs are in
   `manifest.json` under `.repo.remotes`; set it back with
   `git remote set-url origin <url>`.

2. **Read the files directly.** `worktree/` is the tracked content in the
   clear, at the same commit as the history above. No git needed.

3. **Run the tool.** `tool/` holds the omabackup that produced this bundle,
   at the version that produced it:

       OMABACKUP_ROOT=$PWD/tool bash tool/bin/omabackup status

Before restoring anything, read `manifest.json`:

- `.omarchy.migrationWatermark` and `.supportedTargets` decide whether this
  backup can be restored onto the target machine at all (DESIGN.md §12).
- `.verify` is the full coverage report as it stood when this was taken. If
  `.verify.ok` is false, something was already broken here -- the findings say
  what, so you do not restore it blind.
- `.repo.dirty` tells you whether uncommitted work existed on the machine.
  This bundle carries HEAD; anything uncommitted was never in it.
- `.destinations` lists where the other copies live.

Verify integrity before trusting any of it:

    sha256sum -c SHA256SUMS
DOC
}

# bundle_cache_path <repo> <cache_dir>
# Keyed on more than HEAD. The artifact also carries the tool, the manifest and
# every ref (`git bundle --all`), so a tool upgrade or a deleted branch used to
# reuse a bundle that no longer described the machine -- while claiming, in its
# own manifest, to be "the tool that produced this". Callers ask this rather
# than rebuilding the path themselves, which silently went wrong the moment the
# key stopped being HEAD alone.
bundle_cache_path() {
    local repo="$1" cache="$2" head key
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || return 1
    [[ -n "$head" ]] || return 1
    local fp refs gh
    fp="$(_tool_fingerprint)" || return 1
    refs="$(git -C "$repo" show-ref 2>/dev/null | sha256sum)" || return 1
    # The manifest, hashed by content. It ships inside the artifact as
    # tool/groups.default.json -- which cmd_restore reads to decide what the
    # artifact even contains -- but the fingerprint above only covers the
    # tool's own code. _tool_commit used to cover this by accident: committing
    # a manifest edit moved HEAD, which changed the key too. Editing the
    # manifest, committing, and building again returned the OLD artifact, with
    # the old manifest inside it and a tool.commit field that no longer
    # described what actually shipped.
    gh="$(sha256sum "$GROUPS_FILE" 2>/dev/null)" || return 1
    [[ -n "$gh" ]] || return 1
    # Two more things a cache hit used to serve stale, silently: this
    # machine's own Omarchy identity, and the deny-list a build's own
    # scan_files pass was judged against. Neither one is reachable from HEAD,
    # the tool, refs, or GROUPS_FILE -- a migration landing changes nothing
    # any of those four track. A PoC confirmed the result: build, let a new
    # migration marker appear, build again -- "reused," and the manifest
    # INSIDE the reused artifact still reported the watermark from before the
    # migration. Any restore comparing against it would be comparing against
    # a number that was never actually this machine's, at the moment that
    # restore needed it to be. Included here the same way GROUPS_FILE is, so
    # either one changing forces a real rebuild instead of serving a manifest
    # -- or a scan result -- that no longer describes the machine or the
    # rules it was judged by.
    local ident deny
    ident="$(omarchy_identity)"
    deny="$(sha256sum "$SECRETS_DENY_FILE" 2>/dev/null)"
    key="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$head" "$fp" "$refs" "$gh" "$ident" "$deny" | sha256sum | cut -c1-16)"
    printf '%s/%s.tar.zst' "$cache" "$key"
}

# build_bundle <repo> <cache_dir>
# Content-addressed, via bundle_cache_path -- HEAD, the tool's own fingerprint,
# every ref, and the manifest's hash, not HEAD alone -- so a timer that fires
# with nothing new to say does no NEW work. A cache hit still re-runs
# verify_bundle on what is already there (0.165s measured, on a 336K bundle
# with 31 commits) rather than trusting that its mere presence at the key
# means it is whole. Prints "<path>\t<reused|built>".
build_bundle() {
    local repo="$1" cache="$2" head stage out
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || return 1
    [[ -n "$head" ]] || return 1

    mkdir -p "$cache" || return 1
    out="$(bundle_cache_path "$repo" "$cache")" || return 1
    # A cache hit is trusted only after it re-proves itself. The freshly-built
    # path at the end of this function calls verify_bundle before ever handing
    # the path back -- a cache hit returned here without it, so a bundle
    # written by a process that crashed or hit a full disk mid-write, and left
    # a truncated file at the exact cache key a later run would compute, was
    # served as though it were whole every time after, never re-checked again.
    #
    # This file was not just built by this call -- it is whatever has been
    # sitting at this cache path since some earlier run, and the cache key
    # (HEAD + tool fingerprint + refs + GROUPS_FILE) only proves this
    # invocation WOULD have built the same bundle again, not that the bytes
    # on disk still are that bundle. _verify_cache_entry checks data (like
    # restore's 0 does, and for the same reason: this call did not just write
    # these bytes) AND that the embedded tool inside it still fingerprints as
    # what $OMABACKUP_ROOT would produce right now -- the specific gap a data-
    # only check cannot see, since a swapped tool with recomputed SHA256SUMS
    # is internally consistent by construction, same as every other artifact-
    # tampering PoC in this file.
    if [[ -f "$out" ]]; then
        _verify_cache_entry "$out" && { printf '%s\treused' "$out"; return 0; }
        printf 'omabackup: the cached bundle at %s failed its own restore check -- rebuilding\n' \
            "$(_tilde "$out")" >&2
        rm -f "$out"
    fi

    # A shallow repo or one leaning on alternates produces a bundle that cannot
    # clone on its own -- exactly the promise being made here.
    [[ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" == "false" ]] \
        || { printf 'omabackup: refusing to bundle a shallow repository\n' >&2; return 1; }

    stage="$(mktemp -d)" || return 1
    mkdir -p "$stage/worktree" "$stage/tool"

    git -C "$repo" bundle create "$stage/repo.bundle" --all HEAD >/dev/null 2>&1 \
        || { rm -rf "$stage"; return 1; }
    git -C "$repo" archive --format=tar HEAD 2>/dev/null | tar -C "$stage/worktree" -x \
        || { rm -rf "$stage"; return 1; }

    # The tool, at the version that made this.
    cp "$OMABACKUP_ROOT/bin/omabackup" "$stage/tool/" 2>/dev/null || { rm -rf "$stage"; return 1; }
    mkdir -p "$stage/tool/bin" && mv "$stage/tool/omabackup" "$stage/tool/bin/"
    cp -r "$OMABACKUP_ROOT/lib" "$stage/tool/" 2>/dev/null || { rm -rf "$stage"; return 1; }
    cp "$GROUPS_FILE" "$stage/tool/groups.default.json" 2>/dev/null || { rm -rf "$stage"; return 1; }

    _restore_readme >"$stage/RESTORE.md"
    _bundle_manifest "$repo" "$stage" >"$stage/manifest.json" || { rm -rf "$stage"; return 1; }
    # Everything assembly added, before it is sealed. `push` gates the
    # repository and then this function copies in the tool, the manifest and the
    # restore notes -- files the gate never saw, riding to the same destinations
    # as the rest. The manifest is the user's own and free to name anything.
    # push gates through assert_deny_understood before it ever calls this --
    # scan_files alone tolerates a deny-list build_bundle called directly
    # never would have: a pattern missing its required "reason", or an
    # exception no pattern can actually produce (dead protection that reads
    # as covered). Neither is a bypass scan_files itself misses -- an empty
    # or otherwise degenerate regex was tried here as a PoC and grep matched
    # EVERYTHING with it, refusing the build outright rather than passing
    # silently -- but `bundle` should not be a laxer gate than `push` for
    # the SAME deny-list just because it was reached a different way. No
    # `||` here: assert_deny_understood calls die() on any problem, which
    # exits the process outright rather than returning -- $stage is left for
    # the OS, same as every other die() already reachable from a build in
    # progress elsewhere in this codebase.
    assert_deny_understood "$SECRETS_DENY_FILE"
    local extra
    extra="$(scan_files "$stage" "$SECRETS_DENY_FILE" 2>&1)" || {
        printf '%somabackup: the secret scan could not run over the staged artefact%s\n' \
            "${RED:-}" "${NC:-}" >&2
        rm -rf "$stage"; return 1
    }
    if [[ -n "$extra" ]]; then
        printf '%somabackup: refusing to build -- the deny-list matched a file assembly added%s\n' \
            "${RED:-}" "${NC:-}" >&2
        printf '%s\n' "$extra" >&2
        rm -rf "$stage"; return 1
    fi

    ( cd "$stage" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum >SHA256SUMS ) \
        || { rm -rf "$stage"; return 1; }

    # pipefail asked for explicitly. Without it, $? after this pipe is zstd's
    # status alone: a tar that dies partway (a file vanishing between staging
    # and archiving) still hands zstd whatever bytes it managed to emit, zstd
    # compresses that incomplete stream and exits 0, and the `||` guard never
    # fires. The self-verify a few lines down would likely still catch this --
    # SHA256SUMS lists what tar failed to include -- but a status this cheap to
    # check should not be left to a downstream safety net to notice instead.
    local _had_pf=0; [[ -o pipefail ]] && _had_pf=1
    set -o pipefail
    tar -C "$stage" -cf - . 2>/dev/null | zstd -q -19 -T0 -o "$out.tmp" 2>/dev/null
    local comprc=$?
    (( _had_pf )) || set +o pipefail
    (( comprc == 0 )) || { rm -rf "$stage" "$out.tmp"; return 1; }
    mv "$out.tmp" "$out" || { rm -rf "$stage" "$out.tmp"; return 1; }
    rm -rf "$stage"
    # Proved here, not in whichever command happened to ask. verify_bundle used
    # to live in cmd_bundle alone, so `push` -- the verb that actually sends --
    # built or reused an artifact and shipped it unchecked. Restorability is a
    # property of the artifact.
    #
    # 1: unlike the cache-hit check above, this file is what the lines just
    # above wrote, in this process, from this machine's own repo -- the one
    # case where proving the embedded tool actually runs is worth doing.
    if ! verify_bundle "$out" 1; then
        rm -f "$out"
        printf 'omabackup: the bundle did not survive its own restore check\n' >&2
        return 1
    fi
    printf '%s\tbuilt' "$out"
}

# _verify_extracted <already-extracted-dir> <run-embedded:0|1>
# The checks over a directory the caller extracted and owns. Split out of
# verify_bundle so a caller that needs the content afterward -- restore is the
# one that does -- extracts once and verifies THAT directory, rather than
# trusting a verify done on a separate extraction of the same artifact file a
# moment earlier. Between two extractions the file on disk can change; a
# restore acting on the second one would then be acting on something the first
# one never actually checked.
#
# <run-embedded> is required, not optional with a default -- a PoC confirmed
# that running the artifact's own tool/bin/omabackup as a "does it work"
# self-check executes arbitrary code with the caller's full privileges, since
# an artifact under attacker control also controls its own SHA256SUMS: it is
# self-consistent by construction, so the checksum check earlier in this same
# function proves nothing about what that binary will do when run. That is
# safe for build_bundle, which verifies output it JUST built on this machine
# from its own repo. It is not safe for restore, which may be handed an
# artifact from anywhere -- another person's machine, a shared destination, a
# stranger's public dotfiles someone is trying to bootstrap from. The PoC's
# script ran in PLAN mode, before --apply, before any consent, contradicting
# the "nothing was written" this command prints in that mode.
#
# A parameter with a default value would have made the SAFE choice the one a
# careless third caller gets by omission -- exactly the shape of bug this
# project keeps finding in itself ("the half that checks and the half that
# packs were reading two repositories," review 4k). ${2?...} makes bash itself
# refuse to run this function at all without an explicit answer.
_verify_extracted() {
    local x="$1" run_embedded="${2?_verify_extracted requires an explicit run-embedded argument (0 or 1)}"
    local clone rc=0
    # ${2?...} refuses an OMITTED argument, but not an empty or malformed one
    # -- and (( run_embedded )) is arithmetic, so "2" or "1+1" both evaluate
    # truthy. An explicit allow-list closes that: anything but the two literal
    # values this function actually understands is refused, not guessed at.
    case "$run_embedded" in
        0|1) ;;
        *) printf 'omabackup: _verify_extracted called with an invalid run-embedded value: %q\n' \
               "$run_embedded" >&2
           return 1 ;;
    esac
    [[ -d "$x" ]] || return 1

    ( cd "$x" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1 ) || rc=1

    clone="$x/.check"
    git clone -q "$x/repo.bundle" "$clone" >/dev/null 2>&1 || rc=1
    if [[ -d "$clone" ]]; then
        [[ "$(git -C "$clone" rev-parse HEAD 2>/dev/null)" == "$(jq -r '.repo.head' "$x/manifest.json" 2>/dev/null)" ]] || rc=1
        # --no-dereference, because a dotfiles repo tracks symlinks that point
        # outside itself: this one has four, to ~/.local/share/omarchy and to a
        # theme under ~/.local/state. Following them compares the machine's
        # current files instead of the backup, and dangling ones fail outright.
        # The link itself is what was backed up, so the link is what is compared.
        diff -r --no-dereference --exclude=.git "$clone" "$x/worktree" >/dev/null 2>&1 || rc=1
    fi

    if (( run_embedded )); then
        OMABACKUP_ROOT="$x/tool" OMABACKUP_GROUPS="$x/tool/groups.default.json" \
            OMABACKUP_STATE="$x/.state" XDG_RUNTIME_DIR=/nonexistent \
            bash "$x/tool/bin/omabackup" status --json >/dev/null 2>&1 || rc=1
    fi

    rm -rf "$clone"
    return $rc
}

# _zstd_extract <archive> <dest-dir>
# tar -xf <(zstd -dc ...) discards zstd's own exit status: the process
# substitution runs zstd in a separate process feeding a pipe, and $? after
# tar reflects only tar's exit, never zstd's. Confirmed with a PoC: a
# .tar.zst holding one complete, valid frame followed by trailing garbage
# bytes extracts every file successfully -- tar reads exactly what it needs
# and exits 0 before zstd's own later failure on the garbage is ever
# observed. A real pipe with pipefail set is checked instead, the same
# reasoning already applied to this file's compression side (build_bundle's
# tar | zstd -o "$out.tmp"): $? reflects the worse of the two commands, not
# whichever one the shell happened to still be waiting on.
_zstd_extract() {
    local archive="$1" dest="$2"
    local _had_pf=0; [[ -o pipefail ]] && _had_pf=1
    set -o pipefail
    zstd -dc "$archive" 2>/dev/null | tar -C "$dest" -x 2>/dev/null
    local rc=$?
    (( _had_pf )) || set +o pipefail
    return $rc
}

# verify_bundle <path> <run-embedded:0|1>
# §11.4 as a check rather than a claim: extract, clone, compare both halves,
# confirm the checksums and, when asked, run the embedded tool. Offline
# throughout, because cloning from a .bundle file is offline by definition.
#
# <run-embedded> is required for the same reason _verify_extracted's is, and
# for a reason specific to this function's own two callers inside
# build_bundle: the fresh-build self-check verifies output THIS call just
# produced, in this process, from this machine's own repo -- trusted, passes
# 1. The cache-hit re-check verifies a file already sitting on disk from
# some EARLIER call, possibly long past -- not "just built" by anything
# happening now, so it cannot inherit that trust. A PoC confirmed the gap
# this closes: a cached bundle whose tool/bin/omabackup was replaced after
# the fact, with SHA256SUMS recomputed to match, ran the replacement during
# a later cache-hit rebuild -- the exact same class of execution restore was
# fixed against, reopened through the cache instead of the artifact file.
verify_bundle() {
    local path="$1" run_embedded="${2?verify_bundle requires an explicit run-embedded argument (0 or 1)}"
    local x rc
    x="$(mktemp -d)" || return 1
    _zstd_extract "$path" "$x" || { rm -rf "$x"; return 1; }
    _verify_extracted "$x" "$run_embedded"; rc=$?
    rm -rf "$x"
    return $rc
}

# _verify_cache_entry <path> -- build_bundle's cache-hit gate specifically,
# not a restore path and not verify_bundle's fresh-build path either. The
# data-only checks (0, same as restore -- this file was not just built by
# this call) prove the cached bytes are internally consistent; a PoC showed
# that alone is not enough here: a cached bundle whose embedded tool was
# replaced, with SHA256SUMS recomputed to stay self-consistent, is internally
# consistent AND still tampered. Restore cannot use this same extra check --
# an old artifact legitimately carries an old tool, built by different code,
# and refusing that would break the one thing restore exists to do. A cache
# entry has no such excuse: bundle_cache_path's own key already commits to
# _tool_fingerprint() matching $OMABACKUP_ROOT, so this is the one place that
# commitment gets checked against the actual bytes on disk, not trusted
# because the path happened to match.
#
# Skipped, not failed, when OMABACKUP_TOOL_ID is set: that override tells
# _tool_fingerprint() to answer with an arbitrary operator-chosen string
# instead of a content hash, and no extraction of a cached file's bytes can
# ever reproduce an arbitrary string -- every cache hit would "fail" this
# check forever, which is a broken cache, not a caught tamper.
_verify_cache_entry() {
    local path="$1" cx rc=0
    cx="$(mktemp -d)" || return 1
    _zstd_extract "$path" "$cx" || { rm -rf "$cx"; return 1; }
    _verify_extracted "$cx" 0 || rc=1
    if (( rc == 0 )) && [[ -z "${OMABACKUP_TOOL_ID:-}" ]]; then
        local cached_fp live_fp
        cached_fp="$(_tool_fingerprint_of "$cx")" || rc=1
        live_fp="$(_tool_fingerprint)" || rc=1
        [[ -n "$cached_fp" && "$cached_fp" == "$live_fp" ]] || rc=1
    fi
    # The tool fingerprint above proves the cached CODE matches what
    # $OMABACKUP_ROOT would produce; it says nothing about the cached POLICY
    # -- tool/groups.default.json, which is what decides which groups are
    # coupled. A PoC confirmed the gap: a cache entry with only that one file
    # swapped (coupled:true -> false, SHA256SUMS recomputed, the tool binary
    # itself untouched) still reused:true'd. bundle_cache_path's own key
    # already commits to sha256sum "$GROUPS_FILE" as one of its inputs (the
    # same reasoning as the tool fingerprint above, same fix): checked here
    # against the actual bytes now sitting in the cached file, not merely
    # trusted because the path happened to match.
    if (( rc == 0 )); then
        local cached_gh live_gh
        cached_gh="$(sha256sum "$cx/tool/groups.default.json" 2>/dev/null | cut -d' ' -f1)"
        live_gh="$(sha256sum "$GROUPS_FILE" 2>/dev/null | cut -d' ' -f1)"
        [[ -n "$cached_gh" && "$cached_gh" == "$live_gh" ]] || rc=1
    fi
    rm -rf "$cx"
    return $rc
}
