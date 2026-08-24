#!/bin/bash
# Coverage probes (T1). Each one answers the question from docs/DESIGN.md §0:
# does the backup contain the files this system, right now, actually reads?
#
# Every probe reports through `finding <level> <group> <code> <message> [path]`
# and never aborts -- a probe that fails becomes a finding, not a crash.

# package.path roots the user can write to, in the order bootstrap.lua declares
# them. The OMARCHY_PATH root is included so the graph can be TRAVERSED (that is
# how the toggles are reached), but package files are never held to coverage:
# they are restored with the package.
_lua_roots() {
    printf '%s\n' "$HOME/.local/state" "$HOME/.config" "${OMARCHY_PATH:-/usr/share/omarchy}"
}
_is_package_path() { [[ "$1" == "${OMARCHY_PATH:-/usr/share/omarchy}"/* ]]; }

# "hypr.monitors" -> the first root where hypr/monitors.lua exists.
_resolve_module() {
    local mod="${1//.//}" root
    while read -r root; do
        [[ -f "$root/$mod.lua" ]] && { printf '%s' "$root/$mod.lua"; return 0; }
    done < <(_lua_roots)
    return 1
}

# Which config the compositor actually loaded, according to the compositor.
# Falls back to the conventional path when there is no live session
# (systemd timer, container, ssh).
probe_hypr_entry() {
    local log entry
    log="$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$UID}"/hypr/*/hyprland.log 2>/dev/null | head -1)"
    if [[ -n "$log" ]]; then
        entry="$(grep -oP '(?<=Using lua config found at ).*' "$log" 2>/dev/null | tail -1)"
        [[ -n "$entry" ]] && { printf '%s' "$entry"; return 0; }
    fi
    [[ -f "$HOME/.config/hypr/hyprland.lua" ]] && { printf '%s' "$HOME/.config/hypr/hyprland.lua"; return 1; }
    return 2
}

# Transitive closure of `require` starting from the entry point.
#
# Globbing every *.lua under the roots would be simpler, and is what the first
# version did -- but it flags nvim's cache and undo files, which also live in
# ~/.local/state. A checker born with false failures teaches you to ignore it,
# which is the exact failure mode this product exists to prevent.
#
# require_all.files(dir) cannot be resolved statically without interpreting Lua,
# so the quoted literals on that line are tried against each root. That is how
# ~/.local/state/omarchy/toggles/hypr gets in: default/hypr/toggles.lua calls
# require_all.files(paths.state_home .. "/omarchy/toggles/hypr").
probe_hypr_lua_files() {
    local entry="$1"
    [[ -f "$entry" ]] || return 0
    declare -A seen=()
    local queue=("$entry") cur mod frag root dir f

    while ((${#queue[@]})); do
        cur="${queue[0]}"; queue=("${queue[@]:1}")
        [[ -n "${seen[$cur]:-}" ]] && continue
        seen[$cur]=1
        printf '%s\n' "$cur"

        while read -r mod; do
            [[ -n "$mod" ]] || continue
            f="$(_resolve_module "$mod")" && queue+=("$f")
        done < <(grep -oP '(?<=require\(")[^"]+(?=")' "$cur" 2>/dev/null)

        grep -q 'require_all\.files' "$cur" 2>/dev/null || continue
        while read -r frag; do
            [[ "$frag" == /* ]] || continue
            while read -r root; do
                dir="$root$frag"
                [[ -d "$dir" ]] || continue
                while read -r f; do [[ -n "$f" ]] && queue+=("$f"); done \
                    < <(find "$dir" -maxdepth 1 -type f -name '*.lua' 2>/dev/null)
            done < <(_lua_roots)
        done < <(grep -oP '(?<=")[^"]+(?=")' "$cur" 2>/dev/null)
    done
}

probe_hypr() {
    local entry rc
    entry="$(probe_hypr_entry)"; rc=$?
    case $rc in
        0) finding info compositor entry-from-log "compositor loaded $(_tilde "$entry")" "$entry" ;;
        1) finding warn compositor entry-assumed "no live session; assuming $(_tilde "$entry")" "$entry" ;;
        2) finding fail compositor entry-unknown "no Hyprland Lua config found" ""; return ;;
    esac

    local n_lua=0 n_out=0 n_pkg=0 n_exc=0 f
    while read -r f; do
        [[ -n "$f" ]] || continue
        if _is_package_path "$f"; then n_pkg=$((n_pkg + 1)); continue; fi
        n_lua=$((n_lua + 1))
        if is_excluded "$f"; then n_exc=$((n_exc + 1)); continue; fi
        if ! is_covered "$f"; then
            n_out=$((n_out + 1))
            finding fail compositor lua-uncovered "live Lua outside every group: $(_tilde "$f")" "$f"
        fi
    done < <(probe_hypr_lua_files "$entry")
    (( n_out == 0 )) && finding pass compositor lua-covered \
        "$n_lua user .lua covered ($n_pkg from the package, $n_exc excluded on purpose)" ""

    # .conf files the compositor stopped reading with Quattro. Not a failure --
    # dead weight, and §11.7 wants it visible so it is never restored as
    # authoritative.
    local n_conf; n_conf="$(find "$HOME/.config/hypr" -name '*.conf' 2>/dev/null | wc -l)"
    (( n_conf > 0 )) && finding info compositor conf-inert "$n_conf inert .conf files since Quattro" ""
}

probe_shell_json() {
    local f="$HOME/.config/omarchy/shell.json"
    [[ -f "$f" ]] || { finding fail shell missing "shell.json does not exist" "$f"; return; }
    jq -e . "$f" >/dev/null 2>&1 || { finding fail shell invalid-json "shell.json is not valid JSON" "$f"; return; }
    [[ "$(jq -r '.version // empty' "$f")" == "1" ]] \
        || { finding fail shell bad-version "shell.json lacks version: 1 -- the shell falls back to defaults" "$f"; return; }
    is_covered "$f" || { finding fail shell uncovered "shell.json is outside every group" "$f"; return; }
    finding pass shell ok "shell.json valid, version 1" "$f"
}

# Driven by the DIRECTORY, not by listPlugins: listPlugins includes first-party
# plugins (permanent noise) and omits any plugin with an invalid manifest --
# precisely the one that most needs backing up. See docs/DESIGN.md §11.2.
probe_plugins() {
    local dir="$HOME/.config/omarchy/plugins" p id n=0
    [[ -d "$dir" ]] || { finding info plugins none "no plugins installed" ""; return; }
    for p in "$dir"/*/; do
        [[ -d "$p" ]] || continue
        id="$(basename "$p")"
        [[ "$id" == .* ]] && continue
        n=$((n + 1))
        if [[ -d "$p/.git" ]]; then
            git -C "$p" remote get-url origin >/dev/null 2>&1 \
                || finding warn plugins no-remote "$id has no remote: needs a full copy" "$p"
        else
            finding info plugins local "$id is homegrown: stored in full" "$p"
        fi
    done
    finding pass plugins counted "$n plugins inspected" ""
}

probe_migrations() {
    local dir="$HOME/.local/state/omarchy/migrations" n mark
    [[ -d "$dir" ]] || { finding warn state no-markers "no migration markers" "$dir"; return; }
    n="$(find "$dir" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l)"
    mark="$(find "$dir" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null | sed 's/\.sh$//' | sort -n | tail -1)"
    finding pass state markers "$n markers - watermark $mark" "$dir"
    if omarchy-migrate --pending >/dev/null 2>&1; then
        finding warn state migrations-pending "migrations are pending: config will change at next login" ""
    fi
}

probe_packages() {
    local n; n="$(pacman -Qqe 2>/dev/null | wc -l)"
    (( n > 0 )) && finding pass packages counted "$n explicit packages" "" \
                || finding warn packages unavailable "pacman unavailable" ""
}
