#!/bin/bash
# Capturing one omarchy-shell plugin into the backup.
#
# Three cases, each with the strategy that survives a bootstrap:
#   1. clean git  -> URL + commit (reinstall with `omarchy plugin add`, reset to sha)
#   2. dirty git  -> URL + commit + a patch of the local state
#   3. no remote  -> full copy; there is no upstream to pull it back from
#
# Sourceable with no side effects on import, so it can be tested.
# Regressions live in test/plugin-capture.test.sh; rationale in docs/DESIGN.md §11.3.

# Full copy, without dragging along a third party's git history.
_capture_local() {
    local plugin="$1" local_dir="$2" id="$3"
    mkdir -p "$local_dir/$id"
    rsync -a --exclude '.git/' "$plugin/" "$local_dir/$id/"
}

# A patch of the local state against HEAD, including staged and untracked files.
#
# Plain `git diff` only sees what is modified AND unstaged: a `git add` inside a
# plugin directory produced an empty patch while `status --porcelain` still
# reported the plugin dirty, and the customization vanished on restore.
# `git diff HEAD` covers staged changes; untracked files must be in the index to
# show up at all, and the user's index must not be touched -- hence the throwaway
# copy via GIT_INDEX_FILE.
_capture_patch() {
    local plugin="$1"
    # Checked, not assumed: an empty tmp_index below would hand
    # GIT_INDEX_FILE="" to git, which falls through to the plugin's own real
    # index instead of erroring -- the add -N a few lines down would then mark
    # intent-to-add against the live index this function exists to leave
    # untouched, rather than the throwaway copy the comment above promises.
    local tmp_index; tmp_index="$(mktemp)" || return 1
    local real_index; real_index="$(git -C "$plugin" rev-parse --git-path index 2>/dev/null || true)"

    [[ -n "$real_index" && -f "$plugin/$real_index" ]] && cp "$plugin/$real_index" "$tmp_index"
    [[ -n "$real_index" && -f "$real_index" ]] && cp "$real_index" "$tmp_index"

    GIT_INDEX_FILE="$tmp_index" git -C "$plugin" add -N -- . 2>/dev/null || true
    GIT_INDEX_FILE="$tmp_index" git -C "$plugin" diff HEAD
    rm -f "$tmp_index"
}

# capture_plugin <plugin_dir> <patch_dir> <local_dir> <manifest_file>
# Writes the classification to stdout: "git" | "git+patch" | "local"
capture_plugin() {
    local plugin="${1%/}" patch_dir="$2" local_dir="$3" manifest="$4"
    local id; id="$(basename "$plugin")"

    [[ -d "$plugin/.git" ]] || { _capture_local "$plugin" "$local_dir" "$id"; echo "local"; return; }

    local url sha
    url="$(git -C "$plugin" remote get-url origin 2>/dev/null || true)"
    sha="$(git -C "$plugin" rev-parse HEAD 2>/dev/null || true)"

    # With no remote (or no commit) there is nothing to reinstall from, and a
    # patch has no base to apply against. Such a plugin used to be classified
    # "git" and stored nowhere at all -- it disappeared completely.
    if [[ -z "$url" || -z "$sha" ]]; then
        _capture_local "$plugin" "$local_dir" "$id"
        echo "local"
        return
    fi

    # The commit matters as much as the URL: without it a restore installs
    # whatever upstream HEAD is today, which may have moved -- and then the
    # patch no longer applies.
    printf '%s %s %s\n' "$id" "$url" "$sha" >>"$manifest"

    if [[ -z "$(git -C "$plugin" status --porcelain 2>/dev/null)" ]]; then
        rm -f "$patch_dir/$id.patch"
        echo "git"
        return
    fi

    _capture_patch "$plugin" >"$patch_dir/$id.patch"
    echo "git+patch"
}
