#!/usr/bin/env bash
# restore -- putting it back, which is the only reason any of the rest exists.
#
# Two rules shape everything here.
#
# The first: the backup is described by the manifest that MADE it, not by
# whatever manifest this machine happens to carry. A restore driven by the
# local manifest would look for groups the artefact never had and would place
# files by rules that changed after it was written. The artefact ships
# `tool/groups.default.json` for exactly this, and it is what gets read.
#
# The second: nothing is written unless asked. `restore` plans; `restore
# --apply` writes. An overwritten dotfile is as irreversible as a leaked key,
# and this project already decided how it treats irreversible things.

# _restore_in_range <version> <targets-json>
# Whether a version string matches one of the manifest's declared targets.
# The targets are globs ("4.*"), which is what the manifest has always held.
_restore_in_range() {
    local v="$1" targets="$2" t
    [[ -n "$v" && "$v" != unknown ]] || return 1
    while read -r t; do
        [[ -n "$t" ]] || continue
        # shellcheck disable=SC2053 -- the glob is the point
        [[ "$v" == $t ]] && return 0
    done < <(printf '%s' "$targets" | jq -r '.[]?' 2>/dev/null)
    return 1
}

# _restore_verdict <manifest.json>
# "<verdict>\t<explanation>". Four outcomes -- three of them DESIGN.md
# §12.2/§12.3, and a fourth this file adds because the design leaves it
# undefined and undefined is not the same as "refuse":
#
#   same       identical migration watermark; coupled groups and markers apply.
#   behind     inside the range, but this machine's watermark is LOWER than the
#              backup's -- typically a fresh install that has not migrated at
#              all yet (watermark 0, because the migrations directory does not
#              exist until the first one runs). §12.3 has no row for this. The
#              first version of this file quarantined it, reasoning by analogy
#              to a downgrade -- and that quarantined the PRIMARY recovery
#              scenario (new machine, valid backup, same Omarchy version), with
#              the markers that would fix the watermark held inside the very
#              block that was quarantined: it could not recover from itself.
#              Restoring the coupled config also restores the exact schema
#              level that config is written for, so the honest answer is the
#              same as `same` -- apply the coupled groups and their markers,
#              which keeps the two mutually consistent.
#   forward    inside the range, further along; coupled groups apply, the
#              migration markers do NOT -- omarchy-migrate exists to walk that
#              distance, and restoring an older watermark would tell it there
#              is nothing left to walk.
#   quarantine outside the declared range. Nothing from the coupled block is
#              applied. This is the case the whole design was reorganised
#              around: a `.conf` compositor config restored onto an Omarchy
#              that reads `.lua` is refused with a reason instead of applied
#              and found broken hours later.
_restore_verdict() {
    local m="$1" bv bm targets tv tc tm
    bv="$(jq -r '.omarchy.version // "unknown"' "$m" 2>/dev/null)"
    bm="$(jq -r '.omarchy.migrationWatermark // "0"' "$m" 2>/dev/null)"
    targets="$(jq -c '.supportedTargets // []' "$m" 2>/dev/null)"
    IFS=$'\t' read -r tv tc tm <<<"$(omarchy_identity)"

    if ! _restore_in_range "$tv" "$targets"; then
        printf 'quarantine\tthis machine runs Omarchy %s, and the backup declares it can restore onto %s' \
            "$tv" "$(printf '%s' "$targets" | jq -r 'join(", ")' 2>/dev/null)"
        return 0
    fi
    [[ "$bm" =~ ^[0-9]+$ ]] || bm=0
    [[ "$tm" =~ ^[0-9]+$ ]] || tm=0
    if (( tm == bm )); then
        printf 'same\tsame migration watermark (%s): the coupled groups and the migration markers both apply' "$bm"
    elif (( tm > bm )); then
        # Watermarks are unix timestamps, so their difference is a span of time
        # and not a count of migrations. Said as a date, which is what it is.
        printf 'forward\tthis machine has migrated past the backup (%s against %s): the coupled groups apply, the markers do not' \
            "$(date -d "@$tm" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$tm")" \
            "$(date -d "@$bm" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$bm")"
    else
        printf 'behind\tthis machine has fewer migrations than the backup (%s against %s): the coupled groups and the migration markers both apply, to match the schema the config is written for' \
            "$(date -d "@$tm" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$tm")" \
            "$(date -d "@$bm" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$bm")"
    fi
}

# _restore_contained <destination-path>
# Whether a destination, once every symlink and `..` in it is resolved, is
# still inside $HOME. realpath -m resolves the parts of the path that exist
# (following any symlink along the way) and normalizes the parts that do not
# lexically, in one pass -- which is exactly the two ways a destination
# escaped: a declared path holding `..` normalizes past $HOME, and a directory
# under $HOME that is itself a symlink to somewhere else resolves through it.
# --into does not change what this checks: HOME is reassigned to the target
# before this ever runs, so containment is always relative to wherever the
# restore is actually landing.
_restore_contained() {
    local dest="$1" rp home_rp
    rp="$(realpath -m -- "$dest" 2>/dev/null)" || return 1
    home_rp="$(realpath -e -- "$HOME" 2>/dev/null)" || return 1
    [[ -n "$rp" && -n "$home_rp" ]] || return 1
    [[ "$rp" == "$home_rp" || "$rp" == "$home_rp"/* ]]
}

# _restore_repo_prefix <group-id> <declared-path>
# "<repo-relative-prefix>\t<kind>", where kind is `tree` (the repo mirrors the
# directory) or `flat` (the repo keeps one directory of names).
#
# The inverse of lib/publish.sh's map_to_repo, and only a partial one: the flat
# form drops which declared directory a file came from. Where a group has one
# such directory the answer is unambiguous; where it has several, restore says
# so rather than guessing -- see restore_rows.
_restore_repo_prefix() {
    local id="$1" p="$2" sub e rel
    sub="$(group_tracked_repo_path "$id" "$p")"
    if [[ -n "$sub" ]]; then printf '%s\tflat' "$sub"; return 0; fi
    e="$(_expand "$p")"; rel="${e#"$HOME"/}"
    # The exact forms matter here in a way they never did in map_to_repo, which
    # only ever sees a file inside one of these. A group declares the DIRECTORY
    # -- "~/.local/state/omarchy" -- and without a case for it the path fell
    # through to the top-level-dotfile rule and the whole `state` group was
    # looked for under dotfiles/, where it has never been.
    case "$rel" in
        .config/omarchy/plugins)   printf 'configs/omarchy/plugins\ttree' ;;
        .config/omarchy/plugins/*) printf 'configs/omarchy/plugins/%s\ttree' "${rel#.config/omarchy/plugins/}" ;;
        .config)                   printf 'configs\ttree' ;;
        .config/*)                 printf 'configs/%s\ttree' "${rel#.config/}" ;;
        .local/state/omarchy)      printf 'state/omarchy\ttree' ;;
        .local/state/omarchy/*)    printf 'state/omarchy/%s\ttree' "${rel#.local/state/omarchy/}" ;;
        .local/bin|.local/bin/*|bin|bin/*) return 1 ;;
        .*)                        printf 'dotfiles/%s\ttree' "$rel" ;;
        *)                         return 1 ;;
    esac
}

# restore_rows <extracted-dir> <verdict>
# One row per decision: "<action>\t<group>\t<repo-relative>\t<destination>".
#
# Actions:
#   restore    a file that will be written
#   quarantine a file from a coupled group on an out-of-range machine: extracted
#              somewhere safe, never placed
#   held       a migration marker on a `forward` restore: DESIGN.md §12.3 says
#              the coupled groups apply but the markers do not, so this file
#              is set aside like a quarantined one, for the same reason it is
#              not `restore` -- but it is not a symptom of anything being
#              wrong, so it is not counted or labelled the way quarantine is.
#   report     a generated list, or something restoring means installing
#              rather than copying -- packages, systemd units, the enabled-
#              plugins list, a patch against an upstream plugin. The file is
#              named so a human can act on it.
#   ambiguous  the repo flattens several declared directories into one, so the
#              file cannot be traced back to where it came from
#   escape     the computed destination is not inside $HOME (or --into's
#              target) once symlinks and `..` are resolved. Never applied,
#              regardless of verdict or group.
#
# Filtering by group is done through $ONLY -> groups_ids, the same channel
# every other command already uses -- restore used to parse its own --groups,
# but the global flag parser consumes that flag before cmd_restore's argument
# loop ever sees it, so that parsing was dead code and the flag silently did
# nothing.
restore_rows() {
    local x="$1" verdict="$2" id p prefix kind e f rel sub dest action gm coupled
    local wt="$x/worktree"
    [[ -d "$wt" ]] || return 1

    local migdir; migdir="$(_expand '~/.local/state/omarchy/migrations')"

    # The collision map is built once, over every group, before any row is
    # emitted. The first version built it per group and reset it between them,
    # so it never saw two DIFFERENT groups sharing one destination -- `scripts`
    # declaring ~/.local/bin and ~/bin is fine (distinct destinations), but
    # nothing stopped two groups from both naming trackedRepoPath
    # "scripts/shared", which this now catches the same way.
    local -A prefixcount=()
    while read -r id; do
        [[ -n "$id" ]] || continue
        gm="$(group_field "$id" mode)" || return 1
        [[ "$gm" == gen ]] && continue
        while read -r p; do
            [[ -n "$p" ]] || continue
            IFS=$'\t' read -r prefix kind <<<"$(_restore_repo_prefix "$id" "$p")" || continue
            [[ -n "$prefix" ]] || continue
            prefixcount[$prefix]=$(( ${prefixcount[$prefix]:-0} + 1 ))
        done < <(group_paths "$id")
    done < <(groups_ids)

    while read -r id; do
        [[ -n "$id" ]] || continue

        # jq's own status, checked. `group_field` degrades to an empty string on
        # a query that finds nothing, which is correct -- but on a manifest jq
        # cannot read at all, that same empty string used to mean "not coupled"
        # and "not gen", so a quarantine verdict silently restored a coupled
        # group instead of holding it. A manifest this cannot query is one this
        # cannot plan against.
        gm="$(group_field "$id" mode)" || return 1
        if [[ "$gm" == gen ]]; then
            # Named through the same table publish used, because the repo
            # renames these on the way in (systemd-user.txt becomes
            # lists/systemd-user-enabled.txt) and a restore that looked for the
            # staging name would find nothing and say nothing.
            for f in $(_generated_files "$(group_field "$id" generator)"); do
                rel="$(_generated_repo_name "$f")" || continue
                [[ -e "$wt/$rel" ]] && printf 'report\t%s\t%s\t-\n' "$id" "$rel"
            done
            continue
        fi

        coupled="$(group_field "$id" coupled)" || return 1
        action=restore
        [[ "$coupled" == true && "$verdict" == quarantine ]] && action=quarantine

        while read -r p; do
            [[ -n "$p" ]] || continue
            IFS=$'\t' read -r prefix kind <<<"$(_restore_repo_prefix "$id" "$p")" || continue
            [[ -n "$prefix" ]] || continue
            e="$(_expand "$p")"
            [[ -e "$wt/$prefix" ]] || continue

            if [[ "$kind" == flat ]]; then
                while IFS= read -r -d '' f; do
                    sub="${f##*/}"
                    dest="$e/$sub"
                    if ! _restore_contained "$dest"; then
                        printf 'escape\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$sub" "$dest"
                    elif (( ${prefixcount[$prefix]:-1} > 1 )); then
                        printf 'ambiguous\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$sub" "$dest"
                    else
                        printf '%s\t%s\t%s/%s\t%s\n' "$action" "$id" "$prefix" "$sub" "$dest"
                    fi
                done < <(find "$wt/$prefix" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
            elif [[ -d "$wt/$prefix" ]]; then
                while IFS= read -r -d '' f; do
                    rel="${f#"$wt/$prefix"/}"
                    dest="$e/$rel"
                    if ! _restore_contained "$dest"; then
                        printf 'escape\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$rel" "$dest"
                    elif [[ "$verdict" == forward && ( "$dest" == "$migdir" || "$dest" == "$migdir"/* ) ]]; then
                        printf 'held\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$rel" "$dest"
                    else
                        printf '%s\t%s\t%s/%s\t%s\n' "$action" "$id" "$prefix" "$rel" "$dest"
                    fi
                done < <(find "$wt/$prefix" \( -type f -o -type l \) -print0 2>/dev/null)
            else
                dest="$e"
                if ! _restore_contained "$dest"; then
                    printf 'escape\t%s\t%s\t%s\n' "$id" "$prefix" "$dest"
                else
                    printf '%s\t%s\t%s\t%s\n' "$action" "$id" "$prefix" "$dest"
                fi
            fi
        done < <(group_paths "$id")

        # The plugins group is `triple`: local plugin directories are restored
        # by the path loop above like any tree, but publish also writes an
        # enabled-plugins list and per-plugin patches that no declared path
        # points at, and nothing here ever looked for them. They are reported,
        # not applied -- a patch is something to run `git apply` on knowingly,
        # not something to overwrite a live plugin tree with.
        if [[ "$gm" == triple ]]; then
            [[ -f "$wt/lists/omarchy-plugins.txt" ]] \
                && printf 'report\t%s\tlists/omarchy-plugins.txt\t-\n' "$id"
            while IFS= read -r -d '' f; do
                rel="${f#"$wt"/}"
                printf 'report\t%s\t%s\t-\n' "$id" "$rel"
            done < <(find "$wt/patches/omarchy-plugins" -maxdepth 1 -type f -name '*.patch' -print0 2>/dev/null)
        fi
    done < <(groups_ids)
}

# _restore_one <extracted> <repo-relative> <destination> <backup-dir>
# Writes one file, having first put whatever was there somewhere safe. A backup
# that cannot be taken cancels the write: replacing a file we could not save a
# copy of is the one thing this must not do quietly.
_restore_one() {
    local x="$1" rel="$2" dest="$3" backup="$4"
    local src="$x/worktree/$rel"
    [[ -e "$src" || -L "$src" ]] || return 1
    # Checked here too, not only when the row was planned. restore_rows decides
    # whether a row is ever offered to this function, but a function that
    # writes to a path handed to it must not trust that its only caller got the
    # decision right -- that is how the earlier version of this function's own
    # bug went unnoticed: `local x=$1 ... src="$x/..."` expanded $x from the
    # CALLER's scope, not the local just declared on the same line (bash
    # expands every word of a `local` statement before any of it is bound), and
    # it worked only because cmd_restore happened to use a variable also named
    # x holding the same value. True by accident is the shape of half the
    # defects in this project.
    _restore_contained "$dest" || return 1
    if [[ -e "$dest" || -L "$dest" ]]; then
        local keep="$backup/${dest#"$HOME"/}"
        mkdir -p "$(dirname "$keep")" 2>/dev/null || return 1
        cp -Pp "$dest" "$keep" 2>/dev/null || return 1
    fi
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    # -P: a symlink is restored as a symlink. Following it would write through
    # to whatever it points at, which is somebody else's file.
    #
    # rm's status used to be discarded. A dest that rm could not remove --
    # locked, or a directory needing more than -f -- left its symlink or file
    # in place, and the cp that followed wrote THROUGH it: the backup taken a
    # moment ago was of the original, but the destination now held whatever the
    # stale symlink pointed at, and the original was gone from both places at
    # once.
    rm -f "$dest" 2>/dev/null
    if [[ -e "$dest" || -L "$dest" ]]; then return 1; fi
    cp -Pp "$src" "$dest" 2>/dev/null || return 1
}
