# CLAUDE.md — media-suite

Instructions for Claude Code working in this repository.

## What this is

A self-hosted media stack for a single homelab box: Traefik terminating TLS in
front of Radarr, Sonarr, Lidarr, Prowlarr, Byparr, qBittorrent, Homarr, and
either Plex or Jellyfin. Almost everything is Docker Compose plus bash — the
one deliberate exception is the SMB share (`install.sh --smb`), which is
native on the host, not a container; see docs/file-sharing.md for why. There
is no other application code here — the product is the install experience.

Scope is one machine on a LAN. It is not, and should not become, a multi-node or
enterprise deployment.

## Layout

| Path              | Holds                                                                         |
| ----------------- | ----------------------------------------------------------------------------- |
| `compose/`        | `compose.yml` (core + profiles), `compose.portainer.yml` (opt-in)             |
| `config/traefik/` | Files copied onto the host by `install.sh` — not read by containers from here |
| `scripts/`        | `install.sh`, `update.sh`, `remove.sh`, `configure.sh`                        |
| `scripts/lib/`    | `common.sh` (shared bash), `arr_api.py` (REST wiring)                         |
| `docs/`           | Architecture, configuration reference, troubleshooting                        |
| `.env.example`    | Every variable, documented. `.env` is generated and gitignored                |

## Hard rules

**Never commit `.env`.** It holds generated secrets. `.gitignore` covers it; do
not add an exception, and do not write real values into `.env.example`.

**Never print a secret.** Generated values go straight into `.env` by
redirection — never echoed to stdout, never passed as a command-line argument
(where `ps` would expose them), never written to a log. `configure.sh` passes
credentials to `arr_api.py` through the environment for this reason.

**The install path may only depend on bash, coreutils, `openssl`, `curl` and
`ip`.** `install.sh` runs on a bare host _before Docker exists_. Adding a
dependency on `jq`, node, or anything installed later breaks bootstrap.
`configure.sh` may additionally use `python3`, because it only runs after the
stack is up, and Ubuntu Server ships it.

**No `:latest`.** Every image is pinned to a tag in `.env`. There is no
Watchtower — updates are a deliberate act via `update.sh`, so a bad upstream
release cannot land unannounced. Rollback is editing a tag and re-running.

**Scripts stay shellcheck-clean and support `--dry-run`.** Verify with:

```bash
shellcheck -x -P . scripts/*.sh scripts/lib/*.sh
```

Any new destructive operation goes through `run` so `--dry-run` covers it.

**Idempotence is not optional.** Every script is re-runnable. Phases check
whether their work is already done before acting. `arr_api.py` looks up each
entry by name before creating it.

## Storage — the rule that matters most

`DOCKERCONFDIR` holds **SQLite databases** (every arr app, Homarr). It must
live on **block storage** — iSCSI or a local disk. **Never NFS.** File locking
over NFS is not reliable enough for concurrent writes and will corrupt these
databases.

`DOCKERSTORAGEDIR` is bulk media and downloads: large files, single writer, no
locking requirements. NFS is fine and appropriate here. It is also the only
directory the optional SMB share (`--smb`) ever exposes — never suggest
sharing `DOCKERCONFDIR` over SMB.

This split is the single most consequential deployment decision in the repo.
Do not blur it, and do not suggest putting appdata on an NFS share.

## Routing convention

Traefik fronts everything. Apps that tolerate a subpath get a path prefix on
`:443` with their URL base configured to match. Apps that insist on owning `/`
get their own TLS entrypoint:

- `:443` → Homarr at `/`, everything else on a prefix
- `:8443` → Plex or Jellyfin
- `:8446` → Seerr, plus a plain redirect from `:443/discover` for convenience
  (never a path prefix — see "Things that look like bugs but are not" below)

Adding a service that needs `/` means adding an entrypoint, not fighting
priorities.

Note the escaping difference: `$$` in Compose **labels**, single `$` in Traefik
**file-provider** YAML. Mixing these up silently breaks redirects — it was a
real bug in the original repo.

## Media app selection

Plex and Jellyfin are both defined in `compose.yml`, gated by Compose profiles
and selected through `COMPOSE_PROFILES` in `.env`. Never add a second compose
file or an `-f` chain for this. Switching is one line plus `update.sh`; both
config directories persist so switching back is lossless.

## Conventions

- Bash: `set -euo pipefail`, an `ERR` trap, functions for phases, `local` for
  everything not deliberately global.
- Compose: YAML anchors for shared config; comments explain _why_, not _what_.
- Docs: Markdown with Mermaid. Write down rationale, not just steps — a future
  reader should learn why a choice was made, not only what it was.
- Verify before claiming. `docker compose config -q` for compose changes,
  `shellcheck` for scripts, `--dry-run` before any real run.

## Authentication

`--auth=sso|none`, defaulting to **none**, stored as the `sso` Compose profile. Every protected router
references a middleware named **`auth@file`**, which `install.sh` writes into
Traefik's config directory — forward auth to Tinyauth for `sso`, a no-op
`headers` middleware for `none`.

That indirection is load-bearing. The middleware must exist in both modes,
because a router referencing a missing middleware is dropped by Traefik and its
route 404s. Never make the middleware label conditional on the profile; swap the
file instead. Traefik watches the directory, so it applies with no restart.

Tinyauth's own route must never sit behind `auth@file` — it serves the login
page. Plex and Jellyfin are excluded too: media clients cannot complete a
browser login flow. The SMB share follows `--auth` on its own terms (guest
under `none`, Tinyauth's own credential under `sso`) rather than `auth@file` —
it's a different protocol Traefik never touches. See docs/file-sharing.md.

Tinyauth is v5 from `ghcr.io/tinyauthapp/tinyauth` — the `steveiliop56` path is
abandoned after v5.0.7. v5 namespaces all config under `TINYAUTH_*`; the flat v3
names are ignored _silently_, surfacing as "app URL cannot be empty" rather than
an unknown-variable error. It also refuses IP addresses, single-label names and
public-suffix domains for its app URL, writes a SQLite database (so its volume
must be writable, and it belongs on block storage), and ships its own
healthcheck — do not add one, the image has neither curl nor wget.

Credentials go in **files**, never the environment: a bcrypt hash contains `$`
that Compose interpolates, and environment values are visible in
`docker inspect`. The password is never echoed — when generated it is written to
a file for the operator to read once.

## Docker socket access

Homarr reads the Docker API through `docker-proxy`, never the socket directly.
Two reasons, both load-bearing: its app process runs as uid 1000 while the
socket is `root:docker 0660`, so a bind mount silently fails with `EACCES`; and
the Docker API is root-equivalent, which is too much authority for a dashboard.
The proxy allows `CONTAINERS` only and denies the rest explicitly.

Traefik keeps direct socket access — it needs it for the Docker provider, and it
is the component everything else already trusts.

## Healthchecks gate routing

Traefik's Docker provider drops unhealthy containers from its router table, so a
failing healthcheck does not merely look bad — it takes the service off the proxy
and every request to it returns 404. Healthchecks here are load-bearing.

Always probe **`127.0.0.1`, never `localhost`**. In these images `localhost`
resolves to `::1` first while the apps listen on IPv4 only; `curl` falls back
silently, busybox `wget` does not. Homarr ships no `curl`, so a `localhost` probe
left it permanently unhealthy and invisible to the proxy.

## Things that look like bugs but are not

- `serversTransport.insecureSkipVerify=true` is deliberate: backends use
  self-signed certs or plain HTTP inside the Docker network.
- qBittorrent's middleware order is `redirect,strip` and must stay that way —
  strip-first means the trailing-slash redirect can never match.
- Homarr, the media app, and Seerr all use `PathPrefix(`/`)` at `priority=1`.
  Distinct entrypoints keep them apart; the low priority keeps them from
  shadowing the path-prefixed apps.
- Byparr carries no `traefik.enable` label and publishes no port — same
  treatment as `docker-proxy`. Only Prowlarr, over the internal network, ever
  talks to it. This is deliberate, not a missing route.
- Seerr runs on its own entrypoint (`:8446`), never a path prefix. This was
  tried and measured, not just read from docs: an uninitialized Seerr answers
  `GET /` with `307 Location: /setup`, a root-relative redirect that
  `stripPrefix` cannot fix (it only rewrites request paths, never response
  `Location` headers) — so a `/discover` path-prefix approach sends the
  browser outside the router entirely and breaks on the first request, not
  just on some future upgrade. `:443/discover` is only a `redirectregex` to
  `:8446` (`service: noop@internal`, no backend involved) — do not turn it
  into a reverse proxy again. See
  `docs/architecture.md#seerr-redirect-not-a-path-prefix`.
- Seerr has no `configure.sh` wiring, unlike every other \*arr-adjacent
  service. It cannot: it has no bootstrap API key until an owner account
  exists, and that account only comes from its own interactive setup wizard.
  Same treatment as Plex/Jellyfin's first-run setup — don't try to script
  around it without re-checking whether Seerr's setup API is actually stable
  enough to drive unattended.
- The VAAPI GPU overlay (`compose/compose.gpu-vaapi.yml`) sets `group_add`
  from a `GPU_RENDER_GID` env value read with `stat -c '%g'` on the detected
  render node, not a hardcoded GID like `108` or `44`. The render group's
  number varies by distro and by what else is installed — hardcoding it
  works on the box it was tested on and silently breaks hardware transcode
  (falls back to software, no error) on any other box.
- `detect_gpu()`'s VAAPI check (`vaapi_render_node()` in `install.sh`) reads
  each `/dev/dri/renderD*` node's PCI vendor from sysfs before trusting it —
  it does not just check that a render node exists. Confirmed on the real
  dev box this was built on: an Nvidia GTX 1080 with no Intel iGPU still
  produces `/dev/dri/renderD128`, because Nvidia's proprietary driver
  registers its own DRM render node (`nvidia_drm`) at the same path an
  Intel/AMD node would use. Checking existence alone reported `vaapi` on
  that box and never reached the `nvidia` branch — Mesa's VAAPI backends
  can't open an Nvidia-owned node, so Jellyfin would fail at transcode time
  instead of using the NVENC path that actually works.
