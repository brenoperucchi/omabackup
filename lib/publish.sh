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
    while IFS=$'\t' read -r prefix dest; do
        [[ -n "$prefix" && -n "$dest" ]] || continue
        [[ "$rel" == "$prefix"/* ]] || continue
        printf '%s/%s' "$dest" "${rel##*/}"
        return 0
    done <<<"$table"

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
_publish_file() {
    local src="$1" dst="$2"
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

    # `-type f -o -type l`: a plain `-type f` excludes symlinks, and every staged
    # link was therefore dropped without a word. This machine stages
    # ~/.config/nvim/lua/plugins/theme.lua and .../current/background as links,
    # and the destination repo tracks four -- all frozen at whatever the previous
    # tool left behind.
    while IFS= read -r -d '' f; do
        rel="${f#"$staging"/}"
        [[ "$rel" == .generated/* || "$rel" == .plugins/* ]] && continue
        dst="$(map_to_repo "$rel" "$table")" || continue
        if _publish_file "$f" "$repo/$dst"; then written+=("$dst"); else failed=$((failed + 1)); fi
    done < <(find "$staging" \( -type f -o -type l \) -print0 2>/dev/null)
    # find's own status, checked -- the same fail-open scan_files and
    # restore_rows already closed, still open here: a walk that stopped
    # partway published fewer files than staging actually held, and this
    # function's own return status said nothing was wrong. A PoC (a stub
    # find that prints one file then exits nonzero) confirmed rc=0 with an
    # incomplete publish -- sync could proceed to commit over it.
    wait "$!" || failed=$((failed + 1))

    if [[ -d "$staging/.generated" ]]; then
        for f in "$staging"/.generated/*; do
            [[ -f "$f" ]] || continue
            dst="$(_generated_repo_name "$f")" || continue
            if _publish_file "$f" "$repo/$dst"; then written+=("$dst"); else failed=$((failed + 1)); fi
        done
    fi

    if [[ -d "$staging/.plugins" ]]; then
        if [[ -f "$staging/.plugins/manifest.txt" ]]; then
            if _publish_file "$staging/.plugins/manifest.txt" "$repo/lists/omarchy-plugins.txt"
            then written+=("lists/omarchy-plugins.txt"); else failed=$((failed + 1)); fi
        fi
        if [[ -d "$staging/.plugins/patches" ]]; then
            mkdir -p "$repo/patches/omarchy-plugins" || failed=$((failed + 1))
            for f in "$staging"/.plugins/patches/*.patch; do
                [[ -f "$f" ]] || continue
                if cp "$f" "$repo/patches/omarchy-plugins/${f##*/}"
                then written+=("patches/omarchy-plugins/${f##*/}"); else failed=$((failed + 1)); fi
            done
        fi
        if [[ -d "$staging/.plugins/local" ]]; then
            for f in "$staging"/.plugins/local/*/; do
                [[ -d "$f" ]] || continue
                pid="${f%/}"; pid="${pid##*/}"
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
