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
}

main "$@"
