#!/usr/bin/env bash
# cpod-entrypoint — one-time in-container setup, then keep the container alive.
# Interactive sessions (up/start/attach) attach via `exec`, so the main process
# just needs to survive an exited shell.
set -e

# Git identity from the host (values only; host ~/.gitconfig is never mounted).
[ -n "${CPOD_GIT_NAME:-}" ]  && git config --global user.name  "${CPOD_GIT_NAME}"  || true
[ -n "${CPOD_GIT_EMAIL:-}" ] && git config --global user.email "${CPOD_GIT_EMAIL}" || true
git config --global --add safe.directory '*' || true

# When a per-repo deploy key is wired in, route GitHub over SSH and configure it.
if [ "${CPOD_HAS_KEY:-0}" = "1" ]; then
  # Scope the https->ssh rewrite to THIS repo only. A global rewrite would force
  # every github https fetch (submodules, pip/go/npm git deps of other repos) over
  # ssh, where the single-repo deploy key would be denied.
  if [ -n "${CPOD_GIT_REPO:-}" ]; then
    git config --global url."git@github.com:${CPOD_GIT_REPO}.git".insteadOf "https://github.com/${CPOD_GIT_REPO}.git"
    git config --global url."git@github.com:${CPOD_GIT_REPO}".insteadOf   "https://github.com/${CPOD_GIT_REPO}"
  else
    git config --global url."git@github.com:".insteadOf "https://github.com/"
  fi
  mkdir -p "${HOME}/.ssh"; chmod 700 "${HOME}/.ssh"
  {
    echo "Host github.com"
    echo "  User git"
    echo "  StrictHostKeyChecking accept-new"
    if [ "${CPOD_SSH_MODE:-agent}" = "file" ]; then
      echo "  IdentitiesOnly yes"
      echo "  IdentityFile ${HOME}/.ssh/id_ed25519"
    fi
  } > "${HOME}/.ssh/config"
  chmod 600 "${HOME}/.ssh/config"
fi

# Claude Code records the host's install path in ~/.claude.json (e.g.
# ~/.local/bin/claude for the native installer). Inside the pod claude is the image's
# npm-global binary, so that path looks "missing/broken" and claude nags to repair.
# Point the recorded native path at the real binary (container-local; the host tree is
# not mounted). Combined with DISABLE_AUTOUPDATER=1 this keeps the pod's claude quiet.
if command -v claude >/dev/null 2>&1; then
  mkdir -p "${HOME}/.local/bin"
  ln -sf "$(command -v claude)" "${HOME}/.local/bin/claude" 2>/dev/null || true
fi

# If given an explicit command, run it as PID-ish; otherwise idle.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi
exec sleep infinity
