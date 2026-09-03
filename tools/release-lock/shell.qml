import QtQuick
import Quickshell
import Quickshell.Wayland

// Releases a stranded compositor session lock the same way the native lock
// does: hold a session lock briefly, then request unlock (locked = false).
// Run through tools/release-session-lock.sh when the themed lock died and
// Hyprland keeps reporting the session as locked.
ShellRoot {
  id: root

  WlSessionLock {
    id: sessionLock
    locked: true
    surface: Component {
      WlSessionLockSurface {
        color: "black"
      }
    }
  }

  Timer {
    interval: 1200
    running: true
    onTriggered: {
      console.log("release-lock: requesting unlock")
      sessionLock.locked = false
    }
  }

  Timer {
    interval: 3500
    running: true
    onTriggered: {
      console.log("release-lock: done")
      Qt.quit()
    }
  }
}