# Regressões do collect (bin/omabackup collect).
# O tema é sempre o mesmo: o manifesto declara intenção e o coletor precisa
# honrá-la, ou recusar em alto e bom som. Contexto: OMABACKUP-CONTEXT §4,
# "loop genérico atropela lógica específica".

OB="$PWD/bin/omabackup"

_env() {  # _env <home> <groups> <cmd...>
    local h="$1" g="$2"; shift 2
    HOME="$h" OMABACKUP_GROUPS="$g" OMABACKUP_STATE="$h/.state" \
        XDG_RUNTIME_DIR=/nonexistent "$OB" "$@" 2>&1
}

# ── exclude é honrado ────────────────────────────────────────────────────────
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/app/node_modules/pacote" "$H/.config/app/src"
printf 'x\n' >"$H/.config/app/node_modules/pacote/index.js"
printf 'meu\n' >"$H/.config/app/src/main.lua"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"],"exclude":["node_modules/**"]}]}
JSON
_env "$H" "$G" collect >/dev/null

it "exclude do manifesto mantém node_modules fora do staging"
[[ ! -e "$H/.state/staging/.config/app/node_modules" ]] && ok || fail "node_modules foi copiado"

it "exclude não leva o resto junto"
assert_contains "$(cat "$H/.state/staging/.config/app/src/main.lua" 2>/dev/null)" "meu"

# ── mode:triple não vira cópia genérica ──────────────────────────────────────
H="$(mktemp -d)"; G="$H/g.json"
P="$H/.config/omarchy/plugins/acme.dock"
mkdir -p "$P"
git init -q "$P"; git -C "$P" config user.email t@t; git -C "$P" config user.name t
printf 'slotSize: 42\n' >"$P/Dock.qml"
git -C "$P" add -A; git -C "$P" commit -qm base
git -C "$P" remote add origin https://github.com/acme/dock.git
printf 'slotSize: 56\n' >"$P/Dock.qml"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"plugins","label":"Plugins","mode":"triple","coupled":true,"critical":true,
  "paths":["~/.config/omarchy/plugins"]}]}
JSON
_env "$H" "$G" collect >/dev/null
ST="$H/.state/staging"

it "triple não copia o código do plugin de terceiro"
[[ ! -e "$ST/.config/omarchy/plugins" ]] && ok || fail "o diretório do plugin foi copiado inteiro"

it "triple grava URL e commit no manifesto"
assert_contains "$(cat "$ST/.plugins/manifest.txt" 2>/dev/null)" "github.com/acme/dock.git"

it "triple guarda a customização local como patch"
assert_contains "$(cat "$ST/.plugins/patches/acme.dock.patch" 2>/dev/null)" "slotSize: 56"

# ── o manifesto não pode declarar o que o coletor ignora ─────────────────────
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/app"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"copy","coupled":false,"critical":false,
  "paths":["~/.config/app"],"campoQueNinguemImplementou":true}]}
JSON
OUT="$(_env "$H" "$G" collect)"

it "campo desconhecido no manifesto aborta o collect"
assert_contains "$OUT" "campoQueNinguemImplementou"

it "campo desconhecido não deixa staging pela metade"
[[ ! -d "$H/.state/staging" ]] && ok || fail "criou staging antes de abortar"

# ── mode desconhecido também ─────────────────────────────────────────────────
H="$(mktemp -d)"; G="$H/g.json"
mkdir -p "$H/.config/app"
cat >"$G" <<'JSON'
{"schemaVersion":1,"supportedTargets":["4.*"],"groups":[
 {"id":"app","label":"App","mode":"telepatia","coupled":false,"critical":false,
  "paths":["~/.config/app"]}]}
JSON
it "mode desconhecido aborta o collect"
assert_contains "$(_env "$H" "$G" collect)" "telepatia"
