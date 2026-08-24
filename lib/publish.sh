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
    mkdir -p "$(dirname "$dst")"
    if [[ "$dst" == *.json ]] && jq -e . "$src" >/dev/null 2>&1; then
        jq -S . "$src" >"$dst.tmp" && mv "$dst.tmp" "$dst"
    else
        rsync -a "$src" "$dst"
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
publish_staging() {
    local staging="$1" repo="$2" table="${3:-}" list="${4:-}" f pf pid rel dst
    local -a written=()

    while IFS= read -r f; do
        rel="${f#"$staging"/}"
        [[ "$rel" == .generated/* || "$rel" == .plugins/* ]] && continue
        dst="$(map_to_repo "$rel" "$table")" || continue
        _publish_file "$f" "$repo/$dst" && written+=("$dst")
    done < <(find "$staging" -type f 2>/dev/null)

    if [[ -d "$staging/.generated" ]]; then
        for f in "$staging"/.generated/*; do
            [[ -f "$f" ]] || continue
            dst="$(_generated_repo_name "$f")" || continue
            _publish_file "$f" "$repo/$dst" && written+=("$dst")
        done
    fi

    if [[ -d "$staging/.plugins" ]]; then
        [[ -f "$staging/.plugins/manifest.txt" ]] && \
            _publish_file "$staging/.plugins/manifest.txt" "$repo/lists/omarchy-plugins.txt" && \
            written+=("lists/omarchy-plugins.txt")
        if [[ -d "$staging/.plugins/patches" ]]; then
            mkdir -p "$repo/patches/omarchy-plugins"
            for f in "$staging"/.plugins/patches/*.patch; do
                [[ -f "$f" ]] || continue
                cp "$f" "$repo/patches/omarchy-plugins/${f##*/}" \
                    && written+=("patches/omarchy-plugins/${f##*/}")
            done
        fi
        if [[ -d "$staging/.plugins/local" ]]; then
            for f in "$staging"/.plugins/local/*/; do
                [[ -d "$f" ]] || continue
                pid="${f%/}"; pid="${pid##*/}"
                mkdir -p "$repo/configs/omarchy/plugins/$pid"
                rsync -a --exclude '.git/' "$f" "$repo/configs/omarchy/plugins/$pid/" || continue
                while IFS= read -r pf; do
                    [[ -n "$pf" ]] || continue
                    written+=("configs/omarchy/plugins/$pid/${pf#"$f"}")
                done < <(find "$f" -type f -not -path '*/.git/*' 2>/dev/null)
            done
        fi
    fi

    if [[ -n "$list" ]]; then
        : >"$list"
        (( ${#written[@]} )) && printf '%s\0' "${written[@]}" >"$list"
    fi
    printf '%s' "${#written[@]}"
}
