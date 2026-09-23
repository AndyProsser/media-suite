# GPU Passthrough (VAAPI + NVENC) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect a host GPU (Intel/AMD via VAAPI, or Nvidia via NVENC) during
`install.sh` and wire the correct device passthrough into the `jellyfin` and
`plex` Compose services, so hardware transcoding works without any manual
Compose editing.

**Architecture:** `install.sh` gains a `detect_gpu()` phase that writes a
marker file (`.gpu-vaapi-enabled` or `.gpu-nvidia-enabled`) and, for VAAPI, a
`GPU_RENDER_GID` value in `.env`. `scripts/lib/common.sh`'s `compose()`
wrapper appends the matching opt-in overlay compose file
(`compose/compose.gpu-vaapi.yml` or `compose/compose.gpu-nvidia.yml`) when its
marker exists — the exact pattern already used for `compose.portainer.yml` /
`.portainer-enabled`. No changes to the base `compose.yml`.

**Tech Stack:** Bash (`set -euo pipefail`), Docker Compose YAML,
`stat`/`curl`/`gpg`/`apt-get` for detection and (Nvidia only) toolkit install.

**Spec:** [docs/superpowers/specs/2026-09-23-gpu-passthrough-design.md](../specs/2026-09-23-gpu-passthrough-design.md)

## Global Constraints

- `install.sh` may only depend on bash, coreutils, `openssl`, `curl` and `ip`
  for its own control-flow logic — detection uses `stat` (coreutils) and
  `/dev` existence checks, never `lspci`/`getent`. Installing
  `nvidia-container-toolkit` via `apt-get`/`curl`/`gpg` is the same category
  of action `install_docker()` already performs (adding a third-party apt
  repo), not a new dependency on the script's own logic.
- No `:latest` images, no new Compose profiles — GPU state is tracked by
  marker files exactly like `.portainer-enabled`, not `COMPOSE_PROFILES`.
- Never print a secret — not applicable here (no secrets involved), but
  generated/detected values (`GPU_RENDER_GID`) go straight into `.env` via
  `env_set`, never echoed as a bare value outside a labeled log line.
- Scripts stay shellcheck-clean
  (`shellcheck -x -P . scripts/*.sh scripts/lib/*.sh`) and support
  `--dry-run`. Any new state-changing command goes through `run`.
- Idempotence is not optional — `detect_gpu()` re-evaluates hardware on every
  run and corrects the marker files/`.env` to match, rather than skipping
  because "already configured" (unlike `choose_media_app`, this is a
  hardware fact, not a persisted user choice).
- This repo has no unit test framework. "Testing" per the repo's own
  convention (see CLAUDE.md) is: `shellcheck`, `bash -n` syntax checks,
  `docker compose config -q` for YAML validity, and manual `--dry-run` /
  real invocation with assertions on log output and file state. Every
  task's verification steps use these, not a mocked test suite.

---

### Task 1: `.env.example` and `.gitignore` scaffolding

**Files:**

- Modify: `.env.example`
- Modify: `.gitignore`

**Interfaces:**

- Produces: `GPU_RENDER_GID` env key, consumed by `compose/compose.gpu-vaapi.yml`
  (Task 2) and written by `install.sh`'s `configure_vaapi()` (Task 4).

- [ ] **Step 1: Add the `GPU_RENDER_GID` key to `.env.example`**

Add a new section right after `## Jellyfin` (after the
`JELLYFIN_PUBLISHED_SERVER_URL=` line, before `## SMB file share`):

```text
# ── GPU acceleration ─────────────────────────── [auto] ────────────
# Backend detected by install.sh: vaapi | nvidia | none. Override with
# --gpu=vaapi|nvidia|none. See docs/configuration.md#gpu-acceleration.
#
# GPU_RENDER_GID is only used for vaapi: the host's /dev/dri render
# node's group ownership, so the container process (running as
# PUID:PGID) can actually open the device. Left blank until detected.
GPU_RENDER_GID=
```

- [ ] **Step 2: Add the GPU marker files to `.gitignore`**

Find this block:

```text
# install.sh writes this marker when --with-portainer is used.
.portainer-enabled
```

Change it to:

```text
# install.sh writes these markers when a GPU backend is detected/forced.
.portainer-enabled
.gpu-vaapi-enabled
.gpu-nvidia-enabled
```

- [ ] **Step 3: Verify**

Run:

```bash
grep -n 'GPU_RENDER_GID' .env.example && grep -n 'gpu-.*-enabled' .gitignore
```

Expected: both greps print matching lines, no errors.

- [ ] **Step 4: Commit**

```bash
git add .env.example .gitignore
git commit -m "$(cat <<'EOF'
Add GPU_RENDER_GID env key and GPU marker files to .gitignore

Scaffolding for GPU passthrough — see docs/superpowers/specs/2026-09-23-gpu-passthrough-design.md.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Overlay compose files + `compose()` wiring

**Files:**

- Create: `compose/compose.gpu-vaapi.yml`
- Create: `compose/compose.gpu-nvidia.yml`
- Modify: `scripts/lib/common.sh:174-185` (the `compose()` function)

**Interfaces:**

- Consumes: `GPU_RENDER_GID` from `.env` (Task 1).
- Produces: `compose()` now appends the right overlay based on
  `.gpu-vaapi-enabled` / `.gpu-nvidia-enabled` marker files (consumed by
  `install.sh`'s `deploy_stack`, `update.sh`, `remove.sh` — all of which
  already call `compose()`, so no caller-side changes needed).

- [ ] **Step 1: Create `compose/compose.gpu-vaapi.yml`**

```yaml
# ===================================================================
#  VAAPI GPU passthrough — Intel iGPU (i915) or AMD GPU (amdgpu)
# ===================================================================
#  Opt-in overlay, mirroring compose.portainer.yml: install.sh writes
#  .gpu-vaapi-enabled when it detects (or is told via --gpu=vaapi) a
#  render node at /dev/dri/renderD128, and common.sh's compose()
#  appends this file whenever that marker exists.
#
#  Both Intel and AMD expose the same VAAPI device node pattern, so
#  there is exactly one overlay for both vendors — no vendor detection
#  needed, only "does a render node exist".
#
#  group_add is not optional: /dev/dri/renderD128 is owned root:render
#  on the host, and the hotio images' app user (PUID:PGID) has no
#  reason to already be in that group. Without it, the device is
#  visible inside the container but every open() on it fails EACCES,
#  and hardware transcode falls back to software with no visible
#  error anywhere except Jellyfin's own log. GPU_RENDER_GID is written
#  to .env by install.sh from `stat -c '%g' /dev/dri/renderD128`, so
#  this is always correct regardless of what the group is numbered on
#  a given box.
# ===================================================================

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

- [ ] **Step 2: Create `compose/compose.gpu-nvidia.yml`**

```yaml
# ===================================================================
#  NVENC GPU passthrough — Nvidia, via nvidia-container-toolkit
# ===================================================================
#  Opt-in overlay, mirroring compose.portainer.yml: install.sh writes
#  .gpu-nvidia-enabled when it detects (or is told via --gpu=nvidia) a
#  working nvidia-smi, installs nvidia-container-toolkit if it isn't
#  already present, and common.sh's compose() appends this file
#  whenever that marker exists.
#
#  Nvidia doesn't expose /dev/dri — the driver stack needs a GPU
#  reservation instead of a device bind mount, which is why this is a
#  separate overlay rather than a branch inside compose.gpu-vaapi.yml.
# ===================================================================

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

- [ ] **Step 3: Verify both files are valid YAML merges against the base compose file**

Run:

```bash
GPU_RENDER_GID=44 docker compose -f compose/compose.yml -f compose/compose.gpu-vaapi.yml config -q
docker compose -f compose/compose.yml -f compose/compose.gpu-nvidia.yml config -q
```

Expected: both exit 0 with no output (a `-q` config check is silent on
success).

- [ ] **Step 4: Modify `compose()` in `scripts/lib/common.sh`**

Old:

```bash
compose() {
  local -a files=(-f "${REPO_ROOT}/compose/compose.yml")
  if [[ "${WITH_PORTAINER}" == "1" || -f "${REPO_ROOT}/.portainer-enabled" ]]; then
    files+=(-f "${REPO_ROOT}/compose/compose.portainer.yml")
  fi
  docker compose \
    --project-directory "$REPO_ROOT" \
    --env-file "$ENV_FILE" \
    "${files[@]}" "$@"
}
```

New:

```bash
compose() {
  local -a files=(-f "${REPO_ROOT}/compose/compose.yml")
  if [[ "${WITH_PORTAINER}" == "1" || -f "${REPO_ROOT}/.portainer-enabled" ]]; then
    files+=(-f "${REPO_ROOT}/compose/compose.portainer.yml")
  fi
  if [[ -f "${REPO_ROOT}/.gpu-vaapi-enabled" ]]; then
    files+=(-f "${REPO_ROOT}/compose/compose.gpu-vaapi.yml")
  elif [[ -f "${REPO_ROOT}/.gpu-nvidia-enabled" ]]; then
    files+=(-f "${REPO_ROOT}/compose/compose.gpu-nvidia.yml")
  fi
  docker compose \
    --project-directory "$REPO_ROOT" \
    --env-file "$ENV_FILE" \
    "${files[@]}" "$@"
}
```

- [ ] **Step 5: Verify `compose()` picks up the overlay via the marker file**

This repo has no `.env` checked in, so build a throwaway one for this check:

```bash
cd /home/andy/Development/media-suite
cp .env.example /tmp/gpu-test.env
echo 'GPU_RENDER_GID=44' >> /tmp/gpu-test.env
touch .gpu-vaapi-enabled
ENV_FILE=/tmp/gpu-test.env bash -c '
  source scripts/lib/common.sh
  compose config --services
'
rm -f .gpu-vaapi-enabled /tmp/gpu-test.env
```

Expected: the service list includes `jellyfin`, `plex`, etc. with no error
(confirms the overlay merged cleanly with the marker present). Then re-run
without `touch .gpu-vaapi-enabled` and confirm it still succeeds (overlay
correctly omitted when the marker is absent).

- [ ] **Step 6: shellcheck**

Run: `shellcheck -x -P . scripts/lib/common.sh`
Expected: no warnings.

- [ ] **Step 7: Commit**

```bash
git add compose/compose.gpu-vaapi.yml compose/compose.gpu-nvidia.yml scripts/lib/common.sh
git commit -m "$(cat <<'EOF'
Add VAAPI/Nvidia GPU overlay compose files and wire them into compose()

Mirrors the existing compose.portainer.yml pattern: an opt-in overlay
file, appended only when its marker file exists, never a change to
the base compose.yml.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `--gpu` CLI flag on `install.sh`

**Files:**

- Modify: `scripts/install.sh` (globals block, `usage()`, `parse_args()`)

**Interfaces:**

- Produces: `GPU_TYPE` global variable — `""` (auto-detect), `"vaapi"`,
  `"nvidia"`, or `"none"` after `parse_args` runs. Consumed by `detect_gpu()`
  (Task 4/5).

- [ ] **Step 1: Add the `GPU_TYPE` global**

Old (in the globals block):

```bash
MEDIA_APP=""
AUTH_MODE=""
```

New:

```bash
MEDIA_APP=""
AUTH_MODE=""
GPU_TYPE=""
```

- [ ] **Step 2: Document the flag in `usage()`**

Old:

```text
  --auth=sso|none            sso  : one login (Tinyauth) for the whole admin
                                    surface, including the Traefik dashboard.
                             none : no login on the LAN for the arr apps and
                                    qBittorrent. Prompted if omitted.
  --config-dir=PATH          Application config/databases. Must be block
```

New:

```text
  --auth=sso|none            sso  : one login (Tinyauth) for the whole admin
                                    surface, including the Traefik dashboard.
                             none : no login on the LAN for the arr apps and
                                    qBittorrent. Prompted if omitted.
  --gpu=vaapi|nvidia|none    Hardware transcode backend for Jellyfin/Plex.
                             Auto-detected if omitted: vaapi if /dev/dri
                             exists, else nvidia if nvidia-smi works, else
                             none. nvidia additionally installs
                             nvidia-container-toolkit if it's missing.
  --config-dir=PATH          Application config/databases. Must be block
```

- [ ] **Step 3: Parse and validate the flag**

Old (in `parse_args()`):

```bash
      --media-app=*)        MEDIA_APP="${1#*=}" ;;
      --auth=*)             AUTH_MODE="${1#*=}" ;;
      --media-app)          MEDIA_APP="${2:-}"; shift ;;
```

New:

```bash
      --media-app=*)        MEDIA_APP="${1#*=}" ;;
      --auth=*)             AUTH_MODE="${1#*=}" ;;
      --gpu=*)              GPU_TYPE="${1#*=}" ;;
      --media-app)          MEDIA_APP="${2:-}"; shift ;;
```

Old (validation, right after the existing `AUTH_MODE` check):

```bash
  if [[ -n "$AUTH_MODE" && "$AUTH_MODE" != "sso" && "$AUTH_MODE" != "none" ]]; then
    die "--auth must be 'sso' or 'none', got '${AUTH_MODE}'"
  fi
}
```

New:

```bash
  if [[ -n "$AUTH_MODE" && "$AUTH_MODE" != "sso" && "$AUTH_MODE" != "none" ]]; then
    die "--auth must be 'sso' or 'none', got '${AUTH_MODE}'"
  fi
  if [[ -n "$GPU_TYPE" && "$GPU_TYPE" != "vaapi" && "$GPU_TYPE" != "nvidia" && "$GPU_TYPE" != "none" ]]; then
    die "--gpu must be 'vaapi', 'nvidia' or 'none', got '${GPU_TYPE}'"
  fi
}
```

- [ ] **Step 4: Verify the flag parses and validates**

Run:

```bash
bash -n scripts/install.sh
scripts/install.sh --gpu=bogus --dry-run --non-interactive 2>&1 | tail -3
```

Expected: `bash -n` prints nothing (syntax OK). The second command dies
with `--gpu must be 'vaapi', 'nvidia' or 'none', got 'bogus'` and a
non-zero exit.

Run:

```bash
scripts/install.sh --gpu=none --dry-run --non-interactive >/dev/null; echo "exit: $?"
```

Expected: `exit: 0` (a dry run with a valid value gets past `parse_args` —
`detect_gpu` doesn't exist yet so this only proves the flag itself is
accepted; full behavior is checked in Task 4/5).

- [ ] **Step 5: shellcheck**

Run: `shellcheck -x -P . scripts/install.sh`
Expected: no warnings.

- [ ] **Step 6: Commit**

```bash
git add scripts/install.sh
git commit -m "$(cat <<'EOF'
Add --gpu=vaapi|nvidia|none flag to install.sh

Same validated-flag shape as --media-app/--auth. detect_gpu(), added
next, is what actually acts on this.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `detect_gpu()` — VAAPI path and the `none` path

**Files:**

- Modify: `scripts/install.sh` (new functions, placed after
  `choose_media_app()` and before `sync_env_schema()`)

**Interfaces:**

- Consumes: `GPU_TYPE` (Task 3), `env_set`/`run`/`log_*`/`die` (`common.sh`).
- Produces: `detect_gpu()` function; `configure_vaapi()` helper. Task 5 adds
  `configure_nvidia()` and wires it into the same `case` statement — written
  now as a stub `none)` fallthrough so this task's `detect_gpu()` is already
  complete and callable on its own (Task 5 only adds the `nvidia)` branch, it
  doesn't restructure this function).

- [ ] **Step 1: Add `detect_gpu()` and `configure_vaapi()` after `choose_media_app()`**

Insert immediately after the closing `}` of `choose_media_app()` (before the
`# Adds any setting .env.example defines...` comment that precedes
`sync_env_schema()`):

```bash
# ── 4b. GPU acceleration ─────────────────────────────────────────────
#  Not a persisted user choice like MEDIA_APP/AUTH_MODE — this tracks a
#  hardware fact, so it re-evaluates on every run rather than skipping
#  when "already configured". Re-plugging (or removing) a GPU is picked
#  up on the next install.sh run with no flag needed.
detect_gpu() {
  log_step "GPU acceleration"

  if [[ -n "$GPU_TYPE" ]]; then
    log_info "GPU backend forced: ${GPU_TYPE}"
  elif [[ -e /dev/dri/renderD128 ]]; then
    GPU_TYPE="vaapi"
  elif have_cmd nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    GPU_TYPE="nvidia"
  else
    GPU_TYPE="none"
  fi

  case "$GPU_TYPE" in
    vaapi)  configure_vaapi ;;
    nvidia) configure_nvidia ;;
    none)
      run rm -f "${REPO_ROOT}/.gpu-vaapi-enabled" "${REPO_ROOT}/.gpu-nvidia-enabled"
      log_skip "No GPU detected"
      ;;
  esac
}

# VAAPI covers both Intel (i915) and AMD (amdgpu) — both expose the same
# /dev/dri/renderD128 device node, so there is no vendor branch here.
configure_vaapi() {
  if [[ ! -e /dev/dri/renderD128 ]]; then
    die "--gpu=vaapi was forced but /dev/dri/renderD128 does not exist on this host."
  fi
  local gid
  gid="$(stat -c '%g' /dev/dri/renderD128)"
  env_set GPU_RENDER_GID "$gid"
  run touch "${REPO_ROOT}/.gpu-vaapi-enabled"
  run rm -f "${REPO_ROOT}/.gpu-nvidia-enabled"
  log_applied "GPU acceleration: VAAPI (/dev/dri, render group ${gid})"
}
```

Note: `configure_nvidia` is referenced but not yet defined — that's fine for
this step (Task 5 defines it before this code is ever exercised on the
`nvidia` path), but it means Step 3 below must only exercise the `vaapi` and
`none` paths, not `nvidia`.

- [ ] **Step 2: Verify `bash -n` still passes despite the forward reference**

Run: `bash -n scripts/install.sh`
Expected: no output (a forward reference to an undefined function is fine
for bash's parser — it's only resolved at call time).

- [ ] **Step 3: Verify the `none` path**

Run:

```bash
cd /home/andy/Development/media-suite
rm -f .gpu-vaapi-enabled .gpu-nvidia-enabled
bash -c '
  source scripts/lib/common.sh
  source <(sed -n "/^detect_gpu()/,/^}/p; /^configure_vaapi()/,/^}/p" scripts/install.sh)
  GPU_TYPE=none
  detect_gpu
'
ls -la .gpu-vaapi-enabled .gpu-nvidia-enabled 2>&1
```

Expected: prints the `GPU acceleration` step header, then a
`No GPU detected (already done)`-style skip line (via `log_skip`), and the
final `ls` reports both files as "No such file or directory".

- [ ] **Step 4: Verify the forced `vaapi` path against a fake device**

Real `/dev/dri/renderD128` may or may not exist on this dev machine — this
step proves the guard clause deterministically regardless:

```bash
cd /home/andy/Development/media-suite
cp .env.example /tmp/gpu-test.env
bash -c '
  source scripts/lib/common.sh
  source <(sed -n "/^detect_gpu()/,/^}/p; /^configure_vaapi()/,/^}/p" scripts/install.sh)
  ENV_FILE=/tmp/gpu-test.env
  GPU_TYPE=vaapi
  configure_vaapi 2>&1; echo "exit: $?"
'
rm -f /tmp/gpu-test.env
```

Expected: since `/dev/dri/renderD128` almost certainly doesn't exist on a
non-GPU dev box, this prints the `die` message
`--gpu=vaapi was forced but /dev/dri/renderD128 does not exist on this host.`
and a non-zero exit — confirming the guard works. **If this dev machine
actually has `/dev/dri/renderD128`** (e.g. it has an iGPU), expect instead
`GPU acceleration: VAAPI (/dev/dri, render group <N>)` and confirm
`grep GPU_RENDER_GID /tmp/gpu-test.env` shows a numeric value matching
`stat -c '%g' /dev/dri/renderD128`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -x -P . scripts/install.sh`
Expected: no warnings. (If shellcheck flags the forward reference to
`configure_nvidia`, that's expected to resolve once Task 5 adds it — do not
suppress the warning, just confirm no *other* new warnings appear from this
task's code.)

- [ ] **Step 6: Commit**

```bash
git add scripts/install.sh
git commit -m "$(cat <<'EOF'
Add detect_gpu() with the VAAPI and none paths

VAAPI covers both Intel and AMD via the same /dev/dri render node, so
there's one code path for both vendors. GPU_RENDER_GID is read with
stat, not getent, to stay inside install.sh's coreutils-only budget.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `configure_nvidia()` — Nvidia detection + `nvidia-container-toolkit` auto-install

**Files:**

- Modify: `scripts/install.sh` (add `configure_nvidia()` after
  `configure_vaapi()`)

**Interfaces:**

- Consumes: same as Task 4 (`run`, `have_cmd`, `log_*`, `die`).
- Produces: `configure_nvidia()`, completing the forward reference from
  Task 4's `detect_gpu()`.

- [ ] **Step 1: Add `configure_nvidia()` right after `configure_vaapi()`**

```bash
# Only auto-installs the userspace toolkit that bridges an ALREADY
# INSTALLED host Nvidia driver into containers — this never touches
# the GPU driver itself, the same boundary install_docker() draws
# around not installing Docker's own kernel dependencies.
configure_nvidia() {
  have_cmd nvidia-smi || die "--gpu=nvidia was forced but nvidia-smi is not available on this host. Install the Nvidia driver first."
  nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is present but failed to run. Check the Nvidia driver installation."

  if have_cmd nvidia-ctk; then
    log_skip "nvidia-container-toolkit is already installed"
  else
    log_info "Installing nvidia-container-toolkit..."
    run sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/nvidia-container-toolkit.gpg ]]; then
      run bash -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor | sudo tee /etc/apt/keyrings/nvidia-container-toolkit.gpg >/dev/null'
    fi
    if [[ ! -f /etc/apt/sources.list.d/nvidia-container-toolkit.list ]]; then
      run bash -c 'curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed "s#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#g" \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null'
    fi
    run sudo apt-get update -qq
    run sudo apt-get install -y -qq nvidia-container-toolkit
    run sudo nvidia-ctk runtime configure --runtime=docker
    run sudo systemctl restart docker
    log_success "nvidia-container-toolkit installed and configured"
  fi

  run touch "${REPO_ROOT}/.gpu-nvidia-enabled"
  run rm -f "${REPO_ROOT}/.gpu-vaapi-enabled"
  log_applied "GPU acceleration: NVENC (Nvidia)"
}
```

- [ ] **Step 2: Verify `bash -n` and that the forward reference from Task 4 is now resolved**

Run: `bash -n scripts/install.sh`
Expected: no output.

Run:

```bash
grep -n "^configure_nvidia()" scripts/install.sh
grep -n "configure_nvidia" scripts/install.sh
```

Expected: `configure_nvidia` is both defined once and called once (from
`detect_gpu()`'s `case` statement).

- [ ] **Step 3: Verify the "driver missing" guard**

On this dev box (almost certainly no Nvidia driver present):

```bash
cd /home/andy/Development/media-suite
bash -c '
  source scripts/lib/common.sh
  source <(sed -n "/^configure_nvidia()/,/^}/p" scripts/install.sh)
  configure_nvidia 2>&1; echo "exit: $?"
'
```

Expected: dies with
`--gpu=nvidia was forced but nvidia-smi is not available on this host. Install the Nvidia driver first.`
(or the `nvidia-smi failed to run` message if the binary exists but errors),
non-zero exit. **If this box genuinely has a working Nvidia driver**,
expect it to proceed to the apt-repo/install branch instead — re-run with
`DRY_RUN=1` in that case to confirm it only *prints* the install commands
rather than executing them.

- [ ] **Step 4: shellcheck**

Run: `shellcheck -x -P . scripts/install.sh`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh
git commit -m "$(cat <<'EOF'
Add configure_nvidia(): NVENC path for detect_gpu()

Auto-installs nvidia-container-toolkit via NVIDIA's official apt repo
when nvidia-smi already proves a working host driver — the same
third-party-repo pattern install_docker() uses for Docker's own repo.
Never touches the GPU driver itself.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Wire `detect_gpu()` into `main()` and `print_summary()`

**Files:**

- Modify: `scripts/install.sh:1243-1265` (`main()`)
- Modify: `scripts/install.sh:1188-1239` (`print_summary()`)

**Interfaces:**

- Consumes: `detect_gpu()` (Task 4/5), `GPU_TYPE` (set by `detect_gpu()` if
  not already forced).

- [ ] **Step 1: Call `detect_gpu` in `main()`, right after `configure_env`**

**Correction from the original plan review:** `detect_gpu`'s
`configure_vaapi`/`configure_nvidia` call `env_set`, which writes straight to
`$ENV_FILE`. Calling it before `configure_env` runs is a bug — `.env`
doesn't exist yet at that point (`configure_env` is what creates it from
`.env.example`, or swaps `$ENV_FILE` to a dry-run temp copy), so an early
`env_set` would either create a malformed real `.env` containing only
`GPU_RENDER_GID=` ahead of `configure_env`'s own copy step, or — under
`--dry-run` — write to the *real* `.env` path since the dry-run temp-file
swap hasn't happened yet, breaking the "dry-run changes nothing" guarantee.
`detect_gpu` must run after `configure_env`.

Old:

```bash
  preflight
  install_docker
  verify_docker_access
  choose_media_app
  choose_auth_mode
  configure_env
  collect_plex_claim
```

New:

```bash
  preflight
  install_docker
  verify_docker_access
  choose_media_app
  choose_auth_mode
  configure_env
  detect_gpu
  collect_plex_claim
```

- [ ] **Step 2: Add a GPU line to `print_summary()`**

Old:

```bash
  (( WITH_PORTAINER ))  && printf '  %-14s %s\n' "Portainer"   "https://${ip}/docker"
  (( WITH_SMB ))        && printf '  %-14s %s\n' "SMB share"   "\\\\${ip}\\MediaShare"
```

New:

```bash
  (( WITH_PORTAINER ))  && printf '  %-14s %s\n' "Portainer"   "https://${ip}/docker"
  (( WITH_SMB ))        && printf '  %-14s %s\n' "SMB share"   "\\\\${ip}\\MediaShare"
  case "$GPU_TYPE" in
    vaapi)  printf '  %-14s %s\n' "GPU accel" "VAAPI (/dev/dri)" ;;
    nvidia) printf '  %-14s %s\n' "GPU accel" "NVENC (Nvidia)" ;;
    *)      printf '  %-14s %s\n' "GPU accel" "none detected" ;;
  esac
```

- [ ] **Step 3: Verify with a full dry run**

Run:

```bash
cd /home/andy/Development/media-suite
scripts/install.sh --gpu=none --dry-run --non-interactive --media-app=jellyfin --auth=none 2>&1 | grep -A1 "GPU acceleration"
scripts/install.sh --gpu=none --dry-run --non-interactive --media-app=jellyfin --auth=none 2>&1 | grep "GPU accel"
```

Expected: first command shows the `GPU acceleration` step header followed
by the "No GPU detected" skip line; second shows
`GPU accel      none detected` in the summary. Exit code 0 for both
invocations.

- [ ] **Step 4: shellcheck**

Run: `shellcheck -x -P . scripts/install.sh`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add scripts/install.sh
git commit -m "$(cat <<'EOF'
Wire detect_gpu() into install.sh's main() and print_summary()

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `remove.sh` marker cleanup

**Files:**

- Modify: `scripts/remove.sh` (`remove_network()` area / `main()`)

**Interfaces:**

- Consumes: nothing new.
- Produces: `.gpu-vaapi-enabled`/`.gpu-nvidia-enabled` are removed on any
  `remove.sh` run (not gated behind `--purge` — deleting a marker file is
  not data loss, it only resets detection for the next `install.sh` run).

- [ ] **Step 1: Add a `remove_gpu_markers()` function**

Insert after `remove_network()`:

```bash
remove_gpu_markers() {
  [[ -f "${REPO_ROOT}/.gpu-vaapi-enabled" || -f "${REPO_ROOT}/.gpu-nvidia-enabled" ]] || return 0
  run rm -f "${REPO_ROOT}/.gpu-vaapi-enabled" "${REPO_ROOT}/.gpu-nvidia-enabled"
  log_applied "Removed GPU detection markers (re-detected on next install.sh run)"
}
```

- [ ] **Step 2: Call it from `main()`**

Old:

```bash
  remove_stack
  purge_data
  purge_media
  purge_smb
  remove_network
```

New:

```bash
  remove_stack
  purge_data
  purge_media
  purge_smb
  remove_network
  remove_gpu_markers
```

- [ ] **Step 3: Verify**

Run:

```bash
cd /home/andy/Development/media-suite
touch .gpu-vaapi-enabled
cp .env.example /tmp/gpu-test.env
ENV_FILE=/tmp/gpu-test.env DRY_RUN=1 bash -c '
  source scripts/lib/common.sh
  source <(sed -n "/^remove_gpu_markers()/,/^}/p" scripts/remove.sh)
  remove_gpu_markers
'
ls .gpu-vaapi-enabled
rm -f .gpu-vaapi-enabled /tmp/gpu-test.env
```

Expected: under `DRY_RUN=1`, `run` only logs `[dry-run] rm -f ...` and does
not delete — the final `ls` still finds `.gpu-vaapi-enabled`. Re-run without
`DRY_RUN=1` and confirm the file is actually removed.

- [ ] **Step 4: shellcheck**

Run: `shellcheck -x -P . scripts/remove.sh`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add scripts/remove.sh
git commit -m "$(cat <<'EOF'
Clean up GPU marker files on remove.sh

Not purge-gated: removing a marker file isn't data loss, it just
resets GPU detection for the next install.sh run.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Documentation — `docs/configuration.md` and `CLAUDE.md`

**Files:**

- Modify: `docs/configuration.md` (new section after `## Jellyfin`, before
  `## Seerr`)
- Modify: `.claude/CLAUDE.md` ("Things that look like bugs but are not"
  section)

**Interfaces:** None (documentation only).

- [ ] **Step 1: Add a GPU acceleration section to `docs/configuration.md`**

Insert after the `## Jellyfin` section (after its table, before `## Seerr`):

```markdown
## GPU acceleration

| Variable         | Detection                           | Purpose                                                                          |
| ---------------- | ------------------------------------ | --------------------------------------------------------------------------------- |
| `GPU_RENDER_GID` | `stat -c '%g' /dev/dri/renderD128`  | VAAPI only — the host's render-group GID, so the container can open the device.  |

`install.sh` detects a GPU on every run (it tracks hardware, not a stored
choice, so re-plugging or removing a GPU is picked up the next time you run
it) and wires the right passthrough into both `jellyfin` and `plex`:

1. `/dev/dri/renderD128` exists → **VAAPI**. Covers both Intel (`i915`) and
   AMD (`amdgpu`) — they expose the same device node pattern, so there is
   one code path for both vendors, not two.
2. Otherwise, `nvidia-smi` works → **NVENC**. If `nvidia-container-toolkit`
   isn't already installed, `install.sh` installs it from NVIDIA's official
   apt repo and configures the Docker runtime — this only happens once
   `nvidia-smi` has already proven a working host driver is present;
   `install.sh` never installs or touches the GPU driver itself.
3. Neither → no hardware transcode; both apps fall back to software.

Override auto-detection with `--gpu=vaapi|nvidia|none`.

Out of scope, because none of them apply to a Linux Docker homelab host:
AMD AMF (Windows-only), Rockchip MPP (ARM SBC hardware), Apple VideoToolbox
and V4L2. These four still appear in Jellyfin's own hardware-acceleration
dropdown because that list is identical across every platform Jellyfin runs
on — it is not a live readout of what this host supports.

Once passthrough is wired, still pick the specific backend inside each
app's own transcoding settings (Jellyfin: **Dashboard → Playback**; Plex:
**Settings → Transcoder**, requires an active Plex Pass) — `install.sh`
only makes the hardware reachable, it does not change either app's
transcoding preference.
```

- [ ] **Step 2: Add an entry to `.claude/CLAUDE.md`'s "Things that look like bugs but are not" section**

Add this bullet to the end of that list:

```markdown
- The VAAPI GPU overlay (`compose/compose.gpu-vaapi.yml`) sets `group_add`
  from a `GPU_RENDER_GID` env value read with
  `stat -c '%g' /dev/dri/renderD128`, not a hardcoded GID like `108` or
  `44`. The render group's number varies by distro and by what else is
  installed — hardcoding it works on the box it was tested on and silently
  breaks hardware transcode (falls back to software, no error) on any
  other box.
```

- [ ] **Step 3: Verify formatting**

Run:

```bash
grep -n "GPU acceleration" docs/configuration.md && grep -n "GPU_RENDER_GID" .claude/CLAUDE.md
```

Expected: both greps find matches, confirming the sections landed. Then
run this repo's markdown lint locally, since CI enforces it on every
`*.md` file:

```bash
npx --yes markdownlint-cli2 "docs/configuration.md" ".claude/CLAUDE.md"
```

Expected: `Summary: 0 issues`.

- [ ] **Step 4: Commit**

```bash
git add docs/configuration.md .claude/CLAUDE.md
git commit -m "$(cat <<'EOF'
Document GPU passthrough in configuration.md and CLAUDE.md

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: End-to-end validation

**Files:** None created/modified — verification only.

- [ ] **Step 1: Full shellcheck pass**

Run: `shellcheck -x -P . scripts/*.sh scripts/lib/*.sh`
Expected: no warnings anywhere (not just the files touched by this plan —
confirms nothing upstream regressed).

- [ ] **Step 2: Compose config validation for every combination**

```bash
cd /home/andy/Development/media-suite
docker compose -f compose/compose.yml config -q
GPU_RENDER_GID=44 docker compose -f compose/compose.yml -f compose/compose.gpu-vaapi.yml config -q
docker compose -f compose/compose.yml -f compose/compose.gpu-nvidia.yml config -q
docker compose -f compose/compose.yml -f compose/compose.portainer.yml -f compose/compose.gpu-vaapi.yml config -q
```

Expected: all four exit 0 silently — the base file alone, each GPU overlay
alone, and a GPU overlay stacked with Portainer's (confirming the two
opt-in overlays don't conflict with each other).

- [ ] **Step 3: Full dry-run install for each `--gpu` value**

```bash
for g in none vaapi nvidia; do
  echo "=== --gpu=$g ==="
  scripts/install.sh --gpu="$g" --dry-run --non-interactive --media-app=jellyfin --auth=none
  echo "exit: $?"
done
```

Expected: `none` completes cleanly (exit 0). `vaapi` and `nvidia` are
expected to `die` on this dev box specifically because the underlying
hardware/driver genuinely isn't present (that's the correct, intended
behavior verified in Tasks 4/5) — confirm the die message names the right
missing prerequisite in each case, and that no partial `.env`/marker-file
state was left behind by a failed forced run:

```bash
git status --porcelain .env .gpu-vaapi-enabled .gpu-nvidia-enabled 2>/dev/null
```

Expected: no output (none of these are ever committed, and a `die` on the
hardware guard happens before any `env_set`/`touch` call in
`configure_vaapi`/`configure_nvidia`).

- [ ] **Step 4: Confirm idempotence — run the `none` dry-run twice**

```bash
scripts/install.sh --gpu=none --dry-run --non-interactive --media-app=jellyfin --auth=none >/tmp/run1.log
scripts/install.sh --gpu=none --dry-run --non-interactive --media-app=jellyfin --auth=none >/tmp/run2.log
diff /tmp/run1.log /tmp/run2.log
rm -f /tmp/run1.log /tmp/run2.log
```

Expected: no diff — the phase produces identical output on a repeat run,
confirming `detect_gpu()` doesn't accumulate state or drift between runs.

- [ ] **Step 5: Full markdown lint pass**

Run: `npx --yes markdownlint-cli2 "**/*.md"`
Expected: `Summary: 0 issues` — confirms the plan/spec docs and the
documentation changes from Task 8 are all clean under this repo's actual
CI lint config, not just spot-checked files.

- [ ] **Step 6: Report results**

Summarize (in chat, not a new file): which checks passed, and whether this
dev box happened to have real VAAPI or Nvidia hardware to test the success
path against (most homelab dev boxes won't — if so, note that the
success-path device/group_add/nvidia-toolkit-install logic is verified by
code review and the guard-clause tests only, and flag that real-hardware
validation on Andy's actual media-suite host is the remaining step before
this is fully proven end-to-end).
