#!/usr/bin/env bash
# ===================================================================
#  media-suite — uninstaller
# ===================================================================
#  Default is the safe thing: stop and remove containers, leave every
#  byte of data alone. Destroying data always takes an explicit flag,
#  and destroying MEDIA takes a typed confirmation on top of that.
#
#    ./scripts/remove.sh              # containers only
#    ./scripts/remove.sh --purge      # + app configs and databases
#    ./scripts/remove.sh --purge-media  # + the media library itself
# ===================================================================
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
trap 'on_error $LINENO' ERR

PURGE=0
PURGE_MEDIA=0
KEEP_IMAGES=0
REMOVE_NETWORK=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/remove.sh [options]

Removes the media-suite stack. By default only containers and the
project network go; all data is preserved.

Options:
  --purge            Also delete application configs and databases
                     (DOCKERCONFDIR) and the Portainer volume.
  --purge-media      Also delete the media library and downloads
                     (DOCKERSTORAGEDIR). Requires typing the path to
                     confirm. Never implied by --purge.
  --keep-images      Do not remove the stack's images.
  --remove-network   Also remove the shared external 'traefik' network.
  --non-interactive  Skip confirmations. --purge-media still needs its
                     own flag, but will not prompt.
  --dry-run          Print what would happen, change nothing.
  --verbose          Echo each command before running it.
  -h, --help         This text.
USAGE
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --purge)           PURGE=1 ;;
      --purge-media)     PURGE_MEDIA=1; PURGE=1 ;;
      --keep-images)     KEEP_IMAGES=1 ;;
      --remove-network)  REMOVE_NETWORK=1 ;;
      --non-interactive) NON_INTERACTIVE=1 ;;
      --dry-run)         DRY_RUN=1 ;;
      --verbose)         VERBOSE=1 ;;
      -h|--help)         usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
}

show_plan() {
  local conf data
  conf="$(env_get DOCKERCONFDIR || printf '<unknown>')"
  data="$(env_get DOCKERSTORAGEDIR || printf '<unknown>')"

  printf '\n  %sThis will remove:%s\n' "$C_BOLD" "$C_RESET"
  printf '    · all media-suite containers and the project network\n'
  (( KEEP_IMAGES )) || printf '    · the images those containers used\n'
  (( REMOVE_NETWORK )) && printf '    · the shared external network '"'"'traefik'"'"'\n'
  if (( PURGE )); then
    printf '    %s· %s  (app configs and databases)%s\n' "$C_YELLOW" "$conf" "$C_RESET"
    printf '    %s· the portainer_data volume%s\n' "$C_YELLOW" "$C_RESET"
  fi
  if (( PURGE_MEDIA )); then
    printf '    %s%s· %s  (YOUR ENTIRE MEDIA LIBRARY)%s\n' "$C_BOLD" "$C_RED" "$data" "$C_RESET"
  fi

  printf '\n  %sThis will be kept:%s\n' "$C_BOLD" "$C_RESET"
  (( PURGE ))       || printf '    · %s  (app configs and databases)\n' "$conf"
  (( PURGE_MEDIA )) || printf '    · %s  (media library and downloads)\n' "$data"
  printf '    · .env\n'
  printf '\n'
}

confirm_media_destruction() {
  (( PURGE_MEDIA )) || return 0
  local data typed
  data="$(env_get DOCKERSTORAGEDIR)"

  (( NON_INTERACTIVE )) && { log_warn "--non-interactive: deleting ${data} without prompting"; return 0; }

  printf '  %s%sAbout to permanently delete your media library.%s\n' "$C_BOLD" "$C_RED" "$C_RESET"
  printf '  Type the path to confirm, anything else aborts.\n\n'
  read -r -p "    ${data} > " typed || true
  [[ "$typed" == "$data" ]] || die "Path did not match. Nothing was deleted."
}

remove_stack() {
  log_step "Removing containers"
  local -a args=(down --remove-orphans)
  (( KEEP_IMAGES )) || args+=(--rmi all)
  (( PURGE ))       && args+=(--volumes)
  # Bring down every profile, not just the active one, so a stack
  # installed with Plex is fully removed after switching to Jellyfin.
  run compose --profile plex --profile jellyfin --profile monitoring "${args[@]}"
  log_applied "Containers removed"
}

purge_data() {
  (( PURGE )) || return 0
  log_step "Removing application data"
  local conf; conf="$(env_get DOCKERCONFDIR)"
  run sudo rm -rf -- "$conf"
  log_applied "Deleted ${conf}"
}

purge_media() {
  (( PURGE_MEDIA )) || return 0
  log_step "Removing media library"
  local data; data="$(env_get DOCKERSTORAGEDIR)"
  run sudo rm -rf -- "$data"
  log_applied "Deleted ${data}"
}

remove_network() {
  (( REMOVE_NETWORK )) || return 0
  log_step "Removing network"
  if docker network inspect traefik >/dev/null 2>&1; then
    run docker network rm traefik || \
      log_warn "Could not remove 'traefik' — another stack is probably still attached."
  else
    log_skip "Network 'traefik' does not exist"
  fi
}

main() {
  parse_args "$@"
  require_env_file
  require_cmd docker
  printf '%s%s  media-suite uninstaller%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  (( DRY_RUN )) && log_warn "Dry run — nothing will be changed."

  show_plan
  if ! (( DRY_RUN )); then
    confirm "Proceed?" n || die "Aborted. Nothing was changed."
    confirm_media_destruction
  fi

  remove_stack
  purge_data
  purge_media
  remove_network

  printf '\n  %sDone.%s\n' "$C_GREEN" "$C_RESET"
  (( PURGE )) || printf '  Your data is still at %s\n' "$(env_get DOCKERCONFDIR)"
  printf '  Reinstall any time with ./scripts/install.sh\n\n'
}

main "$@"
