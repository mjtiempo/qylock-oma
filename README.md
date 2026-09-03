# QyLock Oma — SDDM and Lock themes

An [Omarchy](https://omarchy.org/) shell plugin that downloads **lock screen and
SDDM themes** from the [qylock](https://github.com/Darkkal44/qylock) repository,
shows them in a square theme grid, and applies your pick:

- **Apply (Lock & SDDM tab)** — one action sets the theme for both the
  Quickshell lock screen (`~/.config/qylock/theme` + the repo's lock app at
  `~/.local/share/omarchy/mark.lock-themes/lockscreen/`) *and* the SDDM login
  screen (installs to `/usr/share/sddm/themes/<name>`, sets
  `Current=<name>` in `/etc/sddm.conf.d/theme.conf` — one Polkit prompt,
  takes effect at the next login screen).
- **Apply (Background tab)** — sets the theme's artwork as the Omarchy
  background (lock screen + wallpaper).
- **Preview** — locks right now with a card's theme without changing your
  selection.

Works out of the box with [qylock](https://github.com/Darkkal44/qylock)
(40 themes incl. the clockwork family) and any other repository that follows
the same layout:

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
— the Omarchy orbital lock-screen extension plugin by **Dumidul**.

### Third-party license

The downloaded repository (themes + lock app) is released under
**GPLv3** by Darkkal44. The plugin code in this repository is **MIT** — it
does not bundle any qylock content; it fetches and uses it as a data source
on the user's machine. If you redistribute this plugin together with
downloaded theme content, the combined distribution is governed by the
themes' GPLv3 terms.

## Install (from git)

Requires `git` (present on Omarchy by default; `omarchy pkg add git` if not):

```sh
# 1. add the plugin from GitHub
omarchy plugin add https://github.com/mjtiempo/qylock-oma.git --enable --yes

#    — or via SSH (mjtiempo key):
#    omarchy plugin add git@github.com:mjtiempo/qylock-oma.git --enable --yes

# 2. restart the shell to load it
omarchy restart shell
```

That's all. On first load the plugin:

1. **Synchronises the theme catalog** (list + previews, ~3 MB) and prepares a
   light asset cache (lock app + safe fallback theme) — total footprint
   **~10 MB**. The heavy theme media is fetched later, per theme, only when
   you Apply or Preview it (first use of a theme needs network and takes a
   moment; afterwards it's instant).
2. **Registers launcher entries** (see below) — no manual config.

If a theme's assets aren't fetched yet, Preview/Apply fetch them on demand —
you can also prefetch with `omarchy-shell mark.lock-themes fetchTheme <name>`.

Validate the folder at any time:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/mark.lock-themes
qmllint -I "$OMARCHY_PATH/shell" \
  ~/.config/omarchy/plugins/mark.lock-themes/Service.qml \
  ~/.config/omarchy/plugins/mark.lock-themes/Menu.qml
```

### Update

```sh
omarchy plugin update mark.lock-themes
omarchy restart shell
```

## Launcher entries (automatic)

On first load the plugin registers itself, so installing users need to do
nothing manual:

- **Omarchy menu row** — a `QyLock Oma` entry (searchable: `qylock`, `lock`,
  `sddm`, `theme`) is added to
  `~/.config/omarchy/extensions/omarchy-menu.jsonc` (only if the key is
  missing; existing entries are untouched). It summons the picker.
- **Desktop entry** — `~/.local/share/applications/qylock-oma.desktop` makes
  it appear in the launcher/Apps search, with the plugin's `preview.png` as
  its icon.

Both are written at user level, idempotently, at every shell start. Disable
with `"autoEntries": false` in the plugin's `shell.json` entry.

## Usage

Open the picker (`omarchy menu` → search **qylock**, or launch **QyLock Oma**
from the app launcher; bind it, e.g. `SUPER+SHIFT+L`):

```sh
omarchy-shell shell summon mark.lock-themes '{}'
```

The picker is a square theme grid with two tabs:

- **Lock & SDDM** — click a theme card to select it; **Preview** and **Apply**
  buttons appear on the card. **Preview** locks now with that theme (without
  changing your selection); **Apply** sets both the lock theme and the SDDM
  login theme (one Polkit prompt for the SDDM part).
- **Background** — click a card, then **Apply** to use its artwork as the
  Omarchy background (lock screen + wallpaper).

The currently applied theme carries a small green **applied** badge (no
selection highlight); the selected card is highlighted green with its action
buttons. A scrollbar on the right scrolls the grid (drag or click);
`Escape` closes.

Everything can also be driven from the command line:

```sh
omarchy-shell mark.lock-themes sync                # download/update themes
omarchy-shell mark.lock-themes status              # JSON status
omarchy-shell mark.lock-themes themes              # JSON theme list
omarchy-shell mark.lock-themes applyBoth material-you   # lock + SDDM
omarchy-shell mark.lock-themes previewLock clockwork-orbital  # lock now
omarchy-shell mark.lock-themes applyBackground forest      # background only
omarchy-shell mark.lock-themes fetchTheme nier-automata     # prefetch assets
```

## Lock behavior

The picker's themes are rendered by the repository's Quickshell lock app,
which answers the `lock` IPC target: locking (keybinding, idle timer,
suspend — `omarchy system lock`) shows the selected theme's lock screen with
the repo's design. The native Omarchy lock plugin is disabled while the
plugin is active (password unlock only — no fingerprint).

To restore the native Omarchy lock, add `"lockMode": "native"` to the
plugin's `shell.json` entry and re-enable the native plugin
(`omarchy-shell shell setPluginEnabled dumidu.orbital-lock true`),
then restart the shell.

The installed lock app gets a small compatibility shim injected at install
time (an inert `keyboard` object + `sddm.hostName`) so themes that use SDDM's
keyboard context or gate login on `isQuickshell` behave correctly.

### Safety net (v1.2+)

A broken theme must never lock you out. The plugin guards the themed lock:

- **theme-collection flattening** — `clockwork` is a folder of sub-themes
  (`orbital`, `neo-orbital`, `tape`), each a complete theme one level deeper
  than the app expects. The scan promotes them to flat, first-class themes
  (`clockwork-orbital`, `clockwork-neo-orbital`, `clockwork-tape`) with
  symlinks in the lock app's `themes_link/` so they lock and install like any
  other theme.
- **known-broken badge** — themes known to hang the lock app (currently
  `Genshin`: needs a manually-downloaded font and crashes on session-model
  handling) are marked with ⚠ in the menu.
- **watchdog** — kills the lock app only on a *confirmed* failure: the theme
  failing to load (`FAILED to load theme`, from the lock app's own loader) or
  the compositor probe repeatedly confirming the session never locked (a real
  hang). It never kills a healthy lock on probe lag.
- **safe fallback** — after a failure the lock relaunches once with a proven
  stable theme (`girl-coffee`: bundled background + font, no videos). If the
  fallback also fails, the session is left unlocked with an error message —
  never a black screen.
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
  "catalogRepo": "https://github.com/mjtiempo/qylock-oma-catalog.git",
  "branch": "",
  "lockThemeFile": "~/.config/qylock/theme",
  "lockAppSubdir": "quickshell-lockscreen",
  "autoSync": true,
  "autoEntries": true
}
```

The repository URL/branch is configured through the `shell.json` plugin entry
(or `~/.local/state/omarchy/mark.lock-themes/config.json`, which wins over
`shell.json`). Sync happens automatically on start and can be triggered with
`omarchy-shell mark.lock-themes sync`. Extra themes can be dropped directly
into `~/.local/share/omarchy/mark.lock-themes/repo/themes/<name>/` and are
picked up by the next scan. State and downloaded themes live under:

- `~/.local/share/omarchy/mark.lock-themes/` — repo clone, installed lock app
- `~/.local/state/omarchy/mark.lock-themes/` — status.json, themes.json, state
- `/etc/sddm.conf.d/theme.conf.bak.*` — backups taken before SDDM switches

## Architecture (catalog + lazy assets)

The plugin keeps the initial footprint small by splitting the data:

- **Catalog repo** — [mjtiempo/qylock-oma-catalog](https://github.com/mjtiempo/qylock-oma-catalog)
  (public, GPLv3): `index.json` (the theme list + flags) and small preview
  PNGs (~3 MB). This is what fills the grid, so the picker opens instantly.
- **Lazy asset cache** — `~/.local/share/omarchy/mark.lock-themes/assets/` is
  a **blobless sparse clone** of the upstream qylock repo. Only
  `quickshell-lockscreen` and the safe fallback theme (`girl-coffee`) are
  materialized up front; each theme's files are fetched on demand when you
  Apply, Preview, or prefetch:

  ```sh
  omarchy-shell mark.lock-themes fetchTheme forest   # ~53 MB for forest
  ```

  Unused themes cost a few KB (tree metadata only), so the cache holds ~10 MB
  before any fetches and grows only with the themes you actually use
  (previously the whole repo was cloned up front: ~1.6 GB).

## How it works

- `Service.qml` (service kind, `keepLoaded`) owns the work: catalog sync with
  `Quickshell.Io.Process`, the sparse per-theme asset fetches, the privileged
  SDDM install via `pkexec` (prompted by the shell's own Polkit agent), and
  the lock app + theme preference writes. It exposes an `IpcHandler` under
  `mark.lock-themes` and mirrors state to `status.json` / `themes.json`.
- `Menu.qml` (menu kind) is a layer-shell surface that watches those files
  and sends requests through `request.json`.

## License

MIT — see LICENSE (plugin code). Downloaded themes and the lock app are
GPLv3, © Darkkal44 — see "Theme source" above.
