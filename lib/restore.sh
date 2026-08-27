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
    # "unreadable" (from omarchy_identity) means the migrations directory
    # exists but could not be scanned -- a real machine problem, not "no
    # migrations yet." Checked on tm AND bm: bm carries the same sentinel
    # when the backup was built by a machine that hit it, and checking only
    # the live side left that half open -- a bundle built while unreadable
    # shipped with migrationWatermark: "unreadable" baked into its manifest,
    # and this same regex-fallback defaulted it exactly like an old bundle
    # predating the field, applying coupled config against a backup whose
    # migration state was never actually known to anyone. build_bundle
    # refuses on this now too (lib/bundle.sh), so a NEW bundle cannot carry
    # it -- this guards artifacts already built before that existed.
    # Two distinct returns, matching the pattern this file already uses in
    # _restore_repo_prefix for the same reason: 1 for "this machine's own
    # state," 2 for "the artifact's" -- the caller could not tell them apart
    # otherwise, and told the user to go investigate their own perfectly
    # healthy machine when an old artifact was what actually needed rebuilding.
    [[ "$tm" == unreadable ]] && return 1
    [[ "$bm" == unreadable ]] && return 2
    # A watermark that is neither a valid non-negative integer nor the
    # "unreadable" sentinel is not a legitimate "no migrations yet" -- that
    # case already produces "0" explicitly, which the regex below matches
    # fine. It is a migrations directory holding a file whose name, once
    # `.sh` is stripped, is not a number (a stray `junk.sh` is enough) on the
    # tm side, or a manifest field some other value got written into on the
    # bm side. Defaulting either to 0 read a genuinely unreadable watermark as
    # the most permissive possible one -- a fresh install, applying coupled
    # config unconditionally -- exactly backwards from the migrations
    # directory existing but not being trustworthy. Refused the same way the
    # sentinel already is, not silently downgraded to it.
    [[ "$tm" =~ ^[0-9]+$ ]] || return 1
    [[ "$bm" =~ ^[0-9]+$ ]] || return 2
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

# _path_contained <path> <base>
# Whether a path, once every symlink and `..` in it is resolved, is still
# inside <base>. realpath -m resolves the parts that exist (following any
# symlink along the way) and normalizes the parts that do not, lexically, in
# one pass -- which is exactly the two ways a path escapes: something holding
# `..` normalizes past its base, and a directory under the base that is itself
# a symlink elsewhere resolves through it. General over $HOME specifically,
# because it turned out $HOME was not the only base a path built from artifact
# content needed checking against -- see _restore_contained below, and the
# quarantine write in cmd_restore, which builds a path from a group id the
# manifest names and never validated that name at all.
_path_contained() {
    local p="$1" base="$2" rp base_rp
    rp="$(realpath -m -- "$p" 2>/dev/null)" || return 1
    base_rp="$(realpath -e -- "$base" 2>/dev/null)" || return 1
    [[ -n "$rp" && -n "$base_rp" ]] || return 1
    [[ "$rp" == "$base_rp" || "$rp" == "$base_rp"/* ]]
}

# _restore_contained <destination-path>
# Whether a destination is still inside $HOME once resolved -- see
# _path_contained. --into does not change what this checks: HOME is
# reassigned to the target before this ever runs, so containment is always
# relative to wherever the restore is actually landing.
_restore_contained() { _path_contained "$1" "$HOME"; }

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
    # trackedRepoPath is looked up by exact match against the manifest's own
    # .live string -- if a manifest declares that WITH a trailing slash, the
    # lookup needs the same unstripped form group_paths handed back. The
    # trailing slash is only stripped below, for the tree computation, where
    # it survives into `rel` and the later ${f#"$wt/$prefix"/} strip then looks
    # for a "//" that is never there -- not a loss (the file this happens to is
    # caught by its own missing-source check first), but a stray line naming a
    # temp directory that was never meant to be user-visible.
    # A query this cannot answer is not the same as one that answered "no
    # override" -- jq's own status is checked. Read through command
    # substitution alone, a failed lookup and an absent trackedRepoPath were
    # the same empty string, and this fell through to the generic .config/*
    # mapping either way: for a group whose override existed precisely
    # because its content does NOT belong wherever that generic mapping would
    # look, that is not a missed override, it is the wrong file's content
    # restored under the right group's name.
    #
    # Returns 2 here, not 1: 1 is the ordinary "nothing maps this path, skip
    # it" a caller continues past (.local/bin and friends use it on purpose);
    # this is "the question itself could not be answered," which a caller
    # must not treat the same way.
    sub="$(group_tracked_repo_path "$id" "$p")" || return 2
    if [[ -n "$sub" ]]; then printf '%s\tflat' "$sub"; return 0; fi
    p="${p%/}"
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
#              is simply never written -- nothing to preserve, since the live
#              marker (if any) was never going to be touched in the first
#              place. Not a symptom of anything being wrong, unlike quarantine,
#              which extracts what it holds somewhere a human can find it.
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
#
# <operator-groups-file>, optional: this MACHINE's own, locally-installed
# groups.default.json, distinct from the artifact's bundled copy that every
# group_field/groups_ids/group_paths call above queries. A PoC confirmed why
# it is needed: an artifact whose manifest.json calls a group coupled, but
# whose OWN bundled groups.default.json quietly omits `coupled` for that same
# id, restored it as an ordinary file even while quarantined -- manifest.json
# and groups.default.json are not independent sources for an artifact built
# by an attacker; both are written by the same build, from the same file, so
# checking one against the other proves nothing. The operator's own local
# file is genuinely independent: the artifact cannot edit it. Used only as a
# FLOOR, never a ceiling -- the artifact can still mark something coupled the
# local schema has never heard of (a newer group id), it just cannot talk the
# local schema's OWN classification of a group it recognizes down to false.
restore_rows() {
    local x="$1" verdict="$2" opgroups="${3:-}" id p prefix kind e f rel sub dest action gm coupled
    local wt="$x/worktree"
    [[ -d "$wt" ]] || return 1

    local migdir; migdir="$(_expand '~/.local/state/omarchy/migrations')"
    # Compared below via _path_contained, not a raw string match against
    # $migdir -- _expand does nothing but substitute a leading ~, and $dest is
    # built the same uncanonicalized way. A PoC confirmed the gap: a group
    # declaring its live path with a trailing slash ("~/.local/state/omarchy/"
    # instead of without) made $dest carry a double slash
    # (".../omarchy//migrations/...") that no longer string-equalled $migdir
    # or matched its "/*" prefix, so an old migration marker on a `forward`
    # verdict -- exactly the case this check exists to hold back -- was
    # offered as an ordinary restore instead. Nothing malicious was needed,
    # just an accidental trailing slash in either this machine's own manifest
    # or an artifact's.

    # Captured once, checked, reused for both loops below -- not fed straight
    # into `done < <(groups_ids)`. A process substitution's own exit status is
    # not directly observable at the `done` that closes it (no `$?` slot to
    # check, and `wait "$!"` is unreliable here because loop bodies below spawn
    # their OWN process substitutions -- find, group_paths -- each overwriting
    # $! before control ever returns to this one). A manifest jq cannot parse
    # at all previously produced empty output the SAME way a manifest with
    # genuinely zero groups does: `while read` over either just runs zero
    # times, restore_rows returns 0, and "0 files would be restored" reported
    # as fact about an artifact whose manifest was never actually readable.
    local ids_out; ids_out="$(groups_ids)" || return 1

    # Two collision maps, not one -- they catch two different things that both
    # end in the same loss. prefixcount, keyed by repo-side prefix, is what
    # restore_rows' doc comment describes: two declared directories flattened
    # into the SAME repo location, so a file there cannot be traced back to
    # which live destination it belongs to (`shared` claimed by both
    # ~/.config/one and ~/.config/two -- the repo cannot tell which is which).
    # destcount, keyed by the expanded LIVE path, catches the mirror case: two
    # DIFFERENT repo prefixes ("prefix-one", "prefix-two") that both declared
    # the SAME `live` directory, printed as an ordinary `restore` row for the
    # same file from two sources -- the second _restore_one to run would have
    # backed up what the first had just written. Neither map subsumes the
    # other: swapping one for the other during development silently traded
    # one class of loss for the other, which the original flat-collision spec
    # (same prefix, different live paths) caught immediately.
    local -A prefixcount=() destcount=()
    while read -r id; do
        [[ -n "$id" ]] || continue
        gm="$(group_field "$id" mode)" || return 1
        [[ "$gm" == gen ]] && continue
        local paths_out; paths_out="$(group_paths "$id")" || return 1
        while read -r p; do
            [[ -n "$p" ]] || continue
            # <<<"$(...)" loses the inner command's exit status -- read's own
            # status is what `<<<` reports, and read succeeds on an empty
            # string same as a real answer. Captured first so the status that
            # matters is the one actually checked.
            local rp; rp="$(_restore_repo_prefix "$id" "$p")"; local rprc=$?
            (( rprc == 2 )) && return 1
            (( rprc == 0 )) || continue
            IFS=$'\t' read -r prefix kind <<<"$rp"
            [[ -n "$prefix" ]] || continue
            e="$(_expand "$p")"
            prefixcount[$prefix]=$(( ${prefixcount[$prefix]:-0} + 1 ))
            destcount[$e]=$(( ${destcount[$e]:-0} + 1 ))
        done <<<"$paths_out"
    done <<<"$ids_out"

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
        # The floor described above the function's own comment: the artifact
        # cannot talk this id's coupling down below what the operator's own
        # installed schema, if it recognizes the id at all, already says.
        # Read failures on the operator's own file are not this artifact's
        # fault -- if it cannot be read or the query cannot run, this simply
        # has nothing to add, and the artifact's own answer above stands.
        if [[ -n "$opgroups" && -r "$opgroups" ]]; then
            local local_coupled
            local_coupled="$(jq -r --arg id "$id" \
                '.groups[]? | select(.id==$id) | .coupled // empty' "$opgroups" 2>/dev/null)"
            [[ "$local_coupled" == true ]] && coupled=true
        fi
        action=restore
        [[ "$coupled" == true && "$verdict" == quarantine ]] && action=quarantine

        local paths_out2; paths_out2="$(group_paths "$id")" || return 1
        while read -r p; do
            [[ -n "$p" ]] || continue
            local rp; rp="$(_restore_repo_prefix "$id" "$p")"; local rprc=$?
            (( rprc == 2 )) && return 1
            (( rprc == 0 )) || continue
            IFS=$'\t' read -r prefix kind <<<"$rp"
            [[ -n "$prefix" ]] || continue
            e="$(_expand "$p")"
            # $prefix, for a `flat` kind, is trackedRepoPath -- verbatim from
            # the ARTIFACT's own bundled groups.default.json, never validated
            # against the worktree it is about to be read from. A PoC
            # confirmed the result: trackedRepoPath ".." (or "../../../etc",
            # or an absolute path) made $wt/$prefix resolve OUTSIDE the
            # extracted artifact entirely -- restore read whatever was
            # actually there on the HOST filesystem (real files under /etc,
            # in the PoC) and, with --apply, copied it under $HOME. Every
            # other containment check in this file guards the WRITE side
            # (the destination); this is the read side, and nothing checked
            # it. Refused as `escape`, before existence is even asked --
            # `-e` on a path outside the worktree can be true, which is
            # exactly the danger.
            if ! _path_contained "$wt/$prefix" "$wt"; then
                printf 'escape\t%s\t%s\t%s\n' "$id" "$prefix" "$e"
                continue
            fi
            [[ -e "$wt/$prefix" ]] || continue

            if [[ "$kind" == flat ]]; then
                while IFS= read -r -d '' f; do
                    sub="${f##*/}"
                    dest="$e/$sub"
                    # find -print0/read -d '' carries the name through correctly
                    # -- the row this prints does not. It is one line of TSV,
                    # and a name holding a literal tab or newline (a file git
                    # tracked under that name; nothing stops it) rides straight
                    # into the row unescaped. A PoC named one
                    # "x<newline>restore<tab>app<tab>foo": the printf below
                    # split at the embedded newline, and everything after it
                    # became a second, well-formed row -- action "restore",
                    # ending in this SAME $dest -- entirely independent of
                    # whatever action this file's row was actually supposed to
                    # carry. A quarantined file's row can inject a `restore`
                    # row for its own destination this way, and whatever reads
                    # these rows line-by-line has no way to tell the difference.
                    # Refused as `escape`, the same category already used for
                    # a destination that resolves outside where it should.
                    if [[ "$sub" == *$'\n'* || "$sub" == *$'\t'* ]]; then
                        # $dest itself carries the dangerous bytes here (it is
                        # built from $sub) -- sanitized before printing, not
                        # raw, so THIS row cannot become the same injection it
                        # exists to report.
                        local sdest="${dest//$'\n'/\\n}"; sdest="${sdest//$'\t'/\\t}"
                        printf 'escape\t%s\t%s/<name with embedded tab or newline>\t%s\n' "$id" "$prefix" "$sdest"
                    elif ! _restore_contained "$dest"; then
                        printf 'escape\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$sub" "$dest"
                    elif (( ${prefixcount[$prefix]:-1} > 1 || ${destcount[$e]:-1} > 1 )); then
                        printf 'ambiguous\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$sub" "$dest"
                    # held was checked in the tree branch only. A manifest is
                    # free to declare a trackedRepoPath override for the
                    # migrations directory itself, which routes it through
                    # `flat` instead -- the shipped manifest never does this,
                    # but nothing stops one from declaring it, and a forward
                    # verdict restoring an old marker through that path would
                    # be exactly the contradiction the tree branch's held check
                    # exists to prevent.
                    elif [[ "$verdict" == forward ]] && _path_contained "$dest" "$migdir"; then
                        printf 'held\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$sub" "$dest"
                    else
                        printf '%s\t%s\t%s/%s\t%s\n' "$action" "$id" "$prefix" "$sub" "$dest"
                    fi
                done < <(find "$wt/$prefix" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
                # find's own status, checked -- the same fail-open scan_files
                # and prune_bundles were already closed, still open here: a
                # walk that stopped partway produced fewer rows, and "N files
                # would be restored" was printed as a fact about a directory
                # this never finished reading.
                wait "$!" || return 1
            elif [[ -d "$wt/$prefix" ]]; then
                while IFS= read -r -d '' f; do
                    rel="${f#"$wt/$prefix"/}"
                    dest="$e/$rel"
                    # Same injection as the flat branch above, through a
                    # relative path instead of a bare filename -- either a
                    # tracked file or an intermediate directory named with an
                    # embedded tab or newline reaches this row the same way.
                    if [[ "$rel" == *$'\n'* || "$rel" == *$'\t'* ]]; then
                        local sdest="${dest//$'\n'/\\n}"; sdest="${sdest//$'\t'/\\t}"
                        printf 'escape\t%s\t%s/<name with embedded tab or newline>\t%s\n' "$id" "$prefix" "$sdest"
                    elif ! _restore_contained "$dest"; then
                        printf 'escape\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$rel" "$dest"
                    # The collision map was checked for `flat` only. Two groups
                    # are free to declare the same live directory -- nothing
                    # stops two ids both naming ~/.config/hypr -- and for
                    # `tree` that means both enumerate the SAME $wt/$prefix and
                    # each emit a `restore` row for every file in it. The
                    # second one to run in _restore_one backs up what the
                    # FIRST one just wrote, not the real original, and the real
                    # original is gone from both the destination and the one
                    # place kept to protect it.
                    elif (( ${prefixcount[$prefix]:-1} > 1 || ${destcount[$e]:-1} > 1 )); then
                        printf 'ambiguous\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$rel" "$dest"
                    elif [[ "$verdict" == forward ]] && _path_contained "$dest" "$migdir"; then
                        printf 'held\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$rel" "$dest"
                    else
                        printf '%s\t%s\t%s/%s\t%s\n' "$action" "$id" "$prefix" "$rel" "$dest"
                    fi
                done < <(find "$wt/$prefix" \( -type f -o -type l \) -print0 2>/dev/null)
                wait "$!" || return 1
            else
                dest="$e"
                if ! _restore_contained "$dest"; then
                    printf 'escape\t%s\t%s\t%s\n' "$id" "$prefix" "$dest"
                elif (( ${prefixcount[$prefix]:-1} > 1 || ${destcount[$e]:-1} > 1 )); then
                    printf 'ambiguous\t%s\t%s\t%s\n' "$id" "$prefix" "$dest"
                else
                    printf '%s\t%s\t%s\t%s\n' "$action" "$id" "$prefix" "$dest"
                fi
            fi
        done <<<"$paths_out2"

        # The plugins group is `triple`: local plugin directories are restored
        # by the path loop above like any tree, but publish also writes an
        # enabled-plugins list and per-plugin patches that no declared path
        # points at, and nothing here ever looked for them. They are reported,
        # not applied -- a patch is something to run `git apply` on knowingly,
        # not something to overwrite a live plugin tree with.
        if [[ "$gm" == triple ]]; then
            [[ -f "$wt/lists/omarchy-plugins.txt" ]] \
                && printf 'report\t%s\tlists/omarchy-plugins.txt\t-\n' "$id"
            # Guarded like the other two find call sites -- patches/omarchy-
            # plugins only exists at all once some plugin has been patched,
            # which is not the common case. Without the guard, find on a
            # directory that legitimately does not exist exits 1 same as it
            # would on one it could not read, and wait "$!" || return 1 could
            # not tell "nothing here" from "something went wrong": it killed
            # restore's own plan for every artifact that never had a dirty
            # plugin, blaming the manifest for a directory that was never
            # supposed to exist in the first place.
            if [[ -d "$wt/patches/omarchy-plugins" ]]; then
                while IFS= read -r -d '' f; do
                    rel="${f#"$wt"/}"
                    # Same TSV injection as the flat/tree branches above --
                    # this row's action is only ever "report" (never applied),
                    # but the row it can forge by riding an embedded newline
                    # is not: this is as much an injection vector as those.
                    if [[ "$rel" == *$'\n'* || "$rel" == *$'\t'* ]]; then
                        printf 'escape\t%s\t%s\t-\n' "$id" "patches/omarchy-plugins/<name with embedded tab or newline>"
                    else
                        printf 'report\t%s\t%s\t-\n' "$id" "$rel"
                    fi
                done < <(find "$wt/patches/omarchy-plugins" -maxdepth 1 -type f -name '*.patch' -print0 2>/dev/null)
                wait "$!" || return 1
            fi
        fi
    done <<<"$ids_out"
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
    # Re-checked immediately before the write that actually matters, not only
    # once at the top -- a parent directory swapped for a symlink in the
    # window between the first check and this line would otherwise be
    # followed by the mkdir -p and the cp right after it. This narrows the
    # window to what is unavoidable with these tools; it does not close it --
    # a symlink swapped between THIS check and the write below still wins,
    # which would need an O_NOFOLLOW-style primitive bash does not have.
    _restore_contained "$dest" || return 1
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
