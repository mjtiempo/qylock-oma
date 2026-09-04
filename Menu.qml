// mark.lock-themes — Theme manager menu
//
// Summon with:  omarchy-shell shell summon mark.lock-themes '{}'
// (or bind it, e.g. SUPER+SHIFT+L -> omarchy-shell shell summon mark.lock-themes '{}')
//
// Square, centered theme picker with two tabs:
//   · Lock & SDDM — clicking a theme applies it to BOTH the lock screen and
//     the SDDM login screen (one action, one Polkit prompt).
//   · Background  — clicking a theme applies its artwork to the Omarchy
//     lock/wallpaper background.
// All work happens in Service.qml (same plugin); this menu writes requests to
// ~/.local/state/omarchy/mark.lock-themes/request.json and mirrors
// status.json / themes.json.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "mark.lock-themes"
  readonly property string homeDir: Quickshell.env("HOME") || "/root"
  readonly property string stateDir: homeDir + "/.local/state/omarchy/" + pluginId
  readonly property string statusFile: stateDir + "/status.json"
  readonly property string themesFile: stateDir + "/themes.json"
  readonly property string requestFile: stateDir + "/request.json"
  readonly property string configFile: stateDir + "/config.json"

  // ------------------------------------------------------------- lifecycle
  property bool opened: false
  // "lock" = Lock & SDDM tab, "background" = Background tab.
  property string tab: "lock"
  // ⚙ lock-provider panel (repo themed lock vs native Omarchy lock).
  property bool providerPanelVisible: false
  // Grid name search (both tabs) — filters as you type.
  property string searchText: ""
  onSearchTextChanged: root.recomputeGrid()

  function open(payloadJson) {
    root.opened = true
    Qt.callLater(root.refreshNow)
  }

  function close() {
    root.opened = false
    root.providerPanelVisible = false
    root.searchText = ""
  }

  function refresh() {
    root.refreshNow()
    return "ok"
  }

  function ping() {
    return "ok"
  }

  // ---------------------------------------------------- mirrored service state
  property string phase: "idle"
  property string message: "Loading…"
  property bool busy: false
  property int themeCount: 0
  property string currentSddm: ""
  property string currentLock: ""
  property string currentBg: ""
  property bool liveRendererPresent: false
  property bool lockAppInstalled: false
  property bool themedLockActive: false
  property string lockMode: "themed"
  property double recoveredNativeAt: 0
  property var themeList: []
  // Tab-filtered grid view: built-in wallpapers only make sense in the
  // Background tab — the Lock & SDDM tab shows catalog themes only.
  property var gridThemes: []
  onTabChanged: root.recomputeGrid()

  // ---------------------------------------------------------------- styling
  property color surface: Color.menu.background
  property color foreground: Color.menu.text
  property color muted: Util.alpha(Color.menu.text, 0.66)
  property color accent: Color.accent
  property color scrim: Color.menu.scrim
  property color cardBorder: Color.menu.border

  property int padding: Style.spacing.panelPadding
  property int gap: Style.spacing.md
  readonly property int columns: 4
  property int cardWidth: Math.min(Style.space(808), panel.width - Style.gapsOut * 2)
  // Centered card sized to its content: three full theme rows, symmetric
  // margins (content anchors center, so no bottom-heavy black area).
  // Reserved header/footer heights matched to their actual content so the
  // card hugs the UI with no extra blank bands top or bottom.
  readonly property int headerBlock: Style.space(160)
  readonly property int footerBlock: Style.space(40)
  readonly property int tileGap: Style.space(14)
  readonly property int rowsVisible: 3
  // Nominal (unclamped) grid for 3 rows; the visible grid is clamped to the
  // card's remaining space so the scrollbar always maps against the visible
  // track even when the card height is limited.
  readonly property int gridNominal: root.rowsVisible * (root.tileHeight + root.tileGap)
  property int cardHeight: Math.min(
    root.padding * 2 + root.headerBlock + root.gridNominal + root.footerBlock,
    panel.height - Style.gapsOut * 2)
  property int gridHeight: Math.max(Style.space(160),
    Math.min(root.gridNominal, cardHeight - root.padding * 2 - root.headerBlock - root.footerBlock))
  // Exact fit: columns*tileGap so the four cells (incl. their right/side
  // gaps) never exceed the available width -> the 4th column is never clipped.
  property int tileWidth: Math.floor((cardWidth - root.padding * 2 - root.columns * root.tileGap) / root.columns)
  property int tileHeight: tileWidth + Style.space(72)

  // ---------------------------------------------------------------- actions
  function shq(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function writeFile(path, content) {
    writer.command = ["bash", "-c", "mkdir -p " + shq(path.substring(0, path.lastIndexOf("/"))) + " && printf '%s' " + shq(content) + " > " + shq(path)]
    writer.running = true
  }

  function request(op, name) {
    var req = JSON.stringify({ op: op, name: name || "", at: Date.now() })
    root.writeFile(root.requestFile, req)
  }

  // Selected theme (click to select, click again to deselect)
  property string selected: ""

  function selectTheme(name) {
    root.selected = (root.selected === name) ? "" : name
  }

  function isSelected(name) {
    return root.selected === name
  }

  function isCurrent(name) {
    if (root.tab === "background") return root.currentBg === name
    return root.currentLock === name && root.currentSddm === name
  }

  // ----------------------------------------------------------------- mirror
  function applyStatus(raw) {
    if (!raw) return
    var j = null
    try { j = JSON.parse(raw) } catch (e) { return }
    if (!j) return
    if (j.phase) root.phase = String(j.phase)
    if (j.message) root.message = String(j.message)
    if (typeof j.busy === "boolean") root.busy = j.busy
    if (typeof j.themeCount === "number") root.themeCount = j.themeCount
    if (typeof j.currentSddm === "string") root.currentSddm = j.currentSddm
    if (typeof j.currentLock === "string") root.currentLock = j.currentLock
    if (typeof j.currentBg === "string") root.currentBg = j.currentBg
    if (typeof j.liveRendererPresent === "boolean") root.liveRendererPresent = j.liveRendererPresent
    if (typeof j.lockAppInstalled === "boolean") root.lockAppInstalled = j.lockAppInstalled
    if (typeof j.themedLockActive === "boolean") root.themedLockActive = j.themedLockActive
    if (typeof j.lockMode === "string") root.lockMode = j.lockMode
    if (typeof j.recoveredNativeAt === "number") root.recoveredNativeAt = j.recoveredNativeAt
  }

  function applyThemes(raw) {
    if (!raw) return
    var arr = null
    try { arr = JSON.parse(raw) } catch (e) { return }
    if (!Array.isArray(arr)) return
    // Same content as the current list? Keep the existing array so the
    // GridView (scroll position, selection) is untouched by the 2s poll.
    if (JSON.stringify(root.themeList) === JSON.stringify(arr)) return
    root.themeList = arr
    root.recomputeGrid()
  }

  function recomputeGrid() {
    var q = String(root.searchText || "").trim().toLowerCase()
    var base = root.tab === "lock"
      ? root.themeList.filter(function(e) { return !e.builtin })
      : root.themeList
    if (!q) { root.gridThemes = base; return }
    root.gridThemes = base.filter(function(e) {
      return String(e.name || "").toLowerCase().indexOf(q) >= 0
    })
  }

  function refreshNow() {
    statusWatcher.reload()
    themesWatcher.reload()
  }

  FileView {
    id: statusWatcher
    path: root.statusFile
    watchChanges: true
    printErrors: false
    onLoaded: root.applyStatus(statusWatcher.text())
    onFileChanged: reload()
  }

  FileView {
    id: themesWatcher
    path: root.themesFile
    watchChanges: true
    printErrors: false
    onLoaded: root.applyThemes(themesWatcher.text())
    onFileChanged: reload()
  }

  Process {
    id: writer
    running: false
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.opened
    onTriggered: {
      root.refreshNow()
    }
  }

  // --------------------------------------------------------------- surface
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "mark-lock-themes"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.providerPanelVisible) root.providerPanelVisible = false
          else if (root.searchText.length > 0) root.searchText = ""
          else root.close()
          event.accepted = true
        }
      }
    }

    Rectangle {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: Style.cornerRadius
      color: root.surface
      border.width: 1
      border.color: root.cardBorder
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((panel.height - height) / 2))
      clip: true

      // Swallow clicks on non-interactive card areas (title, gaps) so they
      // don't fall through to the scrim and close the menu.
      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Column {
        width: parent.width - root.padding * 2
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.gap

        // ------------------------------------------------------------ header
        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width - Style.space(58)
            height: Style.space(44)
            verticalAlignment: Text.AlignVCenter
            text: "QyLock Oma - SDDM and Lock themes"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title + 4
            font.bold: true
            elide: Text.ElideRight
          }

          Button {
            width: Style.space(48)
            text: "⚙"
            accent: root.accent
            selected: root.providerPanelVisible
            onClicked: root.providerPanelVisible = !root.providerPanelVisible
          }
        }

        // Status feedback: only shown when it matters (error / working /
        // empty) so the header stays clean otherwise.
        Text {
          width: parent.width
          visible: root.busy || root.phase === "error" || root.themeCount === 0
          // Show the service's error message whenever there is one — the
          // empty-state text must never hide a failing sync.
          text: root.phase === "error" ? root.message
              : root.themeCount === 0 ? "No themes available yet. Sync is running…"
              : root.message
          color: root.phase === "error" ? Color.urgent : root.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // Crash-recovery notice: the native lock was auto-restored after the
        // themed lock app failed; shown until the themed lock is re-engaged.
        Text {
          width: parent.width
          visible: root.recoveredNativeAt > 0
          text: "⚠ The themed lock crashed — the native Omarchy lock is active. Use ⚙ to re-enable repo themes."
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          wrapMode: Text.WordWrap
        }

        // -------------------------------------------------------------- tabs
        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            width: (parent.width - Style.space(8)) / 2
            text: "Lock & SDDM"
            accent: root.accent
            selected: root.tab === "lock"
            onClicked: root.tab = "lock"
          }

          Button {
            width: (parent.width - Style.space(8)) / 2
            text: "Background"
            accent: root.accent
            selected: root.tab === "background"
            onClicked: root.tab = "background"
          }
        }

        // Name search: filters the grid (both tabs) as you type.
        Rectangle {
          width: parent.width
          height: Style.space(44)
          radius: Style.cornerRadius - 2
          color: Util.alpha(root.surface, 0.6)
          border.width: 1
          border.color: root.cardBorder

          TextInput {
            id: searchInput
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(36)
            verticalAlignment: TextInput.AlignVCenter
            text: root.searchText
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            clip: true
            onTextChanged: root.searchText = text
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.searchText = ""
                event.accepted = true
              }
            }
          }

          Text {
            anchors.fill: parent
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(36)
            visible: root.searchText.length === 0
            text: "Search themes and wallpapers…"
            color: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
          }

          Text {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            visible: root.searchText.length > 0
            text: "✕"
            color: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            MouseArea {
              anchors.fill: parent
              onClicked: {
                root.searchText = ""
                searchInput.focus = true
              }
            }
          }
        }

        // Animated backgrounds are always on (Background tab): video themes
        // apply like image themes. The live renderer is what actually plays
        // them — a note explains when it is missing.
        Text {
          width: parent.width
          visible: root.tab === "background"
          text: root.liveRendererPresent
            ? "Animated backgrounds: on — video and image themes both work."
            : "⚠ Video themes are applied but won't animate: the live-background renderer is not active."
          color: root.liveRendererPresent ? root.muted : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        // -------------------------------------------------------------- grid
        // Grid + always-visible scrollbar (thin, right edge)
        Item {
          width: parent.width
          height: root.gridHeight

          GridView {
            id: themeGrid
            width: parent.width
            height: parent.height
            cellWidth: root.tileWidth + root.tileGap
            cellHeight: root.tileHeight + root.tileGap
            model: root.gridThemes
            clip: true
            boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            width: root.tileWidth
            height: root.tileHeight
            radius: Style.cornerRadius - 2
            color: (root.isSelected(modelData.name) && !root.isCurrent(modelData.name))
                 ? Style.selectionFillFor(root.accent, root.accent)
                 : Style.selectionFillFor(root.foreground, root.accent)
            border.width: (root.isSelected(modelData.name) && !root.isCurrent(modelData.name)) ? 1 : 0
            border.color: root.accent

            required property var modelData

            MouseArea {
              anchors.fill: parent
              // Built-in wallpapers are selectable in the Background tab
              // only (they are not lock/SDDM themes).
              enabled: !root.busy && (root.tab === "background" || modelData.main)
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.selectTheme(modelData.name)
            }

            // Animated marker: video themes show a badge (their tile preview
            // is still the static PNG until the animated background plays).
            Rectangle {
              visible: modelData.video
              height: Style.space(20)
              width: videoBadgeText.implicitWidth + Style.space(12)
              radius: height / 2
              color: Util.alpha(Color.accent, 0.16)
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.rightMargin: Style.space(6)
              anchors.topMargin: Style.space(6)

              Text {
                id: videoBadgeText
                anchors.centerIn: parent
                text: "▶ video"
                color: root.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
            }

            Column {
              width: parent.width - Style.space(12)
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              anchors.topMargin: Style.space(6)
              spacing: Style.space(4)

              // preview: animated GIF, else image, else color, else icon
              Rectangle {
                width: root.tileWidth - Style.space(12)
                height: root.tileWidth - Style.space(12)
                radius: Style.cornerRadius - 3
                clip: true
                color: "transparent"
                anchors.horizontalCenter: parent.horizontalCenter

                AnimatedImage {
                  anchors.fill: parent
                  visible: !!modelData.gif && modelData.gif.length > 0
                  source: !!modelData.gif && modelData.gif.length > 0 ? "file://" + modelData.gif : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                }

                Image {
                  anchors.fill: parent
                  visible: !(!!modelData.gif && modelData.gif.length > 0) && !!modelData.preview && modelData.preview.length > 0
                  source: !!modelData.preview && modelData.preview.length > 0 ? "file://" + modelData.preview : ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                }

                Rectangle {
                  anchors.fill: parent
                  visible: !(!!modelData.gif && modelData.gif.length > 0) && !(!!modelData.preview && modelData.preview.length > 0) && !!modelData.color && modelData.color.length > 0
                  color: modelData.color
                }

                Text {
                  anchors.centerIn: parent
                  visible: !(!!modelData.gif && modelData.gif.length > 0) && !(!!modelData.preview && modelData.preview.length > 0) && !(!!modelData.color && modelData.color.length > 0)
                  text: modelData.video ? "▶" : "🖼"
                  color: root.muted
                  font.pixelSize: Style.font.subtitle
                }
              }

              // Name (with ▶ icon for video backgrounds, ⚠ for known-broken
              // themes), centered with the icon in one row so long names
              // still elide inside the tile.
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(4)

                Text {
                  visible: modelData.video
                  text: "▶"
                  color: root.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  width: Math.min(root.tileWidth - Style.space(48), implicitWidth)
                  text: modelData.name + (modelData.risky ? " ⚠" : "")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                }
              }

              // Current-theme marker: the applied card shows a plain "active"
              // label under its name — no action buttons for it.
              Text {
                width: parent.width
                visible: root.isCurrent(modelData.name)
                text: "active"
                color: root.accent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
              }

              // Action row: only on a selected card that is NOT the current
              // one (the applied card cannot re-apply; it shows "active").
              // Preview only in the lock tab; Apply follows the current tab.
              Row {
                width: parent.width
                visible: root.isSelected(modelData.name) && !root.isCurrent(modelData.name)
                spacing: Style.space(6)
                anchors.horizontalCenter: parent.horizontalCenter

                Button {
                  text: "Preview"
                  accent: root.accent
                  visible: root.tab === "lock"
                  enabled: !root.busy && root.lockAppInstalled && !root.themedLockActive
                  onClicked: root.request("previewLock", modelData.name)
                }

                Button {
                  text: "Apply"
                  accent: root.accent
                  enabled: !root.busy
                  onClicked: root.tab === "background"
                    ? root.request("applyBackground", modelData.name)
                    : root.request("applyBoth", modelData.name)
                }
              }
            }
          }
          }

          // Visible scrollbar (single drag surface: press anywhere on the
          // strip, drag to scroll; the handle simply reflects the position).
          Rectangle {
            id: scrollTrack
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(5)
            radius: width / 2
            color: "transparent"
            // Drive the handle straight from contentY/contentHeight — these
            // always notify when the grid scrolls (programmatic or user),
            // unlike the Flickable visibleArea grouped property.
            visible: themeGrid.contentHeight > themeGrid.height

            Rectangle {
              id: scrollHandle
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              radius: width / 2
              color: Util.alpha(Color.menu.text, 0.35)
              height: Math.max(Style.space(28), (themeGrid.height / Math.max(1, themeGrid.contentHeight)) * (scrollTrack.height - Style.space(4)))
              y: (themeGrid.contentY / Math.max(1, themeGrid.contentHeight - themeGrid.height)) * (scrollTrack.height - height)
            }

            MouseArea {
              id: dragArea
              anchors.fill: parent
              // Wider hit target than the 5px visual strip (Fitts' law)
              anchors.leftMargin: -Style.space(11)
              preventStealing: true
              cursorShape: Qt.PointingHandCursor
              property real grabY: 0

              function applyFrom(py) {
                var track = scrollTrack.height
                var hh = scrollHandle.height
                var f = (py - dragArea.grabY) / Math.max(1, track - hh)
                f = Math.min(Math.max(f, 0), 1)
                var maxc = Math.max(0, themeGrid.contentHeight - themeGrid.height)
                themeGrid.contentY = f * maxc
              }

              onPressed: {
                dragArea.grabY = Math.min(Math.max(mouseY - scrollHandle.y, 0), scrollHandle.height)
                applyFrom(mouseY)
              }
              onPositionChanged: if (pressed) applyFrom(mouseY)
            }
          }
        }

        // ------------------------------------------------------------ footer
        Text {
          width: parent.width
          text: (root.tab === "lock"
            ? "Apply sets the lock theme + SDDM (Polkit at next login); Preview locks now with it. "
            : "Apply changes the background instantly; video themes animate too. ")
            + "Escape closes."
          color: root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      // ------------------------------------------------ lock-provider ⚙
      // Sibling of the Column, anchored to the card (paints above it).
      Rectangle {
        id: providerPanel
        visible: root.providerPanelVisible
        anchors.fill: parent
        z: 20
        radius: Style.cornerRadius
        color: root.surface
        border.width: 1
        border.color: root.cardBorder

        // Swallow clicks outside the panel controls.
        MouseArea {
          anchors.fill: parent
          onClicked: {}
        }

        Column {
          width: parent.width - root.padding * 2
          anchors.centerIn: parent
          spacing: root.gap

          Text {
            width: parent.width
            text: "Lock provider"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            text: "Repo lock: the qylock theme you select locks the screen (Preview/Apply work). "
              + "Native: Omarchy's built-in lock screen — your themes stay installed, they just don't lock. "
              + "Preview always shows the repo theme."
            color: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.recoveredNativeAt > 0
            text: "The native lock is active because the themed lock crashed last session."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: (parent.width - Style.space(8)) / 2
              text: "Use repo themes"
              accent: root.accent
              selected: root.lockMode === "themed"
              enabled: root.lockMode !== "themed"
              onClicked: {
                root.request("setLockMode", "themed")
                root.providerPanelVisible = false
              }
            }

            Button {
              width: (parent.width - Style.space(8)) / 2
              text: "Use native lock"
              accent: root.accent
              selected: root.lockMode === "native"
              enabled: root.lockMode !== "native"
              onClicked: {
                root.request("setLockMode", "native")
                root.providerPanelVisible = false
              }
            }
          }

          Text {
            width: parent.width
            visible: root.lockMode === "native"
            text: "The switch persists. A shell restart makes the native plugin register fully — until then the keybinding still uses the plugin's own handoff."
            color: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            width: parent.width
            text: "Close"
            accent: root.accent
            onClicked: root.providerPanelVisible = false
          }
        }
      }

    }
  }

}