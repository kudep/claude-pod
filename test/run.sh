#!/usr/bin/env bash
# Run the cpod test matrix on one or more runtimes (default: podman and docker).
# Usage: test/run.sh [podman] [docker]
#   CPOD_BASE_IMAGE=ubuntu:24.04 (default here; real default is the CUDA image)
#   CLAUDE_POD_TEST_REPO=owner/repo enables the mutating GitHub deploy-key tests.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${ROOT}/bin:${PATH}"
export CPOD_BASE_IMAGE="${CPOD_BASE_IMAGE:-ubuntu:24.04}"

RUNTIMES=("$@"); [ ${#RUNTIMES[@]} -eq 0 ] && RUNTIMES=(podman docker)

if ! command -v bats >/dev/null 2>&1; then
  echo "[test] нужен 'bats' — установите: apt-get install bats  |  npm i -g bats" >&2
  exit 127
fi

fail=0
for rt in "${RUNTIMES[@]}"; do
  if ! command -v "$rt" >/dev/null 2>&1; then
    echo "[test] пропуск '$rt' — не установлен" >&2; continue
  fi
  echo "==================== runtime: ${rt} ===================="
  export CPOD_TEST_RUNTIME="$rt"
  echo "[test] сборка образа claude-pod:local (${rt}, база ${CPOD_BASE_IMAGE})…"
  if ! CLAUDE_POD_RUNTIME="$rt" cpod build; then
    echo "[test] сборка не удалась для ${rt} — тесты для этого runtime пропущены" >&2
    fail=1; continue
  fi
  bats "${ROOT}"/test/*.bats || fail=1
done

[ "$fail" -eq 0 ] && echo "[test] OK" || echo "[test] были провалы"
exit "$fail"
