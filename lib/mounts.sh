# shellcheck shell=bash
# lib/mounts.sh — bind mounts, ~/.claude hybrid, proxy/env, networking, ports.
# All functions append to the global RUN_ARGS array declared by bin/cpod.

# Secrets never forwarded even with --inherit-env (avoid leaking the main account).
_CPOD_ENV_DENY_RE='^(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|.*_API_KEY|.*_APIKEY|.*_SECRET|.*_TOKEN|.*_PASSWORD|AWS_.*|GOOGLE_APPLICATION_CREDENTIALS|ANTHROPIC_API_KEY|SSH_AUTH_SOCK|HOME|PATH|USER|LOGNAME|SHELL|PWD|OLDPWD|HOSTNAME)$'

# Project mounted at the *same* absolute path as on the host so that
# ~/.claude/projects/<slug> keeps matching and sessions continue seamlessly.
mounts_add_project() {
  case "$PROJECT_DIR" in
    *:*) log_die "project path contains ':' — bind mount is not possible: ${PROJECT_DIR}" ;;
  esac
  RUN_ARGS+=( -v "${PROJECT_DIR}:${PROJECT_DIR}" -w "${PROJECT_DIR}" )
}

# ~/.claude hybrid: whole dir rw, credentials file ro on top. With --claude-hardened,
# the executable-config surface (settings*.json, plugins/agents/skills/commands/hooks)
# is also mounted ro so a compromised container can't plant a hook that later runs on
# the HOST. Sessions/history/projects stay rw for seamless continuation.
mounts_add_claude() {
  local hc="${HOST_HOME}/.claude" cc="${CONTAINER_HOME}/.claude"
  [ -d "$hc" ] || { log_warn "host has no ${hc} — container starts without shared Claude settings"; return 0; }
  RUN_ARGS+=( -v "${hc}:${cc}" )
  [ -f "${hc}/.credentials.json" ] && RUN_ARGS+=( -v "${hc}/.credentials.json:${cc}/.credentials.json:ro" )
  if [ "${CPOD_CLAUDE_HARDENED:-0}" = "1" ]; then
    local p
    for p in settings.json settings.local.json plugins agents skills commands hooks; do
      [ -e "${hc}/${p}" ] && RUN_ARGS+=( -v "${hc}/${p}:${cc}/${p}:ro" )
    done
    log_step ".claude: hardened — settings*/plugins/agents/skills/commands/hooks mounted ro"
  fi
  return 0
}

# Proxy passthrough with localhost -> host-gateway rewrite (skipped under --net-host).
mounts_add_proxy() {
  local gw var val
  gw="$(rt_host_gateway_host)"
  for var in http_proxy https_proxy ftp_proxy no_proxy \
             HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
    val="${!var:-}"; [ -n "$val" ] || continue
    if [ "${CPOD_NET_HOST}" != "1" ]; then
      val="${val//localhost/$gw}"; val="${val//127.0.0.1/$gw}"
    fi
    RUN_ARGS+=( -e "${var}=${val}" )
  done
}

# --inherit-env: forward all host env except the secret denylist. Plus --env passthroughs.
mounts_add_env() {
  local kv k
  if [ "${CPOD_INHERIT_ENV}" = "1" ]; then
    while IFS= read -r kv; do
      k="${kv%%=*}"
      [[ "$k" =~ $_CPOD_ENV_DENY_RE ]] && continue
      [[ "$k" =~ ^(http_proxy|https_proxy|no_proxy|ftp_proxy)$ ]] && continue  # handled by proxy
      RUN_ARGS+=( -e "$k" )
    done < <(env)
  fi
  for k in "${CPOD_EXTRA_ENV[@]:-}"; do
    [ -n "$k" ] && RUN_ARGS+=( -e "$k" )
  done
  # Git identity from the host (values only — never mount host ~/.gitconfig / credential helpers).
  [ -n "${CPOD_GIT_NAME:-}" ]  && RUN_ARGS+=( -e "CPOD_GIT_NAME=${CPOD_GIT_NAME}" )
  [ -n "${CPOD_GIT_EMAIL:-}" ] && RUN_ARGS+=( -e "CPOD_GIT_EMAIL=${CPOD_GIT_EMAIL}" )
  return 0   # never let a trailing false test propagate under `set -e`
}

# Networking: host network on request, otherwise host-gateway resolution for proxy.
mounts_add_net() {
  if [ "${CPOD_NET_HOST}" = "1" ]; then
    RUN_ARGS+=( --network host )
  else
    local a; while IFS= read -r a; do [ -n "$a" ] && RUN_ARGS+=( "$a" ); done < <(rt_host_gateway_args)
  fi
}

# Port publishing (docker-style -p/--port), e.g. 8080:80, 127.0.0.1:8080:80, 8080:80/udp.
# Ignored under --net-host (host network publishes nothing).
mounts_add_ports() {
  [ "${#CPOD_PORTS[@]}" -gt 0 ] || return 0
  if [ "${CPOD_NET_HOST}" = "1" ]; then
    log_warn "-p/--port is ignored with --net-host (host network); drop --net-host to publish ports"
    return 0
  fi
  local p
  for p in "${CPOD_PORTS[@]}"; do
    [ -n "$p" ] && RUN_ARGS+=( -p "$p" )
  done
  log_step "published ports: ${CPOD_PORTS[*]}"
}
