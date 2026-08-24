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

# map_to_repo <path-relative-to-HOME>
# Prints the path relative to the repo root, or fails (empty stdout, exit 1)
# for anything that needs special handling by its caller (plugins, generated
# lists, tracked-only scripts).
map_to_repo() {
    local rel="$1"
    case "$rel" in
        .config/omarchy/plugins/*) return 1 ;;  # triple strategy, not a plain copy
        .config/*)                  printf 'configs/%s' "${rel#.config/}" ;;
        .local/share/applications/*)
            printf 'dotfiles/.local-share-applications/%s' "$(basename "$rel")" ;;
        .local/state/omarchy/*)     printf 'state/omarchy/%s' "${rel#.local/state/omarchy/}" ;;
        .local/bin/*|bin/*|scripts/*) return 1 ;;  # tracked-only, written directly by collect
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

# publish_staging <staging_dir> <repo_root>
# Writes staged files into the repo's working tree. Never commits, never
# pushes, never runs --delete: what disappeared from the machine stays in the
# repo until a human decides with `git rm` (docs/CONTEXT.md §4).
publish_staging() {
    local staging="$1" repo="$2" f rel dst n=0

    while IFS= read -r f; do
        rel="${f#"$staging"/}"
        [[ "$rel" == .generated/* || "$rel" == .plugins/* ]] && continue
        dst="$(map_to_repo "$rel")" || continue
        _publish_file "$f" "$repo/$dst"
        n=$((n + 1))
    done < <(find "$staging" -type f 2>/dev/null)

    if [[ -d "$staging/.generated" ]]; then
        for f in "$staging"/.generated/*; do
            [[ -f "$f" ]] || continue
            dst="$(_generated_repo_name "$f")" || continue
            _publish_file "$f" "$repo/$dst"
            n=$((n + 1))
        done
    fi

    if [[ -d "$staging/.plugins" ]]; then
        [[ -f "$staging/.plugins/manifest.txt" ]] && \
            _publish_file "$staging/.plugins/manifest.txt" "$repo/lists/omarchy-plugins.txt" && n=$((n + 1))
        if [[ -d "$staging/.plugins/patches" ]]; then
            mkdir -p "$repo/patches/omarchy-plugins"
            for f in "$staging"/.plugins/patches/*.patch; do
                [[ -f "$f" ]] || continue
                cp "$f" "$repo/patches/omarchy-plugins/$(basename "$f")"
                n=$((n + 1))
            done
        fi
        if [[ -d "$staging/.plugins/local" ]]; then
            for f in "$staging"/.plugins/local/*/; do
                [[ -d "$f" ]] || continue
                mkdir -p "$repo/configs/omarchy/plugins/$(basename "$f")"
                rsync -a --exclude '.git/' "$f" "$repo/configs/omarchy/plugins/$(basename "$f")/"
                n=$((n + 1))
            done
        fi
    fi

    printf '%s' "$n"
}
