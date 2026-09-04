// mark.lock-themes — Theme store service
//
// Manages a compatible lock/SDDM theme repository (qylock-style):
//   * syncs the repo with git (clone / pull / re-clone on URL change)
//   * scans themes/<name>/ dirs into a theme model
//   * installs the repo's Quickshell lock app (quickshell-lockscreen/) and
//     writes the lock theme preference so the lock uses the chosen theme
//   * applies an SDDM theme (privileged, via pkexec) and sets
//     /etc/sddm.conf.d/theme.conf Current=<name>
//   * applies a theme's background image to the Omarchy lock/wallpaper
//
// IPC (omarchy-shell mark.lock-themes <method>):
//   ping, sync, status, themes, installSddm <name>, setLockTheme <name>,
//   applyBackground <name>, installLockApp
//
// The menu (Menu.qml) talks to this service through request.json and reads
// results from status.json / themes.json under ~/.local/state/omarchy/.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "mark.lock-themes"
  readonly property string homeDir: Quickshell.env("HOME") || "/root"
  readonly property string pluginDir: homeDir + "/.config/omarchy/plugins/" + pluginId
  readonly property string dataDir: homeDir + "/.local/share/omarchy/" + pluginId
  readonly property string stateDir: homeDir + "/.local/state/omarchy/" + pluginId
  readonly property string repoDir: dataDir + "/repo"
  readonly property string catalogDir: dataDir + "/catalog"
  readonly property string assetsDir: dataDir + "/assets"
  readonly property string catalogIndexFile: catalogDir + "/index.json"
  readonly property string lockAppDir: dataDir + "/lockscreen"
  readonly property string statusFile: stateDir + "/status.json"
  readonly property string themesFile: stateDir + "/themes.json"
  readonly property string requestFile: stateDir + "/request.json"
  readonly property string configFile: stateDir + "/config.json"
  readonly property string lockThemeStateFile: stateDir + "/lock-theme"
  readonly property string sddmConf: "/etc/sddm.conf.d/theme.conf"

  // --------------------------------------------------------- configuration
  // Overridable through a shell.json plugin entry:
  //   { "id": "mark.lock-themes", "repo": "<url>", "branch": "<name>",
  //     "lockThemeFile": "~/.config/qylock/theme", "lockAppSubdir": "quickshell-lockscreen",
  //     "autoSync": true }
  // and through the menu (written to stateDir/config.json, which wins).
  property string repoUrl: "https://github.com/Darkkal44/qylock.git"
  // Small catalog repo: theme list + previews to populate the grid. The full
  // theme assets (videos etc.) are fetched lazily per theme on Apply/Preview.
  property string catalogRepo: "https://github.com/mjtiempo/qylock-oma-catalog.git"
  property string repoBranch: ""
  property string lockThemeFile: homeDir + "/.config/qylock/theme"
  property string lockAppSubdir: "quickshell-lockscreen"
  // Built-in background sources scanned into the picker's Background tab
  // (same folders omarchy's own background switcher lists): every shipped
  // Omarchy theme's backgrounds/ dir + the user's custom dir. Overridable
  // via shell.json / config.json `backgroundDirs` (array of absolute paths;
  // a provided value replaces the default sources).
  property var backgroundDirs: []
  readonly property string userBackgroundsRoot: homeDir + "/.config/omarchy/backgrounds"
  // Drop-in folder for user wallpapers (created at startup, auto-rescanned).
  readonly property string pictureBackgroundsRoot: homeDir + "/Pictures/Backgrounds"
  property bool autoSync: true
  // "native" = the Omarchy in-shell lock stays in charge (default);
  // "themed" = this plugin answers the "lock" IPC target and runs the
  // repository's Quickshell lock with the selected theme.
  // An explicit value from shell.json / config.json is respected; a default
  // (unset) install auto-activates "themed" on startup so Lock Preview /
  // Apply work out of the box.
  property string lockMode: "native"
  // Automatically register launcher entries on first load: an Omarchy menu
  // row (extensions/omarchy-menu.jsonc) + a desktop entry. Idempotent.
  property bool autoEntries: true
  // Animated backgrounds are ALWAYS enabled: video themes
  // (background=.mp4/.webm/.mkv/.mov) apply like image themes. The live
  // renderer is what plays them — without it they are still applied, just
  // not animated. The flag stays in state/config for status reporting and
  // backward compat with config.json written by older versions (nothing
  // gates on it anymore).
  property bool animatedBg: true
  property bool animatedBgExplicit: false
  // Explicit lockMode from shell.json / config.json — respected at startup
  // (see the comment on lockMode). Without it the themed lock auto-activates.
  property bool lockModeExplicit: false
  // Set when the lock app crashed repeatedly and the native Omarchy lock was
  // auto-restored (see restoreNativeLock). Surfaced in status.json so the
  // menu can tell the user why the themed lock is no longer in charge;
  // persisted in stateDir/recovered-native so the notice survives the
  // shell restart that re-registers the native plugin.
  property double recoveredNativeAt: 0
  readonly property string recoveredNativeFile: stateDir + "/recovered-native"
  property bool liveRendererPresent: false
  property var storedConfig: ({})

  // ------------------------------------------------------------- live state
  property bool busy: false
  property bool gitAvailable: true
  property bool repoCloned: false
  property bool compatible: false
  property string phase: "idle"
  property string message: "Not initialized"
  property string repoName: ""
  property string branchNow: ""
  property string commitNow: ""
  property int themeCount: 0
  property string currentSddm: ""
  property string currentLock: ""
  property string currentBg: ""
  property bool lockAppInstalled: false
  property bool themedLockActive: false
  property bool sessionSecure: false
  property double lockStartedAt: 0
  property int lockErrBase: 0
  // Healthy-lock tracking: the compositor probe can lag right after lock
  // start, so a lock is only treated as hung when it has been alive past the
  // grace period AND the probe has repeatedly confirmed the session is NOT
  // locked (a real hang never engages the compositor lock).
  property int probeUnlockedCount: 0
  property bool killedByWatchdog: false
  // Safety net for themes that hang or crash the lock app (e.g. Genshin):
  // never leave a stranded compositor lock; fall back to a safe theme once.
  property string safeLockTheme: "girl-coffee"
  property bool everSecured: false
  property int lockFallbacksLeft: 1
  property bool lockExitedCleanly: false
  property var themes: []
  property var pendingRequest: null

  // ------------------------------------------------------------ worker pool
  property var cmdQueue: []
  property bool workerIdle: true
  property var workerDone: null
  property double workerStartAt: 0

  Process {
    id: worker
    stdout: StdioCollector {
      id: workerOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: workerErr
      waitForEnd: true
    }
    onExited: function(code) {
      var cb = root.workerDone
      root.workerDone = null
      root.workerIdle = true
      root.pumpQueue()
      if (cb) cb(code, String(workerOut.text || ""), String(workerErr.text || ""))
    }
  }

  // Watchdog: if a command never reports back, fail it rather than wedging
  // the queue (e.g. pkexec with no Polkit agent to answer).
  Timer {
    interval: 10000
    repeat: true
    running: !root.workerIdle
    onTriggered: {
      if (root.workerIdle) return
      if (Date.now() - root.workerStartAt > 120000) {
        var cb = root.workerDone
        root.workerDone = null
        root.workerIdle = true
        worker.running = false
        root.pumpQueue()
        if (cb) cb(-1, "", "command timed out")
      }
    }
  }

  function pumpQueue() {
    if (!root.workerIdle || root.cmdQueue.length === 0) return
    var next = root.cmdQueue.shift()
    root.workerDone = next.cb
    root.workerIdle = false
    root.workerStartAt = Date.now()
    worker.command = next.args
    worker.running = true
  }

  function runCmd(args, cb) {
    root.cmdQueue.push({ args: args, cb: cb || null })
    root.pumpQueue()
  }

  function shq(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // ------------------------------------------------------------ status file
  function statusPayload() {
    return {
      phase: root.phase,
      message: root.message,
      busy: root.busy,
      gitAvailable: root.gitAvailable,
      repoCloned: root.repoCloned,
      compatible: root.compatible,
      repoUrl: root.repoUrl,
      repoName: root.repoName,
      branch: root.branchNow,
      commit: root.commitNow,
      themeCount: root.themeCount,
      currentSddm: root.currentSddm,
      currentLock: root.currentLock,
      currentBg: root.currentBg,
      animatedBg: root.animatedBg,
      liveRendererPresent: root.liveRendererPresent,
      lockAppInstalled: root.lockAppInstalled,
      lockMode: root.lockMode,
      recoveredNativeAt: root.recoveredNativeAt,
      themedLockActive: root.themedLockActive,
      sessionSecure: root.sessionSecure,
      lockAppDir: root.lockAppDir,
      lockThemeFile: root.lockThemeFile,
      updatedAt: Date.now()
    }
  }

  function writeStatus() {
    root.writeJson(root.statusFile, root.statusPayload())
  }

  function writeJson(path, obj) {
    runCmd(["bash", "-c",
      "mkdir -p " + shq(path.substring(0, path.lastIndexOf("/"))) +
      " && printf '%s' " + shq(JSON.stringify(obj)) + " > " + shq(path)], null)
  }

  // ------------------------------------------------------------------ state
  function setBusy(nextPhase, nextMessage) {
    root.phase = nextPhase
    root.message = nextMessage
    root.busy = true
    root.writeStatus()
  }

  function setDone(nextPhase, nextMessage) {
    root.phase = nextPhase
    root.message = nextMessage
    root.busy = false
    root.writeStatus()
    root.afterOp()
  }

  function fail(nextMessage) {
    root.phase = "error"
    root.message = nextMessage
    root.busy = false
    root.writeStatus()
    root.afterOp()
  }

  // Runs the next queued request once the current operation settled.
  function afterOp() {
    if (root.pendingRequest) {
      var req = root.pendingRequest
      root.pendingRequest = null
      root.dispatchRequest(req)
    }
  }

  // ------------------------------------------------------------ theme model
  // Themes known to hang or crash the repository lock app (missing assets,
  // broken model handling). They still work as SDDM themes; the themed lock
  // falls back to the safe theme automatically when one misbehaves.
  property var knownBrokenLockThemes: ["Genshin"]
  function findTheme(name) {
    for (var i = 0; i < root.themes.length; i++) {
      if (root.themes[i].name === name) return root.themes[i]
    }
    return null
  }

  // Builds the theme model from the catalog's index.json. The catalog carries
  // names, flags and small previews; each entry's subpath points into the
  // lazy asset clone (assetsDir/themes/<subpath>).
  function parseCatalog(cb) {
    root.readTextFile(root.catalogIndexFile, function(raw) {
      var list = []
      var entries = null
      try { entries = JSON.parse(raw || "[]") } catch (e) { entries = null }
      if (!Array.isArray(entries)) {
        root.fail("Catalog index.json is invalid.")
        return
      }
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i]
        var name = String(e.name || "")
        if (!name) continue
        var sub = String(e.subpath || name)
        var pv = String(e.preview || "")
        list.push({
          name: name,
          subpath: sub,
          main: e.main !== false,
          conf: e.conf !== false,
          meta: true,
          background: "",
          kind: e.video ? "video" : (String(e.color || "").length ? "color" : "image"),
          color: String(e.color || ""),
          video: e.video === true,
          collection: false,
          collectionOf: "",
          flattenedFrom: String(e.flattenedFrom || ""),
          risky: e.risky === true,
          path: root.assetsDir + "/themes/" + sub,
          gif: "",
          preview: (pv && pv.length > 0) ? root.catalogDir + "/" + pv : ""
        })
      }
      list.sort(function(a, b) { return a.name.localeCompare(b.name) })
      root.themes = list
      root.themeCount = list.length
      root.writeJson(root.themesFile, root.themes)
      if (cb) cb()
    })
  }

  // Scans the Omarchy background folders and merges every wallpaper into
  // the theme list as a built-in background entry (Background tab only):
  // all shipped theme backgrounds + the custom dirs (omarchy's own
  // ~/.config/omarchy/backgrounds and the drop-in ~/Pictures/Backgrounds,
  // plus any configured backgroundDirs). Entries are plain files;
  // applyBackground special-cases them (no theme.conf, no asset fetch).
  // The scan is safe to re-run (existing entries are skipped by name) and
  // only rewrites themes.json when new files are found.
  function scanBuiltinBackgrounds() {
    var shipped = "/usr/share/omarchy/themes"
    var custom = [root.userBackgroundsRoot, root.pictureBackgroundsRoot].concat(root.backgroundDirs)
    // Shipped: every theme's backgrounds/ dir, prefixed with the theme
    // name (files repeat across themes, e.g. omarchy.png x22).
    // Custom: drop-in dirs, listed by bare file name (prefix "user").
    var s = "shipped=" + shq(shipped) +
      "; { find \"$shipped\" -maxdepth 2 -type d -name backgrounds 2>/dev/null | while read -r d; do t=$(basename \"$(dirname \"$d\")\"); find \"$d\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.apng' \\) -printf '%p\\n' 2>/dev/null | while read -r f; do printf '%s\\t%s\\n' \"$t\" \"$f\"; done; done" +
      "; for src in"
    for (var e = 0; e < custom.length; e++) s += " " + shq(String(custom[e]))
    s += "; do [ -d \"$src\" ] && find \"$src\" -maxdepth 2 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.apng' -o -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' \\) -printf '%p\\n' 2>/dev/null | while read -r f; do printf '%s\\t%s\\n' user \"$f\"; done; done" +
      "; } | sort"
    runCmd(["bash", "-c", s], function(code, out) {
      var lines = String(out || "").split("\n")
      // Every file currently on disk (for removal detection — the drop-in
      // folder owns its list, so deleting a file drops its entry too).
      var found = {}
      for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].split("\t")
        if (parts.length < 2) continue
        var f = parts[1]
        if (f && f.length > 0) found[f] = true
      }
      var added = 0
      for (var i = 0; i < lines.length; i++) {
        var parts = lines[i].split("\t")
        if (parts.length < 2) continue
        var prefix = parts[0]
        var f = parts[1]
        if (!f || f.length === 0) continue
        var base = f.split("/").pop()
        if (!base) continue
        var rawName = prefix === "user" ? base : prefix + "-" + base
        var name = String(rawName).replace(/\.[^.]+$/, "")
        if (!name) continue
        if (root.findTheme(name)) continue   // never shadow a catalog theme
        var lower = String(base).toLowerCase()
        var video = /\.(mp4|webm|mkv|mov)$/.test(lower)
        var anim = /\.(gif|apng)$/.test(lower)
        root.themes.push({
          name: name,
          subpath: "",
          main: false,
          conf: false,
          meta: false,
          background: base,
          kind: video ? "video" : "image",
          color: "",
          video: video,
          collection: false,
          collectionOf: "",
          flattenedFrom: "",
          risky: false,
          path: f,
          gif: anim ? f : "",
          preview: f,
          builtin: true
        })
        added += 1
      }
      var kept = root.themes.filter(function(e) { return !e.builtin || found[e.path] })
      var removedCount = root.themes.length - kept.length
      if (removedCount > 0) root.themes = kept
      if (added > 0 || removedCount > 0) {
        root.themes.sort(function(a, b) { return a.name.localeCompare(b.name) })
        root.themeCount = root.themes.length
        root.writeJson(root.themesFile, root.themes)
        console.log("mark.lock-themes: built-in wallpapers +" + added + " -" + removedCount + " (Background tab)")
      }
    })
  }

  // Drop-in wallpapers: periodic rescan of the built-in background folders
  // (~/Pictures/Backgrounds, ~/.config/omarchy/backgrounds, shipped themes)
  // so a file added by the user appears in the picker without a restart.
  // The scan only rewrites themes.json when NEW files are found, so the
  // menu never churns.
  Timer {
    id: wallpaperRescanTimer
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.scanBuiltinBackgrounds()
  }

  // ---------------------------------------------------------------- syncing
  function sync() {
    if (root.busy) return
    root.setBusy("syncing", "Checking git…")
    runCmd(["bash", "-c", "command -v git >/dev/null 2>&1 && echo yes || echo no"], function(code, out) {
      root.gitAvailable = String(out || "").indexOf("yes") === 0
      if (!root.gitAvailable) {
        root.fail("git is not installed — install it with: omarchy pkg add git")
        return
      }
      root.doCloneOrPull()
    })
  }

  function doCloneOrPull() {
    // Sync the lightweight catalog (list + previews); the heavy theme assets
    // live in a blobless sparse clone and are fetched per theme on demand.
    root.setBusy("syncing", "Syncing theme catalog…")
    var branchClause = root.repoBranch.length > 0 ? " --branch " + shq(root.repoBranch) : ""
    runCmd(["bash", "-c",
      "set -u; src=" + shq(root.catalogRepo) + "; dir=" + shq(root.catalogDir) +
      "; mkdir -p " + shq(root.dataDir) +
      "; exec 9> " + shq(root.stateDir + "/sync.lock") + "; flock -n 9 || { echo ALREADY_SYNCING; exit 3; }" +
      "; if [ -d \"$dir/.git\" ]; then cur=$(git -C \"$dir\" remote get-url origin 2>/dev/null || true)" +
      "; if [ -n \"$cur\" ] && [ \"$cur\" = \"$src\" ]; then git -C \"$dir\" pull --ff-only --quiet 2>/dev/null || git -C \"$dir\" pull --quiet || { echo PULL_FAILED; exit 1; }" +
      "; else rm -rf \"$dir\"; git clone --depth 1" + branchClause + " \"$src\" \"$dir\" || { echo CLONE_FAILED; exit 1; }; fi" +
      "; else rm -rf \"$dir\"; git clone --depth 1" + branchClause + " \"$src\" \"$dir\" || { echo CLONE_FAILED; exit 1; }; fi" +
      "; [ -f \"$dir/index.json\" ] && echo __CATALOG__ || echo __NO_CATALOG__"], function(code, out, err) {
      if (code === 3) {
        root.setDone("idle", "A sync is already in progress — waiting for it to finish.")
        return
      }
      if (code !== 0) {
        root.fail("Catalog sync failed: " + String(out || err).trim())
        return
      }
      if (String(out || "").indexOf("__CATALOG__") === -1) {
        root.fail("Catalog repository is not valid: no index.json found.")
        return
      }
      root.repoCloned = true
      root.parseCatalog(function() {
        root.prepareAssetsBase(function(ok, note) {
          if (!ok) { root.fail(note); return }
          // Include Omarchy's shipped wallpapers + custom dir in the picker.
          root.scanBuiltinBackgrounds()
          if (!root.lockAppInstalled) {
            root.installLockAppInner(function(ok2, note2) {
              if (ok2) root.setDone("idle", "Synced " + root.themeCount + " themes (catalog). " + note2)
              else root.fail(note2)
            })
          } else {
            root.setDone("idle", "Synced " + root.themeCount + " themes (catalog). Theme assets are fetched on Apply / Preview.")
          }
        })
      })
    })
  }

  // Blobless sparse clone of the theme source: only the safe fallback theme
  // and the lock app are materialized up front; everything else is added per
  // theme by ensureThemeAssets().
  function prepareAssetsBase(cb) {
    var src = root.repoUrl
    runCmd(["bash", "-c",
      "set -u; src=" + shq(src) + "; dir=" + shq(root.assetsDir) +
      "; mkdir -p " + shq(root.dataDir) +
      "; if [ -d \"$dir/.git\" ]; then cur=$(git -C \"$dir\" remote get-url origin 2>/dev/null || true)" +
      "; if [ -n \"$cur\" ] && [ \"$cur\" = \"$src\" ]; then git -C \"$dir\" fetch --filter=blob:none --quiet origin 2>/dev/null || true" +
      "; else rm -rf \"$dir\"; git clone --filter=blob:none --sparse \"$src\" \"$dir\" 2>/dev/null || { echo CLONE_FAILED; exit 1; }; fi" +
      "; else rm -rf \"$dir\"; git clone --filter=blob:none --sparse \"$src\" \"$dir\" 2>/dev/null || { echo CLONE_FAILED; exit 1; }; fi" +
      // Add, never set: a `set` replaces the pattern list and `checkout`
      // then deletes every other previously fetched theme from disk (the
      // wallpaper file included). Some git versions reject `--no-cone` on
      // `add` (2.36+), so fall through mode-neutral `add`, then to `set`
      // only as a last resort with the essentials re-included.
      "; git -C \"$dir\" sparse-checkout add --no-cone quickshell-lockscreen themes/girl-coffee 2>/dev/null" +
      " || git -C \"$dir\" sparse-checkout add quickshell-lockscreen themes/girl-coffee 2>/dev/null" +
      " || git -C \"$dir\" sparse-checkout set --no-cone quickshell-lockscreen themes/girl-coffee 2>/dev/null || true" +
      "; git -C \"$dir\" checkout --quiet 2>/dev/null || true" +
      "; [ -d \"$dir/quickshell-lockscreen\" ] && echo __BASE_OK__ || echo __BASE_FAIL__"], function(code, out, err) {
      if (String(out || "").indexOf("__BASE_OK__") === -1) {
        cb(false, "Could not prepare the asset cache (" + String(err || out).trim() + ")")
        return
      }
      // The pre-Option-D full clone (repoDir) is obsolete; reclaim its disk.
      runCmd(["bash", "-c", "rm -rf " + shq(root.repoDir)], null)
      cb(true, "")
    })
  }

  // Fetches one theme's assets (blobs for its sparse path) on demand, with
  // retries — the blob checkout can fail transiently (network), and a theme
  // missing at lock time is a black lock surface, not a retry.
  function ensureThemeAssets(t, cb) {
    if (!t || !t.subpath) { cb(false, "Unknown theme"); return }
    if (!root.repoCloned) { cb(false, "Catalog not synced yet"); return }
    root.ensureThemeAssetsInner(t, 0, cb)
  }

  function ensureThemeAssetsInner(t, attempt, cb) {
    var sub = String(t.subpath)
    var flat = String(t.name).replace(/[^\w.-]/g, "_")
    runCmd(["bash", "-c",
      "dir=" + shq(root.assetsDir) + "; sub=" + shq(sub) + "; flat=" + shq(flat) +
      // Nested sub-themes (clockwork/ -> clockwork-orbital) are addressed by
      // their flat name, and the flat link is otherwise only made at install
      // time. A theme fetched later would leave lock.sh pointing at a missing
      // path -> black lock surface; refresh the link on every successful fetch.
      "; mkln() { [ \"$sub\" = \"$flat\" ] || ln -sfn \"$dir/themes/$sub\" \"$dir/themes/$flat\" 2>/dev/null || true; }" +
      "; if [ -f \"$dir/themes/$sub/Main.qml\" ]; then mkln; echo HAVE; exit 0; fi" +
      "; git -C \"$dir\" sparse-checkout add --no-cone themes/\"$sub\" 2>/dev/null" +
      " || git -C \"$dir\" sparse-checkout add themes/\"$sub\" 2>/dev/null" +
      " || git -C \"$dir\" sparse-checkout set --no-cone themes/\"$sub\" quickshell-lockscreen themes/girl-coffee 2>/dev/null || true" +
      "; git -C \"$dir\" checkout --quiet 2>/dev/null || { echo FETCH_FAIL; exit 1; }" +
      "; if [ -f \"$dir/themes/$sub/Main.qml\" ]; then mkln; echo HAVE; else echo FETCH_FAIL; fi"], function(code, out) {
      if (String(out || "").indexOf("HAVE") === 0) { cb(true, ""); return }
      if (attempt < 2) {
        runCmd(["bash", "-c", "sleep 3"], function() {
          root.ensureThemeAssetsInner(t, attempt + 1, cb)
        })
        return
      }
      cb(false, "Could not fetch assets for \"" + t.name + "\" (after " + (attempt + 1) + " attempts)")
    })
  }

  // --------------------------------------------------------- lock app setup
  function installLockApp(cb) {
    root.setBusy("installing-lock", "Installing lock app…")
    root.installLockAppInner(cb || null)
  }

  function installLockAppInner(cb) {
    runCmd(["bash", "-c",
      "set -e; src=" + shq(root.assetsDir + "/" + root.lockAppSubdir) + "; dst=" + shq(root.lockAppDir) +
      "; themes=" + shq(root.assetsDir + "/themes") +
      "; [ -d \"$src\" ] || { echo NO_LOCK_APP; exit 2; }" +
      "; rm -rf \"$dst\"; mkdir -p \"$(dirname \"$dst\")\"; cp -a \"$src\" \"$dst\"" +
      "; ln -sfn \"$themes\" \"$dst/themes_link\"" +
      // Some qylock themes use SDDM's `keyboard` context object; the lock app
      // does not define it. Inject a tiny inert shim so those themes load clean.
      "; if ! grep -q 'keyboard:' \"$dst/lock_shell.qml\" 2>/dev/null; then perl -0pi -e 's/ShellRoot \{/ShellRoot {\\n    property var keyboard: QtObject {\\n        property bool numLock: false\\n        property bool capsLock: false\\n        property bool scrollLock: false\\n        property string layout: \"\"\\n        property string currentLayout: \"\"\\n        property var layouts: []\\n        function setLayout() {}\\n    }/' \"$dst/lock_shell.qml\"; fi" +
      // qylock themes set isQuickshell = (sddm.hostName === undefined) and
      // hard-guard login behind !isQuickshell. The shim's sddm object had no
      // hostName, so those themes could NEVER authenticate (Enter did
      // nothing). Provide hostName so isQuickshell is false and login works.
      "; if ! grep -q 'hostName' \"$dst/shim/SddmShim.qml\" 2>/dev/null; then perl -0pi -e 's/property var sddm: QtObject \{/property var sddm: QtObject {\\n        property string hostName: \x22localhost\x22/' \"$dst/shim/SddmShim.qml\"; fi" +
      // Fail fast when the theme is missing: never lock a black surface.
      // lock.sh exits 3 and the watchdog falls back to the safe theme.
      // (perl: `/m` so the slurped `^exec quickshell` matches its own line,
      // and `\$` so the replacement keeps shell vars literal — a bare `$`
      // would be interpolated by perl as an empty variable.)
      "; if ! grep -q 'refusing black lock' \"$dst/lock.sh\" 2>/dev/null; then perl -0pi -e 's|^exec quickshell.*|if [ ! -f \"\\$QS_THEME_PATH/Main.qml\" ]; then\\n echo \"lock.sh: theme missing - refusing black lock\" >\\&2\\n exit 3\\nfi\\nexec quickshell -p \"\\$DIR/lock_shell.qml\"|m' \"$dst/lock.sh\"; fi" +
      "; chmod +x \"$dst/lock.sh\" 2>/dev/null || true" +
      "; echo OK"], function(code, out, err) {
      if (code === 0) {
        root.lockAppInstalled = true
        var note = "Lock app installed: " + root.lockAppDir + "/lock.sh"
        if (cb) cb(true, note)
        else root.setDone("idle", note)
      } else if (code === 2) {
        root.lockAppInstalled = false
        var note2 = "This repository has no " + root.lockAppSubdir + "/ — lock themes are recorded but there is no Quickshell lock app to run."
        if (cb) cb(false, note2)
        else root.setDone("idle", note2)
      } else {
        var note3 = "Lock app install failed: " + String(err || out).trim()
        if (cb) cb(false, note3)
        else root.fail(note3)
      }
    })
  }

  // -------------------------------------------------------- lock theme apply
  function setLockTheme(name) {
    var t = root.findTheme(name)
    if (!t) {
      root.fail("Unknown theme: " + name)
      return
    }
    if (!t.main) {
      root.fail("\"" + name + "\" is a theme collection folder (sub-themes inside, no Main.qml) — not usable as a lock theme. Pick one of the listed sub-theme names instead.")
      return
    }
    if (!root.repoCloned) {
      root.fail("No repository synced yet — run sync first.")
      return
    }
    if (!root.lockAppInstalled) {
      root.setBusy("installing-lock", "Installing lock app…")
      root.installLockAppInner(function(ok, note) {
        if (ok) root.writeLockTheme(t)
        else root.fail(note)
      })
      return
    }
    root.writeLockTheme(t)
  }

  function writeLockThemeFiles(name) {
    runCmd(["bash", "-c",
      "mkdir -p " + shq(root.lockThemeFile.substring(0, root.lockThemeFile.lastIndexOf("/"))) +
      " && printf '%s\\n' " + shq(name) + " > " + shq(root.lockThemeFile) +
      " && printf '%s\\n' " + shq(name) + " > " + shq(root.lockThemeStateFile)], null)
  }

  function writeLockTheme(t) {
    root.setBusy("setting-lock", "Setting lock theme " + t.name + "…")
    root.writeLockThemeFiles(t.name)
    root.currentLock = t.name
    root.setDone("idle", "Lock theme set to " + t.name + (root.lockMode === "themed"
      ? " — locking now (Super+L, idle, suspend) shows it."
      : " — used by the repo lock; switch Lock screen to Themed to see it when locking."))
  }

  // ------------------------------------------------------------- SDDM apply
  function installSddm(name) {
    var t = root.findTheme(name)
    if (!t) {
      root.fail("Unknown theme: " + name)
      return
    }
    root.setBusy("installing-sddm", "Installing SDDM theme " + name + "… (Polkit prompt)")
    // Fetch the theme's files first: the sparse clone only materializes
    // assets on Apply/Preview, and a raw copy of a never-fetched theme
    // would fail with a confusing error.
    root.ensureThemeAssets(t, function(ok, note) {
      if (!ok) { root.fail("Could not fetch \"" + name + "\" assets: " + note); return }
      root.installSddmInner(name, function(ok2, msg) {
        if (ok2) root.setDone("idle", "SDDM theme applied: " + name + " — it takes effect at the next login screen.")
        else root.fail(msg)
      })
    })
  }

  // Shared SDDM install. cb(ok, message); on success currentSddm is updated.
  function installSddmInner(name, cb) {
    var t = root.findTheme(name)
    if (!t) {
      cb(false, "Unknown theme: " + name)
      return
    }
    if (!t.main && !t.conf) {
      cb(false, name + " does not look like an SDDM/QML theme (no Main.qml or theme.conf).")
      return
    }
    if (!t.main) {
      cb(false, "\"" + name + "\" is a theme collection folder (sub-themes inside, no Main.qml) — not usable as an SDDM theme.")
      return
    }
    var script = [
      "set -e",
      "name=" + shq(name),
      "src=" + shq(t.path),
      "th=/usr/share/sddm/themes/$name",
      "mkdir -p /usr/share/sddm/themes",
      "rm -rf \"$th\"",
      "cp -a \"$src\" \"$th\"",
      "if [ -f /etc/sddm.conf.d/theme.conf ]; then cp -a /etc/sddm.conf.d/theme.conf \"/etc/sddm.conf.d/theme.conf.bak.$(date +%s)\" ; fi",
      "printf '[Theme]\\nCurrent=%s\\n' \"$name\" > /etc/sddm.conf.d/theme.conf"
    ].join("\n")
    runCmd(["pkexec", "sh", "-c", script], function(code, out, err) {
      if (code === 0) {
        root.currentSddm = name
        cb(true, "")
      } else {
        cb(false, "SDDM install failed (exit " + code + "): " + String(err || out).trim())
      }
    })
  }

  // One-click apply: sets the lock theme AND the SDDM theme to the same pick.
  function applyBoth(name) {
    if (root.busy) return
    var t = root.findTheme(name)
    if (!t) {
      root.fail("Unknown theme: " + name)
      return
    }
    if (!t.main) {
      root.fail("\"" + name + "\" is a theme collection folder (sub-themes inside) — pick one of its sub-theme names instead.")
      return
    }
    root.setBusy("applying-theme", "Applying \"" + name + "\" to lock + SDDM…")
    root.ensureThemeAssets(t, function(ok, note) {
      if (!ok) { root.fail("Could not fetch \"" + name + "\" assets: " + note); return }
      root.installSddmInner(name, function(ok2, msg) {
        if (!ok2) {
          root.fail(msg)
          return
        }
        root.writeLockThemeFiles(name)
        root.currentLock = name
        root.setDone("idle", "\"" + name + "\" applied to the lock and SDDM (SDDM shows at next login).")
      })
    })
  }

  // ------------------------------------------------------- background apply
  // Applies a theme's artwork to the Omarchy background: catalog themes
  // resolve their background= from theme.conf after a lazy asset fetch;
  // built-in wallpapers are plain files applied directly.
  function applyBackground(name) {
    var t = root.findTheme(name)
    if (!t) {
      root.fail("Unknown theme: " + name)
      return
    }
    if (t.builtin) {
      root.setBusy("applying-background", "Applying " + t.name + "…")
      root.applyBackgroundFile(String(t.path || ""), t.name, t.video)
      return
    }
    root.setBusy("applying-background", "Applying " + t.name + " background…")
    root.ensureThemeAssets(t, function(ok, note) {
      if (!ok) { root.fail("Could not fetch \"" + t.name + "\" assets: " + note); return }
      runCmd(["bash", "-c",
        "d=" + shq(root.assetsDir + "/themes/" + t.subpath) +
        "; bg=$(grep -E '^background=' \"$d/theme.conf\" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r' | head -1)" +
        "; if [ -n \"$bg\" ] && [ -f \"$d/$bg\" ]; then printf '%s' \"$d/$bg\"; else exit 1; fi"], function(code2, out2) {
        if (code2 !== 0) { root.fail(t.name + " has no image background to apply."); return }
        root.applyBackgroundFile(String(out2 || "").trim(), t.name, t.video)
      })
    })
  }

  // Sets the background state link to an existing artwork file and verifies
  // the apply by readback: the setter's exit code only proves the command
  // ran — a video file that fails to RENDER still exits 0, so the link must
  // resolve to the file we intended.
  function applyBackgroundFile(bgPath, label, isVideo) {
    if (!bgPath) { root.fail(label + " has no background file to apply."); return }
    runCmd(["bash", "-c", "[ -f " + shq(bgPath) + " ]"], function(code0) {
      if (code0 !== 0) { root.fail(label + ": background file is missing: " + bgPath); return }
      runCmd(["bash", "-c", "omarchy theme bg set " + shq(bgPath)], function(code3, out3, err3) {
        if (code3 !== 0) {
          root.fail("Background apply failed: " + String(err3 || out3).trim())
          return
        }
        runCmd(["bash", "-c",
          "l=" + shq(root.homeDir + "/.local/state/omarchy/current/background") +
          "; r=$(readlink -f \"$l\" 2>/dev/null || true)" +
          "; if [ -n \"$r\" ] && [ -f \"$r\" ] && [ \"$r\" = " + shq(bgPath) + " ]; then echo CONFIRMED; else echo \"BAD:$r\"; fi"],
          function(code4, out4) {
            var verdict = String(out4 || "").trim()
            var art = isVideo ? "animated background" : "background"
            if (code4 === 0 && verdict === "CONFIRMED") {
              root.currentBg = label
              root.setDone("idle", label + " " + art + " applied — the Omarchy lock screen and wallpaper now use its artwork.")
            } else {
              root.fail("Background apply failed: the background link does not resolve to \"" + label + "\"'s artwork (" + verdict + ").")
            }
          })
      })
    })
  }

  // ------------------------------------------------------------ current read
  function readCurrentSddm() {
    runCmd(["bash", "-c", "[ -f " + shq(root.sddmConf) + " ] && grep -E '^Current=' " + shq(root.sddmConf) + " | tail -1 | cut -d= -f2- || true"], function(code, out) {
      root.currentSddm = String(out || "").trim()
    })
  }

  function readCurrentLock() {
    runCmd(["bash", "-c",
      "if [ -f " + shq(root.lockThemeStateFile) + " ]; then cat " + shq(root.lockThemeStateFile) +
      "; elif [ -f " + shq(root.lockThemeFile) + " ]; then cat " + shq(root.lockThemeFile) + "; fi"], function(code, out) {
      root.currentLock = String(out || "").trim()
    })
  }

  // ---------------------------------------------------------------- config
  function loadConfig() {
    var config = root.shell && root.shell.shellConfig ? root.shell.shellConfig : null
    var plugins = config && Array.isArray(config.plugins) ? config.plugins : []
    for (var i = 0; i < plugins.length; i++) {
      var p = plugins[i]
      if (p && String(p.id || "") === root.pluginId) {
        if (p.repo) root.repoUrl = String(p.repo)
        if (p.catalogRepo) root.catalogRepo = String(p.catalogRepo)
        if (p.branch) root.repoBranch = String(p.branch)
        if (p.lockThemeFile) root.lockThemeFile = root.expandHome(String(p.lockThemeFile))
        if (p.lockAppSubdir) root.lockAppSubdir = String(p.lockAppSubdir)
        if (typeof p.autoSync === "boolean") root.autoSync = p.autoSync
        if (p.backgroundDirs) root.backgroundDirs = Array.isArray(p.backgroundDirs) ? p.backgroundDirs.map(String) : [String(p.backgroundDirs)]
        if (p.lockMode === "themed" || p.lockMode === "native") {
          root.lockMode = String(p.lockMode)
          root.lockModeExplicit = true
        }
        if (typeof p.animatedBg === "boolean") {
          root.animatedBg = p.animatedBg
          root.animatedBgExplicit = true
        }
      }
    }
    // user/menu-level overrides (stateDir/config.json) win
    root.loadLocalConfig()
    root.repoName = root.repoUrl.replace(/\.git$/, "").replace(/\/+$/, "").split("/").pop()
  }

  function loadLocalConfig() {
    // config.json is read reactively by configWatcher; this mirrors the same
    // merge for calls that happen between watcher ticks.
    var raw = configWatcher.text()
    if (!raw) return
    var cfg = null
    try { cfg = JSON.parse(raw) } catch (e) { return }
    root.storedConfig = cfg
    if (cfg && cfg.repo && String(cfg.repo).length > 3) root.repoUrl = String(cfg.repo)
    if (cfg && cfg.catalogRepo && String(cfg.catalogRepo).length > 3) root.catalogRepo = String(cfg.catalogRepo)
    if (cfg && cfg.branch) root.repoBranch = String(cfg.branch)
    if (cfg && cfg.lockMode) {
      var mode = String(cfg.lockMode)
      if (mode === "themed" || mode === "native") {
        root.lockMode = mode
        root.lockModeExplicit = true
      }
    }
    if (cfg && cfg.backgroundDirs) root.backgroundDirs = Array.isArray(cfg.backgroundDirs) ? cfg.backgroundDirs.map(String) : [String(cfg.backgroundDirs)]
    if (cfg && typeof cfg.animatedBg === "boolean") {
      root.animatedBg = cfg.animatedBg
      root.animatedBgExplicit = true
    }
  }

  // The live-background renderer (mark.live-background) takes over the
  // "background" IPC target when omarchy.background is disabled in shell.json.
  // Detect that pairing so animated backgrounds flip on automatically; an
  // explicit animatedBg config always wins.
  function detectLiveRenderer() {
    runCmd(["bash", "-c",
      "f=" + shq(root.homeDir + "/.config/omarchy/shell.json") +
      "; if [ -f \"$f\" ]" +
      " && jq -e '(.disabledPlugins // []) | index(\"omarchy.background\") != null' \"$f\" >/dev/null 2>&1" +
      " && jq -e '([.plugins[]?.id] | index(\"mark.live-background\")) != null' \"$f\" >/dev/null 2>&1" +
      "; then echo yes; else echo no; fi"], function(code, out) {
      var present = String(out || "").indexOf("yes") === 0
      var changed = present !== root.liveRendererPresent
      root.liveRendererPresent = present
      if (changed && !root.animatedBgExplicit) {
        root.animatedBg = present
        root.writeStatus()
      }
    })
  }

  // Menu toggle: persists animatedBg to config.json and applies immediately.
  function setAnimatedBg(value) {
    var on = String(value || "") === "true"
    root.setBusy("setting-animated-bg", (on ? "Enabling" : "Disabling") + " animated backgrounds…")
    root.animatedBg = on
    root.animatedBgExplicit = true
    root.writeJson(root.configFile, root.mergedConfig({ animatedBg: on }))
    root.setDone("idle", (on ? "Animated backgrounds enabled" : "Animated backgrounds disabled")
      + " — video themes will " + (on ? "animate on the wallpaper" : "be treated as static (and are refused when they have no image).") + ".")
  }

  function mergedConfig(overrides) {
    var merged = {}
    var keys = ["repo", "branch", "lockMode", "catalogRepo", "animatedBg"]
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i]
      if (root.storedConfig && root.storedConfig[k] !== undefined) merged[k] = root.storedConfig[k]
    }
    for (var j = 0; j < keys.length; j++) {
      var kk = keys[j]
      if (overrides && overrides[kk] !== undefined) merged[kk] = overrides[kk]
    }
    return merged
  }

  function expandHome(p) {
    return p.indexOf("~/") === 0 ? root.homeDir + p.slice(1) : p
  }

  FileView {
    id: configWatcher
    path: root.configFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.loadLocalConfig()
      root.repoName = root.repoUrl.replace(/\.git$/, "").replace(/\/+$/, "").split("/").pop()
      root.writeStatus()
    }
    onFileChanged: reload()
  }

  // ---------------------------------------------------------------- requests
  // The menu (and other callers) write {"op": "...", "name": "..."} to
  // requestFile; this service executes them. Requested ops queue behind the
  // currently running operation.
  FileView {
    id: requestWatcher
    path: root.requestFile
    watchChanges: true
    printErrors: false
    onLoaded: root.dispatchRequest(String(requestWatcher.text() || "").trim())
    onFileChanged: reload()
  }

  function dispatchRequest(raw) {
    if (!raw || raw === "{}") return
    var req = null
    try { req = JSON.parse(raw) } catch (e) { return }
    if (!req || !req.op) return

    if (root.busy) {
      root.pendingRequest = req
      return
    }
    var op = String(req.op)
    var name = String(req.name || "")
    if (op === "sync") root.sync()
    else if (op === "installSddm") root.installSddm(name)
    else if (op === "applyBoth") root.applyBoth(name)
    else if (op === "setLockTheme") root.setLockTheme(name)
    else if (op === "applyBackground") root.applyBackground(name)
    else if (op === "installLockApp") root.installLockApp()
    else if (op === "setLockMode") root.setLockMode(name)
    else if (op === "setAnimatedBg") root.setAnimatedBg(name)
    else if (op === "testLock") { var r = root.themedLock(); if (r !== "ok") root.fail("Cannot start themed lock: " + r) }
    else if (op === "previewLock") { var r2 = root.previewLock(name); if (r2 !== "ok") root.fail("Cannot preview lock: " + r2) }
    else if (op === "fetchTheme") { var r3 = root.fetchTheme(name); if (r3 !== "started") root.fail("Cannot fetch theme: " + r3) }
    else root.fail("Unknown request op: " + op)
  }

  // --------------------------------------------------- themed lock takeover
  // Runs the repository's Quickshell lock (themed lock mode). The lock app is
  // its own short-lived quickshell process — the repository's native design —
  // and locks the session through WlSessionLock, exactly like upstream.
  Process {
    id: lockProc
    running: false
    stdout: StdioCollector { id: lockProcOut; waitForEnd: false }
    stderr: StdioCollector { id: lockProcErr; waitForEnd: false }
    onExited: function() {
      var wasActive = root.themedLockActive
      var everSecured = root.everSecured
      root.themedLockActive = false
      root.sessionSecure = false
      // Publish the state: the menu (and its Preview/Apply buttons) mirrors
      // status.json — without this write the file stays "locked" after
      // unlock, which disabled Preview for every subsequent theme.
      root.writeStatus()
      if (wasActive && !everSecured && root.lockStartedAt > 0) root.handleLockDeath(everSecured)
      else if (wasActive) root.lockExitedCleanly = true
    }
  }

  // A lock that never secured the session within the grace window is hung:
  // kill it and fall back to the safe theme so the user is never stuck on a
  // black screen.
  Timer {
    id: lockHangTimer
    interval: 2000
    repeat: true
    running: root.themedLockActive
    onTriggered: {
      if (!root.themedLockActive) return
      var elapsed = Date.now() - root.lockStartedAt
      // Only kill a lock as hung when the probe has REPEATEDLY confirmed the
      // session is NOT locked while the lock app runs: the compositor probe
      // lags at lock start, so a lone "unlocked" or a silent probe must never
      // kill a healthy lock (that was the "lock died" bug).
      if (!root.everSecured && elapsed > 15000 && root.probeUnlockedCount >= 3) {
        root.killLockProc("lock never secured (probe confirms unlocked)")
        return
      }
      // A lock that DOES hold the session but the theme failed to load is
      // showing a black/empty surface. qylock themes emit benign QML
      // TypeErrors (session helper pattern), so only a hard load failure or
      // a repeated load-failure storm counts — not stray warnings.
      if (elapsed > 5000) {
        var err = String(lockProcErr.text || "").slice(root.lockErrBase)
        var failedLoads = err.split("FAILED to load theme").length - 1
        if (failedLoads >= 2) {
          root.killLockProc("lock theme failed to render")
        }
      }
    }
  }

  function killLockProc(reason) {
    console.log("mark.lock-themes: killing themed lock (" + reason + ")")
    var pid = lockProc.processId
    if (pid) runCmd(["bash", "-c", "kill -9 " + String(pid)], null)
    else lockProc.running = false
  }

  // The lock app exited without the session ever being secured — a crash or
  // hang, not a user unlock. Release any stranded compositor lock and retry
  // once with the safe theme.
  function handleLockDeath() {
    // Give the compositor a beat to settle the lock state, then probe it.
    root.lockDeathProbePending = true
    root.lockDeathAt = Date.now()
    lockDeathTimer.start()
  }

  property bool lockDeathProbePending: false
  property double lockDeathAt: 0

  Timer {
    id: lockDeathTimer
    interval: 300
    repeat: true
    onTriggered: {
      if (!root.lockDeathProbePending) { stop(); return }
      if (Date.now() - root.lockDeathAt < 1500) return
      root.lockDeathProbePending = false
      stop()
      if (!secureCheck.running) secureCheck.running = true
      root.lockDeathProbeArmed = true
    }
  }

  property bool lockDeathProbeArmed: false

  function startSafeFallbackLock() {
    if (root.lockFallbacksLeft <= 0) {
      // The safe theme failed too — the lock APP itself is broken, and
      // girl-coffee inherits the same app. Further themed attempts are
      // pointless: hand the lock back to the native Omarchy lock.
      root.restoreNativeLock("no theme could lock (safe fallback failed as well)")
      return
    }
    root.lockFallbacksLeft -= 1
    var theme = String(root.currentLock || "").trim()
    if (!root.findTheme(root.safeLockTheme)) {
      root.restoreNativeLock("no safe fallback theme available")
      return
    }
    if (theme !== root.safeLockTheme) {
      console.log("mark.lock-themes: themed lock crashed with \"" + theme + "\" — falling back to " + root.safeLockTheme)
      root.currentLock = root.safeLockTheme
      root.writeLockThemeFiles(root.safeLockTheme)
    }
    // Clean any stranded compositor lock state before relaunching, so the
    // fallback lock starts from a released session and the user can unlock.
    root.releaseStrandedLock(function() {
      root.launchLockProc(root.safeLockTheme)
      root.phase = "idle"
      root.message = "Themes: \"" + theme + "\" failed to lock — using " + root.safeLockTheme + " instead. Set a different Lock theme."
      root.writeStatus()
    })
  }

  // Last-resort recovery: the themed lock PIPELINE is broken (theme AND safe
  // fallback failed). Safe to release, re-enable and restart here because the
  // session lock is released BEFORE the shell restart — no lock client is
  // ever orphaned (the black-lock incident's root cause). Everything is
  // persisted first: even a failed restart leaves the native lock in charge
  // on next boot.
  function restoreNativeLock(reason) {
    console.log("mark.lock-themes: restoring native lock (" + reason + ")")
    root.recoveredNativeAt = Date.now()
    root.writeJson(root.recoveredNativeFile, { at: root.recoveredNativeAt, reason: reason })
    root.writeJson(root.configFile, root.mergedConfig({ lockMode: "native" }))
    root.releaseStrandedLock(function() {
      // Mirrors setLockMode("native"): re-enable BOTH plugins the themed
      // takeover disabled, so whichever was the original native lock returns.
      runCmd(["bash", "-c",
        "for id in dumidu.orbital-lock omarchy.lock; do timeout 5 omarchy-shell shell setPluginEnabled \"$id\" true >/dev/null 2>&1 || true; done"],
        function() {
          root.setDone("idle", "The lock app crashed repeatedly (" + reason + ") — switched to the native Omarchy lock. " +
            "Your themes are kept; re-enable the themed lock with ⚙ in the QyLock menu. Restarting the shell…")
          restartShellTimer.start()
        })
    })
  }

  // Fires the shell restart that makes the re-enabled native lock register.
  // Armed only after the restore above has fully persisted and released the
  // session lock.
  Timer {
    id: restartShellTimer
    interval: 4000
    repeat: false
    onTriggered: {
      runCmd(["omarchy", "restart", "shell"], null)
    }
  }

  // Runs the bundled release tool (lock->unlock protocol cycle) to clear a
  // stranded compositor lock; optional callback runs afterwards.
  property var releaseDoneCb: null
  function releaseStrandedLock(cb) {
    root.releaseDoneCb = cb || null
    runCmd(["bash", "-c",
      "release=" + shq(root.pluginDir + "/tools/release-session-lock.sh") +
      "; [ -x \"$release\" ] && timeout 12 \"$release\" >/dev/null 2>&1; true"],
      function() {
        var cb2 = root.releaseDoneCb
        root.releaseDoneCb = null
        if (cb2) cb2()
      })
  }

  // Session-security probe, used while the themed lock runs so that
  // `omarchy-shell lock status` (polled by the suspend path) reports secure
  // only once the compositor actually locked the session. The underlying
  // Hyprland flag is sticky after a lock client dies, so a grace period after
  // lock start gates out the stale flag of a previous lock.
  Process {
    id: secureCheck
    running: false
    command: ["omarchy-hyprland-session-locked"]
    onExited: function(code) {
      var locked = code === 0
      root.sessionSecure = locked && root.themedLockActive
        && (Date.now() - root.lockStartedAt >= 1000)
      if (root.themedLockActive) {
        if (locked) {
          root.probeUnlockedCount = 0
        } else {
          root.probeUnlockedCount += 1
        }
      }
      // Lock-death decision: compositor still holds the lock after the app
      // died without securing -> stranded, fall back to the safe theme.
      if (root.lockDeathProbeArmed && !root.themedLockActive) {
        root.lockDeathProbeArmed = false
        if (locked) root.startSafeFallbackLock()
        else root.lockExitedCleanly = true
      }
    }
  }

  Timer {
    id: securePollTimer
    interval: 500
    repeat: true
    running: root.themedLockActive
    onTriggered: {
      if (!secureCheck.running) secureCheck.running = true
    }
  }

  function activeLockTheme() {
    var theme = String(root.currentLock || "").trim()
    if (!theme) {
      theme = "nier-automata"
      root.currentLock = theme
    }
    return theme
  }

  // Starts the themed lock now — after a pre-flight readiness check. A theme
  // that is missing or incomplete must never reach lock.sh (a black lock
  // surface): the flat themes_link/<name> path is re-linked if needed, then
  // Main.qml presence is asserted; on failure the safe fallback engages
  // instead of a dead lock. Returns a status string for IPC callers.
  function launchLockProc(theme) {
    if (root.lockLaunching) return "ok"
    root.lockLaunching = true
    var t = root.findTheme(theme)
    var sub = t ? String(t.subpath || theme) : theme
    runCmd(["bash", "-c",
      "f=" + shq(root.lockAppDir + "/themes_link/" + theme) +
      "; src=" + shq(root.assetsDir + "/themes/" + sub) +
      "; [ -d \"$f\" ] || { [ -d \"$src\" ] && ln -sfn \"$src\" \"$f\"; }" +
      "; if [ -d \"$f\" ] && [ -f \"$f/Main.qml\" ]; then echo READY; else echo NOT_READY; fi"],
      function(code, out) {
        root.lockLaunching = false
        if (String(out || "").indexOf("READY") !== 0) {
          root.fail("\"" + theme + "\" could not be locked: its files are missing or incomplete (themes_link/" + theme + ").")
          if (theme !== root.safeLockTheme) root.startSafeFallbackLock()
          return
        }
        root.launchLockProcInner(theme)
      })
    return "ok"
  }

  property bool lockLaunching: false

  function launchLockProcInner(theme) {
    lockProc.command = ["bash", "-c", "exec " + shq(root.lockAppDir + "/lock.sh") + " " + shq(theme)]
    root.themedLockActive = true
    root.sessionSecure = false
    root.everSecured = false
    root.probeUnlockedCount = 0
    root.killedByWatchdog = false
    root.lockDeathProbeArmed = false
    root.lockDeathProbePending = false
    lockDeathTimer.stop()
    root.lockStartedAt = Date.now()
    root.lockErrBase = String(lockProcErr.text || "").length
    // A launched lock is not a "busy" operation; clear the transient status.
    root.busy = false
    root.phase = "idle"
    root.message = "Locking with " + theme + "…"
    root.writeStatus()
    lockProc.running = true
  }

  // Starts the themed lock now. Returns a status string for IPC callers.
  function themedLock() {
    if (root.themedLockActive) return "ok"
    if (!root.lockAppInstalled) return "no-lock-app"
    if (!root.repoCloned) return "not-synced"
    var theme = root.activeLockTheme()
    var t = root.findTheme(theme)
    if (t) {
      root.setBusy("fetching-assets", "Fetching " + theme + " assets…")
      root.ensureThemeAssets(t, function(ok, note) {
        if (!ok) { root.fail("Could not fetch \"" + theme + "\" assets: " + note); return }
        root.lockFallbacksLeft = 1
        root.launchLockProc(theme)
      })
      return "ok"
    }
    root.lockFallbacksLeft = 1
    root.launchLockProc(theme)
    return "ok"
  }

  // Locks now with an explicit theme (Lock Preview) without changing the
  // persistent selection.
  function previewLock(name) {
    if (root.themedLockActive) return "ok"
    var t = root.findTheme(name)
    if (!t) return "unknown-theme"
    if (!t.main) return "not-a-theme"
    if (!root.lockAppInstalled) return "no-lock-app"
    if (!root.repoCloned) return "not-synced"
    // Fetch the theme's assets on demand before locking with it
    // (ensureThemeAssets short-circuits when the files are already present).
    root.setBusy("fetching-assets", "Fetching " + t.name + " assets…")
    root.ensureThemeAssets(t, function(ok, note) {
      if (!ok) { root.fail("Could not fetch \"" + t.name + "\" assets: " + note); return }
      root.lockFallbacksLeft = 1
      root.launchLockProc(t.name)
    })
    return "ok"
  }

  function lockStatusPayload() {
    return {
      locked: root.themedLockActive,
      requested: root.themedLockActive,
      pending: false,
      sessionLocked: root.sessionSecure,
      secure: root.sessionSecure,
      realScreens: 1,
      passwordPam: true,
      fingerprint: false,
      authenticating: false,
      mode: "themed",
      theme: root.activeLockTheme(),
      lastEvent: root.themedLockActive ? "locked" : "idle",
      lastEventAt: ""
    }
  }

  // Switches the lock provider. Persists the mode in config.json; the
  // configWatcher flips the "lock" IpcHandler (below) via lockMode.
  function setLockMode(mode) {
    if (mode !== "themed" && mode !== "native") return
    if (mode === root.lockMode) return
    if (mode === "themed") {
      root.recoveredNativeAt = 0
      runCmd(["bash", "-c", "rm -f " + shq(root.recoveredNativeFile)], null)
      root.setBusy("switching-lock", "Switching to the themed lock…")
      // 1. Release the "lock" IPC target: disable the native lock plugin
      //    (live, persisted by the shell config mutator).
      runCmd(["bash", "-c",
        "for id in dumidu.orbital-lock omarchy.lock; do timeout 5 omarchy-shell shell setPluginEnabled \"$id\" false >/dev/null 2>&1 || true; done"],
        function() {
          // 2. Persist the mode; the watcher registers our "lock" handler.
          root.writeJson(root.configFile, root.mergedConfig({ lockMode: "themed" }))
          if (!root.lockAppInstalled) {
            root.installLockAppInner(function(ok, note) {
              if (ok) root.setDone("idle", "Themed lock enabled — locking now shows the repo theme. (Native lock disabled)")
              else root.fail(note)
            })
          } else {
            root.setDone("idle", "Themed lock enabled — locking now shows the repo theme. (Native lock disabled)")
          }
        })
    } else {
      root.setBusy("switching-lock", "Restoring the native lock…")
      // 1. Release the "lock" target before re-enabling the native plugin.
      root.writeJson(root.configFile, root.mergedConfig({ lockMode: "native" }))
      runCmd(["bash", "-c",
        "for id in dumidu.orbital-lock omarchy.lock; do timeout 5 omarchy-shell shell setPluginEnabled \"$id\" true >/dev/null 2>&1 || true; done"],
        function() {
          root.setDone("idle", "Native lock restored — the Omarchy lock screen is in charge again.")
        })
    }
  }

  // Themed-mode lock takeover: answers `omarchy-shell lock lock/status/…` so
  // the keybinding, idle lock and suspend path all use the themed lock.
  IpcHandler {
    id: lockTakeover
    target: "lock"
    enabled: root.lockMode === "themed"

    function lock(): string {
      return root.themedLock()
    }

    function isLocked(): string {
      return root.themedLockActive ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify(root.lockStatusPayload())
    }
  }

  // A lock client that survived a previous shell is unsupervised: the
  // watchdog only monitors its own lockProc child, so a broken orphan would
  // hold the session lock (black surface) until manual rescue. Sweep stale
  // lock_shell.qml processes on start; if the session is still locked,
  // restore an interactive lock UI (the launch pre-flight picks the current
  // theme or falls back to the safe theme).
  // One-shot retry for the sweep's no-lock-app branch: fires after the lock
  // app has had time to (re)install during startup. Re-probes the compositor
  // first — a session the user unlocked in the meantime must not be locked
  // again. (A real Timer: Qt.callLater's extra arguments are function
  // arguments, not a delay.)
  Timer {
    id: sweepRetryTimer
    interval: 12000
    repeat: false
    onTriggered: {
      if (root.themedLockActive) return
      runCmd(["omarchy-hyprland-session-locked"], function(code) {
        if (code !== 0) return
        root.lockFallbacksLeft = 1
        root.themedLock()
      })
    }
  }

  function sweepStrandedLocks() {
    runCmd(["bash", "-c", "pgrep -f 'lock_shell.qml' >/dev/null 2>&1 && echo FOUND || echo CLEAN"], function(code, out) {
      if (String(out || "").indexOf("FOUND") !== 0) return
      console.log("mark.lock-themes: sweeping stale lock client from a previous shell")
      runCmd(["bash", "-c", "pkill -f 'lock_shell.qml' 2>/dev/null || true"], function() {
        runCmd(["omarchy-hyprland-session-locked"], function(code2, out2) {
          if (code2 !== 0) return
          root.lockFallbacksLeft = 1
          if (root.themedLock() === "no-lock-app") {
            // The lock app (re)installs during this very start; the sweep can
            // run ahead of that chain — retry once it has had time to land.
            sweepRetryTimer.start()
          }
        })
      })
    })
  }

  // Fetches a theme's assets on demand (also useful for prefetching).
  function fetchTheme(name) {
    var t = root.findTheme(name)
    if (!t) return "unknown-theme"
    root.setBusy("fetching-assets", "Fetching " + name + " assets…")
    root.ensureThemeAssets(t, function(ok, note) {
      if (ok) root.setDone("idle", "Assets for \"" + name + "\" are ready.")
      else root.fail("Could not fetch \"" + name + "\" assets: " + note)
    })
    return "started"
  }

  // ------------------------------------------------- launcher registration
  // One-time (idempotent) user-level wiring so installs need no manual steps:
  //   · ~/.config/omarchy/extensions/omarchy-menu.jsonc -> "qylock" menu row
  //   · ~/.local/share/applications/qylock-oma.desktop   -> launcher entry
  function readTextFile(path, cb) {
    runCmd(["cat", path], function(code, out) { cb(String(out || "")) })
  }

  function ensureLauncherEntries() {
    if (!root.autoEntries) return
    var menuFile = root.homeDir + "/.config/omarchy/extensions/omarchy-menu.jsonc"
    var desktopFile = root.homeDir + "/.local/share/applications/qylock-oma.desktop"
    var previewIcon = root.pluginDir + "/preview.png"
    var exec = "omarchy-shell shell summon mark.lock-themes '{}'"
    var glyph = "\ue8db"

    // Desktop entry (rewrite every start; cheap and idempotent)
    var desktop = "[Desktop Entry]\nName=QyLock\nComment=Themed lock and live backgrounds picker\nExec=" + exec +
      "\nIcon=" + previewIcon + "\nTerminal=false\nType=Application\nCategories=Settings;System;\n"
    runCmd(["bash", "-c",
      "mkdir -p " + shq(root.homeDir + "/.local/share/applications") +
      " && printf '%s' " + shq(desktop) + " > " + shq(desktopFile) +
      " && (command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database " +
      shq(root.homeDir + "/.local/share/applications") + " >/dev/null 2>&1 || true); true"], null)

    // Omarchy menu row: nested under the built-in "Style" section
    // (style.qylock). Removes a legacy root-level "qylock" entry if one was
    // left by earlier versions. An existing style.qylock row that still
    // carries OUR old auto-generated label is migrated to the current name;
    // a user-customized row is left untouched.
    root.readTextFile(menuFile, function(text) {
      var raw = String(text || "")
      var line = "  \"style.qylock\": {\"icon\":\"" + glyph + "\",\"label\":\"QyLock\",\"description\":\"Themed lock and live backgrounds picker\",\"action\":\"" + exec + "\"},\n"
      if (raw.indexOf('"style.qylock"') !== -1) {
        if (raw.indexOf('"QyLock Oma"') !== -1) {
          var migrated = raw.replace(/"style\.qylock":\s*\{[^}]*\}/,
            '"style.qylock": {"icon":"' + glyph + '","label":"QyLock","description":"Themed lock and live backgrounds picker","action":"' + exec + '"}')
          if (migrated !== raw) {
            runCmd(["bash", "-c", "printf '%s' " + shq(migrated) + " > " + shq(menuFile)], null)
          }
        }
        return
      }
      var body = raw.replace(/\s*"qylock":\s*\{[^}]*\},\s*/g, "").trim()
      var updated = body.replace(/\n\s*\}\s*$/, "\n" + line + "}\n")
      if (updated === body) updated = "{\n" + line + "}\n"
      runCmd(["bash", "-c", "mkdir -p " + shq(root.homeDir + "/.config/omarchy/extensions") +
        " && printf '%s' " + shq(updated) + " > " + shq(menuFile)], null)
    })
  }

  // -------------------------------------------------------------------- IPC
  IpcHandler {
    target: root.pluginId

    function ping(): string {
      return "ok"
    }

    function sync(): string {
      root.sync()
      return "started"
    }

    function status(): string {
      return JSON.stringify(root.statusPayload())
    }

    function themes(): string {
      return JSON.stringify(root.themes)
    }

    function installSddm(name: string): string {
      root.installSddm(name)
      return "started"
    }

    function applyBoth(name: string): string {
      root.applyBoth(name)
      return "started"
    }

    function setLockTheme(name: string): string {
      root.setLockTheme(name)
      return "started"
    }

    function applyBackground(name: string): string {
      root.applyBackground(name)
      return "started"
    }

    function installLockApp(): string {
      root.installLockApp()
      return "started"
    }

    function setLockMode(mode: string): string {
      root.setLockMode(mode)
      return "started"
    }

    function testLock(): string {
      return root.themedLock()
    }

    function previewLock(name: string): string {
      return root.previewLock(name)
    }

    function fetchTheme(name: string): string {
      return root.fetchTheme(name)
    }
  }

  // ---------------------------------------------------------------- startup
  Component.onCompleted: {
    root.loadConfig()
    root.detectLiveRenderer()
    root.sweepStrandedLocks()
    runCmd(["bash", "-c", "mkdir -p " + shq(root.stateDir) + " " + shq(root.dataDir) + " " + shq(root.pictureBackgroundsRoot) + "; : > " + shq(root.requestFile)], function() {
      root.readCurrentSddm()
      root.readCurrentLock()
      root.ensureLauncherEntries()
      // On a default (unset) install the repo lock takes charge so Lock
      // Preview / Apply behave as advertised; an explicit "native" in
      // shell.json / config.json (menu ⚙ or crash recovery) is respected.
      if (root.lockMode !== "themed" && !root.lockModeExplicit) root.setLockMode("themed")
      // Surface a crash-recovery marker (native lock auto-restored) across
      // the shell restart that followed it.
      runCmd(["bash", "-c", "cat " + shq(root.recoveredNativeFile) + " 2>/dev/null || true"], function(code, out) {
        var raw = String(out || "").trim()
        var marker = null
        try { marker = JSON.parse(raw) } catch (e) {}
        if (marker && marker.at) {
          root.recoveredNativeAt = Number(marker.at) || 0
          root.writeStatus()
        }
      })
      if (root.autoSync) root.sync()
      else {
        root.phase = "idle"
        root.message = "Auto-sync is disabled — press Update in the theme menu to download themes."
        root.writeStatus()
        // No sync this boot: still refresh the list from the local catalog
        // and merge the built-in wallpapers.
        root.parseCatalog(function() { root.scanBuiltinBackgrounds() })
      }
    })
  }
}