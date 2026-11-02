#!/bin/bash
# The secrets group, mode "age" (docs/DESIGN.md §6).
#
# A declared secret reaches staging only as age ciphertext for the recipients
# this machine accepted. Which files are secrets, and who may decrypt them,
# is local configuration under ~/.config/omabackup/secrets/, never the
# shipped manifest and never the backup repo: whoever controls the repo must
# not be able to add a recipient and receive the next sync's secrets.
#
#   recipients.txt  age public keys, one per line, # comments allowed
#   files.json      {"schemaVersion":1,"files":[{"live":"~/...","name":"x"}]}
#
# No files.json means the group is off: nothing is read, age is not needed.
#
# The plaintext is read once into a private directory, hashed and encrypted
# from that same copy, then removed. The hash lives only in local state, next
# to the plaintext it describes; publishing it would hand anyone a verifier to
# test guesses against a short .env.

SECRETS_CONFIG_DIR="${OMABACKUP_SECRETS_DIR:-$HOME/.config/omabackup/secrets}"
SECRETS_RECIPIENTS="$SECRETS_CONFIG_DIR/recipients.txt"
SECRETS_FILES="$SECRETS_CONFIG_DIR/files.json"
SECRETS_ACCEPTED="$OMABACKUP_STATE/secrets-recipients.accepted"
SECRETS_STATE="$OMABACKUP_STATE/secrets.json"
SECRETS_DRILLS="$OMABACKUP_STATE/secrets-drills.json"
SECRETS_REPO_DIR="secrets/age"
SECRETS_MAX_BYTES=1048576
# Entries in one index. Collect refuses more, and so does restore, so a backup
# is never written that this build cannot read back (review 92).
SECRETS_MAX_ENTRIES=1000
SECRETS_DRILL_MAX_DAYS=90
AGE_HEADER="age-encryption.org/v1"

# Every file headed for secrets/age/ is checked with this before it is
# published and again in the tree about to be committed. The deny-list reads
# text; a keyring, an NSS database or an SSH key written through in the clear
# would pass it untouched, so this is the gate for this directory. It reads a
# file, never a pipe: head closing a pipe early kills a large producer with
# SIGPIPE, and under pipefail that read as "not ciphertext" (review 87).
_secrets_is_age() {
    local got
    [[ -f "$1" && ! -L "$1" ]] || return 1
    got="$(head -c $(( ${#AGE_HEADER} + 1 )) -- "$1" 2>/dev/null | tr '\n' '|')"
    [[ "$got" == "$AGE_HEADER|" ]]
}

_secrets_sha() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

# The recipient lines, comments and blank lines dropped. Fails on any line
# that is not an age X25519 public key: a typo would otherwise be skipped by
# nobody and rejected by age only at encrypt time, or worse, accepted as a
# recipient nobody holds.
#
# With "strict" each key also goes through age's own parser, which checks the
# bech32 checksum the pattern cannot (review 87). accept is strict; the sync
# hands age these normalized lines, never the raw file, so a comment age
# would reject cannot break it later.
_secrets_recipients() {  # _secrets_recipients [strict]
    [[ -f "$SECRETS_RECIPIENTS" && ! -L "$SECRETS_RECIPIENTS" ]] || return 2
    local line out=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        [[ "$line" =~ ^age1[02-9ac-hj-np-z]{58}$ ]] || return 3
        if [[ "${1:-}" == strict ]]; then
            age -r "$line" -o /dev/null </dev/null 2>/dev/null || return 3
        fi
        out+="$line"$'\n'
    done <"$SECRETS_RECIPIENTS"
    [[ -n "$out" ]] || return 3
    printf '%s' "$out"
}

# Writes <content> to <file> through a new private file in the same directory
# and a rename: a planted <file>.tmp link is never opened, and a link at
# <file> itself is replaced, not followed (review 87).
_secrets_write_private() {  # _secrets_write_private <file> <content>
    local f="$1" t
    ( umask 077; mkdir -p -- "$(dirname -- "$f")" ) || return 1
    t="$(umask 077; command mktemp -- "$(dirname -- "$f")/.${f##*/}.XXXXXX")" || return 1
    printf '%s\n' "$2" >"$t" && mv -T -- "$t" "$f" || { rm -f -- "$t"; return 1; }
}

_secrets_recipients_fp() {
    local r; r="$(_secrets_recipients)" || return $?
    printf '%s' "$r" | sha256sum | cut -d' ' -f1
}

# 0 accepted, 2 missing, 3 invalid, 4 changed or never accepted.
_secrets_recipients_check() {
    local fp acc
    fp="$(_secrets_recipients_fp)" || return $?
    acc="$(cat -- "$SECRETS_ACCEPTED" 2>/dev/null)"
    [[ -n "$acc" && "$acc" == "$fp" ]] || return 4
    return 0
}

_secrets_recipients_why() {
    case "$1" in
        2) printf 'no recipients file at %s' "$(_tilde "$SECRETS_RECIPIENTS")" ;;
        3) printf '%s holds a line that is not an age public key, or no key at all' "$(_tilde "$SECRETS_RECIPIENTS")" ;;
        4) printf 'the recipients in %s were never accepted, or changed since -- review them and run: omabackup secrets accept' "$(_tilde "$SECRETS_RECIPIENTS")" ;;
        *) printf 'the recipients could not be checked' ;;
    esac
}

# `name<TAB>live` per declared secret. Refuses fields it does not know, a name
# that could escape secrets/age/ or collide with the index, and duplicates.
_secrets_files_list() {
    jq -r '
        if .schemaVersion != 1 then error("schemaVersion must be 1")
        elif (.files | type) != "array" then error("files must be an array")
        elif any(.files[]; (type != "object")
                 or (keys - ["live","name"] | length > 0)
                 or ((.live | type) != "string") or ((.name | type) != "string")
                 or (.live | test("[[:cntrl:]]")) or (.live | startswith("~/") | not)
                 or (.live | test("(^|/)\\.\\.?(/|$)")) or (.live | test("//"))
                 or (.live | endswith("/")) or (.live | test("\\s$"))
                 or (.name | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$") | not))
            then error("each entry needs a live path under ~/ and a plain name")
        elif (.files | map(.name) | length) != (.files | map(.name) | unique | length)
            then error("two entries share a name")
        else .files[] | "\(.name)\t\(.live)" end' "$SECRETS_FILES" 2>/dev/null
}

# `live<TAB>group<TAB>path` for each declared secret whose real path is, or
# lies under, the real path of something another group collects. Every mode
# but age counts, triple included: its patches carry file contents as text,
# which no byte comparison would recognize. Real paths on both sides, so a
# symlinked spelling cannot hide the overlap (reviews 87 and 88).
_secrets_overlap() {
    local list name live srp hit
    list="$(_secrets_files_list)" || return 1
    while IFS=$'\t' read -r name live; do
        [[ -n "$name" ]] || continue
        srp="$(realpath -m -- "$(_expand "$live")" 2>/dev/null)" || return 1
        hit="$(_secrets_path_collected "$srp")" || return 1
        [[ -n "$hit" ]] && printf '%s\t%s\n' "$live" "$hit"
    done <<<"$list"
    return 0
}

# Prints "<group>\t<path>" for the first group that copies <realpath> in the
# clear (every mode but age), comparing real paths; nothing when none does.
# Shared by collect and restore: on a machine that only restored there is no
# files.json, so restore must not put a secret where a group collects it
# (review 91).
_secrets_path_collected() {  # _secrets_path_collected <realpath>
    local srp="$1" ids id mode out p prp
    # Every enabled group, whatever --groups selected: the filter narrows what
    # this run collects, and the next run may collect the rest (review 92).
    ids="$(ONLY="" groups_ids)" || return 1
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        mode="$(group_field "$id" mode)" || return 1
        [[ "$mode" == age ]] && continue
        out="$(group_paths "$id")" || return 1
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            prp="$(realpath -m -- "$(_expand "$p")" 2>/dev/null)" || return 1
            [[ -n "$prp" ]] || return 1
            if [[ "$srp" == "$prp" || "$srp" == "$prp"/* ]]; then
                printf '%s\t%s\n' "$id" "$p"; return 0
            fi
        done <<<"$out"
    done <<<"$ids"
    return 0
}

# Size and hash of every secret read in this run, for cmd_collect's check that
# no other staged file holds the same bytes. Empty secrets are not recorded:
# every empty file would match.
declare -A _SECRETS_SEEN=() _SECRETS_SIZES=()

# The one contract for a declared file, shared by the fingerprint and by
# collect_age. Prints the reason for a refusal. 0: a regular file; 1: missing,
# nothing to protect; 2: refused (review 90).
_secrets_source_state() {  # _secrets_source_state <live> <expanded>
    if [[ -L "$2" ]]; then
        printf '%s is a symlink -- declare the file it points at' "$1"; return 2
    fi
    [[ -e "$2" ]] || return 1
    if [[ ! -f "$2" ]]; then
        printf '%s is not a regular file' "$1"; return 2
    fi
    return 0
}

# Copies at most one byte past the limit, so a huge file is never read whole.
# 0: copied; 1: could not read; 3: larger than the limit.
_secrets_read_bounded() {  # _secrets_read_bounded <src> <dst>
    ( umask 077; head -c "$((SECRETS_MAX_BYTES + 1))" -- "$1" >"$2" ) 2>/dev/null || return 1
    local size; size="$(stat -c %s -- "$2" 2>/dev/null)" || return 1
    (( size <= SECRETS_MAX_BYTES )) || return 3
    return 0
}

# Fills the tables from the declared files as they are now, before any
# collector runs and whichever groups run. Each file is read once into the
# private directory, and its size and hash both come from that copy: taken
# from the live path at two moments, they could describe two versions and
# match no file at all (review 90). The copy is removed once hashed.
#
# A missing file has nothing to protect. A symlink, anything that is not a
# regular file, or one over the limit is refused here, the same way
# collect_age refuses it; the reasons go to $_SECRETS_FP_WHY.
_SECRETS_FP_WHY=()
_secrets_fingerprint() {
    local list name live e size h why rc copy
    _SECRETS_FP_WHY=()
    list="$(_secrets_files_list)" || { _SECRETS_FP_WHY=("the secrets list could not be read"); return 1; }
    [[ -n "$list" ]] || return 0
    _secrets_tmp_make || { _SECRETS_FP_WHY=("could not create a private directory for the secrets"); return 1; }
    copy="$_SECRETS_TMPDIR/fingerprint"
    while IFS=$'\t' read -r name live; do
        [[ -n "$name" ]] || continue
        e="$(_expand "$live")"
        why="$(_secrets_source_state "$live" "$e")"; rc=$?
        (( rc == 1 )) && continue
        (( rc == 0 )) || { _SECRETS_FP_WHY+=("$why"); continue; }
        _secrets_read_bounded "$e" "$copy"; rc=$?
        if (( rc == 3 )); then
            _SECRETS_FP_WHY+=("$live is larger than 1 MiB -- not a secret this group holds"); rm -f -- "$copy"; continue
        fi
        (( rc == 0 )) || { _SECRETS_FP_WHY+=("could not read $live"); rm -f -- "$copy"; continue; }
        size="$(stat -c %s -- "$copy" 2>/dev/null)"
        h="$(_secrets_sha "$copy")"
        rm -f -- "$copy"
        [[ -n "$size" && -n "$h" ]] || { _SECRETS_FP_WHY+=("could not read $live"); continue; }
        (( size > 0 )) || continue
        _SECRETS_SIZES[$size]=1
        _SECRETS_SEEN["$size:$h"]=1
    done <<<"$list"
    (( ${#_SECRETS_FP_WHY[@]} == 0 ))
}

# 0: <file> is clean. 1: its name is a restore's temporary, or its bytes are a
# declared secret's. 2: it could not be read. Used on staging, and on a git
# plugin's files before they become a patch whose bytes no longer equal the
# secret's (review 90).
_secrets_file_flagged() {  # _secrets_file_flagged <file> [size]
    local f="$1" sz="${2:-}" h
    [[ "${f##*/}" == .omabackup-restore.* ]] && return 1
    (( ${#_SECRETS_SIZES[@]} )) || return 0
    [[ -n "$sz" ]] || sz="$(stat -c %s -- "$f" 2>/dev/null)" || return 2
    [[ -n "${_SECRETS_SIZES[$sz]:-}" ]] || return 0
    h="$(_secrets_sha "$f")"
    [[ -n "$h" ]] || return 2
    [[ -n "${_SECRETS_SEEN["$sz:$h"]:-}" ]] && return 1
    return 0
}

# The same check on <path> as it is in <repo>'s HEAD: a plugin's patch carries
# HEAD's lines too, removed or as context. 0: clean or not in HEAD; 1: a
# declared secret's bytes; 2: HEAD could not be read (review 91).
_secrets_blob_flagged() {  # _secrets_blob_flagged <repo> <path>
    local out m t o sz h
    (( ${#_SECRETS_SIZES[@]} )) || return 0
    out="$(git --literal-pathspecs -C "$1" ls-tree -l HEAD -- "$2" 2>/dev/null)" || return 2
    [[ -n "$out" ]] || return 0
    read -r m t o sz <<<"${out%%$'\t'*}"
    [[ "$t" == blob ]] || return 0
    [[ -n "${_SECRETS_SIZES[$sz]:-}" ]] || return 0
    h="$(set -o pipefail; git -C "$1" cat-file blob "$o" 2>/dev/null | sha256sum | cut -d' ' -f1)" || return 2
    [[ -n "$h" ]] || return 2
    [[ -n "${_SECRETS_SEEN["$sz:$h"]:-}" ]] && return 1
    return 0
}

# 0 when nothing staged outside .secrets/ is a secret's bytes or a restore's
# temporary; 1 with the reason in $_SECRETS_GATE_WHY otherwise, including any
# failure to list or hash. The reason never names the file: its name could be
# the secret itself (review 89). Runs on every collect: a restore's temporary
# can exist on a machine with no secrets list (review 90).
_SECRETS_GATE_WHY=""
#
# The listing is held in memory, not in a file: the check must not depend on a
# writable state directory. A directory in staging that cannot be listed is
# left out, since publish cannot read it either; any other failure of find
# refuses.
_secrets_staging_clean_of_secrets() {
    local rec sz sf n=0 frc
    local -a recs=()
    _SECRETS_GATE_WHY="the staged files could not be checked against the declared secrets"
    mapfile -d '' recs < <(find "$STAGING" \( -path "$STAGING/.secrets" -o -type d \( ! -readable -o ! -executable \) \) -prune \
        -o -type f -printf '%s\t%p\0' 2>/dev/null)
    wait $! || return 1
    for rec in "${recs[@]}"; do
        sz="${rec%%$'\t'*}"; sf="${rec#*$'\t'}"
        _secrets_file_flagged "$sf" "$sz"
        case $? in
            0) ;;
            1) n=$((n + 1)) ;;
            *) return 1 ;;
        esac
    done
    (( n == 0 )) && return 0
    _SECRETS_GATE_WHY="$n staged file(s) hold a declared secret's bytes or a restore's temporary (names not shown) -- remove the copies from the other groups' paths"
    return 1
}

_SECRETS_TMPDIR=""
_SECRETS_RESTORE_TMP=""
_secrets_tmp_clean() {
    if [[ -n "$_SECRETS_RESTORE_TMP" ]]; then
        rm -f -- "$_SECRETS_RESTORE_TMP" 2>/dev/null
        _SECRETS_RESTORE_TMP=""
    fi
    [[ -n "$_SECRETS_TMPDIR" ]] || return 0
    rm -rf -- "$_SECRETS_TMPDIR" 2>/dev/null
    _SECRETS_TMPDIR=""
}
# Private and preferably in memory: $XDG_RUNTIME_DIR is a per-user tmpfs on a
# systemd machine. Falls back to the state directory, already 0700.
#
# The EXIT trap removes it on every exit a shell can see. A SIGKILL or a power
# cut cannot be seen, and the fallback outlives them, so each run first
# removes what a run that is no longer alive left there. The owning PID is in
# the name. A directory without one is left alone: its owner cannot be told
# from its name (review 88).
_secrets_tmp_make() {
    local base="${XDG_RUNTIME_DIR:-}" d pid
    [[ -n "$_SECRETS_TMPDIR" && -d "$_SECRETS_TMPDIR" && ! -L "$_SECRETS_TMPDIR" ]] && return 0
    [[ -n "$base" && -d "$base" && -w "$base" ]] || base="$OMABACKUP_STATE"
    ( umask 077; mkdir -p "$base" ) || return 1
    for d in "$base"/omabackup-secrets.*; do
        [[ -d "$d" && ! -L "$d" ]] || continue
        pid="${d##*/omabackup-secrets.}"; pid="${pid%%.*}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -0 "$pid" 2>/dev/null && continue
        rm -rf -- "$d"
    done
    _SECRETS_TMPDIR="$(umask 077; command mktemp -d "$base/omabackup-secrets.$$.XXXXXX")" || return 1
}

# Encrypts <plain> into <out>, or reuses the repo's current ciphertext when the
# plaintext, the recipients and that ciphertext are all the ones recorded last
# time. age output is not deterministic, so without this every sync would be a
# commit. Appends this entry's record to the state being built.
_secrets_seal() {  # _secrets_seal <name> <plain> <out> <rfp>
    local name="$1" plain="$2" out="$3" rfp="$4" psha prev repofile=""
    psha="$(_secrets_sha "$plain")"
    [[ -n "$psha" ]] || return 1
    [[ -n "${OMABACKUP_REPO:-}" ]] && repofile="$OMABACKUP_REPO/$SECRETS_REPO_DIR/$name.age"
    prev="$(jq -r --arg n "$name" '.[$n] | "\(.plain) \(.recipients) \(.cipher)"' <<<"$_SECRETS_OLD" 2>/dev/null)"
    # Produced in the private directory and checked there; only a file that
    # is age ciphertext is ever moved into staging. An age that wrote its
    # input and then failed, or a bare `collect`, leaves nothing (review 87).
    local made="$_SECRETS_TMPDIR/sealed"
    rm -f -- "$made"
    if [[ -n "$repofile" && "$prev" == "$psha $rfp "* ]] && _secrets_is_age "$repofile" \
        && [[ "$(_secrets_sha "$repofile")" == "${prev##* }" ]]; then
        cp -- "$repofile" "$made" || { rm -f -- "$made"; return 1; }
    else
        age -R <(printf '%s' "$_SECRETS_RCPTS") -o "$made" -- "$plain" || { rm -f -- "$made"; return 1; }
    fi
    if ! _secrets_is_age "$made"; then
        rm -f -- "$made"
        printf 'omabackup: what age produced for %s is not age ciphertext\n' "$name" >&2
        return 1
    fi
    mv -T -- "$made" "$out" || return 1
    _SECRETS_NEW="$(jq --arg n "$name" --arg p "$psha" --arg r "$rfp" --arg c "$(_secrets_sha "$out")" \
        '.[$n] = {plain:$p, recipients:$r, cipher:$c}' <<<"$_SECRETS_NEW")" || return 1
}

_SECRETS_OLD='{}'
_SECRETS_NEW='{}'
_SECRETS_RCPTS=""

collect_age() {
    local id="$1"
    if [[ ! -e "$SECRETS_FILES" && ! -L "$SECRETS_FILES" ]]; then
        finding info "$id" secrets-unconfigured "no $(_tilde "$SECRETS_FILES"): nothing to encrypt" ""
        (( JSON )) || printf '  %s-%s %s (not configured)\n' "$DIM" "$NC" "$id"
        return 0
    fi
    local list rc
    list="$(_secrets_files_list)" || die "$(_tilde "$SECRETS_FILES") is not a secrets list this build understands"
    # An empty list is the group switched off: nothing to encrypt, so neither
    # age nor recipients are needed (review 89).
    if [[ -z "$list" ]]; then
        finding info "$id" secrets-unconfigured "$(_tilde "$SECRETS_FILES") lists no files: nothing to encrypt" ""
        (( JSON )) || printf '  %s-%s %s (no files listed)\n' "$DIM" "$NC" "$id"
        return 0
    fi
    require_tools age sha256sum
    (( $(wc -l <<<"$list") <= SECRETS_MAX_ENTRIES )) \
        || die "$(_tilde "$SECRETS_FILES") declares more than $SECRETS_MAX_ENTRIES files -- restore could not read that index back"
    # Read once. The fingerprint checked against the accepted one and the keys
    # age encrypts for come from this same string, so a file edited halfway
    # through, or a line age would parse differently, cannot slip in a key
    # nobody accepted (review 87).
    _SECRETS_RCPTS="$(_secrets_recipients)"; rc=$?
    (( rc == 0 )) || die "not encrypting the secrets group: $(_secrets_recipients_why "$rc")"
    local rfp; rfp="$(printf '%s' "$_SECRETS_RCPTS" | sha256sum | cut -d' ' -f1)"
    [[ -n "$rfp" && "$rfp" == "$(cat -- "$SECRETS_ACCEPTED" 2>/dev/null)" ]] \
        || die "not encrypting the secrets group: $(_secrets_recipients_why 4)"

    _secrets_tmp_make || die "could not create a private directory for the secrets"
    local out="$STAGING/.secrets" plain="$_SECRETS_TMPDIR/plain"
    ( umask 077; mkdir -p "$out" ) || die "could not create $(_tilde "$out")"
    _SECRETS_OLD="$(jq -c 'if type == "object" then . else {} end' "$SECRETS_STATE" 2>/dev/null)" || _SECRETS_OLD='{}'
    [[ -n "$_SECRETS_OLD" ]] || _SECRETS_OLD='{}'
    _SECRETS_NEW='{}'

    local name live e size mode index='[]' w
    local -a why=()
    while IFS=$'\t' read -r name live; do
        [[ -n "$name" ]] || continue
        e="$(_expand "$live")"
        w="$(_secrets_source_state "$live" "$e")"; rc=$?
        if (( rc == 1 )); then
            finding warn "$id" path-missing "declared but missing: $live" "$e"
            continue
        fi
        (( rc == 0 )) || { why+=("$w"); continue; }
        mode="$(stat -c %a -- "$e" 2>/dev/null)" || die "could not read $(_tilde "$e")"
        _secrets_read_bounded "$e" "$plain"; rc=$?
        if (( rc == 3 )); then
            rm -f -- "$plain"
            why+=("$live is larger than 1 MiB -- not a secret this group holds"); continue
        fi
        (( rc == 0 )) || die "could not read $(_tilde "$e")"
        size="$(stat -c %s -- "$plain")"
        if (( size > 0 )); then
            _SECRETS_SIZES[$size]=1
            _SECRETS_SEEN["$size:$(_secrets_sha "$plain")"]=1
        fi
        _secrets_seal "$name" "$plain" "$out/$name.age" "$rfp" \
            || die "could not encrypt $(_tilde "$e")"
        index="$(jq -c --arg n "$name" --arg l "$live" --arg m "$mode" '. + [{name:$n, live:$l, mode:$m}]' <<<"$index")"
    done <<<"$list"
    rm -f -- "$plain"

    if (( ${#why[@]} )); then
        _secrets_tmp_clean
        rm -rf -- "$out"
        for w in "${why[@]}"; do printf '  %s✗%s %s\n' "$RED" "$NC" "$w" >&2; done
        die "refusing the secrets group: a declared secret could not be read safely"
    fi

    # Through stdin: as an argument, an index over 128 KiB hit the kernel's
    # per-argument limit (third analysis).
    jq -c '{schemaVersion:1, files:.}' <<<"$index" >"$plain" \
        || die "could not encrypt the secrets index"
    (( $(stat -c %s -- "$plain") <= SECRETS_MAX_BYTES )) \
        || die "the secrets index is larger than 1 MiB -- restore could not read it back; shorten the paths in $(_tilde "$SECRETS_FILES")"
    _secrets_seal _index "$plain" "$out/_index.age" "$rfp" \
        || die "could not encrypt the secrets index"
    _secrets_tmp_clean

    _secrets_write_private "$SECRETS_STATE" "$_SECRETS_NEW" \
        || printf '  %s!%s could not record the secrets state; the next sync re-encrypts\n' "$YELLOW" "$NC" >&2
    (( JSON )) || printf '  %s✓%s %s\n' "$GREEN" "$NC" "$id"
}

# ── verify ───────────────────────────────────────────────────────────────────
# Without the identity nothing here can prove the backup decrypts. What it can
# do is say how long ago a person proved it, per recipient.
probe_secrets() {
    local id="$1" rc rcpts r last now list
    [[ -e "$SECRETS_FILES" || -L "$SECRETS_FILES" ]] || return 0
    list="$(_secrets_files_list)" || { finding fail "$id" secrets-list "$(_tilde "$SECRETS_FILES") is not a secrets list this build understands" ""; return 0; }
    [[ -n "$list" ]] || return 0
    _secrets_recipients_check; rc=$?
    if (( rc != 0 )); then
        finding fail "$id" secrets-recipients "$(_secrets_recipients_why "$rc")" ""
        return 0
    fi
    rcpts="$(_secrets_recipients)" || return 0
    now="$EPOCHSECONDS"
    while IFS= read -r r; do
        [[ -n "$r" ]] || continue
        last="$(jq -r --arg k "$r" '.[$k] // empty' "$SECRETS_DRILLS" 2>/dev/null)"
        if [[ ! "$last" =~ ^[0-9]+$ ]]; then
            finding warn "$id" secrets-drill "recipient ${r:0:16}... never drilled -- run: omabackup secrets drill -i <its identity>" ""
        elif (( now - last > SECRETS_DRILL_MAX_DAYS * 86400 )); then
            finding warn "$id" secrets-drill "recipient ${r:0:16}... last drilled $(( (now - last) / 86400 )) days ago" ""
        fi
    done <<<"$rcpts"
}

# ── secrets drill / restore ──────────────────────────────────────────────────
# The identity is read once and kept in memory, then handed to age through a
# pipe. An identity file that is itself age-encrypted (the rescue identity,
# wrapped with a passphrase) is decrypted first; age asks for the passphrase
# on the terminal.
_SECRETS_ID=""
# An identity wrapped with `age -p`, in either of the forms age writes: binary,
# or armored with -a. The armored one is the printed copy of the rescue key,
# since binary does not survive paper; it used to be read as a plain identity
# and refused. Only for the identity: secrets/age/ still takes binary alone.
# age skips blank lines above the armor header, and a copy typed back from
# paper easily has some, so the first line that is not blank is the one judged
# (review 94).
_secrets_identity_wrapped() {
    local chunk line
    _secrets_is_age "$1" && return 0
    [[ -f "$1" && ! -L "$1" ]] || return 1
    chunk="$(head -c 1024 -- "$1" 2>/dev/null | tr -d '\0')"
    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" == "-----BEGIN AGE ENCRYPTED FILE-----" ]]
        return
    done <<<"$chunk"
    return 1
}

_secrets_load_identity() {
    local f="$1"
    [[ -n "$f" && -f "$f" ]] || die "no identity file at ${f:-(none given)}"
    if _secrets_identity_wrapped "$f"; then
        _SECRETS_ID="$(age -d -- "$f")" || die "could not unlock the identity at $(_tilde "$f")"
    else
        _SECRETS_ID="$(cat -- "$f")" || die "could not read the identity at $(_tilde "$f")"
    fi
    [[ "$_SECRETS_ID" == *AGE-SECRET-KEY-* ]] || die "$(_tilde "$f") holds no age identity"
}
# Restore and drill decrypt ciphertext anyone holding the public keys can
# write, so the output is bounded like collect's input (1 MiB) and the run has
# a deadline. 0: decrypted; 3: larger than the limit; 1: anything else. The
# partial plaintext is removed on every failure (review 91).
#
# The override must be a positive number of seconds: GNU timeout reads 0 as
# "no deadline" (review 92).
SECRETS_DECRYPT_SECONDS="${OMABACKUP_SECRETS_DECRYPT_TIMEOUT:-60}"
_secrets_decrypt() {  # _secrets_decrypt <in> <out>
    local rc sz
    [[ "$SECRETS_DECRYPT_SECONDS" =~ ^[1-9][0-9]{0,3}$ ]] \
        || die "OMABACKUP_SECRETS_DECRYPT_TIMEOUT must be a whole number of seconds from 1 to 9999"
    ( umask 077; set -o pipefail
      timeout -k 5 "$SECRETS_DECRYPT_SECONDS" age -d -i <(printf '%s\n' "$_SECRETS_ID") -- "$1" 2>/dev/null \
          | head -c "$((SECRETS_MAX_BYTES + 1))" >"$2" ); rc=$?
    sz="$(stat -c %s -- "$2" 2>/dev/null)" || sz=-1
    if (( sz > SECRETS_MAX_BYTES )); then
        rm -f -- "$2"; return 3
    fi
    (( rc == 0 && sz >= 0 )) && return 0
    rm -f -- "$2"; return 1
}

_secrets_parse_args() {
    _SA_IDENTITY=""; _SA_FROM=""; _SA_APPLY=0; _SA_FORCE=0
    while (($#)); do
        case "$1" in
            -i|--identity) (($# >= 2)) || die "$1 needs a path"; _SA_IDENTITY="$2"; shift 2 ;;
            --from)        (($# >= 2)) || die "--from needs a directory"; _SA_FROM="$2"; shift 2 ;;
            --apply)       _SA_APPLY=1; shift ;;
            --force)       _SA_FORCE=1; shift ;;
            *) die "unknown flag for secrets: $1" ;;
        esac
    done
    [[ -n "$_SA_IDENTITY" ]] || die "secrets needs -i <identity file>"
    if [[ -z "$_SA_FROM" ]]; then
        [[ -n "${OMABACKUP_REPO:-}" ]] || die "OMABACKUP_REPO is not set; pass --from <dir holding the .age files>"
        _SA_FROM="$OMABACKUP_REPO/$SECRETS_REPO_DIR"
    fi
    [[ -d "$_SA_FROM" ]] || die "no secrets at $(_tilde "$_SA_FROM")"
}

# Decrypts the index into $_SECRETS_TMPDIR/index.json, or dies.
_secrets_open_index() {
    _secrets_is_age "$_SA_FROM/_index.age" || die "no encrypted index at $(_tilde "$_SA_FROM/_index.age")"
    _secrets_tmp_make || die "could not create a private directory"
    local rc
    _secrets_decrypt "$_SA_FROM/_index.age" "$_SECRETS_TMPDIR/index.json"; rc=$?
    (( rc == 3 )) && { _secrets_tmp_clean; die "the secrets index is larger than 1 MiB -- not one this tool wrote"; }
    (( rc == 0 )) \
        || { _secrets_tmp_clean; die "this identity cannot decrypt the secrets index -- it is not one of its recipients"; }
    # No control characters anywhere: the plan is printed for a person to
    # read, and an index can be forged (review 91).
    jq -e --argjson max "$SECRETS_MAX_ENTRIES" '.schemaVersion == 1 and (.files | type == "array") and (.files | length <= $max)
           and all(.files[]; (.name | type == "string") and (.live | type == "string")
                   and ((.mode // "600") | type == "string")
                   and ([.name, .live, (.mode // "600")] | all(test("[[:cntrl:]]") | not)))' \
        "$_SECRETS_TMPDIR/index.json" >/dev/null 2>&1 \
        || { _secrets_tmp_clean; die "the secrets index is not one this build understands"; }
}

_secrets_index_rows() {
    jq -r '.files[] | "\(.name)\t\(.live)\t\(.mode // "600")"' "$_SECRETS_TMPDIR/index.json"
}

# 0 when every directory from <dir> up to <home> is owned by this user and
# writable by nobody else. A restore writes with this user's rights; a
# directory another account can write to lets that account swap it for a
# symlink between the check and the rename (review 89). Refused instead.
_secrets_dir_private() {  # _secrets_dir_private <dir-realpath> <home-realpath>
    local d="$1" home="$2" uid owner perm me
    me="$(id -u)"
    while :; do
        read -r owner perm < <(stat -c '%u %a' -- "$d" 2>/dev/null) || return 1
        [[ "$owner" == "$me" ]] || return 1
        (( (8#$perm & 8#022) == 0 )) || return 1
        [[ "$d" == "$home" ]] && { _secrets_home_anchored "$home"; return; }
        [[ "$d" == "$home"/* ]] || return 1
        d="${d%/*}"
    done
}

# A private home is not enough: whoever can write to the directory holding it
# can rename it and put a symlink in its place between the checks and the
# write. So every directory above the home belongs to root or to the user, and
# one that others can write to has the sticky bit, as /tmp does (review 90).
_secrets_home_anchored() {  # _secrets_home_anchored <home-realpath>
    local d="$1" me owner perm
    me="$(id -u)"
    while [[ "$d" != / ]]; do
        d="${d%/*}"; [[ -n "$d" ]] || d=/
        read -r owner perm < <(stat -c '%u %a' -- "$d" 2>/dev/null) || return 1
        [[ "$owner" == 0 || "$owner" == "$me" ]] || return 1
        if (( (8#$perm & 8#022) != 0 )); then
            (( (8#$perm & 8#1000) != 0 )) || return 1
        fi
    done
    return 0
}

# age does not authenticate who encrypted a file: anyone holding the public
# keys can write an index that decrypts fine. So the index is input, and an
# entry is restored only to a plain name under ~/ with no . or .. component.
# The plan prints every destination before --apply writes any of them.
_secrets_entry_ok() {  # _secrets_entry_ok <name> <live>
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] || return 1
    [[ "$2" == "~/"?* ]] || return 1
    [[ "$2" != *[[:cntrl:]]* ]] || return 1
    [[ "/${2#"~/"}/" != */../* && "/${2#"~/"}/" != */./* && "/${2#"~/"}/" != *//* ]]
}

cmd_secrets() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        accept)  reject_flags "secrets accept" "$@"; _secrets_accept ;;
        drill)   _secrets_drill "$@" ;;
        restore) _secrets_restore "$@" ;;
        *) die "usage: omabackup secrets <accept|drill|restore> [-i <identity>] [--from <dir>] [--apply] [--force]" ;;
    esac
}

_secrets_accept() {
    local r rc fp
    require_tools age sha256sum
    r="$(_secrets_recipients strict)"; rc=$?
    (( rc == 0 )) || die "$(_secrets_recipients_why "$rc")"
    fp="$(printf '%s' "$r" | sha256sum | cut -d' ' -f1)"
    _secrets_write_private "$SECRETS_ACCEPTED" "$fp" || die "could not record the accepted recipients"
    printf 'Accepted %d recipient(s); the next sync encrypts for exactly these:\n' "$(grep -c . <<<"$r")"
    printf '  %s\n' $r
}

_secrets_drill() {
    _secrets_parse_args "$@"
    require_tools age age-keygen jq sha256sum
    _secrets_load_identity "$_SA_IDENTITY"
    local pubs rcpts p rc
    # A file holding several keys decrypts if any one of them can, and would
    # then stamp every one as drilled: the rescue key could be missing from
    # the backup and still look proven (review 87). One key per drill.
    [[ "$(grep -c '^AGE-SECRET-KEY-' <<<"$_SECRETS_ID")" == 1 ]] \
        || die "a drill takes one identity at a time -- this file holds several; drill each on its own"
    pubs="$(age-keygen -y <(printf '%s\n' "$_SECRETS_ID") 2>/dev/null)" || die "could not derive the public key of this identity"
    rcpts="$(_secrets_recipients)"; rc=$?
    (( rc == 0 )) || die "$(_secrets_recipients_why "$rc")"
    local -a ours=()
    while IFS= read -r p; do
        [[ -n "$p" ]] && grep -qxF -- "$p" <<<"$rcpts" && ours+=("$p")
    done <<<"$pubs"
    (( ${#ours[@]} )) || die "this identity is not one of the recipients in $(_tilde "$SECRETS_RECIPIENTS")"

    _secrets_open_index
    local name live mode e failed=0 n=0 differs=0
    while IFS=$'\t' read -r name live mode; do
        [[ -n "$name" ]] || continue
        if ! _secrets_entry_ok "$name" "$live"; then
            printf '  %s✗%s the index names an unsafe entry -- not trusted\n' "$RED" "$NC"
            failed=1; continue
        fi
        if ! _secrets_decrypt "$_SA_FROM/$name.age" "$_SECRETS_TMPDIR/plain"; then
            printf '  %s✗%s %s does not decrypt\n' "$RED" "$NC" "$name"
            failed=1; continue
        fi
        n=$((n + 1))
        e="$(_expand "$live")"
        if [[ -f "$e" ]] && ! cmp -s -- "$e" "$_SECRETS_TMPDIR/plain"; then
            printf '  %s!%s %s decrypts, but differs from %s (changed since the last sync?)\n' "$YELLOW" "$NC" "$name" "$live"
            differs=1
        else
            printf '  %s✓%s %s\n' "$GREEN" "$NC" "$name"
        fi
        rm -f -- "$_SECRETS_TMPDIR/plain"
    done < <(_secrets_index_rows)
    _secrets_tmp_clean
    (( failed == 0 )) || die "drill failed: not every secret decrypts with this identity"

    local drills; drills="$(jq -c 'if type == "object" then . else {} end' "$SECRETS_DRILLS" 2>/dev/null)" || drills='{}'
    [[ -n "$drills" ]] || drills='{}'
    for p in "${ours[@]}"; do
        drills="$(jq -c --arg k "$p" --argjson t "$EPOCHSECONDS" '.[$k] = $t' <<<"$drills")"
    done
    _secrets_write_private "$SECRETS_DRILLS" "$drills" \
        || die "every secret decrypted, but the drill date could not be recorded"
    printf '\n  drill passed: %d secret(s) decrypt with %s...%s\n' "$n" "${ours[0]:0:16}" \
        "$( (( differs )) && printf ' (some differ from the live files; sync to refresh them)')"
}

# 0 when <path> is one of <roots> or lies under one.
_secrets_in_backup() {  # _secrets_in_backup <path> <root>...
    local p="$1" r; shift
    for r in "$@"; do
        [[ "$p" == "$r" || "$p" == "$r"/* ]] && return 0
    done
    return 1
}

_secrets_restore() {
    _secrets_parse_args "$@"
    require_tools age jq
    _secrets_load_identity "$_SA_IDENTITY"
    _secrets_open_index
    local name live mode e dir refused=0 t home_rp dir_rp hit
    # The backup itself is never a destination for plaintext: the configured
    # repo, the directory --from names and the git tree holding it, by real
    # path (third analysis, omabackup-27).
    local -a backup_roots=()
    local br
    [[ -n "${OMABACKUP_REPO:-}" ]] && br="$(realpath -m -- "$OMABACKUP_REPO" 2>/dev/null)" && [[ -n "$br" ]] && backup_roots+=("$br")
    br="$(realpath -e -- "$_SA_FROM" 2>/dev/null)" || die "could not resolve $(_tilde "$_SA_FROM")"
    backup_roots+=("$br")
    if br="$(git -C "$_SA_FROM" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$br" ]]; then
        br="$(realpath -e -- "$br" 2>/dev/null)" && backup_roots+=("$br")
    fi
    while IFS=$'\t' read -r name live mode; do
        [[ -n "$name" ]] || continue
        if ! _secrets_entry_ok "$name" "$live"; then
            printf '  %s✗%s the index names an unsafe entry -- not restored\n' "$RED" "$NC"
            refused=1; continue
        fi
        # Owner bits only, and always readable and writable by the owner: the
        # index is forgeable, and a secret must not come back open to others.
        [[ "$mode" =~ ^[0-7]{3}$ ]] || mode=600
        mode="$(( ${mode:0:1} | 6 ))00"
        e="$(_expand "$live")"
        _secrets_decrypt "$_SA_FROM/$name.age" "$_SECRETS_TMPDIR/plain"; t=$?
        if (( t == 3 )); then
            printf '  %s✗%s %s is larger than 1 MiB once decrypted -- not restored\n' "$RED" "$NC" "$name"
            refused=1; continue
        elif (( t != 0 )); then
            printf '  %s✗%s %s does not decrypt\n' "$RED" "$NC" "$name"
            refused=1; continue
        fi
        # The spelling was checked; the real directory is checked here, for
        # the plan as much as for --apply, so a parent that is a symlink out
        # of ~/ is refused in both (reviews 87 and 88).
        dir="$(dirname -- "$e")"
        home_rp="$(realpath -e -- "$HOME" 2>/dev/null)"
        dir_rp="$(realpath -m -- "$dir" 2>/dev/null)"
        local probe_d="$dir_rp"
        while [[ ! -e "$probe_d" && "$probe_d" == "$home_rp"/* ]]; do probe_d="${probe_d%/*}"; done
        if [[ -z "$home_rp" ]] || [[ "$dir_rp" != "$home_rp"/* && "$dir_rp" != "$home_rp" ]]; then
            printf '  %s✗%s %s: %s resolves outside ~/ -- not touched\n' "$RED" "$NC" "$name" "$live"
            refused=1
        elif _secrets_in_backup "$dir_rp/${e##*/}" "${backup_roots[@]}"; then
            printf '  %s✗%s %s: %s lies inside the backup itself -- not touched\n' "$RED" "$NC" "$name" "$live"
            refused=1
        elif ! hit="$(_secrets_path_collected "$dir_rp/${e##*/}")"; then
            printf '  %s✗%s %s: could not compare %s with the groups -- not touched\n' "$RED" "$NC" "$name" "$live"
            refused=1
        elif [[ -n "$hit" ]]; then
            printf '  %s✗%s %s: %s is collected in the clear by group %s -- not touched\n' "$RED" "$NC" "$name" "$live" "${hit%%$'\t'*}"
            refused=1
        elif ! _secrets_dir_private "$probe_d" "$home_rp"; then
            printf '  %s✗%s %s: a directory above %s is not private to you -- not touched\n' "$RED" "$NC" "$name" "$live"
            refused=1
        elif [[ -L "$e" || ( -e "$e" && ! -f "$e" ) ]]; then
            printf '  %s✗%s %s: %s is not a regular file -- not touched\n' "$RED" "$NC" "$name" "$live"
            refused=1
        elif [[ -f "$e" ]] && cmp -s -- "$e" "$_SECRETS_TMPDIR/plain"; then
            printf '  %s=%s %s already matches %s\n' "$DIM" "$NC" "$name" "$live"
        elif [[ -f "$e" ]] && (( ! _SA_FORCE )); then
            printf '  %s✗%s %s: %s exists and differs -- not overwritten (--force replaces it)\n' "$RED" "$NC" "$name" "$live"
            refused=1
        elif (( ! _SA_APPLY )); then
            printf '  %s→%s %s would be written to %s (mode %s)\n' "$CYAN" "$NC" "$name" "$live" "$mode"
        else
            # Checked again once the directory exists. The temporary is a new
            # file mktemp creates, never a name that could be planted, and the
            # EXIT trap removes it if the run is cut short. Every directory up
            # to ~ is ours and writable only by us, so no other account can
            # swap one between this check and the rename (review 89).
            t=""
            if ( umask 077; mkdir -p -- "$dir" ) \
                && dir_rp="$(realpath -e -- "$dir" 2>/dev/null)" \
                && [[ "$dir_rp" == "$home_rp"/* || "$dir_rp" == "$home_rp" ]] \
                && _secrets_dir_private "$dir_rp" "$home_rp" \
                && hit="$(_secrets_path_collected "$dir_rp/${e##*/}")" && [[ -z "$hit" ]] \
                && ! _secrets_in_backup "$dir_rp/${e##*/}" "${backup_roots[@]}" \
                && t="$(umask 077; command mktemp -- "$dir_rp/.omabackup-restore.XXXXXX")" \
                && _SECRETS_RESTORE_TMP="$t" \
                && cat -- "$_SECRETS_TMPDIR/plain" >"$t" \
                && chmod "$mode" -- "$t" \
                && mv -T -- "$t" "$dir_rp/${e##*/}"; then
                _SECRETS_RESTORE_TMP=""
                printf '  %s✓%s %s -> %s\n' "$GREEN" "$NC" "$name" "$live"
            else
                [[ -n "$t" ]] && rm -f -- "$t"
                _SECRETS_RESTORE_TMP=""
                printf '  %s✗%s %s could not be written to %s (or it resolves outside ~/)\n' "$RED" "$NC" "$name" "$live"
                refused=1
            fi
        fi
        rm -f -- "$_SECRETS_TMPDIR/plain"
    done < <(_secrets_index_rows)
    _secrets_tmp_clean
    (( _SA_APPLY )) || printf '\n  plan only; nothing was written. Rerun with --apply.\n'
    (( refused == 0 )) || die "restore incomplete: see the lines marked ✗"
}
