# shellcheck shell=bash
# lib/deploykey.sh — per-repo GitHub deploy key, delivered via ssh-agent forwarding.
#
# Inputs (globals set by bin/cpod): PROJECT_DIR, CPOD_KEY_MODE (rw|ro|none),
#   CPOD_KEY_FILE (0/1 fallback), CSTATE (per-container state dir), CONTAINER_HOME.
# Effects: appends to RUN_ARGS, writes key metadata into $CSTATE/meta, and sets
#   CPOD env vars so the container entrypoint configures git/ssh.

# Parse owner/repo from the project's GitHub origin. Sets DK_OWNER/DK_REPO/DK_SLUG.
dk_parse_repo() {
  local url path
  url="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null)" || return 1
  case "$url" in
    git@github.com:*)        path="${url#git@github.com:}" ;;
    ssh://git@github.com/*)  path="${url#ssh://git@github.com/}" ;;
    https://github.com/*)    path="${url#https://github.com/}" ;;
    http://github.com/*)     path="${url#http://github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"
  DK_OWNER="${path%%/*}"; DK_REPO="${path#*/}"
  [ -n "$DK_OWNER" ] && [ -n "$DK_REPO" ] && [ "$DK_OWNER" != "$path" ] || return 1
  # Sanitize: owner/repo must each be a single plain segment (no path traversal into
  # the gh API path like foo/bar/../../evil, no slashes/spaces).
  [[ "$DK_OWNER" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$DK_REPO" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  DK_SLUG="${DK_OWNER}/${DK_REPO}"
}

# Generate + register a deploy key and wire it into the container.
dk_setup() {
  DK_KEYID=""; DK_SLUG=""
  # entrypoint defaults CPOD_HAS_KEY to 0; we only set it to 1 on the success path.

  if [ "${CPOD_KEY_MODE}" = "none" ]; then
    log_step "git: deploy key disabled (--key none), working on the local copy"; return 0
  fi
  command -v git >/dev/null 2>&1 || { log_warn "git not found on the host — git isolation skipped"; return 0; }
  git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || {
    log_step "git: current directory is not a repository — no deploy key (by design)"; return 0; }
  dk_parse_repo || { log_step "git: origin is not GitHub — no deploy key, working locally"; return 0; }

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    log_warn "gh unavailable/not authenticated — deploy key not created (git local only)"; return 0
  fi

  local ro="false"; [ "${CPOD_KEY_MODE}" = "ro" ] && ro="true"
  local kf="${CSTATE}/deploy_key"
  local host tstamp
  host="$(hostname -s 2>/dev/null || echo host)"
  tstamp="$(date +%Y-%m-%dT%H-%M-%S)"
  ssh-keygen -q -t ed25519 -N '' -C "cpod-${host}-${tstamp}" -f "$kf" || { log_warn "ssh-keygen failed — no key"; return 0; }

  local id
  id="$(gh api -X POST "/repos/${DK_SLUG}/keys" \
        -f title="cpod ${host} ${tstamp}" \
        -f key="$(cat "${kf}.pub")" \
        -F read_only="${ro}" --jq '.id' 2>/dev/null)" || id=""
  if [ -z "$id" ]; then
    log_warn "failed to register deploy key on ${DK_SLUG} (write access to the repo is required) — no key"
    rm -f "$kf" "${kf}.pub"; return 0
  fi
  DK_KEYID="$id"
  { echo "repo=${DK_SLUG}"; echo "keyid=${id}"; echo "keymode=${CPOD_KEY_MODE}"; } >> "${CSTATE}/meta"
  log_ok "deploy key #${id} for ${DK_SLUG} (mode: ${CPOD_KEY_MODE})"

  RUN_ARGS+=( -e "CPOD_GIT_REPO=${DK_SLUG}" -e "CPOD_HAS_KEY=1" )

  if [ "${CPOD_KEY_FILE}" = "1" ]; then
    # Fallback: mount the private key file read-only (weaker: key touches container disk).
    RUN_ARGS+=( -v "${kf}:${CONTAINER_HOME}/.ssh/id_ed25519:ro" -e "CPOD_SSH_MODE=file" )
    echo "key_file=${kf}" >> "${CSTATE}/meta"
    log_step "key delivered as a file (--key-file): ${CONTAINER_HOME}/.ssh/id_ed25519 (ro)"
  else
    # Default: ssh-agent forwarding — private key stays in agent memory, never on container disk.
    if ! command -v ssh-agent >/dev/null 2>&1 || ! command -v ssh-add >/dev/null 2>&1; then
      log_warn "ssh-agent unavailable — falling back to --key-file"
      RUN_ARGS+=( -v "${kf}:${CONTAINER_HOME}/.ssh/id_ed25519:ro" -e "CPOD_SSH_MODE=file" )
      echo "key_file=${kf}" >> "${CSTATE}/meta"; return 0
    fi
    local sock="${CSTATE}/agent.sock" agent_out agent_pid
    rm -f "$sock"
    agent_out="$(ssh-agent -a "$sock" 2>/dev/null)" || { log_warn "could not start ssh-agent — falling back to file"; \
      RUN_ARGS+=( -v "${kf}:${CONTAINER_HOME}/.ssh/id_ed25519:ro" -e "CPOD_SSH_MODE=file" ); echo "key_file=${kf}" >> "${CSTATE}/meta"; return 0; }
    agent_pid="$(printf '%s' "$agent_out" | sed -n 's/.*SSH_AGENT_PID=\([0-9]*\).*/\1/p')"
    SSH_AUTH_SOCK="$sock" ssh-add "$kf" >/dev/null 2>&1 || log_warn "ssh-add failed"
    { echo "agent_pid=${agent_pid}"; echo "agent_sock=${sock}"; } >> "${CSTATE}/meta"
    # Key is now in agent memory — remove it from disk.
    shred -u "$kf" 2>/dev/null || rm -f "$kf"
    rm -f "${kf}.pub"
    RUN_ARGS+=( -v "${sock}:/run/cpod-ssh-agent.sock" -e "SSH_AUTH_SOCK=/run/cpod-ssh-agent.sock" -e "CPOD_SSH_MODE=agent" )
    log_step "key delivered via ssh-agent (socket forwarded, no key on the container disk)"
  fi
}

# Revoke a deploy key and stop its agent, given a container state dir with meta.
dk_revoke() {
  local cstate="$1" meta="$1/meta" repo keyid agent_pid
  [ -f "$meta" ] || return 0
  repo="$(sed -n 's/^repo=//p' "$meta" | tail -1)"
  keyid="$(sed -n 's/^keyid=//p' "$meta" | tail -1)"
  agent_pid="$(sed -n 's/^agent_pid=//p' "$meta" | tail -1)"
  if [ -n "$repo" ] && [ -n "$keyid" ]; then
    if command -v gh >/dev/null 2>&1 && gh api -X DELETE "/repos/${repo}/keys/${keyid}" >/dev/null 2>&1; then
      log_ok "deploy key #${keyid} revoked from ${repo}"
    else
      log_warn "could not revoke deploy key #${keyid} from ${repo} — check manually: gh api /repos/${repo}/keys"
    fi
  fi
  if [ -n "$agent_pid" ] && kill -0 "$agent_pid" 2>/dev/null; then
    kill "$agent_pid" 2>/dev/null && log_step "ssh-agent (pid ${agent_pid}) stopped"
  fi
}
