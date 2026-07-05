#!/usr/bin/env bats
# Error paths for the management commands: run against a project that has NO container
# they must fail cleanly (clear message, non-zero) or no-op gracefully — never crash or
# emit a raw shell/runtime traceback. Needs a runtime (to check non-existence) but no image.
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  make_project
}

@test "stop/logs/inspect/restart with no container -> clean error (exit != 0, clear message)" {
  local c
  for c in stop logs inspect restart; do
    run cpod "$c"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no container"* ]]
  done
}

@test "exec with no container -> clean error, not a crash" {
  run cpod exec echo hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"no container"* ]]
}

@test "down with no container/state -> graceful no-op (exit 0)" {
  run cpod down
  [ "$status" -eq 0 ]
  [[ "$output" == *"no container"* ]]
}

@test "prune with nothing to remove -> exit 0, says so" {
  run cpod prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"no cpod containers"* ]]
}

@test "status with no container -> exit 0, reports absence" {
  run cpod status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no container"* ]]
}

@test "a value flag missing its argument fails fast (no hang, non-zero)" {
  # `--env` with no value must not hang or silently succeed; it exits non-zero.
  run cpod up --env
  [ "$status" -ne 0 ]
}
