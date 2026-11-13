# amp-orbs

A self-hosted Amp orb provider backed by Docker Sandboxes Cloud (`sbx --cloud`). It runs one cloud sandbox per Amp thread, bootstraps Amp inside it, and preserves the sandbox disk across pauses.

## Files

| Path | Purpose |
| --- | --- |
| `dispatch.py` | Amp dispatch program. Handles `spawn`, `pause`, and `delete` jobs. |
| `image/Dockerfile` | Amp's orb image with the `agent` account Docker Sandboxes needs. You build it and push it to Docker Hub. |
| `service/install.sh` | Installs the provider service for macOS or Linux. |
| `service/install-macos.sh` | launchd installer. |
| `service/install-linux.sh` | systemd installer, one profile per instance. |
| `service/com.elianiva.amp-orb-provider.plist` | launchd template. |
| `service/amp-orb-provider@.service` | systemd template unit. |
| `state/` | Durable `ORB_ID` to sandbox mapping. |
| `logs/` | Provider logs on macOS; Linux uses the journal. |

## Orb image

Orbs boot from Amp's own orb image, `us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest`. It has the Amp CLI, agent-browser with Chrome, Node, Bun, Python, uv, gh, nix, and the tools for portals, Terminal, and Desktop.

Docker Sandboxes Cloud cannot boot that image directly, for two reasons:

- `sbx --cloud create --image-ref` pulls only from Docker Hub (`docker.io`) and `dhi.io`. Amp publishes its image on Google Artifact Registry.
- Docker Sandboxes runs commands as an `agent` account with uid 1000 and home `/home/agent`. Amp's image names uid 1000 `user`.

`image/Dockerfile` adds one layer on top of Amp's image. The layer adds `agent` as a second name for uid 1000, with the same groups and passwordless sudo, and keeps the sandbox proxy variables across sudo. It also installs earlyoom, described under VM limits. You push the result to Docker Hub:

```sh
docker buildx build --pull --platform linux/amd64 \
  -t docker.io/<user>/amp-orb:2026-11-13 -t docker.io/<user>/amp-orb:latest \
  --push image/
```

For arm64, add `--build-arg BASE_IMAGE=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb-arm64:latest` and `--platform linux/arm64`.

Put the full reference, with the `docker.io/` prefix, in `AMP_ORBS_IMAGE`. `sbx` does not add the registry for you. The dispatcher creates each sandbox with `sbx --cloud create --image-ref <image> --cpus N --memory M`, so one image serves every orb type.

Amp updates its image often. Rebuild with `--pull` to pick up a new version. A new tag only affects new orbs. Existing sandboxes keep their disk and do not pick up the new image. Pin a dated tag in `AMP_ORBS_IMAGE` if you want to roll out deliberately, then restart the provider after you change it.

### VM limits

Each spawn tunes the sandbox before it starts Amp:

- It raises `fs.inotify.max_user_watches` to 524288 and `max_user_instances` to 1024, so dev servers and file watchers do not run out of watches.
- It grows `/dev/shm` to 2 GiB. Docker's default is 64 MB, and Chrome tabs crash with "Target closed" when it fills.
- It raises the open-file limit to the hard limit.
- It starts `earlyoom`, which kills a process when available memory falls to 8%, and sends SIGKILL at 4%. On a VM without swap and without earlyoom, a browser that an agent leaves running can fill memory, and the kernel then thrashes for minutes before its own OOM killer acts. During that time Amp misses its heartbeats, and the thread reports "Orb reconnect attempts were exhausted". Amp's image protects Amp through systemd, which does not manage a Docker Sandboxes VM. earlyoom picks Chrome processes first. It kills `amp`, `sshd`, `dockerd`, or `containerd` only when no other process uses a meaningful amount of memory. A killed Chrome tab or browser fails that one command, and the orb stays connected.

Every step that the VM refuses is skipped. The bootstrap log records PID 1, the `/dev/shm` size, the file and inotify limits, the available memory, and whether earlyoom runs, for each spawn. earlyoom logs each kill to `/home/user/.amp-earlyoom.log`:

```sh
sbx --cloud exec <sandbox> bash -lc 'grep ^pid1= /home/user/.amp-bootstrap.log | tail -1; grep -A1 "low memory" /home/user/.amp-earlyoom.log | tail'
```

If earlyoom kills Chrome often, use a larger orb type.

## Orb types

The provider exposes five variants of the same image:

| Type | Shape |
| --- | --- |
| `micro` | 1 vCPU / 2 GiB |
| `small` | 2 vCPU / 4 GiB |
| `medium` | 4 vCPU / 8 GiB |
| `large` | 8 vCPU / 16 GiB |
| `xl` | 16 vCPU / 32 GiB |

Add `micro`, `small`, `medium`, `large`, and `xl` under **Orb types** in the provider's Edit dialog in Amp settings, and select `medium` as the default. The CLI has no command for this setting.

`ORB_TYPE` selects one of `micro`, `small`, `medium`, `large`, or `xl`. If it is unset, the dispatcher uses `medium`. If a project snapshot has a different CPU or memory shape, the dispatcher ignores it for that type, boots the image, and runs `.agents/setup`.

## Dispatch behavior

Amp runs `dispatch.py` once per job. The program reads `ORB_OPERATION`, `ORB_ID`, `ORB_IMAGE`, `ORB_SNAPSHOT_ID`, `ORB_TYPE`, `ORB_TOKEN`, and `AMP_URL`.

### spawn

1. Read `state/orbs/<hash>.json` and inspect the mapped sandbox.
2. If the mapping is missing or stale, list cloud sandboxes and match the name derived from `ORB_ID`. This prevents a second sandbox after a reboot or a lost state file.
3. Create the sandbox if it does not exist. It boots from a project snapshot when one exists, otherwise from `AMP_ORBS_IMAGE` with the type's CPU and memory.
4. Resume the sandbox if it is stopped. A running sandbox is a no-op.
5. Kill any previous `amp orb bootstrap` process and start a new one as `agent` with `HOME=/home/user` and this job's `ORB_TOKEN`. Tokens are single-use and expire after 15 minutes, so reusing a bootstrap from an earlier spawn is not valid.
6. Wait four seconds and fail the job if the bootstrap process is gone. The error includes the tail of `/home/user/.amp-bootstrap.log` from the sandbox.

`ORB_IMAGE` is logged and ignored. Docker Cloud only accepts images from Docker Hub (`docker.io`, `registry-1.docker.io`, `index.docker.io`) and `dhi.io`, and Amp's default image is on `us-central1-docker.pkg.dev`. `AMP_ORBS_IMAGE` replaces it with the Docker Hub copy that `image/Dockerfile` builds.

`ORB_TYPE` selects one of `micro`, `small`, `medium`, `large`, or `xl`. An unset value uses the default type, `medium`. Unknown values log a warning and use `medium`.

### pause

1. If `ORB_SNAPSHOT_ID` is set and the sandbox is running, save a cloud template named `amp-snap-<sha256(snapshot_id)[:16]>` with `--capture-mode disk`. An existing snapshot template is reused.
2. Stop the sandbox with `sbx --cloud stop`. Wait up to 150 seconds for the state to become `stopped`. If Docker is still stopping, the stop request is accepted and the job succeeds; the next spawn waits up to 220 seconds for the sandbox to settle before resuming it. The sandbox keeps its ID, disk, and memory.
3. If the snapshot save fails or times out, the sandbox is still stopped and the failure is logged. The provider never reports a snapshot that was not saved.

### delete

1. Wait for a `stopping` or `hibernating` sandbox to settle.
2. Run `sbx --cloud rm --force` and retry while Docker reports the hibernation workflow is still running.
3. Verify the sandbox is gone and remove the state file.

Snapshot templates are not deleted with the sandbox because Amp project snapshots can be shared by several threads. Remove them with `sbx --cloud template rm --force <name>` when they are no longer needed.

## Sandbox naming and lookup

`ORB_ID` is usually `amp-<thread id>`, which already satisfies Docker Cloud's name rules. The dispatcher uses it unchanged. If an `ORB_ID` contains invalid characters, is longer than 63 characters, or is the reserved name `default`, the dispatcher replaces invalid characters with hyphens and appends an eight-character hash of the original ID. The mapping stays deterministic, so lookup by name still works after a reboot.

The mapping file is `state/orbs/<sha256(ORB_ID)[:24]>.json`. It contains the original `ORB_ID`, the cloud sandbox ID, and the sandbox name. Writes are atomic, and each `ORB_ID` has a file lock so concurrent jobs cannot create duplicates.

## Expiration

Sandboxes are created with `--ttl 24h --on-timeout stop`, so Docker Cloud stops an expired sandbox instead of deleting it. Its default is one hour with a server-chosen action, which can delete a parked orb.

Docker documents that the TTL restarts when a stopped sandbox resumes, but not how long the new period is. The cloud API has a separate `resume_timeout` that `sbx` cannot set. `sbx --cloud ttl` refuses any extension that would end more than 24 hours after creation.

In case a resumed sandbox gets a shorter period than `--ttl`, after every spawn the dispatcher runs `sbx --cloud ttl +<gap>` to push the expiry to 24 hours after creation, less two minutes, and logs the result:

```text
sandbox expires at 2026-11-14T19:02:43Z, in 21.0h; Docker's 24h ceiling is 2026-11-14T19:04:43Z
```

A sandbox older than 24 hours cannot be extended. Each wake then lasts only the resume timeout, and the log says `WARNING this orb stops at ...`. When Docker stops the sandbox, Amp loses the orb until the next message sends a new spawn, which resumes it with its disk intact.

Check a sandbox's expiry with `sbx --cloud ttl <name> --json`.

## Register and run the provider

Create a provider token for each Amp account or workspace. On macOS, this saves it with your Amp credentials:

```sh
amp orb provider create melon-sbx
```

On Linux, pass the token to the installer as `AMP_ORB_PROVIDER_TOKEN`.

### macOS

```sh
cd ~/Development/amp-orbs
AMP_ORBS_IMAGE=docker.io/<user>/amp-orb:latest ./service/install.sh
```

The installer renders the launchd plist with this checkout's path and starts the service at login. Logs are in `logs/provider.err.log`.

### Linux

#### One-command setup

Run this as the service user on the Linux host:

```sh
cd ~/Development/amp-orbs
./service/setup-linux.sh docker-personal --provider Docker \
  --image docker.io/<user>/amp-orb:latest
```

The script prompts for the Docker Hub username unless you pass `--docker-user`, then for the Docker PAT. `--image` defaults to `docker.io/<docker-user>/amp-orb:latest`. The script fixes `sbx` local storage permissions, logs in the profile, installs the systemd service, and checks the provider process. The installer copies the Amp binary to `/usr/local/bin/amp` so SELinux can execute it, and sends the service logs to the journal.

The provider types cannot be set by the CLI. Confirm `micro`, `small`, `medium`, `large`, and `xl` in Amp Settings → Orbs → `Docker` → Edit.

#### Reset

Remove one profile:

```sh
./service/reset-linux.sh docker-personal
```

Remove every profile, the systemd unit, and `/usr/local/bin/amp`:

```sh
./service/reset-linux.sh --all
```

The script stops and disables the service, then removes the env file, state, logs, and the profile's `sbx` config. It does not delete the Amp provider, project snapshot templates, or cloud sandboxes. Remove test sandboxes with `sbx --cloud rm --force` and manage the provider in Settings → Orbs.

#### Manual setup

Log in `sbx` for the profile first. Use the same config directories that the installer uses:

```sh
DOCKER_CONFIG="$HOME/.docker/melon-sbx" \
XDG_CONFIG_HOME="$HOME/.config/melon-sbx" \
sbx login --username <docker-user> --password-stdin
```

Install one systemd instance:

```sh
sudo env AMP_ORB_PROVIDER_TOKEN='aop_live_...' \
  AMP_ORBS_IMAGE=docker.io/<user>/amp-orb:latest \
  ./service/install-linux.sh melon-sbx
```

The installer writes `/etc/amp-orbs/melon-sbx.env` with mode 600, renders `/etc/systemd/system/amp-orb-provider@.service`, runs `sbx --cloud diagnose` with the profile, and starts `amp-orb-provider@melon-sbx.service`. Logs go to `journalctl -u amp-orb-provider@melon-sbx`.

### Multiple accounts on one VPS

Create one provider token per Amp account or workspace and pass it to that profile's service as `AMP_ORB_PROVIDER_TOKEN`. The provider uses the token, so the host does not need a saved Amp account.

`sbx` has no `--profile` flag. Give each Docker account its own `DOCKER_CONFIG` and `XDG_CONFIG_HOME`. The Linux installer defaults to `$HOME/.docker/<profile>` and `$HOME/.config/<profile>`, and the preflight checks that login. If a particular `sbx` build still shares a session, run each profile as a separate OS user with `SERVICE_USER=<user>`.

Run one `amp-orb-provider@<profile>.service` per profile. Each instance has its own token, `sbx` config, state directory, journal logs, and image setting. Profiles can share one public image. Never run two providers for the same token. `--allow-multiple` is only for dispatch programs that share state.

#### Example: two profiles

This example uses the installer's default config directories, two provider tokens, and one public image.

```sh
export AMP_ORBS_IMAGE=docker.io/<user>/amp-orb:latest

# Profile 1: personal Docker account
export DOCKER_CONFIG="$HOME/.docker/melon-sbx"
export XDG_CONFIG_HOME="$HOME/.config/melon-sbx"
echo "$PERSONAL_DOCKER_PAT" | sbx login --username <personal-docker-user> --password-stdin
sudo env AMP_ORB_PROVIDER_TOKEN="$MELON_SBX_TOKEN" AMP_ORBS_IMAGE="$AMP_ORBS_IMAGE" \
  ./service/install-linux.sh melon-sbx

# Profile 2: work Docker account
export DOCKER_CONFIG="$HOME/.docker/work-sbx"
export XDG_CONFIG_HOME="$HOME/.config/work-sbx"
echo "$WORK_DOCKER_PAT" | sbx login --username <work-docker-user> --password-stdin
sudo env AMP_ORB_PROVIDER_TOKEN="$WORK_SBX_TOKEN" AMP_ORBS_IMAGE="$AMP_ORBS_IMAGE" \
  ./service/install-linux.sh work-sbx
```

Both services run at the same time:

```sh
systemctl status amp-orb-provider@melon-sbx.service
systemctl status amp-orb-provider@work-sbx.service
```

Their state directories are separate:

```text
state/melon-sbx/    state/work-sbx/
```

## Test a thread

```sh
amp -ox "Reply with OK." --orb-provider Docker
```

Continue the same thread to test resume:

```sh
amp threads continue <thread-id> -ox "Reply with RESUMED."
```

A thread's sandbox is named `amp-<thread id>`. Check it with `sbx --cloud ls` and `sbx --cloud inspect <name> --format json`.

## Troubleshooting

- Read `logs/provider.err.log` on macOS. On Linux, read `journalctl -u amp-orb-provider@<profile>`.
- Read the orb's bootstrap log inside the sandbox:
  `sbx --cloud exec <sandbox> bash -lc 'tail -50 /home/user/.amp-bootstrap.log'`
- Run `sbx --cloud diagnose` to check Docker sign-in, cloud connectivity, and account access.
- Check project snapshots with `sbx --cloud template ls` and `sbx --cloud template inspect <name> --format json`.
- If `create` fails to pull the image, check that `AMP_ORBS_IMAGE` has the `docker.io/` prefix and that the profile's Docker account can pull it.
- If a sandbox is stuck in `hibernating`, wait for the workflow to settle and retry `sbx --cloud rm --force`.

## Docker Cloud limitations

- Inline images are limited to Docker Hub and `dhi.io`. A Google Artifact Registry or GHCR image cannot be used directly.
- An image-ref sandbox takes no kits, so the dispatcher passes no agent name.
- `sbx exec` has no detach flag. The bootstrap uses `setsid` and a redirect, and the dispatcher verifies that the process survives.
- `sbx exec` does not support `--user`. Bootstrap runs as the image's default `agent` user, which has passwordless sudo.
- `stop` and `rm` are asynchronous. A sandbox can be `stopping` or `hibernating` for about a minute. The dispatcher polls and retries.
- Cloud templates can capture disk or memory plus disk. Project snapshots use disk capture, so files survive but processes do not.
- The cloud template list does not include descriptions, so snapshots use deterministic names and `template inspect`.
