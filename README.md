# media-suite

A self-hosted media stack for one box: Traefik terminating TLS in front of the
\*arr apps, qBittorrent, a Homarr dashboard, and your choice of
**Plex or Jellyfin**.

Three scripts install it, update it, and remove it. Nothing is configured by
hand unless you want it to be.

> [!IMPORTANT]
> This project was inspired by others and is designed as a _proof of concept_.
> What you do with it is up to you. Good luck and happy tinkering.

![Homarr Dashboard](/assets/Dashboard-Screenshot.png "Homarr Dashboard")

## Quickstart

On a fresh Ubuntu server:

```bash
git clone <this-repo> media-suite && cd media-suite
./scripts/install.sh
```

That is the whole thing. The installer detects your user IDs, timezone, IP
address and LAN range; installs Docker if it is missing; generates secrets and
a TLS certificate; brings the stack up; and then wires the apps to each other.

It asks you three things: **which media server**, **how to handle logins**
(default: none), and — if you chose Plex
— your [claim token](https://plex.tv/claim). Skip even those:

```bash
./scripts/install.sh --media-app=jellyfin --non-interactive
```

Want to see what it would do first?

```bash
./scripts/install.sh --dry-run
```

> [!NOTE]
> If Docker was not already installed, the installer adds you to the `docker`
> group and then **stops**, because Linux only applies group membership to new
> login sessions. Log out, log back in, and run it again — it is idempotent and
> resumes from where it paused.

## What you get

| Service            | Address                     | Purpose                               |
| ------------------ | --------------------------- | ------------------------------------- |
| Homarr             | `https://<server>/`         | Dashboard                             |
| Radarr             | `https://<server>/movies`   | Films                                 |
| Sonarr             | `https://<server>/tv`       | Television                            |
| Lidarr             | `https://<server>/music`    | Music                                 |
| Prowlarr           | `https://<server>/idx`      | Indexer management                    |
| qBittorrent        | `https://<server>/download` | Downloads                             |
| Seerr              | `https://<server>/discover` | Media discovery & requests            |
| Traefik            | `https://<server>/admin`    | Proxy dashboard                       |
| Plex _or_ Jellyfin | `https://<server>:8443/`    | Media server                          |
| Portainer          | `https://<server>/docker`   | Container GUI (opt-in)                |
| Tinyauth           | `https://<server>:8445/`    | Sign-in (opt-in, `--auth=sso`)        |
| SMB share          | `\\<server>\MediaShare`     | Windows file access (opt-in, `--smb`) |

The certificate is self-signed, so your browser will warn you once.

## Logins

By default there is **no login on the LAN** for the arr apps or qBittorrent —
nothing extra to run, and it works over a plain IP address.

Optionally, one account can cover everything reached through the proxy: the
dashboard, all four arr apps, qBittorrent, Portainer, and the Traefik dashboard.
Plex/Jellyfin keeps its own account either way.

```bash
./scripts/install.sh --auth=none   # default
./scripts/install.sh --auth=sso    # one login, via Tinyauth (~46 MB)
```

SSO needs a hostname rather than an IP; `<hostname>.local` works over mDNS with
no DNS setup at all, and the installer offers it.

Switchable later by re-running. See [docs/authentication.md](docs/authentication.md).

## The three scripts

```bash
./scripts/install.sh      # set everything up; safe to re-run
./scripts/update.sh       # pull current images and recreate what changed
./scripts/remove.sh       # tear down; your media is never touched by default
```

Every one of them takes `--dry-run`, `--verbose` and `--help`. A fourth,
`./scripts/configure.sh`, does the app cross-wiring and runs automatically at
the end of an install.

**Updates are deliberate.** There is no Watchtower. Images are pinned to tags
in `.env`, so an install is reproducible and a bad upstream release cannot
land unannounced overnight. To update, run `update.sh`. To roll back, put the
old tag back and run it again.

## Choosing Plex or Jellyfin

Both are defined in the compose file behind [Compose
profiles](https://docs.docker.com/compose/profiles/); `install.sh` writes your
choice into `.env`. Switching later is one line plus an update — and because
both config directories persist, switching back is lossless.

See [docs/media-app.md](docs/media-app.md) for the comparison and the procedure.

## Before you install

**Storage matters here.** The \*arr apps are SQLite-backed, so their config
directory must live on **block storage** — a local disk or iSCSI. **Never NFS**:
file locking over NFS is not reliable enough for concurrent writes and will
corrupt those databases. Your media library is bulk files and is perfectly happy
on NFS.

```bash
./scripts/install.sh --config-dir=/mnt/iscsi/appdata --data-dir=/mnt/nfs/media
```

[docs/architecture.md](docs/architecture.md) explains why.

## Documentation

| Document                                      | Covers                                              |
| --------------------------------------------- | --------------------------------------------------- |
| [architecture.md](docs/architecture.md)       | How it fits together, and why it was built this way |
| [configuration.md](docs/configuration.md)     | Every `.env` variable                               |
| [media-app.md](docs/media-app.md)             | Plex vs Jellyfin, and switching                     |
| [authentication.md](docs/authentication.md)   | SSO vs none, and how to switch                      |
| [file-sharing.md](docs/file-sharing.md)       | The native SMB share, opt-in via `--smb`            |
| [troubleshooting.md](docs/troubleshooting.md) | When something is wrong                             |

## Configuring the apps themselves

`configure.sh` handles the plumbing — download clients, root folders, and
Prowlarr's connections to each app. What it deliberately does not do is pick
your indexers, because which trackers you use and what your credentials are is
not something this repo should guess at.

For tuning quality profiles and naming, the
[TRaSH Guides](https://trash-guides.info/) are the place to start, and the
[Servarr Wiki](https://wiki.servarr.com/) documents each application in depth.

## Licence

[MIT](LICENSE).
