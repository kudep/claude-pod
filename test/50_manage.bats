#!/usr/bin/env bats
# Container management: volumes (-v / --cache-volume), exec, restart, prune.
# Requires the claude-pod:local image (test/run.sh builds it).
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  skip_if_no_image
}
teardown() { cpod_cleanup; }

@test "-v bind mount is visible inside; ~/.claude.json mounted when the host has it" {
  make_project
  local extra="${BATS_TEST_TMPDIR}/extra"; mkdir -p "$extra"; echo BINDOK > "$extra/m"
  CPOD_NO_ATTACH=1 run cpod up --key none -v "${extra}:/mnt/x:ro"
  [ "$status" -eq 0 ]
  resolve_cname
  [ "$(in_pod 'cat /mnt/x/m')" = "BINDOK" ]
  # the read-only bind rejects writes
  run in_pod 'echo no >> /mnt/x/m'
  [ "$status" -ne 0 ]
  # ~/.claude.json (Claude Code's main config file) is mounted when present on the host
  if [ -f "$HOME/.claude.json" ]; then in_pod 'test -f ~/.claude.json'; fi
}

@test "--cache-volume: a named volume at ~/.cache that survives recreation" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --cache-volume
  [ "$status" -eq 0 ]
  resolve_cname
  # it is a NAMED volume, not a bind
  run "$RT" inspect -f '{{range .Mounts}}{{.Name}} {{end}}' "$CPOD_CNAME"
  [[ "$output" == *"cpod-cache-"* ]]
  in_pod 'echo KEEP > ~/.cache/marker'
  cpod down                                   # down keeps named volumes by default
  CPOD_NO_ATTACH=1 cpod up --key none --cache-volume
  resolve_cname
  [ "$(in_pod 'cat ~/.cache/marker')" = "KEEP" ]
  # --volumes drops it
  cpod down --volumes
  run "$RT" volume ls --format '{{.Name}}'
  [[ "$output" != *"cpod-cache-"* ]]
}

@test "exec runs a one-off command in the running container" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  run cpod exec sh -c 'echo EXEC_OK'
  [ "$status" -eq 0 ]
  [[ "$output" == *"EXEC_OK"* ]]
}

@test "restart keeps the same container and it stays running" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  CPOD_NO_ATTACH=1 cpod restart
  [ "$("$RT" container inspect -f '{{.State.Running}}' "$CPOD_CNAME")" = "true" ]
}

@test "prune leaves a running container but removes a stopped one" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  cpod prune                                  # running -> untouched
  [ "$("$RT" container inspect -f '{{.State.Running}}' "$CPOD_CNAME" 2>/dev/null)" = "true" ]
  cpod stop
  cpod prune                                  # stopped -> removed
  run "$RT" container inspect "$CPOD_CNAME"
  [ "$status" -ne 0 ]
}
