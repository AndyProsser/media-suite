# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **`install.sh`, `update.sh`, `remove.sh`** — the manual README runbook is
  replaced by three idempotent, re-runnable scripts. All support `--dry-run`,
  `--verbose` and `--help`.
- **`configure.sh`** — cross-wires the stack after install over the \*arr REST
  APIs: registers qBittorrent as a download client, registers each app in
  Prowlarr for indexer sync, and sets root folders. Idempotent, so it is safe
  against a partly hand-configured stack.
- **Jellyfin as an alternative to Plex**, selected at install time and switched
  later through `COMPOSE_PROFILES`. Both config directories persist, so
  switching is lossless.
- **Uptime Kuma** on its own TLS entrypoint (`:8444`), replacing the Prometheus
  and Grafana stack.
- **Single sign-on, or no sign-on** — `--auth=sso|none`. SSO puts one Tinyauth
  account (~46 MB) in front of the dashboard, all four arr apps, qBittorrent,
  Portainer and the Traefik dashboard. The arr apps are set to trust the proxy
  and `configure.sh` tells qBittorrent to do the same, so there is no second
  prompt behind the first. Plex/Jellyfin and Uptime Kuma keep their own accounts;
  media clients cannot complete a browser login flow. Switchable by re-running.
- **The Traefik dashboard is no longer unauthenticated.** It previously had no
  access control at all, despite being able to rewrite the stack's routing.
- **`update.sh --check` reports tag drift** against `.env.example`, with
  `--sync-tags` to adopt the recommended versions. A `git pull` cannot change an
  existing `.env`, so without this a repo-side version bump never reaches an
  installed system.
- **Host detection** — user IDs, timezone, server address, LAN CIDR and
  hostname are derived rather than asked for. A default install asks two
  questions at most.
- **Healthchecks** on every service, with routed services gated on the proxy
  being healthy.
- Repository standards: `.gitignore`, `.editorconfig`, MIT `LICENSE`,
  `.vscode/` recommendations and settings, `.claude/CLAUDE.md`, and a CI
  workflow running ShellCheck, Ruff, Compose validation for both media
  profiles, and markdownlint.
- `docs/` — architecture (with topology diagram and design rationale),
  configuration reference, Plex/Jellyfin comparison, monitoring setup, and
  troubleshooting.

### Fixed

- **`install.sh` no longer charges past a docker-group change.** After adding
  the invoking user to the `docker` group it continued straight into
  `docker network create`, which fails with "permission denied" because Linux
  applies group membership only to new login sessions. It now verifies Docker
  is actually reachable, and if not, stops with exit code 2 and an explanation
  rather than failing mid-deploy. Re-running after a re-login resumes cleanly.
- **Lidarr's root folder was never created.** `configure.sh` posted a bare
  `{"path": ...}`, which Radarr and Sonarr accept but Lidarr's v1 API rejects —
  it also requires a name and default quality and metadata profile IDs. The
  payload is now built per application, looking up Lidarr's available profiles
  and preferring one named "Standard".
- **Arr validation errors are now one readable line.** A rejected POST returns a
  JSON array of field errors; dumping it raw buried the useful part in escaped
  punctuation.
- **Homarr 404'd from behind the proxy.** Its healthcheck probed `localhost`,
  which resolves to `::1` first in these images while the app listens on IPv4
  only. `curl` falls back to IPv4 silently, busybox `wget` does not — and the
  Homarr image ships no `curl`, so the probe failed forever, the container never
  reported healthy, and Traefik's Docker provider dropped it from routing
  entirely. All healthchecks now probe `127.0.0.1`. The bug was latent in every
  service; only Homarr lacked the `curl` that masked it.
- **`HOMARR_TAG` was pinned to a stale version** (`v1.32.0`; current is
  `v1.77.2`) because the registry paginated the tag query used to pick it.
- **Placeholder values leaked into live installs.** `.env.example` shipped
  concrete values (`SERVER_IP=192.168.1.2` among them) for fields documented as
  auto-detected, and `env_set_default` correctly treats any non-empty value as a
  deliberate choice — so detection never ran and the placeholder was baked into
  `.env`, the advertise URL, and the TLS certificate's SAN. Those fields are now
  blank, a freshly created `.env` takes detected values outright, and re-runs
  still preserve anything set by hand.
- **The installer now notices address drift**, comparing the stored `SERVER_IP`
  against the host's actual address and offering to correct it — which also
  catches DHCP lease changes.
- **The certificate is checked against the address in use.** If its SAN does not
  cover the current `SERVER_IP`, the installer offers to regenerate and restarts
  the proxy afterwards, since Traefik does not reload a replaced certificate on
  its own. `--force-cert` regenerates unconditionally.
- **An EXIT trap masked every exit code.** `cleanup` ended on a failing test and
  a trap's status replaces the script's own, so `install.sh` reported 1 where it
  meant 2.
- **Plex never trusted the local network.** The compose file read
  `PLEX_NO_AUTH_NETWORKS`, which was defined nowhere; the env file defined
  `LAN_NETWORK` instead. Now wired together.
- **`PLEX_BETA_INSTALL` was ignored** — hardcoded to `false` in the compose
  file, overriding the env value.
- **The Portainer redirect never matched.** `docker-route.yml` used `$$` in a
  Traefik file-provider document, where a single `$` is correct. `$$` is
  Compose *label* escaping.
- **qBittorrent's trailing-slash redirect never matched** — the middleware
  chain ran `strip` before `redirect`, so the prefix was already gone by the
  time the redirect tried to match it.
- **The monitoring stack could never have routed.** Neither service carried
  `traefik.enable=true` while Traefik ran with `exposedbydefault=false`. It
  also referenced an undefined `traefik-auth` middleware, a `monitoring.env`
  that was not in the repo, and a missing `prometheus.yml`; Grafana was
  configured with initial admin creation disabled and no alternative auth,
  making it unloggable. Removed in favour of Uptime Kuma.
- **The Traefik API was exposed unauthenticated on the LAN** via
  `--api.insecure=true` and a published port 8080. Both removed; the dashboard
  is served over TLS at `/admin`.
- Dead configuration removed: `DOMAIN_NAME`, `QBITTORRENT_ENABLE_PRIVOXY` and
  `QBITTORRENT_WEBUI_PORT` were defined but never referenced, and the
  `traefik_internal` network was declared but joined by nothing.

### Changed

- **Images are pinned; Watchtower is gone.** Every tag lives in `.env`. Updates
  happen when you run `update.sh`, not when upstream publishes. Rollback is
  editing a tag and re-running.
- **Deployment no longer goes through Portainer's web UI.** Scripts drive
  Compose directly; Portainer is an opt-in container GUI via
  `--with-portainer`.
- **Secrets are generated, not templated.** `SECRET_ENCRYPTION_KEY` is created
  at install and written straight into `.env` — never echoed, never passed as a
  command-line argument.
- Repository restructured into `compose/`, `config/`, `scripts/` and `docs/`.
- README cut from a fifteen-step runbook to a quickstart and a service table.

### Removed

- **Prometheus and Grafana.** Two services, a scrape config, a provisioning
  tree and an auth middleware to answer "is anything down?". Uptime Kuma
  answers it in ~100 MB of RAM.
- **Readarr** (and the `bookshelf` fork it actually ran). Readarr is
  end-of-life; its route and `books` directories are gone.
- **`media-suite.env` is no longer tracked.** It held a secret key and a Plex
  claim token. Replaced by `.env.example`, with the real file gitignored.
