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

_tool_commit() {
    printf '%s' "${OMABACKUP_TOOL_ID:-$(git -C "$OMABACKUP_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')}"
}

# _bundle_manifest <repo> <staging> — everything a restore needs, in one file.
_bundle_manifest() {
    local repo="$1" stage="$2" dirty ov oc om
    IFS=$'\t' read -r ov oc om <<<"$(omarchy_identity)"
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
    key="$(printf '%s\n%s\n%s\n' "$head" "$(_tool_commit)" \
            "$(git -C "$repo" show-ref 2>/dev/null | sha256sum)" | sha256sum | cut -c1-16)"
    printf '%s/%s.tar.zst' "$cache" "$key"
}

# build_bundle <repo> <cache_dir>
# Content-addressed by HEAD: the same commit yields the same artifact, so a
# timer that fires with nothing new to say does no work. Prints the path.
build_bundle() {
    local repo="$1" cache="$2" head stage out
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || return 1
    [[ -n "$head" ]] || return 1

    mkdir -p "$cache" || return 1
    out="$(bundle_cache_path "$repo" "$cache")" || return 1
    if [[ -f "$out" ]]; then printf '%s' "$out"; return 0; fi

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

    tar -C "$stage" -cf - . 2>/dev/null | zstd -q -19 -T0 -o "$out.tmp" 2>/dev/null \
        || { rm -rf "$stage" "$out.tmp"; return 1; }
    mv "$out.tmp" "$out" || { rm -rf "$stage" "$out.tmp"; return 1; }
    rm -rf "$stage"
    # Proved here, not in whichever command happened to ask. verify_bundle used
    # to live in cmd_bundle alone, so `push` -- the verb that actually sends --
    # built or reused an artifact and shipped it unchecked. Restorability is a
    # property of the artifact.
    if ! verify_bundle "$out"; then
        rm -f "$out"
        printf 'omabackup: the bundle did not survive its own restore check\n' >&2
        return 1
    fi
    printf '%s' "$out"
}

# verify_bundle <path>
# §11.4 as a check rather than a claim: extract, clone, compare both halves,
# confirm the checksums and run the embedded tool. Offline throughout, because
# cloning from a .bundle file is offline by definition.
verify_bundle() {
    local path="$1" x clone rc=0
    x="$(mktemp -d)" || return 1
    tar -C "$x" -xf <(zstd -dc "$path" 2>/dev/null) 2>/dev/null || { rm -rf "$x"; return 1; }

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

    OMABACKUP_ROOT="$x/tool" OMABACKUP_GROUPS="$x/tool/groups.default.json" \
        OMABACKUP_STATE="$x/.state" XDG_RUNTIME_DIR=/nonexistent \
        bash "$x/tool/bin/omabackup" status --json >/dev/null 2>&1 || rc=1

    rm -rf "$x"
    return $rc
}
