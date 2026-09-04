#!/bin/sh
# QyLock catalog release tool (author side). Rebuilds index.json from the
# curated previous index (metadata source) plus a fresh upstream checkout at
# the commit being reviewed, records the reviewed commit + tree SHAs, and
# signs the manifest with the author's ed25519 key (ssh-keygen -Y sign).
#
# Usage:
#   build-catalog.sh <upstream-checkout> <catalog-dir> <signing-key> <principal>
#
#   <upstream-checkout>  git checkout of Darkkal44/qylock at the exact commit
#                        being reviewed/published (its HEAD is recorded)
#   <catalog-dir>        the qylock-oma-catalog repo working dir (contains
#                        the previous index.json and previews/)
#   <signing-key>        private ed25519 key, ssh-keygen format
#   <principal>          identity recorded in the signature — must match the
#                        principal in the plugin's tools/qylock-oma-signers
#
# One-time key setup:
#   ssh-keygen -t ed25519 -N "" -f ~/.ssh/qylock-catalog-signing -C qylock-catalog-signing
# then put the public key into tools/qylock-oma-signers in the plugin repo:
#   qylock-catalog@mjtiempo ssh-ed25519 <contents of ~/.ssh/qylock-catalog-signing.pub>
set -eu

up="${1:-}"; catdir="${2:-}"; key="${3:-}"; principal="${4:-}"
[ -n "$up" ] && [ -n "$catdir" ] && [ -n "$key" ] && [ -n "$principal" ] \
  || { echo "usage: $0 <upstream-checkout> <catalog-dir> <signing-key> <principal>" >&2; exit 2; }
[ -d "$up/.git" ] || { echo "upstream checkout missing: $up" >&2; exit 2; }
[ -f "$catdir/index.json" ] || { echo "catalog index missing: $catdir/index.json" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not available" >&2; exit 2; }

commit="$(git -C "$up" rev-parse HEAD)"
locktree="$(git -C "$up" rev-parse HEAD:quickshell-lockscreen)" \
  || { echo "upstream checkout has no quickshell-lockscreen/ at HEAD" >&2; exit 2; }
echo "publishing upstream commit: $commit"
echo "lock app tree:            $locktree"

python3 - "$commit" "$locktree" "$up" "$catdir" <<'PYEOF'
import json, subprocess, sys
commit, locktree, up, catdir = sys.argv[1:5]
prev = json.load(open(catdir + "/index.json"))
# tolerate the old list format and the new manifest format
if isinstance(prev, dict) and isinstance(prev.get("themes"), list):
    prev = prev["themes"]
entries = []
for e in prev:
    sub = str(e.get("subpath") or e["name"])
    try:
        tree = subprocess.check_output(
            ["git", "-C", up, "rev-parse", "HEAD:themes/" + sub],
            text=True, stderr=subprocess.STDOUT).strip()
    except subprocess.CalledProcessError as ex:
        print("error: theme missing at pinned commit: %s\n%s" % (sub, ex.output), file=sys.stderr)
        sys.exit(2)
    ne = dict(e)
    ne["subpath"] = sub
    ne["tree"] = tree
    entries.append(ne)
manifest = {"commit": commit, "lockTree": locktree, "themes": entries}
with open(catdir + "/index.json", "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print("entries: %d" % len(entries))
PYEOF

cd "$catdir"
rm -f index.json.sig
ssh-keygen -Y sign -f "$key" -n file -I "$principal" index.json
echo "wrote $catdir/index.json + index.json.sig"
echo "NOTE: commit index.json and index.json.sig, then push before announcing."
