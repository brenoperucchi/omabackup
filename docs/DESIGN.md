# OmaBackup — proposta de design v0

Artefato para revisão. Continuação de [CONTEXT.md](CONTEXT.md),
que descreve o incidente do upgrade 3 → 4.0 "Quattro" e a arquitetura de
plugins do Omarchy. Aqui as perguntas em aberto da §5 daquele doc viram
decisões concretas, para poderem ser atacadas.

Escrito 2026-08-24.

---

## 0. Tese central

**A falha de agosto não foi corrupção de backup. Foi cobertura.**

O `hyprland.conf` versionado estava íntegro, válido e completo. Ele
simplesmente deixou de ser o arquivo que o Hyprland lê. Um backup que
verificasse *integridade* (hash, sintaxe, restore bem-sucedido) teria passado
com nota máxima e mesmo assim não teria salvado nada.

Logo, a pergunta que o OmaBackup precisa responder não é "o backup está
íntegro?" mas:

> **O backup contém os arquivos que este sistema, agora, de fato lê?**

Isso é verificável interrogando a máquina viva, em segundos, sem VM nenhuma.
A VM resolve outra pergunta (mais cara e menos frequente): "restaurado do
zero, isso sobe?". As duas são necessárias; só a primeira precisa rodar toda
hora.

---

## 1. Arquitetura: o plugin é UI, o trabalho pesado é CLI

```
┌─ omabackup (CLI bash, ~/.local/bin) ─────────────────────┐
│  collect · classify · scan-secrets · verify · pack       │
│  push (git | rclone | dir | removable) · restore         │
│  todo subcomando aceita --json                           │
└──────────────────────────▲───────────────────────────────┘
                           │ Quickshell.Io.Process (stdout JSON)
┌──────────────────────────┴───────────────────────────────┐
│  brenoperucchi.omabackup (plugin QML)                    │
│    service    → timer, watcher de versão, gatilhos       │
│    bar-widget → ícone + badge de estado                  │
│    panel      → grupos, destinos, agenda, diff, histórico│
└──────────────────────────────────────────────────────────┘
```

Por que a divisão:

1. **O plugin roda dentro do processo que hospeda o desktop inteiro.** Um erro
   de QML derruba barra, dock e menu — já aconteceu nesta máquina. Backup é
   exatamente a feature que não pode ser a causa disso.
2. **Restauração precisa funcionar quando não há shell.** Máquina nova, tty de
   recuperação, ssh. Um plugin não alcança esse cenário; um CLI sim.
3. **CLI é testável.** `omabackup verify --json` roda em CI, em cron, num
   container. QML não.

O plugin nunca escreve arquivo nem roda `git` diretamente. Se o CLI não estiver
instalado, o widget mostra "não configurado" e não quebra nada.

---

## 2. Grupos — "o que está sendo salvo"

Manifesto declarativo versionado no repo (`omabackup.groups.json`). Cada grupo
é uma unidade que o usuário liga/desliga e sobre a qual o painel reporta.

| id | label | caminhos | estratégia | crítico |
|----|-------|----------|-----------|:---:|
| `compositor` | Hyprland | `~/.config/hypr/**` | cópia | ● |
| `shell` | Omarchy shell | `~/.config/omarchy/{shell.json,themes}` | cópia | ● |
| `state` | Estado do Omarchy | `~/.local/state/omarchy/{current,toggles,migrations}` | cópia | ● |
| `plugins` | Plugins do shell | `~/.config/omarchy/plugins/**` | tripla (§2.1) | ● |
| `terminal` | Terminal | alacritty, ghostty, kitty, foot, tmux, starship | cópia | |
| `editor` | Editores | nvim, opencode | cópia | |
| `shellrc` | Shell do usuário | `.bashrc`, `.bash_profile`, `.inputrc`, `.XCompose` | cópia | ● |
| `desktop` | Desktop | `.local/share/applications`, `mimeapps.list`, `user-dirs.dirs` | cópia | |
| `scripts` | Scripts pessoais | `~/bin`, `~/.local/bin`, `~/scripts` | só rastreados | |
| `packages` | Pacotes | listas pacman/AUR/explícitos | gerado | ● |
| `systemd` | Serviços | units + enabled lists | gerado | |
| `secrets` | Segredos | allow-list explícita, cifrado com age | allow-list | |

Cada linha no painel mostra: **nº de arquivos · tamanho · última mudança ·
estado** (em dia / com alterações / **não coberto**).

O estado "não coberto" é a inovação: vem do verificador de cobertura (§5.1),
não de comparar com o último commit.

### 2.1 A estratégia tripla dos plugins

Herdada do `sync.sh`, é o detalhe que mais custou a descobrir:

| caso | detecção | o que vai pro backup |
|------|----------|----------------------|
| git limpo | tem `.git/`, `status --porcelain` vazio | só a URL |
| git sujo | tem `.git/`, status sujo | URL + `git diff` como patch |
| local | sem `.git/` | o diretório inteiro |

Sem isso: ou perde-se a customização local (`rosakodu.dock` carrega um
`slotSize: 42 → 56` nosso), ou o repo engorda ~7 MB de código de terceiros.

---

## 3. Destinos

Vários simultâneos, cada um com política própria. **O git é a fonte de verdade
do conteúdo; os demais recebem um bundle derivado dele** — assim não existem
três formatos divergentes para reconciliar depois.

| destino | mecanismo | retenção | observação |
|---------|-----------|----------|------------|
| `github` | `git commit` + `push` | histórico git | padrão; dá diff e blame de graça |
| `gdrive` | `rclone copy` p/ remote | últimos N | remote `GoogleDrive:` **já configurado** nesta máquina |
| `dir` | `cp` p/ caminho (NAS, disco) | últimos N | |
| `removable` | igual `dir`, gatilhado por montagem | últimos N | casa por UUID; badge "aguardando pendrive" |

Bundle = `omabackup-<host>-<YYYYMMDD-HHMMSS>.tar.zst`, contendo um `git bundle`
do repo (histórico completo, clonável) + o worktree em claro (legível sem git)
+ `manifest.json` com versões, grupos e resultado da verificação.

Cada destino guarda: habilitado, último sucesso, último erro, backoff.

Um destino falhando **não** invalida os outros — o painel mostra por destino.

---

## 4. Agenda

Intervalos oferecidos: **5 min · 30 min · 1 h · 6 h · 1 dia · manual**.

Ponto de projeto: **o timer dispara uma _verificação_, não um backup.** Sem
diff, nada acontece — nada de commit vazio, nada de tráfego. É o que torna
"5 min" uma opção sã em vez de uma fábrica de lixo no histórico.

Gatilhos além do timer, em ordem de valor:

1. **Pré-upgrade do Omarchy** — o de maior valor no produto inteiro. Observa
   `~/.local/share/omarchy/version` e/ou engancha em `omarchy-update`; força
   backup **antes** de o upgrade rodar. Ataca a lição nº 2 (o momento de maior
   risco é o de menor atenção).
2. **Pós-mutação de plugin** — depois de `omarchy plugin add/update/remove`.
3. **Ao suspender/desligar** — opcional.
4. **Ao montar o pendrive** configurado.

Backoff exponencial por destino em caso de falha. O badge não some sozinho: um
backup velho fica visível até ser resolvido.

---

## 5. Validação — "confirmar que o dotfile funciona"

Três camadas, custo crescente, cada uma pegando uma classe distinta de falha.

### 5.1 T1 — Cobertura (segundos, roda em todo backup)

Interroga o **sistema vivo** e pergunta se o backup o acompanha:

- Hyprland: qual config foi realmente carregada? O log diz
  `[cfg] Using lua config found at <path>`. Esse caminho está no backup?
- Todo `.lua` sob `~/.config/hypr/` está coberto? Existe `.conf` coberto que já
  **não** é mais lido? (avisa: peso morto)
- `shell.json` presente, JSON válido, `version: 1`?
- Todo plugin retornado por `omarchy-shell shell listPlugins` tem cobertura —
  URL, patch ou cópia?
- Todo pacote de `pacman -Qqe` aparece numa lista?
- Toda unit habilitada aparece nas listas?

**É esta camada que teria pego o incidente de agosto**, no dia do upgrade, sem
VM, sem restore, em menos de um segundo.

### 5.2 T2 — Sintaxe (segundos, roda em todo backup)

Sobre o bundle, não sobre a máquina: `luac -p` nos `.lua`, `jq` nos `.json`,
`bash -n` nos scripts, `omarchy plugin validate` em cada plugin local.

Pega backup capturado no meio de uma escrita, ou config quebrada sendo
propagada como se estivesse boa.

### 5.3 T3 — Restore em VM (minutos, sob demanda / semanal)

Responde "isto sobe do zero?". Artefato separado (`tools/omabackup-verify-vm/`),
não parte do plugin — o plugin só exibe "última verificação em VM: ok, há 3 dias".

**Golden image, construída uma vez.** Três caminhos possíveis, do mais fiel ao
mais barato:

- (a) ISO oficial do Omarchy dirigido por `expect` sobre o configurador — mais
  fiel, mais frágil.
- (b) **Deferred provisioning** — o Omarchy já suporta: um install pode deixar
  `/var/lib/omarchy/provisioning/pending` e o `omarchy-provision-owner.service`
  termina o setup no primeiro boot, na tty1. É o gancho projetado para OEM, e
  serve exatamente aqui.
- (c) `pacstrap` direto num qcow2 usando `install/omarchy-base.packages` +
  `install/` do próprio Omarchy — mais barato, pula o instalador (e portanto
  não testa o instalador; aceitável, não é o que queremos testar).

**Cada execução** é barata porque não reinstala nada:

```
qemu-img create -f qcow2 -b golden.qcow2 -F qcow2 run.qcow2
qemu-system-x86_64 -snapshot ... -virtfs <bundle> ...   # headless
  → unit oneshot: restaura o bundle, roda install.sh
  → assert.sh: quickshell vivo? hyprland subiu? shell.json carregado?
               nº de keybindings esperado? monitores aplicados?
  → grim/screenshot copiado de volta
descarta run.qcow2
```

A golden fica intacta; o overlay é descartável. Sem `libvirt` — só
`qemu-system-x86_64`, que já está instalado nesta máquina.

---

## 6. Segredos

**Allow-list explícita**, não deny-list. Nada entra em `secrets/` sem estar
nomeado no manifesto; hoje são dois arquivos (`rclone.conf.age`,
`khronos.master.key.age`), cifrados com `age`.

Por cima disso, um scanner deny-list roda sobre o bundle **e bloqueia o push**
em caso de achado — não apenas avisa. Falsos positivos conhecidos e inofensivos
(`--password-store=gnome-libsecret`, `hide_token_restore`, `source` condicional
no `.bashrc`) vão para uma allow-list de exceções versionada, com justificativa.

Motivo de ser bloqueante: vazamento é irreversível, e "só avisa" é exatamente
o modo de falha da lição nº 1 (aviso que ninguém lê).

---

## 7. Robustez do plugin

Requisitos derivados do crash observado (um erro de QML em *outro* plugin
derrubou o `quickshell` inteiro e nada relançou):

- try/catch em toda fronteira; nada pesado em `Component.onCompleted`
- zero I/O síncrono no QML — só `Quickshell.Io.Process`
- degradação: CLI ausente → widget em "não configurado", sem exceção
- `shell.json` muda debaixo do backup (plugins escrevem nele sozinhos): o CLI
  compara hash antes/depois e relê se divergiu
- convenção de settings inconsistente entre plugins (`rosakodu.dock` usa
  `settings:{}` aninhado, `argus` usa chaves soltas) → capturar o arquivo
  inteiro, nunca reconstruí-lo campo a campo

---

## 8. Decisões que este documento fecha (e que a revisão deve atacar)

| # | pergunta da §5 do contexto | decisão |
|---|---------------------------|---------|
| 1 | git ou tarball? | **git como fonte de verdade + bundle derivado** para os demais destinos |
| 2 | só Omarchy ou dotfiles gerais? | **dotfiles gerais**, organizados em grupos ligáveis; o escopo estreito não resolve a dor real |
| 3 | deny-list ou allow-list de segredos? | **allow-list**, mais scanner deny-list **bloqueante** |
| 4 | `/etc` também? | **não** — o plugin nunca pede sudo; `/etc/sudoers.d` continua sendo só um aviso |
| 5 | onde o trabalho roda? | **CLI externo**; o plugin é UI e agendador |
| 6 | como confirmar que funciona? | **três camadas**: cobertura (sempre) · sintaxe (sempre) · VM (semanal/sob demanda) |
| 7 | symlink (stow) ou cópia? | **híbrido** — link no que só o usuário edita, cópia no que o Omarchy reescreve (§10) |

---

## 9. Riscos conhecidos, não resolvidos

- **Golden image envelhece.** Uma VM construída em agosto testa restore contra
  um Omarchy de agosto. Precisa de política de rebuild.
- **Nada disso ajuda se o usuário desabilitar o plugin.** O CLI + timer systemd
  sobrevive; o plugin não. Talvez o systemd timer seja o mecanismo primário e o
  plugin apenas a cara dele.
- **5 min de intervalo com git** ainda gera muitos commits em dia de trabalho
  pesado em dotfiles, mesmo com a checagem de diff. Squash automático? Branch
  separado?
- **Restauração seletiva** (o item mais pedido da §5 do contexto) está esboçada
  como grupos, mas restaurar *um grupo* sobre um sistema vivo pode deixar o
  sistema em estado misto e inconsistente.

---

## 10. Arte prévia: `omadot`, e a pergunta symlink vs. cópia

[`tomhayes/omadot`](https://github.com/tomhayes/omadot) — wrapper fino de GNU
Stow para Omarchy (56 stars, último push 2026-04-27, sem licença). Dois verbos:
`get <pkg>` move `~/.config/<pkg>` para `~/.dotfiles/<pkg>/.config/<pkg>` e
symlinka de volta; `put <pkg>` refaz o stow numa máquina nova.

O que ele **não** faz e o OmaBackup precisa fazer: agenda, lembrete, destinos
(o git é manual; não há Drive/pendrive/diretório), verificação de qualquer
espécie, e qualquer consciência do Omarchy 4 (`shell.json`, a estratégia tripla
de plugins, `.lua` vs `.conf` inerte).

O que ele acerta, e vale roubar: **elimina o passo de sync.** Se
`~/.config/nvim` *é* o repo, não existe `sync.sh` para alguém esquecer de
rodar. Isso ataca a lição nº 1 na raiz, estruturalmente, em vez de com um
lembrete.

### O experimento que decide a questão

O modelo do stow só vale se os escritores do sistema respeitarem o link.
Medido nesta máquina, em ambiente isolado:

| escritor | mecanismo | symlink sobrevive? |
|----------|-----------|:---:|
| Quickshell `FileView { atomicWrites: true }` (`shell.qml:130`) | grava através do link | **sim** |
| `omarchy-shell-config` → `commit()` (`mktemp` + `mv`) | substitui o inode | **não** |

O segundo é o que sustenta `omarchy bar move`, `omarchy bar set` e
`omarchy plugin enable/disable`. Um `shell.json` sob stow é silenciosamente
desconectado do repo **na primeira vez que se move um widget na barra** — e o
sintoma é exatamente o de agosto: backup verde, conteúdo obsoleto.

### Decisão: híbrido, com o modo de falha tornado visível

- **Symlink (stow)** para o que só o usuário edita: `nvim`, `bashrc`,
  `alacritty`, `ghostty`, `tmux`, `starship`, `.XCompose`. Sem passo de sync.
- **Cópia** para o que o próprio Omarchy reescreve: `shell.json`, `hypr/*.lua`,
  `~/.local/state/omarchy/`, e tudo que é gerado (listas de pacotes, units).
  `plugins/` **não** é cópia rsync — mantém a estratégia tripla da §2.1; foi
  assim que a primeira versão do `sync.sh` se atropelou.
- O manifesto de grupos (§2) ganha uma coluna `mode: link | copy`.
- **A verificação T1 (§5.1) passa a checar integridade de link**: todo caminho
  declarado `mode: link` ainda é um symlink apontando para o repo? Deixou de
  ser → alerta vermelho no painel, com o comando de reparo.

Isso converte a falha silenciosa característica do stow numa falha visível, que
é o objetivo do produto inteiro.

Nota: `stow` **não está instalado** nesta máquina. Se o modo link for adotado,
ou entra como dependência, ou o CLI faz `ln -s` por conta própria — o layout de
diretórios do stow é simples o bastante para não justificar a dependência.

---

## 11. Resultado da revisão (dual-r, 2026-08-24)

Duas lentes independentes e cegas uma à outra — `gpt-5.6-sol`/xhigh via
AgentRelay (modelo comprovado por `codex-argv:-m`) e `dual-opus-reasoner`
nativo (`model: opus`, `effort: max`; versão numerada não comprovada pelo
harness). Todo P0/P1 solo foi verificado no código antes de entrar aqui.

### 11.1 O laço circular (P0)

A §4 dizia: *o timer dispara uma verificação, não um backup; sem diff, nada
acontece.* Isso funciona para grupos em modo `link`, onde o arquivo vivo **é** o
repo. Para grupos em modo **`copy`** — `shell.json`, `hypr/*.lua`, plugins, os
críticos — não existe diff algum enquanto ninguém copiou. O ciclo se fecha em si
mesmo: sem coleta → sem diff → sem backup → sem coleta.

**Correção — o ciclo tem quatro tempos:**

```
collect  → staging em ~/.local/state/omabackup/staging (rsync, sem tocar no repo)
diff     → staging vs. worktree do repo, normalizado (jq -S nos .json)
verify   → T1 cobertura + T2 sintaxe sobre o staging
commit   → só se o diff for não-vazio E a verificação passar
```

Normalizado porque os dois escritores do `shell.json` serializam diferente —
`omarchy-shell-config` usa `jq -S` (chaves ordenadas), o Quickshell usa
`JSON.stringify(payload, null, 2)` (ordem de inserção). Sem normalizar, trocar
um widget de lugar reescreve o arquivo inteiro no diff.

### 11.2 O que muda de decisão

| § | Decisão v0 | Decisão v1 | Por quê |
|---|-----------|-----------|---------|
| 1 | plugin agenda, CLI executa | **systemd timer é primário**; o plugin é só a cara e um botão | `omarchy-update-restart:51` roda `omarchy-restart-shell` no fim de todo update: o agendador morre no evento que existe pra vigiar |
| 1 | estado no shell | estado em `~/.local/state/omabackup/` | restaurar `shell.json` de ontem **desabilita o próprio OmaBackup** — plugin de terceiro está ativo sse seu id aparece no `shell.json`, e não há deep-merge |
| 4 | watcher em `~/.local/share/omarchy/version` | **descartado** | é symlink pra `/usr/share/omarchy`; muda só depois que o pacman trocou o pacote, e reporta `4.0.0.alpha` enquanto `omarchy-version` reporta `4.0.0-1` |
| 4 | gatilho pré-upgrade via hook | **não existe hook pre-update** | `omarchy-update:47-49` = pacotes → migrações → `omarchy-hook post-update`. Os hooks disponíveis são battery-low, font-set, post-boot, post-update, pre-refresh-pacman, theme-set |
| 5.1 | probes por diretório conhecido | **resolução transitiva** | `~/.local/state/omarchy/toggles/hypr/flags.lua` e `current/theme/hyprland.lua` são Lua vivo fora do escopo declarado, carregados via `package.path` |
| 5.1 | cobertura de plugin via `listPlugins` | dirigida pelo **diretório**, `listPlugins` só enriquece | `listPlugins` inclui first-party (ruído permanente) e omite plugin com manifest inválido — justo o que mais precisa de backup |
| 5.3 | golden via deferred provisioning | **pacstrap** é o único caminho não-interativo | `omarchy-provision-owner:551` bloqueia em `read -r -t 0.2 _ </dev/tty` dentro de `while true`, e a seguir pede username/senha/hostname/timezone em `gum` |
| 6 | scanner sobre o bundle | scanner sobre **`git log -p --all`** também | o bundle carrega o histórico completo; um segredo commitado e removido depois viaja em todo backup sem passar pelo scanner |
| 10 | `mode: link|copy` por arquivo | por arquivo **+ teste de propriedade por release** | a sobrevivência do symlink é por-escritor, não por-arquivo: `omarchy-shell-config:59` usa `mv` (destrói), a migração `1785189600.sh:53` usa `cat >` com o comentário explícito *"so a tmux.conf symlinked out of a dotfiles repo keeps pointing where it pointed"* (preserva) |
| 10 | "alerta vermelho com o comando de reparo" | **copiar-o-vivo-pro-repo, então relinkar** | o reparo ingênuo (`ln -sf`) apaga exatamente a edição que quebrou o link |

### 11.3 Bug no `sync.sh` de hoje (não é só design)

`sync.sh:157` decide que um plugin está sujo com `git status --porcelain`, mas
`sync.sh:161` grava o patch com `git diff` — que **não inclui staged nem
untracked**. Provado por construção:

```
status --porcelain : M  Widget.qml ?? Helper.qml
git diff           : 0 linhas   ← o que vai pro patch
git diff HEAD      : 7 linhas
```

O plugin é marcado "git + patch local" com um patch vazio. Correção:
`git diff HEAD` mais captura explícita dos untracked
(`git ls-files --others --exclude-standard`).

E o manifesto guarda só `id url`, sem commit. Se o upstream avançar, o restore
instala outro código e o patch não aplica. Precisa de SHA.

### 11.4 O problema do ovo e da galinha nos destinos

`bootstrap.sh:19-26` decifra `secrets/rclone.conf.age` **de dentro do repo
clonado**. Ou seja: o Google Drive só é alcançável depois de você já ter o repo
do GitHub. Se o GitHub for o que você perdeu, a credencial pra baixar o bundle
do Drive está dentro do bundle do Drive.

Consequência para a §3: cada destino precisa ser **restaurável a partir apenas
do seu próprio identificador**, e a T3 precisa exercitar um destino diferente a
cada rodada (par = bundle local, ímpar = clone do remote, e assim por diante),
exigindo que todos tenham passado nos últimos N dias antes de o painel ficar
verde. Caminho não exercitado não funciona.

Relacionado: o grupo `secrets` usa `age -p` (passphrase interativa,
`secrets/README.md:13`). Nenhum timer consegue atualizá-lo. Ou vira
`age -R recipients.txt` — e aí a chave privada precisa de uma história de
custódia que este doc não tem — ou é explicitamente manual, com data de
validade visível no painel.

### 11.5 O gatilho pré-upgrade, agora que se sabe que o hook não existe

Três opções, nenhuma limpa:

1. **Pacman hook `PreTransaction` em `Target=omarchy`** — é o único ponto
   genuinamente anterior à mutação. Exige root uma vez, o que colide com a
   decisão §8 nº 4 ("o plugin nunca pede sudo"). A colisão é entre *instalar*
   com sudo uma vez e *rodar* com sudo sempre; só a segunda é o que a regra do
   Omarchy proíbe.
2. **Wrapper/alias em `omarchy update`** — contornável por qualquer outra rota
   (`pacman -Syu` atualiza o pacote `omarchy` direto).
3. **`snapper -c home create`** — `omarchy-update:36` já roda
   `omarchy-snapshot create` **antes** dos pacotes; `/` e `/home` são btrfs e o
   snapper está instalado. Barato, local, e não substitui o off-site.

E mesmo um gatilho perfeito não cobre tudo: migrações também rodam **no login**
e por retry (`omarchy-migrate:79`), desacopladas do `omarchy update`. Um
`pacman -Syu` comum atualiza o pacote; as migrações reescrevem `input.lua` e
`bindings.lua` no login seguinte sem nenhum gatilho disparar. O probe certo é
`omarchy-migrate --pending` dentro do T1.

### 11.6 Restauração seletiva: bloqueada até haver grafo

Três razões independentes, qualquer uma bastando:

1. **Lua não degrada, aborta.** `hyprland.lua:14-26` tem seis `require` de topo,
   nenhum protegido por `pcall`. Restaurar só o grupo `compositor` com um
   `looknfeel.lua` que referencia algo que o grupo `state` traria → erro em
   `require` → bindings, autostart e toggles não carregam. O `.conf` antigo era
   tolerante linha a linha; o Lua não é.
2. **Restaurar `shell` desliga o OmaBackup** (§11.2).
3. **Marcadores de migração.** São 439 em `~/.local/state/omarchy/migrations`.
   Sem eles, o restore roda todas as migrações contra a config recém-restaurada.
   Com eles, migrações legítimas da versão nova são puladas pra sempre.

### 11.7 A metade que faltava do invariante

A §0 define cobertura numa direção só: *o backup contém o que o sistema lê?*
Falta a simétrica: *o backup contém **apenas** isso?* O repo já é a prova —
`configs/hypr.backup/`, `configs/waybar.backup/`, `configs/walker.backup/`,
os `.bak` do Quattro, `.user.system-monitor.bak.20260820042654/`. Um bootstrap a
partir daqui hoje ressuscita tudo isso.

O incidente de agosto foi **as duas metades ao mesmo tempo**: `.conf` presentes
e mortos + `.lua` ausentes. O design v0 só endereçava a segunda.

E uma terceira, que o Sol levantou e é a mais desconfortável: **cobertura não é
equivalência semântica.** Depois do upgrade, os `hyprland.lua` gerados eram
templates vazios porém válidos. Copiá-los deixaria a T1 verde com zero
customização preservada. A T1 precisa comparar contra o *último estado
conhecido-bom*, não só contra a existência do caminho.

---

## 12. Decisões v2 — o alcance de restauração substitui a corrida contra o upgrade

Três decisões tomadas depois da revisão. A segunda reorganiza o produto.

### 12.1 O OmaBackup declara o que sabe restaurar; não persegue o upgrade

**Decisão:** manter o backup sempre atualizado (o ciclo de quatro tempos da
§11.1 dá isso) e mover a garantia de segurança do *momento da captura* para o
*momento da restauração*. O OmaBackup declara um conjunto de versões-alvo que
sabe restaurar — hoje Omarchy 3.x e 4.x. Numa máquina fora desse conjunto, ele
**não tenta**.

O que isso resolve, e é muito:

- A §11.5 (gatilho pré-upgrade) deixa de ser o item de maior valor do produto e
  vira conveniência. Não é preciso hook `PreTransaction`, não é preciso sudo,
  não é preciso interceptar `omarchy-update`, e a decisão §8 nº 4 ("o plugin
  nunca pede sudo") deixa de estar em conflito com nada.
- O modo de falha de agosto passa a ser impossível **por construção**: um backup
  no formato `.conf` restaurado num Omarchy que lê `.lua` é recusado com motivo,
  em vez de aplicado e descoberto quebrado horas depois.
- O aviso "vem upgrade aí" não precisa de gancho: `omarchy-update-available` já
  é um poll. O widget passa a dizer *"há upgrade disponível e ele te leva pra
  fora do alcance que o OmaBackup sabe restaurar"* — informativo, nunca
  bloqueante.

O que isso custa: o produto pode se recusar a ajudar justamente no dia mais
difícil (máquina nova com Omarchy 5.x, backup de 4.x). O pagamento é a §12.2.

### 12.2 Eixo novo: acoplamento de versão

Mais importante que `link` vs `copy`. Determina o que sobrevive a uma versão
desconhecida.

| grupo | acoplado ao Omarchy? | por quê |
|-------|:---:|---------|
| `compositor` | **sim** | o formato mudou de `.conf` pra `.lua` no 3→4 |
| `shell` | **sim** | schema `version: 1`, ids de widget, convenção de settings |
| `plugins` | **sim** | API do Quickshell e do `PluginRegistry` |
| `state` | **sim** | toggles, tema ativo, marcadores de migração |
| `terminal` | não | alacritty, ghostty, tmux e starship não sabem o que é Omarchy |
| `editor` | não | idem |
| `shellrc` | não | idem |
| `desktop` | não | freedesktop, não Omarchy |
| `scripts` | não | scripts próprios |
| `packages` | parcial | nomes de pacote mudam devagar; falha é visível e reparável |
| `systemd` | parcial | idem |

Numa máquina fora do alcance, o restore **aplica os desacoplados e põe os
acoplados em quarentena**, com relatório do que ficou de fora e onde está.
Você recupera shell, editor, terminal, scripts e pacotes — a maior parte do dia
a dia — e reconstrói a mão só a config do desktop, que é o que mudou de formato.

Isso também dá o corte que faltava na §11.6: existe uma fronteira **de
princípio** para restauração parcial (acoplado vs. desacoplado), em vez de um
grafo inventado. Dentro do bloco acoplado continua tudo-ou-nada — a cadeia de
`require` sem `pcall` não admite meio-termo.

### 12.3 Identidade de compatibilidade: o marcador de migração, não a string de versão

O bundle grava três coisas:

| campo | fonte | exemplo |
|-------|-------|---------|
| versão | `omarchy-version` | `4.0.0-1` |
| canal | `omarchy-channel-current` | `stable` |
| **marca-d'água de migração** | maior nome em `~/.local/state/omarchy/migrations` | `1786643346` (2026-08-13) |

A marca-d'água é o identificador melhor: são timestamps unix, ordenam sem
ambiguidade, e nesta máquina existem 439 deles cobrindo de 2025-06-28 a
2026-08-13 (contra apenas 78 migrações ainda presentes no pacote — o pacote poda,
o estado acumula).

Ela resolve a pergunta que a §11.6 tinha deixado em aberto:

| situação | o que fazer com os marcadores |
|----------|-------------------------------|
| alvo == origem | restaurar os marcadores: o estado de migração é idêntico |
| alvo > origem, dentro do alcance | **não** restaurar: deixar `omarchy-migrate` correr pra frente — é exatamente para isto que ele existe |
| alvo fora do alcance | não restaurar nada do bloco acoplado |

### 12.4 O que a verificação afirma — e o que vira nota

**Decisão:** o assert verifica que **o arquivo de config está presente e
íntegro**. Hardware não é objeto de teste.

Monitores, rotação, EDID e modos viram uma **nota** no painel — "esta máquina
tinha 3 monitores, o ASUS com `transform 3`" — informação para o humano
conferir depois do restore, nunca um assert que falha.

A consequência honesta: **isso esvazia o caso de uso do QEMU.** Se o assert é
"os arquivos estão no lugar e fazem parse", não é preciso bootar um sistema —
um container Arch descartável faz o mesmo em segundos:

```
podman run --rm -v bundle:/b:ro archlinux \
  → restaura em $HOME falso → luac -p, jq, bash -n, omarchy plugin validate
  → confere: todo caminho que o T1 declarou coberto chegou lá?
```

A VM só volta a valer se um dia quisermos afirmar "o compositor subiu" — o que
a decisão acima diz explicitamente que não é o objetivo. Então a §5.3 encolhe
para **T3 = container** e o QEMU sai do caminho crítico; se for construído, é
com `pacstrap` (§11.2), nunca com deferred provisioning.

---

## 13. Correção da §12.4 — o container não substitui a VM

A §12.4 concluiu que, se o assert é "o arquivo está presente e faz parse", não
haveria por que bootar um sistema. **Está errado**, e a decisão §12.1 (alcance
de restauração) torna o erro pior, não menor.

Duas necessidades distintas foram coladas numa só:

| | pergunta | quem responde | quem lê |
|---|---|---|---|
| **T3** | os arquivos chegaram e fazem parse? | container | máquina |
| **T4** | isto vira um desktop que funciona? | **VM** | **humano** |

O container responde a primeira. Não responde a segunda, e sobretudo **não
deixa ver**. O incidente de agosto passaria por T3 com nota máxima: os `.lua`
gerados eram válidos, parseavam, estavam no lugar. O que faltava só aparecia
olhando a tela.

### 13.1 Por que a §12.1 aumenta a necessidade da VM

A tabela de alcance (`supported_targets = ["3.*", "4.*"]`) é uma **afirmação que
precisa ser ganha**, não uma constante. Duas perguntas dependem dela e nenhuma
tem resposta analítica:

1. **Como se acrescenta `5.x` à lista?** Bootando um Omarchy 5.x, restaurando o
   bundle e olhando o resultado. Não há outro jeito honesto.
2. **O recorte da quarentena (§12.2) está certo?** "Estes 7 grupos são
   independentes de versão" é hipótese. Se `ghostty` ou algum `.desktop` acabar
   dependendo de algo que o Omarchy 5 mudou, quem descobre é a VM.

Ou seja: a VM deixa de ser um teste de regressão semanal e passa a ser **o
mecanismo pelo qual o alcance de restauração é estendido**. Roda uma vez por
release maior do Omarchy, com humano no circuito — frequência baixa, valor alto.

### 13.2 Como o usuário vê

`screendump` do QMP, medido nesta máquina (QEMU 11.1.0):

```
{"execute":"screendump","arguments":{"filename":"/out/tela.ppm"}}
→ {"return": {}}
```

Propriedade decisiva: **a captura vem do lado do host, sem cooperação do
convidado.** Verificado bootando uma VM sem disco — o convidado não subiu e a
captura saiu mesmo assim, mostrando a tela de falha de boot. Se o Hyprland não
levantar depois do restore, você vê *a tela de erro*, não um arquivo vazio.

Um `grim` dentro do convidado não teria essa propriedade: desktop quebrado,
nenhuma captura, nenhum diagnóstico — cego exatamente quando importa.

O ciclo:

```
qemu-img create -f qcow2 -b golden-<versão>.qcow2 -F qcow2 run.qcow2
qemu-system-x86_64 -display none -qmp unix:/tmp/qmp.sock -vnc :1 \
  -virtfs local,path=<bundle>,mount_tag=oma,security_model=mapped-xattr ...
  → unit oneshot: restaura o bundle, roda install.sh, chega no SDDM/Hyprland
  → QMP screendump → tela.png
  → T3 (container) já rodou antes; aqui a saída é a IMAGEM, não um exit code
```

O `-vnc :1` fica aberto: quando a imagem parada não bastar, você entra e clica.

### 13.3 O que a VM entrega — e o que continua não sendo assert

Coerente com a decisão §12.4 sobre hardware: **a captura não é um assert.** Não
existe comparação de pixels, não existe "falhou porque mudou". É **evidência que
um humano olha** — a mesma categoria da nota sobre monitores.

O painel ganha, ao lado dos tiers:

- miniatura da última captura
- versão-alvo em que ela foi tirada
- data
- e, quando a versão-alvo está fora do alcance atual, o botão que promove essa
  versão para `supported_targets` — a decisão fica registrada com a imagem que a
  justificou

### 13.4 Custo, honestamente

Voltam a ser necessários: uma golden image por versão de Omarchy que se queira
suportar, e a construção dela (`pacstrap`, §11.2 — deferred provisioning
continua fora, bloqueia em formulário `gum`). O que **não** volta é a frequência:
T3 em container roda todo dia, sozinho; T4 em VM roda quando sai um Omarchy novo
ou quando você está inseguro. A §12.4 estava certa em tirar a VM do caminho
crítico — errada em tirá-la do produto.
