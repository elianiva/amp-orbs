#!/usr/bin/env bash
# Remove one Linux Amp orb provider profile, or all local provider state.
#
# Run as the service user. The script uses sudo for the systemd and root-owned
# files. It does not delete Amp provider records, cloud templates, or sandboxes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=""
ALL=0
ASSUME_YES=0

usage() {
	cat <<'EOF'
Usage:
  ./service/reset-linux.sh [profile] [options]
  ./service/reset-linux.sh --all [options]

Arguments:
  profile                 systemd instance to remove

Options:
  --all                   Remove every profile, the systemd unit, and
                          /usr/local/bin/amp
  --yes, -y               Do not ask for confirmation
  -h, --help              Show this help

The script stops and disables the service, then removes the env file, job env,
launcher, state, logs, and the profile's sbx config. It does not delete Amp
provider records, cloud templates, or cloud sandboxes. Remove test sandboxes
with `sbx --cloud rm --force` and manage providers in Settings > Orbs.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--all)
			ALL=1
			shift
			;;
		--yes | -y)
			ASSUME_YES=1
			shift
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

if [[ "$ALL" -eq 0 && -z "$PROFILE" ]]; then
	echo "pass a profile or --all" >&2
	usage >&2
	exit 2
fi

if [[ "$(id -u)" -eq 0 ]]; then
	SUDO=""
else
	SUDO="sudo"
fi
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(id -un)}}"
if [[ -z "${SERVICE_HOME:-}" ]]; then
	if command -v getent >/dev/null 2>&1; then
		SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
	else
		SERVICE_HOME="$(eval echo "~$SERVICE_USER")"
	fi
fi
ENV_DIR="/etc/amp-orbs"
UNIT="/etc/systemd/system/amp-orb-provider@.service"

profiles=()
if [[ "$ALL" -eq 1 ]]; then
	while IFS= read -r env_file; do
		profiles+=("$(basename "$env_file" .env)")
	done < <(find "$ENV_DIR" -maxdepth 1 -name '*.env' ! -name '*.job.env' -type f 2>/dev/null | sort)
	if [[ ${#profiles[@]} -eq 0 && -f "$UNIT" ]]; then
		profiles=("")
	fi
else
	profiles=("$PROFILE")
fi

if [[ ${#profiles[@]} -eq 0 ]]; then
	echo "no provider profiles found"
	exit 0
fi

echo "This will remove:"
for profile in "${profiles[@]}"; do
	if [[ -n "$profile" ]]; then
		echo "  service amp-orb-provider@$profile.service"
		echo "  $ENV_DIR/$profile.env"
		echo "  $ENV_DIR/$profile.job.env"
		echo "  /usr/local/bin/amp-orb-dispatch-$profile"
		echo "  $ROOT/state/$profile and $ROOT/logs/$profile"
		echo "  $SERVICE_HOME/.docker/$profile and $SERVICE_HOME/.config/$profile"
	fi
done
if [[ "$ALL" -eq 1 ]]; then
	echo "  $UNIT"
	echo "  /usr/local/bin/amp"
fi
echo
echo "Amp provider records, cloud templates, and cloud sandboxes are not removed."

if [[ "$ASSUME_YES" -eq 0 ]]; then
	read -rp "Continue? [y/N] " answer
	if [[ ! "$answer" =~ ^[yY]$ ]]; then
		echo "cancelled"
		exit 1
	fi
fi

for profile in "${profiles[@]}"; do
	if [[ -z "$profile" ]]; then
		continue
	fi
	$SUDO systemctl disable --now "amp-orb-provider@$profile.service" 2>/dev/null || true
	$SUDO rm -f "$ENV_DIR/$profile.env" "$ENV_DIR/$profile.job.env"
	$SUDO rm -f "/usr/local/bin/amp-orb-dispatch-$profile"
	$SUDO rm -rf "$ROOT/state/$profile" "$ROOT/logs/$profile"
	$SUDO rm -rf "$SERVICE_HOME/.docker/$profile" "$SERVICE_HOME/.config/$profile"
done

if [[ "$ALL" -eq 1 ]]; then
	$SUDO rm -f "$UNIT"
	$SUDO rm -f /usr/local/bin/amp
	$SUDO find /usr/local/bin -maxdepth 1 -name 'amp-orb-dispatch-*' -delete 2>/dev/null || true
fi

$SUDO systemctl daemon-reload
$SUDO systemctl reset-failed 'amp-orb-provider@*' 2>/dev/null || true

echo
echo "Local provider state removed."
if command -v sbx >/dev/null 2>&1; then
	echo "Cloud sandboxes still visible to sbx:"
	sbx --cloud ls 2>&1 || true
fi
echo "Re-run ./service/setup-linux.sh with the provider name from Settings > Orbs."
