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
  git config --global url."git@github.com:".insteadOf "https://github.com/"
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

# If given an explicit command, run it as PID-ish; otherwise idle.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi
exec sleep infinity
