#!/bin/bash
# Machine-owned OmaBackup configuration. This is deliberately a CLI concern:
# QuickShell may launch it, but it never edits these files itself.

CONFIG_ENV_FILE="${OMABACKUP_ENV:-$HOME/.config/omabackup/env}"

_config_atomic_write() {
    local path="$1" content="$2" dir tmp
    dir="$(dirname "$path")"
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "$dir/.omabackup-config.XXXXXX")" || return 1
    if ! printf '%s\n' "$content" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$path"
}

_config_env_set() {
    local key="$1" value="$2" file="$CONFIG_ENV_FILE" dir tmp line found=0
    [[ "$key" == OMABACKUP_REPO || "$key" == OMABACKUP_DESTINATIONS ]] || return 1
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    dir="$(dirname "$file")"
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "$dir/.omabackup-config.XXXXXX")" || return 1
    if [[ -e "$file" && ! -r "$file" ]]; then
        rm -f -- "$tmp"
        return 1
    fi
    if [[ -r "$file" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*${key}= ]]; then
            if (( found == 0 )); then
                printf '%s=%s\n' "$key" "$value" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
            fi
            found=1
        else
            printf '%s\n' "$line" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
        fi
      done <"$file" || { rm -f -- "$tmp"; return 1; }
    fi
    if (( ! found )); then
        printf '%s=%s\n' "$key" "$value" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
    fi
    chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$file"
}

_config_absolute_path() {
    local path="$1"
    path="$(_expand "$path")"
    [[ "$path" == /* \
       && "$path" != *$'\n'* && "$path" != *$'\r'* \
       && "$path" != *"\\"* && "$path" != *"'"* && "$path" != *'"'* ]] || return 1
    printf '%s' "$path"
}

_config_validate_schedule() {
    local value="$1" calendar
    calendar="$(schedule_cron_to_calendar "$value")" || return 1
    systemd-analyze calendar "$calendar" >/dev/null 2>&1
}

_config_validate_calendar() {
    local value="$1"
    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    systemd-analyze calendar "$value" >/dev/null 2>&1
}

_config_validate_destinations() {
    local keep_values keep
    [[ ! -f "$DESTINATIONS_FILE" ]] && return 0
    jq -e --argjson fields "$KNOWN_DEST_FIELDS" --argjson types "$KNOWN_DEST_TYPES" '
      . as $doc
      | ($doc | type == "object")
        and ($doc.schemaVersion == 1)
        and ((($doc | keys) - ["schemaVersion", "destinations"]) | length == 0)
        and (($doc.destinations | type) == "array")
        and all($doc.destinations[];
        (type == "object")
        and (all(keys[]; . as $key | ($fields | index($key) != null)))
        and ((.type // "") as $type | $types | index($type) != null)
        and ((.id // "") | type == "string" and test("^[A-Za-z0-9_-]+$"))
        and ((.id // "") != "github")
        and ((.path // "") | type == "string" and length > 0 and startswith("/"))
        and ((.keep // 0) | type == "number" and floor == . and . >= 1)
        and ((.enabled // true) | type == "boolean")
      )
        and (([$doc.destinations[].id] | unique | length) == ($doc.destinations | length))
    ' "$DESTINATIONS_FILE" >/dev/null 2>&1 || return 1
    keep_values="$(jq -r '.destinations[]? | (.keep // 0)' "$DESTINATIONS_FILE" 2>/dev/null)" || return 1
    if [[ -n "$keep_values" ]]; then
        while IFS= read -r keep; do
            _dest_keep_valid "$keep" || return 1
        done <<<"$keep_values"
    fi
}

_config_destinations_doc() {
    if [[ -f "$DESTINATIONS_FILE" ]]; then
        cat -- "$DESTINATIONS_FILE"
    else
        printf '{"schemaVersion":1,"destinations":[]}\n'
    fi
}

_config_write_destinations() {
    local doc="$1"
    jq -e '.schemaVersion == 1 and (.destinations | type == "array")' <<<"$doc" >/dev/null \
        || return 1
    _config_atomic_write "$DESTINATIONS_FILE" "$doc"
}

_config_timer_set() {
    local unit="$1" schedule="$2" file="$UNIT_DIR/$1" dir tmp line found=0
    [[ -f "$file" ]] || return 1
    dir="$(dirname "$file")"
    tmp="$(mktemp "$dir/.omabackup-config.XXXXXX")" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == OnCalendar=* ]]; then
            if (( found == 0 )); then
                printf 'OnCalendar=%s\n' "$schedule" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
            fi
            found=1
        else
            printf '%s\n' "$line" >>"$tmp" || { rm -f -- "$tmp"; return 1; }
        fi
    done <"$file"
    if (( ! found )); then
        rm -f -- "$tmp"
        return 1
    fi
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f -- "$tmp" "$file"
}

_config_file_schedule() {
    local file="$1" line schedule="" found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^OnCalendar=(.*)$ ]]; then
            (( found == 0 )) && schedule="${BASH_REMATCH[1]}"
            found=1
        fi
    done <"$file" || return 1
    (( found == 1 )) || return 1
    _config_validate_calendar "$schedule" || return 1
    printf '%s' "$schedule"
}

_config_reload_timers() {
    "$SYSTEMCTL" --user daemon-reload || return 1
    for unit in "${TIMER_UNITS[@]}"; do
        "$SYSTEMCTL" --user try-restart "$unit" >/dev/null 2>&1 || return 1
    done
}

_config_require_repo() {
    local repo
    repo="$(_config_absolute_path "$1")" || die "repo must be an absolute path"
    [[ -d "$repo/.git" ]] || die "repo must point at an existing git repository: $repo"
    printf '%s' "$repo"
}

# Whether `path` -- already canonicalized by the caller via `realpath`, so a
# symlink resolves to the same real directory for every check AND for the
# `git init` call that follows a yes answer -- is safe to offer the
# config-TUI's git-init bootstrap for: it exists, is not already inside any
# git repository, and is genuinely empty.
#
# Two things `find`'s output alone cannot tell apart, both found by review on
# this exact guard: empty output because the directory truly has nothing in
# it, and empty output because `find` could not even read the directory (no
# permission -- reproduced live: `find /root -mindepth 1 -maxdepth 1 -print
# -quit 2>/dev/null` prints nothing and exits 1). Checking `$?` as well as the
# output, rather than only `[[ -z "$(...)" ]]`, is what tells those apart;
# fail-closed (not eligible) whenever `find` did not cleanly confirm empty.
#
# Called twice by the caller on purpose: once before the prompt, and again
# immediately before `git init`. The prompt blocks on user input for as long
# as it takes to answer, which is an arbitrary window for the target to stop
# being empty (or to stop existing, or to become a repo) -- re-checking right
# before the one action that actually writes anything is what closes that,
# not a single check made stale by the time the "y" comes back.
_config_repo_init_eligible() {
    local path="$1" listing rc
    [[ -n "$path" && -d "$path" ]] || return 1
    git -C "$path" rev-parse --git-dir >/dev/null 2>&1 && return 1
    listing="$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"; rc=$?
    (( rc == 0 )) && [[ -z "$listing" ]]
}

# Whether `path` -- syntactically absolute, NOT required to exist -- is safe
# to offer the mkdir+git-init bootstrap for. `path` itself not existing is
# not enough on its own: found by review, a path whose leaf is absent but
# whose parent is already inside a git repository (a typo landing one level
# inside an existing backup repo, e.g. "~/dotfiles/subdir" when "~/dotfiles"
# is already `git init`-ed) would otherwise pass straight through, and
# `git init` nests a second repository inside the first -- the exact hazard
# `_config_repo_init_eligible` above exists to prevent for a path that
# already exists, reproduced here for one that does not yet.
#
# `git rev-parse --git-dir` only resolves from a real, existing directory, so
# this walks up from `path` to the nearest ancestor that actually exists
# (there is always at least one: `/`) and asks IT, not `path`. `rev-parse`
# itself then resolves upward through that ancestor's own parents the same
# way git always does, so an ancestor that is merely a subdirectory of an
# existing repo is still caught, not just a repo root exactly at that spot.
_config_repo_create_eligible() {
    local path="$1" existing_ancestor
    [[ -n "$path" && ! -e "$path" ]] || return 1
    existing_ancestor="$path"
    while [[ "$existing_ancestor" != / && ! -e "$existing_ancestor" ]]; do
        existing_ancestor="$(dirname -- "$existing_ancestor")"
    done
    [[ -d "$existing_ancestor" ]] || return 1
    git -C "$existing_ancestor" rev-parse --git-dir >/dev/null 2>&1 && return 1
    return 0
}

# A fresh `git init` -- whether into an existing empty directory or one just
# created by the offer below -- means an empty index. Any group path declared
# trackedOnly (paths[].trackedRepoPath in the manifest, e.g. "Personal
# scripts") uses `git ls-files` as its allow-list (collect_tracked_only,
# bin/omabackup), so it silently backs up nothing until something is
# committed there. That already surfaces as a `warn` finding on the next
# sync, but only there -- printed here too, right when the empty index is
# created, so it is not a surprise discovered days later.
#
# Naming only `.live` and saying "commit something there" was wrong:
# coverage does not depend on the live path at all -- collect_tracked_only
# (bin/omabackup) reads `git ls-files` under `.trackedRepoPath` INSIDE THE
# BACKUP REPO, which a normal live path (e.g. ~/.local/bin) usually is not
# even a git repository of its own. The actionable fact is the
# trackedRepoPath, so both are named. `select(.enabled != false)` matches
# every other per-group query in this codebase (bin/omabackup:285,290,309,
# 311,317) -- a disabled group's declared paths intentionally back up
# nothing, and a false warning about them would be its own bug. `@tsv`
# escapes any embedded tab/newline in the manifest value itself;
# `tui_sanitize_field` below is the belt matching this codebase's actual
# display contract for inline metadata.
_config_repo_tracked_only_note() {
    local tracked list live sub
    tracked="$(jq -r \
        '.groups[]? | select(.enabled != false) | (.paths // [])[]
         | select(type=="object" and has("trackedRepoPath"))
         | [.live, .trackedRepoPath] | @tsv' \
        "$GROUPS_FILE" 2>/dev/null)" || return 0
    [[ -n "$tracked" ]] || return 0
    list=""
    while IFS=$'\t' read -r live sub; do
        [[ -n "$live" ]] || continue
        list+="$(tui_sanitize_field "$live") (tracked under $(tui_sanitize_field "$sub")), "
    done <<<"$tracked"
    list="${list%, }"
    # Explicit, not left to the printf's own exit status: a caller
    # concatenating this into a prefix string never checks $?, but leaving
    # it unset means the function returns 1 whenever there is nothing to
    # say, which would become a real bug the day this script grows `set -e`.
    [[ -n "$list" ]] && printf 'Note: %s will back up nothing until this repository tracks files there. ' "$list"
    return 0
}

_config_show_json() {
    local destinations='{"schemaVersion":1,"destinations":[]}' sync_calendar push_calendar sync_cron push_cron sync_label push_label github_url repo_status
    local log_retention_days log_config_exists log_config_valid
    [[ -f "$DESTINATIONS_FILE" ]] && destinations="$(cat -- "$DESTINATIONS_FILE")"
    log_retention_days="$(_log_retention_days)"
    log_config_exists=false; log_config_valid=true
    if [[ -f "$LOG_CONFIG_FILE" ]]; then
        log_config_exists=true
        _log_retention_valid_file || log_config_valid=false
    fi
    sync_calendar="$(timer_schedule omabackup-sync.timer || true)"
    push_calendar="$(timer_schedule omabackup-push.timer || true)"
    sync_cron="$(schedule_calendar_to_cron "$sync_calendar" || true)"
    push_cron="$(schedule_calendar_to_cron "$push_calendar" || true)"
    sync_label="$(schedule_cron_description "$sync_cron" 2>/dev/null || true)"
    push_label="$(schedule_cron_description "$push_cron" 2>/dev/null || true)"
    github_url="$(dest_github_push_url || true)"
    if [[ -z "${OMABACKUP_REPO:-}" ]]; then
        repo_status="not-configured"
    elif [[ -d "$OMABACKUP_REPO/.git" ]]; then
        repo_status="ready"
    else
        repo_status="not-found"
    fi
    jq -n --arg repo "${OMABACKUP_REPO:-}" --arg env "$CONFIG_ENV_FILE" \
        --arg repoStatus "$repo_status" \
        --arg destfile "$DESTINATIONS_FILE" \
        --argjson destinations "$destinations" \
        --arg sync "$sync_cron" --arg push "$push_cron" \
        --arg syncLabel "$sync_label" --arg pushLabel "$push_label" \
        --arg syncCalendar "$sync_calendar" --arg pushCalendar "$push_calendar" \
        --arg githubUrl "$github_url" \
        --argjson githubActive "$( [[ -n "$github_url" ]] && echo true || echo false )" \
        --argjson enabled "$(scheduler_active && echo true || echo false)" \
        --argjson logRetentionDays "$log_retention_days" \
        --argjson logConfigExists "$log_config_exists" \
        --argjson logConfigValid "$log_config_valid" \
        '{schemaVersion:1, repo:$repo, repoStatus:$repoStatus, envFile:$env, destinationsFile:$destfile,
          destinations:$destinations.destinations,
          github:{remote:"origin", configured:$githubActive, active:$githubActive,
                  url:(if $githubUrl == "" then null else $githubUrl end)},
          schedules:{sync:(if $sync == "" then null else $sync end),
                     syncLabel:(if $syncLabel == "" then null else $syncLabel end),
                     push:(if $push == "" then null else $push end),
                     pushLabel:(if $pushLabel == "" then null else $pushLabel end),
                     calendar:{sync:(if $syncCalendar == "" then null else $syncCalendar end),
                               push:(if $pushCalendar == "" then null else $pushCalendar end)}},
          enabled:$enabled,
          log:{retentionDays:$logRetentionDays, configExists:$logConfigExists, configValid:$logConfigValid}}'
}

_config_validate_json() {
    local errors=() repo sync push
    repo="${OMABACKUP_REPO:-}"
    [[ -n "$repo" && -d "$repo/.git" ]] || errors+=("repo must point at an existing git repository")
    _config_validate_destinations || errors+=("destinations.json is invalid or unsupported")
    [[ -f "$UNIT_DIR/omabackup-sync.timer" ]] || errors+=("sync timer is not installed")
    [[ -f "$UNIT_DIR/omabackup-push.timer" ]] || errors+=("push timer is not installed")
    sync="$(_config_file_schedule "$UNIT_DIR/omabackup-sync.timer" || true)"
    push="$(_config_file_schedule "$UNIT_DIR/omabackup-push.timer" || true)"
    [[ -n "$sync" ]] || errors+=("sync timer has no readable OnCalendar")
    [[ -n "$push" ]] || errors+=("push timer has no readable OnCalendar")
    # Found by review (round omabackup-22): `config validate` covered
    # repo/destinations/timers but nothing about log.json, so a hand-edited
    # file could sit invalid (or over LOG_RETENTION_MAX_DAYS) while this
    # command reported the configuration valid -- even though `config show`
    # separately flags it. Only checked when the file actually exists:
    # a missing log.json is not an error, it just means the default applies.
    [[ -f "$LOG_CONFIG_FILE" ]] && ! _log_retention_valid_file \
        && errors+=("log.json exists but is invalid")
    if (( JSON )); then
        printf '%s\n' "${errors[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0)) as $errors | {schemaVersion:1,valid:($errors|length==0),errors:$errors}'
    else
        if (( ${#errors[@]} == 0 )); then
            printf 'configuration is valid\n'
        else
            printf 'configuration is invalid:\n' >&2
            printf '  - %s\n' "${errors[@]}" >&2
            return 1
        fi
    fi
    (( ${#errors[@]} == 0 ))
}

_config_tui_destinations() {
    local doc github_url count entries entry number path keep
    doc="$(_config_destinations_doc)" || return 1
    if github_url="$(dest_github_push_url)"; then
        printf '  GitHub (implicit)  origin -> %s  (first push target; Git may use more; in the default push set; named destinations can skip it)\n' \
            "$(tui_sanitize_field "$github_url")"
    else
        printf '  GitHub  not configured  (add an origin remote to include it in omabackup push)\n'
    fi
    count="$(jq -r '.destinations | length' <<<"$doc")" || return 1
    if (( count == 0 )); then
        printf '  No backup folders configured.\n'
        return 0
    fi
    entries="$(jq -c '.destinations | to_entries[]' <<<"$doc")" || return 1
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        number="$(jq -r '.key + 1' <<<"$entry")" || return 1
        path="$(jq -r '.value.path' <<<"$entry")" || return 1
        keep="$(jq -r '.value.keep' <<<"$entry")" || return 1
        printf '  %s) %s  (keeps %s newest backups)\n' "$number" \
            "$(tui_sanitize_field "$path")" "$(tui_sanitize_field "$keep")"
    done <<<"$entries"
}

_config_tui_destination_id() {
    local choice="$1" doc index count normalized
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    normalized="$choice"
    while [[ ${#normalized} -gt 1 && ${normalized:0:1} == 0 ]]; do
        normalized="${normalized:1}"
    done
    [[ "$normalized" != "0" ]] || return 1
    # The largest useful destination list is far below this bound. More
    # importantly, it keeps an untrusted decimal string out of Bash
    # arithmetic before it can wrap into a valid index.
    (( ${#normalized} <= 9 )) || return 1
    doc="$(_config_destinations_doc)" || return 1
    count="$(jq -r '.destinations | length' <<<"$doc")" || return 1
    (( 10#$normalized >= 1 && 10#$normalized <= count )) || return 1
    index=$((10#$normalized - 1))
    jq -r --argjson index "$index" '.destinations[$index].id // empty' <<<"$doc"
}

_config_tui_new_destination_id() {
    local path="$1" doc id candidate n
    doc="$(_config_destinations_doc)" || return 1
    id="$(basename -- "$path")"
    id="$(printf '%s' "$id" | tr -cs '[:alnum:]_-' '-')"
    id="${id#-}"; id="${id%-}"
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || id="disk"
    candidate="$id"; n=2
    while [[ "$candidate" == github ]] || jq -e --arg id "$candidate" 'any(.destinations[]; .id == $id)' <<<"$doc" >/dev/null; do
        candidate="${id}-${n}"
        n=$((n + 1))
    done
    printf '%s' "$candidate"
}

_config_tui_time_fields() {
    local value="$1" parsed
    parsed="$(_schedule_time "$value")" || return 1
    printf '%s %s' "${parsed#*:}" "${parsed%:*}"
}

_config_tui_schedule() {
    local kind="$1" choice value minutes time day fields current current_description title
    local interval_default=15 minute_default=0 time_default=02:00 day_default=0
    local current_minute current_hour current_dom current_month current_dow
    CONFIG_TUI_SCHEDULE=""
    current="$(timer_schedule_cron "omabackup-$kind.timer" 2>/dev/null || true)"
    current_description="$(schedule_cron_description "$current" 2>/dev/null || true)"
    [[ -n "$current_description" ]] || current_description="Not configured"
    [[ "$kind" == sync ]] && title="Backup" || title="Send"
    read -r current_minute current_hour current_dom current_month current_dow <<<"$current"
    if [[ "$current_minute" == "*" && "$current_hour" == "*" \
          && "$current_dom" == "*" && "$current_month" == "*" \
          && "$current_dow" == "*" ]]; then
        interval_default=1
    elif [[ "$current_minute" =~ ^\*/([0-9]+)$ \
          && "$current_hour" == "*" && "$current_dom" == "*" \
          && "$current_month" == "*" && "$current_dow" == "*" ]]; then
        value="${BASH_REMATCH[1]}"
        if _schedule_number "$value" 1 59; then
            interval_default="$((10#$value))"
        fi
    elif [[ "$current_hour" == "*" && "$current_dom" == "*" \
            && "$current_month" == "*" && "$current_dow" == "*" ]] \
         && _schedule_number "$current_minute" 0 59; then
        minute_default="$((10#$current_minute))"
    elif [[ "$current_dom" == "*" && "$current_month" == "*" \
            && "$current_dow" == "*" ]] \
         && _schedule_number "$current_hour" 0 23 \
         && _schedule_number "$current_minute" 0 59; then
        time_default="$(printf '%02d:%02d' "$((10#$current_hour))" "$((10#$current_minute))")"
    elif [[ "$current_dom" == "*" && "$current_month" == "*" \
            && "$current_dow" =~ ^[0-7]$ ]] \
         && _schedule_number "$current_hour" 0 23 \
         && _schedule_number "$current_minute" 0 59; then
        time_default="$(printf '%02d:%02d' "$((10#$current_hour))" "$((10#$current_minute))")"
        day_default="$((10#$current_dow % 7))"
    fi
    printf '\n%s schedule (current: %s)\n' "$title" "$current_description"
    printf 'Choose how often it should run:\n'
    printf '  1) Every N minutes (for example, every 15 minutes)\n'
    printf '  2) Every hour\n'
    printf '  3) Every day at a time\n'
    printf '  4) Every week on a day and time\n'
    printf '  5) Advanced: enter a five-field crontab schedule\n'
    while true; do
        printf 'Choose [1-5/q]: '
        tui_read_line choice || return 1
        case "$choice" in
            q|Q|$'\033') return 2 ;;
            1|2|3|4|5) break ;;
            *) printf 'Please choose 1-5 or q. Try again.\n' ;;
        esac
    done
    case "$choice" in
        1)
            while true; do
                printf 'Minutes between runs [%s] (q to cancel): ' "$interval_default"
                tui_read_line minutes || return 1
                [[ "$minutes" == q || "$minutes" == Q || "$minutes" == $'\033' ]] && return 2
                minutes="${minutes:-$interval_default}"
                if _schedule_number "$minutes" 1 59; then
                    CONFIG_TUI_SCHEDULE="*/$((10#$minutes)) * * * *"
                    break
                fi
                printf 'Minutes must be a whole number from 1 to 59. Try again.\n'
            done
            ;;
        2)
            while true; do
                printf 'Minute of the hour [%s] (q to cancel): ' "$minute_default"
                tui_read_line minutes || return 1
                [[ "$minutes" == q || "$minutes" == Q || "$minutes" == $'\033' ]] && return 2
                minutes="${minutes:-$minute_default}"
                if _schedule_number "$minutes" 0 59; then
                    CONFIG_TUI_SCHEDULE="$((10#$minutes)) * * * *"
                    break
                fi
                printf 'Minute must be a whole number from 0 to 59. Try again.\n'
            done
            ;;
        3)
            while true; do
                printf 'Time (HH:MM) [%s] (q to cancel): ' "$time_default"
                tui_read_line time || return 1
                [[ "$time" == q || "$time" == Q || "$time" == $'\033' ]] && return 2
                time="${time:-$time_default}"
                if fields="$(_config_tui_time_fields "$time")"; then
                    CONFIG_TUI_SCHEDULE="${fields%% *} ${fields##* } * * *"
                    break
                fi
                printf 'Use a valid time such as 02:00. Try again.\n'
            done
            ;;
        4)
            while true; do
                printf 'Day (0 Sunday, 1 Monday, ... 6 Saturday) [%s] (q to cancel): ' "$day_default"
                tui_read_line day || return 1
                [[ "$day" == q || "$day" == Q || "$day" == $'\033' ]] && return 2
                day="${day:-$day_default}"
                if _schedule_number "$day" 0 7; then
                    break
                fi
                printf 'Day must be from 0 to 7. Try again.\n'
            done
            while true; do
                printf 'Time (HH:MM) [%s] (q to cancel): ' "$time_default"
                tui_read_line time || return 1
                [[ "$time" == q || "$time" == Q || "$time" == $'\033' ]] && return 2
                time="${time:-$time_default}"
                if fields="$(_config_tui_time_fields "$time")"; then
                    CONFIG_TUI_SCHEDULE="${fields%% *} ${fields##* } * * $((10#$day))"
                    break
                fi
                printf 'Use a valid time such as 02:00. Try again.\n'
            done
            ;;
        5)
            while true; do
                printf 'Advanced crontab (minute hour day month weekday), e.g. */15 * * * * (q to cancel): '
                tui_read_line CONFIG_TUI_SCHEDULE || return 1
                [[ "$CONFIG_TUI_SCHEDULE" == q || "$CONFIG_TUI_SCHEDULE" == Q || "$CONFIG_TUI_SCHEDULE" == $'\033' ]] && {
                    CONFIG_TUI_SCHEDULE=""
                    return 2
                }
                if _config_validate_schedule "$CONFIG_TUI_SCHEDULE"; then
                    break
                fi
                printf 'That schedule is not supported. Try a simple five-field crontab form.\n'
            done
            ;;
        *) printf 'Please choose 1-5 or q.\n'; return 1 ;;
    esac
    _config_validate_schedule "$CONFIG_TUI_SCHEDULE" || {
        printf 'That schedule is not supported. Use a simple five-field crontab form.\n'
        CONFIG_TUI_SCHEDULE=""
        return 1
    }
}

# A schedule/enabled change that fails only because the systemd timers were
# never installed is not a dead end -- `omabackup install` only needs
# OMABACKUP_REPO, which is already on disk by the time a user reaches these
# menu options (option 1 writes it via _config_env_set, and bin/omabackup
# sources that same file at startup). Offering to run it here, instead of
# just surfacing "-- run: omabackup install" and leaving the user to find a
# shell, closes the same class of gap the git-init offer above closes for a
# fresh repository. Return codes: 0 installed (caller should retry the
# original config-set), 1 declined/cancelled, 2 install ran but failed, 3
# the terminal went away (caller must exit the whole TUI, not just this menu
# choice).
#
# Sets CONFIG_TUI_INSTALL_OUTPUT rather than printing `install`'s own output
# directly (as an earlier version of this did): `cmd_config_tui`'s loop opens
# every iteration with `tui_header`, which clears the whole screen before the
# next prompt is drawn, so anything printed here and not folded into the
# caller's own persisted `notice` is gone before a real user could read it --
# found by review. The caller decides whether and how to surface it.
_config_tui_offer_install() {
    local cli="$1" answer install_rc
    CONFIG_TUI_INSTALL_OUTPUT=""
    printf 'Automatic backup timers are not installed yet. Install them now? [y/N] (q to cancel): '
    tui_read_line answer || return 3
    case "$answer" in
        y|Y|yes|Yes|YES) ;;
        *) return 1 ;;
    esac
    CONFIG_TUI_INSTALL_OUTPUT="$("$cli" install 2>&1)"; install_rc=$?
    (( install_rc == 0 )) && return 0
    return 2
}

# `gh auth token` reads the local credential store; it makes no network call,
# matching this file's existing posture of never probing the network just to
# decide whether to show a prompt (the destination/repo/git-init checks above
# are all judged from local state alone). `gh auth status` was the other
# candidate but does more validation, including a round trip -- not needed
# just to gate an offer that gh itself will re-validate for real if accepted.
_config_gh_available() {
    local gh="$1"
    command -v "$gh" >/dev/null 2>&1 || return 1
    "$gh" auth token >/dev/null 2>&1
}

# Offered right after a successful `git init` and after that repository has
# already been persisted as OMABACKUP_REPO (see the caller): a fresh local
# repository is exactly the moment "should this also live on GitHub" is
# relevant, and gh already has everything it needs (an authenticated
# session, a local repo to point --source at). No prompt at all when gh is
# missing or not authenticated -- unlike the install offer, there is no dead
# end here to rescue the user from; this is a convenience on top of an
# already-complete local repository, so silence is the right default when it
# does not apply. `--private` with no visibility prompt: a dotfiles backup
# repository defaulting private is the safe call, and it can be reopened from
# GitHub itself later if the user wants otherwise. No `--push`: the repo is
# empty immediately after `git init` anyway, and the next sync/push cycle is
# what actually sends content -- this only has to wire the remote up.
#
# The repository NAME is passed explicitly, as gh's own `--help` documents:
# "To create a remote repository non-interactively, supply the repository
# name and one of --public/--private/--internal" -- found by review that the
# prior version omitted it, relying only on `--source` defaulting the name.
# Confirmed (on the failure path only, to avoid creating a real repository
# just to probe this) that gh validates `--source` before anything else and
# exits non-interactively either way, but there is no reason to run a form
# gh's own documentation does not call non-interactive when the documented
# one is just as short -- especially with a real TUI prompt sharing the same
# stdin one call away.
#
# The name goes LAST, after every flag, behind its own `--`: an earlier
# version put it first and unterminated -- found by review that a directory
# whose basename starts with `-` (e.g. one literally named `--help`) is then
# read by gh as an option instead of the positional name, so `gh repo create
# --help --private --source=... --remote=origin` just prints gh's own help
# and exits 0 without creating or validating anything, and this helper would
# have reported that as success. `--` stops option parsing the same way it
# does for every other command in this file (`git init -q -- "$path"`, `rm
# -f -- "$tmp"`), so nothing after it can be misread as a flag regardless of
# what the directory happens to be named.
#
# Sets CONFIG_TUI_GITHUB_OUTPUT rather than printing `gh`'s own output
# directly, for the same reason _config_tui_offer_install does: the caller's
# next `tui_header` clears the screen before a real user could read it.
# Return codes mirror _config_tui_offer_install: 0 created, 1 declined or gh
# is not available/authenticated (both silent-fallthrough cases for the
# caller), 2 gh ran but failed, 3 the terminal went away.
_config_tui_offer_github() {
    local gh="$1" path="$2" answer create_rc
    CONFIG_TUI_GITHUB_OUTPUT=""
    _config_gh_available "$gh" || return 1
    printf 'Also create a private GitHub repository for it and set it as origin? [y/N] (q to skip): '
    tui_read_line answer || return 3
    case "$answer" in
        y|Y|yes|Yes|YES) ;;
        *) return 1 ;;
    esac
    CONFIG_TUI_GITHUB_OUTPUT="$("$gh" repo create --private --source="$path" --remote=origin -- "$(basename -- "$path")" 2>&1)"; create_rc=$?
    (( create_rc == 0 )) && return 0
    return 2
}

cmd_config_tui() {
    local cli="${OMABACKUP_ROOT}/bin/omabackup" choice value id path keep output rc dest_choice doc notice="" schedule_rc \
        repo_init_abs repo_init_canon repo_init_prefix repo_init_answer \
        install_offer_rc github_offer_rc install_note
    [[ -t 0 && -t 1 ]] || die "interactive config needs a terminal; use config show --json or config set"
    while true; do
        tui_header configuration
        output="$($cli config show 2>&1)" || true
        printf '%s\n' "$output"
        if [[ -n "$notice" ]]; then
            printf '\n%s\n' "$(tui_sanitize "$notice")"
            notice=""
        fi
        printf '\nActions\n'
        printf '  1) Backup repository\n'
        printf '  2) Backup folders — add a folder\n'
        printf '  3) Backup folders — remove a folder\n'
        printf '  4) Backup schedule\n'
        printf '  5) Send schedule\n'
        printf '  6) Automatic backups\n'
        printf '  7) Log retention\n'
        printf '  q) Cancel\n\n'
        printf 'Choose an option [1-7/q]: '
        tui_read_line choice || return 0
        rc=0
        case "$choice" in
            q|Q|$'\033') printf '\nConfiguration cancelled.\n'; return 0 ;;
            ''|*[!0-9]*)
                notice="Please choose 1-7 or q."
                continue
                ;;
            1)
                printf 'Backup repository path (absolute; q to cancel): '
                tui_read_line value || return 0
                if [[ "$value" == q || "$value" == Q || "$value" == $'\033' ]]; then
                    notice="Backup repository change cancelled."
                    continue
                fi
                # git stays required (sync/push/restore all depend on it --
                # see docs/PLAN.md's design-review note), but a folder that
                # merely has not been `git init`-ed yet -- or does not exist
                # yet at all -- is the common case, not an error: offer to
                # create/init it right here instead of just dying. The two
                # cases get separate prompts below (mkdir+init vs. init-only)
                # since a directory that does not exist yet is missing the
                # "already a repo" / "$HOME-sized" hazards the
                # existing-directory offer has to guard against -- but NOT the
                # nested-repo one: a path whose leaf is absent but whose
                # parent already IS a repository (a typo landing one level
                # inside an existing backup repo) is caught by
                # `_config_repo_create_eligible`, the mkdir-branch's own
                # analogue of the check below, walking up to the nearest
                # existing ancestor instead of checking the target directly.
                #
                # The guard is `git rev-parse --git-dir`, not `-d "$path/.git"`.
                # The latter is wrong in both directions, confirmed by review:
                # a linked worktree or a bare repo has no `.git` directory (it's
                # a file, or absent entirely), so the offer would fire and
                # `git init` would just reinitialize the existing repo and
                # print a false "Initialized..." next to config-set's real
                # "must point at an existing git repository" failure -- two
                # contradictory sentences in one notice. And a path that is
                # merely a SUBdirectory of an existing repo (a typo landing
                # inside `~/Devs/omarchy-personal/configs`, or even `$HOME`)
                # has no `.git` of its own either, so the old guard would offer
                # to init it, `git init` would happily nest a second repo
                # inside the first, and config-set-repo would then *accept*
                # that nested repo as the configured OMABACKUP_REPO -- no
                # error at all, just a silently wrong, origin-less repo.
                # `rev-parse --git-dir` resolves upward like git itself does,
                # so it correctly recognizes both cases as "already a repo"
                # and the offer never fires for either.
                # `rev-parse --git-dir` only checks ancestors, never
                # descendants: it correctly recognizes a subdirectory of an
                # existing repo (above), but has nothing to say about a
                # directory that merely HAPPENS to contain a lot of unrelated
                # content and isn't inside any repo at all -- $HOME itself,
                # for instance. Reproduced: `git -C "$HOME" rev-parse
                # --git-dir` fails even on a machine with git repos all over
                # `~/Devs`, so the guard above would still offer the prompt
                # there. Accepting it would `git init "$HOME"`, config-set
                # would then accept `$HOME` as OMABACKUP_REPO, and the next
                # sync would start publishing backup content directly into
                # it -- a typo or a misclick with no repo-scoped undo. The
                # offer's whole reason to exist is a fresh, empty folder in
                # the first place, so requiring empty closes this without
                # guessing at a blocklist of dangerous paths ($HOME, /, ...)
                # that could never be complete.
                # `realpath -e` up front, once: a symlinked target must be
                # checked and initialized at the SAME real directory, not
                # checked through the link and written through it separately.
                # `find`'s default `-P` policy does not follow a symlink given
                # as its own starting argument (confirmed live: `find /bin
                # -mindepth 1 -maxdepth 1 -print -quit` prints nothing even
                # though /bin is a symlink to the non-empty /usr/bin), while
                # `-d`, `git -C`, and `git init` all do -- so a writable
                # symlink to a non-empty, non-git tree used to pass every
                # check below as though it were an empty real directory.
                repo_init_abs="$(_config_absolute_path "$value" 2>/dev/null)" || repo_init_abs=""
                repo_init_canon=""
                [[ -n "$repo_init_abs" && -e "$repo_init_abs" ]] \
                    && repo_init_canon="$(realpath -e "$repo_init_abs" 2>/dev/null)"
                repo_init_prefix=""
                if [[ -n "$repo_init_canon" ]] && _config_repo_init_eligible "$repo_init_canon"; then
                    printf '%s is not a git repository yet. Initialize one there now? [y/N] (q to cancel): ' \
                        "$(tui_sanitize_field "$repo_init_canon")"
                    tui_read_line repo_init_answer || return 0
                    case "$repo_init_answer" in
                        q|Q|$'\033') notice="Backup repository change cancelled."; continue ;;
                        y|Y|yes|Yes|YES)
                            # Re-checked, not reused: the prompt above just
                            # blocked on user input for an arbitrary amount of
                            # time, which is a window for the target to stop
                            # being empty, stop existing, or become a repo.
                            if ! _config_repo_init_eligible "$repo_init_canon"; then
                                notice="$(tui_sanitize_field "$repo_init_canon") changed while waiting for an answer -- not initializing it."
                                continue
                            fi
                            if ! git init -q -- "$repo_init_canon" >/dev/null 2>&1; then
                                notice="Could not initialize a git repository in $(tui_sanitize_field "$repo_init_canon")."
                                continue
                            fi
                            repo_init_prefix="Initialized an empty git repository in $(tui_sanitize_field "$repo_init_canon"). "
                            repo_init_prefix+="$(_config_repo_tracked_only_note)"
                            ;;
                        *) ;;
                    esac
                elif _config_repo_create_eligible "$repo_init_abs"; then
                    # The only new risk beyond _config_repo_create_eligible's
                    # own guards is `mkdir -p` itself failing (permissions, a
                    # non-directory blocking an ancestor component), handled
                    # the same way the `git init` failure already is: report
                    # it and leave the repo setting unchanged.
                    printf '%s does not exist yet. Create it and initialize a git repository there? [y/N] (q to cancel): ' \
                        "$(tui_sanitize_field "$repo_init_abs")"
                    tui_read_line repo_init_answer || return 0
                    case "$repo_init_answer" in
                        q|Q|$'\033') notice="Backup repository change cancelled."; continue ;;
                        y|Y|yes|Yes|YES)
                            # Re-checked for the same TOCTOU reason as above:
                            # the prompt just blocked on arbitrary answer
                            # time, during which the target could have
                            # appeared, or a repository could now cover one
                            # of its ancestors.
                            if ! _config_repo_create_eligible "$repo_init_abs"; then
                                notice="$(tui_sanitize_field "$repo_init_abs") changed while waiting for an answer -- not creating it."
                                continue
                            fi
                            if ! mkdir -p -- "$repo_init_abs" 2>/dev/null; then
                                notice="Could not create $(tui_sanitize_field "$repo_init_abs")."
                                continue
                            fi
                            repo_init_canon="$(realpath -e "$repo_init_abs" 2>/dev/null)" || repo_init_canon="$repo_init_abs"
                            # A last gate on the directory `mkdir -p` actually
                            # produced, right before `git init`: `mkdir -p`
                            # treats an already-existing directory as success
                            # rather than failure, so a race between the
                            # re-check above and this call could still hand
                            # back a path something else populated or
                            # replaced in the meantime. This is the same
                            # "empty, not already a repo" check the
                            # existing-directory branch relies on, applied to
                            # what was just created instead of assumed from
                            # having just created it.
                            if ! _config_repo_init_eligible "$repo_init_canon"; then
                                notice="$(tui_sanitize_field "$repo_init_canon") changed while it was being created -- not initializing it."
                                continue
                            fi
                            if ! git init -q -- "$repo_init_canon" >/dev/null 2>&1; then
                                notice="Created $(tui_sanitize_field "$repo_init_canon") but could not initialize a git repository there."
                                continue
                            fi
                            repo_init_prefix="Created $(tui_sanitize_field "$repo_init_canon") and initialized an empty git repository there. "
                            repo_init_prefix+="$(_config_repo_tracked_only_note)"
                            ;;
                        *) ;;
                    esac
                fi
                # Persisted right after a fresh `git init` succeeds, before
                # the optional GitHub offer below: that offer blocks on user
                # input and shells out to `gh`, and an interruption during
                # either must not leave a valid, just-initialized local
                # repository unregistered as OMABACKUP_REPO -- especially
                # since a second attempt at this same path would no longer
                # offer to init it (it is already a repo by then), silently
                # losing the recovery path along with the state.
                output="$($cli config set repo "$value" 2>&1)"; rc=$?
                if (( rc != 0 )); then
                    notice="${repo_init_prefix}${output:-Backup repository setting was not changed.}"
                    continue
                fi
                # repo_init_prefix is empty exactly when this iteration typed
                # an already-valid repository path and neither branch above
                # ran -- the GitHub offer only makes sense right after this
                # turn's own fresh `git init`, not every time someone points
                # the setting at a repo that already existed.
                if [[ -n "$repo_init_prefix" ]]; then
                    _config_tui_offer_github "$GH" "$repo_init_canon"
                    github_offer_rc=$?
                    (( github_offer_rc == 3 )) && return 0
                    if (( github_offer_rc == 0 )); then
                        repo_init_prefix+="Created a private GitHub repository and set it as origin. "
                    elif (( github_offer_rc == 2 )); then
                        repo_init_prefix+="Could not create a GitHub repository for it."
                        [[ -n "$CONFIG_TUI_GITHUB_OUTPUT" ]] \
                            && repo_init_prefix+=" $(tui_sanitize "$CONFIG_TUI_GITHUB_OUTPUT")"
                        repo_init_prefix+=" "
                    fi
                fi
                notice="${repo_init_prefix}Backup repository saved."
                ;;
            2)
                printf 'Backup folder path (absolute; q to cancel): '
                tui_read_line path || return 0
                if [[ "$path" == q || "$path" == Q || "$path" == $'\033' ]]; then
                    notice="Adding a backup folder cancelled."
                    continue
                elif [[ "$path" != /* ]]; then
                    notice="Use an absolute folder path."
                    continue
                fi
                id="$(_config_tui_new_destination_id "$path")" || {
                    notice="Could not generate a name for that backup folder."
                    continue
                }
                printf 'Keep the N newest backups [5] (q to cancel): '
                tui_read_line keep || return 0
                if [[ "$keep" == q || "$keep" == Q || "$keep" == $'\033' ]]; then
                    notice="Adding a backup folder cancelled."
                    continue
                fi
                keep="${keep:-5}"
                output="$($cli config destination add "$id" "$path" "$keep" 2>&1)"; rc=$?
                if (( rc == 0 )); then
                    notice="Backup folder added."
                else
                    notice="${output:-Backup folder was not added.}"
                fi
                ;;
            3)
                printf '\nBackup folders\n'
                _config_tui_destinations || true
                printf 'Remove which backup folder number? (q to cancel): '
                tui_read_line dest_choice || return 0
                if [[ "$dest_choice" == q || "$dest_choice" == Q || "$dest_choice" == $'\033' ]]; then
                    notice="Removing a backup folder cancelled."
                    continue
                fi
                id="$(_config_tui_destination_id "$dest_choice")"
                doc="$(_config_destinations_doc)"
                if [[ -z "$id" ]] || ! jq -e --arg id "$id" 'any(.destinations[]; .id == $id)' <<<"$doc" >/dev/null; then
                    notice="No backup folder matches that number."
                    continue
                elif [[ "$id" == github ]]; then
                    notice="GitHub is managed by the repository's origin remote."
                    continue
                else
                    output="$($cli config destination remove "$id" 2>&1)"; rc=$?
                    if (( rc == 0 )); then
                        notice="Backup folder removed."
                    else
                        notice="${output:-Backup folder was not removed.}"
                    fi
                fi
                ;;
            4|5)
                schedule_rc=0
                if [[ "$choice" == 4 ]]; then
                    _config_tui_schedule sync || schedule_rc=$?
                else
                    _config_tui_schedule push || schedule_rc=$?
                fi
                if (( schedule_rc == 2 )); then
                    notice="Schedule change cancelled."
                    continue
                elif (( schedule_rc != 0 )); then
                    notice="Schedule change was not saved. Please choose 1-5 or q."
                    continue
                else
                  value="$CONFIG_TUI_SCHEDULE"
                  if [[ "$choice" == 4 ]]; then
                    output="$($cli config set sync-schedule "$value" 2>&1)"; rc=$?
                  else
                    output="$($cli config set push-schedule "$value" 2>&1)"; rc=$?
                  fi
                  install_note=""
                  if (( rc != 0 )) && [[ "$output" == *"timers are not installed yet"* ]]; then
                    _config_tui_offer_install "$cli"
                    install_offer_rc=$?
                    (( install_offer_rc == 3 )) && return 0
                    if (( install_offer_rc == 0 )); then
                        [[ -n "$CONFIG_TUI_INSTALL_OUTPUT" ]] \
                            && install_note="$(tui_sanitize "$CONFIG_TUI_INSTALL_OUTPUT") "
                        if [[ "$choice" == 4 ]]; then
                            output="$($cli config set sync-schedule "$value" 2>&1)"; rc=$?
                        else
                            output="$($cli config set push-schedule "$value" 2>&1)"; rc=$?
                        fi
                    elif (( install_offer_rc == 2 )); then
                        # The stale "timers are not installed yet" text in
                        # $output would otherwise survive into the notice
                        # below unchanged, telling the user to run the exact
                        # command that was just tried and just failed --
                        # found by review. CONFIG_TUI_INSTALL_OUTPUT carries
                        # the real reason.
                        notice="Could not install the timers automatically."
                        [[ -n "$CONFIG_TUI_INSTALL_OUTPUT" ]] \
                            && notice+=" $(tui_sanitize "$CONFIG_TUI_INSTALL_OUTPUT")"
                        continue
                    fi
                  fi
                  if (( rc == 0 )); then
                    if [[ "$choice" == 4 ]]; then
                        notice="${install_note}Backup schedule saved."
                    else
                        notice="${install_note}Send schedule saved."
                    fi
                  else
                    notice="${output:-Schedule was not changed.}"
                  fi
                fi
                ;;
            6)
                printf 'Automatic backups [on/off] (q to cancel): '
                tui_read_line value || return 0
                if [[ "$value" == q || "$value" == Q || "$value" == $'\033' ]]; then
                    notice="Automatic backup setting cancelled."
                    continue
                fi
                output="$($cli config set enabled "$value" 2>&1)"; rc=$?
                install_note=""
                if (( rc != 0 )) && [[ "$output" == *"timers are not installed yet"* ]]; then
                    _config_tui_offer_install "$cli"
                    install_offer_rc=$?
                    (( install_offer_rc == 3 )) && return 0
                    if (( install_offer_rc == 0 )); then
                        [[ -n "$CONFIG_TUI_INSTALL_OUTPUT" ]] \
                            && install_note="$(tui_sanitize "$CONFIG_TUI_INSTALL_OUTPUT") "
                        output="$($cli config set enabled "$value" 2>&1)"; rc=$?
                    elif (( install_offer_rc == 2 )); then
                        notice="Could not install the timers automatically."
                        [[ -n "$CONFIG_TUI_INSTALL_OUTPUT" ]] \
                            && notice+=" $(tui_sanitize "$CONFIG_TUI_INSTALL_OUTPUT")"
                        continue
                    fi
                fi
                if (( rc == 0 )); then
                    case "$value" in
                        on|true|yes|1) notice="${install_note}Automatic backups enabled." ;;
                        *) notice="${install_note}Automatic backups disabled." ;;
                    esac
                else
                    notice="${output:-Automatic backup setting was not changed.}"
                fi
                ;;
            7)
                printf 'Keep logs for how many days? [%s] (q to cancel): ' "$(_log_retention_days)"
                tui_read_line value || return 0
                if [[ "$value" == q || "$value" == Q || "$value" == $'\033' ]]; then
                    notice="Log retention change cancelled."
                    continue
                fi
                value="${value:-$(_log_retention_days)}"
                output="$($cli config set log-retention-days "$value" 2>&1)"; rc=$?
                if (( rc == 0 )); then
                    notice="Log retention saved."
                else
                    notice="${output:-Log retention was not changed.}"
                fi
                ;;
            *)
                notice="Please choose 1-7 or q."
                continue
                ;;
        esac
        if (( rc == 0 )) && [[ "$choice" == 1 ]]; then
            OMABACKUP_REPO="$(_config_absolute_path "$value")"
            export OMABACKUP_REPO
        fi
    done
}

cmd_config() {
    local sub="${1:-}" key value id path keep doc dest_lock_fd shown
    local repo_status repo_value github_active github_value entries entry
    local schedule_label enabled_value log_retention_show log_config_valid_show
    shift || true
    case "$sub" in
        show|"")
            if [[ -z "$sub" && -t 0 && -t 1 && $JSON -eq 0 ]]; then
                cmd_config_tui
                return
            fi
            [[ "$sub" == show ]] && { (($# == 0)) || die "config show takes no positional arguments"; }
            shown="$(_config_show_json)" || die "could not read the current configuration"
            if (( JSON )); then
                printf '%s\n' "$shown"
            else
                repo_status="$(jq -r '.repoStatus' <<<"$shown")" || die "could not read the current configuration"
                repo_value="$(jq -r '.repo // empty' <<<"$shown")" || die "could not read the current configuration"
                case "$repo_status" in
                    not-configured) printf 'Backup repository: Not configured\n' ;;
                    not-found) printf 'Backup repository: %s (not found)\n' "$(tui_sanitize_field "$repo_value")" ;;
                    *) printf 'Backup repository: %s\n' "$(tui_sanitize_field "$repo_value")" ;;
                esac

                github_active="$(jq -r '.github.active == true' <<<"$shown")" || die "could not read the current configuration"
                github_value="$(jq -r '.github.url // empty' <<<"$shown")" || die "could not read the current configuration"
                if [[ "$github_active" == true ]]; then
                    printf 'GitHub: configured (origin -> %s; first push target; Git may use more; in the default push set)\n' \
                        "$(tui_sanitize_field "$github_value")"
                else
                    printf 'GitHub: not configured (add an origin remote to include it in omabackup push)\n'
                fi

                if [[ "$(jq -r '.destinations | length' <<<"$shown")" == 0 ]]; then
                    printf 'Backup folders: Not configured\n'
                else
                    printf 'Backup folders:\n'
                    entries="$(jq -c '.destinations[]' <<<"$shown")" || die "could not read the current configuration"
                    while IFS= read -r entry; do
                        [[ -n "$entry" ]] || continue
                        path="$(jq -r '.path' <<<"$entry")" || die "could not read the current configuration"
                        keep="$(jq -r '.keep' <<<"$entry")" || die "could not read the current configuration"
                        printf '  %s (keeps %s newest backups)\n' \
                            "$(tui_sanitize_field "$path")" "$(tui_sanitize_field "$keep")"
                    done <<<"$entries"
                fi

                schedule_label="$(jq -r '.schedules.syncLabel // empty' <<<"$shown")" || die "could not read the current configuration"
                printf 'Backup schedule: %s\n' "$(tui_sanitize_field "${schedule_label:-Not configured}")"
                schedule_label="$(jq -r '.schedules.pushLabel // empty' <<<"$shown")" || die "could not read the current configuration"
                printf 'Send schedule: %s\n' "$(tui_sanitize_field "${schedule_label:-Not configured}")"
                enabled_value="$(jq -r 'if .enabled then "on" else "off" end' <<<"$shown")" || die "could not read the current configuration"
                printf 'Automatic backups: %s\n' "$(tui_sanitize_field "$enabled_value")"
                log_retention_show="$(jq -r '.log.retentionDays' <<<"$shown")" || die "could not read the current configuration"
                log_config_valid_show="$(jq -r '.log.configValid' <<<"$shown")" || die "could not read the current configuration"
                if [[ "$log_config_valid_show" == false ]]; then
                    printf 'Log retention: %s days (log.json is invalid -- using the default)\n' \
                        "$(tui_sanitize_field "$log_retention_show")"
                else
                    printf 'Log retention: %s days\n' "$(tui_sanitize_field "$log_retention_show")"
                fi
            fi
            ;;
        validate)
            (($# == 0)) || die "config validate takes no positional arguments"
            _config_validate_json
            ;;
        set)
            (($# == 2)) || die "usage: omabackup config set <repo|sync-schedule|push-schedule|enabled|log-retention-days> VALUE"
            key="$1"; value="$2"
            case "$key" in
                repo)
                    value="$(_config_require_repo "$value")" || return 1
                    _config_env_set OMABACKUP_REPO "$value" || die "could not write $(_tilde "$CONFIG_ENV_FILE")"
                    ;;
                sync-schedule|push-schedule)
                    local calendar
                    calendar="$(schedule_cron_to_calendar "$value")" \
                        || die "invalid schedule: use a simple crontab such as '*/15 * * * *' or '0 2 * * *'"
                    _config_validate_schedule "$value" \
                        || die "unsupported schedule: use a simple crontab such as '*/15 * * * *' or '0 2 * * *'"
                    [[ -f "$UNIT_DIR/omabackup-sync.timer" && -f "$UNIT_DIR/omabackup-push.timer" ]] \
                        || die "timers are not installed yet -- run: omabackup install"
                    local timer_file="$UNIT_DIR/"
                    if [[ "$key" == sync-schedule ]]; then
                        timer_file+="omabackup-sync.timer"
                    else
                        timer_file+="omabackup-push.timer"
                    fi
                    local previous_timer previous_mode
                    previous_timer="$(cat -- "$timer_file")" || die "could not read the existing timer"
                    previous_mode="$(stat -c '%a' -- "$timer_file")" || die "could not read the existing timer mode"
                    _config_timer_set "$(basename "$timer_file")" "$calendar" \
                        || die "could not write the configured timer"
                    if ! _config_reload_timers; then
                        local rollback_tmp
                        rollback_tmp="$(mktemp "$(dirname "$timer_file")/.omabackup-config.XXXXXX")" \
                            || die "timer reload failed and rollback could not start"
                        if ! printf '%s\n' "$previous_timer" >"$rollback_tmp" \
                           || ! chmod "$previous_mode" "$rollback_tmp" \
                           || ! mv -f -- "$rollback_tmp" "$timer_file"; then
                            rm -f -- "$rollback_tmp"
                            die "timer reload failed and rollback could not restore the previous schedule"
                        fi
                        if _config_reload_timers; then
                            die "could not reload the configured timers; previous schedule restored"
                        fi
                        die "could not reload the configured timers; file restored but active timer state could not be confirmed"
                    fi
                    ;;
                enabled)
                    case "$value" in
                        on|true|yes|1) cmd_enable enable ;;
                        off|false|no|0) cmd_enable disable ;;
                        *) die "enabled expects on or off" ;;
                    esac
                    ;;
                log-retention-days)
                    _log_retention_valid "$value" \
                        || die "log retention must be a whole number of days between 1 and $LOG_RETENTION_MAX_DAYS"
                    _log_config_write "$(_log_retention_normalize "$value")" \
                        || die "could not write $(_tilde "$LOG_CONFIG_FILE")"
                    ;;
                *) die "unknown config key: $key" ;;
            esac
            ;;
        destination)
            mkdir -p "$(dirname "$DESTINATIONS_FILE")" || die "could not create the destinations directory"
            exec {dest_lock_fd}>"$DESTINATIONS_FILE.lock" || die "could not lock destinations"
            flock -x "$dest_lock_fd" || die "could not lock destinations"
            case "${1:-}" in
                add)
                    (($# == 4)) || die "usage: omabackup config destination add ID PATH KEEP"
                    id="$2"; path="$3"; keep="$4"
                    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || die "destination id is invalid"
                    [[ "$id" != github ]] || die "github is implicit; configure the repo instead"
                    path="$(_config_absolute_path "$path")" || die "destination path must be absolute"
                    keep="$(_dest_keep_normalize "$keep")" || die "destination keep must be a positive integer within the supported range"
                    _config_validate_destinations || die "existing destinations.json is invalid"
                    doc="$(_config_destinations_doc)"
                    doc="$(jq -c --arg id "$id" --arg path "$path" --argjson keep "$keep" '
                        .schemaVersion=1 | .destinations=(.destinations // [])
                        | if any(.destinations[]; .id == $id) then error("destination already exists")
                          else .destinations += [{id:$id,type:"dir",path:$path,keep:$keep,enabled:true,note:null}]
                          end' <<<"$doc")" || die "could not add destination"
                    _config_write_destinations "$doc" || die "could not write $(_tilde "$DESTINATIONS_FILE")"
                    ;;
                remove)
                    (($# == 2)) || die "usage: omabackup config destination remove ID"
                    id="$2"
                    doc="$(_config_destinations_doc)"
                    _config_validate_destinations || die "existing destinations.json is invalid"
                    jq -e --arg id "$id" 'any(.destinations[]; .id == $id)' <<<"$doc" >/dev/null \
                        || die "destination does not exist: $id"
                    doc="$(jq -c --arg id "$id" '.destinations=(.destinations // []) | .destinations |= map(select(.id != $id))' <<<"$doc")" \
                        || die "could not remove destination"
                    _config_write_destinations "$doc" || die "could not write $(_tilde "$DESTINATIONS_FILE")"
                    ;;
                *) die "usage: omabackup config destination <add|remove> ..." ;;
            esac
            flock -u "$dest_lock_fd"
            eval "exec ${dest_lock_fd}>&-"
            ;;
        *) die "usage: omabackup config [show|validate|set|destination]" ;;
    esac
}
