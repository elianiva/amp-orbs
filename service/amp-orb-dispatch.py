#!/usr/bin/env python3
"""Run dispatch.py with this profile's non-secret orb settings.

Amp starts the provider once, then runs its script once per job. The provider
process inherits the systemd EnvironmentFile, but the job script runs with a
sanitized environment, so AMP_ORBS_* never reaches dispatch.py. Load the
profile's job env first, then hand off to the dispatcher.

The installer renders this file with the job env path and the dispatcher path.
"""

from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path

JOB_ENV = Path("__JOB_ENV__")
DISPATCH = Path("__DISPATCH__")


def load_env(path: Path) -> None:
	if not path.is_file():
		print(f"amp-orb-dispatch: job env {path} is missing", file=sys.stderr)
		return
	for raw in path.read_text(encoding="utf-8").splitlines():
		line = raw.strip()
		if not line or line.startswith("#") or "=" not in line:
			continue
		key, value = line.split("=", 1)
		key = key.strip()
		if not key or not key.replace("_", "").isalnum():
			continue
		# Fill values the provider sanitized away, including ones passed as
		# empty strings. A real value from the provider still wins.
		if not os.environ.get(key, "").strip():
			os.environ[key] = value


def main() -> None:
	load_env(JOB_ENV)
	if not DISPATCH.is_file():
		print(f"amp-orb-dispatch: dispatcher {DISPATCH} is missing", file=sys.stderr)
		raise SystemExit(1)
	sys.argv[0] = str(DISPATCH)
	runpy.run_path(str(DISPATCH), run_name="__main__")


if __name__ == "__main__":
	main()
