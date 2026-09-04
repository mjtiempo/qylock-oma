#!/bin/sh
# QyLock SDDM theme installer — runs as root via pkexec (polkit action
# org.qylock.sddm-theme, see qylock-oma.policy). Kept as a standalone file so
# the polkit prompt shows a clean command line ("Password required to Apply
# SDDM theme") instead of the whole install script.
# Usage: install-sddm.sh <name> <srcdir>
set -e
name="$1"
src="$2"

[ -n "$name" ] && [ -n "$src" ] || { echo "usage: install-sddm.sh <name> <srcdir>" >&2; exit 2; }
[ -d "$src" ] || { echo "theme source missing: $src" >&2; exit 2; }

mkdir -p /usr/share/sddm/themes
rm -rf "/usr/share/sddm/themes/$name"
cp -a "$src" "/usr/share/sddm/themes/$name"
if [ -f /etc/sddm.conf.d/theme.conf ]; then
  cp -a /etc/sddm.conf.d/theme.conf "/etc/sddm.conf.d/theme.conf.bak.$(date +%s)"
fi
printf '[Theme]\nCurrent=%s\n' "$name" > /etc/sddm.conf.d/theme.conf
echo OK