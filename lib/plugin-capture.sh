#!/bin/bash
# Captura de um plugin do omarchy-shell para o repo.
#
# Três casos, cada um com a estratégia que sobrevive a um bootstrap:
#   1. git limpo   → URL + commit (reinstala com `omarchy plugin add` e reseta no sha)
#   2. git sujo    → URL + commit + patch do estado local
#   3. sem remote  → cópia integral; não existe em nenhum remote de onde puxar
#
# Sourceável e sem efeito colateral no import, pra poder ser testado.
# Regressões em test/plugin-capture.test.sh; contexto em docs/OMABACKUP-DESIGN.md §11.3.

# Cópia integral, sem arrastar o histórico git de terceiro.
_capture_local() {
    local plugin="$1" local_dir="$2" id="$3"
    mkdir -p "$local_dir/$id"
    rsync -a --exclude '.git/' "$plugin/" "$local_dir/$id/"
}

# Patch do estado local contra HEAD, incluindo staged e untracked.
#
# `git diff` sozinho vê só o que está modificado E não-staged: um `git add` no
# diretório do plugin produzia patch vazio enquanto o `status --porcelain`
# continuava sujo, e a customização sumia no restore. `git diff HEAD` resolve o
# staged; os untracked exigem estarem no índice, e o índice do usuário não pode
# ser tocado — daí a cópia descartável via GIT_INDEX_FILE.
_capture_patch() {
    local plugin="$1"
    local tmp_index; tmp_index="$(mktemp)"
    local real_index; real_index="$(git -C "$plugin" rev-parse --git-path index 2>/dev/null || true)"

    [[ -n "$real_index" && -f "$plugin/$real_index" ]] && cp "$plugin/$real_index" "$tmp_index"
    [[ -n "$real_index" && -f "$real_index" ]] && cp "$real_index" "$tmp_index"

    GIT_INDEX_FILE="$tmp_index" git -C "$plugin" add -N -- . 2>/dev/null || true
    GIT_INDEX_FILE="$tmp_index" git -C "$plugin" diff HEAD
    rm -f "$tmp_index"
}

# capture_plugin <plugin_dir> <patch_dir> <local_dir> <manifest_file>
# Escreve a classificação em stdout: "git" | "git+patch" | "local"
capture_plugin() {
    local plugin="${1%/}" patch_dir="$2" local_dir="$3" manifest="$4"
    local id; id="$(basename "$plugin")"

    [[ -d "$plugin/.git" ]] || { _capture_local "$plugin" "$local_dir" "$id"; echo "local"; return; }

    local url sha
    url="$(git -C "$plugin" remote get-url origin 2>/dev/null || true)"
    sha="$(git -C "$plugin" rev-parse HEAD 2>/dev/null || true)"

    # Sem remote (ou sem commit) não há de onde reinstalar, e um patch não tem
    # base contra a qual aplicar. Antes esse plugin era classificado "git" e
    # não era gravado em lugar nenhum — sumia por completo.
    if [[ -z "$url" || -z "$sha" ]]; then
        _capture_local "$plugin" "$local_dir" "$id"
        echo "local"
        return
    fi

    # O commit importa tanto quanto a URL: sem ele o restore instala o HEAD de
    # hoje do upstream, que pode ter avançado — e aí o patch não aplica.
    printf '%s %s %s\n' "$id" "$url" "$sha" >>"$manifest"

    if [[ -z "$(git -C "$plugin" status --porcelain 2>/dev/null)" ]]; then
        rm -f "$patch_dir/$id.patch"
        echo "git"
        return
    fi

    _capture_patch "$plugin" >"$patch_dir/$id.patch"
    echo "git+patch"
}
