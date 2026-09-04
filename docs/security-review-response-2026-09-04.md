# Security review response 2026-09-04: marketplace listing blocked

**Review:** HANCORE-linux, marketplace issue #4829
([comment](https://github.com/omacom/omarchy-plugin-marketplace/issues/4829#issuecomment-5545157370)),
blocked at exact commit `f16bb9b` · **Status:** fixed and validated locally;
awaiting maintainer re-review
**Cross-refs:** README → "Security & trust model" · docs/catalog-signing.md
(ongoing release loop) · tests/run-tests.sh (offline evidence)

## The review's findings (both accepted as valid)

1. **Remote-to-root path.** `Service.qml` accepted theme `name`/`subpath`
   verbatim from the mutable remote catalog, built paths by string
   concatenation, and passed them to a pkexec helper that used `name` in
   `rm -rf`, `cp` destinations under `/usr/share/sddm/themes`, and a config
   write to `/etc/sddm.conf.d/theme.conf` — no allowlist, no containment
   check. A compromised catalog could supply traversal components and make
   the root helper delete or overwrite paths outside the intended theme
   directory (the polkit prompt is indistinguishable from a legit apply).
2. **Mutable remote-code trust boundary.** Runtime theme and lock-screen QML
   was cloned, pulled, and checked out from mutable upstream repository
   heads with no commit pinning or digest binding. A later upstream or
   catalog compromise would become unreviewed code in the session lock
   screen and in the privileged SDDM theme location.

Non-blockers confirmed by the reviewer: themed lock, SDDM integration,
backgrounds, media behavior.

## Fix architecture (commits `3849d1d`, `6eb9577`, `f46d790`)

The catalog's `index.json` is now a **signed manifest**
(`{ commit, lockTree, themes: [{ name, subpath, tree, … }] }`), produced by
`tools/build-catalog.sh` and verified before anything is loaded.

| Reviewer demand | Implementation |
| --- | --- |
| Strict single-component theme names; normalized relative subpaths | Path policy (`[A-Za-z0-9][A-Za-z0-9._-]*` per component, no `..`, no separators, no control chars) enforced in three independent layers: `parseCatalog` (Service.qml), `tools/verify-catalog.sh` (jq), and the polkit helper. Rejecting entries at parse time means hostile catalog strings can no longer reach any filesystem operation, root or otherwise. |
| Canonical-path containment inside the privileged helper; refuse symlinks and traversal | `tools/install-sddm.sh` re-validates the name, `realpath`-resolves source and destination, requires the source to canonicalize inside the invoking user's plugin assets dir (via `PKEXEC_UID`), refuses symlinked path components inside the allowed prefix, and refuses any destination escaping the themes dir. Existing config is backed up before the write. |
| Never use remote catalog strings in privileged deletion or config writes | Name policy at parse + helper re-validation (defense in depth). The helper cannot be reached with a name that failed the policy. |
| Runtime assets and executable QML bound to an immutable reviewed commit + independently verified digests; trusted manifest maps each approved theme name to its exact path and hashes | The signed manifest records the reviewed upstream commit, the lock app's git tree SHA, and a per-theme git tree SHA. The asset clone is **checked out at exactly that commit** (never the mutable head) and every tree is re-verified (`git rev-parse HEAD:<path>`) at sync time and again before each theme's apply/install. Git's content-addressed objects verify blob hashes on checkout, so the recorded tree SHAs are the independent digests. An upstream force-push makes the pinned commit unavailable → **fail closed**, never a silent fallback to the new head. |
| Helper receives only an approved identifier and resolves paths from the trusted manifest itself | **Deliberate deviation.** The helper validates the identifier and resolves/confines paths itself, but trust decisions (signature + digest verification) live in the client. A root helper reading a user-writable manifest to resolve paths would be a local privilege escalation on multi-user machines; the split — client owns trust, helper owns confinement — meets the demand's goal (remote strings never directly drive root ops) without creating a user→root channel. |

Supporting changes:

- `tools/verify-catalog.sh` — two modes: signature + structure/policy, and
  commit + tree pinning; both used by the plugin before any theme can run.
- `tools/qylock-oma-signers` — allowed_signers file with the author's
  ed25519 public key (principal `qylock-catalog@mjtiempo`), reviewed at
  listing time. The private key stays with the author; `docs/catalog-signing.md`
  is the ongoing release loop.
- `tests/run-tests.sh` — 34 offline tests covering signature rejection
  (tamper, wrong key/principal, missing sig), policy rejection (traversal,
  slashes, `..`, newlines, leading dots, absolute/empty components, bogus
  SHAs, legacy format), tree pinning (commit/lockTree/theme mismatch,
  missing-at-commit), and helper confinement.

### Bug found during live validation (fixed in `f46d790`)

The polkit bootstrap only checked that the helper *existed*, so a plugin
update left the **stale pre-hardening helper** installed under
`/usr/share/qylock-oma/` (843 bytes vs the new 3569). Every apply now
byte-compares the installed helper and policy against the bundled copies
(sha256) and re-bootstraps on mismatch. Verified live: the installed helper
is byte-identical to the bundled one.

## Verification evidence

- `tests/run-tests.sh`: 34/34 pass (offline, no root).
- Real-data pipeline: manifest built from the live catalog's 40 entries
  against upstream `f86d3f6` → `SIG_OK`, `TREES_OK 40`.
- `omarchy plugin validate` on a fresh clone: exit 0.
- Live cycle on the author's machine after reinstall: signed catalog sync
  (`Synced 40 themes (catalog @ f86d3f6)`), lock theme apply (flat +
  nested-subpath), tree-verified theme fetch, background apply, SDDM apply
  through the real polkit prompt with the hardened helper, and the themed
  lock on `Super+L`.
- Catalog release published: `mjtiempo/qylock-oma-catalog` @ `06fc9be`
  (manifest pinned to upstream `f86d3f6`).

## Residual trust model (documented, accepted)

- **The author's signing key is the trust anchor.** Anyone who can publish
  a manifest the plugin accepts needs the private key. This is the standard
  package-maintainer model; the marketplace reviews the verification
  machinery once, and the author curates what gets signed.
- **One-time bootstrap prompt** copies the helper/policy from the
  user-writable plugin dir into `/usr/share` (raw polkit prompt). This is
  the standard installer pattern for user-installed plugins; subsequent
  runs execute the root-owned, hash-pinned copy.
- **Self-inflicted changes are out of scope:** a user who edits
  `tools/qylock-oma-signers` to trust another key, or points `repo`/
  `catalogRepo` at other remotes, is choosing to trust those sources
  (documented in the README).
- Theme content itself is QML that runs in the lock screen (user level) and
  SDDM (root) — its authorship is reviewed by the author at manifest
  release time, not by the marketplace.

## Commits

| Commit | Change |
| --- | --- |
| `3849d1d` | signed catalog + pinned commit trust boundary (QML + scripts + tests) |
| `6eb9577` | real signing public key + script usage guards |
| `f46d790` | re-bootstrap the polkit helper when the bundled version changes |
