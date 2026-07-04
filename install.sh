#!/usr/bin/env bash
# claude-pod installer. Works both locally (./install.sh) and piped (curl ... | bash).
set -euo pipefail

REPO_URL="${CLAUDE_POD_REPO:-https://github.com/kudep/claude-pod}"
BRANCH="${CLAUDE_POD_BRANCH:-main}"
DEST="${CLAUDE_POD_HOME:-$HOME/.local/share/claude-pod}"
BINDIR="${CLAUDE_POD_BIN:-$HOME/.local/bin}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFDIR="${XDG_CONFIG_HOME:-$HOME/.config}"

say() { printf '[cpod] %s\n' "$*" >&2; }

# Locate the source tree: alongside this script if it looks like the repo, else clone.
src=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  [ -f "$here/bin/cpod" ] && src="$here"
fi
if [ -z "$src" ]; then
  command -v git >/dev/null 2>&1 || { say "git is required for network install"; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  say "cloning ${REPO_URL} (${BRANCH})…"
  git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$tmp/claude-pod" >/dev/null 2>&1 \
    || { say "failed to clone ${REPO_URL}"; exit 1; }
  src="$tmp/claude-pod"
fi

# Files/dirs this installer owns under $DEST (used for both install and cleanup).
PAYLOAD=(bin lib image docs test completions README.md VERSION LICENSE)

new_ver="$(tr -d '[:space:]' < "$src/VERSION" 2>/dev/null || true)"

# Detect a previous installation and reinstall over it. We wipe the old managed
# payload first so files removed in the new version don't linger as stale leftovers
# (a plain copy-over would keep them). Unrelated files a user may have placed in
# $DEST are left untouched.
if [ -e "$DEST/bin/cpod" ] || [ -f "$DEST/VERSION" ]; then
  old_ver="$(tr -d '[:space:]' < "$DEST/VERSION" 2>/dev/null || true)"
  if [ "${old_ver:-unknown}" = "${new_ver:-unknown}" ]; then
    say "existing install found (${old_ver:-unknown}) — reinstalling the same version"
  else
    say "existing install found (${old_ver:-unknown}) — updating to ${new_ver:-unknown}"
  fi
  for d in "${PAYLOAD[@]}"; do rm -rf "${DEST:?}/$d"; done
fi

say "installing into ${DEST}"
mkdir -p "$DEST" "$BINDIR"
for d in "${PAYLOAD[@]}"; do
  [ -e "$src/$d" ] && cp -a "$src/$d" "$DEST/"
done
chmod +x "$DEST/bin/cpod" 2>/dev/null || true
chmod +x "$DEST/image/entrypoint.sh" 2>/dev/null || true

ln -sf "$DEST/bin/cpod" "$BINDIR/cpod"
ln -sf "$DEST/bin/cpod" "$BINDIR/claude-pod"
say "installed commands: cpod, claude-pod  (${BINDIR})"

# Shell completions (best-effort into standard user locations).
if [ -d "$src/completions" ]; then
  install -Dm644 "$src/completions/cpod.bash" "$DATA/bash-completion/completions/cpod" 2>/dev/null \
    && say "bash completion -> $DATA/bash-completion/completions/cpod" || true
  install -Dm644 "$src/completions/cpod.zsh"  "$DATA/zsh/site-functions/_cpod" 2>/dev/null \
    && say "zsh completion  -> $DATA/zsh/site-functions/_cpod (ensure that dir is in fpath)" || true
  install -Dm644 "$src/completions/cpod.fish" "$CONFDIR/fish/completions/cpod.fish" 2>/dev/null \
    && say "fish completion -> $CONFDIR/fish/completions/cpod.fish" || true
fi

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) say "NOTE: ${BINDIR} is not in PATH — add: export PATH=\"${BINDIR}:\$PATH\"" ;;
esac
say "done. Run from a project directory:  cpod up   (help: cpod -h)"
