#!/usr/bin/env bash
# Install one Linux systemd instance of the Amp orb provider.
#
# Usage:
#   sudo env AMP_ORB_PROVIDER_TOKEN='aop_live_...' ./service/install-linux.sh <profile>
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
		$RUN_AS "$SERVICE_USER" bash -lc "command -v $1" 2>/dev/null | tail -1 || true
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
AMP_ORBS_BASE_TEMPLATE="${AMP_ORBS_BASE_TEMPLATE:-melon-orb-base-x86_64-v3}"
AMP_ORBS_BASE_TEMPLATE_MICRO="${AMP_ORBS_BASE_TEMPLATE_MICRO:-melon-orb-base-x86_64-v3-micro}"
AMP_ORBS_BASE_TEMPLATE_SMALL="${AMP_ORBS_BASE_TEMPLATE_SMALL:-melon-orb-base-x86_64-v3-small}"
AMP_ORBS_BASE_TEMPLATE_MEDIUM="${AMP_ORBS_BASE_TEMPLATE_MEDIUM:-$AMP_ORBS_BASE_TEMPLATE}"
AMP_ORBS_BASE_TEMPLATE_LARGE="${AMP_ORBS_BASE_TEMPLATE_LARGE:-melon-orb-base-x86_64-v3-large}"
AMP_ORBS_BASE_TEMPLATE_XL="${AMP_ORBS_BASE_TEMPLATE_XL:-melon-orb-base-x86_64-v3-xl}"
AMP_ORBS_DEFAULT_TYPE="${AMP_ORBS_DEFAULT_TYPE:-medium}"
AMP_ORBS_TEMPLATE_ARCH="${AMP_ORBS_TEMPLATE_ARCH:-amd64}"
AMP_ORBS_TTL="${AMP_ORBS_TTL:-24h}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sed \
	-e "s|__USER__|$SERVICE_USER|g" \
	-e "s|__GROUP__|$SERVICE_GROUP|g" \
	-e "s|__ROOT__|$ROOT|g" \
	-e "s|__AMP_BIN__|$AMP_BIN|g" \
	"$UNIT_SOURCE" >"$WORK/unit"

cat >"$WORK/env" <<EOF
HOME=$SERVICE_HOME
PATH=$SERVICE_HOME/.amp/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
AMP_ORB_PROVIDER_TOKEN=$TOKEN
AMP_ORBS_ROOT=$ROOT
AMP_ORBS_STATE=$AMP_ORBS_STATE
AMP_ORBS_BASE_TEMPLATE=$AMP_ORBS_BASE_TEMPLATE
AMP_ORBS_BASE_TEMPLATE_MICRO=$AMP_ORBS_BASE_TEMPLATE_MICRO
AMP_ORBS_BASE_TEMPLATE_SMALL=$AMP_ORBS_BASE_TEMPLATE_SMALL
AMP_ORBS_BASE_TEMPLATE_MEDIUM=$AMP_ORBS_BASE_TEMPLATE_MEDIUM
AMP_ORBS_BASE_TEMPLATE_LARGE=$AMP_ORBS_BASE_TEMPLATE_LARGE
AMP_ORBS_BASE_TEMPLATE_XL=$AMP_ORBS_BASE_TEMPLATE_XL
AMP_ORBS_DEFAULT_TYPE=$AMP_ORBS_DEFAULT_TYPE
AMP_ORBS_TEMPLATE_ARCH=$AMP_ORBS_TEMPLATE_ARCH
AMP_ORBS_TTL=$AMP_ORBS_TTL
AMP_ORBS_SBX=$SBX_BIN
DOCKER_CONFIG=$DOCKER_CONFIG
XDG_CONFIG_HOME=$XDG_CONFIG_HOME
EOF

if [[ "$DRY_RUN" = 1 ]]; then
	echo "=== $UNIT_TARGET ==="
	cat "$WORK/unit"
	echo "=== $ENV_FILE (token redacted) ==="
	sed 's/^AMP_ORB_PROVIDER_TOKEN=.*/AMP_ORB_PROVIDER_TOKEN=<redacted>/' "$WORK/env"
	exit 0
fi

command -v systemctl >/dev/null 2>&1 || {
	echo "systemctl was not found; this installer is for Linux systemd hosts" >&2
	exit 1
}

echo "==> checking the sbx account for profile $PROFILE"
if ! $RUN_AS "$SERVICE_USER" env \
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
$SUDO install -d -m 0755 "$ROOT/logs/$PROFILE" "$AMP_ORBS_STATE"
$SUDO install -d -m 0700 "$DOCKER_CONFIG" "$XDG_CONFIG_HOME"
$SUDO chown -R "$SERVICE_USER:$SERVICE_GROUP" "$ROOT/logs/$PROFILE" "$AMP_ORBS_STATE" "$DOCKER_CONFIG" "$XDG_CONFIG_HOME"
$SUDO install -d -m 0750 "$ENV_DIR"
$SUDO install -m 0600 -o root -g root "$WORK/env" "$ENV_FILE"
$SUDO install -m 0644 "$WORK/unit" "$UNIT_TARGET"

echo "==> starting $LABEL"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now "$LABEL"
$SUDO systemctl --no-pager status "$LABEL" | sed -n '1,20p'

cat <<EOF

Profile $PROFILE is installed.
  service: $LABEL
  env:     $ENV_FILE
  state:   $AMP_ORBS_STATE
  logs:    $ROOT/logs/$PROFILE/provider.log

The base templates are account-scoped. Build all five in this profile's sbx account:
  export DOCKER_CONFIG=$DOCKER_CONFIG
  export XDG_CONFIG_HOME=$XDG_CONFIG_HOME
  $ROOT/base/build-template.sh
  CPUS=1 MEMORY=2g $ROOT/base/build-template.sh melon-orb-base-x86_64-v3-micro
  CPUS=2 MEMORY=4g $ROOT/base/build-template.sh melon-orb-base-x86_64-v3-small
  CPUS=8 MEMORY=16g $ROOT/base/build-template.sh melon-orb-base-x86_64-v3-large
  CPUS=16 MEMORY=32g $ROOT/base/build-template.sh melon-orb-base-x86_64-v3-xl

Follow logs with:
  journalctl -u $LABEL -f
EOF
