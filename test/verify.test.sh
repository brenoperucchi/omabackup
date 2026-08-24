# Regressões da cobertura (bin/omabackup verify).
# O caso central é o incidente de 17/08/2026: config íntegra, formato trocado,
# backup verde e inútil. Contexto: docs OMABACKUP-DESIGN §0 e §11.
#
# Cada caso monta um $HOME falso e um manifesto próprio; nada toca a máquina.

OB="$PWD/bin/omabackup"

# _home <n>  → cria um HOME falso com uma config Hyprland em Lua
_home() {
    local h; h="$(mktemp -d)"
    mkdir -p "$h/.config/hypr"
    cat >"$h/.config/hypr/hyprland.lua" <<'LUA'
require("hypr.monitors")
require("hypr.bindings")
LUA
    printf 'hl.monitor({})\n'  >"$h/.config/hypr/monitors.lua"
    printf 'hl.bind({})\n'     >"$h/.config/hypr/bindings.lua"
    printf '%s' "$h"
}

# _groups <arquivo> <json-dos-paths> [json-das-exclusões]
_groups() {
    cat >"$1" <<JSON
{ "schemaVersion": 1, "supportedTargets": ["4.*"],
  "excluded": ${3:-[]},
  "groups": [ { "id":"compositor","label":"Hyprland","mode":"copy",
                "coupled":true,"critical":true,"probe":"hypr-lua","paths": $2 } ] }
JSON
}

_verify() {  # ecoa o JSON do verify rodando contra o HOME falso
    HOME="$1" OMABACKUP_GROUPS="$2" XDG_RUNTIME_DIR=/nonexistent \
        OMABACKUP_STATE="$1/.local/state/omabackup" "$OB" verify --json 2>/dev/null
}

# ── o incidente de agosto ────────────────────────────────────────────────────
# O compositor lê .lua; o backup declara só os .conf. Íntegros, válidos, inúteis.
H="$(_home)"; G="$H/groups.json"
printf 'monitor=eDP-1\n' >"$H/.config/hypr/hyprland.conf"
_groups "$G" '["~/.config/hypr/hyprland.conf"]'
OUT="$(_verify "$H" "$G")"

it "agosto: backup só com .conf é reprovado"
assert_eq "$(jq -r .ok <<<"$OUT")" "false"

it "agosto: aponta o .lua que ficou de fora"
assert_contains "$(jq -r '.findings[]|select(.code=="lua-uncovered")|.path' <<<"$OUT")" "hyprland.lua"

it "agosto: reprova cada .lua vivo descoberto, não só o primeiro"
assert_eq "$(jq -r '[.findings[]|select(.code=="lua-uncovered")]|length' <<<"$OUT")" "3"

# ── o mesmo sistema, coberto ─────────────────────────────────────────────────
H="$(_home)"; G="$H/groups.json"
_groups "$G" '["~/.config/hypr"]'
OUT="$(_verify "$H" "$G")"

it "cobrindo o diretório inteiro, passa"
assert_eq "$(jq -r .ok <<<"$OUT")" "true"

# ── transitividade ───────────────────────────────────────────────────────────
# Um módulo alcançado por require de FORA de ~/.config/hypr precisa ser cobrado.
# É o caso real do toggles/hypr/flags.lua, que vive em ~/.local/state.
H="$(_home)"; G="$H/groups.json"
mkdir -p "$H/.local/state/meu"
printf 'return {}\n' >"$H/.local/state/meu/extra.lua"
printf 'require("meu.extra")\n' >>"$H/.config/hypr/hyprland.lua"
_groups "$G" '["~/.config/hypr"]'
OUT="$(_verify "$H" "$G")"

it "módulo alcançado por require fora do grupo é reprovado"
assert_eq "$(jq -r .ok <<<"$OUT")" "false"

it "o módulo transitivo é nomeado no achado"
assert_contains "$(jq -r '.findings[]|select(.code=="lua-uncovered")|.path' <<<"$OUT")" "meu/extra.lua"

# ── exclusão deliberada silencia, com motivo versionado ──────────────────────
H="$(_home)"; G="$H/groups.json"
mkdir -p "$H/.local/state/meu"
printf 'return {}\n' >"$H/.local/state/meu/extra.lua"
printf 'require("meu.extra")\n' >>"$H/.config/hypr/hyprland.lua"
_groups "$G" '["~/.config/hypr"]' '[{"path":"~/.local/state/meu","reason":"gerado, reconstruível"}]'
OUT="$(_verify "$H" "$G")"

it "caminho excluído de propósito não reprova"
assert_eq "$(jq -r .ok <<<"$OUT")" "true"

# ── caminho fantasma ─────────────────────────────────────────────────────────
# Um grupo crítico apontando pra lugar nenhum reportava "em dia" cobrindo zero
# bytes — foi o que aconteceu quando o Omarchy moveu current/ pra ~/.local/state.
H="$(_home)"; G="$H/groups.json"
_groups "$G" '["~/.config/hypr","~/.config/omarchy/nao-existe"]'
OUT="$(_verify "$H" "$G")"

it "caminho declarado e inexistente vira aviso"
assert_contains "$(jq -r '.findings[]|select(.code=="path-missing")|.message' <<<"$OUT")" "nao-existe"

# ── identidade de compatibilidade ────────────────────────────────────────────
H="$(_home)"; G="$H/groups.json"
_groups "$G" '["~/.config/hypr"]'
OUT="$(_verify "$H" "$G")"

it "o relatório carrega a versão do Omarchy"
assert_contains "$(jq -r .omarchy.version <<<"$OUT")" "."

it "o relatório carrega a marca-d'água de migração"
[[ "$(jq -r .omarchy.migrationWatermark <<<"$OUT")" =~ ^[0-9]+$ ]] && ok || fail "marca-d'água não é numérica"
