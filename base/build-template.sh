#!/usr/bin/env bash
# Build the Docker Sandboxes cloud template that every orb boots from.
# Usage: ./build-template.sh [template-name]
set -euo pipefail

cd "$(dirname "$0")"

SBX_BIN="${SBX_BIN:-sbx}"
BUILDER="${BUILDER:-amp-orb-builder}"
TEMPLATE="${1:-${TEMPLATE:-melon-orb-base-x86_64-v3}}"
PLATFORM="${PLATFORM:-linux/amd64}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-8g}"
TTL="${TTL:-4h}"
ARCH_LABEL="${PLATFORM#linux/}"

find_id() {
	"$SBX_BIN" --cloud ls --format json |
		python3 -c 'import json,sys; name=sys.argv[1]; print(next((x["id"] for x in json.load(sys.stdin) if x.get("name")==name), ""))' "$1"
}

if "$SBX_BIN" --cloud template inspect "$TEMPLATE" >/dev/null 2>&1; then
	echo "template $TEMPLATE already exists; remove it first or pass another name" >&2
	exit 1
fi

if [[ -z "$(find_id "$BUILDER")" ]]; then
	echo "==> creating builder $BUILDER (${CPUS} vCPU, ${MEMORY}, ${ARCH_LABEL})"
	"$SBX_BIN" --cloud create --name "$BUILDER" --cpus "$CPUS" --memory "$MEMORY" \
		--platform "$PLATFORM" --ttl "$TTL" --on-timeout stop --no-progress shell
else
	echo "==> reusing builder $BUILDER"
fi

echo "==> uploading provision.sh"
"$SBX_BIN" --cloud cp ./provision.sh "$BUILDER:/home/agent/provision.sh"

echo "==> provisioning (this installs Node, pnpm, Bun, Go, and CLI tools)"
"$SBX_BIN" --cloud exec "$BUILDER" bash -lc 'chmod +x ~/provision.sh && ~/provision.sh'

echo "==> saving template $TEMPLATE (disk capture)"
start=$(date +%s)
"$SBX_BIN" --cloud template save "$BUILDER" "$TEMPLATE" \
	--description "Amp orb base ${ARCH_LABEL}: Debian 13, Node 24, pnpm 11, Bun 1.4, Go 1.27, Typst 0.15, build tools" \
	--capture-mode disk
echo "==> template saved in $(( $(date +%s) - start ))s"

"$SBX_BIN" --cloud template inspect "$TEMPLATE" --format json

if [[ "${KEEP_BUILDER:-0}" != "1" ]]; then
	echo "==> removing builder $BUILDER"
	for _ in 1 2 3 4 5 6; do
		"$SBX_BIN" --cloud rm --force "$BUILDER" && break
		sleep 5
	done
fi
