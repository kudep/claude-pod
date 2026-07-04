# shellcheck shell=bash
# lib/runtime.sh — podman/docker abstraction.
#
# Selection order:  --runtime flag (CPOD_RUNTIME) > $CLAUDE_POD_RUNTIME > podman > docker
# Exposes:  $RT (binary), rt() wrapper, rt_is_podman, rt_host_gateway_host, rt_userns_args

rt_detect() {
  local want="${CPOD_RUNTIME:-${CLAUDE_POD_RUNTIME:-}}"
  if [ -n "$want" ]; then
    command -v "$want" >/dev/null 2>&1 || log_die "runtime '$want' not found in PATH"
    RT="$want"
  elif command -v podman >/dev/null 2>&1; then
    RT="podman"
  elif command -v docker >/dev/null 2>&1; then
    RT="docker"
  else
    log_die "neither podman nor docker found — install one of them"
  fi
  export RT
}

rt() { "$RT" "$@"; }

rt_is_podman() { [ "$RT" = "podman" ]; }

# Hostname usable from inside the container to reach host services.
rt_host_gateway_host() {
  if rt_is_podman; then echo "host.containers.internal"; else echo "host.docker.internal"; fi
}

# Extra run args so bind-mount ownership matches the host user.
#  - podman rootless: keep-id maps host uid/gid -> same uid/gid in the container
#  - docker: image already ships a user with the host uid/gid, so nothing is needed
rt_userns_args() {
  if rt_is_podman; then
    printf '%s\n' "--userns=keep-id"
  fi
}

# Args that make host.docker.internal resolve on docker (podman resolves it natively).
rt_host_gateway_args() {
  if ! rt_is_podman; then
    printf '%s\n' "--add-host=host.docker.internal:host-gateway"
  fi
}
