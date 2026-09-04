# Live wallpaper plan — AnimatedImage / Video backgrounds for qylock-oma

Scope: make the **Background** tab of *QyLock Oma* animate when a theme's artwork is a
GIF or a video (`.mp4/.webm/.mkv/.mov`), while keeping the current static-image
behavior as the safe default.

This is a two-repo effort. The plugin (this repo, `qylock-oma`) only decides *what to
send*; the actual rendering lives in **Omarchy's background plugin**
(`/usr/share/omarchy/shell/plugins/background/Background.qml`, system-owned, upstream
elsewhere). ~90% of the work is in that renderer. **Upstreaming is the follow-up.**

---

## ⚡ Implementation status — 2026-09-04 (local, not pushed)

**Implemented end-to-end and verified on this machine** (see commit log):

- **Phase 0 answered: shadowing is impossible.** `PluginRegistry.qml` (`parseScanOutput`)
  rejects any third-party manifest whose id collides with a first-party id or starts
  with `omarchy.` — `omarchy.background` is a first-party id, so a copy under
  `~/.config/omarchy/plugins/omarchy.background` is silently dropped (runtime-proven:
  a `shadowtest` manifest with that id never appeared in `shell listPlugins`).
  Replacement vehicle: **takeover plugin `mark.live-background`** (this repo,
  `live-background/`) — a third-party service that registers the same
  `IpcHandler { target: "background" }` after `omarchy.background` is disabled
  (`disabledPlugins` + `plugins[]` in `shell.json`). Disable-first is mandatory:
  two live handlers for one target corrupts Quickshell's IPC registry
  (quickshell-mirror/quickshell#898).
- **Tier 1 re-prioritized.** 0 of 27 themes ship GIF/APNG backgrounds (the
  `Assets/*.gif` culture is menu *previews*, not wallpaper art); 16 of 27 are video.
  GIF/APNG support still ships (manual `omarchy theme bg set x.gif` users), but Tier 2
  is the feature that lights up the catalog.
- **qylock-oma Phase 1 done** (`Service.qml`, `Menu.qml`, `manifest.json` 1.28.0,
  `README.md` § Animated backgrounds): video pass-through, `readlink -f` readback
  confirm, `animatedBg` config (auto-enabled when the takeover renderer is detected in
  `shell.json`; overridable via `config.json`/`shell.json`/menu toggle), video badge +
  toggle in the menu. The review.md status line was already restored, so 1.4 simplified
  to the badge only.
- **Renderer Phase 2 done** (`live-background/Background.qml` + `VideoWallpaper.qml`):
  type-dispatching surfaces (image / AnimatedImage / QtMultimedia video), media-aware
  reveal gating and completion cleanup, same-path replay bypass, fail-safe (keep
  previous surface; dark fallback rect so cold-start + corrupt file is never pure
  black), mute + `PreserveAspectCrop` + infinite loop, pause when the session is
  locked (probe poll), per-screen players, double-click switcher handlers preserved.
- **Bug fixed along the way:** `ensureThemeAssets`/`prepareAssetsBase` used
  `sparse-checkout add --no-cone` which git 2.55 rejects → always fell back to `set`,
  and `set` replaces the pattern list, so each new theme fetch PRUNED previously
  fetched themes (girl-coffee, the applied wallpaper file!) from disk. Both now
  `add`-first with `set` only as last resort (observed live, twice).
- **Verified:** static apply (service path + readback CONFIRMED), GIF route
  (`[gif]` switch), video apply (h264 2560x1440 `bg.mp4` decoded on both panels,
  "video committed"), same-path replay (dedupe bypass, media restarts), corrupt-file
  fallback ("video failed → previous surface kept"), multi-monitor (2 per-screen
  layers), lock-pause (player held while locked). *Motion/visual confirmation pending
  the session being unlocked* — the session was locked at handoff and remains so
  (restored via `omarchy-shell lock lock` after the lock client was taken down by a
  shell restart).

**Remaining / known:**

- Upstream PR (2.8) — the fork serves locally; upstreaming is the durable path.
- `vainfo` not installed (libva + `radeonsi_drv_video.so` present) — VA-API
  engagement not yet asserted; decode worked without errors.
- Battery delta (1–2 h `energy_rate` comparison) not measured.
- Lock app (`lockProc`) dies whenever plugins reload (service destroy kills the
  Process child) — pre-existing, surfaced by this work; the lock screen must be
  relaunched after any plugin-file change.
- Fullscreen-cover pause (2.6) not implemented (v1 = pause-on-locked only).

---

## 1. How it works today (verified ground truth)

| Layer | Where | What it does |
| --- | --- | --- |
| Theme artwork | `Service.qml:454` | A theme is a *video theme* when its `background=` in `theme.conf` matches `*.mp4\|*.webm\|*.mkv\|*.mov`. Already detected and tagged end-to-end (`video: true` in the catalog, `t.video`, ▶ placeholder in the grid). |
| Apply | `Service.qml:763` `applyBackground()` | Extracts `background=` from `theme.conf`, checks the file exists, then **refuses video themes** (`Service.qml:769`: "has no image background to apply (video theme)") and runs `omarchy theme bg set <image>`. |
| State link | `omarchy-theme-bg-set` | `realpath` check → `ln -nsf <bg> ~/.local/state/omarchy/current/background` → IPC push `omarchy-shell -q background set <path>`. The `-f` check already passes for video files. |
| Renderer | `Background.qml` | Per-screen `PanelWindow` on `WlrLayershell.layer: WlrLayer.Background`, rendering a **static `Image`** (`base`, line ~223) with a crossfade `oldFrame` + reveal mask. Transition machinery is keyed to `Image.Ready` status events (`Background.qml:207–215`). `IpcHandler { target: "background" }` handles `set`/`setInstant`/`transition` (line 131). Dedupe: same path twice is a no-op (line 45). |
| Proven video path | lock app `.local/share/omarchy/mark.lock-themes/lockscreen/imports/QtMultimedia/Video.qml` | The themed lock app already plays video in Quickshell: a `Video` wrapper around `Native.VideoOutput` + `Native.MediaPlayer` (loops, mute-able, `PreserveAspectCrop`), resolving relative sources against `QS_THEME`. **QtMultimedia 6.0 works in Quickshell on this machine.** |

Key enablers:

- `AnimatedImage` **is** an `Image` subclass (same `source`/`fillMode`/`cache`/`status` properties) → the existing `Image` slot in `Background.qml` is property-compatible for GIF/APNG with almost no change.
- The pipeline is already **path-agnostic**: symlink → `readlink -f` → `IpcHandler.set(path)`. It will carry a `.mp4` today; only the renderer can't display it.
- The plugin already fetches videos lazily on Apply/Preview (`Service.qml:55`), so no new download machinery.

## 2. Design decision: two tiers

**Tier 1 — GIF/APNG (AnimatedImage).** Tiny renderer diff (element swap + fallback).
Covers themes whose artwork is an animated GIF/APNG; no codec risk. Matches the
repo's existing `Assets/*.gif` culture. Ship this first.

**Tier 2 — Video (QtMultimedia).** Real mp4/webm playback via the lock app's proven
`Video`-wrapper pattern. Needs loop, mute, crop, and hardware-decode care (VA-API).
This is what the existing *video themes* (▶ in the grid) would light up.

Recommended: **Tier 1 first as a vertical slice through the whole pipeline**
(plugin → bg-set → renderer), then Tier 2 on the same plumbing. Do *not* build Tier 2
before the shadow-plugin question (Phase 0) is answered.

## 3. Phased steps

### Phase 0 — Spikes that gate everything (0.5 day)

- [ ] **Plugin shadowing**: copy `omarchy/background` from `/usr/share/omarchy/shell/plugins/` to `~/.config/omarchy/plugins/omarchy.background` and confirm the local copy wins over the system one (check how omarchy-shell resolves plugin ids; if duplicate ids collide, find the override mechanism or an uninstall path for the system plugin).
- [ ] **Background-layer render verification**: with `updatesEnabled: true` already forced (the code comments warn the background layer parks buffers otherwise — `Background.qml:199`), confirm a test `AnimatedImage`/`Video` surface on the Background layer keeps producing frames (i.e. media isn't pulse-driven and parking doesn't freeze it).
- [ ] **QtMultimedia availability at background-plugin runtime**: `import QtMultimedia 6.0` loads in a throwaway shadow copy (same import the lock app uses).
- [ ] **Path plumbing**: confirm `omarchy theme bg set <video>` passes the `realpath`/`-f` check and `readlink -f` resolves the video to the plugin unchanged.
- [ ] **Dedupe semantics**: pin down `setBackground`'s same-path no-op (line 45) for media — a replay needs a forced restart (see Phase 2, step 2.5).

### Phase 1 — qylock-oma: stop refusing, send the media, fail safely (0.5 day)

- [ ] **1.1** `applyBackground()` (`Service.qml:763`): replace the `t.video` refusal with a pass-through — the apply target is always the `background=` asset (image *or* video). No new download code (`ensureThemeAssets` already fetches videos).
- [ ] **1.2** Post-apply confirmation must read back the resolved background (`readlink -f current/background`), **not** just `omarchy theme bg set`'s exit code — a video that fails to *render* still exits 0. Show a failure only when the file is missing/undecodable.
- [ ] **1.3** Safety valve: add `animatedBg` (default **off until the renderer ships**, then on) to `config.json` so a user can force static behavior for video themes; the menu footer/status mentions "video bg applied" instead of "background applied".
- [ ] **1.4** Menu polish on the Background tab: video themes already show ▶; add a small "animated" marker on the tile and (if a status line is restored per the `review.md` findings) surface `root.message` for bg apply results — apply failures are currently invisible.
- [ ] **1.5** Unit-ish sanity: applying the *same* theme twice must still round-trip (the service writes a fresh `request.json` each time — timestamps differ — so the watcher path is fine; only the renderer dedupe matters, handled in 2.5).

### Phase 2 — Omarchy background renderer: the actual work (1–2 days)

On the shadow copy of `Background.qml`:

- [ ] **2.1** Detect media by extension in `setBackground()`: image vs `gif/apng` vs `mp4/webm/mkv/mov` (mirror the `Service.qml:454` case logic).
- [ ] **2.2** Per-screen `base` element becomes a type-dispatching pick:
  - image → the existing `Image` (unchanged path, `cache: true` kept);
  - gif/apng → `AnimatedImage` (same source/fillMode, `cache: false`, `asynchronous: true`);
  - video → `Native.VideoOutput` + `Native.MediaPlayer` cloned from the lock app's `Video.qml` semantics: **muted by default** (`AudioOutput.muted`), `loops: MediaPlayer.Infinite`, `PreserveAspectCrop`.
- [ ] **2.3** Transition/reveal gating: the reveal waits on `Image.Ready` (`Background.qml:207–215`). For GIF/APNG the `AnimatedImage` status still fires `Ready` (it inherits `Image`) — keep the gate. For video there is no `Ready`; gate on `mediaStatus === MediaPlayer.LoadedMedia` (or first `videoFrameChanged`). `oldFrame` fade-out is an `Image` and is unaffected.
- [ ] **2.4** Replay/dedupe: media sources must restart on same-path re-apply — reset `source` to `""` then to the path (both `AnimatedImage` and `MediaPlayer` replay semantics); keep the static-image no-op dedupe at line 45 for images.
- [ ] **2.5** Fail-safe (mirror the lock app's safe-theme philosophy): on load failure (AnimatedImage stuck not-Ready after a timeout; `MediaPlayer.error` / never-LoadedMedia) fall back to the theme's static image if one exists, else keep the previous background — the code already has an explicit "never leave a black desktop" invariant (`Background.qml:199`); media must inherit it.
- [ ] **2.6** Session hygiene (v1 minimum): always muted; pause playback while the session is locked/when a compositor fullscreen window covers the screen; resume on reveal. Optionally pause after idle timeout later.
- [ ] **2.7** Performance: confirm hardware decode engages (QtMultimedia → FFmpeg → VA-API; check `libva`/`vainfo`), verify the per-frame upload path (software decode of a fullscreen 1080p video will pin a core — that is the main perf risk).
- [ ] **2.8** **Upstream**: once proven locally, propose the renderer change to Omarchy upstream (this repo should stay thin; the renderer belongs in Omarchy, not behind a shadow copy forever).

### Phase 3 — Wrap-up for qylock-oma (0.5 day)

- [ ] **3.1** Success/error strings for video backgrounds; wire into the restored status line.
- [ ] **3.2** README: "Animated backgrounds" section — what animates (GIF, video themes), the `animatedBg` toggle, and the battery note.
- [ ] **3.3** `manifest.json` minor bump with the feature.

## 4. Testing matrix

| Case | Expected |
| --- | --- |
| GIF theme on Background tab | Animates on lock + wallpaper; crossfade still works; transition clean |
| Video theme on Background tab | Loops, muted, cropped (`PreserveAspectCrop`), doesn't cover panels (Background layer), no keyboard grab |
| Switch theme mid-playback | Old media stops, new one plays; no ghost frames |
| Apply same theme twice | Media restarts (dedupe bypass), no no-op surprise |
| Delete/corrupt the video file | Falls back to static image or prior bg — never black |
| Video without VA-API | Degrades gracefully (software decode warning, no crash); battery delta documented |
| Suspend/resume | Media resumes (MediaPlayer state handling) |
| Fullscreen app covering desktop | Playback pauses (v1), resumes after |
| Battery (1–2 h) | Compare `energy_rate` vs static bg; hardware decode must be engaged |

## 5. Risk register

- **QtMultimedia missing at runtime** — spike (Phase 0) before any Phase 2 work; fallback = Tier 1 only (AnimatedImage has no module dependency).
- **Background-layer buffer parking** — known trap (`Background.qml:199` comment); `updatesEnabled: true` is already forced; verify media frames aren't parked on power state changes.
- **Multi-monitor** — one `PanelWindow` per screen; either one `MediaPlayer` per screen (decode ×N) or single-player + static fallback on secondary screens. Cost/benefit decision in 2.2; default proposal: exact mirrors are cheaper than they look at 2 screens, but keep it a decision.
- **Dedupe vs replay** — the renderer's same-path no-op is correct for images and wrong for media; handled in 2.4, but it's the subtlest behavioral trap in the plan.
- **Ownership** — `/usr/share/omarchy` is system-owned; the shadow copy can be lost on upgrades; upstreaming (2.8) is what makes this durable.
- **Battery/heat** — a permanently repainting fullscreen surface is the exact cost the plugin's static bg avoids today; pause-when-covered and hardware decode are the two mitigations that matter.

## 6. Open questions to resolve before coding

1. Does a user-plugins copy shadow a same-id system plugin, or collide? (gates Phase 2)
2. Where does Omarchy keep the background plugin's source (upstream PR target)?
3. Multi-monitor strategy: per-screen players vs primary-only + static fallback.
4. `animatedBg` default: on (video themes animate) or off (opt-in) at first ship?
5. Tier 2 video support: reuse the lock app's `Video.qml` wrapper verbatim (it has lock-specific path resolution — needs a background-appropriate variant) vs a clean minimal wrapper.

---

*Companion doc: `review.md` (findings on removed status feedback feed Phase 1, step 1.4).*
