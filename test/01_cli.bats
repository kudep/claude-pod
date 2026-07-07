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

@test "help lists management commands and volume flags" {
  run cpod -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"exec"* ]]
  [[ "$output" == *"prune"* ]]
  [[ "$output" == *"restart"* ]]
  [[ "$output" == *"-v, --volume"* ]]
  [[ "$output" == *"--cache-volume"* ]]
}

@test "exec with no container -> error, not a crash" {
  skip_if_no_runtime
  make_project
  run cpod exec echo hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"no container"* ]]
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

@test "invalid --profile is rejected with a hint" {
  run cpod up --profile bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown --profile"* ]]
}

@test "help lists the trust profiles" {
  run cpod -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--profile guarded"* ]]
  [[ "$output" == *"--profile locked"* ]]
}

@test "help lists the --root and --proxy flags" {
  run cpod -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"--root"* ]]
  [[ "$output" == *"--proxy"* ]]
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

@test "help lists the version command and --version flag" {
  run cpod -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"version"* ]]
  [[ "$output" == *"--version"* ]]
}

# `cpod version` prints cpod's own version plus podman/docker (and host tools).
# It must work WITHOUT a runtime present, so no skip_if_no_runtime here.
@test "version prints cpod version and lists both runtimes" {
  run cpod version
  [ "$status" -eq 0 ]
  # cpod's own version, straight from the VERSION file.
  [[ "$output" == *"cpod ${CPOD_VERSION}"* ]]
  # both runtimes are always listed (installed or not).
  [[ "$output" == *"podman"* ]]
  [[ "$output" == *"docker"* ]]
  # and the supporting host tools it drives.
  [[ "$output" == *"git"* ]]
  [[ "$output" == *"ssh"* ]]
}

@test "--version and -V match the version subcommand" {
  run cpod version;   local a="$output"
  run cpod --version; local b="$output"
  run cpod -V;        local c="$output"
  [ "$a" = "$b" ]
  [ "$a" = "$c" ]
}

# The runtime a plain `cpod up` would pick is tagged "(active)". Under the test
# matrix CLAUDE_POD_RUNTIME is set per pass, so the active one is $RT.
@test "version tags the active runtime" {
  skip_if_no_runtime
  run cpod version
  [ "$status" -eq 0 ]
  [[ "$output" == *"${RT}"*"(active)"* ]]
}

# An installed runtime reports a real version number, not "not installed".
@test "version reports an installed runtime's number" {
  skip_if_no_runtime
  run cpod version
  [ "$status" -eq 0 ]
  # line for the active runtime carries a version-looking token, not "not installed".
  local line
  line="$(printf '%s\n' "$output" | grep -E "^[[:space:]]*${RT}[[:space:]]")"
  [[ "$line" == *"(active)"* ]]
  [[ "$line" != *"not installed"* ]]
  [[ "$line" =~ [0-9]+\.[0-9]+ ]]
}
