# PR review: menu/theme-grid UI series (stand-in for PR)

**Repo:** mjtiempo/qylock-oma · **Base:** `e660ee2^` ← **Head:** `8c9eef3` (local `main`)
**Author:** @mtiempo · **Scope:** 2 files, +97/−98 (Menu.qml, manifest.json) — 10 commits
**Note:** No open PR exists on GitHub (`gh pr list` is empty); this reviews the local commit series `e660ee2..HEAD` (theme-grid scrollbar + selection/action rework) as the change set.

## Walkthrough

**Overall impact** — this change set reworks the theme picker menu from a "row-per-theme with an action bar" UI into a square 3-row theme grid with a custom always-visible scrollbar and card-local actions (Preview/Apply on the selected tile). The bottom-right action bar, the header status captions, and the "active/selected" state text are all removed in favor of a cleaner header and a highlight-only-for-selection tile.

**Key files**

- `Menu.qml` — grid + scrollbar overlay, per-tile selection, Preview/Apply buttons, header/footer height reservations. All the work is here.
- `manifest.json` — version 1.14.0 → 1.24.0.

**Key decisions**

- Scrollbar driven *directly* from `contentY/contentHeight` bindings instead of the `Flickable.visibleArea` grouped property (which was the broken-path bug the 4 fix commits chased). This is a good call.
- Press-anywhere scrollbar: a single drag surface where press = click-jump and grab offset is captured at press time, so grabbing the handle never jumps.
- Removed all status captions (message line, theme-count/current-theme line, per-tile "● current"/"- active") for a "clean header".

**Risk areas** — the removed feedback channels (errors and current-theme visibility), static magic-number header/footer heights vs. clipped content, and the scrollbar mapping when the card height is clamped.

## Findings

### 🟡 [minor] `bug` — Menu.qml:318, 383

**The currently-applied theme is no longer visible anywhere.** `isCurrent()` is now used only to *withdraw* the selection highlight (`isSelected && !isCurrent`), and the "- active"/"● current" markers were dropped between `c5e5be9` and `8c9eef3`:

```qml
// tile fill (line 318)
color: (root.isSelected(modelData.name) && !root.isCurrent(modelData.name))
     ? Style.selectionFillFor(root.accent, root.accent)
     : Style.selectionFillFor(root.foreground, root.accent)
// tile name (line 383)
text: modelData.name + (modelData.risky ? " ⚠" : "")
```

Consequence: a user cannot tell which theme is applied, and *selecting the currently-applied theme removes even its highlight* (the condition excludes selected+current, so it falls back to the plain fill). The state data is still mirrored from the service (`currentSddm`, `currentLock`, `currentBg`, `currentLock === name && currentSddm === name`) — it just never reaches the UI.

> Why it matters: the previous UI carried an explicit "● current" marker; this series deletes it. Small fix: render a non-selection marker for `isCurrent` (e.g. name suffix "✓", a check badge, or keep the border for selected-and-current). Keep the green fill for selection only as designed, but a current theme should still be identifiable.

### 🟡 [minor] `bug` — Menu.qml:291 (header)

**All error/status feedback was removed, and failures are now silent.** The deleted captions included `root.message` — the *only* channel from the service, which sets it in `fail()` and elsewhere (`Service.qml:211` — "Cannot preview lock: …", "Unknown request op", "Auto-sync is disabled…", `Service.qml:919` — "…failed to lock — using <safe> instead"). Also removed: "N themes · SDDM: … · lock: … · bg: …" and the "No themes available yet." empty state.

Consequence: apply/preview failures and the empty-install state produce zero UI feedback. The Apply button merely re-enables when the op fails; the user can't distinguish success from failure without checking the lock screen.

> Why it matters: `root.message` and `root.phase` are still parsed from `status.json` (Menu.qml:152–158) but never rendered. Suggest restoring a compact status/error line (the deleted one was fine), or at minimum an error toast on the currently-selected card.

### 🟡 [minor] `refactor` — Menu.qml:60–72, 152–158

**Dead mirrored state left behind.** `message`, `phase`, `themeCount`, `gitAvailable`, `repoName`, `branchNow`, `commitNow`, `currentSddm`, `currentLock`, `currentBg`, `lockAppInstalled`, `lockMode`, `themedLockActive`, `lockAppDir`, `lockThemeFile` are still populated from `status.json` every poll (2s timer) but only `busy` and `lockAppInstalled`/`themedLockActive` are read by the UI. `required property int index` in the delegate is also unused.

> Why it matters: dead state invites drift (and made the two UX regressions above easy to miss). Either render a minimal status line (fixing finding #2 at the same time) or prune the unused properties. If you keep the mirrored state for future use, a short comment saying so helps.

### 🟡 [minor] `documentation` — README.md § Usage

**README still documents the pre-series UI.** § Usage describes "one row per theme with three actions: **Lock**, **SDDM**, **BG**", "shows the synced repository, its status", a **Test lock** button and a **Lock screen** switch — none of which exist in the current menu (the grid/tiles + Preview/Apply + scrollbar aren't mentioned at all). The README was already stale before this series (the repo/status/Test-lock UI predates `f3fc73c`/`eacb21b`), but it was not updated here either.

> Why it matters: user-facing docs for a plugin should describe the screen the user actually sees. At minimum update the § Usage paragraph; ideally describe tiles, per-card Preview/Apply, and the scrollbar.

### 🔵 [info] `maintainability` — Menu.qml:94–101

**Static header/footer reservations + vertical centering + `clip: true` clip content under font scaling or short panels.** `headerBlock: Style.space(104)` and `footerBlock: Style.space(40)` are magic numbers matched to the *current* font metrics; the Column is vertically centered, so content taller than the reservation (larger system font scale, two-line wrapped footer) clips symmetrically — the title's top or the footer's bottom gets cut, with no way to discover it.

Separately, on short panels `cardHeight` clamps (line 99–101) while `gridHeight` stays at 3 rows (~798px). The grid — and the scrollbar — extend under the clipped card, and the scrollbar's mapping divides by the *unclipped* `scrollTrack.height`, so the visible track is shorter than the assumed track: clicking at the visible bottom won't reach the last row, and the drag range is skewed.

> Suggestion (non-blocking): derive the header/footer reservations from the real content (`column.implicitHeight`), and compute the scrollbar scale against the *visible* (clamped) grid height when `cardHeight` is clamped.

### 🔵 [info] `maintainability` — history

- Four consecutive fix commits (`bc966f0` → `7926bde` → `1da3193` → `fbc4f56`) converge on the final scrollbar; the end state is correct, but the series reads as "build, then debug". Squashing into one "add scrollbar" + one "fix" commit would preserve the lesson with less history noise.
- `manifest.json` bumped 1.14.0 → 1.24.0 within this series (a new minor per commit). Ten minor bumps for a UI-only change set — if versioning is meaningful to users/updaters, bump once per release and let the rest be one bump.

### ⚪ [nitpick] `style` — Menu.qml:423–431

The scrollbar hit strip is 5px wide (`width: Style.space(5)`). A 5px drag target is small by Fitts' law standards. Optional: keep the 5px visual but give the `dragArea` a padded hit region (e.g., a wider transparent parent MouseArea), matching the "thin, right edge" intent without the tiny target.

## What's good

- ✅ **The scrollbar math is genuinely correct.** Mapping `f = (py − grabY)/(track − hh)` with `grabY` clamped at press time gives click-jump above the thumb (top lands on cursor), click-jump below (bottom lands on cursor), and zero jump when grabbing the thumb itself. Driving the handle from `contentY/contentHeight` (fbc4f56) avoids the `visibleArea` grouped-property immobility bug it was built to fix.
- ✅ **Buttons-on-the-selected-card is a clean consolidation.** It removed the duplicated action surface (the old bottom-right action bar duplicated Preview/Apply), and the per-tab wiring is right: Preview only in the lock tab, gated on `lockAppInstalled && !themedLockActive`, Apply per-tab semantics kept inline.
- ✅ **The request channel is untouched and robust.** `printf '%s'` + `shq()` quoting handles `%` and quoted paths safely, and the queueing in `dispatchRequest` (`pendingRequest` while busy) still works unchanged.
- ✅ **Click-vs-drag separation is handled:** `preventStealing: true` on the scrollbar keeps the Flickable from stealing a scrollbar drag, while wheel over the strip still scrolls the grid (MouseArea doesn't consume wheel) — right behavior without extra code.

## Verdict: **needs-changes 🟡**

No blockers: the scrollbar and selection/apply logic are sound, and the request path is safe. But this series removed the two pieces of feedback that keep a theme manager usable — the applied-theme marker and the error/status line — leaving `isCurrent()` and `root.message` populated-but-invisible. Fix findings #1 and #2 (small, additive UI changes), update the README paragraph, and consider the dead-state cleanup in #3 before merge. Nothing here blocks correctness; these are UX regressions vs. the previous UI rather than new bugs.

---
*Reviewed as a local series stand-in (no GitHub PR found for mjtiempo/qylock-oma). Happy to post this to a real PR if you open one, or trim to the top findings.*
