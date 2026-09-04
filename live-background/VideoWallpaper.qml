import QtQuick
import QtMultimedia 6.0 as Native

// Wallpaper MediaPlayer wrapper: loops muted video, cropped to fill, safely
// restartable (two-step source reset so a same-path replay always replays).
// MediaStatus/PlaybackState are compared as integer literals (LoadedMedia=2,
// BufferedMedia=3, PlayingState=1, NoError=0) — enum-alias access through
// `Native.MediaPlayer.X` was avoided for parser robustness.
Item {
  id: root

  property string path: ""            // target source (file path or url)
  property bool muted: true
  property int fillMode: 2            // VideoOutput.FillMode.PreserveAspectCrop

  signal mediaReady()                 // media decodable and about to play
  signal mediaError(string message)   // decode/load failure

  property bool loaded: false
  property bool pausedByLock: false

  Native.VideoOutput {
    id: out
    anchors.fill: parent
    fillMode: root.fillMode === 2 ? 2 : 1
  }

  Native.MediaPlayer {
    id: player
    videoOutput: out
    loops: -1                         // MediaPlayer.Infinite
    audioOutput: Native.AudioOutput {
      muted: root.muted
    }

    onMediaStatusChanged: {
      var s = player.mediaStatus
      if (s === 2 || s === 3) {       // LoadedMedia / BufferedMedia
        root.loaded = true
        root.mediaReady()
        if (player.playbackState !== 1 && !root.pausedByLock) player.play()
      }
    }

    onErrorOccurred: {
      if (player.error !== 0) root.mediaError(player.errorString)
    }
  }

  onPathChanged: root.reload()

  function reload() {
    var p = String(root.path || "").trim()
    if (!p) {
      loaded = false
      player.stop()
      return
    }
    // Two-step reset: setting the same source again would be a no-op for an
    // already-loaded media, so clear first, then assign on a later tick.
    player.source = ""
    root.loaded = false
    Qt.callLater(function() {
      if (String(root.path || "").trim() !== p) return
      player.source = p
      player.play()
    })
  }

  function pause() {
    if (player.playbackState === 1) player.pause()
  }

  function resume() {
    if (String(root.path || "").trim() !== "" && player.playbackState !== 1) player.play()
  }

  // Keeps the last decoded frame on screen (used when a video is the
  // underlying layer during an image reveal).
  function holdFrame() {
    if (player.playbackState === 1) player.pause()
  }
}
