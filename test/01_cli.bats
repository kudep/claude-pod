#!/usr/bin/env bats
# Fast CLI checks — no container build needed.
load helpers

setup() { cpod_isolate_state; }

@test "help lists commands and key modes" {
  run cpod -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"up"* ]]
  [[ "$output" == *"attach"* ]]
  [[ "$output" == *"--key rw"* ]]
  [[ "$output" == *"--key ro"* ]]
  [[ "$output" == *"--key none"* ]]
  [[ "$output" == *"--port"* ]]
}

@test "unknown flag -> error + help + exit 2" {
  run cpod --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
  [[ "$output" == *"Commands:"* ]]
}

@test "invalid --key is rejected with a hint" {
  run cpod up --key bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"--key must be rw|ro|none"* ]]
}

@test "two commands at once -> error" {
  run cpod up down
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected extra command"* ]]
}

@test "ls on empty state does not fail" {
  skip_if_no_runtime
  make_project
  run cpod ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAME"* ]]
}
