# OmaBackup

Backup de dotfiles para Omarchy 4 que responde a uma pergunta diferente da
usual. Não *"o backup está íntegro?"* — o `hyprland.conf` de agosto de 2026
estava íntegro, válido e completo, e por isso mesmo inútil quando o Hyprland
passou a ler `.lua`. A pergunta é:

> **O backup contém os arquivos que este sistema, agora, de fato lê?**

E a segunda, que decide se restaurar é seguro:

> **Esta máquina está numa versão que o OmaBackup sabe restaurar?**

## Estado

Etapa 1 de 6. Funciona hoje: `status`, `collect`, `verify`.

```bash
./bin/omabackup status     # versão do Omarchy, alcance, grupos
./bin/omabackup collect    # coleta os grupos para o staging
./bin/omabackup verify     # checa cobertura; --json para consumo programático
./test/run.sh              # 18 specs
```

O plugin QML (`Service.qml`, `BarWidget.qml`, `Panel.qml`) é placeholder até a
etapa 5 — carrega sem ocupar espaço na barra e sem poder derrubar o shell.

## Como funciona

O ciclo tem quatro tempos, e o primeiro não é opcional:

```
collect → staging   diff → contra o repo   verify → cobertura + sintaxe   commit
```

Sem `collect` não existe diff para grupos em `mode: copy` — e um agendador que
só dispara `verify` nunca salvaria `shell.json` nem `hypr/*.lua`.

### O manifesto de grupos

`groups.default.json` descreve o que é salvo, em três eixos:

| eixo | valores | decide |
|------|---------|--------|
| `mode` | `link` · `copy` · `gen` · `triple` | como capturar |
| `coupled` | `true` · `false` | se entra em quarentena num Omarchy fora do alcance |
| `critical` | `true` · `false` | peso no relatório |

`link` é para o que só você edita (o arquivo vivo *é* o repo, sem passo de
sync). `copy` é para o que o Omarchy reescreve. `triple` é só para os plugins:
git limpo grava URL+commit, git sujo grava também o patch, sem remote vira
cópia integral. Sem isso o staging engordaria 6,6 MB de código que já vive no
GitHub — ou perderia a customização local.

**Um campo declarado que o coletor não implementa aborta o `collect`.** Falhar
alto é o ponto: as três primeiras versões ignoraram `exclude`, `trackedOnly` e
`mode: triple` em silêncio, e o staging foi de 1,3 MB para 84 MB sem avisar.

### Cobertura (T1)

A sonda do compositor resolve o grafo de `require` a partir do arquivo que o
Hyprland *diz* ter carregado, atravessa os módulos do pacote e cobra cobertura
só dos arquivos do usuário. É assim que `~/.local/state/omarchy/toggles/hypr/flags.lua`
aparece — Lua vivo fora de `~/.config/hypr`, que uma varredura por diretório
não acharia.

Exclusões deliberadas ficam em `excluded[]`, cada uma com o motivo versionado
junto. Um verificador que nasce com uma dúzia de avisos ensina a ser ignorado.

## Projeto

O desenho, a revisão que o derrubou duas vezes e as decisões estão em
[`docs/DESIGN.md`](docs/DESIGN.md).

## Licença

MIT
