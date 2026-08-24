import QtQuick
import qs.Ui

// Placeholder until stage 5. While the CLI does not exist the widget takes up
// no room in the bar instead of showing an error (docs/DESIGN.md §7: degrade,
// never break).
BarWidget {
  id: root
  moduleName: "brenoperucchi.omabackup"
  implicitWidth: 0
  implicitHeight: 0
  visible: false
}
