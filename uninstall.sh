#!/usr/bin/env bash
# Remove claude-pod scripts and symlinks. Leaves running containers and per-repo
# state untouched — run `cpod down` in each project first to revoke deploy keys.
set -euo pipefail
DEST="${CLAUDE_POD_HOME:-$HOME/.local/share/claude-pod}"
BINDIR="${CLAUDE_POD_BIN:-$HOME/.local/bin}"
STATE="${CLAUDE_POD_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-pod}"

say() { printf '[cpod] %s\n' "$*" >&2; }

rm -f "$BINDIR/cpod" "$BINDIR/claude-pod"
rm -rf "$DEST"
say "скрипты удалены (${DEST})"

if [ -d "$STATE" ] && [ -n "$(ls -A "$STATE/containers" 2>/dev/null || true)" ]; then
  say "ВНИМАНИЕ: остались контейнеры/ключи в ${STATE}."
  say "  выполните 'cpod down' в каждом проекте ДО удаления, чтобы отозвать deploy key."
  say "  затем удалите вручную: rm -rf \"${STATE}\""
fi
