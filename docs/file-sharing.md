# SMB file share

`install.sh --smb` shares `DOCKERSTORAGEDIR` (the media library and downloads
tree, `/mnt/data` by default) over SMB, visible in the Windows Network Browser
as **`MediaShare`**.

## Why this isn't a container

Every other service in this stack is Docker Compose. This one deliberately
isn't:

- `DOCKERSTORAGEDIR` is a **bind mount**, not a Docker volume — the files
  already live at a real host path. A Samba container would just be a second
  process reading the same directory the host can already serve directly.
- **Network Browser visibility needs real LAN broadcast.** NetBIOS browsing
  and WS-Discovery both rely on broadcast/multicast reaching the actual LAN
  segment, which Docker's default bridge network does not pass through. The
  only fix inside Docker is `network_mode: host`, which buys no isolation over
  running the daemon on the host directly.

So it's installed and managed the same way this repo already manages Docker
itself and `avahi-daemon`: a host-level package, via `apt-get` and
`systemctl`, not a compose service. Only `DOCKERSTORAGEDIR` is ever shared —
never `DOCKERCONFDIR`, which holds every app's SQLite database.

## Enabling it

```bash
./scripts/install.sh --smb
```

Re-runnable and persisted (`SMB_SHARE=true` in `.env`), so a later bare
`./scripts/install.sh` keeps the share without repeating the flag.

Installs `samba` (file serving, plus legacy NetBIOS browsing via `nmbd`) and
`wsdd-server` (WS-Discovery, what modern Windows 10/11 actually uses to
populate Network). Both matter: older clients still use NetBIOS, current ones
mostly don't.

`wsdd-server` — not `wsdd` — because Debian/Ubuntu split this into two
packages: `wsdd` is a bare CLI tool with no systemd integration on current
releases (its own man page is section 1, a user command, not section 8), and
`wsdd-server` is what actually wraps it in a systemd unit
(`wsdd-server.service`) and runs it as a background daemon. Installing the
bare `wsdd` package (an earlier version of this feature's mistake) leaves you
with a binary and nothing to start it.

## Auth follows the stack's `--auth` mode

There is no separate SMB credential to manage — it derives from whatever
`--auth` is already set to:

| Stack auth | Share behaviour                                                                    |
| ---------- | ----------------------------------------------------------------------------------- |
| `sso`      | Login required: username `admin`, same password as the Tinyauth account.            |
| `none`     | Guest access, read-write, no login at all.                                          |

Switching `--auth` later and re-running re-derives the share's auth the same
way it re-derives `auth@file`.

### How the SSO login works under the hood

Samba keeps its own password database — separate from both Tinyauth's and the
host's own login. `install.sh` resolves the Unix account that `PUID`/`PGID`
already point at (the same one every container writes files as), maps the SMB
username `admin` onto it via `/etc/samba/smbusers`, and sets that account's
Samba password to the same plaintext just entered for Tinyauth's `admin`
account — captured in memory before it's bcrypt-hashed for Tinyauth and
discarded, never written to disk unhashed.

Because Samba operates as that same Unix account, every file it touches lands
with exactly the ownership the containers already expect. No `force user` or
`force group` needed.

**Edge case:** if Tinyauth's account already existed before `--smb` was added,
its plaintext password is long gone. In that case a separate SMB password is
generated and written once to
`${DOCKERCONFDIR}/tinyauth/initial-smb-password` — read it and delete the
file, the same pattern as Tinyauth's own generated-password flow:

```bash
cat /mnt/docker/appdata/tinyauth/initial-smb-password && rm /mnt/docker/appdata/tinyauth/initial-smb-password
```

## Configuration files

Nothing here overwrites your existing `/etc/samba/smb.conf`. Everything this
stack manages lives in its own included file:

- `/etc/samba/media-suite.conf` — regenerated wholesale on every run. Holds
  `username map` and the `[MediaShare]` definition. Don't hand-edit it; a
  re-run overwrites it.
- `/etc/samba/smbusers` — the `admin = <resolved account>` mapping. Also fully
  owned and rewritten by this stack.
- `/etc/samba/smb.conf` gets exactly one line added, once: an `include =` for
  `media-suite.conf`, spliced into the existing `[global]` section. Everything
  else in that file is left alone.

## Firewall

If `ufw` is active, `install.sh --smb` opens what SMB and WS-Discovery need:
`ufw allow samba` (137,138/udp, 139,445/tcp), and `ufw allow wsdd` — the
`wsdd` package ships its own ufw application profile, which this uses in
preference to a hardcoded port. Both are additive and safe to re-run.

## Removing it

```bash
./scripts/remove.sh --purge-smb
```

Removes `media-suite.conf`, its include line in `smb.conf`, `smbusers`, and
the Samba password entry. Offers separately to remove the `samba` and
`wsdd-server` packages — declining leaves them installed but unconfigured,
which is safe.

## Troubleshooting

**`wsdd-server did not start` at install.** The share itself is unaffected —
this only means WS-Discovery isn't running, so the share may not
*auto-appear* in Windows Network Browser. Connect directly by UNC path
(`\\<server-ip>\MediaShare`) in the meantime, and check:

```bash
systemctl status wsdd-server
journalctl -u wsdd-server --no-pager -n 50
```

**Doesn't show up in Windows Network Browser (but `wsdd-server` is running).**
Check both discovery daemons are actually up:

```bash
systemctl status smbd nmbd wsdd-server
```

Windows sometimes takes a minute or two to refresh Network; connecting
directly by UNC path (`\\<server-ip>\MediaShare`) works immediately regardless
and is a good way to confirm the share itself is fine while discovery catches
up.

**Connects by UNC path but files land with the wrong owner.** Confirm `PUID`
actually resolves to the account you expect:

```bash
getent passwd "$(grep -oP '(?<=^PUID=).*' .env)"
```

If that's empty, `--smb` was skipped at install (a warning says so) — `PUID`
needs to point at a real Unix account.

**Firewall.** If clients on the same LAN can't reach the share at all and
`ufw` is active, confirm the rules landed:

```bash
sudo ufw status | grep -iE 'samba|wsdd'
```
