# Lock & SDDM Theme Manager

An [Omarchy](https://omarchy.org/) shell plugin that downloads **lock screen and
SDDM themes** from a compatible git repository, lists them in a menu, and lets
you apply your pick:

- **SDDM** — installs the theme to `/usr/share/sddm/themes/<name>` and sets
  `Current=<name>` in `/etc/sddm.conf.d/theme.conf` (Polkit password prompt,
  takes effect at the next login screen).
- **Lock** — installs the repository's Quickshell lock app
  (`quickshell-lockscreen/`, qylock-style) to
  `~/.local/share/omarchy/mark.lock-themes/lockscreen/` and writes the chosen
  theme to `~/.config/qylock/theme`. In **Themed** lock mode, locking with the
  keybinding, idle timer or suspend shows the repo lock with the selected
  theme (see "Lock screen provider" below).
- **BG** — applies the theme's background artwork to the Omarchy lock screen
  and wallpaper (`omarchy theme bg set`).

Works out of the box with [qylock](https://github.com/Darkkal44/qylock)
(38 themes) and any other repository that follows the same layout:

```
<repo>/
├── themes/
│   ├── <theme-name>/      # SDDM theme: Main.qml, theme.conf, metadata.desktop, bg.png…
│   └── …
└── quickshell-lockscreen/ # optional: the repo's Quickshell lock app (lock.sh, lock_shell.qml, shim/, imports/)
```

## Theme source

All themes, the Quickshell lock app, and the animated previews come from:

- **Repository:** [Darkkal44/qylock](https://github.com/Darkkal44/qylock)
  by **Darkkal44** — "a bunch of lockscreen themes for SDDM and Quickshell"
- `themes/<name>/` — the SDDM/lock theme set (Main.qml + theme.conf +
  metadata.desktop + background art + bundled fonts where license permits)
- `quickshell-lockscreen/` — the repo's Quickshell lock app
  (lock.sh, lock_shell.qml, shim/, imports/), installed at
  `~/.local/share/omarchy/mark.lock-themes/lockscreen/`
- `Assets/*.gif` — the animated previews shown in the theme grid (from
  qylock's README gallery)

The fonts, artwork, and theme designs are the property of their respective
creators; several themes need a font that cannot be bundled (see qylock's
README "Font Requirements" table — e.g. Genshin, NieR, Terraria, Minecraft).
This plugin downloads the repository at runtime; it does not redistribute the
themes.

### Orbital lock themes

The `clockwork-orbital` and `clockwork-neo-orbital` themes (bundled in
qylock's `themes/clockwork/` collection) follow the **orbital** lock style
from [dumidulkdev/omarchy-orbital-lock](https://github.com/dumidulkdev/omarchy-orbital-lock)
— the Omarchy orbital lock-screen extension plugin by **Dumidul**, which this
project coexists with (its installed copy, `dumidu.orbital-lock`, can be
re-enabled by switching Lock screen back to Native).

### Third-party license

The downloaded repository (themes + lock app) is released under
**GPLv3** by Darkkal44. The plugin code in this repository is **MIT** — it
does not bundle any qylock content; it fetches and uses it as a data source
on the user's machine. If you redistribute this plugin together with
downloaded theme content, the combined distribution is governed by the
themes' GPLv3 terms.

## Install

```sh
# 1. copy the plugin folder
cp -r mark.lock-themes ~/.config/omarchy/plugins/mark.lock-themes

# 2. enable it in shell.json (plugins array)
#    { "id": "mark.lock-themes" }

# 3. restart the shell — it clones qylock automatically on start
omarchy restart shell
```

Validate the folder at any time:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/mark.lock-themes
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/mark.lock-themes/Service.qml \
  ~/.config/omarchy/plugins/mark.lock-themes/Menu.qml
```

## Usage

Open the theme menu (bind it, e.g. `SUPER+SHIFT+L`):

```sh
omarchy-shell shell summon mark.lock-themes '{}'
```

The menu shows the synced repository, its status, and one row per theme with
three actions: **Lock** (lock screen theme), **SDDM** (login screen theme),
**BG** (apply the theme artwork to the Omarchy lock/wallpaper). The row marks
the currently applied themes; `Escape` closes the menu.

Everything can also be driven from the command line:

```sh
omarchy-shell mark.lock-themes sync                # download/update themes
omarchy-shell mark.lock-themes status              # JSON status
omarchy-shell mark.lock-themes themes              # JSON theme list
omarchy-shell mark.lock-themes installSddm nier-automata
omarchy-shell mark.lock-themes setLockTheme material-you
omarchy-shell mark.lock-themes applyBackground forest
```

## Lock screen provider

The menu has a **Lock screen** switch:

- **Native** (default) — the Omarchy in-shell lock stays in charge
  (fingerprint + password, theme-aware). The plugin only manages themes.
- **Themed** — the plugin answers the `lock` IPC target, the native lock
  plugin is disabled, and locking (keybinding / idle / suspend) runs the
  repository's Quickshell lock with the currently selected theme
  (`~/.config/qylock/theme`). Password unlock only — no fingerprint.

Switching is live and persists in
`~/.local/state/omarchy/mark.lock-themes/config.json`; switch back to Native
to restore the Omarchy lock. You can also lock immediately with the menu's
**Test lock** button, or bind the installed app directly:

```sh
~/.local/share/omarchy/mark.lock-themes/lockscreen/lock.sh
```

The installed lock app gets a small compatibility shim injected at install
time (an inert `keyboard` object) so themes that use SDDM's keyboard context
load cleanly.

### Safety net (v1.2+)

A broken theme must never lock you out. The plugin guards the themed lock:

- **theme-collection flattening** — `clockwork` is a folder of sub-themes
  (`orbital`, `neo-orbital`, `tape`), each a complete theme one level deeper
  than the app expects. The scan now promotes them to flat, first-class
  themes (`clockwork-orbital`, `clockwork-neo-orbital`, `clockwork-tape`) with
  symlinks in the lock app's `themes_link/` so they lock and install like any
  other theme.
- **known-broken badge** — themes known to hang the lock app (currently
  `Genshin`: needs a manually-downloaded font and crashes on session-model
  handling) are marked with ⚠ in the menu.
- **watchdog** — kills the lock app only on a *confirmed* failure: the theme
  failing to load (`FAILED to load theme`, from the lock app's own loader) or
  the compositor probe repeatedly confirming the session never locked (a real
  hang). It never kills a healthy lock on probe lag — that bug caused
  healthy locks to die ~9 seconds after locking.
- **safe fallback** — after a failure the lock relaunches once with a proven
  stable theme (`girl-coffee`: bundled background + font, no videos).
 If the fallback also fails, the session is left
  unlocked with an error message — never a black screen.
- **no stranded locks** — after an abnormal exit the plugin probes the
  compositor lock state and re-locks with the safe theme if the session is
  still held, so you can always unlock with your password.

### Emergency manual recovery

If you ever end up on a black screen while locked:

1. Switch to a TTY (`Ctrl+Alt+F3`), log in.
2. Release the stranded lock — either from your desktop session:
   `~/.config/omarchy/plugins/mark.lock-themes/tools/release-session-lock.sh`
   or from the TTY with the session env:
   `XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0`
   `~/.config/omarchy/plugins/mark.lock-themes/tools/release-session-lock.sh`
   (runs the session-lock protocol's unlock cycle).
3. `loginctl unlock-session 2` (the wayland session; check
   `loginctl list-sessions`).
4. `pkill -f lock_shell.qml` to drop any hung lock client.
5. Switch back with `Ctrl+Alt+F1`.

The plugin itself runs steps 2-3 automatically when the lock app dies.

## Configure

Optional `shell.json` plugin entry (defaults shown):

```json
{
  "id": "mark.lock-themes",
  "repo": "https://github.com/Darkkal44/qylock.git",
  "branch": "",
  "lockThemeFile": "~/.config/qylock/theme",
  "lockAppSubdir": "quickshell-lockscreen",
  "autoSync": true
}
```

The repository URL/branch can also be changed from the menu (Update button);
that writes `~/.local/state/omarchy/mark.lock-themes/config.json`, which wins
over `shell.json`. State and downloaded themes live under:

- `~/.local/share/omarchy/mark.lock-themes/` — repo clone, installed lock app
- `~/.local/state/omarchy/mark.lock-themes/` — status.json, themes.json, state
- `/etc/sddm.conf.d/theme.conf.bak.*` — backups taken before SDDM switches

## How it works

- `Service.qml` (service kind, `keepLoaded`) owns the work: git sync with
  `Quickshell.Io.Process`, theme scanning, the privileged SDDM install via
  `pkexec` (prompted by the shell's own Polkit agent), and the lock app +
  theme preference writes. It exposes an `IpcHandler` under
  `mark.lock-themes` and mirrors state to `status.json` / `themes.json`.
- `Menu.qml` (menu kind) is a layer-shell surface that watches those files
  and sends requests through `request.json`.

## License

MIT — see LICENSE (plugin code). Downloaded themes and the lock app are
GPLv3, © Darkkal44 — see "Theme source" above.