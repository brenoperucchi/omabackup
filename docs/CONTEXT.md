# OmaBackup — contexto para começar

Documento de handoff. Reúne o problema que motivou a ideia, tudo que
descobrimos sobre a arquitetura de plugins do Omarchy 4.0 "Quattro", e o que já
existe funcionando neste repo e serve de protótipo.

Escrito em 2026-08-24, logo depois de reconstruir à mão a config perdida no
upgrade pro Quattro.

---

## 1. O problema (a história real que originou a ideia)

**17/08/2026** — upgrade do Omarchy 3 → 4.0 "Quattro". O Hyprland passou a usar
config **Lua nativa**: `~/.config/hypr/hyprland.lua` tem prioridade sobre o
`hyprland.conf`, que vira inerte. O log do compositor confirma a troca:

```
[cfg] Regular config at /home/brenoperucchi/.config/hypr/hyprland.lua
[cfg] Using lua config found at /home/brenoperucchi/.config/hypr/hyprland.lua
```

O instalador gerou `monitors.lua`, `input.lua`, `bindings.lua`, `looknfeel.lua`
e `autostart.lua` como **templates vazios, com tudo comentado**. Nenhuma
customização dos `.conf` antigos foi migrada. Os `.conf` continuaram no disco,
intactos e completamente ignorados.

Resultado prático, tudo de uma vez:

- monitores na resolução errada, o ASUS perdeu a rotação (`transform 3`)
- teclado sem acentuação (`kb_variant = intl` sumiu)
- ~40 keybindings macOS-style perdidos
- gaps, bordas, blur, animações de volta ao default
- workspaces desgarrados dos monitores

Cada um desses teve que ser reconstruído à mão, traduzindo `.conf` → API Lua
nova, testando um a um.

**E o pior:** o repo de dotfiles (`omarchy-personal`) estava parado em 10/08.
Um `bootstrap.sh` a partir dele teria restaurado só os `.conf` — que o Hyprland
0.55+ nem lê mais. O backup existia e mesmo assim não teria salvado nada.

### As três lições que viram requisito de produto

1. **Backup que ninguém roda não é backup.** O `README` documentava
   `./sync.sh` como o fluxo de atualização há meses. O script **nunca existiu**
   (não aparece em nenhum commit). Ninguém percebeu porque nada avisava.
2. **Upgrade é o momento de maior risco e o de menor atenção.** Justamente
   quando a config muda de formato é quando o usuário não pensa em backup.
3. **Nem tudo se restaura do mesmo jeito.** Config própria, plugin de
   terceiro, plugin de terceiro *modificado* e plugin autoral pedem estratégias
   diferentes (ver §4).

---

## 2. Arquitetura de plugins do Quattro (o que você precisa saber pra construir)

Fonte primária, vale ler antes de codar:

- `/usr/share/omarchy/shell/README.md` — manifest, kinds, IPC, `shell.json`
- `/usr/share/omarchy/shell/plugins/README.md` — catálogo dos first-party
- `/usr/share/omarchy/shell/services/PluginRegistry.qml` — schema completo

### Como funciona

`omarchy-shell` é **uma única instância** do [Quickshell](https://quickshell.org/)
que hospeda o desktop inteiro. Barra, painéis, menus, overlays — tudo roda
**dentro** dela como plugin. O processo real chama-se `quickshell`:

```bash
pgrep -af quickshell
# 353177 quickshell -n -p /usr/share/omarchy/shell
```

Um plugin é um **repo git com `manifest.json` na raiz**, clonado em
`~/.config/omarchy/plugins/<id>/`.

### manifest.json

```json
{
  "schemaVersion": 1,
  "id": "brenoperucchi.omabackup",
  "name": "OmaBackup",
  "version": "0.1.0",
  "author": "brenoperucchi",
  "license": "MIT",
  "description": "...",
  "kinds": ["service", "bar-widget", "panel"],
  "keepLoaded": true,
  "entryPoints": {
    "service": "Service.qml",
    "barWidget": "BarWidget.qml",
    "panel": "Panel.qml"
  },
  "barWidget": {
    "displayName": "OmaBackup",
    "category": "System",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": { "intervalHours": 24 },
    "schema": [
      { "key": "intervalHours", "type": "number", "label": "Backup interval" }
    ]
  }
}
```

`kinds` disponíveis:

| Kind | O que é |
|------|---------|
| `bar-widget` | componente que a barra encaixa numa seção |
| `panel` | janela flutuante persistente ou invocada |
| `overlay` | overlay fullscreen |
| `menu` | superfície de menu invocada |
| `service` | singleton headless, sem UI |
| `bar` | barra completa, substitui a `omarchy.bar` |

`keepLoaded: true` mantém o plugin montado entre invocações.

O bloco `barWidget.schema` é o que dá **UI de configuração de graça** — o
usuário edita pelo próprio Omarchy em vez de mexer em JSON na mão. Vale usar.

### IPC

O shell expõe o target `shell`, e cada plugin pode registrar o seu:

| Método | Efeito |
|--------|--------|
| `ping` | health check |
| `summon <id> <payloadJson>` | carrega + abre painel/overlay |
| `hide <id>` / `toggle <id> <payload>` | fecha / alterna |
| `call <id> <method> <arg>` | chama método de plugin carregado |
| `rescanPlugins` | re-varre e faz hot-reload do código |
| `reloadConfig` | recarrega `shell.json` |
| `setPluginEnabled <id> <enabled>` | liga/desliga (string! só `"true"` liga) |
| `listPlugins` | JSON de todos os plugins |

```bash
omarchy-shell shell ping
omarchy-shell shell listPlugins
omarchy-shell shell toggle brenoperucchi.omabackup '{}'
```

Registrar target próprio no QML:

```qml
IpcHandler {
    target: "brenoperucchi.omabackup"
    function runNow() { root.runBackup(); return "ok" }
    function status() { return JSON.stringify(root.lastRun) }
}
```

### Ciclo de desenvolvimento

**Salvar qualquer arquivo em `~/.config/omarchy/plugins/` recarrega o código
automaticamente.** Não precisa reiniciar nada no caso normal.

```bash
omarchy plugin validate <pasta>          # valida manifest contra o schema
omarchy-shell shell rescanPlugins        # força reload
omarchy plugin add <url> --enable --yes  # --yes é o caminho pra script/agente
omarchy plugin clone omarchy.clock       # estudar um first-party sem editá-lo
omarchy-restart-shell                    # restart completo (ver aviso abaixo)
```

⚠️ **O shell pode crashar silenciosamente durante hot-reload.** Aconteceu
nesta sessão: um erro de QML em *outro* plugin derrubou o `quickshell` inteiro
— barra, dock e menu sumiram — e nada relançou sozinho. O diagnóstico é
`pgrep -x quickshell` vazio; a cura é `omarchy-restart-shell`. **Um plugin de
backup precisa ser defensivo a ponto de nunca ser a causa disso**: try/catch em
tudo, nada de exceção não tratada em `Component.onCompleted`.

Para depurar:

```bash
journalctl --user --since "-2 minutes" | grep -iE "omarchy-shell|error|fatal"
```

---

## 3. Estado persistido: `shell.json`

Arquivo único: `~/.config/omarchy/shell.json`. Layout da barra + settings por
entrada + plugins habilitados.

```json
{
  "version": 1,
  "idle": { "screensaver": 150, "lock": 300 },
  "bar": {
    "position": "top",
    "transparent": true,
    "centerAnchor": "omarchy.clock",
    "layout": {
      "left":   [ { "id": "omarchy.menu" } ],
      "center": [ { "id": "rosakodu.dock", "settings": { "autohide": true } } ],
      "right":  [ { "id": "omarchy.tray" } ]
    }
  },
  "plugins": []
}
```

Três armadilhas descobertas na prática:

1. **Sem deep-merge.** Assim que o usuário customiza qualquer coisa, o
   `shell.json` vira a fonte de verdade e os defaults **não** voltam a ser
   mesclados. Um backup precisa capturar o arquivo inteiro.
2. **Plugins escrevem no arquivo sozinhos.** O `argus` gravou
   `sensorThresholds` e `hiddenSensors` na entrada dele sem pedir nada. Um
   backup em andamento tem que tolerar o arquivo mudando debaixo dele.
3. **Convenção de settings é inconsistente entre plugins.** O `rosakodu.dock`
   lê de `"settings": {...}` aninhado; o `argus` lê de chaves soltas na raiz da
   entrada. Não dá pra assumir uma forma só.

Tirar um widget do `layout` já o marca como `enabled: false` automaticamente —
não precisa desabilitar à parte.

---

## 4. O protótipo que já existe: `sync.sh`

Está na raiz deste repo, funcionando, com o commit `cd715db`. É o
**reverso do `install.sh`**: puxa o estado ao vivo da máquina de volta pro repo.
É de onde tirar a lógica do plugin.

```bash
./sync.sh --dry-run     # mostra sem tocar em nada
./sync.sh
git add -A && git commit -m "..." && git push
```

### Decisões de projeto (todas custaram alguma descoberta)

**Só atualiza o que o repo já rastreia.** Varrer `~/.config` inteiro arrastaria
cache, state, perfis de browser e secrets. Para versionar algo novo, cria-se o
caminho no repo uma vez; daí em diante o sync mantém.

**Sem `--delete`.** O que sumiu da máquina fica no repo até decisão explícita
com `git rm`. Real: `elephant`, `mako`, `walker`, `waybar` e `swayosd` não
existem mais ao vivo depois do Quattro, mas ninguém quer perdê-los por acidente.

**Preserva symlinks** (`rsync -a`, nunca `cp -p` nem `-L` genérico). Este repo
versiona 3 symlinks; `configs/nvim/lua/plugins/theme.lua` aponta pro tema
corrente do Omarchy. Sobrescrever com o conteúdo do alvo quebra a troca de tema.
Como auditar:

```bash
git ls-files -s | grep ^120000
```

**Plugins em três estratégias** — o ponto mais importante pro OmaBackup:

| Caso | Como detectar | Estratégia |
|------|---------------|------------|
| git, sem modificação | tem `.git/`, `git status --porcelain` vazio | só a URL em `lists/omarchy-plugins.txt` |
| git, **com** modificação local | tem `.git/`, status sujo | URL **+** `git diff` salvo em `patches/omarchy-plugins/<id>.patch` |
| local (autoral) | sem `.git/` | versionado na íntegra — não existe em nenhum remote |

Sem isso: ou perde-se a modificação local (o `rosakodu.dock` carrega nosso
`slotSize: 42 → 56`), ou o repo engorda ~7MB de código de terceiros que já vive
no GitHub.

### Dois bugs que valem lembrar

**`((count++))` com `set -e` aborta o script.** O pós-incremento devolve o valor
*antigo*; na primeira volta (0) o status vira 1 e o `set -e` mata tudo no meio,
**silenciosamente**. Use `count=$((count + 1))`.

**Loop genérico atropela lógica específica.** A primeira versão copiava
`~/.config/omarchy/` inteiro, `plugins/` incluso — anulando toda a estratégia de
manifest+patch descrita acima. Precisou de `--exclude 'plugins/'` naquele rsync
específico. Moral: quando há tratamento especial pra um subcaminho, o loop
genérico precisa saber disso explicitamente.

### Higiene de secrets

O `.gitignore` deste repo já cobre bastante (secrets, browsers, `**/.env`,
chaves). O sync varre o resultado antes do commit. Falsos positivos comuns e
inofensivos: `--password-store=gnome-libsecret`, `hide_token_restore`, e
`.bashrc` fazendo `source` condicional de arquivos externos sem conter valores.

Um plugin de backup **precisa** dessa varredura embutida e visível — é o tipo
de coisa que só se descobre que faltou quando já vazou.

---

## 5. Ideias de escopo pro OmaBackup

Não decidido, é material bruto pra sessão de design.

### O que o plugin resolveria que o `sync.sh` não resolve

- **Lembrar de rodar.** `service` com timer; badge no `bar-widget` quando o
  backup está velho. Ataca a lição nº 1.
- **Detectar upgrade do Omarchy.** Observar a versão (`~/.local/share/omarchy/version`)
  e propor backup **antes** de aplicar. Ataca a lição nº 2 — o valor mais alto
  do plugin todo.
- **Diff visual antes de commitar.** Painel mostrando o que mudou desde o
  último backup, com opção de excluir caminhos.
- **Restauração seletiva.** Hoje é `install.sh` tudo-ou-nada.
- **Onboarding.** Hoje exige repo git montado à mão. O plugin poderia
  inicializar (git local, remote opcional, destino em disco/rclone).

### Perguntas de design em aberto

1. **Backend:** git (histórico, diff, push) ou snapshot em tarball? Git é o
   protótipo atual, mas exige que o usuário tenha repo. Talvez git local por
   padrão + remote opcional.
2. **Escopo:** só config do Omarchy (`shell.json` + plugins) ou dotfiles em
   geral (o que o `sync.sh` faz)? O primeiro é mais defensável como plugin; o
   segundo é o que dói de verdade.
3. **Segredos:** deny-list (como o `.gitignore` daqui) ou allow-list explícita?
   Allow-list é mais segura e menos conveniente.
4. **Sistema vs. usuário:** só `~/.config` ou também `/etc`? O `sync.sh` só
   *avisa* sobre `/etc/sudoers.d` porque precisa de root. Plugin não deveria
   pedir sudo — o instalador do Omarchy explicitamente nunca roda sudo.
5. **Onde escreve:** um plugin roda dentro do shell, sem sandbox. Escrever
   arquivo e rodar git de dentro do QML pede cuidado; talvez o plugin seja só a
   UI e o trabalho pesado fique num script que ele invoca (`Quickshell.execDetached`).

### Nome

`OmaBackup` combina com a convenção existente (`omacalc`, `omawrite`,
`omacut`). O id seguiria `brenoperucchi.omabackup` ou
`io.github.brenoperucchi.omabackup`.

---

## 6. Referência rápida de caminhos

| Caminho | O que é |
|---------|---------|
| `~/.config/omarchy/shell.json` | layout da barra + settings + enabled |
| `~/.config/omarchy/plugins/<id>/` | plugins de terceiros e autorais |
| `/usr/share/omarchy/shell/` | shell do Omarchy (first-party, referência) |
| `/usr/share/omarchy/shell/README.md` | contrato de plugin — **leia** |
| `/usr/share/omarchy/bin/` | CLI (`omarchy-shell`, `omarchy-restart-shell`) |
| `~/.local/share/omarchy/version` | versão instalada (`4.0.0.alpha`) |
| `~/.config/hypr/*.lua` | config do Hyprland (Quattro) |
| `~/.config/hypr/*.conf` | config antiga, **inerte** desde o Quattro |
| `~/Devs/omarchy-personal/sync.sh` | o protótipo |

Marketplace: <https://omarchyplugins.com> (catálogo pequeno — vários links de
plugin retornam "does not exist in the current catalog", então confie no repo
git direto).

Plugins instalados aqui, úteis como referência de código real:

```
b.everything                       github.com/brianblakely/omarchy-everything
im0001gt.hw-tooltip                github.com/IM0001GT/omarchy-hw-tooltip
io.github.diegopluna.argus         github.com/diegopluna/omarchy-argus
io.github.howdyitskyle.weathering  github.com/howdyitskyle/weathering-omarchy-plugin
rosakodu.dock                      github.com/rosakodu/omarchy-dock
user.workspaces-per-monitor        (local, neste repo — exemplo mínimo, 2 arquivos)
```

O `user.workspaces-per-monitor` em `configs/omarchy/plugins/` é o menor exemplo
completo de plugin autoral: `manifest.json` + um QML, fork de um first-party.
Bom ponto de partida pra estrutura.
