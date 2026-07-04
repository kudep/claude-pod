#!/usr/bin/env bash
# Remove claude-pod scripts, symlinks and completions. Leaves running containers and
# per-repo state untouched — run `cpod down` in each project first to revoke deploy keys.
set -euo pipefail
DEST="${CLAUDE_POD_HOME:-$HOME/.local/share/claude-pod}"
BINDIR="${CLAUDE_POD_BIN:-$HOME/.local/bin}"
STATE="${CLAUDE_POD_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-pod}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}"

say() { printf '[cpod] %s\n' "$*" >&2; }

rm -f "$BINDIR/cpod" "$BINDIR/claude-pod"
rm -f "$DATA/bash-completion/completions/cpod" \
      "$DATA/zsh/site-functions/_cpod" \
      "$CONFDIR/fish/completions/cpod.fish"
rm -rf "$DEST"
say "scripts and completions removed (${DEST})"

if [ -d "$STATE" ] && [ -n "$(ls -A "$STATE/containers" 2>/dev/null || true)" ]; then
  say "NOTE: containers/keys remain in ${STATE}."
  say "  run 'cpod down' in each project BEFORE removing, to revoke deploy keys."
  say "  then remove manually: rm -rf \"${STATE}\""
fi
