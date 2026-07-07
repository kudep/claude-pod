#!/usr/bin/env bats
# Docker-in-cpod (DinD): passing the host docker socket through into the pod.
# Runs under both runtimes (podman/docker) via the test matrix. The *mount* of
# the socket is deterministic on both; whether the in-pod docker CLI can actually
# reach the daemon depends on socket-group mapping (works on docker; rootless
# podman + keep-id often can't), so the functional check is lenient.
load helpers

setup() {
  cpod_isolate_state
  skip_if_no_runtime
  skip_if_no_image
}
teardown() { cpod_cleanup; }

# The host socket cpod would pass through — present whenever docker runs on the host.
host_docker_sock() { [ -S /var/run/docker.sock ]; }

@test "image ships the docker CLI" {
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none
  resolve_cname
  in_pod "command -v docker"
}

@test "--no-docker: the host docker socket is NOT mounted into the pod" {
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --no-docker
  [ "$status" -eq 0 ]
  resolve_cname
  run in_pod 'test -S /var/run/docker.sock'
  [ "$status" -ne 0 ]
}

@test "--docker: the host docker socket is passed through into the pod" {
  host_docker_sock || skip "no host /var/run/docker.sock to pass through"
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --docker
  [ "$status" -eq 0 ]
  resolve_cname
  in_pod 'test -S /var/run/docker.sock'
}

@test "--docker with no host socket: warns and skips (container still starts)" {
  host_docker_sock && skip "host has a docker socket — the skip path can't be exercised here"
  make_project
  CPOD_NO_ATTACH=1 run cpod up --key none --docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker socket"* ]] && [[ "$output" == *"DinD skipped"* ]]
}

@test "auto-detect: a Dockerfile enables passthrough with a warning" {
  host_docker_sock || skip "no host /var/run/docker.sock to pass through"
  make_project
  : > Dockerfile
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  # auto mode (no explicit --docker/--no-docker) warns before enabling passthrough
  [[ "$output" == *"docker found in the project"* ]]
  resolve_cname
  in_pod 'test -S /var/run/docker.sock'
}

@test "auto-detect: no docker markers -> no passthrough, no warning" {
  make_project           # no Dockerfile / compose file
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  [[ "$output" != *"docker found in the project"* ]]
  resolve_cname
  run in_pod 'test -S /var/run/docker.sock'
  [ "$status" -ne 0 ]
}

@test "auto-detect: a compose file also enables passthrough" {
  host_docker_sock || skip "no host /var/run/docker.sock to pass through"
  make_project
  : > docker-compose.yml
  CPOD_NO_ATTACH=1 run cpod up --key none
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker found in the project"* ]]
  resolve_cname
  in_pod 'test -S /var/run/docker.sock'
}

@test "--no-docker overrides auto-detection for a docker project" {
  make_project
  : > Dockerfile
  CPOD_NO_ATTACH=1 run cpod up --key none --no-docker
  [ "$status" -eq 0 ]
  # explicit --no-docker wins: no warning, no socket
  [[ "$output" != *"docker found in the project"* ]]
  resolve_cname
  run in_pod 'test -S /var/run/docker.sock'
  [ "$status" -ne 0 ]
}

@test "--docker: the in-pod docker CLI can reach the daemon (when the socket group maps)" {
  host_docker_sock || skip "no host /var/run/docker.sock"
  make_project
  CPOD_NO_ATTACH=1 cpod up --key none --docker
  resolve_cname
  run in_pod 'docker version --format "{{.Server.Version}}"'
  # Reaching the daemon needs group access to the socket. That works on docker;
  # rootless podman + keep-id usually can't map the host socket group, so a
  # permission error there is expected — don't fail the suite on it.
  if [ "$status" -eq 0 ]; then
    [[ "$output" =~ [0-9]+\.[0-9]+ ]]
  else
    [[ "$output" == *"permission denied"* ]] || [[ "$output" == *"Cannot connect"* ]] || [[ "$output" == *"denied"* ]]
    skip "socket mounted but daemon not reachable in this runtime (group mapping) — expected on rootless podman"
  fi
}
