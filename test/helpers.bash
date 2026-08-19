# shellcheck shell=bash
# Common helpers for cpod bats tests.

CPOD_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${CPOD_REPO_ROOT}/bin:${PATH}"

# Light base for tests unless overridden; the real default is the CUDA image.
export CPOD_BASE_IMAGE="${CPOD_BASE_IMAGE:-docker.io/library/ubuntu:24.04}"
# Which runtime this pass targets (set by test/run.sh).
export CLAUDE_POD_RUNTIME="${CPOD_TEST_RUNTIME:-podman}"

RT="${CLAUDE_POD_RUNTIME}"

# cpod's declared version (from the VERSION file) — for the `cpod version` tests.
CPOD_VERSION="$(tr -d '[:space:]' < "${CPOD_REPO_ROOT}/VERSION" 2>/dev/null || true)"
export CPOD_VERSION

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
  command -v "$RT" >/dev/null 2>&1 || skip "runtime '$RT' unavailable"
}

skip_if_no_image() {
  "$RT" image inspect claude-pod:local >/dev/null 2>&1 || skip "image claude-pod:local not built (test/run.sh builds it)"
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

# Live Claude tests make a REAL (paid) Anthropic API call, so they run only when
# you opt in — like the mutating GitHub tests. Skip explicitly (never silently)
# when not opted in or when there is no Claude auth to reach the API with.
require_live() {
  [ "${CLAUDE_POD_TEST_LIVE:-}" = "1" ] \
    || skip "live Claude test — set CLAUDE_POD_TEST_LIVE=1 (makes a real, paid API call) to run"
  [ -f "$HOME/.claude/.credentials.json" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] \
    || skip "no Claude auth — need ~/.claude/.credentials.json (claude login) or ANTHROPIC_API_KEY"
}

# Route Claude's traffic through your proxy for the run. CLAUDE_POD_TEST_PROXY
# wins; otherwise whatever http(s)_proxy is already in the environment is used
# (cpod forwards it and rewrites localhost -> host-gateway automatically).
setup_test_proxy() {
  local p="${CLAUDE_POD_TEST_PROXY:-}"
  [ -n "$p" ] || return 0
  export http_proxy="$p"  https_proxy="$p"
  export HTTP_PROXY="$p"  HTTPS_PROXY="$p"
}

# `cpod up` args needed to give the pod Claude auth: nothing if the host has a
# credentials file (cpod mounts it), else forward ANTHROPIC_API_KEY by name.
claude_auth_up_args() {
  CPOD_AUTH_ARGS=()
  [ -f "$HOME/.claude/.credentials.json" ] || CPOD_AUTH_ARGS=( --env ANTHROPIC_API_KEY )
}

# Optional --net-host for live runs where the pod cannot reach a host-local proxy
# on the default network — e.g. rootless podman + slirp4netns, where the host
# gateway resolves but host services are unreachable. CLAUDE_POD_TEST_NET_HOST=1.
nethost_up_args() {
  CPOD_NETHOST_ARGS=()
  [ "${CLAUDE_POD_TEST_NET_HOST:-}" = "1" ] && CPOD_NETHOST_ARGS=( --net-host )
  return 0
}

# True when the live run is using host networking (proxy reached via shared loopback,
# so cpod does NOT rewrite localhost -> host-gateway).
is_net_host() { [ "${CLAUDE_POD_TEST_NET_HOST:-}" = "1" ]; }
