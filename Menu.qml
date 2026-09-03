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

  function open(payloadJson) {
    root.opened = true
    Qt.callLater(root.refreshNow)
  }

  function close() {
    root.opened = false
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
  property bool gitAvailable: true
  property string repoName: "…"
  property string branchNow: ""
  property string commitNow: ""
  property int themeCount: 0
  property string currentSddm: ""
  property string currentLock: ""
  property string currentBg: ""
  property bool lockAppInstalled: false
  property string lockMode: "native"
  property bool themedLockActive: false
  property string lockAppDir: ""
  property string lockThemeFile: ""
  property var themeList: []

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
  property int cardWidth: Math.min(Style.space(870), panel.width - Style.gapsOut * 2)
  // Centered card sized to its content: three full theme rows, symmetric
  // margins (content anchors center, so no bottom-heavy black area).
  readonly property int headerBlock: Style.space(205)
  readonly property int footerBlock: Style.space(48)
  readonly property int tileGap: Style.space(14)
  readonly property int rowsVisible: 3
  property int gridHeight: root.rowsVisible * (root.tileHeight + root.tileGap)
  property int cardHeight: Math.min(
    root.padding * 2 + root.headerBlock + root.gridHeight + root.footerBlock,
    panel.height - Style.gapsOut * 2)
  // Exact fit: columns*tileGap so the four cells (incl. their right/side
  // gaps) never exceed the available width -> the 4th column is never clipped.
  property int tileWidth: Math.floor((cardWidth - root.padding * 2 - root.columns * root.tileGap) / root.columns)
  property int tileHeight: tileWidth + Style.space(56)

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

  function saveConfigThenSync() {
    var url = String(urlField.text || "").trim()
    var branch = String(branchField.text || "").trim()
    if (url.length < 4) return
    // config.json overrides the shell.json entry; the service watches it.
    root.writeFile(root.configFile, JSON.stringify({ repo: url, branch: branch }))
    Qt.callLater(function() { root.request("sync", "") })
  }

  // Selected theme (click to select, click again to deselect)
  property string selected: ""

  function selectTheme(name) {
    root.selected = (root.selected === name) ? "" : name
  }

  function isSelected(name) {
    return root.selected === name
  }

  function applyTheme(name) {
    if (root.tab === "background") root.request("applyBackground", name)
    else root.request("applyBoth", name)
  }

  function previewSelected() {
    root.request("previewLock", root.selected)
  }

  function applySelected() {
    if (root.tab === "background") root.request("applyBackground", root.selected)
    else root.request("applyBoth", root.selected)
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
    if (typeof j.gitAvailable === "boolean") root.gitAvailable = j.gitAvailable
    if (j.repoName) root.repoName = String(j.repoName)
    if (j.branch) root.branchNow = String(j.branch)
    if (j.commit) root.commitNow = String(j.commit)
    if (typeof j.themeCount === "number") root.themeCount = j.themeCount
    if (typeof j.currentSddm === "string") root.currentSddm = j.currentSddm
    if (typeof j.currentLock === "string") root.currentLock = j.currentLock
    if (typeof j.currentBg === "string") root.currentBg = j.currentBg
    if (typeof j.lockAppInstalled === "boolean") root.lockAppInstalled = j.lockAppInstalled
    if (j.lockMode === "themed" || j.lockMode === "native") root.lockMode = String(j.lockMode)
    if (typeof j.themedLockActive === "boolean") root.themedLockActive = j.themedLockActive
    if (j.lockAppDir) root.lockAppDir = String(j.lockAppDir)
    if (j.lockThemeFile) root.lockThemeFile = String(j.lockThemeFile)
    if (j.repoUrl && String(urlField.text).length === 0) urlField.text = String(j.repoUrl)
  }

  function applyThemes(raw) {
    if (!raw) return
    var arr = null
    try { arr = JSON.parse(raw) } catch (e) { return }
    if (Array.isArray(arr)) root.themeList = arr
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
    onTriggered: root.refreshNow()
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
          root.close()
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

      Column {
        width: parent.width - root.padding * 2
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.gap

        // ------------------------------------------------------------ header
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "Lock & SDDM Themes"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
            width: parent.width - statusPill.width - parent.spacing
          }

          Rectangle {
            id: statusPill
            width: pillText.implicitWidth + Style.space(16)
            height: pillText.implicitHeight + Style.space(8)
            radius: height / 2
            color: root.busy ? root.accent
                 : root.phase === "error" ? Color.urgent
                 : root.phase === "idle" ? Style.selectionFillFor(root.foreground, root.accent)
                 : root.accent
            anchors.verticalCenter: parent.verticalCenter

            Text {
              id: pillText
              anchors.centerIn: parent
              text: root.busy ? "working…" : root.phase
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }

        Text {
          width: parent.width
          text: root.message
          color: root.phase === "error" ? Color.urgent : root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ------------------------------------------------------------- repo
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            id: repoLabel
            text: "git repo"
            color: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(56)
          }

          TextField {
            id: urlField
            width: parent.width - repoLabel.width - branchLabel.width - updateButton.width - parent.spacing * 2
            text: ""
            placeholderText: "https://github.com/Darkkal44/qylock.git"
            verticalPadding: Style.spacing.inputPaddingY
            onEditingFinished: root.saveConfigThenSync()
          }

          Text {
            id: branchLabel
            text: "branch"
            color: root.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(40)
          }

          TextField {
            id: branchField
            width: Style.space(88)
            text: ""
            placeholderText: "default"
            verticalPadding: Style.spacing.inputPaddingY
            onEditingFinished: root.saveConfigThenSync()
          }

          Button {
            id: updateButton
            text: "Update"
            accent: root.accent
            enabled: !root.busy
            onClicked: {
              root.saveConfigThenSync()
              root.refreshNow()
            }
          }
        }

        Text {
          width: parent.width
          text: root.themeCount > 0
            ? root.repoName + "  ·  " + (root.branchNow || "default") + " @" + root.commitNow + "  ·  " + root.themeCount + " themes   " +
              (root.currentSddm ? "· SDDM: " + root.currentSddm : "") + "   " +
              (root.currentLock ? "· lock: " + root.currentLock : "") + "   " +
              (root.currentBg ? "· bg: " + root.currentBg : "")
            : "No repository synced yet — press Update to download themes."
          color: root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
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

        // -------------------------------------------------------------- grid
        GridView {
          id: themeGrid
          width: parent.width
          height: root.gridHeight
          cellWidth: root.tileWidth + root.tileGap
          cellHeight: root.tileHeight + root.tileGap
          model: root.themeList
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            width: root.tileWidth
            height: root.tileHeight
            radius: Style.cornerRadius - 2
            color: (root.isCurrent(modelData.name) || root.isSelected(modelData.name))
                 ? Style.selectionFillFor(root.accent, root.accent)
                 : Style.selectionFillFor(root.foreground, root.accent)
            border.width: (root.isCurrent(modelData.name) || root.isSelected(modelData.name)) ? 1 : 0
            border.color: root.accent

            required property var modelData
            required property int index

            MouseArea {
              anchors.fill: parent
              enabled: !root.busy && modelData.main
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.selectTheme(modelData.name)
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

              Text {
                width: parent.width
                text: modelData.name
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
              }

              Text {
                width: parent.width
                text: {
                  var parts = []
                  if (modelData.risky) parts.push("⚠")
                  if (modelData.collection) parts.push("collection")
                  if (modelData.flattenedFrom) parts.push("·")
                  if (modelData.main && modelData.conf) parts.push("lock-ready")
                  if (root.isSelected(modelData.name)) parts.push("● selected")
                  else if (root.isCurrent(modelData.name)) parts.push("● current")
                  return parts.join(" ")
                }
                color: root.isCurrent(modelData.name) ? root.accent : root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }
        }

        // ------------------------------------------------------------ footer
        Text {
          width: parent.width
          text: (root.tab === "lock"
            ? "Apply sets the lock theme + SDDM (Polkit prompt at next login); Lock Preview locks now with the selected theme. "
            : "Apply changes the background instantly. ")
            + "Escape closes."
          color: root.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // --------------------------------------------- selection action bar
      // Appears in the bottom-right corner when a theme is selected.
      Rectangle {
        id: actionBar
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: root.padding
        radius: Style.cornerRadius - 2
        color: root.surface
        border.width: 1
        border.color: root.cardBorder
        visible: root.selected.length > 0 && root.themeList.length > 0
        width: actionRow.implicitWidth + Style.space(12)
        height: actionRow.implicitHeight + Style.space(12)

        Row {
          id: actionRow
          anchors.centerIn: parent
          spacing: Style.space(8)

          Button {
            text: "Lock Preview"
            accent: root.accent
            visible: root.tab === "lock"
            enabled: !root.busy && root.lockAppInstalled && !root.themedLockActive
            onClicked: root.previewSelected()
          }

          Button {
            text: "Apply"
            accent: root.accent
            enabled: !root.busy
            onClicked: root.applySelected()
          }
        }
      }
    }
  }

}