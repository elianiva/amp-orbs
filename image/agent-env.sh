# Environment for agents in an Amp orb. Login shells source this file from
# /etc/profile.d, and the dispatcher sources it before `amp orb bootstrap`, so
# Amp and every command it runs get the same settings.

# mise shims come first, so a version a repository pins with mise wins over the
# image's own Node, Go, and Python.
export PATH="/home/user/.local/share/mise/shims:/home/user/.local/bin:/home/user/.amp/bin:/home/user/go/bin:/usr/local/share/npm-global/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LANG=C.UTF-8
export NPM_CONFIG_PREFIX=/usr/local/share/npm-global

# Agents have no TTY. A pager, editor, or credential prompt hangs or fails with
# a confusing error, so turn them off.
export PAGER=cat GIT_PAGER=cat MANPAGER=cat SYSTEMD_PAGER=cat
export GIT_TERMINAL_PROMPT=0 GIT_EDITOR=true
export PIP_NO_INPUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1
export NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false NPM_CONFIG_UPDATE_NOTIFIER=false

# mise installs dev tools on demand, such as `mise use -g rust@1.95`. Keep its
# state under Amp's home whatever HOME is, so project snapshots capture it.
export MISE_DATA_DIR=/home/user/.local/share/mise
export MISE_CONFIG_DIR=/home/user/.config/mise
export MISE_CACHE_DIR=/home/user/.cache/mise
export MISE_YES=1

# Let Puppeteer and other tools reuse agent-browser's Chrome instead of
# downloading their own.
export CHROME_PATH=/usr/local/bin/google-chrome
export PUPPETEER_EXECUTABLE_PATH=/usr/local/bin/google-chrome
export PUPPETEER_SKIP_DOWNLOAD=true

# Agents often leave a browser open when they move on. agent-browser shuts its
# daemon and Chrome down after this much inactivity (its default is 1h). The
# next command starts a fresh browser, without the old tabs and cookies.
export AGENT_BROWSER_IDLE_TIMEOUT_MS="${AGENT_BROWSER_IDLE_TIMEOUT_MS:-900000}"

# Chrome keeps renderer memory in /dev/shm, and tabs crash when it fills up.
# The dispatcher grows it at spawn. If it is still under 1 GiB, make Chrome
# use /tmp instead. Re-check a fallback this file set earlier, because a shell
# that loaded it before the dispatcher grew /dev/shm passes the value on.
if [ -z "${AGENT_BROWSER_ARGS:-}" ] || [ -n "${AMP_ORB_SHM_FALLBACK:-}" ]; then
	unset AGENT_BROWSER_ARGS AMP_ORB_SHM_FALLBACK
	_amp_shm=$(df -k --output=size /dev/shm 2>/dev/null | tail -1 | tr -d ' ')
	case "$_amp_shm" in
		'' | *[!0-9]*) ;;
		*)
			if [ "$_amp_shm" -lt 1048576 ]; then
				export AGENT_BROWSER_ARGS=--disable-dev-shm-usage AMP_ORB_SHM_FALLBACK=1
			fi
			;;
	esac
	unset _amp_shm
fi

# Docker Sandboxes can route HTTPS through a TLS-inspecting egress proxy and
# publishes its CA as PROXY_CA_CERT_B64. Chrome on Linux ignores the system CA
# bundle, so hand the CA to agent-browser explicitly.
if [ -n "${PROXY_CA_CERT_B64:-}" ] && [ -z "${AGENT_BROWSER_CA_CERT:-}" ]; then
	_amp_ca="${HOME:-/home/user}/.cache/sbx-proxy-ca.crt"
	if mkdir -p "${_amp_ca%/*}" 2>/dev/null &&
		printf '%s' "$PROXY_CA_CERT_B64" | base64 -d >"$_amp_ca" 2>/dev/null; then
		export AGENT_BROWSER_CA_CERT="$_amp_ca"
	fi
	unset _amp_ca
fi
