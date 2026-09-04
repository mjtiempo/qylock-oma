import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import QtMultimedia 6.0 as Native
import qs.Commons
import qs.Ui

// Live Background — fork of omarchy's background renderer with live wallpaper
// support. Same IPC surface as omarchy.background (target "background":
// set/setInstant/transition/themeTransition/refresh) so omarchy-theme-bg-set
// and the theme switcher keep working unchanged.
//
// Media handling:
//   - images  -> static Image (unchanged path, cache on)
//   - gif/apng-> AnimatedImage (same source/fillMode/status; cache off)
//   - mp4/webm/mkv/mov -> VideoWallpaper (QtMultimedia MediaPlayer, loop,
//     muted by default, PreserveAspectCrop). No crossfade for video (v1):
//     the previous surface keeps showing until the new media is decodable,
//     then swaps — never a blank/black desktop.
//   - failure -> keep the previous surface; the dark fallback rect guarantees
//     even a cold start with a corrupt file is never pure black.
//
// Known v1 simplifications (documented in live-wallpaper.md):
//   - video transitions are instant (no reveal mask); image/gif reveals
//     still crossfade with the original machinery.
//   - one MediaPlayer per screen (N decodes for N monitors).
//   - playback pauses while the session is locked (probe poll @2s).
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property string currentBackground: ""
  property string displayedBackground: ""
  property string incomingBackground: ""
  property string oldBackground: ""
  property bool finishingTransition: false
  property int backgroundVersion: 0
  property int revealStartedVersion: -1
  property int pendingThemeVersion: -1
  property string pendingColorsRaw: ""
  property string pendingShellRaw: ""
  property real revealProgress: 1

  // ------------------------------------------------------------ media state
  // Root-level media targets; per-panel players react and commit.
  property string videoPath: ""          // path the players should load ("" = none)
  property string videoCommitting: ""    // path committed as the wallpaper ("" = none)
  property bool lockPaused: false        // session locked -> players paused
  property bool videoHeld: false         // video is the "old" layer during an image reveal
  property string lastFailedVideoPath: ""
  property bool coldStart: true

  function isVideoPath(p) {
    return /\.(mp4|webm|mkv|mov)([?#].*)?$/i.test(String(p || ""))
  }

  function isGifPath(p) {
    return /\.(gif|apng)([?#].*)?$/i.test(String(p || ""))
  }

  function imageUrl(path) {
    return Util.fileUrl(path)
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function setBackground(path, instant) {
    transitionBackground("", path, path, instant, false)
  }

  function transitionBackground(fromPath, path, finalPath, instant, force) {
    path = String(path || "").trim()
    finalPath = String(finalPath || path).trim()
    fromPath = String(fromPath || "").trim()
    if (!path) return

    var same = !force && finalPath === currentBackground
    if (same) {
      // Dedupe is correct for images but wrong for media: same-path replay
      // must restart the animation/playback.
      if (isVideoPath(finalPath)) {
        if (lastFailedVideoPath === finalPath) lastFailedVideoPath = ""
        restartMedia(finalPath)
      } else if (isGifPath(finalPath)) {
        restartGif()
      }
      return
    }

    currentBackground = finalPath
    backgroundVersion += 1
    revealStartedVersion = -1
    revealAnimation.stop()
    finishingTransition = false

    console.log("live-background: switch to " + finalPath
      + (isVideoPath(finalPath) ? " [video]" : isGifPath(finalPath) ? " [gif]" : " [image]"))
    if (isVideoPath(finalPath)) {
      // Video route: keep whatever is on screen until the new media is
      // decodable, then commit (per panel, independently).
      videoCommitting = ""
      videoHeld = false
      lastFailedVideoPath = ""
      videoPath = finalPath
      videoLoadGuard.restart()
      return
    }

    // Image / GIF route: original machinery, with AnimatedImage for gifs.
    if (instant || !displayedBackground) {
      oldBackground = ""
      incomingBackground = ""
      displayedBackground = path
      revealProgress = 1
      // Stop any video player; the target is not media.
      videoPath = ""
      videoCommitting = ""
      coldStart = false
      return
    }

    // Crossfade reveal. If the old layer is a video, keep it (held frame)
    // as the "old" surface under the reveal instead of an Image copy.
    if (isVideoPath(displayedBackground)) {
      videoHeld = true
    } else {
      videoHeld = false
    }
    oldBackground = fromPath || displayedBackground
    incomingBackground = path
    revealProgress = 0
  }

  function restartMedia(path) {
    if (lastFailedVideoPath === path) lastFailedVideoPath = ""
    videoPath = ""
    videoCommitting = ""
    videoHeld = false
    Qt.callLater(function() {
      if (String(path || "") === currentBackground) videoPath = path
    })
  }

  function restartGif() {
    // baseGif per panel restarts on this signal.
    gifRestartToken += 1
  }

  property int gifRestartToken: 0

  // Called by the first panel whose player reports decodable for videoPath.
  function commitVideo(path) {
    if (path !== videoPath) return
    console.log("live-background: video committed: " + path)
    videoCommitting = path
    videoLoadGuard.stop()
    displayedBackground = path
    incomingBackground = ""
    oldBackground = ""
    revealProgress = 1
    finishingTransition = false
    videoHeld = false
    coldStart = false
  }

  // A player failed to load/decode the target. Abort the switch; the previous
  // surface (or the fallback rect) stays on screen — never black.
  function videoTargetFailed(path, msg) {
    if (path !== videoPath) return
    console.warn("live-background: video failed: " + path + " (" + msg + ")")
    lastFailedVideoPath = path
    videoPath = ""
    videoCommitting = ""
    videoHeld = false
    videoLoadGuard.stop()
  }

  function clearTransition() {
    incomingBackground = ""
    oldBackground = ""
    finishingTransition = false
    videoHeld = false
    if (!isVideoPath(currentBackground)) {
      videoPath = ""
      videoCommitting = ""
    }
  }

  function setPendingTheme(colorsB64, shellB64) {
    pendingColorsRaw = Util.decodeBase64(colorsB64)
    pendingShellRaw = Util.decodeBase64(shellB64)
    pendingThemeVersion = backgroundVersion
    pendingThemeFallbackTimer.restart()
  }

  function applyPendingTheme() {
    if (pendingThemeVersion < 0) return
    pendingThemeFallbackTimer.stop()
    Color.loadColors(pendingColorsRaw)
    Color.loadShell(pendingShellRaw)
    Style.scheduleRefresh()
    pendingThemeVersion = -1
    pendingColorsRaw = ""
    pendingShellRaw = ""
  }

  function transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64) {
    transitionBackground(fromPath, path, finalPath, false, true)
    setPendingTheme(colorsB64, shellB64)
    if (!incomingBackground || revealProgress >= 1) applyPendingTheme()
  }

  function startReveal(panel) {
    if (!incomingBackground) return
    panel.maskReady = true
    if (revealStartedVersion === backgroundVersion) return
    revealStartedVersion = backgroundVersion
    applyPendingTheme()
    revealAnimation.restart()
  }

  function openSelector() {
    if (!bgSwitchProc.running) bgSwitchProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  Process {
    id: bgSwitchProc
    command: ["bash", "-c", "background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set \"$background\""]
    onExited: root.refreshBackground()
  }

  Process {
    id: themeSwitchProc
    command: ["bash", "-c", "theme=$(omarchy-theme-switcher); [[ -n $theme ]] && omarchy-theme-set \"$theme\" >/dev/null 2>&1 &"]
    onExited: root.refreshBackground()
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      onStreamFinished: root.setBackground(String(text || "").trim(), false)
    }
  }

  // Session-lock probe: while media is active, poll the compositor lock state
  // and pause playback when locked (battery + lock-screen correctness).
  Process {
    id: lockProbe
    command: ["omarchy-hyprland-session-locked"]
    onExited: function(code) { root.lockPaused = code === 0 }
  }

  Timer {
    id: lockPoll
    interval: 2000
    repeat: true
    running: root.videoPath !== "" || root.videoCommitting !== ""
    onTriggered: {
      if (!lockProbe.running) lockProbe.running = true
    }
  }

  // A media target that never becomes decodable (no error, no Ready) must
  // not hang the swap forever.
  Timer {
    id: videoLoadGuard
    interval: 10000
    repeat: false
    onTriggered: {
      if (root.videoPath !== "" && root.videoCommitting === "") {
        root.videoTargetFailed(root.videoPath, "no decode within timeout")
      }
    }
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refreshBackground()
    }

    function set(path: string): void {
      root.setBackground(path, false)
    }

    function setInstant(path: string): void {
      root.setBackground(path, true)
    }

    function transition(fromPath: string, path: string): void {
      root.transitionBackground(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.transitionBackgroundWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  Timer {
    id: pendingThemeFallbackTimer
    interval: 300
    repeat: false
    onTriggered: root.applyPendingTheme()
  }

  NumberAnimation {
    id: revealAnimation
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incomingBackground) {
        root.displayedBackground = root.currentBackground || root.incomingBackground
        root.finishingTransition = true
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: refreshBackground()

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }
      color: "transparent"
      // Keep render updates enabled. The background layer has been observed to
      // lose its committed buffer while parked with updatesEnabled=false,
      // leaving a black desktop until omarchy-shell is restarted. Live media
      // repaints constantly, so this correctness-for-perf tradeoff is required
      // for the animation to produce frames at all.
      updatesEnabled: true

      property bool maskReady: false

      // Per-panel media state.
      property string videoLoaded: ""            // path this panel decoded
      property bool videoVisible: root.videoCommitting !== "" && panel.videoLoaded === root.videoCommitting
      property bool activeIsGif: !root.isVideoPath(root.displayedBackground) && root.isGifPath(root.displayedBackground)
      // While a video is the committed wallpaper, keep the previous still
      // image (if any) underneath so the surface swap never goes blank.
      property string lastImage: ""

      function maybeStartReveal() {
        if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
        var activeIn = root.isGifPath(root.incomingBackground) ? incomingGif : incomingFrame
        if (activeIn.status !== Image.Ready) return
        Qt.callLater(function() {
          if (!root.incomingBackground || root.revealProgress !== 0 || maskReady) return
          var current = root.isGifPath(root.incomingBackground) ? incomingGif : incomingFrame
          if (current.status !== Image.Ready) return
          root.startReveal(panel)
        })
      }

      function onMediaReady() {
        if (root.videoPath === "") return
        console.log("live-background: media ready (panel): " + root.videoPath)
        panel.videoLoaded = root.videoPath
        if (root.videoCommitting === "") root.commitVideo(root.videoPath)
      }

      function onMediaError(msg) {
        if (root.videoPath === "") return
        panel.videoLoaded = ""
        root.videoTargetFailed(root.videoPath, msg)
      }

      function restartGif() {
        baseGif.playing = false
        baseGif.currentFrame = 0
        baseGif.playing = true
      }

      Connections {
        target: root
        function onDisplayedBackgroundChanged() {
          if (root.displayedBackground !== "" && !root.isVideoPath(root.displayedBackground)) {
            panel.lastImage = root.imageUrl(root.displayedBackground)
          }
        }
        function onGifRestartTokenChanged() { panel.restartGif() }
        function onVideoPathChanged() {
          // The VideoWallpaper path binding handles the load; nothing else
          // needed here (commit happens on mediaReady).
        }
        function onLockPausedChanged() {
          if (panel.videoVisible) {
            if (root.lockPaused) baseVideo.pause()
            else baseVideo.resume()
          }
        }
      }

      WlrLayershell.namespace: "omarchy-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // ------------------------------------------------------------ surfaces
      // z-order: fallback < still image < gif < video < old frame < incoming
      // reveal < mask < click surface.
      Rectangle {
        // Never-black guarantee: a very dark neutral rect behind everything.
        id: wallpaperFallback
        anchors.fill: parent
        z: 0
        color: "#15171b"
      }

      Image {
        id: baseImg
        anchors.fill: parent
        z: 1
        visible: !panel.videoVisible && !panel.activeIsGif
        source: root.isVideoPath(root.displayedBackground)
          ? (panel.lastImage !== "" && !panel.videoVisible ? panel.lastImage : "")
          : root.imageUrl(root.displayedBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        onStatusChanged: {
          if (status === Image.Ready && root.finishingTransition) root.clearTransition()
        }
      }

      AnimatedImage {
        id: baseGif
        anchors.fill: parent
        z: 1
        visible: !panel.videoVisible && panel.activeIsGif
        source: panel.activeIsGif ? root.imageUrl(root.displayedBackground) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        onStatusChanged: {
          if (status === Image.Ready && root.finishingTransition) root.clearTransition()
        }
      }

      VideoWallpaper {
        id: baseVideo
        anchors.fill: parent
        z: 2
        path: root.videoPath
        muted: true
        pausedByLock: root.lockPaused || root.videoHeld
        visible: panel.videoVisible
        onMediaReady: panel.onMediaReady()
        onMediaError: (msg) => panel.onMediaError(msg)
        // A held (paused) video must resume when the reveal finishes.
        Connections {
          target: root
          function onVideoHeldChanged() {
            if (!root.videoHeld && panel.videoVisible && !root.lockPaused) baseVideo.resume()
          }
        }
      }

      Image {
        id: oldFrame
        anchors.fill: parent
        z: 3
        // A video old-layer keeps playing as the video surface; never hand a
        // media path to the Image decoder (noise-free, and avoids a useless
        // decode error storm).
        source: root.isVideoPath(root.oldBackground) ? "" : root.imageUrl(root.oldBackground)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        visible: root.oldBackground !== "" && root.revealProgress < 1 && !root.isVideoPath(root.oldBackground)
        onStatusChanged: panel.maybeStartReveal()
      }

      Item {
        id: incomingLayer
        anchors.fill: parent
        z: 4
        visible: root.incomingBackground !== ""
          && ((root.isGifPath(root.incomingBackground) ? incomingGif : incomingFrame).status === Image.Ready)
          && (root.revealProgress >= 1 || panel.maskReady)
        layer.enabled: root.incomingBackground !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: revealMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingFrame
          anchors.fill: parent
          visible: !root.isGifPath(root.incomingBackground)
          source: root.isGifPath(root.incomingBackground) ? "" : root.imageUrl(root.incomingBackground)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: panel.maybeStartReveal()
        }

        AnimatedImage {
          id: incomingGif
          anchors.fill: parent
          visible: root.isGifPath(root.incomingBackground)
          source: root.isGifPath(root.incomingBackground) ? root.imageUrl(root.incomingBackground) : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          onStatusChanged: panel.maybeStartReveal()
        }
      }

      Item {
        id: revealMask
        anchors.fill: parent
        z: 5
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real centerTop: width / 2 - slant * height / 2
        readonly property real centerBottom: width / 2 + slant * height / 2
        readonly property real reach: width / 2 + Math.abs(slant) * height / 2 + 4
        readonly property real spread: reach * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: revealMask.centerTop - revealMask.spread; startY: 0
            PathLine { x: revealMask.centerTop + revealMask.spread; y: 0 }
            PathLine { x: revealMask.centerBottom + revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerBottom - revealMask.spread; y: revealMask.height }
            PathLine { x: revealMask.centerTop - revealMask.spread; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingBackgroundChanged() {
          panel.maskReady = false
          panel.maybeStartReveal()
        }
      }

      MouseArea {
        anchors.fill: parent
        z: 6
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
