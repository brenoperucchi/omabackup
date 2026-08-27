#!/bin/bash
# Publishing the staging area into a destination repo -- the mapping step
# between omabackup's HOME-shaped staging and the repo layout an existing
# dotfiles repo already uses (configs/, dotfiles/, state/, scripts/, lists/,
# patches/). This is the same mapping docs/CONTEXT.md §4 describes for
# sync.sh; a repo already using that layout needs no new conventions.
#
# Publish WRITES into the destination repo's working tree, uncommitted --
# same philosophy sync.sh always had: "review with git status/diff before
# committing". cmd_sync (in bin/omabackup) is what turns that into a commit.

# map_to_repo <path-relative-to-HOME> [<tracked-table>]
# Prints the path relative to the repo root, or fails (empty stdout, exit 1)
# for anything that needs special handling by its caller (plugins, generated
# lists).
#
# The table is `<prefix-relative-to-HOME>\t<repo-path>` lines built from the
# manifest's `trackedRepoPath` entries (bin/omabackup:tracked_path_map). It is
# consulted first, and maps flat -- the repo keeps one directory of names, not
# a mirror of the live tree. Before this, map_to_repo repeated one of those
# destinations as a literal and refused the other two outright, so the whole
# `scripts` group was collected into staging and then silently dropped on the
# way to the repo. The manifest declares the destination; this only honors it.
map_to_repo() {
    local rel="$1" table="${2:-}" prefix dest
    # The FIRST matching prefix used to win, not the most specific one -- if
    # the table declares BOTH "root" and "root/nested" (an override for a
    # directory nested inside another trackedRepoPath), a file under
    # root/nested/ matches both, and which one answered depended on table
    # ORDER, not on which mapping was actually meant for it. A PoC confirmed
    # the result changed with the two entries simply swapped. Every match is
    # considered now; the LONGEST prefix -- the most specific one -- wins,
    # regardless of where in the table it happens to sit.
    local best_prefix="" best_dest=""
    while IFS=$'\t' read -r prefix dest; do
        [[ -n "$prefix" && -n "$dest" ]] || continue
        [[ "$rel" == "$prefix"/* ]] || continue
        (( ${#prefix} > ${#best_prefix} )) && { best_prefix="$prefix"; best_dest="$dest"; }
    done <<<"$table"
    if [[ -n "$best_prefix" ]]; then
        printf '%s/%s' "$best_dest" "${rel##*/}"
        return 0
    fi

    case "$rel" in
        .config/omarchy/plugins/*) return 1 ;;  # triple strategy, not a plain copy
        .config/*)                  printf 'configs/%s' "${rel#.config/}" ;;
        .local/state/omarchy/*)     printf 'state/omarchy/%s' "${rel#.local/state/omarchy/}" ;;
        # An executables directory the manifest never gave a trackedRepoPath:
        # refuse rather than guess, or a stray `~/.local/bin` declaration
        # publishes 15MB of mise and npm shims under dotfiles/.
        .local/bin/*|bin/*)          return 1 ;;
        .*)                          printf 'dotfiles/%s' "$rel" ;;  # a top-level dotfile
        *)                           return 1 ;;
    esac
}

# A .json file gets its keys sorted on the way in. Quickshell and
# omarchy-shell-config serialize shell.json differently (insertion order vs.
# `jq -S`), and without normalizing, moving one bar widget rewrites the whole
# file in the diff. See docs/DESIGN.md §11.1.
# _publish_contained <path> <base>
# Self-contained rather than reusing lib/restore.sh's _path_contained --
# publish.sh is sourced standalone in its own tests, and a cross-file
# function dependency would break there. Same logic: realpath -m resolves
# the parts of <path> that exist (following any symlink along the way) and
# normalizes the rest lexically, in one pass -- the two ways a path escapes
# its base, whether or not <path> itself exists yet.
_publish_contained() {
    local p="$1" base="$2" rp base_rp
    rp="$(realpath -m -- "$p" 2>/dev/null)" || return 1
    base_rp="$(realpath -e -- "$base" 2>/dev/null)" || return 1
    [[ -n "$rp" && -n "$base_rp" ]] || return 1
    [[ "$rp" == "$base_rp" || "$rp" == "$base_rp"/* ]]
}

_publish_file() {  # _publish_file <src> <dst> <repo-root>
    local src="$1" dst="$2" base="$3"
    # --remove-destination two lines down protects the FINAL component --
    # confirmed separately that it does nothing for a symlink higher up the
    # path. A PoC: repo/configs -> /tmp/outside (an existing symlinked
    # ANCESTOR directory, not the file itself). mkdir -p follows it same as
    # any real directory would, and the write landed in /tmp/outside instead
    # of inside the repo, rc=0. Checked before mkdir -p ever runs, since by
    # the time it has run the escape has already happened.
    _publish_contained "$(dirname "$dst")" "$base" || return 1
    mkdir -p "$(dirname "$dst")" || return 1
    # A symlink is content: copied as a link, never followed. Publishing what it
    # points at would silently turn a link into a fat copy of somebody else's
    # file, and a link pointing outside the tree would either fail or drag in
    # something that was never declared.
    if [[ -L "$src" ]]; then
        rm -f "$dst" 2>/dev/null
        cp -P "$src" "$dst"
    elif [[ "$dst" == *.json ]] && jq -e . "$src" >/dev/null 2>&1; then
        jq -S . "$src" >"$dst.tmp" && mv "$dst.tmp" "$dst"
    else
        # `cp -p`, not `rsync`. rsync costs ~44ms to start against cp's ~0.5ms,
        # and this runs once per staged file: 597 files spent 27 of a sync's 33
        # seconds paying rsync startup, which is what made a frequent timer
        # indefensible. rsync buys nothing for a single regular file.
        # --remove-destination because plain cp FOLLOWS a symlink already at
        # the destination and writes through it: with a repo path that is a link
        # pointing outside the repo, publish overwrote somebody else's file
        # instead of replacing the link. The link is unlinked first now.
        cp -p --remove-destination "$src" "$dst"
    fi
}

# Explicit renames for what `collect_generated` writes -- the repo's existing
# names predate this tool and do not match 1:1.
_generated_repo_name() {
    case "$(basename "$1")" in
        pkgs-explicit.txt)  printf 'lists/pkgs-explicit.txt' ;;
        pkgs-aur.txt)        printf 'lists/pkgs-aur.txt' ;;
        pkgs-arch.txt)       printf 'lists/pkgs-arch.txt' ;;
        systemd-user.txt)    printf 'lists/systemd-user-enabled.txt' ;;
        systemd-system.txt)  printf 'lists/systemd-system-enabled.txt' ;;
        *) return 1 ;;
    esac
}

# publish_staging <staging_dir> <repo_root> [<tracked-table>] [<written-list>]
# Writes staged files into the repo's working tree and prints how many. Never
# commits, never pushes, never runs --delete: what disappeared from the machine
# stays in the repo until a human decides with `git rm` (docs/CONTEXT.md §4).
#
# When <written-list> is given, every file actually written is recorded there
# as a repo-relative path, NUL-separated. cmd_sync commits exactly that set and
# nothing else: `git add -A` in someone's dotfiles repo sweeps up whatever they
# left mid-review into a commit labelled "omabackup: sync". NUL-separated in a
# file rather than on stdout because command substitution discards NUL bytes,
# and a pathspec list is only as safe as its separator.
#
# Local plugins record the files rsync copied, never the directory: rsync runs
# without --delete, so committing the directory would also commit anything the
# user has under configs/omarchy/plugins/<id>/ that this tool never wrote.
# A write that fails is a file that is not backed up. Every failure is counted
# and the function returns non-zero, so cmd_sync can refuse to commit rather
# than reporting success over a partial publish -- the old version dropped the
# failure and fell through to its own success printf. `find -print0` throughout,
# because a newline in a filename would otherwise split one path into two.
publish_staging() {
    local staging="$1" repo="$2" table="${3:-}" list="${4:-}" f pf pid rel dst failed=0
    local -a written=()

    # A snapshot, not two independent `find` calls. The first version ran
    # find TWICE -- once to count destinations, once to write -- and a PoC
    # confirmed that is not the same thing as one: forcing the two walks to
    # see different sets (a file added between them) let a collision slip
    # past the count and overwrite silently anyway. Captured once, into
    # parallel arrays rather than a single delimited string, since a staged
    # file's name is free to hold the tab or newline a text encoding would
    # need as its own separator -- the same reasoning restore_rows' TSV rows
    # were fixed against.
    #
    # map_to_repo maps FLAT for a trackedRepoPath entry -- the repo keeps one
    # directory of names, not a mirror -- and nothing stopped two DIFFERENT
    # staged files from mapping to the SAME repo destination: two groups
    # whose trackedRepoPath both name the same repo directory, each holding
    # a file with the same basename. A PoC confirmed the result: both wrote,
    # the second silently overwrote the first, "2 files" published, one
    # gone, exit 0.
    #
    # destcount is also poisoned for ancestor/descendant destinations, the
    # same technique restore_rows uses for declared live paths: "shared" and
    # "shared/child" never collide as exact strings, but a PoC forcing the
    # more specific one to enumerate first turned the less specific one's
    # own file into a DIRECTORY component of the other's path -- shared/
    # child/child instead of two files -- rc=0, no warning.
    #
    # .generated and .plugins/manifest.txt and .plugins/patches/*.patch are
    # folded into this SAME map before anything is written, not skipped and
    # written separately after: a PoC showed a plain staged file mapping to
    # the identical repo path as a generated list (lists/pkgs-explicit.txt,
    # reachable through a manifest that also declares that path) silently
    # overwrote whichever one wrote last, uncaught, because the old code
    # never compared the two namespaces against each other at all.
    local -a rels=() dsts=()
    local -A destcount=()
    while IFS= read -r -d '' f; do
        rel="${f#"$staging"/}"
        [[ "$rel" == .generated/* || "$rel" == .plugins/* ]] && continue
        dst="$(map_to_repo "$rel" "$table")" || continue
        rels+=("$rel"); dsts+=("$dst")
    done < <(find "$staging" \( -type f -o -type l \) -print0 2>/dev/null)
    # find's own status, checked BEFORE anything below ever runs -- the
    # earlier version incremented `failed` here but fell through to the
    # write pass regardless. A PoC (a stub find that prints one file then
    # exits nonzero) confirmed the result: rc=1 reported at the very end,
    # but the file had already been written by then.
    wait "$!" || return 1

    if [[ -d "$staging/.generated" ]]; then
        for f in "$staging"/.generated/*; do
            [[ -f "$f" ]] || continue
            dst="$(_generated_repo_name "$f")" || continue
            rels+=(".generated/${f##*/}"); dsts+=("$dst")
        done
    fi
    if [[ -f "$staging/.plugins/manifest.txt" ]]; then
        rels+=(".plugins/manifest.txt"); dsts+=("lists/omarchy-plugins.txt")
    fi
    if [[ -d "$staging/.plugins/patches" ]]; then
        for f in "$staging"/.plugins/patches/*.patch; do
            [[ -f "$f" ]] || continue
            rels+=(".plugins/patches/${f##*/}"); dsts+=("patches/omarchy-plugins/${f##*/}")
        done
    fi

    local i n_pairs="${#rels[@]}" existing_dst
    local -a seen_dst=()
    for (( i = 0; i < n_pairs; i++ )); do
        dst="${dsts[$i]}"
        destcount[$dst]=$(( ${destcount[$dst]:-0} + 1 ))
        for existing_dst in "${seen_dst[@]}"; do
            [[ "$existing_dst" == "$dst" ]] && continue
            if [[ "$dst" == "$existing_dst"/* || "$existing_dst" == "$dst"/* ]]; then
                destcount[$dst]=$(( ${destcount[$dst]} + 1 ))
                destcount[$existing_dst]=$(( ${destcount[$existing_dst]:-1} + 1 ))
            fi
        done
        seen_dst+=("$dst")
    done

    for (( i = 0; i < n_pairs; i++ )); do
        rel="${rels[$i]}"; dst="${dsts[$i]}"
        f="$staging/$rel"
        if (( ${destcount[$dst]:-1} > 1 )); then
            printf 'omabackup: %s maps to %s, which more than one staged source maps to -- refusing to publish any of them, one would silently overwrite another\n' \
                "$rel" "$dst" >&2
            failed=$((failed + 1))
            continue
        fi
        if _publish_file "$f" "$repo/$dst" "$repo"; then written+=("$dst"); else failed=$((failed + 1)); fi
    done

    if [[ -d "$staging/.plugins" ]]; then
        if [[ -d "$staging/.plugins/local" ]]; then
            for f in "$staging"/.plugins/local/*/; do
                [[ -d "$f" ]] || continue
                pid="${f%/}"; pid="${pid##*/}"
                # Same containment _publish_file's own writes get -- a repo
                # whose configs/omarchy/plugins directory is itself a
                # symlink (or has one somewhere in its ancestry) would
                # otherwise have this rsync follow it same as mkdir -p does.
                _publish_contained "$repo/configs/omarchy/plugins/$pid" "$repo" \
                    || { failed=$((failed + 1)); continue; }
                mkdir -p "$repo/configs/omarchy/plugins/$pid" || { failed=$((failed + 1)); continue; }
                rsync -a --exclude '.git/' "$f" "$repo/configs/omarchy/plugins/$pid/" \
                    || { failed=$((failed + 1)); continue; }
                while IFS= read -r -d '' pf; do
                    [[ -n "$pf" ]] || continue
                    written+=("configs/omarchy/plugins/$pid/${pf#"$f"}")
                done < <(find "$f" \( -type f -o -type l \) -not -path "*/.git/*" -print0 2>/dev/null)
                wait "$!" || failed=$((failed + 1))
            done
        fi
    fi

    if [[ -n "$list" ]]; then
        : >"$list" || return 1
        (( ${#written[@]} )) && { printf '%s\0' "${written[@]}" >"$list" || return 1; }
    fi
    printf '%s' "${#written[@]}"
    (( failed == 0 ))
}
