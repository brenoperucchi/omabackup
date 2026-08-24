import QtQuick

// Placeholder until stage 5. Nothing heavy in Component.onCompleted, no
// synchronous I/O: an error here takes down the whole quickshell process --
// bar, dock and menu at once. Real scheduling lives in a systemd timer, not
// here (docs/DESIGN.md §11.2).
Item {
  id: root
  property var shell: null
  property var manifest: null
  property var settings: ({})
}
