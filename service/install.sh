#!/usr/bin/env bash
# Install the provider service for the current platform.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
	Darwin)
		exec "$ROOT/service/install-macos.sh" "$@"
		;;
	Linux)
		exec "$ROOT/service/install-linux.sh" "$@"
		;;
	*)
		echo "unsupported provider host: $(uname -s)" >&2
		exit 1
		;;
esac
