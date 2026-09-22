# GPU passthrough for hardware transcoding (Jellyfin & Plex)

Status: approved
Date: 2026-09-23

## Why

Software transcoding pegs the CPU on a single homelab box and caps how many
concurrent streams either media app can serve. Both Jellyfin and Plex can use
a host GPU instead, but Docker never passes hardware through automatically —
without an explicit device mapping, both apps fall back to software transcode
silently, and the failure only shows up as "why is this so slow" months
later.

## Scope

Two backends, chosen because they're what actually exists on x86 homelab
hardware:

- **VAAPI** — Intel iGPU (`i915` driver) or AMD GPU (`amdgpu` driver). Both
  expose the same Linux kernel API through the same device node pattern
  (`/dev/dri/renderD128`), so there is exactly one code path and one overlay
  file for both vendors. No vendor detection needed — only "does a render
  node exist."
- **NVENC** — Nvidia, via `nvidia-container-toolkit`. Genuinely different:
  Nvidia's driver stack doesn't expose `/dev/dri`, and the container needs a
  GPU reservation instead of a device bind mount.

Explicitly out of scope: AMD AMF (Windows-only, irrelevant on Linux), Rockchip
MPP (ARM SBC hardware, not this repo's target), Apple VideoToolbox and V4L2
(not applicable to a Linux Docker host). These four appear in Jellyfin's
hardware-acceleration dropdown because that list is static across every
platform Jellyfin runs on — it is not a live readout of what the current host
supports, and should not be read as "supported options for this repo."

Applies to **both** `jellyfin` and `plex` service blocks in `compose.yml`.
They're structurally parallel (profile-gated, only one active at a time), so
one pair of overlay files targets both by service name at no extra cost, and
Plex also supports hardware transcode with a Plex Pass.

## Detection

A new `detect_gpu()` phase in `install.sh`, placed in `main()` right after
`choose_media_app()`. Unlike `--media-app`/`--auth`, this is not a persisted
user *choice* — it's a hardware fact, so it re-checks on every run rather than
skipping when "already configured." Re-plugging a GPU (or removing one)
should be picked up the next time `install.sh` runs, with no flag needed.

- `--gpu=vaapi|nvidia|none` overrides auto-detection, validated in
  `parse_args()` the same way `--media-app` and `--auth` are.
- Otherwise, auto-detect in order:
  1. `/dev/dri/renderD128` exists → `vaapi`.
  2. `nvidia-smi` is present and exits 0 → `nvidia`.
  3. Neither → `none`.
- On `vaapi`: compute the device's group ownership with
  `stat -c '%g' /dev/dri/renderD128` (pure coreutils — no `getent`, keeping
  `install.sh` inside its bash/coreutils/openssl/curl/ip dependency budget)
  and write it to `.env` as `GPU_RENDER_GID`. Compose needs this in the
  environment to interpolate into the overlay file's `group_add`.
- On `nvidia`: if `nvidia-container-toolkit` isn't already installed, install
  it automatically — add NVIDIA's official apt repo (curl + gpg key, same
  shape as `install_docker()`'s Docker repo addition), `apt-get install
  nvidia-container-toolkit`, then `nvidia-ctk runtime configure
  --runtime=docker` and restart the Docker daemon. This only fires when
  `nvidia-smi` has already proven a working host driver is present —
  `install.sh` never installs or touches the GPU driver itself, the same
  boundary it already draws around not installing Docker's kernel
  dependencies.
- Writes a marker file mirroring `.portainer-enabled`:
  `.gpu-vaapi-enabled` or `.gpu-nvidia-enabled`, mutually exclusive. Unlike
  `.portainer-enabled` (which today is only ever created, never removed — a
  pre-existing gap, not a pattern to copy), `detect_gpu()` actively removes
  the other marker (or both, on `none`) each run, since this state is
  supposed to track current hardware, not accumulate.

## Overlay compose files

Mirrors the existing `compose.portainer.yml` pattern: an opt-in file merged
in via an extra `-f`, never a change to the base `compose.yml`, never a
second `-f` chain baked into the default install path.

`compose/compose.gpu-vaapi.yml`:

```yaml
services:
  jellyfin:
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "${GPU_RENDER_GID}"
  plex:
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "${GPU_RENDER_GID}"
```

`compose/compose.gpu-nvidia.yml`:

```yaml
services:
  jellyfin:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
  plex:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

**Why `group_add` matters and is easy to get wrong:** `/dev/dri/renderD128` is
owned `root:render` on the host. The hotio images run their app process as
`PUID:PGID`, which has no reason to already be a member of that group. Without
`group_add`, the device node is visible inside the container but every
`open()` on it fails with `EACCES` — hardware transcode falls back to
software with no visible error, and the only symptom is Jellyfin's own log
line. Passing the host's actual render-group GID in (via `stat`, not a
hardcoded `108` or similar) makes this correct regardless of what the group is
numbered on a given box.

## Wiring

- `compose()` in `scripts/lib/common.sh` gains the same conditional-append
  shape used for Portainer:

  ```bash
  if [[ -f "${REPO_ROOT}/.gpu-vaapi-enabled" ]]; then
    files+=(-f "${REPO_ROOT}/compose/compose.gpu-vaapi.yml")
  elif [[ -f "${REPO_ROOT}/.gpu-nvidia-enabled" ]]; then
    files+=(-f "${REPO_ROOT}/compose/compose.gpu-nvidia.yml")
  fi
  ```

  This means `update.sh` (and anything else that calls `compose()`) picks up
  the right overlay with no GPU-specific logic of its own — all the decision
  logic lives in `install.sh`'s `detect_gpu()`.
- `print_summary()` gains one line: `GPU acceleration: VAAPI (/dev/dri)` /
  `NVENC (Nvidia)` / `None detected`.
- `remove.sh` removes both marker files unconditionally (not gated behind
  `--purge` — deleting a marker file is not data loss, just resets detection
  for the next install).
- `docs/configuration.md` gains a GPU passthrough section: what gets
  detected, how to override with `--gpu=`, and the `group_add`/render-GID
  reasoning above.
- `.claude/CLAUDE.md`'s "Things that look like bugs but are not" section
  gains an entry for the `group_add` render-GID quirk, since a future reader
  hitting silent software-transcode fallback would otherwise re-debug this
  from scratch.

## Testing

- `shellcheck -x -P . scripts/*.sh scripts/lib/*.sh` after the `install.sh`
  and `common.sh` changes.
- `docker compose -f compose/compose.yml -f compose/compose.gpu-vaapi.yml
  config -q` and the `-nvidia` equivalent, to validate the overlay YAML
  merges cleanly.
- `--dry-run` install on a box with no GPU (`none` path, no overlay files
  touched).
- Real-hardware validation on the actual homelab box: confirm
  `/dev/dri/renderD128` passthrough, confirm `GPU_RENDER_GID` matches
  `stat -c '%g' /dev/dri/renderD128` inside the running container, and (if
  an Nvidia card is available to test against) confirm `nvidia-smi` runs
  inside the `jellyfin`/`plex` container.
