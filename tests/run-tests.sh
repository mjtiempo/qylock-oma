#!/bin/sh
# Offline test suite for the QyLock trust boundary:
#   * tools/verify-catalog.sh — signature, policy, commit + tree pinning
#   * tools/install-sddm.sh   — name policy + path confinement (no root)
#
# No network, no root needed. Run from anywhere:  tests/run-tests.sh
set -u
cd "$(dirname "$0")/.."

T="$(mktemp -d /tmp/qylock-tests.XXXXXX)"
trap 'rm -rf "$T"' EXIT

pass=0; failn=0
ok()  { pass=$((pass+1)); echo "  ok:   $1"; }
bad() { failn=$((failn+1)); echo "  FAIL: $1"; }

expect_pass() {
  desc="$1"; shift
  if "$@" >"$T/out.log" 2>&1; then ok "$desc"; else
    bad "$desc"; sed 's/^/        | /' "$T/out.log"
  fi
}
expect_fail() {
  desc="$1"; shift
  if "$@" >"$T/out.log" 2>&1; then bad "$desc (expected failure)"; else ok "$desc"; fi
}

echo "== fixtures =="

# --- fake upstream theme repo ------------------------------------------
UP="$T/upstream"
mkdir -p "$UP/quickshell-lockscreen/shim" "$UP/themes/girl-coffee" "$UP/themes/other/basic"
cd "$UP"
git init -q
git config user.email test@example.com
git config user.name test
printf 'lock'  > quickshell-lockscreen/lock.sh
printf 'qml'   > quickshell-lockscreen/lock_shell.qml
printf 'shim'  > quickshell-lockscreen/shim/SddmShim.qml
printf 'm1'    > themes/girl-coffee/Main.qml
printf 'c1'    > themes/girl-coffee/theme.conf
printf 'bg'    > themes/girl-coffee/bg.png
printf 'm2'    > themes/other/basic/Main.qml
printf 'c2'    > themes/other/basic/theme.conf
git add -A
git commit -qm init
COMMIT="$(git rev-parse HEAD)"
LOCKTREE="$(git rev-parse HEAD:quickshell-lockscreen)"
GIRLTREE="$(git rev-parse HEAD:themes/girl-coffee)"
OTHERTREE="$(git rev-parse HEAD:themes/other/basic)"
cd - >/dev/null

# --- catalog + signing key ---------------------------------------------
CAT="$T/catalog"; mkdir -p "$CAT"
KEY="$T/testkey"
ssh-keygen -q -t ed25519 -N "" -f "$KEY"
printf 'qylock-catalog@test ssh-ed25519 %s\n' "$(cut -d' ' -f2 "$KEY.pub")" > "$T/signers"

python3 - "$COMMIT" "$LOCKTREE" "$GIRLTREE" "$OTHERTREE" > "$CAT/index.base.json" <<'PY'
import json, sys
commit, locktree, girl, other = sys.argv[1:5]
json.dump({"commit": commit, "lockTree": locktree, "themes": [
  {"name": "girl-coffee", "subpath": "girl-coffee", "tree": girl,
   "main": True, "conf": True, "video": False, "color": "",
   "risky": False, "flattenedFrom": "", "preview": "previews/girl-coffee.png"},
  {"name": "basic", "subpath": "other/basic", "tree": other,
   "main": True, "conf": True, "video": False, "color": "",
   "risky": False, "flattenedFrom": "", "preview": ""},
]}, sys.stdout, indent=2)
PY
cp "$CAT/index.base.json" "$CAT/index.json"
rm -f "$CAT/index.json.sig"
ssh-keygen -q -Y sign -f "$KEY" -n file -I qylock-catalog@test "$CAT/index.json"

# --- pinned assets clone (what prepareAssetsBase produces) --------------
ASSETS="$T/assets"
git clone -q --filter=blob:none --sparse --no-checkout "$UP" "$ASSETS"
git -C "$ASSETS" sparse-checkout set --no-cone quickshell-lockscreen themes/girl-coffee >/dev/null 2>&1
git -C "$ASSETS" checkout -q "$COMMIT"

# hostile() builds a signed-but-bad manifest from the base, then the
# verifier must reject it.
hostile() {
  desc="$1"; code="$2"
  python3 -c "
import json
d=json.load(open('$CAT/index.base.json'))
$code
json.dump(d, open('$CAT/index.json','w'))
" || { bad "$desc (fixture build failed)"; return 1; }
  rm -f "$CAT/index.json.sig"
  ssh-keygen -q -Y sign -f "$KEY" -n file -I qylock-catalog@test "$CAT/index.json"
  expect_fail "$desc" tools/verify-catalog.sh "$CAT/index.json" "$T/signers" qylock-catalog@test file
}

echo "== signature =="
expect_pass "valid signed manifest" \
  tools/verify-catalog.sh "$CAT/index.json" "$T/signers" qylock-catalog@test file
sed -i 's/"girl-coffee"/"girl-coffex"/' "$CAT/index.json"
expect_fail "tampered manifest (stale signature)" \
  tools/verify-catalog.sh "$CAT/index.json" "$T/signers" qylock-catalog@test file
cp "$CAT/index.base.json" "$CAT/index.json"
rm -f "$CAT/index.json.sig"
ssh-keygen -q -Y sign -f "$KEY" -n file -I qylock-catalog@test "$CAT/index.json"
ssh-keygen -q -t ed25519 -N "" -f "$T/otherkey"
printf 'qylock-catalog@test ssh-ed25519 %s\n' "$(cut -d' ' -f2 "$T/otherkey.pub")" > "$T/othersigners"
expect_fail "signature from a different key" \
  tools/verify-catalog.sh "$CAT/index.json" "$T/othersigners" qylock-catalog@test file
expect_fail "wrong principal" \
  tools/verify-catalog.sh "$CAT/index.json" "$T/signers" someone-else file
rm "$CAT/index.json.sig"
expect_fail "missing signature file" \
  tools/verify-catalog.sh "$CAT/index.json" "$T/signers" qylock-catalog@test file
rm -f "$CAT/index.json.sig"
ssh-keygen -q -Y sign -f "$KEY" -n file -I qylock-catalog@test "$CAT/index.json"

echo "== policy =="
hostile "traversal name"          "d['themes'][0]['name']='../../etc/foo'"
hostile "name with slash"         "d['themes'][0]['name']='a/b'"
hostile "name with dotdot"        "d['themes'][0]['name']='x..y'"
hostile "name with newline"       "d['themes'][0]['name']='evil\\nx'"
hostile "name with leading dot"   "d['themes'][0]['name']='.hidden'"
hostile "traversal subpath"       "d['themes'][0]['subpath']='../evil'"
hostile "absolute subpath"        "d['themes'][0]['subpath']='/etc'"
hostile "double-slash subpath"    "d['themes'][0]['subpath']='a//b'"
hostile "missing tree"            "del d['themes'][0]['tree']"
hostile "bogus tree sha"          "d['themes'][0]['tree']='z'*40"
hostile "bogus commit sha"        "d['commit']='z'*40"
hostile "missing lockTree"        "del d['lockTree']"
hostile "old list format"         "d = d['themes']"

echo "== tree pinning =="
cp "$CAT/index.base.json" "$CAT/index.json"
rm -f "$CAT/index.json.sig"
ssh-keygen -q -Y sign -f "$KEY" -n file -I qylock-catalog@test "$CAT/index.json"
expect_pass "trees match pinned commit" \
  tools/verify-catalog.sh --trees "$CAT/index.json" "$ASSETS" quickshell-lockscreen
out="$(tools/verify-catalog.sh --trees "$CAT/index.json" "$T/nonexistent" quickshell-lockscreen)"
case "$out" in *NO_ASSETS_SKIPPED*) ok "missing assets clone -> skipped";; *) bad "missing assets clone (got: $out)";; esac
python3 -c "
import json
d=json.load(open('$CAT/index.base.json'))
d['commit']='0'*40
json.dump(d, open('$CAT/index.json','w'))
"
expect_fail "assets commit does not match manifest" \
  tools/verify-catalog.sh --trees "$CAT/index.json" "$ASSETS" quickshell-lockscreen
python3 -c "
import json
d=json.load(open('$CAT/index.base.json'))
d['lockTree']='0'*40
json.dump(d, open('$CAT/index.json','w'))
"
expect_fail "lock app tree mismatch" \
  tools/verify-catalog.sh --trees "$CAT/index.json" "$ASSETS" quickshell-lockscreen
python3 -c "
import json
d=json.load(open('$CAT/index.base.json'))
d['themes'][0]['tree']='z'*40
json.dump(d, open('$CAT/index.json','w'))
"
expect_fail "theme tree mismatch" \
  tools/verify-catalog.sh --trees "$CAT/index.json" "$ASSETS" quickshell-lockscreen
python3 -c "
import json
d=json.load(open('$CAT/index.base.json'))
d['themes'].append({'name':'ghost','subpath':'ghost','tree':'2'*40,'main':True,'conf':True})
json.dump(d, open('$CAT/index.json','w'))
"
expect_fail "theme missing at pinned commit" \
  tools/verify-catalog.sh --trees "$CAT/index.json" "$ASSETS" quickshell-lockscreen

echo "== install-sddm confinement =="
SRCPREFIX="$T/sddsrc"; mkdir -p "$SRCPREFIX/oktheme"
printf 'm' > "$SRCPREFIX/oktheme/Main.qml"
DEST="$T/sddm-dest"; CONF="$T/sddm-dest.conf"
QYLOCK_SRC_PREFIX="$SRCPREFIX"; export QYLOCK_SRC_PREFIX
expect_pass "valid install" \
  tools/install-sddm.sh oktheme "$SRCPREFIX/oktheme" "$DEST" "$CONF"
[ -f "$DEST/oktheme/Main.qml" ] && grep -q 'Current=oktheme' "$CONF" \
  && ok "dest + conf written" || bad "dest + conf written"
expect_pass "valid re-install (replaces existing dir)" \
  tools/install-sddm.sh oktheme "$SRCPREFIX/oktheme" "$DEST" "$CONF"
[ -n "$(ls "$DEST" | head -1)" ] || bad "dest dir populated after re-install"
expect_fail "traversal name" \
  tools/install-sddm.sh ../../evil "$SRCPREFIX/oktheme" "$DEST" "$CONF"
expect_fail "name with slash" \
  tools/install-sddm.sh "a/b" "$SRCPREFIX/oktheme" "$DEST" "$CONF"
expect_fail "name with newline" \
  tools/install-sddm.sh "$(printf 'evil\nx')" "$SRCPREFIX/oktheme" "$DEST" "$CONF"
expect_fail "name with leading dot" \
  tools/install-sddm.sh .hidden "$SRCPREFIX/oktheme" "$DEST" "$CONF"
expect_fail "missing source" \
  tools/install-sddm.sh oktheme "$SRCPREFIX/nope" "$DEST" "$CONF"
mkdir -p "$T/outside"
expect_fail "source outside prefix" \
  tools/install-sddm.sh oktheme "$T/outside" "$DEST" "$CONF"
ln -s "$SRCPREFIX/oktheme" "$SRCPREFIX/linktheme"
expect_fail "symlinked source component" \
  tools/install-sddm.sh linktheme "$SRCPREFIX/linktheme" "$DEST" "$CONF"

echo
echo "passed: $pass  failed: $failn"
[ "$failn" -eq 0 ] || exit 1
