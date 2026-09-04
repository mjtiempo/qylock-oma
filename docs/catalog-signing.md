# Publishing a catalog release (author side)

The plugin only loads `index.json` from the catalog repo when:

1. `index.json.sig` verifies against the public key in
   `tools/qylock-oma-signers` (ssh-keygen ed25519, namespace `file`), and
2. every entry's `tree` SHA matches the upstream checkout pinned by the
   manifest's `commit`.

A catalog release therefore publishes a specific, reviewed upstream commit.

## One-time key setup

```sh
ssh-keygen -t ed25519 -N "" -f ~/.ssh/qylock-catalog-signing -C qylock-catalog-signing
```

Put the public key into the plugin repo (`tools/qylock-oma-signers`), one
line, principal first — the principal must match `catalogSignerId` in
`Service.qml`:

```text
qylock-catalog@mjtiempo ssh-ed25519 <contents of ~/.ssh/qylock-catalog-signing.pub>
```

Keep the private key offline/private. Anyone with it can publish themes the
plugin will trust.

## Reviewing an upstream commit

```sh
git clone https://github.com/Darkkal44/qylock.git /tmp/qylock-review
cd /tmp/qylock-review
git log --oneline -5          # pick the commit to publish
git checkout <commit>         # review themes/* and quickshell-lockscreen/*
```

Sanity checks while reviewing:

```sh
# every listed theme dir has the files the plugin requires
ls themes/*/Main.qml 2>/dev/null | wc -l
# the lock app subdir exists
test -f quickshell-lockscreen/lock_shell.qml && echo ok
```

## Building and signing the manifest

From the catalog repo (with the previous `index.json` present — its curated
metadata such as flags and preview paths is reused):

```sh
tools/build-catalog.sh /tmp/qylock-review /path/to/qylock-oma-catalog \
  ~/.ssh/qylock-catalog-signing qylock-catalog@mjtiempo
```

This writes `index.json` (now a manifest object with `commit`, `lockTree`,
and per-entry `tree`) and `index.json.sig`.

**Before pushing, self-check the same way the plugin does:**

```sh
cd /path/to/qylock-oma-catalog
tools/verify-catalog.sh index.json <plugin-repo>/tools/qylock-oma-signers qylock-catalog@mjtiempo
# after a pinned checkout of the recorded commit exists in a clone:
tools/verify-catalog.sh --trees index.json <assets-clone> quickshell-lockscreen
```

Then commit and push `index.json` + `index.json.sig`.

## Notes

- The upstream repo's HEAD is **not** what users get — they get exactly the
  `commit` recorded here. New upstream themes appear only after you review
  and publish a new signed manifest.
- If the upstream repo rewrites history (force-push), the pinned commit may
  disappear: users then fail closed ("theme missing at pinned commit")
  rather than silently fetching something else.
- `tests/run-tests.sh` in the plugin repo exercises the verifier and the
  polkit helper against hostile fixtures; run it after changing either.
