#!/usr/bin/env bash
# Create per-shape memory+disk checkpoints for the orb image.
#
# New orbs restore from these in about two seconds. Docker Cloud cannot resize
# a template, so one template is needed per orb type. The template name matches
# what dispatch.py derives from AMP_ORBS_IMAGE:
#
#   amp-base-<image tag>-<arch>-<type>
#
# Only run this against a credential-free image. The checkpoint captures the
# VM's memory, so never save one from a sandbox that has seen an Amp token or
# another secret.
set -euo pipefail

IMAGE="${AMP_ORBS_IMAGE:-}"
PLATFORM="${AMP_ORBS_PLATFORM:-linux/amd64}"
ARCH="${PLATFORM#linux/}"
SBX="${AMP_ORBS_SBX:-$(command -v sbx || true)}"
SETTLE="${AMP_ORBS_TEMPLATE_SETTLE:-20}"
FORCE=0
TYPES=()

usage() {
	cat <<'USAGE'
Usage: service/create-base-templates.sh [--force] [type ...]

Types: micro small medium large xl (default: all five).
Set AMP_ORBS_IMAGE to the published image. The script creates
amp-base-<tag>-<arch>-<type> templates with --capture-mode all.

Options:
  --force   Recreate templates that already exist.
  --help    Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--force) FORCE=1; shift ;;
		--help|-h) usage; exit 0 ;;
		-*) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
		*) TYPES+=("$1"); shift ;;
	esac
done

if [[ -z "$IMAGE" ]]; then
	echo "set AMP_ORBS_IMAGE to the published image" >&2
	exit 1
fi
if [[ -z "$SBX" ]]; then
	echo "sbx was not found; set AMP_ORBS_SBX" >&2
	exit 1
fi
if [[ ${#TYPES[@]} -eq 0 ]]; then
	TYPES=(micro small medium large xl)
fi

tag="${IMAGE%%@*}"
tag="${tag##*/}"
if [[ "$tag" == *:* ]]; then
	tag="${tag##*:}"
else
	tag="latest"
fi
prefix="${AMP_ORBS_BASE_TEMPLATE_PREFIX:-amp-base-$tag}"
prefix="$(printf '%s' "$prefix" | sed 's/[^A-Za-z0-9._-]/-/g; s/^-*//; s/-*$//')"
lowered="$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')"
case "$lowered" in
	''|0|off|none|no|false)
		echo "AMP_ORBS_BASE_TEMPLATE_PREFIX disables base templates; unset it or choose a prefix" >&2
		exit 1
		;;
esac

shape() {
	case "$1" in
		micro) echo "1 2g" ;;
		small) echo "2 4g" ;;
		medium) echo "4 8g" ;;
		large) echo "8 16g" ;;
		xl) echo "16 32g" ;;
		*) return 1 ;;
	esac
}

sbx() { "$SBX" --cloud --no-input "$@"; }

cleanup_sandbox=""
cleanup() {
	if [[ -n "$cleanup_sandbox" ]]; then
		sbx rm --force "$cleanup_sandbox" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

echo "image:  $IMAGE"
echo "prefix: $prefix"
echo

for type in "${TYPES[@]}"; do
	spec="$(shape "$type")" || {
		echo "unknown orb type: $type" >&2
		exit 1
	}
	read -r cpus memory <<<"$spec"
	name="$prefix-$ARCH-$type"
	if [[ "$FORCE" -eq 0 ]] && sbx template inspect "$name" --format json >/dev/null 2>&1; then
		echo "==> $name already exists; skipping (use --force to replace)"
		continue
	fi
	if [[ "$FORCE" -eq 1 ]]; then
		sbx template rm --force "$name" >/dev/null 2>&1 || true
	fi
	sandbox="amp-base-build-$type-$(date +%s)"
	cleanup_sandbox="$sandbox"
	echo "==> $type: creating $sandbox ($cpus vCPU/$memory)"
	sbx create --name "$sandbox" --image-ref "$IMAGE" \
		--cpus "$cpus" --memory "$memory" --platform "$PLATFORM" \
		--ttl 30m --on-timeout delete --no-progress >/dev/null
	echo "==> $type: settling for ${SETTLE}s"
	sleep "$SETTLE"
	echo "==> $type: saving $name with memory+disk"
	sbx template save "$sandbox" "$name" --capture-mode all \
		--description "Amp orb base $type from $IMAGE"
	info="$(sbx template inspect "$name" --format json)"
	python3 - "$info" "$name" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
size = (value.get("total_size_bytes") or 0) / 1e9
print(f"    {sys.argv[2]}: {value.get('status')} {size:.1f} GB")
PY
	sbx rm --force "$sandbox" >/dev/null 2>&1 || true
	cleanup_sandbox=""
done

echo
echo "Done. dispatch.py derives the same prefix from AMP_ORBS_IMAGE, so new"
echo "orbs use these templates automatically. Set"
echo "AMP_ORBS_BASE_TEMPLATE_PREFIX=$prefix only to override the derived name."
