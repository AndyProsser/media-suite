# Plex or Jellyfin

The stack runs one media server. You choose which at install time, and you can
change your mind later without losing anything.

## The comparison

|                          | Plex                                                            | Jellyfin                                     |
| ------------------------ | --------------------------------------------------------------- | -------------------------------------------- |
| **Licence**              | Proprietary                                                     | GPL, fully open source                       |
| **Cost**                 | Free tier; Plex Pass for hardware transcoding and mobile sync   | Free, everything included                    |
| **Account**              | Required — the server links to a plex.tv account                | None; entirely self-contained                |
| **Hardware transcoding** | Plex Pass only                                                  | Free                                         |
| **Client apps**          | Excellent and everywhere: smart TVs, consoles, streaming sticks | Good and improving; patchier on TV platforms |
| **Remote access**        | Built in, brokered through Plex's servers                       | You arrange it yourself                      |
| **Offline dependency**   | Some features degrade if plex.tv is unreachable                 | None                                         |

**Pick Plex if** you want the smoothest experience on the widest range of
client devices, especially TVs and consoles, and you do not mind an account and
a subscription for transcoding.

**Pick Jellyfin if** you want no account, no paid tier, no external dependency,
and free hardware transcoding — and you are willing to live with clients that
are rougher at the edges.

Genuinely unsure? Install Jellyfin. It costs nothing to try, and switching is
about three minutes of work.

## Switching

Both services are defined in `compose/compose.yml` behind Compose profiles, so
switching is a configuration change rather than a reinstall.

Edit `COMPOSE_PROFILES` in `.env`:

```diff
-COMPOSE_PROFILES=plex
+COMPOSE_PROFILES=jellyfin
```

Then apply it:

```bash
./scripts/update.sh
```

Compose stops the service that is no longer in the profile list and starts the
one that is. Takes a couple of minutes, mostly pulling the image.

### What survives

Both config directories persist independently:

```text
${DOCKERCONFDIR}/plex/       # kept, untouched
${DOCKERCONFDIR}/jellyfin/   # kept, untouched
```

Switching back restores the old server with its libraries, users and watch
history intact. Nothing is deleted unless you run `remove.sh --purge`.

Your media library is never touched by either operation — both servers read the
same files from `DOCKERSTORAGEDIR`.

### What does not carry across

Watch history, user accounts and library metadata are stored per-server. Moving
from Plex to Jellyfin means re-adding your libraries in the new server's setup
wizard and re-scanning. The scan is unattended but can take a while on a large
library.

There is no supported way to migrate watch state between the two.

## After switching

**To Jellyfin:** open `https://<server>:8443/`, complete the setup wizard, and
add libraries pointing at `/data/media/movies`, `/data/media/tv` and
`/data/media/music`.

**To Plex:** get a fresh [claim token](https://plex.tv/claim) — they expire
after four minutes — and put it in `.env` as `PLEX_CLAIM_TOKEN` before running
`update.sh`, or link the server manually afterwards.

## Running both at once

Technically possible — `COMPOSE_PROFILES=plex,jellyfin` — but not
supported by the installer and not recommended. Two servers scanning and
transcoding the same library doubles the I/O for no benefit, and they will
compete for the same hardware transcoding device.

If you want to trial one against the other, do it sequentially. Switching is
cheap and reversible, which is rather the point.
