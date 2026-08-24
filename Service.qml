import QtQuick

// Placeholder da etapa 5. Nada pesado em Component.onCompleted, nenhum I/O
// síncrono: um erro aqui derruba o quickshell inteiro — barra, dock e menu.
// O agendamento de verdade vive num systemd timer, não aqui (design §11.2).
Item {
  id: root
  property var shell: null
  property var manifest: null
  property var settings: ({})
}
