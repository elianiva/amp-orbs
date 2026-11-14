# amp-orbs

A self-hosted Amp orb provider backed by Docker Sandboxes Cloud (`sbx --cloud`). It runs one cloud sandbox per Amp thread, bootstraps Amp inside it, and preserves the sandbox disk across pauses.

## Files

| Path | Purpose |
| --- | --- |
| `dispatch.py` | Amp dispatch program. Handles `spawn`, `pause`, and `delete` jobs. |
| `service/amp-orb-dispatch.py` | Launcher template that loads a profile's job env before running `dispatch.py`. |
| `image/Dockerfile` | Amp's orb image with the `agent` account Docker Sandboxes needs. You build it and push it to Docker Hub. |
| `service/install.sh` | Installs the provider service for macOS or Linux. |
| `service/install-macos.sh` | launchd installer. |
| `service/install-linux.sh` | systemd installer, one profile per instance. |
| `service/com.elianiva.amp-orb-provider.plist` | launchd template. |
| `service/amp-orb-provider@.service` | systemd template unit. |
| `state/` | Durable `ORB_ID` to sandbox mapping. |
| `logs/` | Provider logs on macOS; Linux uses the journal. |

## Setup

You need:

- A Docker account with an active [Docker Agentic Platform subscription](https://docs.docker.com/agentic-platform/signup/), which gives access to cloud sandboxes. Docker bills cloud compute per hour.
- A Docker Hub repository for the orb image, such as `docker.io/<user>/amp-orb`.
- A machine with Docker and Buildx to build the image, such as your laptop.
- A host for the provider: a Linux server with systemd, or a Mac with Apple silicon. It runs only `amp orb provider` and `sbx`, so it needs no virtualization support.
- An Amp account. A personal provider works. A workspace provider needs a workspace admin.

### 1. Build and publish the image

On the build machine:

```sh
docker login
git clone https://github.com/elianiva/amp-orbs
cd amp-orbs
docker buildx build --pull --platform linux/amd64 \
  -t docker.io/<user>/amp-orb:2026-11-14 -t docker.io/<user>/amp-orb:latest \
  --push image/
```

The build pulls Amp's orb image from Google Artifact Registry, about 1.7 GiB, and adds one small layer. See [Orb image](#orb-image) for what the layer does.

On an arm64 machine, Buildx builds the amd64 image under emulation. Docker Desktop sets this up for you. On Linux, install the emulators first with `docker run --privileged --rm tonistiigi/binfmt --install amd64`.

A public repository is the simplest choice. A private repository works only if the Docker account that the provider signs in with can pull it.

### 2. Create the provider in Amp

1. Open **Settings → Orbs**, either your [personal settings](https://ampcode.com/settings/orbs) or your workspace settings, and click **Add Orb Provider**. Name it, for example `Docker`. Members pick the provider by this name.
2. Copy the provider token. It starts with `aop_live_`. The Linux setup script asks for it.
3. Click **Edit** on the provider. Under **Orb types**, add `micro`, `small`, `medium`, `large`, and `xl`, and select `medium` as the default. The CLI cannot set orb types. See [Orb types](#orb-types) for their sizes.

On macOS, you can run `amp orb provider create <name>` instead of steps 1 and 2. It creates the provider and saves its token with your Amp credentials, which the launchd service uses.

### 3. Prepare the provider host

Create a Docker personal access token (PAT) for the subscribed account in Docker Hub under **Account settings → Personal access tokens**. The provider host signs `sbx` in with it.

On Ubuntu, install `sbx`, Amp, and this repository as the user that will run the service:

```sh
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
curl -fsSL https://ampcode.com/install.sh | bash
git clone https://github.com/elianiva/amp-orbs ~/Development/amp-orbs
```

For other distributions, install the `.rpm` or `.deb` package from the [sbx releases](https://github.com/docker/sbx-releases/releases). Cloud sandboxes do not need KVM, so skip the `kvm` group steps in Docker's install guide. The host also needs `python3`, `git`, and `sudo`.

On macOS:

```sh
brew trust docker/tap
brew install docker/tap/sbx
curl -fsSL https://ampcode.com/install.sh | bash
git clone https://github.com/elianiva/amp-orbs ~/Development/amp-orbs
```

Cloud sandboxes need `sbx` 0.45.0 or later.

### 4. Install the provider service

On Linux, run the setup script as the service user, not as root:

```sh
cd ~/Development/amp-orbs
./service/setup-linux.sh docker-personal --provider Docker \
  --docker-user <user> --image docker.io/<user>/amp-orb:2026-11-14
```

`docker-personal` is the profile name. The script asks for the Docker PAT, then for the provider token. It then does these steps:

- It signs `sbx` in under a config directory for this profile and runs `sbx --cloud diagnose`.
- It writes `/etc/amp-orbs/docker-personal.env` with the provider token and mode 600, and `/etc/amp-orbs/docker-personal.job.env` with the non-secret orb settings and mode 644.
- It installs the per-profile launcher `/usr/local/bin/amp-orb-dispatch-docker-personal`. `amp orb provider` runs job scripts with a sanitized environment, so the launcher loads the job env before running `dispatch.py`.
- It copies the Amp binary to `/usr/local/bin/amp`, so SELinux lets systemd run it.
- It starts `amp-orb-provider@docker-personal.service`, which logs to the journal.

On macOS, sign `sbx` in and install the launchd service:

```sh
sbx login
sbx --cloud diagnose
cd ~/Development/amp-orbs
AMP_ORBS_IMAGE=docker.io/<user>/amp-orb:2026-11-14 ./service/install.sh
```

The service starts at login and logs to `logs/provider.err.log`.

### 5. Test a thread

Start a thread on the provider:

```sh
amp -ox "Reply with OK." --orb-provider Docker
```

The first orb from a new image tag takes longer, because Docker Cloud pulls the whole image. Follow the provider log while it starts. On Linux, run `journalctl -u amp-orb-provider@docker-personal -f`. On macOS, run `tail -f logs/provider.err.log`.

Continue the same thread to test pause and resume:

```sh
amp threads continue <thread-id> -ox "Reply with RESUMED."
```

The thread's sandbox is named `amp-<thread id>`. Check that it started earlyoom:

```sh
sbx --cloud exec amp-<thread id> bash -lc 'grep ^pid1= /home/user/.amp-bootstrap.log | tail -1'
```

The line ends with `earlyoom=on`.

To make the provider the default for new threads, select it in **Settings → Orbs**, or run `amp orb provider set-default Docker`. Add `--workspace` to set the workspace default.

### Update the image

Amp updates its orb image often. To roll out a new version:

1. Build and push the image again with a new dated tag, as in step 1. `--pull` fetches Amp's latest image.
2. Point the provider at the new tag and restart it. On Linux:

   ```sh
   sudo sed -i 's|^AMP_ORBS_IMAGE=.*|AMP_ORBS_IMAGE=docker.io/<user>/amp-orb:<new-tag>|' \
     /etc/amp-orbs/docker-personal.job.env /etc/amp-orbs/docker-personal.env
   sudo systemctl restart amp-orb-provider@docker-personal
   ```

   On macOS, run `./service/install.sh` again with the new `AMP_ORBS_IMAGE`.

Only new orbs use the new image. Existing sandboxes and project snapshots keep the image they started from.

## Orb image

Orbs boot from Amp's own orb image, `us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest`. It has the Amp CLI, agent-browser with Chrome, Node, Bun, Python, uv, gh, nix, and the tools for portals, Terminal, and Desktop.

Docker Sandboxes Cloud cannot boot that image directly, for two reasons:

- `sbx --cloud create --image-ref` pulls only from Docker Hub (`docker.io`) and `dhi.io`. Amp publishes its image on Google Artifact Registry.
- Docker Sandboxes runs commands as an `agent` account with uid 1000 and home `/home/agent`. Amp's image names uid 1000 `user`.

`image/Dockerfile` adds one layer on top of Amp's image. The layer adds `agent` as a second name for uid 1000, with the same groups and passwordless sudo, and keeps the sandbox proxy variables across sudo. It also installs earlyoom, described under VM limits. [Setup](#1-build-and-publish-the-image) pushes the result to Docker Hub.

For arm64, add `--build-arg BASE_IMAGE=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb-arm64:latest` and `--platform linux/arm64`.

Put the full reference, with the `docker.io/` prefix, in `AMP_ORBS_IMAGE`. `sbx` does not add the registry for you. The dispatcher creates each sandbox with `sbx --cloud create --image-ref <image> --cpus N --memory M`, so one image serves every orb type.

Pin a dated tag in `AMP_ORBS_IMAGE`, so that you choose when orbs move to a new image. See [Update the image](#update-the-image).

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

`ORB_TYPE` selects one of `micro`, `small`, `medium`, `large`, or `xl`. If it is unset, the dispatcher uses `medium`. If a project snapshot has a different CPU or memory shape, the dispatcher ignores it for that type, boots the image, and runs `.agents/setup`.

## Dispatch behavior

Amp runs the profile's launcher once per job. The launcher loads `/etc/amp-orbs/<profile>.job.env` and then runs `dispatch.py`. The provider itself inherits `/etc/amp-orbs/<profile>.env`, but it sanitizes the environment it passes to the job script, so the launcher is what makes `AMP_ORBS_*` visible. The dispatcher reads `ORB_OPERATION`, `ORB_ID`, `ORB_IMAGE`, `ORB_SNAPSHOT_ID`, `ORB_TYPE`, `ORB_TOKEN`, and `AMP_URL` from the job.

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

## Provider service

[Setup](#4-install-the-provider-service) installs the service. This section covers removing profiles, installing without the setup script, and running several accounts on one host.

### Reset

Remove one profile:

```sh
./service/reset-linux.sh docker-personal
```

Remove every profile, the systemd unit, and `/usr/local/bin/amp`:

```sh
./service/reset-linux.sh --all
```

The script stops and disables the service, then removes the env file, state, logs, and the profile's `sbx` config. It does not delete the Amp provider, project snapshot templates, or cloud sandboxes. Remove test sandboxes with `sbx --cloud rm --force` and manage the provider in Settings → Orbs.

### Manual setup on Linux

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

The installer writes `/etc/amp-orbs/melon-sbx.env` with the provider token and mode 600, and `/etc/amp-orbs/melon-sbx.job.env` with the non-secret orb settings. It installs `/usr/local/bin/amp-orb-dispatch-melon-sbx`, renders `/etc/systemd/system/amp-orb-provider@.service`, runs `sbx --cloud diagnose` with the profile, and starts `amp-orb-provider@melon-sbx.service`. Logs go to `journalctl -u amp-orb-provider@melon-sbx`.

### Multiple accounts on one host

Create one provider token per Amp account or workspace and pass it to that profile's service as `AMP_ORB_PROVIDER_TOKEN`. The provider uses the token, so the host does not need a saved Amp account.

`sbx` has no `--profile` flag. Give each Docker account its own `DOCKER_CONFIG` and `XDG_CONFIG_HOME`. The Linux installer defaults to `$HOME/.docker/<profile>` and `$HOME/.config/<profile>`, and the preflight checks that login. If a particular `sbx` build still shares a session, run each profile as a separate OS user with `SERVICE_USER=<user>`.

Run one `amp-orb-provider@<profile>.service` per profile. Each instance has its own token, `sbx` config, state directory, journal logs, and image setting. Profiles can share one public image. Never run two providers for the same token. `--allow-multiple` is only for dispatch programs that share state.

### Example: two profiles

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
