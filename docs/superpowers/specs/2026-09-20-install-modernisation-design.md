# Design: Install Modernisation & Media App Choice

- **Date:** 2026-09-20
- **Status:** Approved; revised 2026-09-20 — Prometheus/Grafana and Readarr dropped,
  Uptime Kuma added, install automation maximised
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
- Metrics, dashboards, or time-series storage. Uptime Kuma answers "is it up?"; any
  deeper observability is out of scope for a homelab media box.
- Indexer configuration. Which trackers to use and their credentials stay with the
  operator.
- Migrating existing installs. Scripts are written to be idempotent and safe to run
  against an existing deployment, but no data migration is attempted.

## 4. Approach

Three POSIX-bash scripts sharing a `lib/common.sh`, with `.env` as the single source
of truth for all state. `docker compose -p media-suite` supplies the rest.

**Rejected alternatives:**

- _Separate installer state file._ `docker compose down` already knows what it
  created; a second manifest is bookkeeping that can only drift.
- _A TypeScript CLI._ Bootstrap tooling that needs Node installed before it can
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
│   ├── compose.yml             # core + plex/jellyfin/monitoring profiles
│   └── compose.portainer.yml   # opt-in
├── config/
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
│   ├── configure.sh            # post-install arr cross-wiring
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

| #   | File                      | Defect                                                                                                                                                                                                               | Fix                                                                                                           |
| --- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 1   | `media-suite-compose.yml` | Plex reads `${PLEX_NO_AUTH_NETWORKS}`, which is not defined anywhere. Env defines `LAN_NETWORK` instead. Resolves empty.                                                                                             | Compose sets `PLEX_NO_AUTH_NETWORKS=${LAN_NETWORK}`; `LAN_NETWORK` stays the single operator-facing variable. |
| 2   | `media-suite-compose.yml` | `PLEX_BETA_INSTALL=false` hardcoded, overriding the env value.                                                                                                                                                       | Reads `${PLEX_BETA_INSTALL}`.                                                                                 |
| 3   | `docker-route.yml`        | `regex: "^(.*)/docker$$"` — `$$` is Compose _label_ escaping, invalid in a Traefik file-provider YAML.                                                                                                               | Single `$`.                                                                                                   |
| 4   | `media-suite-compose.yml` | qBittorrent middleware chain `qb-strip,qb-redirect,qb-headers`: strip runs first, so the redirect can never match.                                                                                                   | Reordered to `qb-redirect,qb-strip,qb-headers`.                                                               |
| 5 | `monitoring-compose.yml` | No `traefik.enable=true` on either service while Traefik runs `exposedbydefault=false` — neither would ever route. Undefined `traefik-auth` middleware, missing `monitoring.env`, missing `prometheus.yml`, and a Grafana config that disables admin creation without configuring any alternative auth (unloggable). | **File deleted.** Prometheus and Grafana removed entirely — metrics plumbing costs more than it returns at this scale. Replaced by Uptime Kuma (Section 9a). |
| 6   | `media-suite-compose.yml` | `--api.insecure=true` plus a published `:8080` exposes the Traefik API unauthenticated on the LAN.                                                                                                                   | Both removed. Dashboard stays on `/admin` behind TLS. `--ping=true` added for healthchecks.                   |
| 7   | `media-suite.env`         | `DOMAIN_NAME`, `QBITTORRENT_ENABLE_PRIVOXY`, `QBITTORRENT_WEBUI_PORT` defined but never referenced. `PGID=990` contradicts the README's derivation snippet.                                                          | Dead vars removed; `DOMAIN_NAME` wired to cert generation; PUID/PGID derived by `install.sh`.                 |

**Additional repairs:**

- The `traefik_internal` network is declared and attached to the proxy but joined by
  nothing. Removed.
- No healthchecks anywhere; `depends_on` has no conditions, so arr apps start before
  Traefik is ready. Healthchecks added (Section 9).
- Traefik's Prometheus metrics flags go away with Prometheus itself.

**Removals requested after design approval:**

- **Prometheus and Grafana** — deleted, not repaired. See Section 9a for the
  replacement.
- **Readarr / `bookshelf`** — the service, its `/books` route, and its `books` media
  and torrent directories are removed. Readarr is EOL and the replacement fork is not
  wanted here.

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

|                | Plex                                       | Jellyfin                                   |
| -------------- | ------------------------------------------ | ------------------------------------------ |
| Claim token    | Prompted at install, 4-minute validity     | Not applicable — prompt skipped            |
| Advertise URL  | `PLEX_ADVERTISE_URL`                       | `JELLYFIN_PublishedServerUrl`              |
| Internal port  | 32400                                      | 8096                                       |
| Published port | 32400/tcp                                  | 8096/tcp, 7359/udp (discovery)             |
| Traefik router | `websecure-alt` (:8443), `HostRegexp(.*)`  | identical pattern                          |
| Config path    | `${DOCKERCONFDIR}/plex/{config,transcode}` | `${DOCKERCONFDIR}/jellyfin/{config,cache}` |

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
4. **`configure_env`** — copy `.env.example` to `.env` if absent, then fill it by
   **detection rather than interrogation** (Section 8.5). The operator is shown the
   detected values as a single confirmable block and can accept all of them with one
   keypress. Existing `.env` values always win over detection on re-run. Under
   `--non-interactive`, detection plus flags supply everything and a missing required
   value is a hard error.
5. **`generate_secrets`** — `SECRET_ENCRYPTION_KEY` via `openssl rand -hex 32`.
   **Written directly into `.env` by redirection; never echoed to stdout, a log, or a
   command line.** Skipped if a value is already present.
6. **`generate_certificates`** — self-signed cert into the Traefik certificates
   directory if absent, subject built from the configured domain and locale values.
7. **`install_traefik_config`** — _copy_ `config/traefik/certificates.yml` into the
   live Traefik config directory. When `--with-portainer` is set, also copy
   `config/traefik/dynamic/portainer.yml`, substituting `SERVER_IP` into the backend
   URL. Replaces the README's `echo -e` blocks entirely.
8. **`create_network`** — `docker network create traefik` if it does not exist.
9. **`deploy_stack`** — `compose up -d`, adding `-f compose.portainer.yml` and
   `-f compose.monitoring.yml` when their flags are set.
10. **`wait_for_health`** — poll container health with a timeout; report which
    services came up and which did not.
11. **`configure_apps`** — unless `--skip-configure`, run `scripts/configure.sh` to
    cross-wire the arr stack (Section 8.5).
12. **`print_summary`** — the access URL table, the Uptime Kuma monitor set to add,
    and any follow-up the operator must do (re-login for the docker group, where to
    find qBittorrent's generated password).

**Flags:** `--media-app=plex|jellyfin`, `--non-interactive`, `--with-portainer`,
`--no-monitoring`, `--data-dir=PATH`, `--config-dir=PATH`, `--skip-docker-install`,
`--skip-configure`, `--dry-run`, `--verbose`, `--help`.

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


### 8.5 Automation Scope

The target is a working stack from `./scripts/install.sh` with **no arguments and at
most two answers**. Everything below is derived, not asked.

**Detected from the host:**

| Value | Source |
|---|---|
| `PUID` / `PGID` | `id -u` / `id -g` of the invoking user |
| `TZ` | `timedatectl show -p Timezone --value`, falling back to `/etc/timezone` |
| `SERVER_IP` | the address on the interface holding the default route |
| `LAN_NETWORK` | that interface's address and prefix, normalised to network/CIDR |
| `DOMAIN_NAME` | the host's FQDN, falling back to `hostname` |
| Data/config paths | the spec defaults, overridable by flag |

**Generated, never asked for:** `SECRET_ENCRYPTION_KEY`, the TLS keypair, and the
Docker network.

**The only genuine questions:** which media app, and — for Plex only — the claim
token, which cannot be derived because it is minted by a human logging into plex.tv
and expires in four minutes. Both are also settable by flag, so
`--media-app=jellyfin --non-interactive` is a fully unattended install.

**`configure.sh` — post-install cross-wiring.** The step that actually costs an
evening is not installing containers, it is wiring them to each other. This script
does it over the arr REST APIs once the containers are healthy:

1. Read each app's API key from `${DOCKERCONFDIR}/<app>/config.xml` (written on first
   start).
2. Read qBittorrent's generated password from its container log.
3. Register qBittorrent as a download client in Radarr, Sonarr and Lidarr, with the
   correct category per app.
4. Register Radarr, Sonarr and Lidarr as applications in Prowlarr, so indexers sync
   outward automatically.
5. Set each app's root folder to its `/data/media/<type>` path.

Every step is idempotent — it queries for an existing entry by name before creating
one — so the script is safe to re-run, and safe to run against a stack the operator
has already partly configured by hand. It is also runnable standalone, and exposed as
`install.sh --skip-configure` for operators who want to do it themselves.

Indexers themselves are deliberately not automated: which trackers an operator uses,
and their credentials, are not something this repo should be guessing at.

## 9. Compose Changes

**Image tags.** Watchtower is removed. Every image takes an explicit tag from `.env`
(`TRAEFIK_TAG`, `RADARR_TAG`, `PLEX_TAG`, …). Auto-updates are traded for a
reproducible install, a rollback path, and no silent 3 a.m. Plex upgrades;
`update.sh` becomes the deliberate update point.

**Healthchecks.** Added to every service, with `depends_on: { proxy: { condition:
service_healthy } }` on the routed services. Traefik uses `traefik healthcheck --ping`
(requires the new `--ping=true`); arr apps use their `/ping` endpoint under the
configured URL base; Plex uses `/identity`; Jellyfin uses `/health`; Uptime Kuma uses
its bundled `extra/healthcheck` probe. Exact commands are verified against each image
during implementation — probe binaries differ between bases.

**Routing table.**

| Service            | Route         | Entrypoint                |
| ------------------ | ------------- | ------------------------- |
| Homarr             | `/`           | websecure :443            |
| Traefik dashboard  | `/admin`      | websecure                 |
| Radarr             | `/movies`     | websecure                 |
| Sonarr             | `/tv`         | websecure                 |
| Lidarr             | `/music`      | websecure                 |
| Prowlarr           | `/idx`        | websecure                 |
| qBittorrent        | `/download`   | websecure                 |
| Portainer          | `/docker`     | websecure (file provider) |
| Uptime Kuma | `/` | websecure-kuma :8444 |
| Plex _or_ Jellyfin | `/`           | websecure-alt :8443       |

Services holding a path prefix have their URL base configured to match
(`RADARR__SERVER__URLBASE=/movies` and friends) so generated links stay correct behind
the proxy.


## 9a. Uptime Monitoring — Uptime Kuma

Prometheus and Grafana are replaced by a single Uptime Kuma container. The old stack
was two services, a scrape config, a dashboard provisioning tree, and a basic-auth
middleware — all to answer "is anything down?" on a box with a dozen containers.
Uptime Kuma answers that directly, in roughly 100 MB of RAM, with notifications built
in and no query language to learn.

- **Image:** `louislam/uptime-kuma:${UPTIME_KUMA_TAG}`, pinned to `2` (2.x is GA;
  current release 2.5.5).
- **Profile:** `monitoring`, enabled by default in the generated
  `COMPOSE_PROFILES`. Opting out is removing one word from `.env`.
- **Storage:** SQLite at `/app/data`, bound to `${DOCKERCONFDIR}/uptime-kuma`. This is
  a database, so it falls squarely under the block-storage rule in Section 11.
- **Docker integration:** `/var/run/docker.sock` mounted read-only so container-level
  monitors work alongside HTTP ones.

**Routing.** Uptime Kuma has no subpath support — `UPTIME_KUMA_BASE_PATH` exists only
in closed pull requests and appears nowhere in the 2.5.5 source, so it cannot be served
from `/uptime`. It gets its own TLS entrypoint on `:8444`, exactly the pattern Plex
already uses on `:8443`.

This settles a convention worth stating plainly: **apps that must own their root path
get a dedicated TLS entrypoint; everything else gets a path prefix on `:443`.** Homarr
holds `/` on 443, the media app holds `/` on 8443, Uptime Kuma holds `/` on 8444.

**Seeding.** Uptime Kuma 2.x removed the JSON backup/restore feature, and its only
programmatic interface is Socket.io — too heavy a dependency for a bash installer, and
writing to its SQLite file before first boot is too fragile to ship. Monitors are
therefore not auto-created. Instead `install.sh` prints, and `docs/monitoring.md`
records, the exact monitor set for the deployed profile (URL, expected status, suggested
interval) so setup is transcription rather than design.

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
  _Traefik_, _Sonarr_, _Prowlarr_, _Jellyfin_, _Homarr_, _qBittorrent_, _servarr_ and
  _TRaSH_ stop being underlined.
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

**`docs/monitoring.md`** — what Uptime Kuma is doing here, the monitor set to create
for the deployed profile, and how to wire up notifications.

**`docs/troubleshooting.md`** — the self-signed certificate warning, finding
qBittorrent's generated password, the docker-group re-login, port conflicts, and
where each service writes its logs.

## 13. Verification

- `shellcheck -x scripts/*.sh scripts/lib/*.sh` clean.
- `docker compose config -q` succeeds for `plex`, `jellyfin`, `monitoring`, and the
  Portainer overlay.
- `./scripts/install.sh --dry-run` for each media app prints a complete, coherent plan
  and touches nothing.
- `markdownlint-cli2` clean.
- `git status` after a dry-run install shows no `.env` and no certificate material.
- `./scripts/configure.sh --dry-run` reports the wiring it would create without
  touching any app.
- A real install on a disposable Ubuntu target: install → verify each route responds →
  `configure.sh` → confirm Prowlarr sees all three arr apps and each has qBittorrent as
  a download client → `update.sh --check` → `remove.sh` → confirm media survives.

## 14. Open Decisions

1. **Git history.** The committed `media-suite.env` holds only placeholder values, so
   history is left intact. If any value was ever real, history needs rewriting and
   those credentials rotating — operator's call.
2. **Watchtower.** Removed outright. If hands-off updates are wanted for a subset, the
   fallback is to reinstate it scoped to the arr apps only, with label-based opt-in
   and notifications configured.
