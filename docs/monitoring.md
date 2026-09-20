# Monitoring

The stack includes [Uptime Kuma](https://github.com/louislam/uptime-kuma) as its
monitoring layer. It answers one question well — _is anything down?_ — in about
100 MB of RAM.

It runs under the `monitoring` profile, enabled by default. To opt out, remove
`monitoring` from `COMPOSE_PROFILES` in `.env` and run `./scripts/update.sh`, or
install with `--no-monitoring`.

## First run

Open `https://<server>:8444/` and create an admin account. Uptime Kuma has no
default credentials; the first account you create is the administrator.

> **Why a separate port?** Uptime Kuma has no support for running under a
> subpath, so it cannot live at `https://<server>/uptime` the way Radarr lives
> at `/movies`. It gets its own TLS entrypoint instead — the same approach used
> for the media server on `:8443`. See [architecture.md](architecture.md).

## Monitors to create

Uptime Kuma 2.x removed the JSON import feature, and its only programmatic
interface is a Socket.io API — too heavy a dependency to justify in a bash
installer, and writing to its database before first boot is too fragile to ship.
So monitors are not created for you. Here is the set to add.

Create each as an **HTTP(s)** monitor. Because the certificate is self-signed,
turn **"Ignore TLS/SSL error"** on for every one of them.

| Name        | URL                              | Expected |
| ----------- | -------------------------------- | -------- |
| Homarr      | `https://<server>/`              | 200      |
| Radarr      | `https://<server>/movies/ping`   | 200      |
| Sonarr      | `https://<server>/tv/ping`       | 200      |
| Lidarr      | `https://<server>/music/ping`    | 200      |
| Prowlarr    | `https://<server>/idx/ping`      | 200      |
| qBittorrent | `https://<server>/download/`     | 200      |
| Traefik     | `https://<server>/admin/ping`    | 200      |
| Plex        | `https://<server>:8443/identity` | 200      |
| Jellyfin    | `https://<server>:8443/health`   | 200      |

Add the Plex _or_ Jellyfin row, whichever you installed.

A 60-second interval is plenty for a home server. The `/ping` endpoints are
purpose-built health checks and cost the applications almost nothing.

### Docker monitors

The container has `/var/run/docker.sock` mounted read-only, so you can also add
**Docker Container** monitors. Add a Docker host of type _Socket_ pointing at
`/var/run/docker.sock`, then create a monitor per container.

These catch a different failure than the HTTP checks: a container that has
crashed and is restart-looping may still briefly answer HTTP, but will show as
unhealthy here. Worth adding for `proxy` and your media server at minimum.

## Notifications

Monitoring nothing tells you is monitoring you will not look at. Set up at least
one notification channel under **Settings → Notifications**; Uptime Kuma supports
around ninety, including ntfy, Gotify, Telegram, Discord, email and generic
webhooks.

Attach it to every monitor with the **Default enabled** checkbox when you create
the notification, which saves wiring each one by hand.

## Backups

Uptime Kuma's configuration lives in SQLite at
`${DOCKERCONFDIR}/uptime-kuma/`. It is included in `./scripts/update.sh --backup`
along with the rest of the application data.

Like every database in this stack, that directory must be on block storage, not
NFS. See [architecture.md](architecture.md).
