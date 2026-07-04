#!/usr/bin/env bash
# Run the cpod test matrix on one or more runtimes (default: podman and docker).
# Usage: test/run.sh [podman] [docker]
#   CPOD_BASE_IMAGE=ubuntu:24.04 (default here; the real default is the CUDA image)
#   CLAUDE_POD_TEST_REPO=owner/repo enables the mutating GitHub deploy-key tests.
#   CLAUDE_POD_TEST_LIVE=1 enables the live Claude tests (a real, paid API call).
#   CLAUDE_POD_TEST_PROXY=http://localhost:PORT forces Claude traffic via that proxy.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${ROOT}/bin:${PATH}"
export CPOD_BASE_IMAGE="${CPOD_BASE_IMAGE:-ubuntu:24.04}"

RUNTIMES=("$@"); [ ${#RUNTIMES[@]} -eq 0 ] && RUNTIMES=(podman docker)

if ! command -v bats >/dev/null 2>&1; then
  echo "[test] 'bats' is required — install: apt-get install bats  |  npm i -g bats" >&2
  exit 127
fi

fail=0
for rt in "${RUNTIMES[@]}"; do
  if ! command -v "$rt" >/dev/null 2>&1; then
    echo "[test] skipping '$rt' — not installed" >&2; continue
  fi
  echo "==================== runtime: ${rt} ===================="
  export CPOD_TEST_RUNTIME="$rt"
  echo "[test] building image claude-pod:local (${rt}, base ${CPOD_BASE_IMAGE})…"
  if ! CLAUDE_POD_RUNTIME="$rt" cpod build; then
    echo "[test] build failed for ${rt} — tests for this runtime skipped" >&2
    fail=1; continue
  fi
  bats "${ROOT}"/test/*.bats || fail=1
done

[ "$fail" -eq 0 ] && echo "[test] OK" || echo "[test] there were failures"
exit "$fail"
