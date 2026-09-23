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
AUTH_MODE=""
GPU_TYPE=""
SSO_PASSWORD_FILE=""
DOCKERCONFDIR_CACHED=""
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
WITH_SMB=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/install.sh [options]

Installs the media-suite stack. Re-runnable; existing configuration is
preserved and only missing pieces are created.

Options:
  --media-app=plex|jellyfin  Which media server to run. Prompted if omitted.
  --auth=sso|none            sso  : one login (Tinyauth) for the whole admin
                                    surface, including the Traefik dashboard.
                             none : no login on the LAN for the arr apps and
                                    qBittorrent. Prompted if omitted.
  --gpu=vaapi|nvidia|none    Hardware transcode backend for Jellyfin/Plex.
                             Auto-detected if omitted: vaapi if /dev/dri
                             exists, else nvidia if nvidia-smi works, else
                             none. nvidia additionally installs
                             nvidia-container-toolkit if it's missing.
  --config-dir=PATH          Application config/databases. Must be block
                             storage (iSCSI or local disk), never NFS.
  --data-dir=PATH            Media library and downloads. NFS is fine.
  --with-portainer           Also deploy Portainer (container GUI).
  --smb                      Share the data directory over SMB, native on
                             the host. See docs/file-sharing.md.
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
      --auth=*)             AUTH_MODE="${1#*=}" ;;
      --gpu=*)              GPU_TYPE="${1#*=}" ;;
      --media-app)          MEDIA_APP="${2:-}"; shift ;;
      --config-dir=*)       CONFIG_DIR="${1#*=}" ;;
      --data-dir=*)         DATA_DIR="${1#*=}" ;;
      --with-portainer)     WITH_PORTAINER=1 ;;
      --smb)                WITH_SMB=1 ;;
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
  if [[ -n "$AUTH_MODE" && "$AUTH_MODE" != "sso" && "$AUTH_MODE" != "none" ]]; then
    die "--auth must be 'sso' or 'none', got '${AUTH_MODE}'"
  fi
  if [[ -n "$GPU_TYPE" && "$GPU_TYPE" != "vaapi" && "$GPU_TYPE" != "nvidia" && "$GPU_TYPE" != "none" ]]; then
    die "--gpu must be 'vaapi', 'nvidia' or 'none', got '${GPU_TYPE}'"
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
  for p in 80 443 8443; do
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

# ── 4b. GPU acceleration ─────────────────────────────────────────────
#  Not a persisted user choice like MEDIA_APP/AUTH_MODE — this tracks a
#  hardware fact, so it re-evaluates on every run rather than skipping
#  when "already configured". Re-plugging (or removing) a GPU is picked
#  up on the next install.sh run with no flag needed.
detect_gpu() {
  log_step "GPU acceleration"

  if [[ -n "$GPU_TYPE" ]]; then
    log_info "GPU backend forced: ${GPU_TYPE}"
  elif vaapi_render_node >/dev/null; then
    GPU_TYPE="vaapi"
  elif have_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    GPU_TYPE="nvidia"
  else
    GPU_TYPE="none"
  fi

  case "$GPU_TYPE" in
    vaapi)  configure_vaapi ;;
    nvidia) configure_nvidia ;;
    none)
      run rm -f "${REPO_ROOT}/.gpu-vaapi-enabled" "${REPO_ROOT}/.gpu-nvidia-enabled"
      log_skip "No GPU detected"
      ;;
  esac
}

# Prints the first /dev/dri/renderD* node backed by Intel (i915, PCI
# vendor 0x8086) or AMD (amdgpu, 0x1002), or fails if none exists.
#
# Existence of a render node alone is NOT proof of VAAPI: Nvidia's own
# proprietary driver registers a DRM render node too (nvidia_drm), and
# it shows up at the same /dev/dri/renderD128 path an Intel/AMD node
# would use. Mesa's VAAPI backends (iHD, radeonsi) cannot open an
# Nvidia-owned node — treating "a render node exists" as "VAAPI is
# available" reports vaapi on an Nvidia-only box and Jellyfin fails at
# transcode time instead of falling through to the nvidia branch,
# which is the backend that actually works there. Checking the PCI
# vendor via sysfs (pure filesystem read, no lspci) is what tells them
# apart.
vaapi_render_node() {
  local node vendor
  for node in /dev/dri/renderD*; do
    [[ -e "$node" ]] || continue
    vendor="$(cat "/sys/class/drm/$(basename "$node")/device/vendor" 2>/dev/null)"
    case "$vendor" in
      0x8086|0x1002) printf '%s' "$node"; return 0 ;;
    esac
  done
  return 1
}

# VAAPI covers both Intel (i915) and AMD (amdgpu) — both expose the same
# device node pattern, so there is no vendor branch here beyond the
# Nvidia exclusion in vaapi_render_node.
configure_vaapi() {
  local node
  node="$(vaapi_render_node)" || die "--gpu=vaapi was forced but no Intel/AMD render node was found under /dev/dri (an Nvidia-only render node doesn't count — see vaapi_render_node)."
  local gid
  gid="$(stat -c '%g' "$node")"
  env_set GPU_RENDER_GID "$gid"
  run touch "${REPO_ROOT}/.gpu-vaapi-enabled"
  run rm -f "${REPO_ROOT}/.gpu-nvidia-enabled"
  log_applied "GPU acceleration: VAAPI (${node}, render group ${gid})"
}

# Only auto-installs the userspace toolkit that bridges an ALREADY
# INSTALLED host Nvidia driver into containers — this never touches
# the GPU driver itself, the same boundary install_docker() draws
# around not installing Docker's own kernel dependencies.
configure_nvidia() {
  have_cmd nvidia-smi || die "--gpu=nvidia was forced but nvidia-smi is not available on this host. Install the Nvidia driver first."
  nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is present but failed to run. Check the Nvidia driver installation."

  if have_cmd nvidia-ctk; then
    log_skip "nvidia-container-toolkit is already installed"
  else
    log_info "Installing nvidia-container-toolkit..."
    run sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/nvidia-container-toolkit.gpg ]]; then
      run bash -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor | sudo tee /etc/apt/keyrings/nvidia-container-toolkit.gpg >/dev/null'
    fi
    if [[ ! -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]]; then
      run bash -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#g" \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null'
    fi
    run sudo apt-get update -qq
    run sudo apt-get install -y -qq nvidia-container-toolkit
    run sudo nvidia-ctk runtime configure --runtime=docker
    run sudo systemctl restart docker
    log_success "nvidia-container-toolkit installed and configured"
  fi

  run touch "${REPO_ROOT}/.gpu-nvidia-enabled"
  run rm -f "${REPO_ROOT}/.gpu-vaapi-enabled"
  log_applied "GPU acceleration: NVENC (Nvidia)"
}

# Adds any setting .env.example defines that .env does not, using the
# example's value. Auto-detected fields are blank there, so detection
# below fills them in as it would on a fresh install. This is what
# makes an existing install survive a repo upgrade that adds settings.
sync_env_schema() {
  # The list is materialised BEFORE any write. env_set rewrites .env in
  # place, and reading the missing-key list lazily from a process
  # substitution would have it grepping a half-written file — which
  # reports keys as missing that are merely mid-rewrite, and then
  # clobbers their values with the example defaults.
  local -a missing=()
  mapfile -t missing < <(env_missing_keys)
  (( ${#missing[@]} )) || return 0

  log_info "New settings introduced by a repo update:"
  local key
  for key in "${missing[@]}"; do
    printf '      %s\n' "$key"
    env_set "$key" "$(env_get "$key" "$ENV_EXAMPLE" 2>/dev/null || printf '')"
  done
  log_applied "Added ${#missing[@]} new setting(s) from .env.example"
  return 0
}

choose_auth_mode() {
  [[ -n "$AUTH_MODE" ]] && return 0

  if has_profile sso 2>/dev/null; then
    AUTH_MODE="sso"; log_skip "Authentication already configured: sso"; return 0
  fi
  if [[ -f "$ENV_FILE" ]] && env_get COMPOSE_PROFILES >/dev/null 2>&1; then
    AUTH_MODE="none"; log_skip "Authentication already configured: none"; return 0
  fi
  if (( NON_INTERACTIVE )); then
    AUTH_MODE="none"; log_info "Defaulting to no login (--auth not given)"; return 0
  fi

  printf '\n    How would you like to handle logins?\n\n'
  printf '      1) None           — no login on the LAN for the arr apps and\n'
  printf '                          qBittorrent. Nothing extra to run, and no\n'
  printf '                          hostname needed. Anything that can reach\n'
  printf '                          this box controls your downloads and library.\n'
  printf '      2) Single sign-on — one account covers the dashboard, all four\n'
  printf '                          arr apps, qBittorrent, Portainer and the\n'
  printf '                          Traefik dashboard. Adds one 46 MB container,\n'
  printf '                          and needs a hostname (not an IP) that your\n'
  printf '                          devices can resolve.\n\n'
  printf '    Either way Homarr and the media server keep their own accounts —\n'
  printf '    neither option can remove those.\n\n'
  local reply
  read -r -p "    Choice [1]: " reply || true
  case "${reply:-1}" in
    1|none|None) AUTH_MODE="none" ;;
    2|sso|SSO)   AUTH_MODE="sso" ;;
    *) die "Invalid choice: ${reply}" ;;
  esac
  log_success "Authentication: ${AUTH_MODE}"
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

  sync_env_schema

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
  [[ "$AUTH_MODE" == "sso" ]] && profiles="${profiles},sso"
  env_set COMPOSE_PROFILES "$profiles"
  log_applied "Profiles: ${profiles}"

  # SMB is a host-level feature, not a compose profile — but it still
  # needs to persist across re-runs the same way, or a bare re-run
  # without --smb would look like a request to remove it.
  if (( WITH_SMB )); then
    env_set SMB_SHARE "true"
  else
    env_get SMB_SHARE >/dev/null 2>&1 || env_set SMB_SHARE "false"
  fi
  WITH_SMB=0; [[ "$(env_get SMB_SHARE)" == "true" ]] && WITH_SMB=1

  # Advertise URLs depend on the detected address.
  local ip; ip="$(env_get SERVER_IP || printf '')"
  if [[ -n "$ip" ]]; then
    if [[ "$MEDIA_APP" == "plex" ]]; then
      env_set PLEX_ADVERTISE_URL "http://${ip}:32400"
    else
      env_set JELLYFIN_PUBLISHED_SERVER_URL "http://${ip}:8096"
    fi
  fi

  DOCKERCONFDIR_CACHED="$(env_get DOCKERCONFDIR)"
  log_info "Config dir: ${DOCKERCONFDIR_CACHED}  (must be block storage)"
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
    "${conf}/prowlarr" "${conf}/qbittorrent" "${conf}/homarr" "${conf}/seerr"
  )
  if [[ "$MEDIA_APP" == "plex" ]]; then
    dirs+=("${conf}/plex/config" "${conf}/plex/transcode")
  else
    dirs+=("${conf}/jellyfin/config" "${conf}/jellyfin/cache")
  fi
  [[ "$AUTH_MODE" == "sso" ]] && dirs+=("${conf}/tinyauth")

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
  local crt="$1" ip host san
  ip="$(env_get SERVER_IP || printf '')"
  host="$(env_get DOMAIN_NAME || printf '')"
  [[ -n "$ip" || -n "$host" ]] || return 0
  if [[ -r "$crt" ]]; then
    san="$(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null)" || return 1
  else
    san="$(sudo openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null)" || return 1
  fi
  # Both matter. Switching to SSO changes DOMAIN_NAME, and a certificate
  # still naming the old host is rejected for the new one — checking
  # only the IP would let that through silently.
  [[ -z "$ip"   || "$san" == *"IP Address:${ip}"* ]] || return 1
  [[ -z "$host" || "$san" == *"DNS:${host}"* ]]      || return 1
  return 0
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
      log_warn "The certificate does not cover $(env_get DOMAIN_NAME) / $(env_get SERVER_IP)."
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

# ── 6b. SSO credentials ────────────────────────────────────────────

# Tinyauth reads its user list and cookie secret from FILES, not the
# environment: a bcrypt hash is full of $ that Compose would try to
# interpolate, and secrets in the environment show up in
# `docker inspect`. Both files are written here, mode 600, and the
# password itself is never echoed, logged, or stored in plaintext.
# Tinyauth v5 will not accept just any host in its app URL. It
# refuses IP addresses, single-label names, and public-suffix domains
# — which includes home.arpa, the obvious choice for a homelab. A bad
# value surfaces as a cryptic bootstrap failure, so it is checked here
# instead.
valid_sso_host() {
  local h="$1"
  [[ -n "$h" ]] || return 1
  [[ "$h" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 1   # IP address
  [[ "$h" == *.* ]] || return 1                             # single label
  case "$h" in
    home.arpa|*.home.arpa) return 1 ;;                      # public suffix
  esac
  return 0
}

# A .local name is advertised by an mDNS responder rather than a DNS
# server, so <hostname>.local resolves for macOS, Windows and Linux
# clients with nothing configured anywhere. That makes it far and away
# the least painful way to satisfy Tinyauth's hostname requirement on
# a network with no local DNS.
ensure_mdns() {
  local host="$1"
  [[ "$host" == *.local ]] || return 0

  if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    log_success "mDNS responder running — ${host} resolves with no DNS setup"
    return 0
  fi

  if have_cmd avahi-daemon; then
    log_warn "avahi-daemon is installed but not running; ${host} will not resolve."
    if confirm "Start and enable it?" y; then
      run sudo systemctl enable --now avahi-daemon
      log_applied "mDNS responder started"
    fi
    return 0
  fi

  log_warn "No mDNS responder installed, so ${host} will not resolve for clients."
  if confirm "Install avahi-daemon now?" y; then
    run sudo apt-get install -y -qq avahi-daemon libnss-mdns
    run sudo systemctl enable --now avahi-daemon
    log_applied "mDNS responder installed and started"
  else
    log_warn "Add a DNS entry for ${host} yourself, or SSO will be unreachable."
  fi
}

# Picks the host the login page will live on, and stores it. Only
# called when SSO is selected.
configure_sso_host() {
  [[ "$AUTH_MODE" == "sso" ]] || return 0

  local host existing
  existing="$(env_get TINYAUTH_APP_URL 2>/dev/null || printf '')"
  if [[ -n "$existing" ]]; then
    host="${existing#https://}"; host="${host%%:*}"
    if valid_sso_host "$host"; then
      log_skip "SSO hostname: ${host}"
      return 0
    fi
    log_warn "Stored SSO hostname '${host}' is not usable."
  fi

  host="$(env_get DOMAIN_NAME 2>/dev/null || printf '')"
  if ! valid_sso_host "$host"; then
    log_warn "Single sign-on needs a hostname, and '${host:-<unset>}' will not do."
    log_info "Tinyauth refuses IP addresses, single-label names, and anything"
    log_info "under home.arpa. It must be a dotted name your devices can"
    log_info "resolve to this machine — for example media.lan."
    if (( DRY_RUN )); then
      log_dry "a real run would stop here until a usable hostname is set"
      return 0
    fi
    if (( NON_INTERACTIVE )); then
      die "Set DOMAIN_NAME to a resolvable dotted hostname, or install with --auth=none."
    fi
    # <hostname>.local is advertised automatically by mDNS, so it needs
    # no DNS entry anywhere. Offer that first.
    local suggestion
    suggestion="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    suggestion="${suggestion:-media}.local"
    printf '\n    %s is suggested: a .local name is answered by mDNS, so it\n' "$suggestion"
    printf '    resolves on macOS, Windows and Linux with nothing to configure.\n\n'
    host="$(ask 'Hostname for the login page' "$suggestion")"
    valid_sso_host "$host" || die "'${host}' is not usable as an SSO hostname."
    env_set DOMAIN_NAME "$host"

    if [[ "$host" != *.local ]]; then
      log_warn "Point ${host} at $(env_get SERVER_IP) in your router or hosts file,"
      log_warn "or the login page will not resolve for clients."
    elif [[ "$host" != "$suggestion" ]]; then
      log_warn "mDNS advertises this machine as '${suggestion}', not '${host}'."
      log_warn "They must match, or change the system hostname to suit."
    fi
  fi

  ensure_mdns "$host"
  env_set TINYAUTH_APP_URL "https://${host}:8445"
  log_success "SSO hostname: ${host}"
}

configure_sso() {
  [[ "$AUTH_MODE" == "sso" ]] || return 0
  log_step "Single sign-on"

  local dir; dir="${DOCKERCONFDIR_CACHED}/tinyauth"

  if (( DRY_RUN )); then
    log_dry "would create an admin account and write ${dir}/{users,secret}"
    return 0
  fi

  run sudo mkdir -p "$dir"
  run sudo chown "$(env_get PUID):$(env_get PGID)" "$dir"

  if sudo test -s "${dir}/users" && sudo test -s "${dir}/secret"; then
    log_skip "SSO credentials already exist"
    return 0
  fi

  # Cookie secret: tinyauth requires exactly 32 characters.
  sudo tee "${dir}/secret" >/dev/null <<<"$(openssl rand -hex 16)"
  run sudo chmod 600 "${dir}/secret"
  log_applied "Generated cookie secret (32 chars)"

  local password generated=0
  if (( NON_INTERACTIVE )); then
    password="$(openssl rand -base64 18)"
    generated=1
  else
    local confirm_pw
    printf '\n    Create the login you will use for the whole stack.\n\n'
    read -r -s -p "    Password for 'admin' (blank to generate one): " password || true
    printf '\n'
    if [[ -z "$password" ]]; then
      password="$(openssl rand -base64 18)"
      generated=1
    else
      read -r -s -p "    Confirm: " confirm_pw || true
      printf '\n'
      [[ "$password" == "$confirm_pw" ]] || die "Passwords did not match."
    fi
  fi

  # tinyauth's own CLI does the bcrypt hashing. Its output is filtered
  # to the user:hash line and written straight to the file — nothing
  # reaches the terminal.
  # v5 prints a human-readable block rather than a log line; the
  # usable value is the one after TINYAUTH_AUTH_USERS=.
  local users_line
  users_line="$(docker run --rm "ghcr.io/tinyauthapp/tinyauth:$(env_get TINYAUTH_TAG)" \
      user create --username admin --password "$password" 2>&1 \
    | sed -E 's/\x1b\[[0-9;]*m//g' \
    | sed -nE 's/^TINYAUTH_AUTH_USERS=(.+)$/\1/p' | tr -d '\r\n')"

  [[ "$users_line" == admin:* ]] || die "Could not create the SSO user."
  sudo tee "${dir}/users" >/dev/null <<<"$users_line"
  run sudo chmod 600 "${dir}/users"
  run sudo chown -R "$(env_get PUID):$(env_get PGID)" "$dir"
  log_applied "Created SSO account 'admin'"

  # v5 creates tinyauth.db here on first start, so the directory has to
  # stay writable by the container.
  if (( generated )); then
    # The password is written to a file rather than printed, so it does
    # not end up in scrollback or a terminal log.
    local pwfile="${dir}/initial-password"
    sudo tee "$pwfile" >/dev/null <<<"$password"
    run sudo chmod 600 "$pwfile"
    run sudo chown "$(env_get PUID):$(env_get PGID)" "$pwfile"
    SSO_PASSWORD_FILE="$pwfile"
    log_warn "A password was generated. Read it once, then delete the file:"
    log_info "  cat ${pwfile} && rm ${pwfile}"
  fi

  # The SMB share (if requested) reuses this exact plaintext, captured
  # here before it is discarded. This only fires on a FRESH account —
  # see configure_smb_share for the fallback when Tinyauth's account
  # already existed and the plaintext is gone.
  if [[ "$WITH_SMB" == "1" ]]; then
    local smb_user; smb_user="$(resolve_smb_user)"
    [[ -n "$smb_user" ]] && ensure_smb_password "$smb_user" "$password"
  fi
  unset password
}

# ── 6c. SMB share ──────────────────────────────────────────────────
#
# Native on the host, not a container: DOCKERSTORAGEDIR is a bind
# mount, so the files already live at a real host path, and Windows
# Network Browser visibility needs genuine LAN broadcast that Docker's
# bridge network does not pass through cleanly. See docs/file-sharing.md.

# Resolves the Unix account PUID/PGID already point at — the same one
# every container writes files as. Samba operates as this account
# rather than fighting it with force user/force group, so ownership
# over SMB matches what the containers already produce.
resolve_smb_user() {
  local puid; puid="$(env_get PUID)"
  getent passwd "$puid" 2>/dev/null | cut -d: -f1
}

smb_user_has_password() {
  sudo pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$1"
}

# ensure_smb_password UNIX_USER [PLAINTEXT] — sets UNIX_USER's Samba
# password to PLAINTEXT, or generates one if none is given (the case
# where Tinyauth's own credentials already existed before --smb was
# added, so its plaintext is gone). Idempotent: does nothing if a
# Samba password is already set.
ensure_smb_password() {
  local unix_user="$1" password="${2:-}" generated=0
  smb_user_has_password "$unix_user" && {
    log_skip "Samba password already set for ${unix_user}"
    return 0
  }
  (( DRY_RUN )) && { log_dry "would set the Samba password for ${unix_user}"; return 0; }

  if [[ -z "$password" ]]; then
    password="$(openssl rand -base64 18)"
    generated=1
  fi
  if ! printf '%s\n%s\n' "$password" "$password" \
      | sudo smbpasswd -s -a "$unix_user" >/dev/null 2>&1; then
    log_warn "Could not set the Samba password for ${unix_user}."
    unset password
    return 1
  fi
  log_applied "Samba password set for ${unix_user} (SMB login: admin)"

  if (( generated )); then
    local dir="${DOCKERCONFDIR_CACHED}/tinyauth" pwfile
    run sudo mkdir -p "$dir"
    pwfile="${dir}/initial-smb-password"
    sudo tee "$pwfile" >/dev/null <<<"$password"
    run sudo chmod 600 "$pwfile"
    run sudo chown "$(env_get PUID):$(env_get PGID)" "$pwfile"
    log_warn "Tinyauth's password already existed, so it could not be reused for SMB."
    log_warn "A separate SMB password was generated. Read it once, then delete the file:"
    log_info "  cat ${pwfile} && rm ${pwfile}"
  fi
  unset password
}

# Split from configure_smb_share and called earlier in main(), before
# configure_sso: ensure_smb_password (called from inside configure_sso,
# to capture Tinyauth's plaintext before it is discarded) needs the
# `smbpasswd` binary to already exist.
install_smb_packages() {
  [[ "$WITH_SMB" == "1" ]] || return 0
  log_step "SMB packages"

  if (( DRY_RUN )); then
    log_dry "would install samba and wsdd-server"
    return 0
  fi

  # dpkg -s, not have_cmd: smbd/wsdd live under /usr/sbin or /usr/bin,
  # neither reliably on a non-root invoking user's PATH, and — the
  # actual bug this replaced — the bare `wsdd` package ships only a
  # CLI tool with no systemd integration at all on newer Ubuntu
  # releases (verified on 26.04/resolute: wsdd's own man page is
  # section 1, a user command, not section 8). The systemd-managed
  # daemon, unit `wsdd-server.service`, is a SEPARATE package,
  # `wsdd-server`, which depends on `wsdd` for the binary. Installing
  # bare `wsdd` and asking systemd to enable "wsdd" both silently
  # target the wrong thing; `have_cmd wsdd` would also wrongly report
  # "already installed" once the CLI-only package's binary exists,
  # even with wsdd-server absent.
  if dpkg -s samba wsdd-server >/dev/null 2>&1; then
    log_skip "samba and wsdd-server already installed"
  else
    log_info "Installing samba and wsdd-server..."
    run sudo apt-get update -qq
    run sudo apt-get install -y -qq samba wsdd-server
    log_applied "samba and wsdd-server installed"
  fi
}

configure_smb_share() {
  [[ "$WITH_SMB" == "1" ]] || return 0
  log_step "SMB share"

  local data unix_user
  data="$(env_get DOCKERSTORAGEDIR)"
  unix_user="$(resolve_smb_user)"

  if (( DRY_RUN )); then
    log_dry "would share ${data} as //${DET_IP:-<server-ip>}/MediaShare"
    return 0
  fi

  if [[ -z "$unix_user" ]]; then
    log_warn "PUID $(env_get PUID) does not match a Unix account — skipping the SMB share."
    return 0
  fi

  # smbusers is fully owned by this phase — rewritten wholesale, same
  # as every other generated file in this repo.
  printf 'admin = %s\n' "$unix_user" | sudo tee /etc/samba/smbusers >/dev/null

  # Everything this phase manages lives in its own included file
  # rather than editing smb.conf's [global] section in place, so a
  # re-run never has to parse or preserve anything an operator added
  # by hand. `username map` must sit in [global] context, so the
  # include line is spliced into the stock [global] section once.
  local managed="/etc/samba/media-suite.conf"
  {
    printf '# Managed by media-suite install.sh --smb. Regenerated on every\n'
    printf '# run — edit smb.conf outside of this include instead.\n'
    printf 'username map = /etc/samba/smbusers\n\n'
    printf '[MediaShare]\n'
    printf '   path = %s\n' "$data"
    printf '   browseable = yes\n'
    printf '   read only = no\n'
    printf '   create mask = 0664\n'
    printf '   directory mask = 0775\n'
    if [[ "$AUTH_MODE" == "sso" ]]; then
      printf '   guest ok = no\n'
      # username map has already resolved "admin" to unix_user by the
      # time this is checked, so it must name the resolved account.
      printf '   valid users = %s\n' "$unix_user"
    else
      printf '   guest ok = yes\n'
      printf '   guest only = yes\n'
      printf '   guest account = %s\n' "$unix_user"
    fi
  } | sudo tee "$managed" >/dev/null

  local conf="/etc/samba/smb.conf"
  if ! sudo grep -qF "include = ${managed}" "$conf"; then
    run sudo sed -i "/^\[global\]/a\\   include = ${managed}" "$conf"
    log_applied "Spliced media-suite's include into smb.conf's [global]"
  else
    log_skip "smb.conf already includes media-suite.conf"
  fi

  if ! sudo testparm -s >/dev/null 2>&1; then
    log_warn "smb.conf failed validation (testparm) — check it by hand."
  fi
  run sudo systemctl enable --now smbd nmbd
  run sudo systemctl restart smbd nmbd
  log_applied "SMB share configured (${AUTH_MODE} mode)"

  # Split from smbd/nmbd above: WS-Discovery is what gets this share
  # to *appear* in Windows Network Browser on current Windows, but the
  # share itself works fine without it (UNC path, or legacy NetBIOS
  # browsing via nmbd). A wsdd-server hiccup — a chroot/capability
  # restriction in some container or VM environment, say — should not
  # take down the share over a nice-to-have.
  if run sudo systemctl enable --now wsdd-server && run sudo systemctl restart wsdd-server; then
    log_applied "wsdd-server running (WS-Discovery, for Network Browser visibility)"
  else
    log_warn "wsdd-server did not start — the share still works, but it may not"
    log_warn "appear automatically in Windows Network Browser. Connect directly:"
    log_warn "  \\\\$(env_get SERVER_IP 2>/dev/null || printf '<server-ip>')\\MediaShare"
    log_warn "Troubleshoot with: systemctl status wsdd-server"
  fi

  # Fallback path: if configure_sso just created a fresh account, the
  # password is already set and this is a no-op. If Tinyauth's account
  # pre-dated --smb, this generates SMB's own password instead.
  #
  # Written as a full if/fi rather than `[[ cond ]] && cmd`: as the
  # LAST statement in the function, a bare `&&` form makes the
  # function's own return status hinge on whichever branch was taken —
  # under --auth=none this test is false, so the function would return
  # 1 with nothing having gone wrong, and main() calling this as a
  # bare statement would trip set -e over it. Cost Andy a debugging
  # session; do not reintroduce this shape at the end of a function.
  if [[ "$AUTH_MODE" == "sso" ]]; then
    ensure_smb_password "$unix_user"
  fi
}

configure_smb_firewall() {
  [[ "$WITH_SMB" == "1" ]] || return 0
  have_cmd ufw || return 0
  sudo ufw status 2>/dev/null | grep -q "^Status: active" || return 0

  log_step "SMB firewall rules"
  (( DRY_RUN )) && { log_dry "would open samba + WS-Discovery ports in ufw"; return 0; }

  if sudo ufw status | grep -qi samba; then
    log_skip "ufw: samba already allowed"
  else
    run sudo ufw allow samba
    log_applied "ufw: allowed samba (137,138/udp, 139,445/tcp)"
  fi

  # The wsdd package ships its own ufw application profile
  # (/etc/ufw/applications.d/wsdd) — prefer it over a hardcoded port,
  # since it tracks whatever wsdd actually listens on upstream rather
  # than a port number frozen at the time this was written.
  local wsdd_rule="wsdd"
  sudo ufw app info wsdd >/dev/null 2>&1 || wsdd_rule="3702/udp"
  if sudo ufw status | grep -qi "$wsdd_rule"; then
    log_skip "ufw: ${wsdd_rule} already allowed"
  else
    run sudo ufw allow "$wsdd_rule"
    log_applied "ufw: allowed ${wsdd_rule} (WS-Discovery)"
  fi
}

install_traefik_config() {
  log_step "Traefik configuration"

  local traefik; traefik="$(env_get TRAEFIK_DIR)"
  run sudo cp "${REPO_ROOT}/config/traefik/certificates.yml" \
    "${traefik}/config/certificates.yml"
  log_applied "Installed certificates.yml"

  # Every protected router references auth@file, so this must exist in
  # both modes — a router pointing at a missing middleware is dropped
  # and its route 404s. Swapping the file switches modes with no
  # restart and no change to any router.
  if [[ "$AUTH_MODE" == "sso" ]] && ! (( DRY_RUN )); then
    # The SSO document carries an IP-to-hostname redirect, so it needs
    # both values substituted.
    local atmp; atmp="$(mktemp)"
    sed -e "s|__SERVER_IP__|$(env_get SERVER_IP)|g" \
        -e "s|__DOMAIN_NAME__|$(env_get DOMAIN_NAME)|g" \
      "${REPO_ROOT}/config/traefik/dynamic/auth-sso.yml" >"$atmp"
    sudo cp "$atmp" "${traefik}/config/auth.yml"
    rm -f "$atmp"
  else
    run sudo cp "${REPO_ROOT}/config/traefik/dynamic/auth-${AUTH_MODE}.yml" \
      "${traefik}/config/auth.yml"
  fi
  log_applied "Installed auth.yml (mode: ${AUTH_MODE})"

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

  # Tinyauth trusts forwarded client IPs only from networks it is told
  # about. Docker assigns the subnet, so it has to be read back rather
  # than assumed.
  (( DRY_RUN )) && return 0
  local subnet
  subnet="$(docker network inspect traefik \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || printf '')"
  if [[ -n "$subnet" ]]; then
    env_set TINYAUTH_TRUSTED_PROXIES "$subnet"
    log_success "Proxy network: ${subnet}"
  fi
}

# `compose up` starts the services in the selected profiles but does
# NOT stop ones whose profile was de-selected — they are part of the
# file, so --remove-orphans does not consider them orphans. Switching
# Plex to Jellyfin, or SSO off, would otherwise leave the old
# container running and still routed.
prune_inactive_services() {
  local project; project="$(env_get COMPOSE_PROJECT_NAME)"
  local -a want=() running=()
  mapfile -t want < <(compose config --services 2>/dev/null)
  (( ${#want[@]} )) || return 0
  mapfile -t running < <(docker ps \
    --filter "label=com.docker.compose.project=${project}" \
    --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null)

  local svc keep
  for svc in "${running[@]}"; do
    [[ -n "$svc" ]] || continue
    keep=0
    local w
    for w in "${want[@]}"; do [[ "$w" == "$svc" ]] && { keep=1; break; }; done
    (( keep )) && continue
    log_info "Stopping ${svc} — no longer in the selected profiles"
    run docker rm -f "$svc" >/dev/null
  done
  return 0
}

deploy_stack() {
  log_step "Deploying stack"
  run compose pull --quiet
  run compose up -d --remove-orphans
  prune_inactive_services
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
  printf '  %-14s %s\n' "Seerr"      "https://${ip}/discover"
  printf '  %-14s %s\n' "Traefik"    "https://${ip}/admin"
  if [[ "$MEDIA_APP" == "plex" ]]; then
    printf '  %-14s %s\n' "Plex"      "https://${ip}:8443/  (clients: http://${ip}:32400)"
  else
    printf '  %-14s %s\n' "Jellyfin"  "https://${ip}:8443/  (clients: http://${ip}:8096)"
  fi
  (( WITH_PORTAINER ))  && printf '  %-14s %s\n' "Portainer"   "https://${ip}/docker"
  (( WITH_SMB ))        && printf '  %-14s %s\n' "SMB share"   "\\\\${ip}\\MediaShare"
  case "$GPU_TYPE" in
    vaapi)  printf '  %-14s %s\n' "GPU accel" "VAAPI (/dev/dri)" ;;
    nvidia) printf '  %-14s %s\n' "GPU accel" "NVENC (Nvidia)" ;;
    *)      printf '  %-14s %s\n' "GPU accel" "none detected" ;;
  esac

  printf '\n  %sAuthentication%s\n' "$C_BOLD" "$C_RESET"
  if [[ "$AUTH_MODE" == "sso" ]]; then
    printf '    · One account ("admin") covers the dashboard, the arr apps,\n'
    printf '      qBittorrent, Portainer and the Traefik dashboard.\n'
    if [[ -n "$SSO_PASSWORD_FILE" ]]; then
      printf '    %s· Your generated password: cat %s%s\n' "$C_YELLOW" "$SSO_PASSWORD_FILE" "$C_RESET"
      printf '      Read it once, then delete that file.\n'
    fi
    printf '    · The media server keeps its own account.\n'
    (( WITH_SMB )) && printf '    · The SMB share uses the same "admin" login.\n'
  else
    printf '    · No login on the LAN for the arr apps or qBittorrent.\n'
    printf '    · Anything that can reach this box controls your library.\n'
    printf '    · Switch later with: ./scripts/install.sh --auth=sso\n'
    (( WITH_SMB )) && printf '    · The SMB share allows guest access — no login needed.\n'
  fi

  printf '\n  %sNotes%s\n' "$C_BOLD" "$C_RESET"
  printf '    · The certificate is self-signed; your browser will warn once.\n'
  printf '    · qBittorrent password: docker logs qbittorrent 2>&1 | grep -i password\n'
  printf '    · Seerr needs a one-time setup at /discover: create the owner\n'
  printf '      account, then connect Radarr/Sonarr. See docs/configuration.md.\n'
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
  choose_auth_mode
  configure_env
  detect_gpu
  collect_plex_claim
  create_directories
  generate_secrets
  install_smb_packages
  configure_sso_host
  configure_sso
  configure_smb_share
  configure_smb_firewall
  generate_certificates
  install_traefik_config
  create_network
  deploy_stack
  wait_for_health
  configure_apps
  print_summary
}

main "$@"
