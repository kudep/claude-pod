# shellcheck shell=bash
# lib/dind.sh — optional Docker access inside the container via host socket.
# CPOD_DIND: auto | on | off ; CPOD_DIND_EXPLICIT: 1 if user passed --docker/--no-docker.
# Appends to RUN_ARGS.

dind_project_uses_docker() {
  [ -f "${PROJECT_DIR}/Dockerfile" ] && return 0
  ls "${PROJECT_DIR}"/docker-compose*.y*ml >/dev/null 2>&1 && return 0
  [ -f "${PROJECT_DIR}/compose.yaml" ] || [ -f "${PROJECT_DIR}/compose.yml" ] && return 0
  return 1
}

dind_add() {
  local enable=0
  case "${CPOD_DIND}" in
    on)  enable=1 ;;
    off) return 0 ;;
    auto)
      if dind_project_uses_docker; then
        enable=1
        if [ "${CPOD_DIND_EXPLICIT}" != "1" ]; then
          log_warn "в проекте найден docker (Dockerfile/compose) — включаю проброс docker-сокета."
          log_warn "  это ~= root на хосте. Отключить: --no-docker. Задать явно заранее: --docker."
        fi
      fi
      ;;
  esac
  [ "$enable" = "1" ] || return 0

  local sock="/var/run/docker.sock"
  if [ ! -S "$sock" ]; then
    log_warn "docker-сокет ${sock} не найден на хосте — DinD пропущен"
    return 0
  fi
  RUN_ARGS+=( -v "${sock}:${sock}" )
  # Grant the container user access to the socket's group.
  local gid
  gid="$(stat -c '%g' "$sock" 2>/dev/null || echo)"
  [ -n "$gid" ] && RUN_ARGS+=( --group-add "$gid" )
  log_step "DinD: проброшен ${sock}"
}
