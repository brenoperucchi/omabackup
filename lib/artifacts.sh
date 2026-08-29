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

# _artifact_manifest <archive> -- prints manifest.json's bytes on stdout.
# Mirrors _zstd_extract's own reasoning (lib/bundle.sh): `tar -xO` alone would
# report only tar's exit status, and tar can finish reading the one member it
# wants before a later zstd failure downstream of the pipe is ever observed --
# a valid frame followed by trailing garbage extracts manifest.json cleanly
# and only THEN fails, past the point tar had any reason to notice. pipefail
# makes the pipeline's status the worse of the two, and the CALLER now reads
# that status (a review round caught it not being read at all: an artifact
# `restore` itself refuses as unextractable was still reported here as
# valid:true). This never writes anything to disk and never runs the
# artifact's own embedded tool -- listing is a read of one small JSON member,
# not an extraction.
_artifact_manifest() {
    local archive="$1"
    local _had_pf=0; [[ -o pipefail ]] && _had_pf=1
    set -o pipefail
    # ./manifest.json, not manifest.json: the bundle's members are stored with
    # the leading "./" (tar -C stage -x's own doing, confirmed against a real
    # bundle), and tar -xO does not normalize that away when matching a name.
    zstd -dc "$archive" 2>/dev/null | tar -xO ./manifest.json 2>/dev/null
    local rc=$?
    (( _had_pf )) || set +o pipefail
    return $rc
}

# _artifact_manifest_file <archive> <outfile> -- like _artifact_manifest, but
# writes to a FILE rather than returning bytes through a bash variable. A
# review round found that a manifest.json containing a raw NUL byte (a
# malicious artifact can put one there; a bundle this tool built itself never
# would) got silently truncated by bash's command substitution -- jq then
# validated and served the TRUNCATED text as valid:true, with no sign the
# original bytes differed. Reading straight from the file with `jq -e .
# <file>` / `jq --slurpfile` never routes the bytes through a bash variable at
# all, so a raw NUL makes the JSON syntactically invalid (NUL must be
# u0000-escaped inside a JSON string) and jq correctly refuses it -- the
# right outcome, valid:false, instead of a quiet truncation.
_artifact_manifest_file() {
    local archive="$1" out="$2"
    local _had_pf=0; [[ -o pipefail ]] && _had_pf=1
    set -o pipefail
    zstd -dc "$archive" 2>/dev/null | tar -xO ./manifest.json 2>/dev/null >"$out"
    local rc=$?
    (( _had_pf )) || set +o pipefail
    return $rc
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
