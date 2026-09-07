#!/bin/bash
# Listing what `restore` could read (docs/DESIGN.md restore-panel design round).
#
# `restore` has always taken a path and said nothing about what paths exist.
# The panel cannot list a `dir` destination itself -- QuickShell.Io.Process is
# the only I/O it is allowed, per the same invariant `status`/`verify` already
# honor -- so this is the CLI verb that makes a restore-picking UI possible at
# all. `github` is not a source here: docs/DESIGN.md never gave it a bundle to
# hold, only the repo itself.
#
# Three destination-level states, not one flat list, because "no artifacts"
# and "could not tell" must never render the same way: a NAS that is merely
# unmounted is not the same fact as a NAS with nothing on it yet, and a `find`
# that stopped partway is not a listing either -- same reasoning `prune_bundles`
# already applies to deletion, applied here to what gets shown at all.
#
# _artifact_manifest_file's own decompressed-byte cap and wall-clock timeout,
# below -- flagged by marketplace security review (2026-09-06): this listing
# path runs `zstd -dc | tar -xO` over EVERY matching file in a `dir`
# destination this tool shares with other processes by design (NAS,
# Syncthing), with no bound of its own. `_zstd_extract` (lib/bundle.sh) closed
# the identical shape for the restore path itself; this is the same fix
# applied to the read-only listing path restore's own bound never covered.
#
# 1 MiB, not lib/bundle.sh's 4 GiB: a real manifest.json (host, createdAt,
# omarchy identity, repo head/dirty, verify.ok) is a few hundred bytes. 1 MiB
# is generous headroom for that shape while still bounding a crafted archive's
# worst case to something that costs nothing to reject, not "however much CPU
# and temp-filesystem space exists." Validated as a canonical positive decimal
# before use, same reasoning as OMABACKUP_RESTORE_MAX_BYTES (lib/bundle.sh):
# GNU `head -c -N` means "all but the last N bytes," the opposite of a cap, so
# an unvalidated negative override would have made this functionally
# unlimited instead of tighter.
#
# This cap MUST apply to what `tar -xO` writes OUT, not to how far it may
# read to find the member -- round omabackup-41 review (both reviewers,
# independently) caught the first version of this fix applying it to the
# latter instead: `head -c` sat BETWEEN zstd and tar, bounding the raw
# decompressed TAR STREAM tar is allowed to consume before giving up. A
# legitimate bundle's own total size is unbounded on purpose (`build_bundle`,
# lib/bundle.sh, includes the whole `repo.bundle` -- the dotfiles repo's full
# git history, which only grows -- plus this tool's own ~500KB `tool/`
# staging), and `tar -C stage -cf - .` has no `--sort`, so `./manifest.json`'s
# own position in the archive is whatever `readdir` happens to return, not
# something this project controls. `omabackup-rev-2` reproduced the failure
# end to end: a real, non-malicious 3MB artifact with `manifest.json` placed
# after `repo.bundle` was reported `valid:false` ("corrupt or truncated
# archive") and vanished from the restore TUI's own artifact list entirely --
# indistinguishable from a genuinely corrupt backup, for a backup that was
# completely intact. See _artifact_manifest_file's own updated pipe order
# below for the fix.
# Length-bounded against ARTIFACT_MANIFEST_MAX_BYTES_CEILING before ANY
# arithmetic context, same reasoning and shape as _log_tail's own
# LOG_TAIL_MAX_LINES check (lib/log.sh) -- found by review (round
# omabackup-43, `omabackup-rev`): `^[1-9][0-9]*$` alone accepts a decimal
# so large that `_artifact_manifest_file`'s own `$(( ARTIFACT_MANIFEST_MAX_BYTES + 1 ))`
# overflows bash's signed 64-bit `(( ))` and wraps to a negative number --
# and GNU `head -c` treats a negative count as "all but the last N bytes,"
# the exact opposite of a cap, the same class of bug already closed once
# for OMABACKUP_RESTORE_MAX_BYTES (lib/bundle.sh). 1 GiB is far more
# headroom than a real manifest.json's own default (1 MiB) could ever
# plausibly need to grow into, while sitting nowhere near the overflow
# boundary even after the `+ 1`.
ARTIFACT_MANIFEST_MAX_BYTES_CEILING=1073741824
if [[ "${OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES:-}" =~ ^[1-9][0-9]*$ ]] \
    && (( ${#OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES} <= ${#ARTIFACT_MANIFEST_MAX_BYTES_CEILING} )) \
    && (( 10#$OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES <= ARTIFACT_MANIFEST_MAX_BYTES_CEILING )); then
    ARTIFACT_MANIFEST_MAX_BYTES="$OMABACKUP_ARTIFACT_MANIFEST_MAX_BYTES"
else
    ARTIFACT_MANIFEST_MAX_BYTES=1048576
fi

# 10s, not lib/bundle.sh's 120s: this reads one small named member out of one
# archive, not a whole backup's worth of files -- a real read finishes in a
# fraction of a second even on slow media. Same canonical-positive-decimal
# validation as OMABACKUP_RESTORE_TIMEOUT_SEC.
if [[ "${OMABACKUP_ARTIFACT_MANIFEST_TIMEOUT_SEC:-}" =~ ^[1-9][0-9]*$ ]]; then
    ARTIFACT_MANIFEST_TIMEOUT_SEC="$OMABACKUP_ARTIFACT_MANIFEST_TIMEOUT_SEC"
else
    ARTIFACT_MANIFEST_TIMEOUT_SEC=10
fi

# _artifact_manifest_file <archive> <outfile> -- writes manifest.json's bytes
# to a FILE rather than through a bash variable. A review round found that a
# manifest.json containing a raw NUL byte (a malicious artifact can put one
# there; a bundle this tool built itself never would) got silently truncated
# by bash's command substitution -- jq then validated and served the
# TRUNCATED text as valid:true, with no sign the original bytes differed.
# Reading straight from the file with `jq -e . <file>` / `jq --slurpfile`
# never routes the bytes through a bash variable at all, so a raw NUL makes
# the JSON syntactically invalid (NUL must be u0000-escaped inside a JSON
# string) and jq correctly refuses it -- the right outcome, valid:false,
# instead of a quiet truncation.
#
# The whole pipe runs under `timeout --kill-after`, the same idiom
# `_zstd_extract` (lib/bundle.sh) and bin/omabackup-tui already use for
# exactly this reason: `timeout` alone sends TERM at the deadline and then
# WAITS for the child, so a stage that ignores or is slow to act on TERM
# makes the ceiling not actually hold (measured live there: a child ignoring
# TERM under a 3s timeout still reported 124, but only after 20 real
# seconds). `timeout` without `--foreground` creates its own process group
# for zstd/tar/head together and signals that whole group on expiry, so a
# hung zstd does not outlive a killed tar.
#
# The byte cap sits AFTER `tar -xO`, not between zstd and tar (fixed in
# round omabackup-41, see the comment above ARTIFACT_MANIFEST_MAX_BYTES for
# the full story of why the first placement was wrong): `tar` is left free
# to read as much of the decompressed stream as it needs to LOCATE
# `./manifest.json`, however large the rest of the bundle is, and only the
# bytes `tar -xO` actually EXTRACTS from that one member are bounded. A
# crafted archive whose `manifest.json` member is itself a bomb is still
# fully contained: `head -c`, now watching tar's own output instead of
# zstd's, only ever writes up to the cap, and the resulting SIGPIPE back
# through tar/zstd (once head stops reading) is exactly what `pipefail`
# already turns into this pipe's own non-zero status -- measured directly:
# tar itself exits non-zero (cut off mid-write of the oversized member),
# distinct from a legitimate small manifest, where tar finishes writing
# before head's cap is ever reached and both exit 0.
#
# Deliberately WITHOUT `--occurrence=1`, despite that flag looking like the
# obvious complement (make tar stop as soon as it finds the member, instead
# of reading to the archive's own end). Tried it, measured it, reverted it:
# `--occurrence=1` makes tar exit the instant it is satisfied, which closes
# tar's own stdin while zstd may still be mid-write -- zstd then gets its
# OWN SIGPIPE (141) purely from tar stopping early, on every single
# legitimate small manifest, indistinguishable by exit code alone from the
# real failure this whole mechanism exists to catch. Confirmed live: with
# `--occurrence=1`, a real, valid 2MB artifact reported `pipestatus: 141 0
# 0` -- tar succeeded (its own status is 0), but pipefail's own "rightmost
# non-zero" rule surfaces zstd's incidental 141 anyway, marking a perfectly
# good backup unrestorable. Without `--occurrence=1`, tar reads its input
# through to natural EOF regardless of when it finds the member, so zstd
# never gets cut off for a benign reason -- `pipestatus: 0 0 0` for the same
# fixture. This also preserves an existing, load-bearing property: a valid
# zstd frame with trailing garbage appended must still be rejected (a
# separate round's own regression, "a valid frame with trailing garbage is
# marked invalid, not valid:true" -- `restore`'s own extraction of the WHOLE
# archive has no early exit and WOULD hit that garbage and fail, so this
# listing must not call the artifact valid:true first). `--occurrence=1`
# would not have broken that specific case, but the version without it does
# not need to reason about that separately: zstd still runs to completion
# and still reports its own real corruption honestly either way. The
# bomb case pays no meaningful cost for dropping `--occurrence=1` either --
# `head -c`'s own early close already bounds the pipe within a few
# milliseconds regardless (measured: ~4ms), since nothing downstream is
# still consuming zstd's output past the cap.
#
# `env -u TAR_OPTIONS`, matching `_zstd_extract` (lib/bundle.sh:732): an
# inherited TAR_OPTIONS could in principle redirect where tar's own output
# goes, same class of bypass closed there -- not demonstrated exploitable on
# this specific invocation (no `--index-file`/member-name-escaping surface
# for it to redirect), but free, and keeps both `tar` invocations in this
# project holding the same environment contract rather than two by accident.
#
# The pipe's own exit status is NOT sufficient to detect truncation right at
# the cap boundary -- found by review (round omabackup-42, `omabackup-rev`):
# whether `head -c` cutting off the stream actually reaches back as a
# SIGPIPE through tar/zstd depends on pipe-buffer timing, not just on
# whether the true content exceeds the cap. A large overage (the 50MB bomb)
# reliably blocks tar mid-write and cascades a real SIGPIPE; a SMALL overage
# (reproduced: exactly 1 byte past the cap) can have tar finish writing
# everything -- overage included -- into the pipe buffer before `head`
# finishes counting and closes, so tar exits 0 naturally and nothing is ever
# cut off, even though `head` still quietly discarded the excess byte(s)
# from its own output. Confirmed live: `pipestatus: 0 0 0`, function
# returned 0, for a manifest exactly cap+1 bytes long whose truncated
# cap-byte prefix happened to still be complete JSON on its own -- accepted
# as valid despite genuinely exceeding the configured limit.
#
# Fixed by reading one byte MORE than the real cap (`cap + 1`) and then
# explicitly checking the WRITTEN file's own size afterward: if it reached
# `cap + 1`, the true content was at or past the limit regardless of which
# exit codes did or didn't fire along the way. This does not replace the
# exit-status check above it -- that still catches missing members and
# zstd's own real corruption -- it closes the one class those statuses
# cannot: silent, unsignaled truncation.
_artifact_manifest_file() {
    local archive="$1" out="$2" size
    # ./manifest.json, not manifest.json: the bundle's members are stored with
    # the leading "./" (tar -C stage -x's own doing, confirmed against a real
    # bundle), and tar -xO does not normalize that away when matching a name.
    timeout --kill-after=5s "${ARTIFACT_MANIFEST_TIMEOUT_SEC}s" bash -c '
        set -o pipefail
        zstd -dc -- "$1" 2>/dev/null \
            | env -u TAR_OPTIONS tar -xO ./manifest.json 2>/dev/null \
            | head -c "$2"
    ' _ "$archive" "$(( ARTIFACT_MANIFEST_MAX_BYTES + 1 ))" >"$out" || return $?
    size="$(stat -c %s -- "$out" 2>/dev/null)" || return 1
    (( size <= ARTIFACT_MANIFEST_MAX_BYTES ))
}

# _artifact_entry <path> <name> <size> <mtime-epoch>
# One artifact's metadata, or its refusal -- and always ONE OR THE OTHER: this
# function is written to never fail and never print empty output, because its
# caller appends its stdout straight into a bash array with the exit status
# unchecked (`items+=("$(_artifact_entry ...)")`), and `jq -s` downstream
# treats a blank element as insignificant whitespace between JSON values
# rather than a syntax error. A review round demonstrated exactly that: a
# manifest.json that is valid JSON but the WRONG SHAPE (a bare `[]` instead of
# an object) makes the field-projection jq call below fail with "cannot index
# array with string" -- and before this fix, that failure's empty output just
# vanished from the array. The file did not become valid:false; it disappeared
# from the destination entirely, the exact silent-drop this project has hit
# and fixed as a class of bug more than once (see the `find` status checks
# throughout lib/destinations.sh and lib/restore.sh).
_artifact_entry() {
    local path="$1" name="$2" size="$3" mtime="$4"
    local tmp; tmp="$(mktemp)" || {
        jq -n --arg f "$name" --arg p "$path" --argjson sz "${size:-0}" --arg mt "${mtime:-0}" \
            '{file:$f, path:$p, sizeBytes:$sz, mtimeEpoch:($mt|tonumber? // 0|floor),
              valid:false, error:"could not allocate a working file to read this artifact'"'"'s manifest"}'
        return 0
    }
    local mrc
    _artifact_manifest_file "$path" "$tmp"; mrc=$?
    if (( mrc != 0 )); then
        rm -f "$tmp"
        jq -n --arg f "$name" --arg p "$path" --argjson sz "${size:-0}" --arg mt "${mtime:-0}" \
            '{file:$f, path:$p, sizeBytes:$sz, mtimeEpoch:($mt|tonumber? // 0|floor),
              valid:false, error:"this artifact does not extract cleanly -- corrupt or truncated archive"}'
        return 0
    fi
    if [[ ! -s "$tmp" ]] || ! jq -e . "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        jq -n --arg f "$name" --arg p "$path" --argjson sz "${size:-0}" --arg mt "${mtime:-0}" \
            '{file:$f, path:$p, sizeBytes:$sz, mtimeEpoch:($mt|tonumber? // 0|floor),
              valid:false, error:"could not read manifest.json from this artifact"}'
        return 0
    fi
    local out orc
    out="$(jq -n --arg f "$name" --arg p "$path" --argjson sz "${size:-0}" --arg mt "${mtime:-0}" \
        --slurpfile m "$tmp" '
        ($m[0]) as $mm |
        {file:$f, path:$p, sizeBytes:$sz, mtimeEpoch:($mt|tonumber? // 0|floor),
         valid:true,
         host:($mm.host // null), createdAt:($mm.createdAt // null),
         omarchy:{version:($mm.omarchy.version // null), channel:($mm.omarchy.channel // null),
                  migrationWatermark:($mm.omarchy.migrationWatermark // null)},
         repo:{head:($mm.repo.head // null), dirty:($mm.repo.dirty // null)},
         verifyOk:($mm.verify.ok // null)}' 2>/dev/null)"; orc=$?
    rm -f "$tmp"
    if (( orc != 0 )) || [[ -z "$out" ]]; then
        jq -n --arg f "$name" --arg p "$path" --argjson sz "${size:-0}" --arg mt "${mtime:-0}" \
            '{file:$f, path:$p, sizeBytes:$sz, mtimeEpoch:($mt|tonumber? // 0|floor),
              valid:false, error:"manifest.json is valid JSON but not in the shape this tool expects"}'
        return 0
    fi
    printf '%s' "$out"
}

# _artifacts_for_dest <id> <dir> -- one destination's block of the document.
#
# NUL-delimited throughout, size/mtime before the name and the name last, not
# a plain newline-joined TSV: a `dir` destination is a mount this tool shares
# with other processes (NAS, Syncthing) by design, and this project's own
# threat model already assumes a filename here is not necessarily one this
# tool wrote. A review round confirmed both failure shapes directly against a
# crafted destination -- a tab in the name silently dropped that ARTIFACT
# from the list while the destination still reported state:"ok" (worse than
# the list-failed state this function otherwise takes care to produce
# honestly); a newline in the name split ONE file into several bogus rows.
# Putting the name last means `read`'s own field-soak behavior hands it
# everything remaining on the record, tabs included, and NUL (not newline) as
# the record terminator means an embedded newline can never end a record
# early. This is the same `find -print0` / `read -r -d ''` / `wait "$!"`
# idiom already used throughout lib/restore.sh and lib/publish.sh for exactly
# this reason.
_artifacts_for_dest() {
    local id="$1" dir="$2"
    if [[ ! -d "$dir" ]]; then
        jq -n --arg id "$id" --arg path "$dir" \
            '{id:$id, path:$path, state:"unreachable",
              error:"directory does not exist or is not mounted", artifacts:[]}'
        return 0
    fi
    local -a items=()
    local size mtime name found=0
    while IFS=$'\t' read -r -d '' size mtime name; do
        [[ -n "$name" ]] || continue
        found=1
        items+=("$(_artifact_entry "$dir/$name" "$name" "$size" "$mtime")")
    done < <(find "$dir" -maxdepth 1 -type f -regextype posix-extended \
        -regex ".*/omabackup-.+-${DEST_NAME_TAIL}" -printf '%s\t%T@\t%f\0' 2>/dev/null)
    if ! wait "$!"; then
        jq -n --arg id "$id" --arg path "$dir" \
            --arg err "could not list $dir -- the walk stopped partway (unreadable entry, or the mount went away mid-read)" \
            '{id:$id, path:$path, state:"list-failed", error:$err, artifacts:[]}'
        return 0
    fi
    if (( ! found )); then
        # A destination that has recorded a successful push before (dest_state
        # would not have a lastSuccess otherwise), yet whose directory carries
        # no ownership stamp right now, is not credible as "genuinely empty."
        # A review round pointed out the likely real cause: a removable drive
        # that unmounted leaves its (parent filesystem's own) empty mountpoint
        # directory behind, indistinguishable from a fresh directory by `-d`
        # alone -- but the stamp lived on the REAL device, not the mountpoint,
        # so its absence here is the tell. This mirrors the same DEST_STAMP
        # reasoning prune_bundles' own ownership check already relies on.
        if [[ -n "$(dest_state "$id" '.lastSuccess // empty')" ]] && [[ ! -f "$dir/$DEST_STAMP" ]]; then
            jq -n --arg id "$id" --arg path "$dir" \
                --arg err "this destination has a recorded successful push, but the directory now carries no ownership stamp -- looks like an unmounted drive's empty mountpoint, not a genuinely empty destination" \
                '{id:$id, path:$path, state:"unreachable", error:$err, artifacts:[]}'
            return 0
        fi
        jq -n --arg id "$id" --arg path "$dir" \
            '{id:$id, path:$path, state:"empty", error:null, artifacts:[]}'
        return 0
    fi
    jq -n --arg id "$id" --arg path "$dir" \
          --argjson arts "$(printf '%s\n' "${items[@]}" | jq -s 'sort_by(-.mtimeEpoch)')" \
        '{id:$id, path:$path, state:"ok", error:null, artifacts:$arts}'
}

# artifacts_json -- every `dir` destination, in the shape `omabackup artifacts
# --json` publishes and the panel's artifact list reads directly.
#
# assert_destinations_understood runs first (the caller, cmd_artifacts, does
# not skip it): without it, a destinations.json that fails to PARSE at all
# degrades dest_ids to an empty read silently, and "no dir destinations
# configured" and "could not read destinations.json" produced the exact same
# {"destinations":[]} document -- the same "not found" vs "could not look"
# confusion this file's own header says the per-destination states exist to
# avoid, just one level up, at the document as a whole. dest_field's own
# status is checked per call too: a query that fails for one destination
# (not the whole file) now surfaces as that one destination's own
# list-failed, rather than silently vanishing from the array or being
# looked up under an empty path.
artifacts_json() {
    assert_destinations_understood
    local id type path; local -a blocks=()
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if ! type="$(dest_field "$id" type)"; then
            blocks+=("$(jq -n --arg id "$id" \
                '{id:$id, path:null, state:"list-failed",
                  error:"could not read this destination'"'"'s type from destinations.json", artifacts:[]}')")
            continue
        fi
        [[ "$type" == dir ]] || continue
        if ! path="$(dest_field "$id" path)"; then
            blocks+=("$(jq -n --arg id "$id" \
                '{id:$id, path:null, state:"list-failed",
                  error:"could not read this destination'"'"'s path from destinations.json", artifacts:[]}')")
            continue
        fi
        blocks+=("$(_artifacts_for_dest "$id" "$path")")
    done < <(dest_ids)
    # dest_ids' own status, checked: by the time this runs,
    # assert_destinations_understood has already confirmed the file parses
    # and validates, so a failure here is an exceptional runtime failure
    # (jq crashing, OOM), not a data problem -- loud and fatal, the same
    # severity every other such failure in this codebase gets, rather than
    # a silently truncated destination list a caller would read as complete.
    wait "$!" || die "could not enumerate destinations from $(_tilde "$DESTINATIONS_FILE") -- refusing to report a possibly incomplete artifact list"
    if (( ${#blocks[@]} == 0 )); then
        jq -n '{schemaVersion:1, destinations:[]}'
        return 0
    fi
    jq -n --argjson d "$(printf '%s\n' "${blocks[@]}" | jq -s '.')" \
        '{schemaVersion:1, destinations:$d}'
}
