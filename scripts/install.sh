#!/usr/bin/env bash
# ===================================================================
#  media-suite — installer
# ===================================================================
#  Idempotent: safe to re-run against an existing install. Every phase
#  checks whether its work is already done before acting.
#
#  Goal is a working stack from `./scripts/install.sh` with no
#  arguments and at most two answers (which media server, and the Plex
#  claim token if Plex was chosen). Everything else is detected.
#
#    ./scripts/install.sh
#    ./scripts/install.sh --media-app=jellyfin --non-interactive
#    ./scripts/install.sh --dry-run
# ===================================================================
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
trap 'on_error $LINENO' ERR
# Must return 0: an EXIT trap's status replaces the script's own exit
# code, so a bare failing test here would mask every non-zero exit.
cleanup() {
  [[ -n "$DRY_ENV_TMP" ]] && rm -f "$DRY_ENV_TMP"
  return 0
}
trap cleanup EXIT

MEDIA_APP=""
WITH_MONITORING=1
# Detected host values, kept in memory so --dry-run can report
# accurately without having written .env.
ENV_CREATED=0
# A dry run works against a throwaway copy of .env so every later
# phase sees realistic values instead of blank auto-detect fields.
DRY_ENV_TMP=""
DET_IP=""
DET_LAN=""
DET_TZ=""
DET_FQDN=""
SKIP_DOCKER=0
SKIP_CONFIGURE=0
FORCE_CERT=0
NEEDS_PROXY_RESTART=0
DATA_DIR=""
CONFIG_DIR=""

usage() {
  cat <<'USAGE'
Usage: ./scripts/install.sh [options]

Installs the media-suite stack. Re-runnable; existing configuration is
preserved and only missing pieces are created.

Options:
  --media-app=plex|jellyfin  Which media server to run. Prompted if omitted.
  --config-dir=PATH          Application config/databases. Must be block
                             storage (iSCSI or local disk), never NFS.
  --data-dir=PATH            Media library and downloads. NFS is fine.
  --with-portainer           Also deploy Portainer (container GUI).
  --no-monitoring            Skip Uptime Kuma.
  --skip-docker-install      Fail rather than install Docker if absent.
  --skip-configure           Do not auto-wire the arr apps afterwards.
  --force-cert               Regenerate the TLS certificate even if one exists.
  --non-interactive          Never prompt; use flags and detected values.
  --dry-run                  Print what would happen, change nothing.
  --verbose                  Echo each command before running it.
  -h, --help                 This text.

Exit codes:
  0  Success.
  2  Paused: you were added to the docker group and must start a new
     login session before the install can continue. Re-run afterwards;
     nothing is lost.
USAGE
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --media-app=*)        MEDIA_APP="${1#*=}" ;;
      --media-app)          MEDIA_APP="${2:-}"; shift ;;
      --config-dir=*)       CONFIG_DIR="${1#*=}" ;;
      --data-dir=*)         DATA_DIR="${1#*=}" ;;
      --with-portainer)     WITH_PORTAINER=1 ;;
      --no-monitoring)      WITH_MONITORING=0 ;;
      --skip-docker-install) SKIP_DOCKER=1 ;;
      --skip-configure)     SKIP_CONFIGURE=1 ;;
      --force-cert)         FORCE_CERT=1 ;;
      --non-interactive)    NON_INTERACTIVE=1 ;;
      --dry-run)            DRY_RUN=1 ;;
      --verbose)            VERBOSE=1 ;;
      -h|--help)            usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done

  if [[ -n "$MEDIA_APP" && "$MEDIA_APP" != "plex" && "$MEDIA_APP" != "jellyfin" ]]; then
    die "--media-app must be 'plex' or 'jellyfin', got '${MEDIA_APP}'"
  fi
}

# ── 1. Preflight ───────────────────────────────────────────────────

preflight() {
  log_step "Preflight checks"

  [[ $EUID -ne 0 ]] || die "Do not run as root. Run as your normal user; sudo is used where needed."

  require_cmd openssl "install with: sudo apt-get install openssl"
  require_cmd ip "part of iproute2"

  if (( DRY_RUN )); then
    log_info "sudo check skipped (dry run)"
  elif ! sudo -n true 2>/dev/null; then
    log_info "sudo access is required; you may be prompted for your password."
    sudo -v || die "sudo access is required."
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    local id_like name
    id_like="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
    name="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
    if [[ "$id_like" == *debian* || "$id_like" == *ubuntu* ]]; then
      log_success "OS: ${name}"
    else
      log_warn "OS '${name}' is not Debian/Ubuntu. Docker auto-install will be skipped."
      SKIP_DOCKER=1
    fi
  else
    log_warn "Cannot identify the OS; Docker auto-install will be skipped."
    SKIP_DOCKER=1
  fi

  local -a busy=()
  local p
  for p in 80 443 8443 8444; do
    if port_in_use "$p" && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx proxy; then
      busy+=("$p")
    fi
  done
  if (( ${#busy[@]} )); then
    log_warn "Ports already in use: ${busy[*]}"
    confirm "Continue anyway?" n || die "Free those ports and re-run."
  else
    log_success "Required ports are free"
  fi
}

# ── 2. Docker ──────────────────────────────────────────────────────

install_docker() {
  log_step "Docker Engine"

  if have_cmd docker && docker compose version >/dev/null 2>&1; then
    log_skip "Docker and the Compose plugin are present"
  elif (( SKIP_DOCKER )); then
    die "Docker is not installed and auto-install is disabled. Install Docker Engine and the Compose plugin, then re-run."
  else
    log_info "Installing Docker Engine from the official apt repository..."
    run sudo install -m 0755 -d /etc/apt/keyrings
    run sudo apt-get update -qq
    run sudo apt-get install -y -qq ca-certificates curl gnupg
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
      run sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
      run sudo chmod a+r /etc/apt/keyrings/docker.asc
    fi
    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
      local arch codename
      arch="$(dpkg --print-architecture)"
      codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
      run sudo tee /etc/apt/sources.list.d/docker.list >/dev/null <<<"deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable"
    fi
    run sudo apt-get update -qq
    run sudo apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    log_success "Docker Engine installed"
  fi

  local me; me="$(id -un)"
  if id -nG "$me" | tr ' ' '\n' | grep -qx docker; then
    log_skip "${me} is in the docker group"
  else
    run sudo usermod -aG docker "$me"
    log_warn "Added ${me} to the docker group (applies to new login sessions only)."
    NEEDS_RELOGIN=1
  fi
}

# ── 2b. Docker access ──────────────────────────────────────────────
#  Linux applies group membership only to NEW login sessions. If we
#  just added this user to the docker group, every command from here
#  on would fail with "permission denied" — so stop cleanly and say
#  so, rather than dying halfway through the deploy.

pause_for_relogin() {
  local me; me="$(id -un)"
  printf '\n%s%s  Install paused — one manual step needed%s\n\n' \
    "$C_BOLD" "$C_YELLOW" "$C_RESET"
  printf '  The Docker daemon is running, but this login session does not\n'
  printf '  have the %sdocker%s group applied — Linux grants group membership\n' \
    "$C_BOLD" "$C_RESET"
  printf '  only to sessions started after the change. Until you start a new\n'
  printf '  one, every Docker command fails with "permission denied".\n\n'
  printf '  %s is in the group; this shell just predates it.\n\n' "$me"
  printf '  %sLog out and back in, then run this again:%s\n\n' "$C_BOLD" "$C_RESET"
  printf '      %s./scripts/install.sh%s\n\n' "$C_CYAN" "$C_RESET"
  printf '  Nothing is lost. The installer is idempotent — it will skip\n'
  printf '  everything it has already done and carry on from here.\n\n'
  printf '  %sDo not want to log out?%s This runs it in a shell that already\n' \
    "$C_DIM" "$C_RESET"
  printf '  has the group applied:\n\n'
  printf '      %ssg docker -c "./scripts/install.sh"%s\n\n' "$C_CYAN" "$C_RESET"
  exit 2
}

verify_docker_access() {
  log_step "Docker access"

  if docker info >/dev/null 2>&1; then
    log_success "Docker is reachable as $(id -un)"
    return 0
  fi

  if (( DRY_RUN )); then
    log_dry "docker is not reachable yet — a real run would pause here"
    return 0
  fi

  # A stopped daemon is a different problem from group membership;
  # fixing it may be all that is needed.
  if have_cmd systemctl && ! systemctl is-active --quiet docker 2>/dev/null; then
    log_warn "The Docker daemon is not running."
    if confirm "Start and enable it now?" y; then
      run sudo systemctl enable --now docker
      sleep 3
      if docker info >/dev/null 2>&1; then
        log_success "Docker started"
        return 0
      fi
    fi
  fi

  # Daemon is up but we cannot reach it: group membership is the
  # overwhelmingly likely cause.
  if [[ -n "${NEEDS_RELOGIN:-}" ]] || ! id -nG | tr ' ' '\n' | grep -qx docker; then
    pause_for_relogin
  fi

  die "Cannot reach the Docker daemon. Check with: systemctl status docker"
}

# ── 3. Configuration ───────────────────────────────────────────────

choose_media_app() {
  [[ -n "$MEDIA_APP" ]] && return 0

  local existing
  if existing="$(active_media_app 2>/dev/null)"; then
    MEDIA_APP="$existing"
    log_skip "Media server already configured: ${MEDIA_APP}"
    return 0
  fi

  if (( NON_INTERACTIVE )); then
    MEDIA_APP="plex"
    log_info "Defaulting to Plex (--media-app not given)"
    return 0
  fi

  printf '\n    Which media server would you like?\n\n'
  printf '      1) Plex     — polished clients, Plex Pass for HW transcoding,\n'
  printf '                    account-linked, some features are cloud-dependent\n'
  printf '      2) Jellyfin — fully open source, no account, no paid tier,\n'
  printf '                    HW transcoding free, clients are rougher\n\n'
  local reply
  read -r -p "    Choice [1]: " reply || true
  case "${reply:-1}" in
    1|plex|Plex|PLEX)         MEDIA_APP="plex" ;;
    2|jellyfin|Jellyfin|JF)   MEDIA_APP="jellyfin" ;;
    *) die "Invalid choice: ${reply}" ;;
  esac
  log_success "Media server: ${MEDIA_APP}"
}

configure_env() {
  log_step "Configuration"

  if [[ ! -f "$ENV_FILE" ]]; then
    if (( DRY_RUN )); then
      log_dry "cp ${ENV_EXAMPLE} ${ENV_FILE}"
      DRY_ENV_TMP="$(mktemp -t media-suite-dryrun.XXXXXX)"
      cp "$ENV_EXAMPLE" "$DRY_ENV_TMP"
      ENV_FILE="$DRY_ENV_TMP"
      ENV_CREATED=1
    else
      cp "$ENV_EXAMPLE" "$ENV_FILE"
      chmod 600 "$ENV_FILE"
      ENV_CREATED=1
      log_success "Created .env from .env.example (mode 600)"
    fi
  else
    log_skip ".env exists — existing values will be kept"
  fi

  # Detection. env_set_default never overwrites an operator's value.
  DET_TZ="$(detect_timezone || printf 'UTC')"
  DET_IP="$(detect_server_ip || printf '')"
  DET_LAN="$(detect_lan_network || printf '')"
  DET_FQDN="$(detect_fqdn || printf 'media.home.arpa')"

  log_info "Detected from this host:"
  printf '      %-16s %s\n' "PUID/PGID" "$(id -u)/$(id -g)"
  printf '      %-16s %s\n' "Timezone" "$DET_TZ"
  printf '      %-16s %s\n' "Server IP" "${DET_IP:-<none>}"
  printf '      %-16s %s\n' "LAN network" "${DET_LAN:-<none>}"
  printf '      %-16s %s\n' "Hostname" "$DET_FQDN"

  (( DRY_RUN )) && log_dry "would write the above into .env"

  # On a brand new .env, detection is authoritative. On a re-run, the
  # operator's stored values win — env_set_default leaves them alone.
  local setter=env_set_default
  (( ENV_CREATED )) && setter=env_set

  "$setter" PUID "$(id -u)"
  "$setter" PGID "$(id -g)"
  "$setter" TZ "$DET_TZ"
  "$setter" DOMAIN_NAME "$DET_FQDN"
  [[ -n "$DET_IP" ]]  && "$setter" SERVER_IP "$DET_IP"
  [[ -n "$DET_LAN" ]] && "$setter" LAN_NETWORK "$DET_LAN"

  warn_on_address_drift

  [[ -n "$CONFIG_DIR" ]] && env_set DOCKERCONFDIR "$CONFIG_DIR"
  [[ -n "$DATA_DIR" ]]   && env_set DOCKERSTORAGEDIR "$DATA_DIR"

  # Profiles are always rewritten: they encode the flags given now.
  local profiles="$MEDIA_APP"
  (( WITH_MONITORING )) && profiles="${profiles},monitoring"
  env_set COMPOSE_PROFILES "$profiles"
  log_applied "Profiles: ${profiles}"

  # Advertise URLs depend on the detected address.
  local ip; ip="$(env_get SERVER_IP || printf '')"
  if [[ -n "$ip" ]]; then
    if [[ "$MEDIA_APP" == "plex" ]]; then
      env_set PLEX_ADVERTISE_URL "http://${ip}:32400"
    else
      env_set JELLYFIN_PUBLISHED_SERVER_URL "http://${ip}:8096"
    fi
  fi

  log_info "Config dir: $(env_get DOCKERCONFDIR)  (must be block storage)"
  log_info "Data dir:   $(env_get DOCKERSTORAGEDIR)"
}

# The stored address can fall out of step with reality — a DHCP lease
# change, or a .env carried over from another machine. Silently wrong
# here produces a certificate and advertise URL nobody can use.
warn_on_address_drift() {
  local stored
  stored="$(env_get SERVER_IP || printf '')"
  [[ -n "$DET_IP" && -n "$stored" && "$stored" != "$DET_IP" ]] || return 0

  log_warn "SERVER_IP in .env is ${stored}, but this host is on ${DET_IP}."
  if confirm "Update .env to ${DET_IP}?" y; then
    env_set SERVER_IP "$DET_IP"
    [[ -n "$DET_LAN" ]] && env_set LAN_NETWORK "$DET_LAN"
    log_success "SERVER_IP updated to ${DET_IP}"
  else
    log_warn "Keeping ${stored}. Certificates and advertise URLs will use it."
  fi
}

collect_plex_claim() {
  [[ "$MEDIA_APP" == "plex" ]] || return 0
  (( DRY_RUN )) && { log_dry "would prompt for the Plex claim token"; return 0; }

  if env_get PLEX_CLAIM_TOKEN >/dev/null 2>&1; then
    log_skip "Plex claim token already set"
    return 0
  fi
  if (( NON_INTERACTIVE )); then
    log_warn "No Plex claim token set. Plex will start unclaimed; link it manually afterwards."
    return 0
  fi

  printf '\n    Plex needs a claim token to link the server to your account.\n'
  printf '    Get one from %shttps://plex.tv/claim%s — it expires after 4 minutes.\n\n' \
    "$C_CYAN" "$C_RESET"
  local token
  read -r -p "    Claim token (blank to skip): " token || true
  if [[ -n "$token" ]]; then
    env_set PLEX_CLAIM_TOKEN "$token"
    log_success "Claim token saved"
  else
    log_warn "Skipped. Plex will start unclaimed; link it manually afterwards."
  fi
}

# ── 4. Directories ─────────────────────────────────────────────────

create_directories() {
  log_step "Directories"

  local conf data traefik puid pgid
  conf="$(env_get DOCKERCONFDIR)"   || die "DOCKERCONFDIR is not set in .env"
  data="$(env_get DOCKERSTORAGEDIR)" || die "DOCKERSTORAGEDIR is not set in .env"
  traefik="$(env_get TRAEFIK_DIR)"   || die "TRAEFIK_DIR is not set in .env"
  puid="$(env_get PUID)"             || die "PUID is not set in .env"
  pgid="$(env_get PGID)"             || die "PGID is not set in .env"

  local -a dirs=(
    "${traefik}/acme" "${traefik}/certificates"
    "${traefik}/config" "${traefik}/config/dynamic" "${traefik}/logs"
    "${conf}/radarr" "${conf}/sonarr" "${conf}/lidarr"
    "${conf}/prowlarr" "${conf}/qbittorrent" "${conf}/homarr"
  )
  if [[ "$MEDIA_APP" == "plex" ]]; then
    dirs+=("${conf}/plex/config" "${conf}/plex/transcode")
  else
    dirs+=("${conf}/jellyfin/config" "${conf}/jellyfin/cache")
  fi
  (( WITH_MONITORING )) && dirs+=("${conf}/uptime-kuma")

  local t
  for t in movies tv music; do
    dirs+=("${data}/media/${t}" "${data}/torrents/${t}")
  done

  run sudo mkdir -p "${dirs[@]}"
  run sudo chown -R "${puid}:${pgid}" "$conf" "$data" "$traefik"
  log_applied "${#dirs[@]} directories ready under ${conf}, ${data}, ${traefik}"
}

# ── 5. Secrets ─────────────────────────────────────────────────────

generate_secrets() {
  log_step "Secrets"

  if (( DRY_RUN )); then
    log_dry "would generate SECRET_ENCRYPTION_KEY if unset"
    return 0
  fi

  if env_get SECRET_ENCRYPTION_KEY >/dev/null 2>&1; then
    log_skip "SECRET_ENCRYPTION_KEY already set"
    return 0
  fi

  # Written straight into .env. Never echoed, never passed as an
  # argument, never logged.
  env_set SECRET_ENCRYPTION_KEY "$(openssl rand -hex 32)"
  log_success "Generated SECRET_ENCRYPTION_KEY (32 bytes, written to .env)"
}

# ── 6. TLS ─────────────────────────────────────────────────────────

# True when the certificate's SAN already lists the address we are
# about to advertise. Traefik serves whatever is on disk, so a stale
# SAN is a silent failure for every client.
cert_covers_current_address() {
  local crt="$1" ip san
  ip="$(env_get SERVER_IP || printf '')"
  [[ -n "$ip" ]] || return 0
  if [[ -r "$crt" ]]; then
    san="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null)" || return 1
  else
    san="$(sudo openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null)" || return 1
  fi
  [[ "$san" == *"IP Address:${ip}"* ]]
}

generate_certificates() {
  log_step "TLS certificate"

  local traefik crt key
  traefik="$(env_get TRAEFIK_DIR)"
  crt="${traefik}/certificates/cert.crt"
  key="${traefik}/certificates/cert.key"

  if (( DRY_RUN )); then
    log_dry "would generate a self-signed certificate at ${crt}"
    return 0
  fi

  if sudo test -f "$crt" && sudo test -f "$key"; then
    if (( FORCE_CERT )); then
      log_info "Regenerating certificate (--force-cert)"
      run sudo rm -f "$crt" "$key"
    elif cert_covers_current_address "$crt"; then
      log_skip "Certificate already present and covers this address"
      return 0
    else
      log_warn "The existing certificate does not cover $(env_get SERVER_IP)."
      log_info "Browsers and clients will reject it for that address."
      if confirm "Regenerate it?" y; then
        run sudo rm -f "$crt" "$key"
        NEEDS_PROXY_RESTART=1
      else
        log_warn "Keeping the existing certificate."
        return 0
      fi
    fi
  fi

  local cn days c st l o subject ip
  cn="$(env_get DOMAIN_NAME)"
  days="$(env_get CERT_VALIDITY_DAYS)"
  c="$(env_get CERT_COUNTRY)"; st="$(env_get CERT_STATE)"
  l="$(env_get CERT_LOCALITY)"; o="$(env_get CERT_ORG)"
  ip="$(env_get SERVER_IP || printf '')"
  subject="/C=${c}/ST=${st}/L=${l}/O=${o}/CN=${cn}"

  # SANs matter: browsers reject a certificate whose name does not
  # match, and this stack is normally reached by IP.
  local san="DNS:${cn},DNS:localhost"
  [[ -n "$ip" ]] && san="${san},IP:${ip}"

  sudo openssl req -x509 -newkey rsa:4096 -sha256 \
    -keyout "$key" -out "$crt" \
    -days "$days" -nodes -subj "$subject" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1 \
    || die "Certificate generation failed"

  run sudo chown "$(env_get PUID):$(env_get PGID)" "$crt" "$key"
  run sudo chmod 640 "$key"
  log_success "Self-signed certificate created (CN=${cn}, SAN=${san}, ${days} days)"
}

install_traefik_config() {
  log_step "Traefik configuration"

  local traefik; traefik="$(env_get TRAEFIK_DIR)"
  run sudo cp "${REPO_ROOT}/config/traefik/certificates.yml" \
    "${traefik}/config/certificates.yml"
  log_applied "Installed certificates.yml"

  if (( WITH_PORTAINER )); then
    local ip tmp
    if (( DRY_RUN )); then
      ip="${DET_IP:-127.0.0.1}"
    else
      ip="$(env_get SERVER_IP || printf '127.0.0.1')"
    fi
    if (( DRY_RUN )); then
      log_dry "would install portainer.yml with SERVER_IP=${ip}"
    else
      tmp="$(mktemp)"
      sed "s|__SERVER_IP__|${ip}|g" \
        "${REPO_ROOT}/config/traefik/dynamic/portainer.yml" >"$tmp"
      sudo cp "$tmp" "${traefik}/config/portainer.yml"
      rm -f "$tmp"
      log_applied "Installed portainer.yml (backend https://${ip}:9443)"
    fi
    run touch "${REPO_ROOT}/.portainer-enabled"
  else
    run sudo rm -f "${traefik}/config/portainer.yml"
  fi
}

# ── 7. Network & deploy ────────────────────────────────────────────

create_network() {
  log_step "Docker network"
  if docker network inspect traefik >/dev/null 2>&1; then
    log_skip "Network 'traefik' exists"
  else
    run docker network create traefik
    log_applied "Created network 'traefik'"
  fi
}

deploy_stack() {
  log_step "Deploying stack"
  run compose pull --quiet
  run compose up -d --remove-orphans
  log_applied "Stack deployed"

  # Traefik watches its config directory but not the certificate files
  # themselves, so a replaced certificate needs the proxy restarted.
  if (( NEEDS_PROXY_RESTART )); then
    run docker restart proxy
    log_applied "Restarted proxy to pick up the new certificate"
  fi
}

wait_for_health() {
  log_step "Waiting for services"
  (( DRY_RUN )) && { log_dry "would poll container health"; return 0; }

  local deadline=$(( SECONDS + 300 )) unhealthy
  while (( SECONDS < deadline )); do
    unhealthy="$(compose ps --format '{{.Name}} {{.Health}}' 2>/dev/null \
      | awk '$2 != "healthy" && $2 != "" {print $1}' || true)"
    [[ -z "$unhealthy" ]] && { log_success "All services healthy"; return 0; }
    sleep 10
  done

  log_warn "Timed out after 5 minutes. Still not healthy:"
  local svc
  while IFS= read -r svc; do
    [[ -n "$svc" ]] && printf '      %s\n' "$svc"
  done <<<"$unhealthy"
  log_info "Check with: docker compose -p $(env_get COMPOSE_PROJECT_NAME) logs -f"
}

configure_apps() {
  (( SKIP_CONFIGURE )) && { log_info "Skipping app cross-wiring (--skip-configure)"; return 0; }
  log_step "Cross-wiring applications"
  local -a args=()
  (( DRY_RUN )) && args+=(--dry-run)
  (( VERBOSE )) && args+=(--verbose)
  "${REPO_ROOT}/scripts/configure.sh" "${args[@]}" || \
    log_warn "Auto-configuration did not fully succeed. Re-run ./scripts/configure.sh once all services are up."
}

# ── 8. Summary ─────────────────────────────────────────────────────

print_summary() {
  local ip conf
  if (( DRY_RUN )); then
    ip="${DET_IP:-<server-ip>}"
  else
    ip="$(env_get SERVER_IP || printf '<server-ip>')"
  fi
  conf="$(env_get DOCKERCONFDIR)"

  printf '\n%s%s  media-suite is up%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
  printf '  %-14s %s\n' "Dashboard"  "https://${ip}/"
  printf '  %-14s %s\n' "Radarr"     "https://${ip}/movies"
  printf '  %-14s %s\n' "Sonarr"     "https://${ip}/tv"
  printf '  %-14s %s\n' "Lidarr"     "https://${ip}/music"
  printf '  %-14s %s\n' "Prowlarr"   "https://${ip}/idx"
  printf '  %-14s %s\n' "qBittorrent" "https://${ip}/download"
  printf '  %-14s %s\n' "Traefik"    "https://${ip}/admin"
  if [[ "$MEDIA_APP" == "plex" ]]; then
    printf '  %-14s %s\n' "Plex"      "https://${ip}:8443/  (clients: http://${ip}:32400)"
  else
    printf '  %-14s %s\n' "Jellyfin"  "https://${ip}:8443/  (clients: http://${ip}:8096)"
  fi
  (( WITH_MONITORING )) && printf '  %-14s %s\n' "Uptime Kuma" "https://${ip}:8444/"
  (( WITH_PORTAINER ))  && printf '  %-14s %s\n' "Portainer"   "https://${ip}/docker"

  printf '\n  %sNotes%s\n' "$C_BOLD" "$C_RESET"
  printf '    · The certificate is self-signed; your browser will warn once.\n'
  printf '    · qBittorrent password: docker logs qbittorrent 2>&1 | grep -i password\n'
  (( WITH_MONITORING )) && \
  printf '    · Uptime Kuma monitors are not auto-created — see docs/monitoring.md\n'
  [[ -n "${NEEDS_RELOGIN:-}" ]] && \
  printf '    %s· Log out and back in for docker group membership to apply.%s\n' "$C_YELLOW" "$C_RESET"
  printf '\n  Next: docs/troubleshooting.md if anything looks wrong.\n\n'
}

# ── Main ───────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  printf '%s%s  media-suite installer%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  (( DRY_RUN )) && log_warn "Dry run — nothing will be changed."

  preflight
  install_docker
  verify_docker_access
  choose_media_app
  configure_env
  collect_plex_claim
  create_directories
  generate_secrets
  generate_certificates
  install_traefik_config
  create_network
  deploy_stack
  wait_for_health
  configure_apps
  print_summary
}

main "$@"
