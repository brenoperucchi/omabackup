#!/bin/bash
# Sondas de cobertura (T1). Cada uma responde à pergunta da §0 do design:
# o backup contém os arquivos que este sistema, AGORA, de fato lê?
#
# Toda sonda escreve achados com `finding <nível> <grupo> <código> <mensagem> [caminho]`
# e nunca aborta o processo — uma sonda que falha vira achado, não crash.

# Raízes de package.path, na ordem em que o bootstrap.lua as declara.
# A do pacote entra pra poder ATRAVESSAR os módulos default (é por eles que se
# chega nos toggles), mas arquivo do pacote nunca é cobrado de cobertura:
# restaura com o pacote.
_lua_roots() {
    printf '%s\n' "$HOME/.local/state" "$HOME/.config" "${OMARCHY_PATH:-/usr/share/omarchy}"
}
_is_package_path() { [[ "$1" == "${OMARCHY_PATH:-/usr/share/omarchy}"/* ]]; }

# "hypr.monitors" → primeiro root onde hypr/monitors.lua existir.
_resolve_module() {
    local mod="${1//.//}" root
    while read -r root; do
        [[ -f "$root/$mod.lua" ]] && { printf '%s' "$root/$mod.lua"; return 0; }
    done < <(_lua_roots)
    return 1
}

# Qual config o compositor realmente carregou, segundo ele mesmo.
# Cai pro caminho convencional quando não há sessão (timer, container, ssh).
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

# Fecho transitivo do require a partir do entry point.
#
# Varrer todo *.lua sob as raízes seria mais simples e é o que a primeira versão
# fazia — mas acusa cache e undo do nvim, que também moram em ~/.local/state.
# Um verificador que nasce com falha falsa ensina a ser ignorado, que é o modo
# de falha que este produto existe pra evitar.
#
# require_all.files(dir) não dá pra resolver estaticamente sem interpretar Lua,
# então os literais entre aspas da linha são testados contra cada raiz. É assim
# que ~/.local/state/omarchy/toggles/hypr entra: default/hypr/toggles.lua faz
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
    local entry rc covered
    entry="$(probe_hypr_entry)"; rc=$?
    case $rc in
        0) finding info compositor entry-from-log "compositor carregou $(_tilde "$entry")" "$entry" ;;
        1) finding warn compositor entry-assumed "sem sessão viva; assumindo $(_tilde "$entry")" "$entry" ;;
        2) finding fail compositor entry-unknown "nenhuma config Lua do Hyprland encontrada" ""; return ;;
    esac

    local n_lua=0 n_out=0 n_pkg=0 n_exc=0 f
    while read -r f; do
        [[ -n "$f" ]] || continue
        if _is_package_path "$f"; then n_pkg=$((n_pkg + 1)); continue; fi
        n_lua=$((n_lua + 1))
        if is_excluded "$f"; then n_exc=$((n_exc + 1)); continue; fi
        if ! is_covered "$f"; then
            n_out=$((n_out + 1))
            finding fail compositor lua-uncovered "Lua vivo fora de todo grupo: $(_tilde "$f")" "$f"
        fi
    done < <(probe_hypr_lua_files "$entry")
    (( n_out == 0 )) && finding pass compositor lua-covered \
        "$n_lua .lua do usuário cobertos ($n_pkg do pacote, $n_exc excluídos de propósito)" ""

    # .conf que o compositor não lê mais desde o Quattro. Não é falha — é peso
    # morto, e a §11.7 pede que apareça pra não ser restaurado como autoritativo.
    local n_conf; n_conf="$(find "$HOME/.config/hypr" -name '*.conf' 2>/dev/null | wc -l)"
    (( n_conf > 0 )) && finding info compositor conf-inert "$n_conf .conf inertes desde o Quattro" ""
}

probe_shell_json() {
    local f="$HOME/.config/omarchy/shell.json"
    [[ -f "$f" ]] || { finding fail shell missing "shell.json não existe" "$f"; return; }
    jq -e . "$f" >/dev/null 2>&1 || { finding fail shell invalid-json "shell.json não é JSON válido" "$f"; return; }
    [[ "$(jq -r '.version // empty' "$f")" == "1" ]] \
        || { finding fail shell bad-version "shell.json sem version: 1 — o shell cai pros defaults" "$f"; return; }
    is_covered "$f" || { finding fail shell uncovered "shell.json fora de todo grupo" "$f"; return; }
    finding pass shell ok "shell.json válido, version 1" "$f"
}

# Dirigida pelo DIRETÓRIO, não por listPlugins: listPlugins inclui first-party
# (ruído permanente) e omite plugin com manifest inválido — justo o que mais
# precisa de backup. Ver design §11.2.
probe_plugins() {
    local dir="$HOME/.config/omarchy/plugins" p id n=0
    [[ -d "$dir" ]] || { finding info plugins none "nenhum plugin instalado" ""; return; }
    for p in "$dir"/*/; do
        [[ -d "$p" ]] || continue
        id="$(basename "$p")"
        [[ "$id" == .* ]] && continue
        n=$((n + 1))
        if [[ -d "$p/.git" ]]; then
            git -C "$p" remote get-url origin >/dev/null 2>&1 \
                || finding warn plugins no-remote "$id não tem remote: precisa de cópia integral" "$p"
        else
            finding info plugins local "$id é autoral: versionado na íntegra" "$p"
        fi
    done
    finding pass plugins counted "$n plugins inspecionados" ""
}

probe_migrations() {
    local dir="$HOME/.local/state/omarchy/migrations" n mark
    [[ -d "$dir" ]] || { finding warn state no-markers "sem marcadores de migração" "$dir"; return; }
    n="$(find "$dir" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | wc -l)"
    mark="$(find "$dir" -maxdepth 1 -type f -name '*.sh' -printf '%f\n' 2>/dev/null | sed 's/\.sh$//' | sort -n | tail -1)"
    finding pass state markers "$n marcadores · marca-d'água $mark" "$dir"
    if omarchy-migrate --pending >/dev/null 2>&1; then
        finding warn state migrations-pending "há migrações pendentes: a config vai mudar no próximo login" ""
    fi
}

probe_packages() {
    local n; n="$(pacman -Qqe 2>/dev/null | wc -l)"
    (( n > 0 )) && finding pass packages counted "$n pacotes explícitos" "" \
                || finding warn packages unavailable "pacman indisponível" ""
}
