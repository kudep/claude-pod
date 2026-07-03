# shellcheck shell=bash
# Common helpers for cpod bats tests.

CPOD_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${CPOD_REPO_ROOT}/bin:${PATH}"

# Light base for tests unless overridden; real default is the CUDA image.
export CPOD_BASE_IMAGE="${CPOD_BASE_IMAGE:-ubuntu:24.04}"
# Which runtime this pass targets (set by test/run.sh).
export CLAUDE_POD_RUNTIME="${CPOD_TEST_RUNTIME:-podman}"

RT="${CLAUDE_POD_RUNTIME}"

# Per-test isolated cpod state (keys/containers metadata).
cpod_isolate_state() { export CLAUDE_POD_STATE="${BATS_TEST_TMPDIR}/state"; }

# Create a throwaway project dir (optionally a git repo) and cd into it.
make_project() {
  local dir="${BATS_TEST_TMPDIR}/proj-${RANDOM}"
  mkdir -p "$dir"; cd "$dir" || return 1
  if [ "${1:-}" = "git" ]; then
    git init -q; git config user.email t@t; git config user.name t
    echo hi > README.md; git add -A; git commit -qm init
  fi
  PROJECT="$dir"
}

# Guaranteed teardown of a container for the current project.
cpod_cleanup() { cpod down >/dev/null 2>&1 || true; }

skip_if_no_runtime() {
  command -v "$RT" >/dev/null 2>&1 || skip "runtime '$RT' недоступен"
}

skip_if_no_image() {
  "$RT" image inspect claude-pod:local >/dev/null 2>&1 || skip "образ claude-pod:local не собран (test/run.sh собирает его)"
}

# Deterministic container name for $PWD — MUST mirror container_name() in lib/container.sh.
resolve_cname() {
  local base hash
  base="$(basename "$PWD")"
  base="$(printf '%s' "$base" | tr -c 'a-zA-Z0-9_.-' '-' | cut -c1-30)"
  hash="$(printf '%s' "$PWD" | sha256sum | cut -c1-10)"
  CPOD_CNAME="cpod-${base}-${hash}"
}

# Run a command inside the running container (no TTY).
in_pod() { "$RT" exec "$CPOD_CNAME" bash -lc "$1"; }
