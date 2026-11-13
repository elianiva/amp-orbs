#!/usr/bin/env bash
# Install and start the Amp orb provider as a per-user launchd service.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.elianiva.amp-orb-provider"
SOURCE="$ROOT/service/$LABEL.plist"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
AMP_BIN="${AMP_BIN:-$(command -v amp || true)}"

IMAGE="${AMP_ORBS_IMAGE:-}"

if [[ -z "$AMP_BIN" ]]; then
	echo "amp was not found on PATH" >&2
	exit 1
fi
if [[ -z "$IMAGE" ]]; then
	echo "set AMP_ORBS_IMAGE to the published orb image, such as docker.io/<user>/amp-orb:latest" >&2
	exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$ROOT/logs"
sed \
	-e "s|__AMP_BIN__|$AMP_BIN|g" \
	-e "s|__ROOT__|$ROOT|g" \
	-e "s|__HOME__|$HOME|g" \
	-e "s|__IMAGE__|$IMAGE|g" \
	-e "s|__PATH__|/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.amp/bin|g" \
	"$SOURCE" >"$TARGET"
plutil -lint "$TARGET" >/dev/null

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 20); do
	if ! pgrep -f "amp orb provider $ROOT/dispatch.py" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

for attempt in 1 2 3 4 5; do
	if launchctl bootstrap "$DOMAIN" "$TARGET" 2>/dev/null; then
		break
	fi
	if [[ "$attempt" = 5 ]]; then
		echo "launchctl bootstrap failed after $attempt attempts" >&2
		exit 1
	fi
	sleep 3
done

launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

sleep 2
echo "=== launchd ==="
launchctl print "$DOMAIN/$LABEL" | sed -n '1,25p'
echo "=== processes ==="
pgrep -fl 'amp orb provider' || true
echo "=== provider stderr ==="
tail -20 "$ROOT/logs/provider.err.log" 2>/dev/null || true
