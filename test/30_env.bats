#!/usr/bin/env bats
# Env passthrough, proxy, networking.
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  skip_if_no_image
}
teardown() { cpod_cleanup; }

@test "--inherit-env пробрасывает обычные, но НЕ секреты из денилиста" {
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

@test "--env пробрасывает одну переменную" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --env FOO=barbaz
  [ "$status" -eq 0 ]
  resolve_cname
  [ "$(in_pod 'echo $FOO')" = "barbaz" ]
}

@test "--net-host: контейнер в сети хоста" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --net-host
  [ "$status" -eq 0 ]
  resolve_cname
  [ "$("$RT" container inspect -f '{{.HostConfig.NetworkMode}}' "$CPOD_CNAME")" = "host" ]
}

@test "прокси: http_proxy проброшен и localhost переписан на host-gateway" {
  make_project
  export http_proxy="http://localhost:1084"
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  resolve_cname
  run in_pod 'echo $http_proxy'
  [[ "$output" == *"host.docker.internal"* ]] || [[ "$output" == *"host.containers.internal"* ]]
}
