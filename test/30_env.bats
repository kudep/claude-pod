#!/usr/bin/env bats
# Env passthrough, proxy, networking, port publishing.
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  skip_if_no_image
}
teardown() { cpod_cleanup; }

@test "--inherit-env forwards ordinary vars but NOT denylisted secrets" {
  make_project
  export CPOD_MARKER_VALUE="hello-cpod"
  export GH_TOKEN="should-not-leak"
  export MY_API_KEY="should-not-leak"
  CPOD_NO_ATTACH=1 run cpod up --key none --inherit-env
  [ "$status" -eq 0 ]
  resolve_cname
  [ "$(in_pod 'echo $CPOD_MARKER_VALUE')" = "hello-cpod" ]
  [ -z "$(in_pod 'echo $GH_TOKEN')" ]
  [ -z "$(in_pod 'echo $MY_API_KEY')" ]
}

@test "--env forwards a single variable" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --env FOO=barbaz
  [ "$status" -eq 0 ]
  resolve_cname
  [ "$(in_pod 'echo $FOO')" = "barbaz" ]
}

@test "-p publishes a specific port (no host network)" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none -p 18080:80
  [ "$status" -eq 0 ]
  resolve_cname
  run "$RT" container inspect -f '{{.HostConfig.PortBindings}}' "$CPOD_CNAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"18080"* ]]
  # not host network
  [ "$("$RT" container inspect -f '{{.HostConfig.NetworkMode}}' "$CPOD_CNAME")" != "host" ]
}

@test "--net-host: container on the host network" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --net-host
  [ "$status" -eq 0 ]
  resolve_cname
  [ "$("$RT" container inspect -f '{{.HostConfig.NetworkMode}}' "$CPOD_CNAME")" = "host" ]
}

@test "--claude-hardened: settings.json mounted read-only" {
  [ -f "$HOME/.claude/settings.json" ] || skip "no ~/.claude/settings.json"
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --claude-hardened
  [ "$status" -eq 0 ]
  resolve_cname
  # config is writable normally, but under hardened settings.json is ro
  run in_pod "echo x >> ~/.claude/settings.json"
  [ "$status" -ne 0 ]
}

@test "proxy: http_proxy forwarded and localhost rewritten to host-gateway" {
  make_project
  export http_proxy="http://localhost:1084"
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  run in_pod 'echo $http_proxy'
  [[ "$output" == *"host.docker.internal"* ]] || [[ "$output" == *"host.containers.internal"* ]]
}

@test "proxy: http_proxy is mirrored onto https_proxy (Claude's API is HTTPS)" {
  make_project
  export http_proxy="http://localhost:1084"
  unset https_proxy HTTPS_PROXY 2>/dev/null || true
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  run in_pod 'echo $https_proxy'
  [ -n "$output" ]
  [[ "$output" == *"1084"* ]]
  [[ "$output" == *"host.docker.internal"* ]] || [[ "$output" == *"host.containers.internal"* ]]
}
