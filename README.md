# amp-orbs

A self-hosted Amp orb provider backed by Docker Sandboxes Cloud (`sbx --cloud`). It runs one cloud sandbox per Amp thread, bootstraps Amp inside it, and preserves the sandbox disk across pauses.

## Files

| Path | Purpose |
| --- | --- |
| `dispatch.py` | Amp dispatch program. Handles `spawn`, `pause`, and `delete` jobs. |
| `base/provision.sh` | Installs the lean base toolchain inside a cloud sandbox. |
| `base/build-template.sh` | Builds and saves the x86_64 cloud template. |
| `service/install.sh` | Installs the provider service for macOS or Linux. |
| `service/install-macos.sh` | launchd installer. |
| `service/install-linux.sh` | systemd installer, one profile per instance. |
| `service/com.elianiva.amp-orb-provider.plist` | launchd template. |
| `service/amp-orb-provider@.service` | systemd template unit. |
| `state/` | Durable `ORB_ID` to sandbox mapping. |
| `logs/` | Provider logs. |

## Base template

`melon-orb-base-x86_64-v3` is the medium Docker Cloud template, built from Docker's `shell` sandbox on `linux/amd64`. It has 4 vCPU and 8 GiB of memory. `melon-orb-base-x86_64-v3-small` is the small template, built from the same provisioning script with 2 vCPU and 4 GiB.

Amp hardcodes `/home/user` and commands such as `install -o user -g user`. The template creates `/home/user` owned by the default `agent` account (uid 1000) and a `user` group with gid 1000. Bootstrap runs as `agent` with `HOME=/home/user`, so Amp's paths and ownership commands resolve correctly. The managed `user` account's passwd entry is reset at boot, so the dispatcher re-applies the home and group on every spawn.

It includes:

- Debian 13, Bash, git, GitHub CLI, ripgrep, fd, bat, jq, yq, fzf, shellcheck, sqlite3, tmux, vim, less, tree.
- Node.js 24.22.3, npm, corepack, pnpm 11.28, Bun 1.4.4.
- Go 1.27.4.
- Python 3.13 with uv.
- Typst 0.15.1, so this repository's `.agents/setup` skips its x86_64 download.
- Build tools: gcc, g++, make, pkg-config, libssl-dev, libsqlite3-dev.

Rebuild it with:

```sh
cd ~/Development/amp-orbs
./base/build-template.sh
```

The script creates an amd64 builder, runs `base/provision.sh`, saves the template with a disk capture, and removes the builder. It takes about two minutes. To build a new version, pass a name:

```sh
./base/build-template.sh melon-orb-base-x86_64-v4
```

Then set the type template variables in the service environment and restart the provider.

## Orb types

The provider exposes two variants:

| Type | Shape | Base template |
| --- | --- | --- |
| `small` | 2 vCPU / 4 GiB | `melon-orb-base-x86_64-v3-small` |
| `medium` | 4 vCPU / 8 GiB | `melon-orb-base-x86_64-v3` |

Add `small` and `medium` under **Orb types** in the provider's Edit dialog in Amp settings, and select `medium` as the default. The CLI has no command for this setting.

Build the small template once in each `sbx` account:

```sh
CPUS=2 MEMORY=4g ./base/build-template.sh melon-orb-base-x86_64-v3-small
```

`ORB_TYPE` selects the template. If it is unset, the dispatcher uses `medium`. If a project snapshot has a different CPU or memory shape, the dispatcher ignores it for that type, boots the matching base template, and runs `.agents/setup`.

## Dispatch behavior

Amp runs `dispatch.py` once per job. The program reads `ORB_OPERATION`, `ORB_ID`, `ORB_IMAGE`, `ORB_SNAPSHOT_ID`, `ORB_TYPE`, `ORB_TOKEN`, and `AMP_URL`.

### spawn

1. Read `state/orbs/<hash>.json` and inspect the mapped sandbox.
2. If the mapping is missing or stale, list cloud sandboxes and match the name derived from `ORB_ID`. This prevents a second sandbox after a reboot or a lost state file.
3. Create the sandbox if it does not exist. It boots from a project snapshot when one exists, otherwise from the base template.
4. Resume the sandbox if it is stopped. A running sandbox is a no-op.
5. Kill any previous `amp orb bootstrap` process and start a new one as `agent` with `HOME=/home/user` and this job's `ORB_TOKEN`. Tokens are single-use and expire after 15 minutes, so reusing a bootstrap from an earlier spawn is not valid.
6. Wait four seconds and fail the job if the bootstrap process is gone. The error includes the tail of `/home/user/.amp-bootstrap.log` from the sandbox.

`ORB_IMAGE` is logged and ignored. Docker Cloud only accepts images from Docker Hub (`docker.io`, `registry-1.docker.io`, `index.docker.io`) and `dhi.io`; Amp's default image is on `us-central1-docker.pkg.dev`. The base template replaces it.

`ORB_TYPE` selects `small` or `medium`. An unset value uses the default type, `medium`. Unknown values log a warning and use `medium`.

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

Sandboxes are created with `--ttl 24h --on-timeout stop`. A running sandbox that is left idle stops after 24 hours instead of being deleted. A stopped sandbox has no running TTL; resuming it starts a new TTL period. The provider's pause job usually stops an idle orb much sooner.

Docker Cloud's default is one hour with a server-chosen action, which is too short and can delete a parked orb. The explicit TTL and `stop` action avoid that.

## Register and run the provider

Create a provider token for each Amp account or workspace. On macOS, this saves it with your Amp credentials:

```sh
amp orb provider create melon-sbx
```

On Linux, pass the token to the installer as `AMP_ORB_PROVIDER_TOKEN`.

### macOS

```sh
cd ~/Development/amp-orbs
./service/install.sh
```

The installer renders the launchd plist with this checkout's path and starts the service at login. Logs are in `logs/provider.err.log`.

### Linux

Log in `sbx` for the profile first. Use the same config directories that the installer uses:

```sh
DOCKER_CONFIG="$HOME/.docker/melon-sbx" \
XDG_CONFIG_HOME="$HOME/.config/melon-sbx" \
sbx login --username <docker-user> --password-stdin
```

Install one systemd instance:

```sh
sudo env AMP_ORB_PROVIDER_TOKEN='aop_live_...' \
  ./service/install-linux.sh melon-sbx
```

The installer writes `/etc/amp-orbs/melon-sbx.env` with mode 600, renders `/etc/systemd/system/amp-orb-provider@.service`, runs `sbx --cloud diagnose` with the profile, and starts `amp-orb-provider@melon-sbx.service`. Logs go to `logs/melon-sbx/provider.err.log` and `journalctl -u amp-orb-provider@melon-sbx`.

The base templates are account-scoped. Build both in the same profile:

```sh
DOCKER_CONFIG="$HOME/.docker/melon-sbx" \
XDG_CONFIG_HOME="$HOME/.config/melon-sbx" \
./base/build-template.sh

DOCKER_CONFIG="$HOME/.docker/melon-sbx" \
XDG_CONFIG_HOME="$HOME/.config/melon-sbx" \
CPUS=2 MEMORY=4g \
./base/build-template.sh melon-orb-base-x86_64-v3-small
```

### Multiple accounts on one VPS

Create one provider token per Amp account or workspace and pass it to that profile's service as `AMP_ORB_PROVIDER_TOKEN`. The provider uses the token, so the host does not need a saved Amp account.

`sbx` has no `--profile` flag. Give each Docker account its own `DOCKER_CONFIG` and `XDG_CONFIG_HOME`. The Linux installer defaults to `$HOME/.docker/<profile>` and `$HOME/.config/<profile>`, and the preflight checks that login. If a particular `sbx` build still shares a session, run each profile as a separate OS user with `SERVICE_USER=<user>`.

Run one `amp-orb-provider@<profile>.service` per profile. Each instance has its own token, `sbx` config, state directory, logs, and base template. Never run two providers for the same token. `--allow-multiple` is only for dispatch programs that share state.

#### Example: two profiles

This example uses the installer's default config directories and two provider tokens. The template name is the same in both `sbx` accounts because templates are account-scoped.

```sh
# Profile 1: personal Docker account
export DOCKER_CONFIG="$HOME/.docker/melon-sbx"
export XDG_CONFIG_HOME="$HOME/.config/melon-sbx"
echo "$PERSONAL_DOCKER_PAT" | sbx login --username <personal-docker-user> --password-stdin
./base/build-template.sh
CPUS=2 MEMORY=4g ./base/build-template.sh melon-orb-base-x86_64-v3-small
sudo env AMP_ORB_PROVIDER_TOKEN="$MELON_SBX_TOKEN" \
  ./service/install-linux.sh melon-sbx

# Profile 2: work Docker account
export DOCKER_CONFIG="$HOME/.docker/work-sbx"
export XDG_CONFIG_HOME="$HOME/.config/work-sbx"
echo "$WORK_DOCKER_PAT" | sbx login --username <work-docker-user> --password-stdin
./base/build-template.sh
CPUS=2 MEMORY=4g ./base/build-template.sh melon-orb-base-x86_64-v3-small
sudo env AMP_ORB_PROVIDER_TOKEN="$WORK_SBX_TOKEN" \
  ./service/install-linux.sh work-sbx
```

Both services run at the same time:

```sh
systemctl status amp-orb-provider@melon-sbx.service
systemctl status amp-orb-provider@work-sbx.service
```

Their state and logs are separate:

```text
state/melon-sbx/    state/work-sbx/
logs/melon-sbx/     logs/work-sbx/
```

## Test a thread

```sh
amp -ox "Reply with OK." --orb-provider melon-sbx
```

Continue the same thread to test resume:

```sh
amp threads continue <thread-id> -ox "Reply with RESUMED."
```

A thread's sandbox is named `amp-<thread id>`. Check it with `sbx --cloud ls` and `sbx --cloud inspect <name> --format json`.

## Troubleshooting

- Read `logs/provider.err.log` on macOS. On Linux, read `logs/<profile>/provider.err.log` and `journalctl -u amp-orb-provider@<profile>`.
- Read the orb's bootstrap log inside the sandbox:
  `sbx --cloud exec <sandbox> bash -lc 'tail -50 /home/user/.amp-bootstrap.log'`
- Run `sbx --cloud diagnose` to check Docker sign-in, cloud connectivity, and account access.
- Check both base templates with `sbx --cloud template inspect melon-orb-base-x86_64-v3 --format json` and `sbx --cloud template inspect melon-orb-base-x86_64-v3-small --format json`.
- If a sandbox is stuck in `hibernating`, wait for the workflow to settle and retry `sbx --cloud rm --force`.

## Docker Cloud limitations

- Inline images are limited to Docker Hub and `dhi.io`. A private or Google Artifact Registry image cannot be used directly. Build a cloud template instead.
- `sbx exec` has no detach flag. The bootstrap uses `setsid` and a redirect, and the dispatcher verifies that the process survives.
- `sbx exec` does not support `--user`. Bootstrap runs as the template's default `agent` user, which has passwordless sudo.
- `stop` and `rm` are asynchronous. A sandbox can be `stopping` or `hibernating` for about a minute. The dispatcher polls and retries.
- Cloud templates can capture disk or memory plus disk. Project snapshots use disk capture, so files survive but processes do not.
- The cloud template list does not include descriptions, so snapshots use deterministic names and `template inspect`.
