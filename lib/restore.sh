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
# "<verdict>\t<explanation>". Three outcomes, per DESIGN.md §12.2/§12.3:
#
#   same       this machine is where the backup came from; the coupled groups
#              apply, and so do the migration markers -- migration state is
#              identical, so restoring it restores the truth.
#   forward    inside the declared range but further along; the coupled groups
#              apply, the markers do NOT -- omarchy-migrate exists to walk that
#              distance and restoring an older watermark would tell it there is
#              nothing to walk.
#   quarantine outside the range. The coupled groups are not applied at all.
#              This is the case the whole design was reorganised around: a
#              `.conf` compositor config restored onto an Omarchy that reads
#              `.lua` is refused with a reason instead of applied and found
#              broken hours later.
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
        # A machine BEHIND the backup is not a forward restore. Applying coupled
        # config written by a newer Omarchy onto an older one is the August
        # failure with the arrow reversed, and nothing here can migrate
        # backwards.
        printf 'quarantine\tthis machine is behind the backup (%s against %s): the coupled groups are not applied' \
            "$(date -d "@$tm" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$tm")" \
            "$(date -d "@$bm" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$bm")"
    fi
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

# restore_rows <extracted-dir> <verdict> [<group-filter>]
# One row per decision: "<action>\t<group>\t<repo-relative>\t<destination>".
#
# Actions:
#   restore    a file that will be written
#   quarantine a file from a coupled group on an out-of-range machine: extracted
#              somewhere safe, never placed
#   report     a generated list -- packages, systemd units. Restoring those
#              means installing software, which is not a file copy and is not
#              something this tool will do behind someone's back. The file is
#              named so a human can act on it.
#   ambiguous  the repo flattens several declared directories into one, so the
#              file cannot be traced back to where it came from
restore_rows() {
    local x="$1" verdict="$2" filter="${3:-}" id p prefix kind e f rel sub dest action
    local wt="$x/worktree"
    [[ -d "$wt" ]] || return 1

    while read -r id; do
        [[ -n "$id" ]] || continue
        if [[ -n "$filter" && ",$filter," != *",$id,"* ]]; then continue; fi

        case "$(group_field "$id" mode)" in
            gen)
                # Named through the same table publish used, because the repo
                # renames these on the way in (systemd-user.txt becomes
                # lists/systemd-user-enabled.txt) and a restore that looked for
                # the staging name would find nothing and say nothing.
                for f in $(_generated_files "$(group_field "$id" generator)"); do
                    rel="$(_generated_repo_name "$f")" || continue
                    [[ -e "$wt/$rel" ]] && printf 'report\t%s\t%s\t-\n' "$id" "$rel"
                done
                continue ;;
        esac

        action=restore
        if [[ "$(group_field "$id" coupled)" == true && "$verdict" == quarantine ]]; then
            action=quarantine
        fi

        # How many declared paths land in the SAME repo directory -- not how
        # many the group has. The first version counted the group's paths, and
        # called `scripts` ambiguous for declaring ~/.local/bin and ~/bin, which
        # have distinct destinations and are not ambiguous at all. Only a shared
        # destination loses the information.
        local -A prefixcount=()
        while read -r p; do
            [[ -n "$p" ]] || continue
            IFS=$'\t' read -r prefix kind <<<"$(_restore_repo_prefix "$id" "$p")" || continue
            [[ -n "$prefix" ]] || continue
            prefixcount[$prefix]=$(( ${prefixcount[$prefix]:-0} + 1 ))
        done < <(group_paths "$id")

        while read -r p; do
            [[ -n "$p" ]] || continue
            IFS=$'\t' read -r prefix kind <<<"$(_restore_repo_prefix "$id" "$p")" || continue
            [[ -n "$prefix" ]] || continue
            e="$(_expand "$p")"
            [[ -e "$wt/$prefix" ]] || continue

            if [[ "$kind" == flat ]]; then
                while IFS= read -r -d '' f; do
                    sub="${f##*/}"
                    if (( ${prefixcount[$prefix]:-1} > 1 )); then
                        printf 'ambiguous\t%s\t%s/%s\t%s/%s\n' "$id" "$prefix" "$sub" "$e" "$sub"
                    else
                        printf '%s\t%s\t%s/%s\t%s/%s\n' "$action" "$id" "$prefix" "$sub" "$e" "$sub"
                    fi
                done < <(find "$wt/$prefix" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
            elif [[ -d "$wt/$prefix" ]]; then
                while IFS= read -r -d '' f; do
                    rel="${f#"$wt/$prefix"/}"
                    printf '%s\t%s\t%s/%s\t%s/%s\n' "$action" "$id" "$prefix" "$rel" "$e" "$rel"
                done < <(find "$wt/$prefix" \( -type f -o -type l \) -print0 2>/dev/null)
            else
                printf '%s\t%s\t%s\t%s\n' "$action" "$id" "$prefix" "$e"
            fi
        done < <(group_paths "$id")
    done < <(groups_ids)
}

# _restore_one <extracted> <repo-relative> <destination> <backup-dir>
# Writes one file, having first put whatever was there somewhere safe. A backup
# that cannot be taken cancels the write: replacing a file we could not save a
# copy of is the one thing this must not do quietly.
_restore_one() {
    local x="$1" rel="$2" dest="$3" backup="$4" src="$x/worktree/$rel"
    [[ -e "$src" || -L "$src" ]] || return 1
    if [[ -e "$dest" || -L "$dest" ]]; then
        local keep="$backup/${dest#"$HOME"/}"
        mkdir -p "$(dirname "$keep")" 2>/dev/null || return 1
        cp -Pp "$dest" "$keep" 2>/dev/null || return 1
    fi
    mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
    # -P: a symlink is restored as a symlink. Following it would write through
    # to whatever it points at, which is somebody else's file.
    rm -f "$dest" 2>/dev/null
    cp -Pp "$src" "$dest" 2>/dev/null || return 1
}
