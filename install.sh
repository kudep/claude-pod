#!/usr/bin/env bash
# claude-pod installer. Works both locally (./install.sh) and piped (curl ... | bash).
set -euo pipefail

REPO_URL="${CLAUDE_POD_REPO:-https://github.com/kudep/claude-pod}"
BRANCH="${CLAUDE_POD_BRANCH:-main}"
DEST="${CLAUDE_POD_HOME:-$HOME/.local/share/claude-pod}"
BINDIR="${CLAUDE_POD_BIN:-$HOME/.local/bin}"

say() { printf '[cpod] %s\n' "$*" >&2; }

# Locate the source tree: alongside this script if it looks like the repo, else clone.
src=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  [ -f "$here/bin/cpod" ] && src="$here"
fi
if [ -z "$src" ]; then
  command -v git >/dev/null 2>&1 || { say "нужен git для установки по сети"; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  say "клонирую ${REPO_URL} (${BRANCH})…"
  git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$tmp/claude-pod" >/dev/null 2>&1 \
    || { say "не удалось клонировать ${REPO_URL}"; exit 1; }
  src="$tmp/claude-pod"
fi

say "устанавливаю в ${DEST}"
mkdir -p "$DEST" "$BINDIR"
for d in bin lib image docs test README.md VERSION LICENSE; do
  [ -e "$src/$d" ] && cp -a "$src/$d" "$DEST/"
done
chmod +x "$DEST/bin/cpod" 2>/dev/null || true
chmod +x "$DEST/image/entrypoint.sh" 2>/dev/null || true

ln -sf "$DEST/bin/cpod" "$BINDIR/cpod"
ln -sf "$DEST/bin/cpod" "$BINDIR/claude-pod"
say "установлены команды: cpod, claude-pod  (${BINDIR})"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) say "ВНИМАНИЕ: ${BINDIR} не в PATH — добавьте: export PATH=\"${BINDIR}:\$PATH\"" ;;
esac
say "готово. Запуск из каталога проекта:  cpod up   (справка: cpod -h)"
