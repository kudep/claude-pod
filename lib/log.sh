# shellcheck shell=bash
# lib/log.sh — logging / warnings / small ui helpers (no side effects on source)

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'
  _C_BLU=$'\033[34m'; _C_DIM=$'\033[2m'; _C_RST=$'\033[0m'
else
  _C_RED=""; _C_YEL=""; _C_GRN=""; _C_BLU=""; _C_DIM=""; _C_RST=""
fi

log_info()  { printf '%s[cpod]%s %s\n'      "$_C_BLU" "$_C_RST" "$*" >&2; }
log_ok()    { printf '%s[cpod]%s %s\n'      "$_C_GRN" "$_C_RST" "$*" >&2; }
log_warn()  { printf '%s[cpod] warn:%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
log_error() { printf '%s[cpod] error:%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
log_step()  { printf '%s  ->%s %s\n'         "$_C_DIM" "$_C_RST" "$*" >&2; }

# log_die MSG [CODE] — print error and exit
log_die() { log_error "$*"; exit "${_die_code:-1}"; }

# require CMD [HINT] — ensure a command exists on the host
require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  log_error "требуется '$1', но он не найден в PATH${2:+ ($2)}"
  return 1
}
