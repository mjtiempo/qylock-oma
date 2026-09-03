#!/usr/bin/env bash
# Releases a stranded Hyprland session lock (black screen after the lock app
# died). Uses the session-lock protocol's own unlock path.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec quickshell --path "$DIR/release-lock"