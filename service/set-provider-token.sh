#!/usr/bin/env bash
# Replace the Amp orb provider token for one Linux systemd profile.
#
# Usage:
#   ./service/set-provider-token.sh <profile>
#
# The script prompts for the new token without echoing it, updates the
# EnvironmentFile that amp-orb-provider@<profile>.service actually reads,
# keeps the file at mode 600, restarts the service, and checks the provider
# log. Generate the new token in Amp under Settings -> Orbs.
#
# This script is for the Linux/systemd installer. On macOS the provider token
# is managed by the Amp CLI, not by an EnvironmentFile.
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: ./service/set-provider-token.sh <profile>

Replaces AMP_ORB_PROVIDER_TOKEN in the profile's systemd EnvironmentFile,
restarts amp-orb-provider@<profile>.service, and checks the provider log.
The token is read from a terminal without echo, or from stdin when piped.

Examples:
  ./service/set-provider-token.sh elianiva
  ./service/set-provider-token.sh elianiva < /secure/path/to/token

Set DRY_RUN=1 to validate the profile, locate the EnvironmentFile, and check
the token shape without writing anything or restarting the service.
USAGE
}

case "${1:-}" in
	--help|-h)
		usage
		exit 0
		;;
	'')
		usage >&2
		exit 1
		;;
esac

PROFILE="$1"
if [[ ! "$PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; then
	echo "profile must be 1-63 letters, numbers, or hyphens" >&2
	exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
	echo "systemctl was not found; this script is for the Linux systemd installer" >&2
	exit 1
fi

UNIT="amp-orb-provider@${PROFILE}.service"
SUDO=()
if [[ "$(id -u)" -ne 0 ]]; then
	SUDO=(sudo)
fi

# Use the EnvironmentFile that systemd actually reads, not a guessed path.
# The property looks like "/etc/amp-orbs/elianiva.env (ignore_errors=no)".
ENV_FILE="$("${SUDO[@]}" systemctl show "$UNIT" \
	-p EnvironmentFiles --value 2>/dev/null |
	awk '{print $1}' |
	sed -e 's/^EnvironmentFiles=//' -e 's/(.*//' |
	head -1)"
if [[ -z "$ENV_FILE" ]]; then
	ENV_FILE="/etc/amp-orbs/${PROFILE}.env"
fi
if ! "${SUDO[@]}" test -f "$ENV_FILE"; then
	echo "EnvironmentFile not found: $ENV_FILE" >&2
	echo "Install the profile first with ./service/setup-linux.sh or service/install-linux.sh." >&2
	exit 1
fi

if [[ -t 0 ]]; then
	read -rsp "New Amp provider token for ${PROFILE}: " TOKEN
	echo
else
	IFS= read -r TOKEN || true
fi
if [[ -z "${TOKEN:-}" ]]; then
	echo "no token was provided" >&2
	exit 1
fi
if [[ "$TOKEN" != aop_* ]]; then
	echo "that does not look like an Amp provider token; expected aop_..." >&2
	exit 1
fi
if (( ${#TOKEN} < 20 )); then
	echo "that token is too short; copy the whole token from Amp" >&2
	exit 1
fi

if [[ "${DRY_RUN:-0}" = 1 ]]; then
	echo "profile:  $PROFILE"
	echo "service:  $UNIT"
	echo "env file: $ENV_FILE"
	echo "token:    valid shape (not printed)"
	echo "dry run:  no files changed, service not restarted"
	exit 0
fi

TOKEN_FILE=""
cleanup() {
	if [[ -n "$TOKEN_FILE" ]]; then
		rm -f "$TOKEN_FILE"
	fi
}
trap cleanup EXIT
umask 077
TOKEN_FILE="$(mktemp "${TMPDIR:-/tmp}/amp-provider-token.XXXXXX")"
printf '%s\n' "$TOKEN" >"$TOKEN_FILE"
unset TOKEN

"${SUDO[@]}" python3 - "$ENV_FILE" "$TOKEN_FILE" <<'PY'
import os
import pathlib
import re
import sys
import tempfile

env_path = pathlib.Path(sys.argv[1])
token = pathlib.Path(sys.argv[2]).read_text().strip()
if (
	not token.startswith("aop_")
	or len(token) < 20
	or re.search(r"\s", token)
):
	raise SystemExit("the new token does not look like an Amp provider token")

try:
	lines = env_path.read_text().splitlines()
except OSError as error:
	raise SystemExit(f"cannot read {env_path}: {error}")

updated = []
replaced = False
for line in lines:
	if line.startswith("AMP_ORB_PROVIDER_TOKEN="):
		updated.append("AMP_ORB_PROVIDER_TOKEN=" + token)
		replaced = True
	else:
		updated.append(line)
if not replaced:
	updated.append("AMP_ORB_PROVIDER_TOKEN=" + token)

content = "\n".join(updated) + "\n"
descriptor, temporary = tempfile.mkstemp(
	prefix="." + env_path.name + ".", dir=str(env_path.parent)
)
try:
	with os.fdopen(descriptor, "w") as handle:
		handle.write(content)
	os.chmod(temporary, 0o600)
	os.replace(temporary, env_path)
finally:
	if os.path.exists(temporary):
		os.unlink(temporary)
print(f"updated {env_path} (mode 600)")
PY

if command -v restorecon >/dev/null 2>&1; then
	"${SUDO[@]}" restorecon "$ENV_FILE" 2>/dev/null || true
fi

echo "restarting $UNIT"
RESTART_AT="$(date '+%Y-%m-%d %H:%M:%S')"
"${SUDO[@]}" systemctl restart "$UNIT"

active=0
for _ in $(seq 1 40); do
	if "${SUDO[@]}" systemctl is-active --quiet "$UNIT"; then
		active=1
		break
	fi
	sleep 0.5
done
if [[ "$active" -ne 1 ]]; then
	echo "provider did not become active; recent log:" >&2
	"${SUDO[@]}" journalctl -u "$UNIT" --since "$RESTART_AT" \
		--no-pager -n 30 >&2 || true
	exit 1
fi

started=0
for _ in $(seq 1 30); do
	if "${SUDO[@]}" journalctl -u "$UNIT" --since "$RESTART_AT" \
		--no-pager 2>/dev/null | grep -q 'Orb provider started'; then
		started=1
		break
	fi
	sleep 0.5
done

echo "--- $UNIT log since restart ---"
"${SUDO[@]}" journalctl -u "$UNIT" --since "$RESTART_AT" \
	--no-pager 2>/dev/null | tail -20 || true

LOG="$("${SUDO[@]}" journalctl -u "$UNIT" --since "$RESTART_AT" \
	--no-pager 2>/dev/null || true)"
if printf '%s\n' "$LOG" |
	grep -Eiq 'unauthorized|forbidden|invalid.*token|authentication failed|HTTP 401|HTTP 403'; then
	echo "ERROR: the provider log reports an authentication failure; check the new token." >&2
	exit 1
fi
if [[ "$started" -ne 1 ]]; then
	echo "WARNING: the service is active but did not log 'Orb provider started'." >&2
	echo "Check the log above. The provider may still be starting." >&2
	exit 1
fi

echo
echo "Provider token replaced. Retry the thread in a few seconds."
