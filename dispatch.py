#!/usr/bin/env python3
"""Dispatch Amp orb jobs to Docker Sandboxes Cloud.

Amp runs this program once per job with ORB_OPERATION, ORB_ID, and related
environment variables. The program is deliberately idempotent: a repeated job
must converge on the same cloud sandbox, not create another one.

State lives beside this program under state/. The cloud sandbox name is derived
from ORB_ID, so a missing state file can be reconciled with `sbx --cloud ls`.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(
    os.environ.get("AMP_ORBS_ROOT", Path.home() / "Development" / "amp-orbs")
).expanduser()
STATE_DIR = Path(os.environ.get("AMP_ORBS_STATE", ROOT / "state")).expanduser()
LOG_DIR = Path(os.environ.get("AMP_ORBS_LOGS", ROOT / "logs")).expanduser()
SBX = (
    os.environ.get("AMP_ORBS_SBX")
    or shutil.which("sbx")
    or ("/opt/homebrew/bin/sbx" if sys.platform == "darwin" else "/usr/local/bin/sbx")
)
# The orb base image, built from image/Dockerfile and published to Docker Hub.
IMAGE = os.environ.get("AMP_ORBS_IMAGE", "").strip()
PLATFORM = os.environ.get("AMP_ORBS_PLATFORM", "linux/amd64")
TEMPLATE_ARCH = PLATFORM.removeprefix("linux/")
TYPE_SPECS = {
    "micro": (1, 2048),
    "small": (2, 4096),
    "medium": (4, 8192),
    "large": (8, 16384),
    "xl": (16, 32768),
}
DEFAULT_ORB_TYPE = os.environ.get("AMP_ORBS_DEFAULT_TYPE", "medium").strip().lower()
if DEFAULT_ORB_TYPE not in TYPE_SPECS:
    DEFAULT_ORB_TYPE = "medium"
TTL = os.environ.get("AMP_ORBS_TTL", "24h")
# Docker Cloud never lets an expiry pass 24 hours after creation.
TTL_CEILING = 24 * 3600
TTL_MARGIN = 120
JOB_BUDGET = float(os.environ.get("AMP_ORBS_JOB_BUDGET", "280"))
SNAPSHOT_BUDGET = float(os.environ.get("AMP_ORBS_SNAPSHOT_BUDGET", "120"))
PAUSE_WAIT = float(os.environ.get("AMP_ORBS_PAUSE_WAIT", "150"))
SETTLE_BUDGET = float(os.environ.get("AMP_ORBS_SETTLE_BUDGET", "220"))
LOCK_WAIT = float(os.environ.get("AMP_ORBS_LOCK_WAIT", "30"))

JOB = ""
JOB_START = 0.0

BOOTSTRAP = r"""
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
# The image's agent environment: PATH, non-interactive pagers and editors,
# mise, and Chrome. Amp and every command it runs inherit it.
if [ -r /etc/profile.d/amp-orb.sh ]; then
	. /etc/profile.d/amp-orb.sh
fi
printf '\n=== spawn %s ===\n' "$(date -Is)" >> "$HOME/.amp-bootstrap.log"
printf 'pid1=%s shm=%s nofile=%s inotify_watches=%s browser_args=%s mem=%s earlyoom=%s\n' \
	"$(ps -o comm= -p 1 2>/dev/null || echo '?')" \
	"$(df -h --output=size /dev/shm 2>/dev/null | tail -1 | tr -d ' ' || echo '?')" \
	"$(ulimit -n)" \
	"$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo '?')" \
	"${AGENT_BROWSER_ARGS:-none}" \
	"$(free -m 2>/dev/null | awk '/^Mem:/ {print $7 "/" $2 "M"}' || echo '?')" \
	"$(pgrep -x earlyoom >/dev/null 2>&1 && echo on || echo off)" >> "$HOME/.amp-bootstrap.log"
# A token belongs to one spawn job and expires after 15 minutes, so an older
# bootstrap must not be reused after a pause.
pkill -x amp 2>/dev/null || true
for _ in $(seq 1 20); do
	pgrep -x amp >/dev/null 2>&1 || break
	sleep 0.2
done
pkill -9 -x amp 2>/dev/null || true
# tini -s becomes the subreaper for Amp's process tree, so orphaned dev servers,
# Chrome helpers, and test runners do not pile up as zombies when PID 1 does
# not reap them.
reaper=()
if command -v tini >/dev/null 2>&1; then
	reaper=(tini -s --)
fi
setsid "${reaper[@]}" amp orb bootstrap </dev/null >>"$HOME/.amp-bootstrap.log" 2>&1 &
echo "bootstrap started pid $!"
"""

LAUNCHER = r"""
set -euo pipefail
# Amp hardcodes /home/user and runs commands such as `install -o user -g user`.
# The image gives uid 1000 a user name, group, and home. Re-apply them in case
# the sandbox runtime rewrote /etc/passwd or /etc/group at boot. Only fix the
# top-level directories: a recursive chown would walk every checkout.
sudo install -d -o 1000 -g 1000 /home/user /home/user/.amp /home/user/.amp/bin \
	/home/user/.local /home/user/.local/bin /home/user/.local/state /home/user/go /home/user/go/bin
if getent group user >/dev/null 2>&1; then
	sudo sed -i -E 's|^user:x:[0-9]+:|user:x:1000:|' /etc/group
else
	echo 'user:x:1000:' | sudo tee -a /etc/group >/dev/null
fi
getent passwd user >/dev/null 2>&1 ||
	echo 'user:x:1000:1000::/home/user:/bin/bash' | sudo tee -a /etc/passwd >/dev/null
# Dev servers and file watchers run out of inotify watches and file descriptors
# at the default limits, and Chrome crashes when Docker's 64 MB /dev/shm fills.
# Raise what the VM allows. agent-env.sh falls back for anything still small.
sudo sysctl -q -w fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=1024 \
	>/dev/null 2>&1 || true
shm_kb=$(df -k --output=size /dev/shm 2>/dev/null | tail -1 | tr -d ' ')
case "$shm_kb" in '' | *[!0-9]*) shm_kb=0 ;; esac
if [ "$shm_kb" -lt 2097152 ]; then
	sudo mount -o remount,size=2g /dev/shm 2>/dev/null ||
		sudo mount -t tmpfs -o size=2g,mode=1777,nosuid,nodev tmpfs /dev/shm 2>/dev/null || true
fi
ulimit -n "$(ulimit -Hn)" 2>/dev/null || ulimit -n 1048576 2>/dev/null || true
# Without swap, when a leaked browser fills memory, the kernel thrashes
# for minutes before its OOM killer acts, and Amp misses its heartbeats until
# the orb is declared lost. earlyoom kills earlier: Chrome first, Amp last.
if command -v earlyoom >/dev/null 2>&1 && ! pgrep -x earlyoom >/dev/null 2>&1; then
	sudo setsid earlyoom -m 8,4 -r 0 -p \
		--prefer '^(chrome|chromium|chrome-headless|headless_shell)' \
		--avoid '^(amp|tini|earlyoom|sshd|dockerd|containerd)$' \
		</dev/null >>/home/user/.amp-earlyoom.log 2>&1 &
fi
cat > /home/user/.amp-orb-bootstrap.sh <<'AMP_ORB_BOOTSTRAP'
__BOOTSTRAP__
AMP_ORB_BOOTSTRAP
chmod 0755 /home/user/.amp-orb-bootstrap.sh
env HOME=/home/user USER=user \
	PATH=/home/user/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
	setsid bash /home/user/.amp-orb-bootstrap.sh \
	</dev/null >>/home/user/.amp-bootstrap.log 2>&1 &
echo launched
"""

BOOTSTRAP_CHECK = r"""
env HOME=/home/user bash -c '
if pgrep -x amp >/dev/null 2>&1; then
	echo RUNNING
else
	echo DEAD
	tail -40 /home/user/.amp-bootstrap.log 2>/dev/null || true
	exit 1
fi'
"""


class DispatchError(RuntimeError):
	"""A job failed and the provider log must say why."""


class SbxError(DispatchError):
	"""An sbx command failed."""


def log(message: str) -> None:
	prefix = f"{JOB}: " if JOB else ""
	stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
	print(f"[{stamp}] {prefix}{message}", file=sys.stderr, flush=True)


def tail(text: str, limit: int = 3000) -> str:
	text = (text or "").strip()
	return text[-limit:]


def run(
	args: list[str],
	*,
	timeout: float = 60,
	check: bool = True,
) -> subprocess.CompletedProcess[str]:
	command = [SBX, "--cloud", "--no-input", *args]
	try:
		proc = subprocess.run(
			command,
			capture_output=True,
			text=True,
			timeout=timeout,
		)
	except FileNotFoundError as error:
		raise DispatchError(f"sbx not found at {SBX}") from error
	except subprocess.TimeoutExpired as error:
		raise SbxError(
			f"sbx {' '.join(args)} timed out after {timeout:.0f}s"
		) from error
	if check and proc.returncode != 0:
		raise SbxError(
			f"sbx {' '.join(args)} exited {proc.returncode}: "
			f"{tail(proc.stderr or proc.stdout)}"
		)
	return proc


def json_run(args: list[str], *, timeout: float = 60) -> Any:
	proc = run(args, timeout=timeout)
	try:
		return json.loads(proc.stdout)
	except json.JSONDecodeError as error:
		raise DispatchError(
			f"sbx {' '.join(args)} returned invalid JSON: {tail(proc.stdout)}"
		) from error


def sandbox_name(orb_id: str) -> str:
	"""Map ORB_ID to a valid Docker Cloud sandbox name.

	Docker allows 2-63 ASCII letters, numbers and hyphens, starting and ending
	with a letter or number, and reserves "default". ORB_ID normally already
	fits, so it is used unchanged. Anything else gets a short hash suffix to
	keep the mapping deterministic and collision-resistant.
	"""
	name = re.sub(r"[^A-Za-z0-9-]+", "-", orb_id)
	name = re.sub(r"-{2,}", "-", name).strip("-")
	if (
		name != orb_id
		or not 2 <= len(name) <= 63
		or name == "default"
	):
		digest = hashlib.sha256(orb_id.encode()).hexdigest()[:8]
		prefix = (name or "amp-orb")[:54].rstrip("-")
		name = f"{prefix}-{digest}" if prefix else f"amp-orb-{digest}"
	return name[:63].rstrip("-")


def orb_key(orb_id: str) -> str:
	return hashlib.sha256(orb_id.encode()).hexdigest()[:24]


def state_path(orb_id: str) -> Path:
	return STATE_DIR / "orbs" / f"{orb_key(orb_id)}.json"


def read_state(orb_id: str) -> dict[str, Any] | None:
	path = state_path(orb_id)
	try:
		with path.open() as handle:
			value = json.load(handle)
	except FileNotFoundError:
		return None
	except (OSError, json.JSONDecodeError) as error:
		log(f"ignoring unreadable state file {path}: {error}")
		return None
	return value if isinstance(value, dict) else None


def write_state(orb_id: str, sandbox_id: str, name: str) -> None:
	path = state_path(orb_id)
	path.parent.mkdir(parents=True, exist_ok=True)
	now = time.strftime("%Y-%m-%dT%H:%M:%S%z")
	previous = read_state(orb_id) or {}
	value = {
		"orb_id": orb_id,
		"sandbox_id": sandbox_id,
		"name": name,
		"created_at": previous.get("created_at", now),
		"updated_at": now,
	}
	temporary = path.with_suffix(".tmp")
	with temporary.open("w") as handle:
		json.dump(value, handle, indent=2)
		handle.write("\n")
	os.replace(temporary, path)


def remove_state(orb_id: str) -> None:
	try:
		state_path(orb_id).unlink()
	except FileNotFoundError:
		pass


@contextmanager
def orb_lock(orb_id: str):
	path = STATE_DIR / "locks" / f"{orb_key(orb_id)}.lock"
	path.parent.mkdir(parents=True, exist_ok=True)
	with path.open("w") as handle:
		deadline = time.monotonic() + LOCK_WAIT
		while True:
			try:
				fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
				break
			except BlockingIOError:
				if time.monotonic() >= deadline:
					raise DispatchError(
						"another dispatch job still holds this orb's lock"
					)
				time.sleep(0.5)
		try:
			yield
		finally:
			fcntl.flock(handle, fcntl.LOCK_UN)


def is_missing(text: str) -> bool:
	lowered = text.lower()
	return any(
		marker in lowered
		for marker in (
			"not found",
			"does not exist",
			"no such sandbox",
			"unknown sandbox",
		)
	)


def inspect_sandbox(reference: str) -> dict[str, Any] | None:
	proc = run(
		["inspect", reference, "--format", "json"],
		timeout=60,
		check=False,
	)
	if proc.returncode == 0:
		try:
			value = json.loads(proc.stdout)
		except json.JSONDecodeError as error:
			raise DispatchError(
				f"inspect {reference} returned invalid JSON: {tail(proc.stdout)}"
			) from error
		return value if isinstance(value, dict) else None
	if proc.returncode == 4 or is_missing(proc.stderr + proc.stdout):
		return None
	raise SbxError(
		f"sbx inspect {reference} exited {proc.returncode}: "
		f"{tail(proc.stderr or proc.stdout)}"
	)


def list_sandboxes() -> list[dict[str, Any]]:
	value = json_run(["ls", "--format", "json"])
	if not isinstance(value, list):
		raise DispatchError(f"unexpected sandbox list: {tail(str(value))}")
	return [item for item in value if isinstance(item, dict)]


def find_by_name(name: str) -> dict[str, Any] | None:
	matches = [item for item in list_sandboxes() if item.get("name") == name]
	if len(matches) > 1:
		ids = ", ".join(str(item.get("id")) for item in matches)
		raise DispatchError(
			f"{len(matches)} cloud sandboxes are named {name!r}: {ids}"
		)
	return matches[0] if matches else None


def resolve(orb_id: str) -> dict[str, Any] | None:
	"""Find the sandbox for ORB_ID, repairing a missing or stale mapping."""
	name = sandbox_name(orb_id)
	state = read_state(orb_id)
	if state and state.get("sandbox_id"):
		info = inspect_sandbox(str(state["sandbox_id"]))
		if info:
			if info.get("name") != state.get("name"):
				write_state(orb_id, str(info["id"]), str(info.get("name") or name))
			return info
		log(
			f"mapped sandbox {state['sandbox_id']} is gone; "
			f"reconciling by name {name}"
		)
	info = find_by_name(name)
	if info:
		full = inspect_sandbox(str(info["id"])) or info
		log(f"reconciled to {full['id']} by name {name}")
		write_state(orb_id, str(full["id"]), name)
		return full
	return None


def template_info(name: str) -> dict[str, Any] | None:
	proc = run(
		["template", "inspect", name, "--format", "json"],
		timeout=60,
		check=False,
	)
	if proc.returncode == 0:
		try:
			value = json.loads(proc.stdout)
		except json.JSONDecodeError as error:
			raise DispatchError(
				f"template inspect {name} returned invalid JSON: "
				f"{tail(proc.stdout)}"
			) from error
		return value if isinstance(value, dict) else None
	if proc.returncode == 4 or is_missing(proc.stderr + proc.stdout):
		return None
	raise SbxError(
		f"sbx template inspect {name} exited {proc.returncode}: "
		f"{tail(proc.stderr or proc.stdout)}"
	)


def template_usable(name: str) -> dict[str, Any] | None:
	info = template_info(name)
	if not info:
		return None
	status = str(info.get("status") or "")
	if status and status != "completed":
		log(f"template {name} is {status}, not completed")
		return None
	architecture = info.get("architecture")
	if architecture and architecture != TEMPLATE_ARCH:
		log(
			f"template {name} is {architecture}, expected "
			f"{TEMPLATE_ARCH}; not using it"
		)
		return None
	return info


def snapshot_template_name(snapshot_id: str) -> str:
	digest = hashlib.sha256(snapshot_id.encode()).hexdigest()[:16]
	return f"amp-snap-{digest}"


def create_sandbox(
	orb_id: str, snapshot_id: str | None, orb_type: str
) -> dict[str, Any]:
	name = sandbox_name(orb_id)
	cpus, memory_mib = TYPE_SPECS[orb_type]
	shape = f"{cpus} vCPU/{memory_mib} MiB"
	source: list[str] = []
	if snapshot_id:
		snapshot_template = snapshot_template_name(snapshot_id)
		snapshot_info = template_usable(snapshot_template)
		if not snapshot_info:
			log(
				f"WARNING project snapshot {snapshot_template} is missing or "
				"not usable; booting the base image and running .agents/setup"
			)
		elif (snapshot_info.get("cpus"), snapshot_info.get("memory_mib")) != (
			cpus,
			memory_mib,
		):
			log(
				f"WARNING project snapshot {snapshot_template} is "
				f"{snapshot_info.get('cpus')} vCPU/"
				f"{snapshot_info.get('memory_mib')} MiB, expected {shape} for "
				f"{orb_type}; booting the base image and running .agents/setup"
			)
		else:
			# A template carries its own CPU and memory; sbx rejects --cpus
			# and --memory with --template.
			source = ["--template", snapshot_template]
	if not source:
		if not IMAGE:
			raise DispatchError(
				"AMP_ORBS_IMAGE is not set; set it to the published orb image, "
				"such as docker.io/<user>/amp-orb:latest"
			)
		source = [
			"--image-ref",
			IMAGE,
			"--cpus",
			str(cpus),
			"--memory",
			f"{memory_mib // 1024}g",
			"--platform",
			PLATFORM,
		]
	log(f"creating cloud sandbox {name} from {source[1]} ({orb_type}: {shape})")
	proc = run(
		[
			"create",
			"--name",
			name,
			*source,
			"--ttl",
			TTL,
			"--on-timeout",
			"stop",
			"--no-progress",
		],
		# The first create from a new image tag pulls the image.
		timeout=240,
		check=False,
	)
	if proc.returncode != 0:
		existing = find_by_name(name)
		if existing:
			full = inspect_sandbox(str(existing["id"])) or existing
			log(
				f"create reported an error but {full['id']} already "
				f"exists; using it"
			)
			write_state(orb_id, str(full["id"]), name)
			return full
		raise SbxError(
			f"sbx create exited {proc.returncode}: "
			f"{tail(proc.stderr or proc.stdout)}"
		)
	match = re.search(r"\bsbx_[A-Za-z0-9]+\b", proc.stdout + "\n" + proc.stderr)
	info = inspect_sandbox(match.group(0)) if match else None
	if not info:
		info = find_by_name(name)
	if not info:
		raise DispatchError(
			f"create succeeded but no sandbox named {name!r} was found"
		)
	write_state(orb_id, str(info["id"]), name)
	log(f"created {info['id']} ({name})")
	return info


def wait_for_state(
	sandbox_id: str,
	desired: set[str],
	budget: float,
	poll: float = 3,
) -> dict[str, Any]:
	deadline = time.monotonic() + budget
	last = "unknown"
	while time.monotonic() < deadline:
		info = inspect_sandbox(sandbox_id)
		if info is None:
			raise DispatchError(f"sandbox {sandbox_id} disappeared")
		last = str(info.get("state") or "unknown")
		if last in desired:
			return info
		if last in {"error", "failed"}:
			raise DispatchError(
				f"sandbox {sandbox_id} entered state {last}"
			)
		time.sleep(poll)
	raise DispatchError(
		f"timed out waiting for {sandbox_id} to reach "
		f"{', '.join(sorted(desired))}; last state was {last}"
	)


def ensure_running(sandbox_id: str) -> bool:
	"""Return True when this call resumed a stopped sandbox."""
	info = inspect_sandbox(sandbox_id)
	if info is None:
		raise DispatchError(f"sandbox {sandbox_id} no longer exists")
	state = str(info.get("state") or "unknown")
	if state == "running":
		return False
	if state in {"stopping", "hibernating"}:
		log(f"{sandbox_id} is {state}; waiting for it to settle")
		info = wait_for_state(sandbox_id, {"stopped"}, SETTLE_BUDGET)
		state = str(info.get("state") or "stopped")
	if state == "starting":
		log(f"{sandbox_id} is starting; waiting for it")
		wait_for_state(sandbox_id, {"running"}, 120)
		return True
	if state == "stopped":
		log(f"{sandbox_id} is stopped; resuming")
		proc = run(["exec", sandbox_id, "true"], timeout=120, check=False)
		if proc.returncode != 0:
			raise SbxError(
				f"could not resume {sandbox_id}: "
				f"{tail(proc.stderr or proc.stdout)}"
			)
		wait_for_state(sandbox_id, {"running"}, 120)
		return True
	if state in {"error", "failed"}:
		raise DispatchError(f"sandbox {sandbox_id} is in state {state}")
	log(f"{sandbox_id} is {state}; trying to start it")
	proc = run(["exec", sandbox_id, "true"], timeout=120, check=False)
	if proc.returncode != 0:
		raise SbxError(
			f"could not start {sandbox_id}: "
			f"{tail(proc.stderr or proc.stdout)}"
		)
	wait_for_state(sandbox_id, {"running"}, 120)
	return True


def parse_time(value: Any) -> float | None:
	"""Parse an RFC 3339 timestamp from sbx into epoch seconds."""
	if not isinstance(value, str) or not value:
		return None
	text = value.strip().replace("Z", "+00:00")
	# Python accepts at most six fractional digits; sbx may send nine.
	text = re.sub(r"(\.\d{6})\d+", r"\1", text)
	try:
		return datetime.fromisoformat(text).timestamp()
	except ValueError:
		return None


def clock(epoch: float) -> str:
	return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def refresh_ttl(sandbox_id: str) -> None:
	"""Push a running sandbox's expiry to Docker Cloud's 24-hour ceiling.

	`create --ttl` sets only the first period. A stopped sandbox that resumes
	gets the server's resume timeout instead, so without this an orb stops that
	long after every wake, however busy it is. `sbx ttl` cannot extend past 24
	hours after creation, so an older sandbox keeps the resume timeout.
	"""
	info = inspect_sandbox(sandbox_id) or {}
	created = parse_time(info.get("created_at"))
	expires = parse_time(info.get("expires_at"))
	if created is None or expires is None:
		log(
			f"WARNING cannot read the TTL of {sandbox_id}: created_at="
			f"{info.get('created_at')!r} expires_at={info.get('expires_at')!r}"
		)
		return
	ceiling = created + TTL_CEILING
	gap = int(ceiling - TTL_MARGIN - expires)
	if gap >= 60:
		proc = run(["ttl", f"+{gap}s", sandbox_id], timeout=60, check=False)
		if proc.returncode == 0:
			expires = parse_time((inspect_sandbox(sandbox_id) or {}).get("expires_at")) or expires
		else:
			log(f"WARNING could not extend the TTL: {tail(proc.stderr or proc.stdout)}")
	now = time.time()
	log(
		f"sandbox expires at {clock(expires)}, in {(expires - now) / 3600:.1f}h; "
		f"Docker's 24h ceiling is {clock(ceiling)}"
	)
	if expires - now < 2 * 3600:
		log(
			f"WARNING this orb stops at {clock(expires)}: the sandbox was created "
			f"{(now - created) / 3600:.1f}h ago and Docker Cloud cannot extend it "
			"past 24 hours after creation"
		)


def start_bootstrap(
	sandbox_id: str, token: str, amp_url: str | None
) -> None:
	env_args = ["-e", f"ORB_TOKEN={token}"]
	if amp_url:
		env_args += ["-e", f"AMP_URL={amp_url}"]
	log("restarting bootstrap with this spawn job's token")
	launcher = LAUNCHER.replace("__BOOTSTRAP__", BOOTSTRAP.strip())
	proc = run(
		[
			"exec",
			*env_args,
			sandbox_id,
			"bash",
			"-lc",
			launcher,
		],
		timeout=120,
		check=False,
	)
	if proc.returncode != 0:
		raise SbxError(
			f"bootstrap launch failed: {tail(proc.stderr or proc.stdout)}"
		)
	# A rejected or immediately crashing bootstrap exits in under a second.
	# Do not report success until the process has survived the first seconds.
	time.sleep(4)
	check = run(
		["exec", sandbox_id, "bash", "-lc", BOOTSTRAP_CHECK],
		timeout=60,
		check=False,
	)
	if check.returncode != 0:
		raise DispatchError(
			"bootstrap did not survive: "
			f"{tail(check.stdout + check.stderr)}"
		)
	log("bootstrap is running")


def save_snapshot(
	sandbox_id: str, snapshot_id: str, remaining: float
) -> bool:
	name = snapshot_template_name(snapshot_id)
	try:
		if template_usable(name):
			log(f"project snapshot {name} already exists; not saving again")
			return True
	except DispatchError as error:
		log(f"could not inspect snapshot template {name}: {error}")
	timeout = min(
		SNAPSHOT_BUDGET,
		max(30.0, remaining - PAUSE_WAIT - 20.0),
	)
	log(
		f"saving project snapshot {snapshot_id} as {name} "
		f"(timeout {timeout:.0f}s)"
	)
	started = time.monotonic()
	try:
		proc = run(
			[
				"template",
				"save",
				sandbox_id,
				name,
				"--description",
				f"amp-orb-snapshot snapshot={snapshot_id}",
				"--capture-mode",
				"disk",
			],
			timeout=timeout,
			check=False,
		)
	except DispatchError as error:
		log(f"ERROR snapshot save failed: {error}")
		return False
	elapsed = time.monotonic() - started
	if proc.returncode != 0:
		log(
			f"ERROR snapshot save exited {proc.returncode} after "
			f"{elapsed:.0f}s: {tail(proc.stderr or proc.stdout)}"
		)
		return False
	log(f"project snapshot {name} saved in {elapsed:.0f}s")
	return True


def pause(orb_id: str) -> None:
	info = resolve(orb_id)
	if info is None:
		log("no cloud sandbox exists; nothing to pause")
		return
	sandbox_id = str(info["id"])
	state = str(info.get("state") or "unknown")
	snapshot_id = os.environ.get("ORB_SNAPSHOT_ID") or None
	if state == "starting":
		log(f"{sandbox_id} is starting; waiting for it")
		info = wait_for_state(sandbox_id, {"running"}, 120)
		state = str(info.get("state") or "running")
	if snapshot_id:
		if state == "running":
			save_snapshot(
				sandbox_id,
				snapshot_id,
				JOB_BUDGET - (time.monotonic() - JOB_START),
			)
		else:
			log(
				f"ORB_SNAPSHOT_ID is set but the sandbox is {state}; "
				"cannot save a snapshot from a stopped sandbox"
			)
	if state == "stopped":
		log("sandbox is already stopped; disk preserved")
		return
	if state in {"stopping", "hibernating"}:
		try:
			wait_for_state(sandbox_id, {"stopped"}, PAUSE_WAIT)
			log("sandbox finished stopping; disk preserved")
		except DispatchError as error:
			log(f"stop is still settling; leaving it: {error}")
		return
	log(f"stopping {sandbox_id}")
	proc = run(["stop", sandbox_id], timeout=60, check=False)
	if proc.returncode != 0:
		current = inspect_sandbox(sandbox_id)
		if current and current.get("state") == "stopped":
			log("sandbox is stopped; disk preserved")
			return
		if current is None:
			log("sandbox disappeared while stopping")
			return
		raise SbxError(
			f"stop exited {proc.returncode}: "
			f"{tail(proc.stderr or proc.stdout)}"
		)
	try:
		wait_for_state(sandbox_id, {"stopped"}, PAUSE_WAIT)
		log("sandbox stopped; disk and memory preserved")
	except DispatchError as error:
		log(f"stop accepted; sandbox is still settling: {error}")


def delete(orb_id: str) -> None:
	info = resolve(orb_id)
	if info is None:
		remove_state(orb_id)
		log("no cloud sandbox exists; state removed")
		return
	sandbox_id = str(info["id"])
	state = str(info.get("state") or "unknown")
	if state in {"stopping", "hibernating"}:
		try:
			wait_for_state(sandbox_id, {"stopped"}, SETTLE_BUDGET)
		except DispatchError as error:
			log(f"continuing to delete while {state}: {error}")
	log(f"removing {sandbox_id}")
	deadline = time.monotonic() + JOB_BUDGET
	removed = False
	while time.monotonic() < deadline:
		proc = run(["rm", "--force", sandbox_id], timeout=90, check=False)
		if proc.returncode == 0:
			removed = True
			break
		text = proc.stderr + proc.stdout
		if is_missing(text):
			removed = True
			break
		lowered = text.lower()
		if (
			"hibernating" in lowered
			or "failed_precondition" in lowered
			or "in use" in lowered
			or "starting" in lowered
			or "stopping" in lowered
		):
			log("removal is waiting for the sandbox workflow; retrying")
			time.sleep(5)
			continue
		raise SbxError(
			f"rm exited {proc.returncode}: {tail(proc.stderr or proc.stdout)}"
		)
	if not removed:
		raise DispatchError(f"timed out removing {sandbox_id}")
	for _ in range(20):
		if inspect_sandbox(sandbox_id) is None:
			break
		time.sleep(3)
	else:
		log(f"WARNING {sandbox_id} is still listed after removal; verify with sbx --cloud ls")
	remove_state(orb_id)
	log("sandbox removed; state removed")


def spawn(orb_id: str) -> None:
	token = os.environ.get("ORB_TOKEN")
	if not token:
		raise DispatchError("ORB_TOKEN is required for spawn")
	requested_type = (os.environ.get("ORB_TYPE") or "").strip().lower()
	orb_type = requested_type or DEFAULT_ORB_TYPE
	if orb_type not in TYPE_SPECS:
		log(f"unknown ORB_TYPE={requested_type!r}; using {DEFAULT_ORB_TYPE}")
		orb_type = DEFAULT_ORB_TYPE
	expected = TYPE_SPECS[orb_type]
	shape = f"{expected[0]} vCPU/{expected[1]} MiB"
	log(f"orb type {orb_type}: {shape}")
	image = os.environ.get("ORB_IMAGE")
	if image:
		log(
			f"ORB_IMAGE={image} ignored; Docker Cloud only accepts Docker Hub "
			f"images, so orbs boot from {IMAGE or 'AMP_ORBS_IMAGE'}"
		)
	info = resolve(orb_id)
	if info is None:
		info = create_sandbox(
			orb_id,
			os.environ.get("ORB_SNAPSHOT_ID") or None,
			orb_type,
		)
	else:
		actual = (info.get("cpus"), info.get("memory_mib"))
		if actual != expected:
			log(
				f"WARNING existing sandbox is {actual[0]} vCPU/"
				f"{actual[1]} MiB, requested {orb_type} is {shape}; "
				"keeping the existing size"
			)
		log(
			f"found {info['id']} ({info.get('state')})"
		)
	sandbox_id = str(info["id"])
	ensure_running(sandbox_id)
	try:
		refresh_ttl(sandbox_id)
	except DispatchError as error:
		log(f"WARNING TTL refresh failed: {error}")
	start_bootstrap(
		sandbox_id,
		token,
		os.environ.get("AMP_URL") or None,
	)


def main() -> None:
	global JOB, JOB_START
	operation = os.environ.get("ORB_OPERATION")
	orb_id = os.environ.get("ORB_ID")
	if not operation or not orb_id:
		raise DispatchError("ORB_OPERATION and ORB_ID are required")
	JOB = f"{operation} {orb_id}"
	JOB_START = time.monotonic()
	STATE_DIR.mkdir(parents=True, exist_ok=True)
	LOG_DIR.mkdir(parents=True, exist_ok=True)
	log("starting")
	with orb_lock(orb_id):
		if operation == "spawn":
			spawn(orb_id)
		elif operation == "pause":
			pause(orb_id)
		elif operation == "delete":
			delete(orb_id)
		else:
			raise DispatchError(f"unknown ORB_OPERATION {operation!r}")
	log(f"finished in {time.monotonic() - JOB_START:.1f}s")


if __name__ == "__main__":
	try:
		main()
	except Exception as error:
		log(f"ERROR {error}")
		if os.environ.get("AMP_ORBS_DEBUG"):
			traceback.print_exc()
		sys.exit(1)
