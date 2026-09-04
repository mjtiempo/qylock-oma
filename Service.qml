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
  readonly property string themesRawFile: stateDir + "/themes.txt"
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
  property bool autoSync: true
  // "native" = the Omarchy in-shell lock stays in charge (default);
  // "themed" = this plugin answers the "lock" IPC target and runs the
  // repository's Quickshell lock with the selected theme.
  property string lockMode: "native"
  // Automatically register launcher entries on first load: an Omarchy menu
  // row (extensions/omarchy-menu.jsonc) + a desktop entry. Idempotent.
  property bool autoEntries: true
  // Animated backgrounds: video themes (background=.mp4/.webm/.mkv/.mov) are
  // applied to the Omarchy background instead of refused when this is on.
  // Auto-enabled when the live-background renderer (mark.live-background) is
  // registered and omarchy.background is disabled; config.json / shell.json
  // `animatedBg` always wins over the auto state.
  property bool animatedBg: false
  property bool animatedBgExplicit: false
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
  // Sanitization: removes stray self-referential symlink loops inside theme
  // dirs (a theme/<name>/<name> -> theme/<name>/ loop crashes the lock app's
  // recursive file walking). Runs on every scan.
  property var lastSanitizeCount: 0

  function sanitizeThemeSymlinks() {
    runCmd(["bash", "-c",
      "cd " + shq(root.repoDir + "/themes") + " 2>/dev/null || exit 0" +
      "; for d in */; do [ -d \"$d\" ] || continue; n=$(basename \"$d\")" +
      "; [ -L \"$d/$n\" ] && rm -f \"$d/$n\" && echo \"loop:$d/$n\"; done" +
      "; for d in */; do [ -d \"$d\" ] || continue; for f in \"$d\"*; do" +
      "; [ -L \"$f\" ] && rm -f \"$f\"; done; done"], function(code, out) {
      var removed = String(out || "").split("\n").filter(function(l) { return l.indexOf("loop:") === 0 }).length
      root.lastSanitizeCount = removed
      if (removed > 0) console.log("mark.lock-themes: removed " + removed + " symlink loop(s) in themes/")
    })
  }

  // Collection folders (no Main.qml of their own; sub-themes live inside) are
  // not selectable as lock/SDDM themes.
  property var collectionThemes: ["clockwork"]

  function findTheme(name) {
    for (var i = 0; i < root.themes.length; i++) {
      if (root.themes[i].name === name) return root.themes[i]
    }
    return null
  }

  // Maps a theme name to the animated preview GIF in the repo's Assets/ dir
  // (qylock's README gallery uses GitHub-style underscore filenames; win7 is
  // the gif for windows_7 and clockwork.gif covers all clockwork sub-themes).
  function themeGif(name) {
    var special = {
      "windows_7": "win7.gif",
      "last-of-us": "the_last_of_us.gif",
      "star-rail": "star_rail.gif",
      "nier-automata": "nier_automata.gif",
      "girl-coffee": "girl_coffee.gif",
      "girl-pillow": "girl_pillow.gif",
      "dog-samurai": "dog_samurai.gif",
      "man-bicycle": "man_bicycle.gif",
      "women-umbrella": "women_umbrella.gif",
      "ninja-gaiden": "ninja_gaiden.gif",
      "genshin": "genshin.gif",
      "osu": "osu.gif",
      "osumania": "osumania.gif",
      "minecraft": "minecraft.gif",
      "terraria": "terraria.gif",
      "sword": "sword.gif",
      "winter": "winter.gif",
      "field": "field.gif",
      "enfield": "enfield.gif",
      "forest": "forest.gif",
      "material-you": "material-you.gif",
      "nothing": "nothing.gif",
      "wuwa": "wuwa.gif",
      "R1999_1": "R1999_1.gif",
      "R1999_2": "R1999_2.gif",
      "pixel-coffee": "pixel_coffee.gif",
      "pixel-dusk-city": "pixel_dusk_city.gif",
      "pixel-hollowknight": "pixel_hollowknight.gif",
      "pixel-munchlax": "pixel_munchlax.gif",
      "pixel-night-city": "pixel_night_city.gif",
      "pixel-rainyroom": "pixel_rainyroom.gif",
      "pixel-skyscrapers": "pixel_skyscrapers.gif",
      "pixel-cyberpunk": "pixel-cyberpunk.gif",
      "pixel-emerald": "pixel-emerald.gif",
      "pixel-sakura": "pixel-sakura.gif",
      "pixel-waterfall": "pixel-waterfall.gif",
      "ninja_gaiden": "ninja_gaiden.gif"
    }
    if (special[name]) return root.repoDir + "/Assets/" + special[name]
    // Case-insensitive fallback (Genshin vs genshin, etc.): theme dir names
    // use their own casing while the README/Assets use lowercase.
    var lower = String(name).toLowerCase()
    if (special[lower]) return root.repoDir + "/Assets/" + special[lower]
    if (name.indexOf("clockwork") === 0) return root.repoDir + "/Assets/clockwork.gif"
    return ""
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

  function parseScan(raw) {
    var list = []
    var lines = String(raw || "").split("\n")
    var nestedNames = []
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 8 || parts[0].length === 0) continue
      var name = parts[0]
      var bg = parts[4]
      var video = parts[7] === "1"
      // Real theme directory (nested for promoted sub-themes).
      var realPath = parts.length >= 9 && parts[8].length > 0 ? parts[8] : (root.repoDir + "/themes/" + name)
      var themePath = realPath
      var hasMain = parts[1] === "1"
      list.push({
        name: name,
        main: hasMain,
        conf: parts[2] === "1",
        meta: parts[3] === "1",
        background: bg,
        kind: parts[5] || "image",
        color: parts[6] || "",
        video: video,
        collection: false,
        collectionOf: "",
        flattenedFrom: (realPath.indexOf("/clockwork/") !== -1) ? "clockwork" : "",
        risky: root.knownBrokenLockThemes.indexOf(name) !== -1,
        path: themePath,
        gif: root.themeGif(name),
        preview: (!video && bg.length > 0) ? themePath + "/" + bg : ""
      })
      // Nested sub-themes (e.g. clockwork/neo-orbital, renamed to the flat
      // clockwork-neo-orbital) need a flat-name symlink in themes_link.
      // Top-level themes live at repo/themes/<name>/ exactly; anything deeper
      // is a promoted sub-theme. Compare with the trailing slash normalized.
      var norm = realPath.replace(/\/+$/, "")
      var flatPath = root.repoDir + "/themes/" + name
      if (norm !== flatPath) {
        nestedNames.push(name + "\t" + realPath)
      }
    }
    list.sort(function(a, b) { return a.name.localeCompare(b.name) })
    root.themes = list
    root.themeCount = list.length
    root.writeJson(root.themesFile, root.themes)
    // The lock app resolves themes at themes_link/<name>; promote nested
    // sub-theme names with symlinks so lock.sh finds them at their flat name.
    root.promoteNestedThemes(nestedNames)
  }

  function promoteNestedThemes(pairs) {
    if (!pairs || pairs.length === 0) return
    // Remember links for when the lock app is (re)installed, and link now if
    // it is already in place.
    root.nestedLinkPairs = pairs
    if (root.lockAppInstalled) root.applyNestedLinks()
  }

  property var nestedLinkPairs: []

  function applyNestedLinks() {
    var pairs = root.nestedLinkPairs
    if (!pairs || pairs.length === 0) return
    var script = "linkdir=" + shq(root.lockAppDir + "/themes_link") + "; mkdir -p \"$linkdir\""
    for (var i = 0; i < pairs.length; i++) {
      var parts = String(pairs[i]).split("\t")
      if (parts.length < 2) continue
      script += "; ln -sfn " + shq(parts[1]) + " \"$linkdir/" + String(parts[0]).replace(/[^\w.-]/g, "_") + "\""
    }
    runCmd(["bash", "-c", script], null)
  }

  function scanThemes(cb) {
    runCmd(["bash", "-c",
      "repo=" + shq(root.repoDir) + "; out=" + shq(root.themesRawFile) +
      "; : > \"$out\"; [ -d \"$repo/themes\" ] || exit 0" +
      // First pass: top-level themes. Collection folders (no Main.qml) are
      // walked one level deeper for their sub-themes, which are promoted to
      // flat entries (clockwork/ -> clockwork-orbital, etc.) so they fit the
      // app's one-level theme format.
      "; scan_dir() { d=\"$1\"; flatname=\"$2\"; [ -d \"$d\" ] || return; main=0; conf=0; meta=0; bg=\"\"; typev=\"image\"; color=\"\"" +
      "; [ -f \"$d/Main.qml\" ] && main=1; [ -f \"$d/theme.conf\" ] && conf=1; [ -f \"$d/metadata.desktop\" ] && meta=1" +
      "; if [ -f \"$d/theme.conf\" ]; then while IFS='=' read -r k v; do case \"$k\" in" +
      " background) bg=\"$v\" ;; type) typev=\"$v\" ;; color) color=\"$v\" ;; esac; done" +
      " < <(grep -E '^(background|type|color)=' \"$d/theme.conf\" 2>/dev/null || true); fi" +
      "; if [ -n \"$bg\" ] && [ ! -f \"$d/$bg\" ]; then bg=\"\"; fi" +
      "; video=0; case \"$bg\" in *.mp4|*.webm|*.mkv|*.mov) video=1 ;; esac" +
      "; printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$flatname\" \"$main\" \"$conf\" \"$meta\" \"$bg\" \"$typev\" \"$color\" \"$video\" \"$d\" >> \"$out\"" +
      "; }" +
      "; for d in \"$repo\"/themes/*/; do [ -d \"$d\" ] || continue" +
      "; [ -L \"${d%/}\" ] && continue; name=$(basename \"$d\")" +
      "; if [ -f \"$d/Main.qml\" ]; then scan_dir \"$d\" \"$name\"" +
      "; else" +
      // collection folder: promote each sub-theme dir to a flat entry
      " for s in \"$d\"*/; do [ -d \"$s\" ] || continue" +
      "; [ -f \"$s/Main.qml\" ] || continue" +
      "; sub=$(basename \"$s\"); flat=\"${name}-${sub}\"" +
      "; scan_dir \"$s\" \"$flat\"" +
      "; done" +
      "; fi; done"], function(code, out, err) {
      var ok = code === 0
      if (ok) {
        // read the TSV back in a separate step (worker output is the script's own stdout)
        root.readFileCb = function(text) {
          root.parseScan(text)
          if (cb) cb()
        }
        root.readFile(root.themesRawFile)
      } else {
        root.fail("Theme scan failed: " + String(err || out).trim())
      }
    })
  }

  property var readFileCb: null
  function readFile(path) {
    runCmd(["cat", path], function(code, out) {
      if (root.readFileCb) {
        var cb = root.readFileCb
        root.readFileCb = null
        cb(String(out || ""))
      }
    })
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

  // Fetches one theme's assets (blobs for its sparse path) on demand.
  function ensureThemeAssets(t, cb) {
    if (!t || !t.subpath) { cb(false, "Unknown theme"); return }
    if (!root.repoCloned) { cb(false, "Catalog not synced yet"); return }
    var sub = String(t.subpath)
    runCmd(["bash", "-c",
      "dir=" + shq(root.assetsDir) + "; sub=" + shq(sub) +
      "; if [ -f \"$dir/themes/$sub/Main.qml\" ]; then echo HAVE; exit 0; fi" +
      "; git -C \"$dir\" sparse-checkout add --no-cone themes/\"$sub\" 2>/dev/null" +
      " || git -C \"$dir\" sparse-checkout add themes/\"$sub\" 2>/dev/null" +
      " || git -C \"$dir\" sparse-checkout set --no-cone themes/\"$sub\" quickshell-lockscreen themes/girl-coffee 2>/dev/null || true" +
      "; git -C \"$dir\" checkout --quiet 2>/dev/null || { echo FETCH_FAIL; exit 1; }" +
      "; [ -f \"$dir/themes/$sub/Main.qml\" ] && echo HAVE || echo FETCH_FAIL"], function(code, out) {
      if (String(out || "").indexOf("HAVE") === 0) cb(true, "")
      else cb(false, "Could not fetch assets for \"" + t.name + "\"")
    })
  }

  function checkLockAppPresence() {
    runCmd(["bash", "-c", "[ -d " + shq(root.repoDir + "/" + root.lockAppSubdir) + " ] && echo yes || echo no"], function(code, out) {
      var hasLockApp = String(out || "").indexOf("yes") === 0
      if (hasLockApp && !root.lockAppInstalled) {
        root.setBusy("installing-lock", "Installing lock app…")
        root.installLockAppInner(function(ok, note) {
          if (ok) root.setDone("idle", "Synced " + root.themeCount + " themes. " + note)
          else root.fail(note)
        })
      } else {
        root.setDone("idle", "Synced " + root.themeCount + " themes from " + root.repoName + ".")
      }
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
      "; chmod +x \"$dst/lock.sh\" 2>/dev/null || true" +
      "; echo OK"], function(code, out, err) {
      if (code === 0) {
        root.lockAppInstalled = true
        root.applyNestedLinks()
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
    root.setBusy("installing-sddm", "Installing SDDM theme " + name + "… (Polkit prompt)")
    root.installSddmInner(name, function(ok, msg) {
      if (ok) root.setDone("idle", "SDDM theme applied: " + name + " — it takes effect at the next login screen.")
      else root.fail(msg)
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
  function applyBackground(name) {
    var t = root.findTheme(name)
    if (!t) {
      root.fail("Unknown theme: " + name)
      return
    }
    if (t.video && !root.animatedBg) {
      root.fail(t.name + " is a video theme — animated backgrounds are off (enable them in the Background tab).")
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
        var bgPath = String(out2 || "").trim()
        runCmd(["bash", "-c", "omarchy theme bg set " + shq(bgPath)], function(code3, out3, err3) {
          if (code3 !== 0) {
            root.fail("Background apply failed: " + String(err3 || out3).trim())
            return
          }
          // The setter's exit code only proves the command ran — a video file
          // that fails to RENDER still exits 0. Verify the state link actually
          // resolves to the artwork and the file still exists.
          runCmd(["bash", "-c",
            "l=" + shq(root.homeDir + "/.local/state/omarchy/current/background") +
            "; r=$(readlink -f \"$l\" 2>/dev/null || true)" +
            "; if [ -n \"$r\" ] && [ -f \"$r\" ] && [ \"$r\" = " + shq(bgPath) + " ]; then echo CONFIRMED; else echo \"BAD:$r\"; fi"],
            function(code4, out4) {
              var verdict = String(out4 || "").trim()
              var art = t.video ? "animated background" : "background"
              if (code4 === 0 && verdict === "CONFIRMED") {
                root.currentBg = t.name
                root.setDone("idle", t.name + " " + art + " applied — the Omarchy lock screen and wallpaper now use its artwork.")
              } else {
                root.fail("Background apply failed: the background link does not resolve to \"" + t.name + "\"'s artwork (" + verdict + ").")
              }
            })
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
        if (p.lockMode === "themed" || p.lockMode === "native") root.lockMode = String(p.lockMode)
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
      if (mode === "themed" || mode === "native") root.lockMode = mode
    }
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
      root.fail("The themed lock app failed repeatedly — the session was left unlocked. " +
        "Check the theme or switch Lock screen back to Native.")
      root.releaseStrandedLock()
      return
    }
    root.lockFallbacksLeft -= 1
    var theme = String(root.currentLock || "").trim()
    if (!root.findTheme(root.safeLockTheme)) {
      root.fail("The lock app failed and no safe fallback theme is available — session left unlocked.")
      root.releaseStrandedLock()
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

  // Starts the themed lock now. Returns a status string for IPC callers.
  function launchLockProc(theme) {
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
        "timeout 5 omarchy-shell shell setPluginEnabled dumidu.orbital-lock true >/dev/null 2>&1 || true"],
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
    var desktop = "[Desktop Entry]\nName=QyLock Oma\nComment=SDDM and lock theme picker\nExec=" + exec +
      "\nIcon=" + previewIcon + "\nTerminal=false\nType=Application\nCategories=Settings;System;\n"
    runCmd(["bash", "-c",
      "mkdir -p " + shq(root.homeDir + "/.local/share/applications") +
      " && printf '%s' " + shq(desktop) + " > " + shq(desktopFile) +
      " && (command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database " +
      shq(root.homeDir + "/.local/share/applications") + " >/dev/null 2>&1 || true); true"], null)

    // Omarchy menu row: nested under the built-in "Style" section
    // (style.qylock). Removes a legacy root-level "qylock" entry if one was
    // left by earlier versions.
    root.readTextFile(menuFile, function(text) {
      var raw = String(text || "")
      if (raw.indexOf('"style.qylock"') !== -1) return
      var body = raw.replace(/\s*"qylock":\s*\{[^}]*\},\s*/g, "").trim()
      var line = "  \"style.qylock\": {\"icon\":\"" + glyph + "\",\"label\":\"QyLock Oma\",\"description\":\"SDDM and lock theme picker\",\"action\":\"" + exec + "\"},\n"
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
    runCmd(["bash", "-c", "mkdir -p " + shq(root.stateDir) + " " + shq(root.dataDir) + "; : > " + shq(root.requestFile)], function() {
      root.readCurrentSddm()
      root.readCurrentLock()
      root.ensureLauncherEntries()
      // The menu no longer exposes a lock-provider switch: the repo lock is
      // always in charge so Lock Preview / Apply behave as advertised. Make
      // the takeover active (disables the native lock plugin) if needed.
      if (root.lockMode !== "themed") root.setLockMode("themed")
      if (root.autoSync) root.sync()
      else {
        root.phase = "idle"
        root.message = "Auto-sync is disabled — press Update in the theme menu to download themes."
        root.writeStatus()
      }
    })
  }
}