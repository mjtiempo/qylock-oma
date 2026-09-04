#!/bin/sh
# QyLock SDDM theme installer — runs as root via pkexec (polkit action
# org.qylock.sddm-theme). See the "Security & trust model" section of the
# README for what this helper enforces.
#
# Usage: install-sddm.sh <name> <srcdir> [themes-dir] [conf-file]
#   (the last two args exist for the test suite; the plugin always calls
#    with two, and pkexec strips arbitrary environment variables so the
#    overrides below cannot be smuggled in through polkit.)
#
# Defense in depth (never trust the caller):
#   * <name> must be a single path component: first char alphanumeric,
#     only [A-Za-z0-9._-], no "..", no separators, no control chars.
#   * <srcdir> must exist, must not contain symlinked path components
#     inside the allowed prefix, and must canonicalize inside the invoking
#     user's plugin assets dir (or $QYLOCK_SRC_PREFIX for tests).
#   * The destination must canonicalize inside <themes-dir>; the old theme
#     dir is replaced (rm -rf of exactly that single-component path) and
#     the copy is refused if the path can be re-created as a link.
set -eu

name="$1"
src="$2"
themes_dir="${3:-/usr/share/sddm/themes}"
conf_file="${4:-/etc/sddm.conf.d/theme.conf}"

fail() { echo "install-sddm: $*" >&2; exit 2; }

# ---- name policy (mirrors the QML/verify-catalog policy) -------------
case "$name" in
  ''|*[!A-Za-z0-9._-]*|*..*|[!A-Za-z0-9]*) fail "refusing unsafe theme name";;
esac

# ---- source containment ----------------------------------------------
[ -n "$src" ] || fail "missing theme source"
[ -d "$src" ] || fail "theme source missing or not a directory"
command -v realpath >/dev/null 2>&1 || fail "realpath not available"

# The invoking user's plugin assets dir. pkexec sets PKEXEC_UID to the user
# who authorized the action; a direct root invocation falls back to root.
# QYLOCK_SRC_PREFIX is a test-suite override (pkexec clears it).
invoker_uid="${PKEXEC_UID:-$(id -u)}"
invoker_home="$(getent passwd "$invoker_uid" | cut -d: -f6 || true)"
if [ -n "${QYLOCK_SRC_PREFIX:-}" ]; then
  prefix="$QYLOCK_SRC_PREFIX"
elif [ -n "$invoker_home" ]; then
  prefix="$invoker_home/.local/share/omarchy/mark.lock-themes/assets/themes"
else
  fail "cannot resolve invoking user"
fi

src_real="$(realpath -e "$src" 2>/dev/null)" || fail "cannot resolve theme source"
prefix_real="$(realpath -m "$prefix")"
case "$src_real/" in
  "$prefix_real"/*) ;;
  *) fail "theme source outside allowed prefix";;
esac

# Refuse symlinked path components inside the allowed prefix (above the
# prefix, paths are root-owned system directories — not attacker-writable).
p="$src"
while [ "$p" != "/" ]; do
  rp="$(realpath -m "$p" 2>/dev/null || true)"
  if [ -n "$rp" ] && [ "$rp" = "$prefix_real" ]; then
    break
  fi
  if [ -L "$p" ]; then
    fail "refusing symlinked source component: $p"
  fi
  p="$(dirname "$p")"
done

# ---- destination containment ------------------------------------------
mkdir -p "$themes_dir"
themes_real="$(realpath -m "$themes_dir")"
dest="$themes_dir/$name"
dest_real="$(realpath -m "$dest")"
case "$dest_real" in
  "$themes_real"/*) ;;
  *) fail "refusing destination outside themes dir";;
esac

rm -rf "$dest"
if [ -e "$dest" ] || [ -L "$dest" ]; then
  fail "could not replace existing theme directory"
fi
cp -a "$src" "$dest"

# ---- config write ------------------------------------------------------
conf_dir="$(dirname "$conf_file")"
mkdir -p "$conf_dir"
if [ -f "$conf_file" ]; then
  cp -a "$conf_file" "$conf_file.bak.$(date +%s)"
fi
printf '[Theme]\nCurrent=%s\n' "$name" > "$conf_file"
echo OK
