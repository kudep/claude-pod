# shellcheck shell=bash
# lib/version.sh — `cpod version` / `--version`.
#
# Prints cpod's own version plus the versions of the host software it drives:
# the container runtimes (podman/docker) and the supporting tools (git, gh, ssh,
# nvidia-smi). The active/would-be-selected runtime is highlighted so you can see
# at a glance which one a plain `cpod up` would use.

# cpod_version — cpod's own version string (from the VERSION file, else "unknown").
cpod_version() {
  local vf="${CPOD_HOME}/VERSION"
  if [ -f "$vf" ]; then tr -d '[:space:]' < "$vf"; else printf 'unknown'; fi
}

# _ver_extract CMD... — run the tool's version command and pull out the first
# version-looking token (e.g. 1.2.3 / 9.6p1). Echoes the raw first line if no
# such token is found. Nothing is printed (rc 1) when the tool is absent.
_ver_extract() {
  local bin="$1"; shift
  command -v "$bin" >/dev/null 2>&1 || return 1
  local out
  # ssh -V and some tools print to stderr; fold both streams together.
  out="$("$bin" "$@" 2>&1 | head -n1)"
  local num
  num="$(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+([.][0-9]+)?([A-Za-z0-9]+)?' | head -n1)"
  printf '%s' "${num:-$out}"
}

# _ver_row LABEL VALUE [SUFFIX] — print one aligned "  label   value suffix" line.
_ver_row() {
  local label="$1" value="$2" suffix="${3:-}"
  if [ -n "$value" ]; then
    printf '  %s%-11s%s %s%s\n' "$_C_GRN" "$label" "$_C_RST" "$value" \
      "${suffix:+ $_C_DIM$suffix$_C_RST}" >&2
  else
    printf '  %s%-11s%s %snot installed%s\n' "$_C_GRN" "$label" "$_C_RST" \
      "$_C_DIM" "$_C_RST" >&2
  fi
}

# _ver_active_runtime — which runtime a plain `cpod up` would pick right now,
# mirroring rt_detect()'s order but never dying when none is present.
_ver_active_runtime() {
  local want="${CPOD_RUNTIME:-${CLAUDE_POD_RUNTIME:-}}"
  if [ -n "$want" ]; then printf '%s' "$want"; return; fi
  if command -v podman >/dev/null 2>&1; then printf 'podman'
  elif command -v docker >/dev/null 2>&1; then printf 'docker'
  fi
}

cmd_version() {
  local active; active="$(_ver_active_runtime)"

  printf '%scpod%s %s\n' "$_C_BLU" "$_C_RST" "$(cpod_version)" >&2

  # Container runtimes — always list both; tag the one that would be used.
  local rt v
  for rt in podman docker; do
    v="$(_ver_extract "$rt" --version || true)"
    if [ "$rt" = "$active" ]; then _ver_row "$rt" "$v" "(active)"; else _ver_row "$rt" "$v"; fi
  done

  # Supporting host tools cpod relies on.
  _ver_row git        "$(_ver_extract git  --version   || true)"
  _ver_row gh         "$(_ver_extract gh   --version   || true)"
  _ver_row ssh        "$(_ver_extract ssh  -V          || true)"
  _ver_row nvidia-smi "$(_ver_extract nvidia-smi --version || true)"
}
