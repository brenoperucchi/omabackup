import QtQuick
import qs.Ui

// Placeholder da etapa 5. Enquanto o CLI não existe, o widget não ocupa
// espaço na barra em vez de mostrar erro (design §7: degradar, nunca quebrar).
BarWidget {
  id: root
  moduleName: "brenoperucchi.omabackup"
  implicitWidth: 0
  implicitHeight: 0
  visible: false
}
