# shellcheck shell=bash
# lib/container.sh — image build, container lifecycle, labels, listing.
# The container's main process is `sleep infinity` (set up by entrypoint.sh), so
# up / start / attach all drop the user in via `exec`; the container survives an
# exited shell, which is what makes the three lifecycle modes work uniformly.

IMAGE="${CPOD_IMAGE:-claude-pod:local}"

# Deterministic per-project container name: cpod-<basename>-<hash(abspath)>.
container_name() {
  local base hash
  base="$(basename "$PROJECT_DIR")"
  base="$(printf '%s' "$base" | tr -c 'a-zA-Z0-9_.-' '-' | cut -c1-30)"
  hash="$(printf '%s' "$PROJECT_DIR" | sha256sum | cut -c1-10)"
  CNAME="cpod-${base}-${hash}"
  CSTATE="${CPOD_STATE}/containers/${CNAME}"
  CACHE_VOL="cpod-cache-${hash}"   # per-project named volume for --cache-volume
}

container_exists()  { rt container inspect "$CNAME" >/dev/null 2>&1; }
container_running() { [ "$(rt container inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null)" = "true" ]; }

image_ensure() {
  if [ "${CPOD_REBUILD:-0}" != "1" ] && rt image inspect "$IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  log_info "building image ${IMAGE} (runtime=${RT}, base=${CPOD_BASE_IMAGE})…"
  # Build with host networking so a localhost proxy is reachable; forward proxy
  # vars as predefined build-args (docker/podman do not persist these in the image).
  local -a proxy_args=() v
  for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    [ -n "${!v:-}" ] && proxy_args+=( --build-arg "${v}=${!v}" )
  done
  rt build --network host "${proxy_args[@]}" \
    --build-arg "BASE_IMAGE=${CPOD_BASE_IMAGE}" \
    --build-arg "HOST_USER=${HOST_USER}" \
    --build-arg "HOST_UID=${HOST_UID}" \
    --build-arg "HOST_GID=${HOST_GID}" \
    --build-arg "HOST_HOME=${HOST_HOME}" \
    -t "$IMAGE" "${CPOD_HOME}/image" || log_die "image build failed"
  log_ok "image ${IMAGE} ready"
}

# Drop the user into the container honoring --claude / --run / default shell.
login_exec() {
  [ "${CPOD_NO_ATTACH:-0}" = "1" ] && return 0   # create/start only (scripts, tests)
  local -a argv wa=() tty=()
  if [ -n "${CPOD_RUN_CMD}" ]; then
    argv=( bash -lc "${CPOD_RUN_CMD}" )
  elif [ "${CPOD_RUN_CLAUDE}" = "1" ]; then
    argv=( bash -lc "exec claude" )
  else
    argv=( bash -l )
  fi
  [ -d "$PROJECT_DIR" ] && wa=( -w "$PROJECT_DIR" )
  if [ -t 0 ] && [ -t 1 ]; then tty=( -it ); else tty=( -i ); fi
  rt exec "${tty[@]}" "${wa[@]}" -e "TERM=${TERM:-xterm-256color}" "$CNAME" "${argv[@]}"
}

cmd_up() {
  container_name
  if container_exists; then
    log_warn "container ${CNAME} already exists"
    if container_running; then cmd_attach; else cmd_start; fi
    return
  fi
  image_ensure
  # If a previous run left state (e.g. container removed out-of-band, not via `down`),
  # revoke its orphaned deploy key before we overwrite the metadata.
  [ -f "${CSTATE}/meta" ] && dk_revoke "$CSTATE"
  mkdir -p "$CSTATE"; : > "${CSTATE}/meta"
  { echo "project=${PROJECT_DIR}"; echo "runtime=${RT}"; } >> "${CSTATE}/meta"

  RUN_ARGS=()
  RUN_ARGS+=( --name "${CNAME}" --hostname "cpod" )
  RUN_ARGS+=( --label "cpod.managed=1" --label "cpod.project=${PROJECT_DIR}" --label "cpod.runtime=${RT}" )
  RUN_ARGS+=( -e "CONTAINER_HOME=${CONTAINER_HOME}" )
  # The image ships a pinned Claude Code; it must never self-update inside a pod. Without
  # this, a host ~/.claude.json recorded as a "native" install makes claude see its recorded
  # path as broken, auto-update, and race the first request into a 403.
  RUN_ARGS+=( -e "DISABLE_AUTOUPDATER=1" )

  local a
  while IFS= read -r a; do [ -n "$a" ] && RUN_ARGS+=( "$a" ); done < <(rt_userns_args)

  mounts_add_project
  mounts_add_claude
  mounts_add_net
  mounts_add_ports
  mounts_add_volumes
  mounts_add_proxy
  mounts_add_env
  gpu_add
  dind_add
  dk_setup

  [ -n "${DK_KEYID:-}" ] && RUN_ARGS+=( --label "cpod.keyid=${DK_KEYID}" )
  [ -n "${DK_SLUG:-}" ]  && RUN_ARGS+=( --label "cpod.repo=${DK_SLUG}" )

  log_info "creating container ${CNAME}"
  if ! rt run -d "${RUN_ARGS[@]}" "$IMAGE" >/dev/null; then
    # Don't leave the just-registered deploy key / agent orphaned on failure.
    dk_revoke "$CSTATE"; rm -rf "$CSTATE"
    log_die "failed to start the container"
  fi
  log_ok "container ${CNAME} started (${RT})"
  [ "${CPOD_RUN_CLAUDE}" = "1" ] || [ -n "${CPOD_RUN_CMD}" ] || \
    log_info "entering shell (claude is not auto-started; run 'claude' manually)"
  login_exec
  # --rm: ephemeral container — tear it down (and revoke its key) once the
  # interactive session ends. Skipped in no-attach mode (nothing to wait on).
  if [ "${CPOD_RM:-0}" = "1" ] && [ "${CPOD_NO_ATTACH:-0}" != "1" ]; then
    log_info "--rm: removing the ephemeral container"
    cmd_down
  fi
}

cmd_start() {
  container_name
  container_exists || log_die "no container for this project — use: cpod up"
  if ! container_running; then
    rt start "$CNAME" >/dev/null || log_die "failed to start ${CNAME}"
    log_ok "container ${CNAME} started"
  fi
  login_exec
}

cmd_attach() {
  container_name
  container_exists || log_die "no container for this project — use: cpod up"
  container_running || { log_info "container is stopped — bringing it up"; cmd_start; return; }
  login_exec
}

cmd_stop() {
  container_name
  container_exists || log_die "no container for this project"
  rt stop "$CNAME" >/dev/null && log_ok "stopped ${CNAME}"
}

cmd_down() {
  container_name
  if [ ! -d "$CSTATE" ] && ! container_exists; then
    log_warn "no container/state for ${PROJECT_DIR}"; return 0
  fi
  dk_revoke "$CSTATE"
  if container_exists; then
    rt rm -f "$CNAME" >/dev/null 2>&1 && log_ok "container ${CNAME} removed"
  fi
  rm -rf "$CSTATE"
  # Named volumes hold data, so they survive `down` unless --volumes is given.
  if [ "${CPOD_DOWN_VOLUMES:-0}" = "1" ]; then
    rt volume rm "$CACHE_VOL" >/dev/null 2>&1 && log_ok "cache volume ${CACHE_VOL} removed"
  fi
}

cmd_restart() {
  container_name
  container_exists || log_die "no container for this project — use: cpod up"
  rt restart "$CNAME" >/dev/null || log_die "failed to restart ${CNAME}"
  log_ok "container ${CNAME} restarted"
  login_exec
}

# One-off command in the running container (docker exec-style); argv is literal.
cmd_exec() {
  container_name
  container_exists  || log_die "no container for this project — use: cpod up"
  container_running || log_die "container is stopped — start it: cpod start"
  [ "${#CPOD_PASSTHRU[@]}" -gt 0 ] || log_die "usage: cpod exec <command> [args...]"
  local -a tty=() wa=()
  [ -d "$PROJECT_DIR" ] && wa=( -w "$PROJECT_DIR" )
  if [ -t 0 ] && [ -t 1 ]; then tty=( -it ); else tty=( -i ); fi
  rt exec "${tty[@]}" "${wa[@]}" -e "TERM=${TERM:-xterm-256color}" "$CNAME" "${CPOD_PASSTHRU[@]}"
}

cmd_logs() {
  container_name
  container_exists || log_die "no container for this project"
  local -a a=(); [ "${CPOD_LOGS_FOLLOW:-0}" = "1" ] && a=( -f )
  rt logs "${a[@]}" "$CNAME"
}

cmd_inspect() {
  container_name
  container_exists || log_die "no container for this project"
  rt container inspect "$CNAME"
}

# Remove STOPPED cpod containers (this project, or --all), revoking their deploy
# keys and clearing state first — the safe bulk cleanup analog of `docker prune`.
cmd_prune() {
  local -a f=( --filter "label=cpod.managed=1" )
  local scope="${PROJECT_DIR}"
  if [ "${CPOD_ALL:-0}" = "1" ]; then scope="all projects"; else f+=( --filter "label=cpod.project=${PROJECT_DIR}" ); fi
  local names n removed=0
  names="$(rt ps -a "${f[@]}" --format '{{.Names}}' 2>/dev/null)" || true
  if [ -z "$names" ]; then log_info "no cpod containers to prune (${scope})"; return 0; fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ "$(rt container inspect -f '{{.State.Running}}' "$n" 2>/dev/null)" = "true" ]; then
      continue   # prune leaves running containers alone
    fi
    dk_revoke "${CPOD_STATE}/containers/${n}"
    if rt rm -f "$n" >/dev/null 2>&1; then
      rm -rf "${CPOD_STATE}/containers/${n}"; removed=$((removed+1)); log_ok "pruned ${n}"
    fi
  done <<< "$names"
  log_info "pruned ${removed} stopped container(s) (${scope})"
}

cmd_ls() {
  local -a f=( --filter "label=cpod.managed=1" )
  local scope="all projects"
  if [ "${CPOD_ALL:-0}" != "1" ]; then
    f+=( --filter "label=cpod.project=${PROJECT_DIR}" )
    scope="${PROJECT_DIR}"
  fi
  printf '%s[cpod]%s containers (%s):\n' "$_C_BLU" "$_C_RST" "$scope" >&2
  printf '%-40s %-22s %s\n' "NAME" "STATUS" "REPO"
  # Only {{.Names}} in ps (docker's {{.Label "x"}} is unsupported by podman); the
  # repo label is read per-container via inspect, which both runtimes support.
  local names n st repo
  names="$(rt ps -a "${f[@]}" --format '{{.Names}}' 2>/dev/null)" || return 0
  [ -n "$names" ] || return 0
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    st="$(rt container inspect -f '{{.State.Status}}' "$n" 2>/dev/null)"
    repo="$(rt container inspect -f '{{index .Config.Labels "cpod.repo"}}' "$n" 2>/dev/null)"
    printf '%-40s %-22s %s\n' "$n" "${st:-?}" "${repo:-—}"
  done <<< "$names"
}

cmd_status() {
  container_name
  if container_exists; then
    local st; st="$(rt container inspect -f '{{.State.Status}}' "$CNAME" 2>/dev/null)"
    log_info "container ${CNAME}: ${st}"
    [ -f "${CSTATE}/meta" ] && sed 's/^/    /' "${CSTATE}/meta" >&2
  else
    log_info "no container for ${PROJECT_DIR} (cpod up — create one)"
  fi
}

cmd_default() {
  container_name
  if ! container_exists; then cmd_up
  elif container_running; then cmd_attach
  else cmd_start; fi
}
