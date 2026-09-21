# Native SMB share for DOCKERSTORAGEDIR

Status: proposed
Date: 2026-09-21

## Why

Andy wants `/mnt/data` (the `DOCKERSTORAGEDIR` library/downloads tree) to show
up as a share in the Windows Network Browser, so it can be opened from a
Windows box without typing a UNC path or mapping a drive by hand.

## Why this is not a container

Every other service in this repo is Docker Compose. This one deliberately
isn't, for two reasons specific to it:

1. **The data is already at a real host path.** `DOCKERSTORAGEDIR` is a bind
   mount, not a Docker volume — the files live at `/mnt/data` on the host
   regardless of any container. A Samba container would just be a second
   process reading the same host directory a container gains nothing by
   sitting in front of.
2. **Network Browser visibility needs real L2 broadcast.** NetBIOS browsing
   and WS-Discovery both rely on broadcast/multicast reaching the actual LAN
   segment. Docker's default bridge network doesn't pass that through
   properly; the only fix inside Docker is `network_mode: host`, which buys
   no isolation over running the daemon on the host directly, and does not
   avoid the "share a bind-mounted directory it can already see natively"
   problem in point 1.

So this feature is a host-level install phase, not a compose service. It's the
same category of exception this repo already makes for `avahi-daemon`
(installed and enabled by `install.sh` today, for mDNS) and for Docker itself
— host-level daemons install.sh is already willing to manage via `apt-get` and
`systemctl`.

## Scope

Shares exactly one path: `DOCKERSTORAGEDIR` (`/mnt/data` by default, whatever
the operator configured at install time). `DOCKERCONFDIR` is never shared —
it holds every app's SQLite database, and exposing it over SMB would be both
a correctness risk (a second, unlocked writer against the same rule this repo
already enforces against NFS) and pointless (nothing in there is meant for
manual browsing).

## Packages

- `samba` — `smbd` (file serving) + `nmbd` (legacy NetBIOS browsing, still
  used by older clients and some Windows Explorer paths) + `samba-common-bin`
  (pulled in as a dependency; provides `smbpasswd`).
- `wsdd` — WS-Discovery responder. Modern Windows 10/11 primarily discovers
  LAN devices via WS-Discovery, not NetBIOS; Samba doesn't implement this
  itself, so without `wsdd` the share often works by UNC path
  (`\\<ip>\MediaShare`) but never appears in the Network Browser on current
  Windows. Both daemons are installed together because between them they
  cover old and current clients.

Both are enabled and started via `systemctl enable --now`, following the
existing `ensure_mdns()` pattern for `avahi-daemon`.

## Identity: no `force user` hacks

`PUID`/`PGID` in this stack are, in the overwhelming common case, literally
the installing operator's own `id -u`/`id -g` (`install.sh` detects them that
way — see `PUID/PGID` phase). That Unix account already owns every file under
`/mnt/data`, since every container writes as that PUID:PGID.

Rather than fight Samba's `force user`/`force group` (which needs a resolvable
Unix account and gets fragile across distros when driven by a bare UID),
this design resolves the actual username behind `PUID` with
`getent passwd "$PUID" | cut -d: -f1` and lets Samba operate as that account
natively:

- **SSO mode** — a `username map` entry maps the SMB login "admin" to that
  real Unix account, and `smbpasswd` sets a Samba password for it (Samba
  keeps its own password database; this does not touch `/etc/shadow` or the
  account's real login password). The client types "admin" and the same
  password captured for Tinyauth; Samba resolves it to the real account
  underneath, so every file it touches lands with exactly the ownership the
  containers already expect — no `force user` needed.
- **Guest mode** (`--auth=none`) — `guest account = <that same username>` at
  the share level. Guest sessions run as the PUID-owning account for the same
  reason: correct ownership with no extra plumbing.

If `PUID` doesn't resolve to any Unix account (uncommon — only possible if an
operator hand-edited `.env` to an arbitrary number), the phase warns and skips
rather than guessing.

## Auth modes

Directly derived from the stack's existing `--auth` choice — no separate flag,
matching what was asked for ("if SSO enabled, use the same tinyauth user/pass;
if no auth, guests should have access"):

| Stack `--auth=` | Share behavior |
| ---------------- | -------------- |
| `sso`  | `guest ok = no`; login is "admin" + the same password Tinyauth's admin account got, resolved via username map to the PUID account. |
| `none` | `guest ok = yes`, `guest only = yes`; anyone on the LAN gets in with no credentials, mapped to the same PUID account. |

Both modes: `read only = no` — confirmed explicitly with Andy that guests get
read-write, same as the SSO login. (Read-only-for-guests was the safer
default and was offered; he wants read-write for both.)

Switching `--auth` later (already a supported, idempotent operation on this
repo) re-derives the share's auth block the same way it re-derives
`auth@file`.

## Flag and persistence

New `install.sh` flag: `--smb` (opt-in; omitted/absent = off, matching "add an
*option* to share"). Persisted as `SMB_SHARE=true` in `.env` so a bare re-run
of `install.sh` stays idempotent and doesn't need the flag repeated, exactly
like `AUTH_MODE` and `COMPOSE_PROFILES` today.

## Config management

`/etc/samba/smb.conf` is a host file that may pre-date this install (unlikely
but possible) or gain hand-edits later. Rather than scanning it for a marked
block to replace, everything this phase manages lives in its own file,
`/etc/samba/media-suite.conf`, rewritten wholesale on every run — the same
"fully own it, regenerate every time" approach `auth.yml` already uses for
Traefik. It holds `username map = /etc/samba/smbusers` and the `[MediaShare]`
definition.

The stock `smb.conf` gets exactly one idempotent change: an
`include = /etc/samba/media-suite.conf` line spliced into its existing
`[global]` section (checked for first, so a re-run never duplicates it).
Samba treats an `include` inside `[global]` as continuing that same section,
which is why `username map` — a global-only parameter — can live in the
included file without needing its own `[global]` header. Everything else an
operator has in `smb.conf` is left untouched.

`/etc/samba/smbusers` (the `admin = <unix_user>` mapping) is likewise fully
owned and rewritten wholesale.

## Firewall

If `ufw` is active, `install.sh` opens what's needed:
`ufw allow samba` (137,138/udp + 139,445/tcp) and `ufw allow 3702/udp`
(WS-Discovery). Both are additive, idempotent (`ufw allow` is safe to repeat),
and only run if `ufw status` reports active — same conditional style already
used for the avahi phase.

## Credential capture

Reuses the plaintext `password` variable install.sh already holds in memory
during the existing Tinyauth credential phase (before it's bcrypt-hashed and
`unset`). Immediately after Tinyauth's `user create` call and before that
`unset`, this phase pipes the same plaintext into
`smbpasswd -s -a "$unix_user"` (`-s` = read password from stdin twice,
non-interactive). Nothing new is echoed, logged, or written to a file that
doesn't already exist for this purpose.

**Edge case:** if Tinyauth's account already existed before `--smb` was
added, its plaintext is already gone by the time this phase runs — the
credential-capture call above is only reached when a *fresh* Tinyauth
account is being created. The SMB phase makes its own idempotent call to the
same "set if not already set" helper as a fallback; finding no Samba password
yet set, it generates an independent one and writes it out once, the same
pattern as Tinyauth's own generated-password flow.

## Removal

`remove.sh` gets a confirm-gated step (`--purge-smb`), only run if
`SMB_SHARE=true` is set: removes `/etc/samba/media-suite.conf`, its `include`
line in `smb.conf`, `/etc/samba/smbusers`, and the Samba password entry
(`smbpasswd -x`), and — behind a separate, explicit confirmation, since it's a
system package removal rather than config — offers to `apt-get remove`
`samba`/`wsdd`. Declining either leaves the packages installed but
unconfigured, which is safe.

## Docs

New `docs/file-sharing.md`: what's shared, why it's native, how the two auth
modes work, the discovery mechanism (nmbd + wsdd) and its own small
troubleshooting section (client can't see the share → check `wsdd`/`nmbd` are
running and the firewall rules above; wrong file ownership over SMB → check
`getent passwd $PUID` resolved to the account you expected).
`docs/configuration.md` gets the new `--smb` flag documented alongside the
existing table of options.

## Out of scope

- Sharing `DOCKERCONFDIR` — never; see Scope above.
- Per-directory/per-user ACLs beyond the single guest/SSO split — not asked
  for, and out of proportion for a single-operator homelab box.
- Time Machine / AFP / NFS-for-Windows alternatives — SMB is what was asked
  for and what Windows actually wants.
