#!/usr/bin/env bash
# Set up one Linux Amp orb provider profile on a Docker Sandboxes cloud host.
#
# Run as the service user, not root. The script uses sudo for the systemd
# install. The Docker PAT and Amp provider token are read without echo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=""
PROVIDER="Docker"
DOCKER_USER="elianiva"

usage() {
	cat <<'EOF'
Usage:
  ./service/setup-linux.sh [profile] [options]

Arguments:
  profile                 systemd instance name (default: melon-sbx)

Options:
  --provider NAME         Amp provider name (default: Docker)
  --docker-user USER      Docker Hub username (default: elianiva)
  -h, --help              Show this help

The script logs in sbx, fixes its local storage permissions, checks the five
cloud templates, installs the systemd service, and checks the provider process.
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

echo "==> checking the five cloud templates"
templates=(
	"melon-orb-base-x86_64-v3"
	"melon-orb-base-x86_64-v3-micro"
	"melon-orb-base-x86_64-v3-small"
	"melon-orb-base-x86_64-v3-large"
	"melon-orb-base-x86_64-v3-xl"
)
missing=0
for template in "${templates[@]}"; do
	if "$SBX_BIN" --cloud template inspect "$template" >/dev/null 2>&1; then
		echo "ok: $template"
	else
		echo "missing: $template" >&2
		missing=1
	fi
done
if [[ "$missing" -eq 1 ]]; then
	cat >&2 <<EOF

Build the missing templates in this sbx account:
  cd "$ROOT"
  ./base/build-template.sh
  CPUS=1 MEMORY=2g ./base/build-template.sh melon-orb-base-x86_64-v3-micro
  CPUS=2 MEMORY=4g ./base/build-template.sh melon-orb-base-x86_64-v3-small
  CPUS=8 MEMORY=16g ./base/build-template.sh melon-orb-base-x86_64-v3-large
  CPUS=16 MEMORY=32g ./base/build-template.sh melon-orb-base-x86_64-v3-xl
EOF
	exit 1
fi

echo "==> provider $PROVIDER"
echo "Make sure the provider has the orb types in Amp Settings > Orbs."

echo "==> installing the provider service"
sudo env \
	AMP_BIN="$AMP_BIN" \
	SBX_BIN="$SBX_BIN" \
	DOCKER_CONFIG="$DOCKER_CONFIG" \
	XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
	"$ROOT/service/install-linux.sh" "$PROFILE"

echo "==> checking the provider service"
systemctl status "amp-orb-provider@$PROFILE.service" --no-pager
pgrep -fl "amp orb provider" || true
journalctl -u "amp-orb-provider@$PROFILE" -n 20 --no-pager

echo "==> done"
