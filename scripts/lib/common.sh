#!/usr/bin/env bash
# ===================================================================
#  media-suite — shared script library
# ===================================================================
#  Sourced by install.sh, update.sh, remove.sh and configure.sh.
#  Not executable on its own.
#
#  Dependencies are deliberately limited to bash, coreutils, openssl
#  and curl: install.sh has to run on a bare host before Docker (or
#  anything else) exists.
# ===================================================================

# Resolve repo paths from this file's location, so scripts work from
# any working directory.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_LIB_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
ENV_EXAMPLE="${REPO_ROOT}/.env.example"
export REPO_ROOT ENV_FILE ENV_EXAMPLE

# Behaviour flags, overridden by each script's argument parser.
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
WITH_PORTAINER="${WITH_PORTAINER:-0}"

# ── Presentation ───────────────────────────────────────────────────

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_DIM=''; C_BOLD=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

log_step()    { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
log_info()    { printf '    %s\n' "$*"; }
log_success() { printf '    %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()    { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '    %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_skip()    { printf '    %s·%s %s %s(already done)%s\n' "$C_DIM" "$C_RESET" "$*" "$C_DIM" "$C_RESET"; }
log_cmd()     { printf '    %s$ %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
# log_applied — for messages asserting that state CHANGED. Silent under
# --dry-run, where `run` has already printed what would happen and a
# "✓ done" line would be a lie.
log_applied() { (( DRY_RUN )) || log_success "$@"; }
log_dry()     { printf '    %s[dry-run]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }

die() { log_error "$*"; exit 1; }

# ── Error reporting ────────────────────────────────────────────────

# Installed by each script via: trap 'on_error $LINENO' ERR
on_error() {
  local line="$1" code=$?
  log_error "Failed at ${BASH_SOURCE[1]:-script}:${line} (exit ${code})"
  log_info  "Re-run with --verbose to see the failing command."
  exit "$code"
}

# ── Execution ──────────────────────────────────────────────────────

# run CMD...  — honours --verbose and --dry-run.
# Use for anything that changes state. Read-only queries call directly.
run() {
  (( VERBOSE )) && log_cmd "$*"
  if (( DRY_RUN )); then
    log_dry "$*"
    return 0
  fi
  "$@"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  have_cmd "$1" || die "Required command not found: $1${2:+ ($2)}"
}

# confirm PROMPT [default]  — default is "n" unless given as "y".
confirm() {
  local prompt="$1" default="${2:-n}" reply hint
  if (( NON_INTERACTIVE )); then
    [[ "$default" == "y" ]] && return 0 || return 1
  fi
  [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "    ${prompt} ${hint} " reply || true
  reply="${reply:-$default}"
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# ask PROMPT DEFAULT  — prints the answer on stdout.
ask() {
  local prompt="$1" default="$2" reply
  if (( NON_INTERACTIVE )); then
    printf '%s' "$default"
    return 0
  fi
  read -r -p "    ${prompt} [${default}]: " reply || true
  printf '%s' "${reply:-$default}"
}

# ── .env handling ──────────────────────────────────────────────────

# env_get KEY [FILE] — prints value, returns 1 if absent or empty.
env_get() {
  local key="$1" file="${2:-$ENV_FILE}" line
  [[ -f "$file" ]] || return 1
  line="$(grep -m1 -E "^${key}=" "$file" 2>/dev/null)" || return 1
  line="${line#*=}"
  [[ -n "$line" ]] || return 1
  printf '%s' "$line"
}

# env_set KEY VALUE [FILE] — idempotent in-place edit. Handles values
# containing slashes, ampersands and dollars, which sed would mangle.
env_set() {
  local key="$1" value="$2" file="${3:-$ENV_FILE}"
  local tmp found=0 line
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "${key}="* ]]; then
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
        found=1
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$file"
  fi
  (( found )) || printf '%s=%s\n' "$key" "$value" >>"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# env_set_default KEY VALUE — only writes if the key is unset/empty.
# Anything the operator set by hand always wins over detection.
env_set_default() {
  local key="$1" value="$2"
  env_get "$key" >/dev/null 2>&1 && return 0
  env_set "$key" "$value"
}

require_env_file() {
  [[ -f "$ENV_FILE" ]] || die "No .env found. Run ./scripts/install.sh first."
}

# ── Compose ────────────────────────────────────────────────────────

compose() {
  local -a files=(-f "${REPO_ROOT}/compose/compose.yml")
  if [[ "${WITH_PORTAINER}" == "1" || -f "${REPO_ROOT}/.portainer-enabled" ]]; then
    files+=(-f "${REPO_ROOT}/compose/compose.portainer.yml")
  fi
  docker compose \
    --project-directory "$REPO_ROOT" \
    --env-file "$ENV_FILE" \
    "${files[@]}" "$@"
}

# ── Host detection ─────────────────────────────────────────────────

detect_default_iface() {
  ip route show default 2>/dev/null | awk '{print $5; exit}'
}

detect_server_ip() {
  local iface
  iface="$(detect_default_iface)"
  [[ -n "$iface" ]] || return 1
  ip -4 -o addr show dev "$iface" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -1
}

# Converts an interface address like 192.168.1.5/24 to its network
# address, 192.168.1.0/24.
cidr_network() {
  local cidr="$1" addr prefix a b c d net mask
  addr="${cidr%/*}"; prefix="${cidr#*/}"
  IFS=. read -r a b c d <<<"$addr"
  [[ -n "$d" ]] || return 1
  net=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  if (( prefix == 0 )); then mask=0; else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  net=$(( net & mask ))
  printf '%d.%d.%d.%d/%d' \
    $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) \
    $(( (net >> 8) & 255 )) $(( net & 255 )) "$prefix"
}

detect_lan_network() {
  local iface cidr
  iface="$(detect_default_iface)"
  [[ -n "$iface" ]] || return 1
  cidr="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | head -1)"
  [[ -n "$cidr" ]] || return 1
  cidr_network "$cidr"
}

detect_timezone() {
  local tz
  if have_cmd timedatectl; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null)" && [[ -n "$tz" ]] && {
      printf '%s' "$tz"; return 0; }
  fi
  if [[ -r /etc/timezone ]]; then
    tz="$(tr -d '[:space:]' </etc/timezone)" && [[ -n "$tz" ]] && {
      printf '%s' "$tz"; return 0; }
  fi
  if [[ -L /etc/localtime ]]; then
    tz="$(readlink -f /etc/localtime)"
    tz="${tz#/usr/share/zoneinfo/}"
    [[ -n "$tz" ]] && { printf '%s' "$tz"; return 0; }
  fi
  return 1
}

detect_fqdn() {
  local name
  name="$(hostname -f 2>/dev/null)" || name="$(hostname 2>/dev/null)"
  [[ -n "$name" ]] || return 1
  printf '%s' "$name"
}

# ── Misc ───────────────────────────────────────────────────────────

port_in_use() {
  local port="$1"
  if have_cmd ss; then
    ss -Hltn "sport = :${port}" 2>/dev/null | grep -q . && return 0
  elif have_cmd netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && return 0
  fi
  return 1
}

# Prints the active media app from COMPOSE_PROFILES: plex, jellyfin,
# or nothing.
active_media_app() {
  local profiles
  profiles="$(env_get COMPOSE_PROFILES 2>/dev/null)" || return 1
  case ",${profiles}," in
    *,plex,*)     printf 'plex' ;;
    *,jellyfin,*) printf 'jellyfin' ;;
    *) return 1 ;;
  esac
}

has_profile() {
  local want="$1" profiles
  profiles="$(env_get COMPOSE_PROFILES 2>/dev/null)" || return 1
  [[ ",${profiles}," == *",${want},"* ]]
}
