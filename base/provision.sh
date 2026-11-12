#!/usr/bin/env bash
# Provision the Docker Sandboxes cloud template used by the Amp orb provider.
# Runs inside a `shell` cloud sandbox as the default `agent` user.
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-24.22.3}"
GO_VERSION="${GO_VERSION:-1.27.4}"
BUN_VERSION="${BUN_VERSION:-1.4.4}"
TYPST_VERSION="${TYPST_VERSION:-0.15.1}"

export DEBIAN_FRONTEND=noninteractive

case "$(uname -m)" in
	aarch64 | arm64)
		node_arch=arm64
		go_arch=arm64
		bun_arch=aarch64
		typst_arch=aarch64
		;;
	x86_64 | amd64)
		node_arch=x64
		go_arch=amd64
		bun_arch=x64
		typst_arch=x86_64
		;;
	*)
		echo "unsupported architecture: $(uname -m)" >&2
		exit 1
		;;
esac

echo "==> apt packages"
sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends \
	build-essential pkg-config libssl-dev libsqlite3-dev \
	ca-certificates curl wget gnupg \
	fd-find bat yq zip unzip xz-utils zstd \
	vim less tree fzf shellcheck sqlite3 git-lfs

echo "==> Node ${NODE_VERSION}"
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz
sudo rm -rf /usr/local/lib/nodejs
sudo mkdir -p /usr/local/lib/nodejs
sudo tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs --strip-components=1
for binary in node npm npx corepack; do
	sudo ln -sf "/usr/local/lib/nodejs/bin/${binary}" "/usr/local/bin/${binary}"
done

echo "==> pnpm"
sudo /usr/local/bin/npm install -g --silent pnpm@11
sudo ln -sf /usr/local/lib/nodejs/bin/pnpm /usr/local/bin/pnpm
sudo ln -sf /usr/local/lib/nodejs/bin/pnpx /usr/local/bin/pnpx

echo "==> Bun ${BUN_VERSION}"
curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_arch}.zip" -o /tmp/bun.zip
sudo rm -rf /usr/local/lib/bun
sudo mkdir -p /usr/local/lib/bun
sudo unzip -q -o /tmp/bun.zip -d /usr/local/lib/bun
sudo ln -sf "/usr/local/lib/bun/bun-linux-${bun_arch}/bun" /usr/local/bin/bun

echo "==> Go ${GO_VERSION}"
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz" -o /tmp/go.tar.gz
sudo rm -rf /usr/local/go
sudo tar -xzf /tmp/go.tar.gz -C /usr/local
sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

echo "==> Typst ${TYPST_VERSION}"
curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${typst_arch}-unknown-linux-musl.tar.xz" -o /tmp/typst.tar.xz
sudo tar -xJf /tmp/typst.tar.xz -C /usr/local/bin --strip-components=1 "typst-${typst_arch}-unknown-linux-musl/typst"
sudo chmod 0755 /usr/local/bin/typst

echo "==> Amp CLI"
curl -fsSL https://ampcode.com/install.sh | bash
sudo ln -sf "${HOME}/.amp/bin/amp" /usr/local/bin/amp

echo "==> Amp user layout"
# Amp hardcodes /home/user and runs commands such as `install -o user -g user`.
# The shell template's managed user account shares uid 1000 with agent, but its
# passwd entry is reset at boot, so do not rely on changing it. Run bootstrap as
# the default agent account with HOME=/home/user, create that home, and give the
# user group gid 1000 so -o user -g user resolves to the process's own ids.
if getent group user >/dev/null; then
	sudo sed -i -E 's|^user:x:[0-9]+:|user:x:1000:|' /etc/group
else
	echo 'user:x:1000:' | sudo tee -a /etc/group >/dev/null
fi
getent group user | grep -q ':1000:' || {
	echo "failed to give the user group gid 1000" >&2
	exit 1
}
sudo mkdir -p /home/user/.amp/bin /home/user/.local/bin /home/user/.local/state /home/user/go/bin
sudo chown -R 1000:1000 /home/user
[ -e /home/user/.amp/bin/amp ] || sudo ln -s "${HOME}/.amp/bin/amp" /home/user/.amp/bin/amp
[ -e /home/user/.local/bin/amp ] || sudo ln -s "${HOME}/.amp/bin/amp" /home/user/.local/bin/amp
sudo chown -h 1000:1000 /home/user/.amp/bin/amp /home/user/.local/bin/amp
env HOME=/home/user USER=user bash -lc '
	echo "user HOME=$HOME"
	id
	install -d -o user -g user -m 0755 /home/user/.local/state
	echo user-layout-ok
'

echo "==> convenience symlinks and PATH"
sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd
sudo ln -sf /usr/bin/batcat /usr/local/bin/bat
sudo tee /etc/profile.d/amp-dev.sh >/dev/null <<'EOF'
export PATH="$HOME/.local/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
EOF
if ! grep -q 'amp-dev PATH' "${HOME}/.bashrc" 2>/dev/null; then
	cat >>"${HOME}/.bashrc" <<'EOF'

# amp-dev PATH
export PATH="$HOME/.local/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
EOF
fi
mkdir -p "${HOME}/go/bin"

echo "==> cleanup"
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
rm -rf /tmp/node.tar.xz /tmp/go.tar.gz /tmp/bun.zip /tmp/typst.tar.xz /tmp/*.log

echo "==> versions"
node --version
npm --version
pnpm --version
bun --version
go version
python3 --version
uv --version
typst --version
getent passwd user
git --version
gh --version | head -1
rg --version | head -1
tmux -V
amp --version
df -h / | tail -1
