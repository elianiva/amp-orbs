#!/usr/bin/env bash
# Install one Linux systemd instance of the Amp orb provider.
#
# Usage:
#   sudo env AMP_ORB_PROVIDER_TOKEN='aop_live_...' \
#     AMP_ORBS_IMAGE=docker.io/<user>/amp-orb:latest \
#     ./service/install-linux.sh <profile>
#
# Each profile gets its own sbx config, state directory, logs, and token, so one
# VPS can serve several Docker and Amp accounts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-melon-sbx}"
LABEL="amp-orb-provider@${PROFILE}.service"
UNIT_SOURCE="$ROOT/service/amp-orb-provider@.service"
UNIT_TARGET="/etc/systemd/system/amp-orb-provider@.service"
ENV_DIR="/etc/amp-orbs"
ENV_FILE="$ENV_DIR/${PROFILE}.env"
JOB_ENV_FILE="$ENV_DIR/${PROFILE}.job.env"
LAUNCHER="/usr/local/bin/amp-orb-dispatch-${PROFILE}"
DRY_RUN="${DRY_RUN:-0}"

if [[ ! "$PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; then
	echo "profile must be 1-63 letters, numbers, or hyphens" >&2
	exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
	SUDO=""
	RUN_AS="runuser -u"
else
	SUDO="sudo"
	RUN_AS="sudo -u"
fi

SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$USER}}"
SERVICE_GROUP="${SERVICE_GROUP:-$(id -gn "$SERVICE_USER")}"
if [[ -z "${SERVICE_HOME:-}" ]]; then
	if command -v getent >/dev/null 2>&1; then
		SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
	else
		SERVICE_HOME="$(eval echo "~$SERVICE_USER")"
	fi
fi

resolve_for_user() {
	if [[ -z "$SUDO" ]]; then
		$RUN_AS "$SERVICE_USER" -- bash -lc "command -v $1" 2>/dev/null | tail -1 || true
	else
		$RUN_AS "$SERVICE_USER" -- bash -lc "command -v $1" 2>/dev/null | tail -1 || true
	fi
}

AMP_BIN="${AMP_BIN:-$(resolve_for_user amp)}"
SBX_BIN="${SBX_BIN:-$(resolve_for_user sbx)}"
if [[ -z "$AMP_BIN" ]]; then
	echo "amp was not found for $SERVICE_USER; set AMP_BIN" >&2
	exit 1
fi
if [[ -z "$SBX_BIN" ]]; then
	echo "sbx was not found for $SERVICE_USER; set SBX_BIN" >&2
	exit 1
fi

# systemd runs as init_t and SELinux denies executing a user_home_t binary.
# Install the Amp binary under /usr/local/bin so it gets bin_t.
if [[ "$AMP_BIN" != "/usr/local/bin/amp" ]]; then
	$SUDO install -m 0755 "$AMP_BIN" /usr/local/bin/amp
	AMP_BIN="/usr/local/bin/amp"
fi

TOKEN="${AMP_ORB_PROVIDER_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
	if [[ -t 0 ]]; then
		read -rsp "Provider token for $PROFILE: " TOKEN
		echo
	else
		echo "set AMP_ORB_PROVIDER_TOKEN or run from a terminal" >&2
		exit 1
	fi
fi

DOCKER_CONFIG="${DOCKER_CONFIG:-$SERVICE_HOME/.docker/$PROFILE}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$SERVICE_HOME/.config/$PROFILE}"
AMP_ORBS_STATE="${AMP_ORBS_STATE:-$ROOT/state/$PROFILE}"
AMP_ORBS_IMAGE="${AMP_ORBS_IMAGE:-}"
if [[ -z "$AMP_ORBS_IMAGE" ]]; then
	echo "set AMP_ORBS_IMAGE to the published orb image, such as docker.io/<user>/amp-orb:latest" >&2
	exit 1
fi
AMP_ORBS_PLATFORM="${AMP_ORBS_PLATFORM:-linux/amd64}"
AMP_ORBS_DEFAULT_TYPE="${AMP_ORBS_DEFAULT_TYPE:-medium}"
AMP_ORBS_TTL="${AMP_ORBS_TTL:-24h}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sed \
	-e "s|__USER__|$SERVICE_USER|g" \
	-e "s|__GROUP__|$SERVICE_GROUP|g" \
	-e "s|__ROOT__|$ROOT|g" \
	-e "s|__AMP_BIN__|$AMP_BIN|g" \
	-e "s|__LAUNCHER__|$LAUNCHER|g" \
	"$UNIT_SOURCE" >"$WORK/unit"

sed \
	-e "s|__JOB_ENV__|$JOB_ENV_FILE|g" \
	-e "s|__DISPATCH__|$ROOT/dispatch.py|g" \
	"$ROOT/service/amp-orb-dispatch.py" >"$WORK/launcher"

cat >"$WORK/env" <<EOF
HOME=$SERVICE_HOME
PATH=$SERVICE_HOME/.amp/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
AMP_ORB_PROVIDER_TOKEN=$TOKEN
AMP_ORBS_ROOT=$ROOT
AMP_ORBS_STATE=$AMP_ORBS_STATE
AMP_ORBS_IMAGE=$AMP_ORBS_IMAGE
AMP_ORBS_PLATFORM=$AMP_ORBS_PLATFORM
AMP_ORBS_DEFAULT_TYPE=$AMP_ORBS_DEFAULT_TYPE
AMP_ORBS_TTL=$AMP_ORBS_TTL
AMP_ORBS_PAUSE_GRACE=${AMP_ORBS_PAUSE_GRACE:-10m}
AMP_ORBS_BOOTSTRAP_SETTLE=${AMP_ORBS_BOOTSTRAP_SETTLE:-2}
AMP_ORBS_SBX=$SBX_BIN
DOCKER_CONFIG=$DOCKER_CONFIG
XDG_CONFIG_HOME=$XDG_CONFIG_HOME
EOF

# amp orb provider runs the job script with a sanitized environment, so the
# AMP_ORBS_* values above never reach dispatch.py. The launcher reads this
# non-secret copy instead. Keep the token out of it.
cat >"$WORK/job-env" <<EOF
HOME=$SERVICE_HOME
PATH=$SERVICE_HOME/.amp/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
AMP_ORBS_ROOT=$ROOT
AMP_ORBS_STATE=$AMP_ORBS_STATE
AMP_ORBS_IMAGE=$AMP_ORBS_IMAGE
AMP_ORBS_PLATFORM=$AMP_ORBS_PLATFORM
AMP_ORBS_DEFAULT_TYPE=$AMP_ORBS_DEFAULT_TYPE
AMP_ORBS_TTL=$AMP_ORBS_TTL
AMP_ORBS_PAUSE_GRACE=${AMP_ORBS_PAUSE_GRACE:-10m}
AMP_ORBS_BOOTSTRAP_SETTLE=${AMP_ORBS_BOOTSTRAP_SETTLE:-2}
AMP_ORBS_SBX=$SBX_BIN
DOCKER_CONFIG=$DOCKER_CONFIG
XDG_CONFIG_HOME=$XDG_CONFIG_HOME
EOF

if [[ "$DRY_RUN" = 1 ]]; then
	echo "=== $UNIT_TARGET ==="
	cat "$WORK/unit"
	echo "=== $ENV_FILE (token redacted) ==="
	sed 's/^AMP_ORB_PROVIDER_TOKEN=.*/AMP_ORB_PROVIDER_TOKEN=<redacted>/' "$WORK/env"
	echo "=== $JOB_ENV_FILE (non-secret) ==="
	cat "$WORK/job-env"
	echo "=== $LAUNCHER ==="
	cat "$WORK/launcher"
	exit 0
fi

command -v systemctl >/dev/null 2>&1 || {
	echo "systemctl was not found; this installer is for Linux systemd hosts" >&2
	exit 1
}

echo "==> checking the sbx account for profile $PROFILE"
if ! $RUN_AS "$SERVICE_USER" -- env \
	HOME="$SERVICE_HOME" \
	DOCKER_CONFIG="$DOCKER_CONFIG" \
	XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
	"$SBX_BIN" --cloud diagnose; then
	echo "sbx cloud diagnose failed for $SERVICE_USER." >&2
	echo "Log in first:" >&2
	echo "  DOCKER_CONFIG=$DOCKER_CONFIG XDG_CONFIG_HOME=$XDG_CONFIG_HOME $SBX_BIN login --username <docker-user> --password-stdin" >&2
	exit 1
fi

echo "==> installing files"
$SUDO install -d -m 0755 "$ROOT/logs" "$ROOT/state"
$SUDO chown "$SERVICE_USER:$SERVICE_GROUP" "$ROOT/logs" "$ROOT/state"
$SUDO install -d -m 0755 "$ROOT/logs/$PROFILE" "$AMP_ORBS_STATE"
$SUDO install -d -m 0700 "$DOCKER_CONFIG" "$XDG_CONFIG_HOME"
$SUDO chown -R "$SERVICE_USER:$SERVICE_GROUP" "$ROOT/logs/$PROFILE" "$AMP_ORBS_STATE" "$DOCKER_CONFIG" "$XDG_CONFIG_HOME"
$SUDO install -d -m 0755 "$ENV_DIR"
$SUDO install -m 0600 -o root -g root "$WORK/env" "$ENV_FILE"
$SUDO install -m 0644 -o root -g root "$WORK/job-env" "$JOB_ENV_FILE"
$SUDO install -m 0644 "$WORK/unit" "$UNIT_TARGET"
$SUDO install -d -m 0755 "$(dirname "$LAUNCHER")"
$SUDO install -m 0755 "$WORK/launcher" "$LAUNCHER"
if command -v restorecon >/dev/null 2>&1; then
	$SUDO restorecon "$ENV_FILE" "$JOB_ENV_FILE" "$UNIT_TARGET" "$LAUNCHER" 2>/dev/null || true
fi

echo "==> starting $LABEL"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now "$LABEL"
$SUDO systemctl --no-pager status "$LABEL" | sed -n '1,20p'

cat <<EOF

Profile $PROFILE is installed.
  service:  $LABEL
  env:      $ENV_FILE (token, mode 600)
  job env:  $JOB_ENV_FILE (non-secret orb settings)
  launcher: $LAUNCHER
  state:    $AMP_ORBS_STATE
  logs:     journalctl -u $LABEL

New orbs boot from $AMP_ORBS_IMAGE. The provider passes a sanitized environment
to the job script, so the launcher loads the non-secret job env before running
dispatch.py. To roll out a new image, push it, update AMP_ORBS_IMAGE in both
$ENV_FILE and $JOB_ENV_FILE, then restart the service.

New orbs use amp-base-<tag>-<arch>-<type> memory checkpoints when they exist.
Create them after publishing an image with:
  AMP_ORBS_IMAGE=$AMP_ORBS_IMAGE ./service/create-base-templates.sh

Paused orbs stay warm for AMP_ORBS_PAUSE_GRACE (10m) before Docker stops them.
Set it to 0 in the job env to stop immediately.

Follow logs with:
  journalctl -u $LABEL -f
EOF
