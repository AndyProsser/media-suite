# Troubleshooting

## First moves

```bash
docker compose -p media-suite ps          # what is running, and its health
docker compose -p media-suite logs -f <service>
./scripts/update.sh --check               # what would change on an update
```

Every script takes `--verbose` to echo each command, and `--dry-run` to show
what it would do without doing it.

## "Your connection is not private"

Expected. The certificate is self-signed. Click through the warning once per
browser.

To make it go away properly, replace `cert.crt` and `cert.key` in
`${TRAEFIK_DIR}/certificates` with a real certificate and restart the proxy:

```bash
docker restart proxy
```

Traefik watches the config directory but not the certificate files themselves,
so a replaced certificate needs that restart.

## I do not know the qBittorrent password

Modern qBittorrent generates a temporary password on first start and prints it
to the log:

```bash
docker logs qbittorrent 2>&1 | grep -i "temporary password"
```

Set a permanent one in **Tools → Options → Web UI**. If you have already changed
it, `configure.sh` cannot recover it — set it by hand in each \*arr app's
download client settings.

## A service is unhealthy or restarting

```bash
docker compose -p media-suite ps
docker logs <container> --tail 50
```

Most commonly this is permissions. Every container runs as `PUID:PGID` from
`.env` and needs to own its directories:

```bash
sudo chown -R "$(id -u):$(id -g)" /mnt/docker/appdata /mnt/data
```

Re-running `./scripts/install.sh` fixes ownership as part of its directory
phase and is safe at any time.

## Downloads are slow to import, or the disk fills up

The \*arr apps hardlink completed downloads into the library instead of copying
them — but only if both are on the **same filesystem**. If `media/` and
`torrents/` are on different mounts, every import silently becomes a full copy:
twice the disk usage, and slow.

```bash
df /mnt/data/media /mnt/data/torrents   # must be the same filesystem
```

Both live under `DOCKERSTORAGEDIR` by default, which is why. See
[architecture.md](architecture.md).

## Database corruption, or "database is locked"

Almost certainly `DOCKERCONFDIR` on NFS. The \*arr apps, Homarr and Uptime Kuma
are all SQLite-backed, and file locking over NFS is not reliable enough for
concurrent writes.

Move that directory to block storage — a local disk or iSCSI — and reinstall:

```bash
./scripts/install.sh --config-dir=/mnt/iscsi/appdata
```

Media can stay on NFS. This is a hard rule, not a tuning preference.

## A route returns 404

Traefik only routes containers that are up, healthy and labelled. Check the
proxy dashboard at `https://<server>/admin` — the Routers view shows what
Traefik actually knows about.

If a router is missing entirely, the container is probably not on the `traefik`
network or is still starting. If it is present but failing, check the service's
own logs.

## Port already in use

```bash
sudo ss -ltnp | grep -E ':(80|443|8443|8444)\b'
```

The stack needs 80, 443, 8443 and 8444, plus 32400 for Plex or 8096 and 7359
for Jellyfin. A distro-packaged nginx or Apache on 80 is the usual culprit.

## "permission denied" talking to Docker

Your user is not in the `docker` group yet, or the group membership has not
taken effect in this shell:

```bash
id -nG | tr ' ' '\n' | grep -x docker    # is it there?
```

`install.sh` adds you, but group membership only applies to **new** login
sessions. Log out and back in.

## Prowlarr is not syncing indexers

Check that `configure.sh` registered the apps:

```bash
./scripts/configure.sh --dry-run
```

Anything reported as "already configured" is wired up. Anything it would create
was missing — run it without `--dry-run` to fix.

Note that `configure.sh` connects Prowlarr to the apps but deliberately does not
add indexers. You add those yourself in Prowlarr; they then sync outward
automatically.

## Plex says the server is unclaimed

Claim tokens expire four minutes after you generate them, so a slow install can
outrun one. Get a fresh token from [plex.tv/claim](https://plex.tv/claim):

```bash
# edit PLEX_CLAIM_TOKEN in .env, then:
docker compose -p media-suite up -d --force-recreate plex
```

Or just sign in at `https://<server>:8443/` and claim it through the web UI.

## Starting over

```bash
./scripts/remove.sh            # containers only; all data kept
./scripts/remove.sh --purge    # also app configs and databases
./scripts/install.sh           # rebuild
```

`remove.sh` never touches your media library unless you pass `--purge-media`,
which additionally requires typing the path to confirm.

## Getting further help

- [Servarr Wiki](https://wiki.servarr.com/) — per-application documentation
- [TRaSH Guides](https://trash-guides.info/) — quality profiles, naming, hardlinks
- [Traefik docs](https://doc.traefik.io/traefik/) — routing and middleware
