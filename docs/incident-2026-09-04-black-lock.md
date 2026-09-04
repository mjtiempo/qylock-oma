# Incident 2026-09-04: black lock screen (cursor, no login form) — 3:26–3:39 PST

**Severity:** lockout ~13 min · **Recovery:** manual (pkill + release tool) → watchdog safe-fallback → password unlock
**Environment:** Omarchy, Hyprland, plugin `mark.lock-themes` (lockMode `themed`), qylock themes via blobless sparse clone
**Cross-refs:** README → "Safety net (v1.2+)" and "Emergency manual recovery"

## Symptom

Locking (`Super+L`) produced a **pure black screen with a cursor and no login
form**. The session was compositor-locked (ext-session-lock), the lock surface
was mapped but rendered nothing. TTY rescue needed (`Ctrl+Alt+F4`).

## Timeline (reconstructed)

| Time | Event |
| ------ | ------- |
| 15:26:00 | Lock pressed; `lock_shell.qml` instance #1 spawned (theme `clockwork-orbital`) |
| 15:26:00 | Main shell (quickshell) restarts; instance #1 is orphaned — reparented to `systemd --user`, **no longer a child of the shell** |
| 15:29:22 | Lock pressed again; instance #2 spawned as the shell's supervised `lockProc` child — same theme |
| 15:26–15:39 | Black screen + cursor. Watchdog does **not** fire: instance #1 (the actual lock holder) is unsupervised; instance #2's surface never maps (ext-session-lock is exclusive) |
| 15:39 | Manual `pkill -f lock_shell.qml` (both) → watchdog sees its child die → release cycle + relaunch with safe theme `girl-coffee` → working login form |
| 15:42 | Password unlock OK; `LOCK` blocker cleared from both monitors |

## Root causes

1. **Theme assets missing at lock time (primary).** `lock-theme`/`qylock/theme`
   was `clockwork-orbital`, but its files were never materialized in the
   sparse clone (`assets/themes/clockwork/orbital/` absent — only `clockwork/`,
   `field/`, `forest/`, `girl-coffee/` existed). `lock.sh` sets
   `QS_THEME_PATH=…/themes_link/clockwork-orbital` → the theme `Loader`
   errors (`FAILED to load theme`) → `WlSessionLockSurface` keeps its
   `color: "black"` → cursor + no form. The fetch likely failed twice on the
   blob checkout (network), while the theme *had* been registered in the
   sparse pattern list — so later fetches short-circuit oddly.
2. **Unsupervised lock holder (why the safety net stayed silent ~13 min).**
   The watchdog only monitors its own `lockProc` child (instance #2). The
   orphan (instance #1) held the session lock and its failure was invisible.
   The safe-fallback only engaged after *both* were killed.
3. **Contributing: git version.** Installed git rejects
   `sparse-checkout add --no-cone` (`unknown option`); the fallback chain
   (`add` in cone mode) registers patterns but the blob fetch still needs
   network at checkout — flaky at the time. No retry exists.

## Recovery performed (as documented for future use)

```bash
# 1. Drop every lock client (hung instances hold the session lock)
pkill -f lock_shell.qml

# 2. Release the stranded compositor lock (session-lock unlock cycle)
XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
  ~/.config/omarchy/plugins/mark.lock-themes/tools/release-session-lock.sh

# 3. Materialize the wanted theme's assets (git worked once network recovered)
cd ~/.local/share/omarchy/mark.lock-themes/assets
git sparse-checkout add themes/clockwork/orbital && git checkout

# 4. Re-select the theme through the plugin (keeps plugin state coherent)
omarchy-shell mark.lock-themes setLockTheme clockwork-orbital
```

After step 1 the watchdog did its job on its own: released the stranded lock
and relaunched with the safe `girl-coffee` theme (status message: `Themes:
"clockwork-orbital" failed to lock — using girl-coffee instead`). The black
screen was therefore always recoverable with one's own password.

## Hardening recommendations (not yet implemented)

- **Verify before launch:** in `launchLockProc()`/`themedLock()`, assert
  `themes_link/<theme>/Main.qml` exists *immediately before* running
  `lock.sh`; if absent → go straight to the safe-theme fallback, don't
  launch. Optionally have `lock.sh` fail fast on a missing theme dir so even
  unsupervised launches die instantly (which the watchdog then treats as a
  crash and recovers).
- **Orphan sweep on shell start:** on `Component.onCompleted`, probe for a
  stranded session lock not owned by this shell (native lock already has this
  via `checkStrandedLock`) and sweep pre-existing `lock_shell.qml` processes
  started before the current shell's start time — kill them so the session
  lock can't be held by an unsupervised client.
- **Fetch retry + git-version detection:** retry `ensureThemeAssets()`
  (2–3×, backoff) before declaring failure; detect `--no-cone` support (try
  once, then use cone-mode `add <path>` which works for directory paths) and
  mirror that in `prepareAssetsBase()`.
- **Visible failure state:** when a theme fails to load, render something
  non-black (error text + safe-theme background) instead of a black surface —
  turns a 13-minute lockout into an obvious "theme X failed" UI.

## Second occurrence (same day, 17:33) — flat-link gap

~2 h after the first rescue, `Super+L` black-screened again with the same
symptom and theme. Root cause refined: the lock app resolves the theme by its
**flat name** (`themes_link/clockwork-orbital`), but that name is a symlink to
`themes/clockwork/orbital` that `applyNestedLinks()` only creates at
lock-app-install / theme-scan time — and the scan sees only what is
**materialized on disk at that moment**. The sub-theme was fetched later
(including by the first fix) but the flat link was never (re)created, so
`lock.sh` still pointed at a nonexistent `themes_link/clockwork-orbital`.
Materializing the sub-theme alone is NOT sufficient: **the flat link is the
actual load path.**

The watchdog again did its job once the stuck child was killed (journal:
`17:47:57 themed lock crashed with "clockwork-orbital" — falling back to
girl-coffee`; `17:48:16 killing themed lock (lock never secured (probe
confirms unlocked))`).

## Fixes applied 2026-09-04 (second pass)

- manual: `ln -sfn …/assets/themes/clockwork/orbital …/assets/themes/clockwork-orbital`
  (the exact link `applyNestedLinks()` would make)
- `Service.qml → ensureThemeAssets()`: refreshes the flat link on **every**
  successful fetch (both the already-present and the freshly-checked-out
  paths), so a theme fetched after install always gets its flat name.
  Applied to the installed plugin copy and the repo copy.
- installed `lockscreen/lock.sh`: fails fast (exit 3) when
  `$QS_THEME_PATH/Main.qml` is missing — never locks a black surface.
  Verified: `bash lock.sh bogus-theme` → `exit 3`.
- `Service.qml → installLockAppInner()`: re-injects the same fail-fast check
  into `lock.sh` on every lock-app reinstall (grep-guarded, idempotent), so
  it survives upstream lock-app updates. Applied to installed + repo.
- Hot-reload confirmed in journal (`17:49:29 Local plugin changed, reloading:
  mark.lock-themes`) — no QML parse errors, shell stays up.
- Theme preference restored afterwards (`omarchy-shell mark.lock-themes
  setLockTheme clockwork-orbital`). NOTE: the watchdog's fallback calls
  `writeLockThemeFiles(girl-coffee)` and **overwrites the user's theme
  choice** — re-select after any fallback event.

## Hardening status (after second pass)

- ✅ verify-before-launch: implemented via lock.sh fail-fast (exit 3) +
  watchdog fallback — a missing theme now degrades to the safe theme, never
  a black screen. (`ensureThemeAssets()` also refreshes flat links per fetch.)
- ⬜ orphan sweep on shell start: still open — an unsupervised lock holder is
  only discovered once the supervised child dies.
- ⚠️ fetch retry + `--no-cone` detection: still open — a one-shot blob fetch
  can still fail at lock time; the fail-fast now contains the damage.
- ⬜ visible failure state (non-black error UI when a theme fails): open.
