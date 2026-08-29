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
# Returns 2 for "the targets list itself could not be parsed" -- distinct
# from 1, "parsed fine, this version is not in it". A process substitution
# has no `$?` a caller can check on the loop that reads from it, so a jq
# failure here (an unlikely second parse of a string this function's own
# caller just fetched with jq, but not impossible) used to look exactly
# like "genuinely out of range": the while loop ran zero times either way,
# and this returned 1 regardless. A PoC confirmed the result: a quarantine
# verdict citing "the backup declares it can restore onto <empty>" printed
# as a real incompatibility rather than "could not confirm compatibility".
_restore_in_range() {
    local v="$1" targets="$2" t out
    [[ -n "$v" && "$v" != unknown ]] || return 1
    out="$(printf '%s' "$targets" | jq -r '.[]?' 2>/dev/null)" || return 2
    while read -r t; do
        [[ -n "$t" ]] || continue
        # shellcheck disable=SC2053 -- the glob is the point
        [[ "$v" == $t ]] && return 0
    done <<<"$out"
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
    # Each query's own status, checked -- 2>/dev/null discarded stderr, but
    # nothing checked jq's exit code either. `// "0"` only degrades a query
    # that SUCCEEDED against a null/absent field; it says nothing about one
    # that never completed at all. A PoC confirmed the gap: a jq that
    # printed "0" and then exited 1 produced a watermark that passed the
    # numeric-format check below same as a genuine "no migrations" answer
    # would, and the verdict this artifact's manifest could not actually be
    # read for was decided anyway. Refused as return 2 -- this is the
    # artifact's own manifest, the same side of the distinction this
    # function's other two returns already draw.
    bv="$(jq -r '.omarchy.version // "unknown"' "$m" 2>/dev/null)" || return 2
    bm="$(jq -r '.omarchy.migrationWatermark // "0"' "$m" 2>/dev/null)" || return 2
    targets="$(jq -c '.supportedTargets // []' "$m" 2>/dev/null)" || return 2
    IFS=$'\t' read -r tv tc tm <<<"$(omarchy_identity)"

    _restore_in_range "$tv" "$targets"; local range_rc=$?
    if (( range_rc == 2 )); then
        return 2
    elif (( range_rc != 0 )); then
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
# dirname($1)'s containment, not $1's own -- the same distinction $src's
# own check in _restore_one draws, and for the same reason: realpath -m
# follows the FINAL component too, and a destination this file has not
# customized yet can legitimately still BE a live symlink to a package-
# installed default living outside $HOME. _restore_one never follows that
# symlink to write through it -- it unlinks first (rm -f, then cp -Pp) --
# so refusing on the symlink's OWN target protected nothing: a PoC
# confirmed the actual write mechanism, simulated directly, lands a
# regular file inside $HOME regardless of what the pre-existing symlink at
# $dest pointed to. Checking only that the DIRECTORY $dest lives in stays
# contained still catches the traversal this exists to close (a declared
# path or an ancestor directory that itself escapes), without also
# refusing the single file on a machine most likely to need restoring --
# exactly the one nobody has customized away from its package default yet.
_restore_contained() { _path_contained "$(dirname "$1")" "$HOME"; }

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
    #
    # Neither map catches a THIRD shape, though: two declared live paths
    # where one is an ANCESTOR of the other -- ~/.config/foo (tree, mirrors
    # everything under it) and ~/.config/foo/bar (also declared, its own
    # entry). destcount's exact-string keying treats those as two unrelated
    # paths -- they never collide as strings -- but the FIRST group's walk
    # already recurses into bar/ on its own, and the second group's separate
    # walk over the same files produces a second row for the same
    # destination. A PoC confirmed the result: two rows, one destination,
    # neither flagged ambiguous; --apply wrote the file twice, and the
    # SECOND write's backup overwrote the first's in replaced/ -- the
    # operator's real original was gone from both the live destination and
    # the one place kept to protect it. seen_e/poisoned_e catch this by
    # checking every new live path against every one already seen for a
    # strict ancestor/descendant relationship, not just equality.
    #
    # Both destcount and poisoned_e are keyed on $ec (canonical), not $e.
    # A first version compared $e's raw spelling, and two PoCs went straight
    # through it: a trailing slash on one of two otherwise-identical live
    # paths (".../foo/" vs ".../foo"), and two declared paths that are not
    # textually related AT ALL but are the SAME real location because one is
    # a symlink to the other (~/.config/alias -> ~/.config/foo, both
    # declared). Either one reproduced the exact replaced/-overwritten loss
    # this map exists to prevent, just through a spelling the string
    # comparison never saw as related. realpath -m resolves both: the
    # trailing slash lexically, the symlink by actually following it on
    # THIS machine's real filesystem, where the alias genuinely is one.
    local -A prefixcount=() destcount=() poisoned_e=()
    local -a seen_e=()
    # frow_* capture every individual FILE this walk would enumerate under a
    # flat or tree declared path, one snapshot pass, not re-walked later --
    # the same TOCTOU reasoning publish_staging's own single-pass capture is
    # built on. Collision detection above (prefixcount/destcount/poisoned_e)
    # only ever compared the DECLARED bases against each other; it has
    # nothing to say about two files from two UNRELATED, non-overlapping
    # bases landing on the same live destination because a symlink partway
    # INSIDE one of the trees points at the other. A PoC confirmed the
    # result: group `foo` (tree) and group `bar` (tree) declare unrelated,
    # non-aliased paths; the artifact's own `foo/link/` is an ordinary
    # tracked directory, but the LIVE target already has `~/.config/foo/link
    # -> ~/.config/bar` -- a symlink that exists only on the machine being
    # restored to, not in the artifact. Restoring `foo`'s tree writes
    # through that link into bar/, restoring `bar`'s own declared path
    # writes there directly, and whichever one runs second backs up what
    # the first one just wrote over the operator's real original --
    # permanently: the ONLY backup slot for bar/file now holds the first
    # restore's borrowed content, not the file that was actually there
    # before either ran. Every declared-path check above is blind to this:
    # `foo` and `bar` are not ancestors of each other, not aliases of each
    # other, and neither string nor realpath -m says otherwise. Only
    # walking each tree's actual FILES and canonicalizing each one's
    # resolved destination -- following exactly the live symlinks a real
    # write would follow -- catches it.
    local -a frow_id=() frow_prefix=() frow_rel=() frow_dest=()
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
            local ec; ec="$(realpath -m -- "$e" 2>/dev/null)" || return 1
            # A fallback to the raw string here -- ec="$e" on failure -- would
            # have made a broken realpath (missing binary, an environment
            # hostile enough to make -m itself fail) quietly reopen the exact
            # string-comparison bug this canonicalization exists to close.
            [[ -n "$ec" ]] || return 1
            prefixcount[$prefix]=$(( ${prefixcount[$prefix]:-0} + 1 ))
            destcount[$ec]=$(( ${destcount[$ec]:-0} + 1 ))
            local existing_e
            for existing_e in "${seen_e[@]}"; do
                [[ "$existing_e" == "$ec" ]] && continue
                if [[ "$ec" == "$existing_e"/* || "$existing_e" == "$ec"/* ]]; then
                    poisoned_e[$ec]=1
                    poisoned_e[$existing_e]=1
                fi
            done
            seen_e+=("$ec")

            # The same walk the emit loop below used to do itself, moved
            # here and captured instead of printed immediately: this is the
            # ONE pass over each tree/flat directory's contents, and the
            # emit loop reuses what is captured here rather than walking
            # again.
            #
            # Gated by the SAME containment check the emit loop's own escape
            # row is built from, checked here too rather than assumed -- a
            # prefix that resolves outside the worktree (trackedRepoPath
            # from the artifact's own manifest, never validated against the
            # worktree it names) would otherwise have `find` walk whatever
            # is actually there on the host filesystem before the emit
            # loop's escape check ever gets a chance to refuse it. Nothing
            # from such a walk is ever restored -- the emit loop's escape
            # check still fires first and skips straight past this id's
            # flat/tree branch entirely -- but there is no reason to walk a
            # path this is never going to use.
            if _path_contained "$wt/$prefix" "$wt" && [[ -e "$wt/$prefix" ]]; then
                if [[ "$kind" == flat ]]; then
                    while IFS= read -r -d '' f; do
                        local frel="${f##*/}"
                        frow_id+=("$id"); frow_prefix+=("$prefix")
                        frow_rel+=("$frel"); frow_dest+=("$e/$frel")
                    # A trailing slash on the argument -- not "$wt/$prefix"
                    # bare. find does not dereference a symlink given as ITS
                    # OWN starting argument unless told to with -L or a
                    # trailing slash; without either, a $prefix that is
                    # itself a symlink to a directory (a shared-config
                    # pattern a repo can legitimately track) makes find
                    # report only the symlink's own path, matching -type l,
                    # and never descend into it at all. A PoC confirmed the
                    # result: one garbled row (the prefix-strip below never
                    # matches an entry with no "/" after it, so `frel` was
                    # the whole absolute worktree path) and every real file
                    # actually inside the symlinked tree invisible to
                    # restore entirely.
                    done < <(find "$wt/$prefix/" -maxdepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
                    wait "$!" || return 1
                elif [[ -d "$wt/$prefix" ]]; then
                    while IFS= read -r -d '' f; do
                        local frel="${f#"$wt/$prefix"/}"
                        frow_id+=("$id"); frow_prefix+=("$prefix")
                        frow_rel+=("$frel"); frow_dest+=("$e/$frel")
                    done < <(find "$wt/$prefix/" \( -type f -o -type l \) -print0 2>/dev/null)
                    wait "$!" || return 1
                else
                    # A `tree`-kind prefix that is not a directory in the
                    # worktree at all -- a single-file group, the emit
                    # loop's own `else` branch (dest=$e, no walk). The
                    # reasoning that skipped this case entirely -- "no walk,
                    # no alias risk: there is nothing to enumerate" -- is
                    # true about this branch PRODUCING an alias, but wrong
                    # about it being the TARGET of one: another group's tree
                    # walk can land on this exact file through a live
                    # symlink neither string comparison nor declared-base
                    # ancestry sees, and this branch being absent from the
                    # file-level map meant nobody ever checked it from
                    # either side. A PoC (two declared bases unrelated by
                    # either measure -- one a lone file, the other a tree
                    # containing a live-symlink alias into it) confirmed the
                    # result: no ambiguous verdict, 2 files restored, and
                    # the operator's real original gone -- not just from the
                    # live destination, but from the ONE backup slot meant
                    # to protect it, because _restore_one keys that slot on
                    # the same canonical destination both sides alias to.
                    frow_id+=("$id"); frow_prefix+=("$prefix")
                    frow_rel+=(""); frow_dest+=("$e")
                fi
            fi
        done <<<"$paths_out"
    done <<<"$ids_out"

    # Canonicalized the same way publish_staging's own per-file destination
    # map is: realpath -m follows every symlink that actually exists along
    # the path, ancestors included -- the exact mechanism that resolves
    # `foo/link/file` and `bar/file` to the SAME physical location when
    # `foo/link` is a live symlink to `bar`, which neither string comparison
    # nor the declared-path-only canonicalization above could ever see.
    # Poisoning is by ancestor-directory lookup, not a pairwise scan, for
    # the same reason publish_staging's own scan was rewritten this way:
    # O(n^2) here is exactly the same blowup over exactly the same shape of
    # data (hundreds of individual files across a real machine's groups),
    # just discovered a round later.
    local n_frow="${#frow_id[@]}" k fdc anc
    local -a frow_dc=()
    local -A fdestcount=() fleaf_seen=() fdir_seen=() fpoisoned=()
    for (( k = 0; k < n_frow; k++ )); do
        fdc="$(realpath -m -- "${frow_dest[$k]}" 2>/dev/null)" || return 1
        [[ -n "$fdc" ]] || return 1
        frow_dc+=("$fdc")
        fdestcount[$fdc]=$(( ${fdestcount[$fdc]:-0} + 1 ))
        anc="$fdc"
        while [[ "$anc" == */* && "$anc" != "/" ]]; do
            anc="${anc%/*}"
            [[ -n "$anc" ]] || break
            fdir_seen[$anc]=1
        done
        fleaf_seen[$fdc]=1
    done
    for (( k = 0; k < n_frow; k++ )); do
        fdc="${frow_dc[$k]}"
        [[ -n "${fdir_seen[$fdc]:-}" ]] && fpoisoned[$fdc]=1
        anc="$fdc"
        while [[ "$anc" == */* && "$anc" != "/" ]]; do
            anc="${anc%/*}"
            [[ -n "$anc" ]] || break
            if [[ -n "${fleaf_seen[$anc]:-}" ]]; then
                fpoisoned[$fdc]=1
                fpoisoned[$anc]=1
            fi
        done
    done

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
            # group_field's own status, checked -- nested directly inside
            # $(_generated_files "$(...)") it was not, and a failed query
            # produced the same empty string _generated_files' own case
            # statement returns for an id it genuinely has no entry for.
            # Either way the for loop below ran zero times and said
            # nothing: "no generated lists for this group" and "could not
            # find out which lists this group generates" looked identical,
            # and a recovery plan silently omitted the report rows that
            # point at whatever this artifact's package/systemd lists are.
            local gen; gen="$(group_field "$id" generator)" || return 1
            for f in $(_generated_files "$gen"); do
                rel="$(_generated_repo_name "$f")" || continue
                [[ -e "$wt/$rel" ]] && printf 'report\t%s\t%s\t-\n' "$id" "$rel"
            done
            continue
        fi

        coupled="$(group_field "$id" coupled)" || return 1
        # A second floor, entirely inside the artifact: manifest.json records
        # its OWN copy of coupled per group (_bundle_manifest, built from the
        # SAME groups.default.json at build time), and this used to be the
        # only one ever read for the decision above. Nothing kept the two
        # documents honest against each other for an artifact an attacker
        # assembled by hand -- a PoC confirmed a manifest.json claiming
        # coupled:true for a group while tool/groups.default.json quietly
        # said false restored that group anyway; neither document is a
        # trusted second opinion on its own, but the query above only ever
        # consulted one of the two places this artifact makes the same claim,
        # and disagreeing with itself is not a reason to pick the answer that
        # applies more.
        local manifest_coupled
        manifest_coupled="$(jq -r --arg id "$id" \
            '.groups[]? | select(.id==$id) | .coupled // empty' "$x/manifest.json")" || return 1
        [[ "$manifest_coupled" == true ]] && coupled=true
        # The floor described above the function's own comment: the artifact
        # cannot talk this id's coupling down below what the operator's own
        # installed schema, if it recognizes the id at all, already says.
        #
        # jq's own status is checked -- not discarded into 2>/dev/null the
        # way the first version of this floor did. A genuinely absent id
        # (jq succeeds, produces nothing) legitimately has nothing to add,
        # and the artifact's own answer stands. But a file that EXISTS and
        # is READABLE yet fails to PARSE -- corrupted, truncated, edited by
        # hand into invalid JSON -- used to look exactly the same as
        # "absent": empty output either way, `2>/dev/null` erasing the
        # difference. A PoC confirmed the result: an unreadable-to-jq local
        # manifest let the artifact's own (less restrictive) answer win,
        # which is precisely what this floor exists to prevent. The
        # question this floor asks was not answered "no" -- it could not be
        # asked at all, and a floor that cannot be checked must not be
        # skipped.
        if [[ -n "$opgroups" ]]; then
            # -r alone used to gate this: a file that EXISTS but cannot be
            # READ (permissions, ownership drift) failed -r the same way a
            # path that was never given at all does, and the floor skipped
            # itself silently either way. A PoC confirmed the result: a
            # local schema at mode 000, artifact claiming coupled:false,
            # restored anyway. $opgroups being genuinely EMPTY (the third
            # argument simply not passed -- an older caller, a test) is the
            # only case this floor has nothing to add for; a non-empty path
            # this cannot read is a floor that cannot be checked, and one
            # that cannot be checked must refuse, not skip.
            [[ -r "$opgroups" ]] || return 1
            local local_coupled
            local_coupled="$(jq -r --arg id "$id" \
                '.groups[]? | select(.id==$id) | .coupled // empty' "$opgroups")" || return 1
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
            # Canonicalized the same way the counting pass above keys
            # destcount/poisoned_e -- a lookup against the raw $e here would
            # miss both maps for the exact spellings (trailing slash, a
            # symlink alias) they exist to catch.
            local ec; ec="$(realpath -m -- "$e" 2>/dev/null)" || return 1
            # A fallback to the raw string here -- ec="$e" on failure -- would
            # have made a broken realpath (missing binary, an environment
            # hostile enough to make -m itself fail) quietly reopen the exact
            # string-comparison bug this canonicalization exists to close.
            [[ -n "$ec" ]] || return 1
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

            if [[ "$kind" == flat || -d "$wt/$prefix" ]]; then
                # Iterated from the single capture pass above, not walked
                # again -- a second walk here is exactly the TOCTOU window
                # publish_staging's own preflight-then-rsync gap turned out
                # to have: a file that appears between the two walks is in
                # neither collision map, but a second find would still
                # enumerate and write it.
                local fk
                for (( fk = 0; fk < n_frow; fk++ )); do
                    [[ "${frow_id[$fk]}" == "$id" && "${frow_prefix[$fk]}" == "$prefix" ]] || continue
                    sub="${frow_rel[$fk]}"
                    dest="${frow_dest[$fk]}"
                    local dc="${frow_dc[$fk]}"
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
                    # prefixcount/destcount/poisoned_e catch two DECLARED
                    # bases colliding; fdestcount/fpoisoned catch two
                    # individual FILES colliding once each is resolved
                    # through whatever symlinks actually exist on the live
                    # filesystem -- two different, non-subsuming checks, the
                    # same way prefixcount and destcount above are.
                    elif (( ${prefixcount[$prefix]:-1} > 1 || ${destcount[$ec]:-1} > 1 || ${fdestcount[$dc]:-1} > 1 )) \
                         || [[ -n "${poisoned_e[$ec]:-}" || -n "${fpoisoned[$dc]:-}" ]]; then
                        printf 'ambiguous\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$sub" "$dest"
                    elif [[ "$verdict" == forward ]] && _path_contained "$dest" "$migdir"; then
                        printf 'held\t%s\t%s/%s\t%s\n' "$id" "$prefix" "$sub" "$dest"
                    else
                        printf '%s\t%s\t%s/%s\t%s\n' "$action" "$id" "$prefix" "$sub" "$dest"
                    fi
                done
            else
                dest="$e"
                # The matching single-file entry frow_* captured for this
                # exact (id, prefix): there is at most one, since this
                # branch never walks a directory.
                local fk2 dc2=""
                for (( fk2 = 0; fk2 < n_frow; fk2++ )); do
                    [[ "${frow_id[$fk2]}" == "$id" && "${frow_prefix[$fk2]}" == "$prefix" ]] || continue
                    dc2="${frow_dc[$fk2]}"
                    break
                done
                if ! _restore_contained "$dest"; then
                    printf 'escape\t%s\t%s\t%s\n' "$id" "$prefix" "$dest"
                elif (( ${prefixcount[$prefix]:-1} > 1 || ${destcount[$ec]:-1} > 1 || ${fdestcount[$dc2]:-1} > 1 )) \
                     || [[ -n "${poisoned_e[$ec]:-}" || ( -n "$dc2" && -n "${fpoisoned[$dc2]:-}" ) ]]; then
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
    # Every OTHER containment check in this file guards $dest, the WRITE
    # side; nothing guarded $src, the READ side, at all. restore_rows is the
    # only caller and only ever hands this a $rel it itself built from a safe
    # walk -- but a caller that writes wherever $rel points must not trust
    # that its only caller got $rel right, the same reasoning _restore_contained
    # below is re-checked for $dest rather than trusted from the plan. A
    # crafted group id containing an embedded tab (closed at its source in
    # groups_ids now, but this is the second, independent gate) shifted a
    # printed row's fields so $rel arrived here as "../../../../etc/hostname"
    # instead of the row's real relative path; a PoC confirmed the result
    # before this check existed: _restore_one read /etc/hostname off the HOST
    # filesystem and copied it into the target under an unrelated name.
    # Refused before existence is even asked -- -e on a path outside the
    # worktree can be true, which is exactly the danger.
    #
    # dirname($src)'s containment, not $src's own -- realpath -m follows
    # the FINAL component too, and $src can legitimately be a symlink whose
    # own target lives outside the worktree (a theme config symlinked to a
    # package-installed default, say). A PoC confirmed the regression this
    # introduced: an honest artifact with such a symlink -- unrelated to
    # the injection this check exists to close -- was refused outright,
    # rc=1, "could not be written", where fe29845's _restore_one had
    # correctly restored it as a symlink (never following it, per the `-P`
    # a few lines below). The traversal this exists to catch (a $rel with
    # "../" in it, not a symlink at the leaf) is fully caught by the
    # DIRECTORY containing $src resolving outside the worktree -- checking
    # only that, the same distinction _publish_contained already draws for
    # the write side in lib/publish.sh, closes the injection without also
    # refusing legitimate content.
    _path_contained "$(dirname "$src")" "$x/worktree" || return 1
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
        # ${dest#"$HOME"/} is a lexical strip, not the normalized path
        # _restore_contained just confirmed containment against -- a $dest
        # containing a literal ".." that still resolves back inside $HOME
        # (a declared path like "~/../$(basename "$HOME")/target": legal
        # containment, illegal-looking string) strips to a suffix that STILL
        # carries the "..", and mkdir -p "$(dirname "$keep")" then creates a
        # directory outside $backup entirely, a sibling of replaced/. The
        # original ends up backed up outside the one place kept to protect
        # it, while the report goes on naming $backup as where it landed.
        # realpath -m first, so the suffix stripped is the path containment
        # was actually checked against, not its unresolved spelling.
        #
        # dirname($dest), resolved, plus $dest's own LEXICAL basename --
        # not realpath -m on the whole path. The full-path form followed a
        # pre-existing symlink AT $dest to wherever it pointed (a package
        # default outside $HOME, say) and filed the backup under THAT
        # path instead: contained inside $backup still, since the prefix
        # strip only ever removes a literal $HOME/ and nothing worse
        # happens, but archived under a name nobody restoring by hand
        # would ever think to look for -- the live original silently
        # mislaid rather than protected. The write below never follows
        # that symlink either (cp -Pp copies it as a link, and the branch
        # this runs in is about to rm -f it and write fresh content), so
        # the backup slot should not follow it when computing where to
        # file the original.
        local dest_dir_rp; dest_dir_rp="$(realpath -m -- "$(dirname "$dest")" 2>/dev/null)" || return 1
        local dest_rp="$dest_dir_rp/$(basename "$dest")"
        # Stripped against realpath -e "$HOME", not $HOME's own raw
        # spelling -- the same canonical form containment was just
        # checked against a few lines up (_restore_contained resolves its
        # base the same way). $HOME with a symlink component (a common
        # /home/user -> /mnt/data/user layout) or a relative --into target
        # never literally prefixes the now-canonicalized $dest_rp, so the
        # `#"$HOME"/` strip removed nothing at all: the backup landed at
        # replaced/<dest_rp's full path> instead of replaced/<the path
        # relative to $HOME> -- contained inside $backup still, but filed
        # under a name nobody restoring by hand would think to look for.
        # This is the same mislaying class the leaf-symlink fix just
        # closed, reopened by the OTHER half of what "$HOME" can mean.
        local home_rp; home_rp="$(realpath -e -- "$HOME" 2>/dev/null)" || return 1
        local keep="$backup/${dest_rp#"$home_rp"/}"
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

# ── the durable restore journal ─────────────────────────────────────────────
# `restore --apply` is deliberately never launched by the panel itself (the
# restore-panel design round settled on a terminal handoff, not an in-panel
# apply) -- but the panel still needs to say something once that terminal
# closes, and it cannot watch a process it never started. This is the
# record that makes that possible: one file, one destination-state-style
# atomic write (mkdir -p + write-to-.tmp + mv, the same idiom
# dest_state_write already uses), holding the outcome of the most recent
# --apply run regardless of whether it succeeded, partially succeeded, or
# failed outright. A plan-only run writes nothing here, the same as it
# writes nothing anywhere else.
#
# A SIBLING of restore/, not a file inside it: restore/ is the directory
# holding one mktemp -d slot per --apply run (.../restore/<stamp>-XXXX/), and
# a spec (`ls "$state/restore" | wc -l` counting how many such slots exist)
# confirmed directly that a file dropped into that same directory is counted
# as a slot too, off-by-one against every caller that enumerates it that way.
RESTORE_LAST_FILE_REL="restore-last.json"

# restore_record <json-doc> -- overwrites the durable record with <json-doc>.
# Never dies on failure: a restore that ran to completion but could not save
# its own receipt should still exit reporting what it actually did, not fail
# the whole command over a state-directory write -- but it DOES warn on
# stderr now (a review round pointed out that "silent by design" and "silent
# by omission" looked identical before this: a read-only state directory or a
# full disk made the journal indistinguishable from one that had simply never
# run). `rm -f "$p.tmp"` first, not `>` straight onto whatever name is
# already there: a review round confirmed this is the exact symlink-follow
# `_publish_file` (lib/publish.sh) was already fixed against -- a `.tmp` path
# pre-planted as a symlink gets written THROUGH, and the `mv` right after
# moves the link itself over the real file, leaving every future record
# silently redirected wherever that link pointed.
restore_record() {
    local doc="$1" p="$OMABACKUP_STATE/$RESTORE_LAST_FILE_REL"
    mkdir -p "$(dirname "$p")" 2>/dev/null || {
        printf 'omabackup: could not make %s -- the restore journal was not saved\n' \
            "$(dirname "$p")" >&2
        return 1
    }
    rm -f "$p.tmp" 2>/dev/null
    if printf '%s\n' "$doc" >"$p.tmp" 2>/dev/null && mv "$p.tmp" "$p" 2>/dev/null; then
        return 0
    fi
    printf 'omabackup: could not save the restore journal at %s\n' "$p" >&2
    rm -f "$p.tmp" 2>/dev/null
    return 1
}

# restore_last_json -- the durable record; JSON null means exactly one thing
# (no --apply has EVER run against this state directory -- the file does not
# exist). A record that DOES exist but cannot be read as valid JSON
# (truncated, corrupted, permissions) is a different fact and must never
# collapse into that same null -- it becomes {"unreadable":true} instead, so
# a consumer can never mistake "nothing to report" for "something happened
# and I can't tell what."
#
# A review round found the previous version actively lying in this exact
# spot: `jq -e .` PRINTS its value and only THEN exits non-zero when the
# last token is itself `null`/`false`, or when valid JSON is followed by
# trailing garbage -- so `jq -e . "$p" 2>/dev/null || printf 'null'` emitted
# the parsed record with a second `null` appended right after it
# ('{"ok":true} null'), which is not valid JSON at all. That went straight
# into cmd_status's `--argjson lastrestore "$(restore_last_json)"` with no
# `|| echo null` fallback (the only one of five neighbouring --argjson calls
# missing it) -- jq refused the whole document, and `status --json` died
# with NO field reaching the panel, not just this one. Captured into a
# variable and validated BEFORE anything is printed, so this function now
# only ever emits one clean, complete value.
restore_last_json() {
    local p="$OMABACKUP_STATE/$RESTORE_LAST_FILE_REL" raw jrc
    [[ -f "$p" ]] || { printf 'null'; return 0; }
    # jq's own exit status is checked, not just what it printed: jq parses a
    # STREAM of top-level values by default, so a valid record followed by
    # trailing garbage prints the valid value to stdout and only THEN fails
    # on the garbage -- capturing stdout alone (the first version here)
    # caught that record, re-validated it in isolation, and served it as
    # good. A file is not "the bytes jq managed to emit before it choked."
    raw="$(jq -c . "$p" 2>/dev/null)"; jrc=$?
    if (( jrc == 0 )) && [[ -n "$raw" ]] && jq -e . >/dev/null 2>&1 <<<"$raw"; then
        printf '%s' "$raw"
        return 0
    fi
    printf '{"unreadable":true}'
}
