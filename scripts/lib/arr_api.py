#!/usr/bin/env python3
"""Cross-wire the arr stack over its REST APIs.

Called by scripts/configure.sh, which supplies credentials through the
environment (not argv, so they do not show up in `ps`).

Every operation is idempotent: it looks for an existing entry by name
before creating one. Running this twice changes nothing the second
time, and running it against a partly hand-configured stack only fills
in what is missing.

Requests go through Traefik on the host rather than to the containers
directly, because the arr apps publish no ports of their own. The
certificate is self-signed, so verification is disabled for these
loopback calls only.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.request

# ── Service topology ───────────────────────────────────────────────
# Mirrors compose/compose.yml. `internal` is how containers address
# each other on the traefik network; `base` is the public path prefix.

ARR_APPS = {
    "radarr": {
        "label": "Radarr",
        "base": "/movies",
        "api": "v3",
        "internal": "http://radarr:7878/movies",
        "category_field": "movieCategory",
        "category": "radarr",
        "root_folder": "/data/media/movies",
        "root_folder_name": "Movies",
        "root_folder_needs_profiles": False,
        "config_contract": "RadarrSettings",
    },
    "sonarr": {
        "label": "Sonarr",
        "base": "/tv",
        "api": "v3",
        "internal": "http://sonarr:8989/tv",
        "category_field": "tvCategory",
        "category": "sonarr",
        "root_folder": "/data/media/tv",
        "root_folder_name": "TV",
        "root_folder_needs_profiles": False,
        "config_contract": "SonarrSettings",
    },
    "lidarr": {
        "label": "Lidarr",
        "base": "/music",
        "api": "v1",
        "internal": "http://lidarr:8686/music",
        "category_field": "musicCategory",
        "category": "lidarr",
        "root_folder": "/data/media/music",
        "root_folder_name": "Music",
        # Lidarr's v1 root folder resource is richer than Radarr's and
        # Sonarr's v3: it rejects a bare path, demanding a name plus
        # default quality and metadata profile IDs.
        "root_folder_needs_profiles": True,
        "config_contract": "LidarrSettings",
    },
}

PROWLARR = {"base": "/idx", "api": "v1", "internal": "http://prowlarr:9696/idx"}

GATEWAY = os.environ.get("GATEWAY", "https://127.0.0.1")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
VERBOSE = os.environ.get("VERBOSE", "0") == "1"

_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode = ssl.CERT_NONE

changed = 0
failed = 0


# ── Output ─────────────────────────────────────────────────────────

def ok(msg: str) -> None:
    print(f"    \033[32m✓\033[0m {msg}", flush=True)


def skip(msg: str) -> None:
    print(f"    \033[2m·\033[0m {msg} \033[2m(already configured)\033[0m", flush=True)


def warn(msg: str) -> None:
    sys.stdout.flush()
    print(f"    \033[33m!\033[0m {msg}", file=sys.stderr, flush=True)


def dry(msg: str) -> None:
    print(f"    \033[36m[dry-run]\033[0m {msg}", flush=True)


def debug(msg: str) -> None:
    if VERBOSE:
        print(f"    \033[2m  {msg}\033[0m", flush=True)


# ── HTTP ───────────────────────────────────────────────────────────

def _describe_error(body: str) -> str:
    """Turn an arr validation response into one readable line.

    These APIs answer a bad POST with a JSON array of field errors.
    Dumping it raw buries the useful part in escaped punctuation.
    """
    try:
        data = json.loads(body)
    except ValueError:
        return body.strip()[:300] or "(no detail)"
    if isinstance(data, list):
        parts = []
        for item in data:
            if isinstance(item, dict):
                field = item.get("propertyName") or "?"
                msg = item.get("errorMessage") or "?"
                parts.append(f"{field}: {msg}")
        return "; ".join(parts) or str(data)[:300]
    if isinstance(data, dict):
        return str(data.get("message") or data.get("error") or data)[:300]
    return str(data)[:300]


def api(app_base: str, api_ver: str, key: str, path: str,
        method: str = "GET", payload: dict | None = None):
    """Call an arr API endpoint. Returns parsed JSON, or None on 404."""
    url = f"{GATEWAY}{app_base}/api/{api_ver}/{path.lstrip('/')}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("X-Api-Key", key)
    req.add_header("Accept", "application/json")
    if data:
        req.add_header("Content-Type", "application/json")

    debug(f"{method} {url}")
    try:
        with urllib.request.urlopen(req, context=_SSL_CTX, timeout=30) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        detail = _describe_error(exc.read().decode("utf-8", "replace"))
        raise RuntimeError(f"HTTP {exc.code} from {path} — {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{method} {url} → unreachable: {exc.reason}") from exc


def reachable(app_base: str, api_ver: str, key: str) -> bool:
    try:
        return api(app_base, api_ver, key, "system/status") is not None
    except RuntimeError as exc:
        debug(str(exc))
        return False


# ── Idempotent operations ──────────────────────────────────────────

def ensure_download_client(name: str, cfg: dict, key: str,
                           qb_user: str, qb_pass: str) -> None:
    """Register qBittorrent as a download client in one arr app."""
    global changed, failed
    label = cfg["label"]

    existing = api(cfg["base"], cfg["api"], key, "downloadclient") or []
    if any(c.get("name") == "qBittorrent" for c in existing):
        skip(f"{label}: qBittorrent download client")
        return

    if DRY_RUN:
        dry(f"{label}: would add qBittorrent as a download client "
            f"(category '{cfg['category']}')")
        return

    payload = {
        "enable": True,
        "protocol": "torrent",
        "priority": 1,
        "removeCompletedDownloads": True,
        "removeFailedDownloads": True,
        "name": "qBittorrent",
        "implementation": "QBittorrent",
        "implementationName": "qBittorrent",
        "configContract": "QBittorrentSettings",
        "tags": [],
        "fields": [
            {"name": "host", "value": "qbittorrent"},
            {"name": "port", "value": 8080},
            {"name": "useSsl", "value": False},
            {"name": "urlBase", "value": ""},
            {"name": "username", "value": qb_user},
            {"name": "password", "value": qb_pass},
            {"name": cfg["category_field"], "value": cfg["category"]},
            {"name": "initialState", "value": 0},
            {"name": "sequentialOrder", "value": False},
            {"name": "firstAndLast", "value": False},
        ],
    }
    try:
        api(cfg["base"], cfg["api"], key, "downloadclient", "POST", payload)
        ok(f"{label}: qBittorrent added (category '{cfg['category']}')")
        changed += 1
    except RuntimeError as exc:
        warn(f"{label}: could not add download client — {exc}")
        failed += 1


def pick_profile(cfg: dict, key: str, endpoint: str,
                 prefer: str | None = None) -> int | None:
    """Return a profile id, preferring one by name, else the first."""
    try:
        items = api(cfg["base"], cfg["api"], key, endpoint) or []
    except RuntimeError as exc:
        debug(f"{endpoint}: {exc}")
        return None
    if not items:
        return None
    if prefer:
        for item in items:
            if str(item.get("name", "")).lower() == prefer.lower():
                return item["id"]
    return items[0]["id"]


def ensure_root_folder(name: str, cfg: dict, key: str) -> None:
    """Point the app at its media directory."""
    global changed, failed
    label, path = cfg["label"], cfg["root_folder"]

    existing = api(cfg["base"], cfg["api"], key, "rootfolder") or []
    if any(f.get("path", "").rstrip("/") == path for f in existing):
        skip(f"{label}: root folder {path}")
        return

    payload: dict = {"path": path}
    if cfg.get("root_folder_needs_profiles"):
        quality = pick_profile(cfg, key, "qualityprofile", prefer="Standard")
        metadata = pick_profile(cfg, key, "metadataprofile", prefer="Standard")
        if quality is None or metadata is None:
            warn(f"{label}: no quality/metadata profiles available yet — "
                 "re-run configure.sh once it has finished initialising.")
            failed += 1
            return
        payload.update({
            "name": cfg["root_folder_name"],
            "defaultQualityProfileId": quality,
            "defaultMetadataProfileId": metadata,
            "defaultMonitorOption": "all",
            "defaultNewItemMonitorOption": "all",
            "defaultTags": [],
        })

    if DRY_RUN:
        dry(f"{label}: would set root folder to {path}")
        return

    try:
        api(cfg["base"], cfg["api"], key, "rootfolder", "POST", payload)
        ok(f"{label}: root folder set to {path}")
        changed += 1
    except RuntimeError as exc:
        warn(f"{label}: could not set root folder — {exc}")
        failed += 1


def ensure_prowlarr_app(name: str, cfg: dict, app_key: str,
                        prowlarr_key: str) -> None:
    """Register an arr app in Prowlarr so indexers sync out to it."""
    global changed, failed
    label = cfg["label"]

    existing = api(PROWLARR["base"], PROWLARR["api"], prowlarr_key,
                   "applications") or []
    if any(a.get("name") == label for a in existing):
        skip(f"Prowlarr: {label} application")
        return

    if DRY_RUN:
        dry(f"Prowlarr: would register {label} for indexer sync")
        return

    payload = {
        "name": label,
        "implementation": label,
        "implementationName": label,
        "configContract": cfg["config_contract"],
        "syncLevel": "fullSync",
        "tags": [],
        "fields": [
            {"name": "prowlarrUrl", "value": PROWLARR["internal"]},
            {"name": "baseUrl", "value": cfg["internal"]},
            {"name": "apiKey", "value": app_key},
        ],
    }
    try:
        api(PROWLARR["base"], PROWLARR["api"], prowlarr_key,
            "applications", "POST", payload)
        ok(f"Prowlarr: {label} registered for indexer sync")
        changed += 1
    except RuntimeError as exc:
        warn(f"Prowlarr: could not register {label} — {exc}")
        failed += 1


# ── Entry point ────────────────────────────────────────────────────

def main() -> int:
    qb_user = os.environ.get("QBIT_USER", "admin")
    qb_pass = os.environ.get("QBIT_PASS", "")
    prowlarr_key = os.environ.get("PROWLARR_API_KEY", "")

    keys = {n: os.environ.get(f"{n.upper()}_API_KEY", "") for n in ARR_APPS}
    available = {n: k for n, k in keys.items() if k}

    if not available:
        warn("No API keys found. Are the containers running? "
             "Each app writes its key to config.xml on first start.")
        return 1

    if not qb_pass:
        warn("No qBittorrent password available — download clients will be "
             "added without one and will need the password set by hand.")

    print("\n  Download clients and root folders", flush=True)
    for name, key in available.items():
        cfg = ARR_APPS[name]
        if not reachable(cfg["base"], cfg["api"], key):
            warn(f"{cfg['label']}: not reachable at {GATEWAY}{cfg['base']} — skipping")
            continue
        ensure_download_client(name, cfg, key, qb_user, qb_pass)
        ensure_root_folder(name, cfg, key)

    if prowlarr_key:
        print("\n  Prowlarr indexer sync", flush=True)
        if reachable(PROWLARR["base"], PROWLARR["api"], prowlarr_key):
            for name, key in available.items():
                ensure_prowlarr_app(name, ARR_APPS[name], key, prowlarr_key)
        else:
            warn(f"Prowlarr not reachable at {GATEWAY}{PROWLARR['base']} — skipping")
    else:
        warn("No Prowlarr API key — skipping indexer sync setup.")

    print()
    if DRY_RUN:
        print("  Dry run complete — nothing was changed.\n")
    elif failed:
        print(f"  {changed} change(s) applied, {failed} failed. "
              "Re-run once the failing services are healthy.\n")
        return 1
    elif changed:
        print(f"  {changed} change(s) applied.\n")
    else:
        print("  Everything was already wired up.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
