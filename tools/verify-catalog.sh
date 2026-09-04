#!/bin/sh
# QyLock catalog verification — part of the plugin's trust boundary.
#
# Mode 1 (signature + policy):
#   verify-catalog.sh <index.json> <allowed-signers> <principal> [namespace]
#   Verifies the ssh-keygen ed25519 signature of index.json (index.json.sig)
#   against the allowed_signers file shipped with the plugin, then rejects
#   manifests whose structure or theme name/subpath/tree fields violate the
#   strict single-component path policy. Exits nonzero on any failure.
#
# Mode 2 (commit + tree pinning):
#   verify-catalog.sh --trees <index.json> <assets-dir> <lock-subdir>
#   Requires the assets clone to be checked out at the manifest's recorded
#   commit and every recorded tree SHA to match. Prints NO_ASSETS_SKIPPED
#   and exits 0 when the assets clone does not exist yet (offline install).
#
# Policy (mirrored in Service.qml — keep in sync):
#   name/subpath components: first char alphanumeric, only [A-Za-z0-9._-],
#   no ".." anywhere, no empty components, no leading slash in subpaths.
#   tree/commit/lockTree: 40- or 64-char lowercase hex git object IDs.
set -u

fail() { echo "verify-catalog: $*" >&2; exit 2; }

check_policy() {
  index="$1"
  jq -e '
    type == "object"
    and ((.commit|type) == "string") and (.commit|test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))
    and ((.lockTree|type) == "string") and (.lockTree|test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))
    and ((.themes|type) == "array")
    and (.themes | all(.[];
      ((.name|type) == "string") and ((.subpath|type) == "string") and ((.tree|type) == "string")
      and (.name|gsub("[^A-Za-z0-9._-]";"")) == .name
      and (.name|test("^[A-Za-z0-9]"))
      and (.name|contains("..")|not)
      and (.name != "")
      and (.subpath|split("/") | all(.[];
        (gsub("[^A-Za-z0-9._-]";"") == .) and test("^[A-Za-z0-9]") and (contains("..")|not)))
      and (.subpath|startswith("/")|not)
      and (.tree|test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))
    ))
  ' "$index" >/dev/null 2>&1 || fail "manifest structure/policy violation"
}

if [ "${1:-}" = "--trees" ]; then
  # ------------------------------------------------------------ mode 2: trees
  index="$2"; assets="$3"; lock_sub="$4"
  [ -n "$index" ] && [ -n "$assets" ] && [ -n "$lock_sub" ] \
    || fail "usage: $0 --trees <index.json> <assets-dir> <lock-subdir>"
  [ -f "$index" ] || fail "missing catalog index"
  command -v git >/dev/null 2>&1 || fail "git not available"
  command -v jq >/dev/null 2>&1 || fail "jq not available"
  check_policy "$index"
  # The lock subdir is configurable via the plugin config — apply the same
  # component policy before using it in a git rev-parse expression.
  printf '%s\n' "$lock_sub" | jq -eR '
    split("/") | all(.[]; (gsub("[^A-Za-z0-9._-]";"") == .) and test("^[A-Za-z0-9]") and (contains("..")|not))
  ' >/dev/null 2>&1 || fail "invalid lock subdir: $lock_sub"
  [ -d "$assets/.git" ] || { echo NO_ASSETS_SKIPPED; exit 0; }

  commit="$(jq -r .commit "$index")"
  locktree="$(jq -r .lockTree "$index")"
  head="$(git -C "$assets" rev-parse HEAD 2>/dev/null)" \
    || fail "cannot read assets checkout"
  [ "$head" = "$commit" ] \
    || fail "assets checkout ($head) does not match pinned commit ($commit)"
  got="$(git -C "$assets" rev-parse "HEAD:$lock_sub" 2>/dev/null)" \
    || fail "lock app missing at pinned commit ($lock_sub)"
  [ "$got" = "$locktree" ] || fail "lock app tree mismatch"
  n=0
  while IFS='	' read -r sub tree; do
    got="$(git -C "$assets" rev-parse "HEAD:themes/$sub" 2>/dev/null)" \
      || fail "theme missing at pinned commit: $sub"
    [ "$got" = "$tree" ] || fail "theme tree mismatch: $sub"
    n=$((n + 1))
  done <<EOF
$(jq -r '.themes[] | [.subpath, .tree] | @tsv' "$index")
EOF
  echo "TREES_OK $n"
  exit 0
fi

# -------------------------------------------------------------- mode 1: sig
index="$1"; signers="$2"; principal="$3"; ns="${4:-file}"
[ -n "$index" ] && [ -n "$signers" ] && [ -n "$principal" ] \
  || fail "usage: $0 <index.json> <allowed-signers> <principal> [namespace]"
[ -f "$index" ] || fail "missing catalog index"
[ -f "$index.sig" ] || fail "missing catalog signature ($index.sig)"
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen not available"
command -v jq >/dev/null 2>&1 || fail "jq not available"
ssh-keygen -Y verify -f "$signers" -I "$principal" -n "$ns" -s "$index.sig" < "$index" \
  >/dev/null 2>&1 || fail "catalog signature verification failed"
check_policy "$index"
echo SIG_OK
