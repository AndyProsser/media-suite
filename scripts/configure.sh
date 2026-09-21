#!/usr/bin/env bash
# ===================================================================
#  media-suite — post-install application wiring
# ===================================================================
#  Installing containers is the easy part. What actually costs an
#  evening is connecting them to each other: telling each arr app
#  about qBittorrent, telling Prowlarr about each arr app, and setting
#  root folders. This does that over their REST APIs.
#
#  Idempotent — every entry is looked up by name before being created,
#  so it is safe to re-run, and safe against a stack you have already
#  partly configured by hand.
#
#  Indexers are deliberately NOT automated: which trackers you use and
#  what your credentials are is not something this repo should guess.
#
#    ./scripts/configure.sh
#    ./scripts/configure.sh --dry-run
# ===================================================================
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
trap 'on_error $LINENO' ERR

usage() {
  cat <<'USAGE'
Usage: ./scripts/configure.sh [options]

Wires the arr applications together after install:
  · registers qBittorrent as a download client in Radarr/Sonarr/Lidarr
  · registers those apps in Prowlarr so indexers sync automatically
  · sets each app's root folder under /data/media
  · registers Byparr as Prowlarr's FlareSolverr indexer proxy
  · sets qBittorrent's save path to /data/torrents/ and removes any
    stale Remote Path Mapping that was worked around it instead

Safe to re-run; existing configuration is never overwritten.

Options:
  --dry-run    Report what would be configured, change nothing.
  --verbose    Show each API call.
  -h, --help   This text.
USAGE
}

while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

# ── API keys ───────────────────────────────────────────────────────
# Each arr app writes its key into config.xml on first start. Read
# them with sudo, since the files are owned by the container user.

read_api_key() {
  local app="$1" conf file
  conf="$(env_get DOCKERCONFDIR)"
  file="${conf}/${app}/config.xml"
  # install.sh chowns appdata to PUID:PGID, so this is normally
  # readable without sudo. Fall back to a NON-interactive sudo rather
  # than a prompt, which would hang an otherwise unattended run.
  if [[ -r "$file" ]]; then
    grep -oP '(?<=<ApiKey>)[^<]+' "$file" 2>/dev/null | head -1
  elif sudo -n test -r "$file" 2>/dev/null; then
    sudo -n grep -oP '(?<=<ApiKey>)[^<]+' "$file" 2>/dev/null | head -1
  else
    return 1
  fi
}

# ── qBittorrent credentials ────────────────────────────────────────
# Modern qBittorrent generates a temporary password on first start and
# prints it to the log. If the operator has already changed it, we
# cannot recover it — say so rather than writing a wrong one.

read_qbit_password() {
  local pass
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx qbittorrent || return 1
  pass="$(timeout 15 docker logs qbittorrent 2>&1 \
    | grep -oP 'temporary password is provided for this session:\s*\K\S+' \
    | tail -1)" || true
  [[ -n "$pass" ]] || return 1
  printf '%s' "$pass"
}

# ── qBittorrent access ─────────────────────────────────────────────
# qBittorrent keeps its own login even behind the proxy, which would
# mean a second prompt after signing in. Trusting the Docker network
# it is reached over removes that. Requests only arrive from Traefik —
# the container publishes no ports — so this does not widen access
# beyond whatever already guards the /download route.
#
# Driven through `docker exec` rather than the proxy, because under
# --auth=sso the proxy route is itself behind the login.

# qbittorrent_set_preference JSON — logs in and POSTs one
# setPreferences call. Prints the login and set HTTP status codes,
# space-separated ("204 200" is success for both).
qbittorrent_set_preference() {
  local json="$1"
  docker exec qbittorrent sh -c "
    curl -s -c /tmp/qb.ck -o /dev/null -w '%{http_code}' \
      --data-urlencode 'username=${QBIT_USER}' \
      --data-urlencode 'password=${QBIT_PASS}' \
      -H 'Referer: http://127.0.0.1:8080' \
      http://127.0.0.1:8080/api/v2/auth/login
    printf ' '
    curl -s -b /tmp/qb.ck -o /dev/null -w '%{http_code}' \
      -H 'Referer: http://127.0.0.1:8080' \
      --data-urlencode 'json=${json}' \
      http://127.0.0.1:8080/api/v2/app/setPreferences
    rm -f /tmp/qb.ck
  " 2>/dev/null
}

configure_qbittorrent_access() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx qbittorrent || {
    log_warn "qbittorrent is not running — skipping its access settings."
    return 0
  }

  local subnet
  subnet="$(docker network inspect traefik \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
  if [[ -z "$subnet" ]]; then
    log_warn "Could not determine the traefik network subnet — skipping."
    return 0
  fi

  # Already configured? Leave it alone.
  local current
  current="$(docker exec qbittorrent curl -s \
    http://127.0.0.1:8080/api/v2/app/preferences 2>/dev/null \
    | grep -o '"bypass_auth_subnet_whitelist_enabled":[a-z]*' || true)"
  if [[ "$current" == *true ]]; then
    log_skip "qbittorrent: already trusts the proxy network"
    return 0
  fi

  if [[ -z "${QBIT_PASS:-}" ]]; then
    log_warn "qbittorrent: no password available, cannot change its settings."
    log_info "Set 'Bypass authentication for clients in whitelisted IP subnets'"
    log_info "to ${subnet} under Tools > Options > Web UI, to avoid a second login."
    return 0
  fi

  if (( DRY_RUN )); then
    log_dry "qbittorrent: would trust ${subnet}, removing its separate login"
    return 0
  fi

  local out
  out="$(qbittorrent_set_preference \
    "{\\\"bypass_auth_subnet_whitelist_enabled\\\":true,\\\"bypass_auth_subnet_whitelist\\\":\\\"${subnet}\\\",\\\"bypass_local_auth\\\":true}")" \
    || true

  if [[ "$out" == "204 200" ]]; then
    log_success "qbittorrent: trusts ${subnet} — no second login behind the proxy"
  else
    log_warn "qbittorrent: could not update settings (login/set returned '${out}')."
    log_info "Set the subnet whitelist to ${subnet} by hand if you get a second login."
  fi
}

# ── qBittorrent save path ──────────────────────────────────────────
# Every *arr app and qBittorrent mount DOCKERSTORAGEDIR at the same
# container path, /data, specifically so their paths already match —
# see docs/architecture.md. Left at its own default, qBittorrent saves
# somewhere the arr apps do not recognise, and the usual workaround is
# a Remote Path Mapping in each arr app instead of fixing this. This
# sets the one thing that actually needs fixing; arr_api.py removes any
# stale mapping that was added as a workaround.
configure_qbittorrent_save_path() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx qbittorrent || {
    log_warn "qbittorrent is not running — skipping its save path."
    return 0
  }

  local current
  current="$(docker exec qbittorrent curl -s \
    http://127.0.0.1:8080/api/v2/app/preferences 2>/dev/null \
    | grep -o '"save_path":"[^"]*"' || true)"
  if [[ "$current" == '"save_path":"/data/torrents/"' ]]; then
    log_skip "qbittorrent: save path already /data/torrents/"
    return 0
  fi

  if [[ -z "${QBIT_PASS:-}" ]]; then
    log_warn "qbittorrent: no password available, cannot set its save path."
    log_info "Set 'Default Save Path' to /data/torrents/ under Tools > Options >"
    log_info "Downloads by hand, and remove any Remote Path Mapping in the arr apps."
    return 0
  fi

  if (( DRY_RUN )); then
    log_dry "qbittorrent: would set Default Save Path to /data/torrents/"
    return 0
  fi

  local out
  out="$(qbittorrent_set_preference '{\"save_path\":\"/data/torrents/\"}')" || true

  if [[ "$out" == "204 200" ]]; then
    log_success "qbittorrent: Default Save Path set to /data/torrents/"
  else
    log_warn "qbittorrent: could not set save path (login/set returned '${out}')."
    log_info "Set it by hand under Tools > Options > Downloads if this recurs."
  fi
}

main() {
  require_env_file
  require_cmd docker
  require_cmd python3 "Ubuntu Server ships python3 by default; install with: sudo apt-get install python3"

  printf '%s%s  media-suite configuration%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  (( DRY_RUN )) && log_warn "Dry run — nothing will be changed."

  log_step "Reading credentials"

  local app key found=0
  # Exported for arr_api.py. Passed via the environment rather than
  # argv so they never appear in `ps` output.
  for app in radarr sonarr lidarr prowlarr; do
    if key="$(read_api_key "$app")" && [[ -n "$key" ]]; then
      export "${app^^}_API_KEY=${key}"
      log_success "${app}: API key found"
      found=1
    else
      export "${app^^}_API_KEY="
      log_warn "${app}: no API key yet (has it started at least once?)"
    fi
  done

  if ! (( found )); then
    if (( DRY_RUN )); then
      log_warn "No API keys yet — nothing to preview. This is expected before the first real run."
      exit 0
    fi
    die "No API keys available. Start the stack and wait for the apps to initialise, then re-run."
  fi

  if QBIT_PASS="$(read_qbit_password)"; then
    export QBIT_PASS
    log_success "qbittorrent: temporary password recovered from container log"
  else
    export QBIT_PASS=""
    log_warn "qbittorrent: could not read the password from the log."
    log_info "If you have already changed it, set it by hand in each arr app's"
    log_info "download client settings after this finishes."
  fi
  export QBIT_USER="admin"

  local ip
  ip="$(env_get SERVER_IP || printf '127.0.0.1')"
  export GATEWAY="https://${ip}"
  export DRY_RUN VERBOSE

  log_step "Applying configuration via ${GATEWAY}"
  python3 "${REPO_ROOT}/scripts/lib/arr_api.py"

  log_step "qBittorrent access"
  configure_qbittorrent_access
  configure_qbittorrent_save_path
}

main "$@"
