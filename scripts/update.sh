#!/usr/bin/env bash
# ===================================================================
#  media-suite — updater
# ===================================================================
#  There is no Watchtower in this stack. Updates are a decision, taken
#  here, so a bad upstream release cannot land unannounced at 3am.
#
#  Image tags live in .env. To move to a new major version, edit the
#  tag there and run this. To roll back, put the old tag back and run
#  this again.
#
#    ./scripts/update.sh --check     # what would change
#    ./scripts/update.sh --backup    # tar configs first, then update
#    ./scripts/update.sh --service=radarr
# ===================================================================
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
trap 'on_error $LINENO' ERR

CHECK_ONLY=0
DO_BACKUP=0
SYNC_TAGS=0
NO_PRUNE=0
SERVICE=""

usage() {
  cat <<'USAGE'
Usage: ./scripts/update.sh [options]

Pulls current images for the pinned tags in .env and recreates any
container whose image changed. Containers that did not change are left
running untouched.

Options:
  --check            Report what would be updated, then exit.
  --sync-tags        Adopt the image tags recommended in .env.example.
                     Use after a git pull that bumps a pinned version.
  --backup           Tar application config directories first.
                     Media is never included — it is far too large.
  --service=NAME     Update only this service.
  --no-prune         Keep dangling images after updating.
  --dry-run          Print what would happen, change nothing.
  --verbose          Echo each command before running it.
  -h, --help         This text.
USAGE
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --check)       CHECK_ONLY=1 ;;
      --sync-tags)   SYNC_TAGS=1 ;;
      --backup)      DO_BACKUP=1 ;;
      --no-prune)    NO_PRUNE=1 ;;
      --service=*)   SERVICE="${1#*=}" ;;
      --dry-run)     DRY_RUN=1 ;;
      --verbose)     VERBOSE=1 ;;
      -h|--help)     usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done
}

# Pinned tags live in .env, but the repo's recommended tags live in
# .env.example. A `git pull` that bumps a tag there would otherwise
# never reach an existing install — surface the difference.
report_tag_drift() {
  local drift=0 key mine theirs
  while IFS= read -r key; do
    mine="$(env_get "$key" || printf '')"
    theirs="$(env_get "$key" "$ENV_EXAMPLE" || printf '')"
    [[ -n "$theirs" && -n "$mine" && "$mine" != "$theirs" ]] || continue
    (( drift )) || log_step "Recommended tag changes in .env.example"
    printf '    %-20s %s  ->  %s\n' "$key" "$mine" "$theirs"
    drift=1
  done < <(grep -oE '^[A-Z_]+_TAG' "$ENV_EXAMPLE" | sort -u)

  if (( drift )); then
    if (( SYNC_TAGS )); then
      while IFS= read -r key; do
        theirs="$(env_get "$key" "$ENV_EXAMPLE" || printf '')"
        [[ -n "$theirs" ]] && run env_set "$key" "$theirs"
      done < <(grep -oE '^[A-Z_]+_TAG' "$ENV_EXAMPLE" | sort -u)
      log_applied "Adopted the recommended tags"
    else
      log_info ""
      log_info "Adopt them with: ./scripts/update.sh --sync-tags"
    fi
  fi
}

check_updates() {
  log_step "Checking for updates"
  local -a svcs
  if [[ -n "$SERVICE" ]]; then svcs=("$SERVICE"); else
    mapfile -t svcs < <(compose config --services)
  fi

  local svc image local_digest changed=0
  for svc in "${svcs[@]}"; do
    image="$(compose config --format json 2>/dev/null \
      | python3 -c "import json,sys;print(json.load(sys.stdin)['services'].get('$svc',{}).get('image',''))" 2>/dev/null)" || image=""
    [[ -n "$image" ]] || continue
    local_digest="$(docker image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null || printf 'not-pulled')"
    printf '    %-14s %-46s %s\n' "$svc" "$image" \
      "$([[ "$local_digest" == "not-pulled" ]] && printf 'not present' || printf 'present')"
    changed=1
  done
  (( changed )) || log_warn "No services found — is .env correct?"

  log_info ""
  log_info "Pulling image metadata to compare against local copies..."
  if (( DRY_RUN )); then
    log_dry "compose pull --dry-run"
  else
    compose pull --dry-run 2>&1 | sed 's/^/    /' || true
  fi
}

backup_configs() {
  log_step "Backing up configuration"
  local conf dest stamp
  conf="$(env_get DOCKERCONFDIR)"
  stamp="$(date +%Y%m%d-%H%M%S)"
  dest="${REPO_ROOT}/backups/media-suite-config-${stamp}.tar.gz"

  run mkdir -p "${REPO_ROOT}/backups"
  log_info "Archiving ${conf} (databases only — no media)"
  # Transcode/cache dirs are large and regenerate themselves.
  run sudo tar -czf "$dest" \
    --exclude='*/transcode/*' --exclude='*/cache/*' \
    -C "$(dirname "$conf")" "$(basename "$conf")"
  (( DRY_RUN )) || log_success "Backup: ${dest} ($(du -h "$dest" 2>/dev/null | cut -f1))"
}

do_update() {
  log_step "Pulling images"
  if [[ -n "$SERVICE" ]]; then
    run compose pull "$SERVICE"
  else
    run compose pull
  fi

  log_step "Recreating changed containers"
  if [[ -n "$SERVICE" ]]; then
    run compose up -d "$SERVICE"
  else
    run compose up -d --remove-orphans
  fi
  log_applied "Containers are on the current images for their pinned tags"

  if (( NO_PRUNE )); then
    log_info "Keeping dangling images (--no-prune)"
  else
    log_step "Pruning superseded images"
    run docker image prune -f
  fi
}

main() {
  parse_args "$@"
  require_env_file
  require_cmd docker
  printf '%s%s  media-suite updater%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  (( DRY_RUN )) && log_warn "Dry run — nothing will be changed."

  report_tag_drift

  if (( CHECK_ONLY )); then
    check_updates
    printf '\n  Run without --check to apply.\n\n'
    exit 0
  fi

  (( DO_BACKUP )) && backup_configs
  do_update

  log_step "Status"
  compose ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || true
  printf '\n'
}

main "$@"
