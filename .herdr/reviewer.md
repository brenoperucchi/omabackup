# OmaBackup

CLI + plugin QML pra backup dos dotfiles do usuário (Omarchy/Hyprland). Design
recente e ainda em movimento (`docs/DESIGN.md`, 2026-08-24) — **confira
`docs/PLAN.md` antes de assumir que algo abaixo já está implementado**; isso
aqui são invariantes de design, não garantia de que o código atual as cumpre.

## Isolamento

Você é a única lente nesta rodada (a outra roda em paralelo, cega, num
diretório irmão — ver `request.md`). Não invoque skills de revisão
multi-agente (`dual-r`, `tri-r`, `pair-i`, `codex-r`, `codex-i`) nem delegue
via subagente/`agentrelay`/`dispatch`. Se faltar informação, diga o que
faltou — não busque segunda opinião pra preencher a lacuna.

## Separação de repositório — sempre verdade, independente de implementação

- `~/Devs/omabackup` (este repo) é **só código**, público, GitHub. Dado de
  backup nunca entra aqui.
- `~/Devs/omarchy-personal` é o dotfiles real do usuário — privado, é o
  `OMABACKUP_REPO`. Código do OmaBackup nunca entra lá.

## Invariantes de design (violação é achado, se o código já implementa isso)

1. **Plugin nunca escreve arquivo nem roda `git` direto.** A CLI (`omabackup`
   em `~/.local/bin`) faz o trabalho pesado; o plugin QML é só UI/scheduler.
   Zero I/O síncrono em QML — só `Quickshell.Io.Process`. Se a CLI não estiver
   instalada, o widget mostra "not configured", nunca lança exceção.

2. **Secrets: allow-list explícita, nunca deny-list solto.** Nada entra em
   `secrets/` sem estar nomeado no manifest. Um scanner deny-list roda sobre o
   bundle e **bloqueia o push** num hit (não é warning) — inclusive sobre
   `git log -p --all`, porque um segredo commitado e depois removido ainda
   viaja no histórico do bundle.

3. **Estratégia tripla pra grupo `plugins`.** git limpo → só a URL; git sujo →
   URL + patch; sem `.git` → diretório inteiro. **Bug real já achado aqui**
   (revisão de 24/08): `sync.sh` decidia "sujo" via `git status --porcelain`
   mas gerava o patch com `git diff` (sem staged nem untracked) — patch vazio
   marcado como "git + local patch". Fix correto é `git diff HEAD` +
   `git ls-files --others --exclude-standard`. Confirme se isso já foi
   corrigido antes de reportar de novo.

4. **`mode: link` vs `mode: copy` por grupo, não por arquivo inteiro.** Link
   (stow) só pro que o usuário edita (nvim, bashrc, terminal). Copy pro que o
   Omarchy reescreve (`shell.json`, `hypr/*.lua`, `~/.local/state/omarchy/`).
   `plugins/` nunca é rsync puro — usa a estratégia tripla do item 3. A
   sobrevivência do link é **por escritor, não por arquivo**: `mv` destrói o
   link, `cat >` preserva — não assuma qual é qual sem checar o writer real.

5. **Ciclo de 4 batidas, não diff direto no repo.** `collect` (staging via
   rsync, repo intocado) → `diff` (staging vs. worktree, normalizado — ex:
   `jq -S` porque dois escritores de `shell.json` serializam diferente) →
   `verify` (T1 coverage + T2 syntax sobre o staging) → `commit` (só se diff
   não-vazio E verificação passa). Isso substitui um design anterior com loop
   circular (P0 já corrigido): sem staging, "o timer só dispara um check" vira
   "nada nunca é coletado, logo nunca há diff, logo nunca há backup".

6. **Faixa de restauração declarada, não corrida contra o upgrade.** OmaBackup
   declara versões-alvo que sabe restaurar (hoje: Omarchy 3.x e 4.x). Fora da
   faixa, não tenta. Eixo que decide isso: grupos "acoplados à versão"
   (compositor, shell, plugins, state — formato muda entre versões do
   Omarchy) vs. "não-acoplados" (terminal, editor, shellrc, desktop, scripts,
   packages) — restauração fora da faixa aplica só os não-acoplados e
   quarentena o resto, nunca mistura.

7. **T1/T2/T3/T4 são camadas com perguntas diferentes**, não uma escada de
   redundância: T1 = a config presente bate com o que o sistema *lê agora*
   (coverage, segundos); T2 = sintaxe do bundle; T3 = container, "os arquivos
   chegam e parseiam?"; T4 = VM com captura de tela via QMP `screendump` do
   lado do host, "isso vira uma área de trabalho de verdade?" — só T4
   responde essa última, e só um humano lê o resultado (não é assert
   automático).

## Workflow de bug fix (do `AGENTS.md`)

Reproduzir com spec de regressão permanente antes de corrigir (falha antes,
passa depois), manter no suite, rodar `./test/run.sh` antes de considerar
concluído.
