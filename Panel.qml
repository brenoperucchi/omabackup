import QtQuick

// Placeholder until stage 5.
Item {
  id: root
  property var shell: null
  property var manifest: null
  property bool opened: false
  function open(payloadJson) { root.opened = true }
  function close() { root.opened = false }
}
