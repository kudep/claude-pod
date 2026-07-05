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
  # Claude Code keeps its main config (projects, onboarding, MCP) in ~/.claude.json,
  # a FILE next to the dir — mount it too so the pod isn't seen as a fresh install.
  [ -f "${HOST_HOME}/.claude.json" ] && RUN_ARGS+=( -v "${HOST_HOME}/.claude.json:${CONTAINER_HOME}/.claude.json" )
  if [ "${CPOD_CLAUDE_HARDENED:-0}" = "1" ]; then
    local p
    for p in settings.json settings.local.json plugins agents skills commands hooks; do
      [ -e "${hc}/${p}" ] && RUN_ARGS+=( -v "${hc}/${p}:${cc}/${p}:ro" )
    done
    log_step ".claude: hardened — settings*/plugins/agents/skills/commands/hooks mounted ro"
  fi
  return 0
}

# Rewrite a host-local proxy URL to the container's host-gateway so a localhost
# proxy on the host stays reachable from inside (a no-op under --net-host, where
# the container already shares the host loopback).
_proxy_rewrite() {
  local v="$1" gw
  if [ "${CPOD_NET_HOST}" != "1" ]; then
    gw="$(rt_host_gateway_host)"
    v="${v//localhost/$gw}"; v="${v//127.0.0.1/$gw}"
  fi
  printf '%s' "$v"
}

# Proxy passthrough (opt-in with --proxy) with localhost -> host-gateway rewrite. OFF by
# default: forwarding an unreachable proxy silently breaks the pod's network (esp. rootless
# podman), whereas the pod's direct network is usually what apt/git/setup want.
mounts_add_proxy() {
  [ "${CPOD_AUTO_PROXY}" = "1" ] || return 0

  local var val had_local=0
  for var in http_proxy https_proxy ftp_proxy no_proxy \
             HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
    val="${!var:-}"; [ -n "$val" ] || continue
    case "$val" in *localhost*|*127.0.0.1*) had_local=1 ;; esac
    RUN_ARGS+=( -e "${var}=$(_proxy_rewrite "$val")" )
  done

  # Claude's API is HTTPS. Many setups define only http_proxy (a single proxy that
  # also handles HTTPS via CONNECT). Without https_proxy, claude's API traffic would
  # bypass it and fail — so mirror the HTTP proxy onto HTTPS when the host lacks one.
  local http_any="${http_proxy:-${HTTP_PROXY:-}}"
  if [ -n "$http_any" ] && [ -z "${https_proxy:-}" ] && [ -z "${HTTPS_PROXY:-}" ]; then
    case "$http_any" in *localhost*|*127.0.0.1*) had_local=1 ;; esac
    local hv; hv="$(_proxy_rewrite "$http_any")"
    RUN_ARGS+=( -e "https_proxy=${hv}" -e "HTTPS_PROXY=${hv}" )
    log_step "no host https_proxy — routing HTTPS (Claude's API) through http_proxy: ${hv}"
  fi

  # Footgun: on rootless podman a host-local proxy rewritten to the host-gateway is NOT
  # reachable (slirp blocks host services) unless the pod shares the host network. Warn
  # instead of leaving the user with a silently dead network.
  if [ "$had_local" = "1" ] && rt_is_podman && [ "${CPOD_NET_HOST}" != "1" ]; then
    log_warn "rootless podman: this host-local proxy is unreachable from a bridge pod (slirp)."
    log_warn "  add --net-host, or drop --proxy to use the pod's direct network."
  fi
  return 0
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

# Extra bind mounts and named volumes (docker-style -v/--volume), plus an optional
# per-project cache volume. Passthrough SPECs (HOST:CONT[:opts] or NAME:CONT[:opts])
# are forwarded verbatim; a couple of clearly dangerous sources get a warning since
# any -v weakens the isolation this tool exists to provide.
mounts_add_volumes() {
  local v src
  for v in "${CPOD_VOLUMES[@]:-}"; do
    [ -n "$v" ] || continue
    src="${v%%:*}"
    case "$src" in
      /|/etc|/etc/*|/root|/root/*|"${HOST_HOME}"|"${HOST_HOME}/.ssh"*)
        log_warn "-v mounts sensitive host path '${src}' — this weakens isolation" ;;
    esac
    case "$v" in
      */docker.sock*|*/podman.sock*)
        log_warn "-v mounts a container socket (host control) — use --docker for the daemon instead" ;;
    esac
    RUN_ARGS+=( -v "$v" )
    log_step "volume: ${v}"
  done
  if [ "${CPOD_CACHE_VOL:-0}" = "1" ]; then
    RUN_ARGS+=( -v "${CACHE_VOL}:${CONTAINER_HOME}/.cache" )
    log_step "cache volume ${CACHE_VOL} -> ${CONTAINER_HOME}/.cache (persists across recreation; remove with 'down --volumes')"
  fi
  return 0
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
