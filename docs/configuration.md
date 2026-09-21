# Configuration reference

All configuration lives in `.env`, created from
[`.env.example`](../.env.example) by `install.sh`. Values you set by hand are
never overwritten by a re-run.

`.env` is gitignored because it holds generated secrets. Keep it that way.

## Project

| Variable               | Default           | Purpose                                                                         |
| ---------------------- | ----------------- | ------------------------------------------------------------------------------- |
| `COMPOSE_PROJECT_NAME` | `media-suite` | Docker project name. Changing it after install orphans the existing containers. |
| `COMPOSE_PROFILES`     | `plex`        | Which components run. See below.                                                |

### `COMPOSE_PROFILES`

A comma-separated list controlling which optional services exist:

- `plex` **or** `jellyfin` — exactly one media server. See [media-app.md](media-app.md).

Portainer is separate: it lives in its own compose file and is enabled with
`install.sh --with-portainer`. The SMB share is separate too, and isn't a
Compose profile at all — see [file-sharing.md](file-sharing.md).

## Host identity

Detected by `install.sh`; override only if the detection is wrong.

| Variable | Detection                      | Purpose                                                                                                    |
| -------- | ------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `PUID`   | `id -u`                        | User ID the containers run as. Must own the data directories.                                              |
| `PGID`   | `id -g`                        | Group ID, likewise.                                                                                        |
| `TZ`     | `timedatectl`, `/etc/timezone` | Timezone for logs and scheduling.                                                                          |
| `UMASK`  | `002`                          | File creation mask. `002` keeps files group-writable, which matters when several containers share `/data`. |

## Network

Left blank in `.env.example` and detected by `install.sh` on first run. Set one
by hand and a re-run will never overwrite it — but the installer warns you if
what is stored no longer matches the host.

| Variable      | Detection                                | Purpose                                                                                                                 |
| ------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `DOMAIN_NAME` | `hostname -f`                            | Common name on the generated TLS certificate.                                                                           |
| `SERVER_IP`   | Address on the default-route interface   | Used in the certificate's SAN, the media server's advertise URL, and the Portainer backend.                             |
| `LAN_NETWORK` | Interface address, masked to its network | Treated as trusted by Plex for local direct play. Must be `network/prefix`, e.g. `192.168.1.0/24` — not a host address. |

> [!IMPORTANT]
> The `[auto]` fields in `.env.example` are deliberately **blank**. A non-empty
> value there would be treated as a deliberate choice and never overwritten,
> which is exactly how a placeholder address ends up baked into a live install
> and its TLS certificate.

### If the address changes

A DHCP lease change leaves `SERVER_IP` stale, and the certificate's SAN with it.
Re-run the installer: it detects the mismatch, offers to update `.env`, notices
the certificate no longer covers the new address, and offers to regenerate it
and restart the proxy.

```bash
./scripts/install.sh                 # detects and offers to fix
./scripts/install.sh --force-cert    # regenerate the certificate regardless
```

A DHCP reservation or a static address avoids the problem entirely.

## Storage

| Variable           | Default               | Purpose                                      |
| ------------------ | --------------------- | -------------------------------------------- |
| `DOCKERCONFDIR`    | `/mnt/docker/appdata` | Application config **and SQLite databases**. |
| `DOCKERSTORAGEDIR` | `/mnt/data`           | Media library and downloads.                 |
| `TRAEFIK_DIR`      | `/mnt/docker/traefik` | Certificates, dynamic config, access logs.   |

> [!IMPORTANT]
> `DOCKERCONFDIR` **must** be on block storage — local disk or iSCSI. Never
> NFS: file locking over NFS is not reliable enough for concurrent SQLite
> writes and will corrupt these databases.
>
> `DOCKERSTORAGEDIR` is bulk files and is fine on NFS.
>
> Keep media and downloads on the **same filesystem** so the \*arr apps can
> hardlink rather than copy. See [architecture.md](architecture.md).

Set both at install time:

```bash
./scripts/install.sh --config-dir=/mnt/iscsi/appdata --data-dir=/mnt/nfs/media
```

## SMB share

| Variable    | Default | Purpose                                                          |
| ----------- | ------- | ----------------------------------------------------------------- |
| `SMB_SHARE` | `false` | Set to `true` by `install.sh --smb`. Native on the host, not a compose service — see [file-sharing.md](file-sharing.md). |

## Logging

| Variable                | Default | Purpose                               |
| ----------------------- | ------- | ------------------------------------- |
| `DOCKERLOGGING_MAXFILE` | `10`    | Rotated log files kept per container. |
| `DOCKERLOGGING_MAXSIZE` | `200k`  | Size at which each rotates.           |

Defaults cap total container logging at roughly 2 MB per service.

## Image tags

Every image is pinned. There is no `:latest` anywhere, and no Watchtower.

| Variable                                                                    | Default   |
| --------------------------------------------------------------------------- | --------- |
| `TRAEFIK_TAG`                                                               | `v3.7`    |
| `RADARR_TAG`, `SONARR_TAG`, `LIDARR_TAG`, `PROWLARR_TAG`, `QBITTORRENT_TAG` | `release` |
| `HOMARR_TAG`                                                                | `v1.77.2` |
| `PLEX_TAG`, `JELLYFIN_TAG`                                                  | `release` |
| `PORTAINER_TAG`                                                             | `lts`     |
| `BYPARR_TAG`                                                                | `v3.0.4`  |

`update.sh --check` also compares your pinned tags against the ones recommended
in `.env.example` and reports any that have moved — a `git pull` cannot change
your `.env`, so this is how a repo-side version bump reaches an existing install:

```bash
./scripts/update.sh --check        # show recommended tag changes
./scripts/update.sh --sync-tags    # adopt them, then update
```

`update.sh` pulls the current image _for the tag you have pinned_. To move to a
new major version, edit the tag here and run `update.sh`. To roll back, put the
old tag back and run it again — which is the whole reason these are pinned.

Homarr has no floating major tag upstream, so it is pinned to an exact version
and needs bumping by hand.

## Secrets

| Variable                | Purpose                          |
| ----------------------- | -------------------------------- |
| `SECRET_ENCRYPTION_KEY` | Homarr's at-rest encryption key. |

Generated by `install.sh` with `openssl rand -hex 32`, written straight into
`.env` — never printed, never passed as a command-line argument. Generate one
manually the same way if you need to.

Changing this after Homarr has stored anything makes the existing data
unreadable.

## Plex

Only used when `COMPOSE_PROFILES` includes `plex`.

| Variable             | Purpose                                                                                                                                      |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `PLEX_CLAIM_TOKEN`   | Links the server to your account on first start. From [plex.tv/claim](https://plex.tv/claim); **expires after 4 minutes**. Only needed once. |
| `PLEX_ADVERTISE_URL` | Helps LAN clients discover the server. Set from `SERVER_IP` at install.                                                                      |
| `PLEX_BETA_INSTALL`  | Beta builds. Requires an active Plex Pass.                                                                                                   |

`PLEX_NO_AUTH_NETWORKS` is not set here — it is wired to `LAN_NETWORK` in the
compose file, so there is one place to change your trusted range.

## Jellyfin

Only used when `COMPOSE_PROFILES` includes `jellyfin`.

| Variable                        | Purpose                                                                   |
| ------------------------------- | ------------------------------------------------------------------------- |
| `JELLYFIN_PUBLISHED_SERVER_URL` | Advertised to LAN clients for discovery. Set from `SERVER_IP` at install. |

## TLS certificate

Used only when `install.sh` generates the self-signed certificate. Changing
them afterwards has no effect unless you delete the existing certificate and
re-run.

| Variable             | Default             |
| -------------------- | ------------------- |
| `CERT_VALIDITY_DAYS` | `7300` (20 years)   |
| `CERT_COUNTRY`       | `AU`                |
| `CERT_STATE`         | `Western Australia` |
| `CERT_LOCALITY`      | `Perth`             |
| `CERT_ORG`           | `HomeLab`           |

The certificate gets `DNS:${DOMAIN_NAME}`, `DNS:localhost` and `IP:${SERVER_IP}`
in its subjectAltName, so browsers accept it after one warning rather than
refusing outright.

To use a real certificate instead, replace `cert.crt` and `cert.key` in
`${TRAEFIK_DIR}/certificates` and restart the proxy.
