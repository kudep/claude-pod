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
}

container_exists()  { rt container inspect "$CNAME" >/dev/null 2>&1; }
container_running() { [ "$(rt container inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null)" = "true" ]; }

image_ensure() {
  if [ "${CPOD_REBUILD:-0}" != "1" ] && rt image inspect "$IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  log_info "собираю образ ${IMAGE} (runtime=${RT}, база=${CPOD_BASE_IMAGE})…"
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
    -t "$IMAGE" "${CPOD_HOME}/image" || log_die "сборка образа не удалась"
  log_ok "образ ${IMAGE} готов"
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
    log_warn "контейнер ${CNAME} уже существует"
    if container_running; then cmd_attach; else cmd_start; fi
    return
  fi
  image_ensure
  mkdir -p "$CSTATE"; : > "${CSTATE}/meta"
  { echo "project=${PROJECT_DIR}"; echo "runtime=${RT}"; } >> "${CSTATE}/meta"

  RUN_ARGS=()
  RUN_ARGS+=( --name "${CNAME}" --hostname "cpod" )
  RUN_ARGS+=( --label "cpod.managed=1" --label "cpod.project=${PROJECT_DIR}" --label "cpod.runtime=${RT}" )
  RUN_ARGS+=( -e "CONTAINER_HOME=${CONTAINER_HOME}" )

  local a
  while IFS= read -r a; do [ -n "$a" ] && RUN_ARGS+=( "$a" ); done < <(rt_userns_args)

  mounts_add_project
  mounts_add_claude
  mounts_add_net
  mounts_add_proxy
  mounts_add_env
  gpu_add
  dind_add
  dk_setup

  [ -n "${DK_KEYID:-}" ] && RUN_ARGS+=( --label "cpod.keyid=${DK_KEYID}" )
  [ -n "${DK_SLUG:-}" ]  && RUN_ARGS+=( --label "cpod.repo=${DK_SLUG}" )

  log_info "создаю контейнер ${CNAME}"
  rt run -d "${RUN_ARGS[@]}" "$IMAGE" >/dev/null || log_die "не удалось запустить контейнер"
  log_ok "контейнер ${CNAME} запущен (${RT})"
  [ "${CPOD_RUN_CLAUDE}" = "1" ] || [ -n "${CPOD_RUN_CMD}" ] || \
    log_info "вход в shell (claude не запущен автоматически; наберите 'claude' вручную)"
  login_exec
}

cmd_start() {
  container_name
  container_exists || log_die "нет контейнера для этого проекта — используйте: cpod up"
  if ! container_running; then
    rt start "$CNAME" >/dev/null || log_die "не удалось запустить ${CNAME}"
    log_ok "контейнер ${CNAME} запущен"
  fi
  login_exec
}

cmd_attach() {
  container_name
  container_exists || log_die "нет контейнера для этого проекта — используйте: cpod up"
  container_running || { log_info "контейнер остановлен — поднимаю"; cmd_start; return; }
  login_exec
}

cmd_stop() {
  container_name
  container_exists || log_die "нет контейнера для этого проекта"
  rt stop "$CNAME" >/dev/null && log_ok "остановлен ${CNAME}"
}

cmd_down() {
  container_name
  if [ ! -d "$CSTATE" ] && ! container_exists; then
    log_warn "нет контейнера/состояния для ${PROJECT_DIR}"; return 0
  fi
  dk_revoke "$CSTATE"
  if container_exists; then
    rt rm -f "$CNAME" >/dev/null 2>&1 && log_ok "контейнер ${CNAME} удалён"
  fi
  rm -rf "$CSTATE"
}

cmd_ls() {
  local -a f=( --filter "label=cpod.managed=1" )
  local scope="все проекты"
  if [ "${CPOD_ALL:-0}" != "1" ]; then
    f+=( --filter "label=cpod.project=${PROJECT_DIR}" )
    scope="${PROJECT_DIR}"
  fi
  printf '%s[cpod]%s контейнеры (%s):\n' "$_C_BLU" "$_C_RST" "$scope" >&2
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
    log_info "контейнер ${CNAME}: ${st}"
    [ -f "${CSTATE}/meta" ] && sed 's/^/    /' "${CSTATE}/meta" >&2
  else
    log_info "для ${PROJECT_DIR} контейнера нет (cpod up — создать)"
  fi
}

cmd_default() {
  container_name
  if ! container_exists; then cmd_up
  elif container_running; then cmd_attach
  else cmd_start; fi
}
