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
    # git diff's own status, checked -- a bare `rm -f "$tmp_index"` right
    # after it, with nothing capturing diff's exit code first, made this
    # function's own return status whatever `rm -f` reported (almost always
    # 0) regardless of whether the diff itself succeeded.
    GIT_INDEX_FILE="$tmp_index" git -C "$plugin" diff HEAD
    local diff_rc=$?
    rm -f "$tmp_index"
    return "$diff_rc"
}

# capture_plugin <plugin_dir> <patch_dir> <local_dir> <manifest_file>
# Writes the classification to stdout: "git" | "git+patch" | "local"
capture_plugin() {
    local plugin="${1%/}" patch_dir="$2" local_dir="$3" manifest="$4"
    local id; id="$(basename "$plugin")"

    # _capture_local's own status, checked at both call sites below -- a
    # compound `{ _capture_local ...; echo "local"; return; }` discarded it
    # either way, since a bare `return` reports the LAST command's status,
    # and that was always the `echo`. A PoC (rsync stubbed to always fail)
    # confirmed the result: a plugin whose rsync copy failed was still
    # classified "local" and this function still returned 0 -- collect
    # reported success for a plugin directory that was never actually
    # copied into staging.
    [[ -d "$plugin/.git" ]] || { _capture_local "$plugin" "$local_dir" "$id" || return 1; echo "local"; return; }

    local url sha
    url="$(git -C "$plugin" remote get-url origin 2>/dev/null || true)"
    sha="$(git -C "$plugin" rev-parse HEAD 2>/dev/null || true)"

    # With no remote (or no commit) there is nothing to reinstall from, and a
    # patch has no base to apply against. Such a plugin used to be classified
    # "git" and stored nowhere at all -- it disappeared completely.
    if [[ -z "$url" || -z "$sha" ]]; then
        _capture_local "$plugin" "$local_dir" "$id" || return 1
        echo "local"
        return
    fi

    # The commit matters as much as the URL: without it a restore installs
    # whatever upstream HEAD is today, which may have moved -- and then the
    # patch no longer applies.
    #
    # This write's own status, checked -- a manifest this cannot append to
    # (the destination pointing at a directory, a disk-full moment) used
    # to be silent: collect proceeded, classified the plugin "git", and
    # the one line that lets a restore reinstall it never landed anywhere.
    printf '%s %s %s\n' "$id" "$url" "$sha" >>"$manifest" || return 1

    # git status's own status, checked -- a query that failed produced the
    # same empty output a genuinely clean plugin does, and a dirty plugin
    # was classified "git" with no patch at all: the local customization
    # this whole function exists to capture never entered the backup, and
    # collect still reported success.
    local porcelain; porcelain="$(git -C "$plugin" status --porcelain 2>/dev/null)" || return 1
    if [[ -z "$porcelain" ]]; then
        rm -f "$patch_dir/$id.patch"
        echo "git"
        return
    fi

    # _capture_patch's own status, checked -- git diff HEAD failing used
    # to write an empty patch file and still classify the plugin
    # "git+patch", indistinguishable from a genuinely trivial diff.
    _capture_patch "$plugin" >"$patch_dir/$id.patch" || return 1
    echo "git+patch"
}
