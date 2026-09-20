# Design: Install Modernisation & Media App Choice

- **Date:** 2026-09-20
- **Status:** Approved (design), pending spec review
- **Scope:** Replace the manual README runbook with idempotent install/update/remove
  scripts, add a Plex-or-Jellyfin choice, fix known compose defects, and bring the
  repo up to standard tooling conventions.

---

## 1. Problem

`media-suite` is a homelab media stack (Traefik + arr apps + qBittorrent + Homarr +
Plex) distributed as three Compose files, one env file, and an 8 KB README that is
really a fifteen-step manual runbook. There are no scripts of any kind.

Three things are broken about this:

1. **Secrets are committed.** `media-suite.env` is tracked in git and holds
   `SECRET_ENCRYPTION_KEY` and `PLEX_CLAIM_TOKEN`. There is no `.gitignore`.
2. **Install is copy-paste, and it retypes files the repo already ships.** The README
   asks the operator to `echo -e` out `certificates.yml` and a Portainer route file
   that already exist at the repo root, unused by anything.
3. **Deployment is a GUI step.** The final install action is "open Portainer, click Add
   Stack, upload these files" — unscriptable, unversionable, and the reason no update
   or remove path exists at all.

Alongside these, seven correctness defects and several fragility issues were found
during review (Section 6).

## 2. Goals

- One command to install, one to update, one to remove.
- Operator chooses Plex or Jellyfin at install time; switching later is a config change.
- No secret ever enters git, a terminal transcript, or a log.
- Reproducible installs and a rollback path.
- Repo standards: gitignore, editorconfig, licence, changelog, VS Code config,
  Claude instructions, CI linting.

## 3. Non-Goals

- Rewriting git history to scrub the committed env file. Current values are
  placeholders; flagged as a separate decision the operator can revisit.
- Let's Encrypt / ACME automation. Self-signed stays the default; the `acme` mount
  remains for operators who wire it up themselves.
- VPN, remote access, or reverse-proxy-to-the-internet concerns.
- Migrating existing installs. Scripts are written to be idempotent and safe to run
  against an existing deployment, but no data migration is attempted.

## 4. Approach

Three POSIX-bash scripts sharing a `lib/common.sh`, with `.env` as the single source
of truth for all state. `docker compose -p media-suite` supplies the rest.

**Rejected alternatives:**

- *Separate installer state file.* `docker compose down` already knows what it
  created; a second manifest is bookkeeping that can only drift.
- *A TypeScript CLI.* Bootstrap tooling that needs Node installed before it can
  install Docker is the wrong shape. Install must run on a bare Ubuntu box with
  nothing but coreutils, `openssl`, and `curl`.

## 5. Repository Layout

```
media-suite/
├── .claude/
│   └── CLAUDE.md               # project instructions for Claude Code
├── .github/
│   └── workflows/lint.yml      # shellcheck + compose validate + markdownlint
├── .vscode/
│   ├── extensions.json
│   └── settings.json
├── assets/                     # screenshots (unchanged)
├── compose/
│   ├── compose.yml             # core stack + plex/jellyfin profiles
│   ├── compose.portainer.yml   # opt-in
│   └── compose.monitoring.yml  # opt-in, repaired
├── config/
│   ├── prometheus/prometheus.yml
│   └── traefik/
│       ├── certificates.yml    # copied into place, never echoed
│       └── dynamic/portainer.yml
├── docs/
│   ├── architecture.md         # Mermaid topology + design rationale
│   ├── configuration.md        # every env var, what it does
│   ├── media-app.md            # Plex vs Jellyfin, how to switch
│   ├── troubleshooting.md
│   └── superpowers/specs/      # this document
├── scripts/
│   ├── install.sh
│   ├── update.sh
│   ├── remove.sh
│   └── lib/common.sh
├── .editorconfig
├── .env.example
├── .gitignore
├── CHANGELOG.md
├── LICENSE                     # MIT
└── README.md
```

`media-suite.env`, `certificates.yml`, `docker-route.yml`, `portainer-compose.yml`,
`media-suite-compose.yml` and `monitoring-compose.yml` are removed from the repo root;
their content moves into the structure above.

## 6. Defects Fixed

| # | File | Defect | Fix |
|---|------|--------|-----|
| 1 | `media-suite-compose.yml` | Plex reads `${PLEX_NO_AUTH_NETWORKS}`, which is not defined anywhere. Env defines `LAN_NETWORK` instead. Resolves empty. | Compose sets `PLEX_NO_AUTH_NETWORKS=${LAN_NETWORK}`; `LAN_NETWORK` stays the single operator-facing variable. |
| 2 | `media-suite-compose.yml` | `PLEX_BETA_INSTALL=false` hardcoded, overriding the env value. | Reads `${PLEX_BETA_INSTALL}`. |
| 3 | `docker-route.yml` | `regex: "^(.*)/docker$$"` — `$$` is Compose *label* escaping, invalid in a Traefik file-provider YAML. | Single `$`. |
| 4 | `media-suite-compose.yml` | qBittorrent middleware chain `qb-strip,qb-redirect,qb-headers`: strip runs first, so the redirect can never match. | Reordered to `qb-redirect,qb-strip,qb-headers`. |
| 5 | `monitoring-compose.yml` | No `traefik.enable=true` on either service while Traefik runs `exposedbydefault=false` — neither would ever route. References an undefined `traefik-auth` middleware and a `monitoring.env` that is not in the repo. | Labels added; a real basic-auth middleware defined; monitoring vars folded into the single `.env`. |
| 6 | `media-suite-compose.yml` | `--api.insecure=true` plus a published `:8080` exposes the Traefik API unauthenticated on the LAN. | Both removed. Dashboard stays on `/admin` behind TLS. `--ping=true` added for healthchecks. |
| 7 | `media-suite.env` | `DOMAIN_NAME`, `QBITTORRENT_ENABLE_PRIVOXY`, `QBITTORRENT_WEBUI_PORT` defined but never referenced. `PGID=990` contradicts the README's derivation snippet. | Dead vars removed; `DOMAIN_NAME` wired to cert generation; PUID/PGID derived by `install.sh`. |

**Additional repairs:**

- `monitoring-compose.yml` sets `GF_SECURITY_DISABLE_INITIAL_ADMIN_CREATION: "true"`
  with no alternative auth configured — Grafana would be unloggable. Removed.
- Prometheus mounts `/etc/prometheus` but the repo ships no `prometheus.yml`. A scrape
  config targeting Traefik's metrics endpoint is added at `config/prometheus/`.
- The `traefik_internal` network is declared and attached to the proxy but joined by
  nothing. Removed.
- `readarr` runs `ghcr.io/pennydreadful/bookshelf` (Readarr is EOL). Service renamed
  `bookshelf` to match reality; route stays `/books`.
- No healthchecks anywhere; `depends_on` has no conditions, so arr apps start before
  Traefik is ready. Healthchecks added (Section 9).

## 7. Media App Selection

Both services are defined in `compose/compose.yml`, gated by Compose profiles:

```yaml
  plex:
    profiles: [plex]
    image: ghcr.io/hotio/plex:${PLEX_TAG}
    ...
  jellyfin:
    profiles: [jellyfin]
    image: ghcr.io/hotio/jellyfin:${JELLYFIN_TAG}
    ...
```

`install.sh` writes `COMPOSE_PROFILES=plex` or `COMPOSE_PROFILES=jellyfin` into `.env`.
Every script invokes Compose with `--env-file .env`, so the profile is honoured
implicitly — no `-f` chains to keep in sync.

`ghcr.io/hotio/jellyfin` is confirmed to exist, which keeps the same
`PUID`/`PGID`/`UMASK` environment contract as the rest of the stack.

**Differences handled:**

| | Plex | Jellyfin |
|---|---|---|
| Claim token | Prompted at install, 4-minute validity | Not applicable — prompt skipped |
| Advertise URL | `PLEX_ADVERTISE_URL` | `JELLYFIN_PublishedServerUrl` |
| Internal port | 32400 | 8096 |
| Published port | 32400/tcp | 8096/tcp, 7359/udp (discovery) |
| Traefik router | `websecure-alt` (:8443), `HostRegexp(.*)` | identical pattern |
| Config path | `${DOCKERCONFDIR}/plex/{config,transcode}` | `${DOCKERCONFDIR}/jellyfin/{config,cache}` |

Switching after install: edit `COMPOSE_PROFILES` in `.env`, run `./scripts/update.sh`.
Compose stops the deselected service and starts the other. Both config directories
persist, so switching back is lossless. This is documented in `docs/media-app.md`
alongside a short comparison of the two (licensing, hardware transcoding, client
support) so the choice is informed rather than arbitrary.

Running both simultaneously is possible (`COMPOSE_PROFILES=plex,jellyfin`) but is not
offered by the installer and is documented as unsupported — two scanners on one
library doubles I/O for no benefit.

## 8. Scripts

All three: `set -euo pipefail`, an `ERR` trap that reports the failing line, `--help`,
`--dry-run`, and `--verbose`. All are `shellcheck -x` clean. No dependency beyond
bash, coreutils, `openssl`, and `curl`.

### 8.1 `lib/common.sh`

Shared, sourced by all three. Provides:

- `log_step`, `log_info`, `log_warn`, `log_error`, `log_success` — colour-aware,
  honours `NO_COLOR` and non-TTY output.
- `die MESSAGE` — log and exit non-zero.
- `confirm PROMPT` — y/N; auto-yes under `--non-interactive`.
- `run CMD...` — echoes under `--verbose`, skips execution under `--dry-run`.
- `have_cmd` / `require_cmd`.
- `env_get KEY` / `env_set KEY VALUE` — idempotent in-place `.env` editing.
- `compose ARGS...` — wraps `docker compose --project-name "$COMPOSE_PROJECT_NAME"
  --env-file "$ENV_FILE" -f compose/compose.yml [optional -f overlays]`.
- `repo_root` — resolves the repo root from `$BASH_SOURCE` so scripts work from any cwd.

### 8.2 `install.sh`

Idempotent and re-runnable. Each phase is a function; each checks whether its work is
already done before acting.

1. **`preflight`** — verify OS family (Debian/Ubuntu supported; others warn and
   continue), that the invoking user is not root but has sudo, that ports 80, 443,
   8443 and the media app's port are free, that sufficient disk space exists, and that
   no conflicting containers are already running.
2. **`install_docker`** — detect `docker` and `docker compose`. If absent, install
   Docker Engine via the official apt repository method. Add the invoking user to the
   `docker` group and note that a re-login is required.
3. **`create_directories`** — build the appdata, media and Traefik trees from the
   configured paths; `chown` to `PUID:PGID`.
4. **`configure_env`** — copy `.env.example` to `.env` if absent, then prompt for:
   media app, timezone, domain/CN, LAN CIDR, server IP, config and data paths, with
   PUID/PGID auto-derived as defaults. Existing values are offered as defaults on
   re-run. Under `--non-interactive`, flags and existing values supply everything and
   a missing required value is a hard error.
5. **`generate_secrets`** — `SECRET_ENCRYPTION_KEY` via `openssl rand -hex 32`, and
   the monitoring basic-auth credential via `openssl passwd -apr1`. **Written directly
   into `.env` by redirection; never echoed to stdout, a log, or a command line.**
   Skipped if a value is already present. Note that Traefik's `basicauth.users` label
   requires `$` doubled to `$$` when the value is consumed through a Compose label, so
   the hash is stored raw in `.env` and the doubling is applied in the Compose file —
   not baked into the stored value, which would break a direct file-provider use.
6. **`generate_certificates`** — self-signed cert into the Traefik certificates
   directory if absent, subject built from the configured domain and locale values.
7. **`install_traefik_config`** — *copy* `config/traefik/certificates.yml` into the
   live Traefik config directory. When `--with-portainer` is set, also copy
   `config/traefik/dynamic/portainer.yml`, substituting `SERVER_IP` into the backend
   URL. Replaces the README's `echo -e` blocks entirely.
8. **`create_network`** — `docker network create traefik` if it does not exist.
9. **`deploy_stack`** — `compose up -d`, adding `-f compose.portainer.yml` and
   `-f compose.monitoring.yml` when their flags are set.
10. **`wait_for_health`** — poll container health with a timeout; report which
    services came up and which did not.
11. **`print_summary`** — the access URL table, and any follow-up the operator must do
    (re-login for docker group, qBittorrent's generated password location).

**Flags:** `--media-app=plex|jellyfin`, `--non-interactive`, `--with-portainer`,
`--with-monitoring`, `--data-dir=PATH`, `--config-dir=PATH`, `--skip-docker-install`,
`--dry-run`, `--verbose`, `--help`.

### 8.3 `update.sh`

1. `--check` — `compose pull --dry-run` equivalent; report which images have newer
   digests and exit without changing anything.
2. `--backup` — tar the appdata config directories (never media) to a timestamped
   archive before proceeding.
3. Pull, then `compose up -d` to recreate only changed containers.
4. Prune dangling images.

Rollback is editing the relevant `*_TAG` in `.env` and re-running. Flags:
`--check`, `--backup`, `--no-prune`, `--service=NAME`, `--dry-run`, `--verbose`.

### 8.4 `remove.sh`

Default: `compose down` — containers and the project network only. Config, media and
the external `traefik` network survive.

- `--purge` — additionally delete the appdata config tree and named volumes.
- `--purge-media` — additionally delete the media tree. Requires typing the literal
  path to confirm. Never implied by `--purge`.
- `--keep-images` — skip image removal.
- `--remove-network` — drop the external `traefik` network.

Every destructive path prints exactly what will be deleted and requires confirmation
unless `--non-interactive` is given. `--purge-media` is never implied and always
requires its own flag, even non-interactively.

## 9. Compose Changes

**Image tags.** Watchtower is removed. Every image takes an explicit tag from `.env`
(`TRAEFIK_TAG`, `RADARR_TAG`, `PLEX_TAG`, …). Auto-updates are traded for a
reproducible install, a rollback path, and no silent 3 a.m. Plex upgrades;
`update.sh` becomes the deliberate update point.

**Healthchecks.** Added to every service, with `depends_on: { proxy: { condition:
service_healthy } }` on the routed services. Traefik uses `traefik healthcheck --ping`
(requires the new `--ping=true`); arr apps use their `/ping` endpoint under the
configured URL base; Plex uses `/identity`; Jellyfin uses `/health`. Exact commands are
verified against each image during implementation — probe binaries differ between bases.

**Routing table.**

| Service | Route | Entrypoint |
|---|---|---|
| Homarr | `/` | websecure :443 |
| Traefik dashboard | `/admin` | websecure |
| Radarr | `/movies` | websecure |
| Sonarr | `/tv` | websecure |
| Lidarr | `/music` | websecure |
| Bookshelf | `/books` | websecure |
| Prowlarr | `/idx` | websecure |
| qBittorrent | `/download` | websecure |
| Portainer | `/docker` | websecure (file provider) |
| Grafana | `/grafana` | websecure + basic auth |
| Prometheus | `/prometheus` | websecure + basic auth |
| Plex *or* Jellyfin | `/` | websecure-alt :8443 |

Grafana gets `GF_SERVER_ROOT_URL` and `GF_SERVER_SERVE_FROM_SUB_PATH=true`; Prometheus
gets `--web.external-url` and `--web.route-prefix` so both work under a path prefix.

## 10. Repository Standards

- **`.gitignore`** — `.env` and `.env.*` with an explicit `!.env.example` negation,
  `*.key`/`*.crt`/`*.pem`, `.remember/`, `logs/`, backup archives, OS and editor cruft.
- **`.editorconfig`** — 2-space YAML/JSON/Markdown, 2-space shell, LF, final newline,
  trailing-whitespace trim.
- **`LICENSE`** — MIT.
- **`CHANGELOG.md`** — Keep a Changelog format; this restructure is the first entry.
- **`.vscode/extensions.json`** — YAML, Containers, ShellCheck, shell-format,
  EditorConfig, markdownlint, dotenv, Mermaid preview, code spell checker.
- **`.vscode/settings.json`** — Compose schema binding for `compose/compose*.yml`,
  format-on-save, `shellcheck.customArgs: ["-x"]` (scripts source `lib/common.sh`),
  `shellformat.flag: "-i 2 -ci"`, `.remember` hidden, and a homelab dictionary so
  *Traefik*, *Sonarr*, *Prowlarr*, *Jellyfin*, *Homarr*, *qBittorrent*, *servarr* and
  *TRaSH* stop being underlined.
- **`.github/workflows/lint.yml`** — on push and PR: `shellcheck -x` over `scripts/`,
  `docker compose config -q` against both media profiles and both optional overlays,
  and `markdownlint-cli2` over `*.md`.

## 11. `.claude/CLAUDE.md`

Project instructions covering:

- What the repo is and the layout map.
- **Hard rules:** never commit `.env`; secrets are written by redirection and never
  echoed; the install path may depend only on bash, coreutils, `openssl` and `curl`
  (it runs before Docker exists); every script stays `shellcheck -x` clean and
  supports `--dry-run`; no `:latest` tags.
- Compose conventions: profiles for optional components, tags from `.env`.
- **Storage rule:** the arr apps are SQLite-backed, so `DOCKERCONFDIR` must live on
  block storage (iSCSI), never NFS. `DOCKERSTORAGEDIR` is bulk media and is fine on
  NFS. This is the single most consequential deployment constraint in the repo and is
  documented in `docs/architecture.md` as well.
- Documentation conventions: Markdown with Mermaid, rationale as well as usage.

## 12. Documentation

**`README.md`** shrinks to: what this is, a three-command quickstart, the service
access table, and links into `docs/`. The Docker-installation wall disappears into
`install.sh`. Existing typos (`Helpfull`, `convers`, `montioring`, `dependancy`,
`Dashboardl`, `containter`) are corrected. The proof-of-concept disclaimer and the
Servarr/TRaSH links are kept.

**`docs/architecture.md`** — Mermaid topology diagram (entrypoints, routers,
services, volumes), why Traefik terminates TLS with a self-signed cert, why path
prefixes instead of subdomains, the iSCSI-versus-NFS storage split and why, and why
Watchtower was dropped.

**`docs/configuration.md`** — every `.env` variable: purpose, format, default, and
which profile needs it.

**`docs/media-app.md`** — Plex versus Jellyfin comparison and the switching procedure.

**`docs/troubleshooting.md`** — the self-signed certificate warning, finding
qBittorrent's generated password, the docker-group re-login, port conflicts, and
where each service writes its logs.

## 13. Verification

- `shellcheck -x scripts/*.sh scripts/lib/*.sh` clean.
- `docker compose config -q` succeeds for `plex`, `jellyfin`, and both optional
  overlays.
- `./scripts/install.sh --dry-run` for each media app prints a complete, coherent plan
  and touches nothing.
- `markdownlint-cli2` clean.
- `git status` after a dry-run install shows no `.env` and no certificate material.
- A real install on a disposable Ubuntu target: install → verify each route responds →
  `update.sh --check` → `remove.sh` → confirm media survives.

## 14. Open Decisions

1. **Git history.** The committed `media-suite.env` holds only placeholder values, so
   history is left intact. If any value was ever real, history needs rewriting and
   those credentials rotating — operator's call.
2. **Watchtower.** Removed outright. If hands-off updates are wanted for a subset, the
   fallback is to reinstate it scoped to the arr apps only, with label-based opt-in
   and notifications configured.
