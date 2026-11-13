#!/usr/bin/env bash
# Set up one Linux Amp orb provider profile on a Docker Sandboxes cloud host.
#
# Run as the service user, not root. The script uses sudo for the systemd
# install. The Docker PAT and Amp provider token are read without echo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=""
PROVIDER="Docker"
DOCKER_USER=""
IMAGE=""

usage() {
	cat <<'EOF'
Usage:
  ./service/setup-linux.sh [profile] [options]

Arguments:
  profile                 systemd instance name (default: melon-sbx)

Options:
  --provider NAME         Amp provider name (default: Docker)
  --docker-user USER      Docker Hub username (prompts if omitted)
  --image REF             Orb image on Docker Hub
                          (default: docker.io/<docker-user>/amp-orb:latest)
  -h, --help              Show this help

The script logs in sbx, fixes its local storage permissions, installs the
systemd service, and checks the provider process. Build and push the orb image
from image/Dockerfile first.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--provider)
			PROVIDER="$2"
			shift 2
			;;
		--docker-user)
			DOCKER_USER="$2"
			shift 2
			;;
		--image)
			IMAGE="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			echo "unknown option: $1" >&2
			usage >&2
			exit 2
			;;
		*)
			if [[ -n "$PROFILE" ]]; then
				echo "unexpected argument: $1" >&2
				exit 2
			fi
			PROFILE="$1"
			shift
			;;
	esac
done
PROFILE="${PROFILE:-melon-sbx}"

if [[ -z "$DOCKER_USER" ]]; then
	read -rp "Docker Hub username: " DOCKER_USER
fi
if [[ -z "$DOCKER_USER" ]]; then
	echo "Docker Hub username is required" >&2
	exit 1
fi
IMAGE="${IMAGE:-docker.io/$DOCKER_USER/amp-orb:latest}"

if [[ "$(id -u)" -eq 0 ]]; then
	echo "run this script as the service user, not root" >&2
	exit 1
fi

for bin in sbx amp python3 git systemctl sudo; do
	if ! command -v "$bin" >/dev/null 2>&1; then
		echo "$bin is missing from PATH" >&2
		exit 1
	fi
done

SERVICE_USER="$(id -un)"
SERVICE_HOME="$HOME"
DOCKER_CONFIG="$SERVICE_HOME/.docker/$PROFILE"
XDG_CONFIG_HOME="$SERVICE_HOME/.config/$PROFILE"
AMP_BIN="$(command -v amp)"
SBX_BIN="$(command -v sbx)"
export DOCKER_CONFIG XDG_CONFIG_HOME
umask 0077

echo "==> fixing sbx local storage permissions"
DATA_HOME="${XDG_DATA_HOME:-$SERVICE_HOME/.local/share}"
for dir in \
	"$SERVICE_HOME" \
	"$SERVICE_HOME/.local" \
	"$SERVICE_HOME/.local/share" \
	"$DATA_HOME" \
	"$DATA_HOME/sandboxes" \
	"$DATA_HOME/sandboxes/sandboxes"; do
	if [[ -d "$dir" ]]; then
		chmod go-w "$dir" 2>/dev/null || true
	fi
done
for dir in "$DATA_HOME/sandboxes" "$DATA_HOME/sandboxes/sandboxes"; do
	if [[ -d "$dir" ]]; then
		chmod 0700 "$dir"
	fi
done
install -d -m 0700 "$DOCKER_CONFIG" "$XDG_CONFIG_HOME"

echo "==> logging in sbx for profile $PROFILE"
read -rsp "Docker PAT for $DOCKER_USER: " SBX_PAT
printf '%s' "$SBX_PAT" | "$SBX_BIN" login --username "$DOCKER_USER" --password-stdin
unset SBX_PAT
"$SBX_BIN" --cloud diagnose

echo "==> provider $PROVIDER, image $IMAGE"
echo "Make sure the provider has the orb types in Amp Settings > Orbs."

echo "==> installing the provider service"
sudo env \
	AMP_BIN="$AMP_BIN" \
	SBX_BIN="$SBX_BIN" \
	AMP_ORBS_IMAGE="$IMAGE" \
	DOCKER_CONFIG="$DOCKER_CONFIG" \
	XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
	"$ROOT/service/install-linux.sh" "$PROFILE"

echo "==> checking the provider service"
systemctl status "amp-orb-provider@$PROFILE.service" --no-pager
pgrep -fl "amp orb provider" || true
journalctl -u "amp-orb-provider@$PROFILE" -n 20 --no-pager

echo "==> done"
