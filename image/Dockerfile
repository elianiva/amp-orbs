# syntax=docker/dockerfile:1
#
# Base image for Amp orbs on Docker Sandboxes Cloud.
#
# Build and push it once, then point the provider at it with AMP_ORBS_IMAGE:
#   docker buildx build --platform linux/amd64 -t docker.io/<user>/amp-orb:<tag> --push image/
#
# Docker Cloud pulls inline images only from Docker Hub and dhi.io.

ARG BASE_IMAGE=docker.io/sbx/shell:latest
FROM ${BASE_IMAGE}

ARG TARGETARCH
ARG NODE_VERSION=26.13.1
ARG PNPM_VERSION=12.18.0
ARG BUN_VERSION=1.4.4
ARG GO_VERSION=1.27.4
ARG TYPST_VERSION=0.15.1
ARG YQ_VERSION=4.54.3
ARG MISE_VERSION=2026.11.8
ARG AST_GREP_VERSION=0.51.2
ARG AGENT_BROWSER_VERSION=latest

USER root
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# The build environment. Orb sessions get theirs from agent-env.sh, which
# /etc/profile.d and the dispatcher's bootstrap both load.
ENV LANG=C.UTF-8 \
	DEBIAN_FRONTEND=noninteractive \
	NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
	PATH=/home/user/.local/share/mise/shims:/home/user/.local/bin:/home/user/.amp/bin:/home/user/go/bin:/home/agent/.local/bin:/usr/local/share/npm-global/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN <<'EOF'
apt-get update
apt-get install -y --no-install-recommends \
	build-essential pkg-config libssl-dev libsqlite3-dev \
	ca-certificates curl wget gnupg openssh-client git-lfs \
	fd-find bat fzf shellcheck sqlite3 tree less \
	zip unzip xz-utils zstd file rsync procps psmisc lsof strace earlyoom \
	ffmpeg imagemagick fonts-liberation fonts-noto-color-emoji
ln -sf /usr/bin/fdfind /usr/local/bin/fd
ln -sf /usr/bin/batcat /usr/local/bin/bat
# The base image prints a large banner on the first login shell. Agents read
# command output, so drop it.
rm -f /etc/profile.d/01-dhi.sh
rm -rf /var/lib/apt/lists/*
EOF

RUN <<'EOF'
case "${TARGETARCH:-amd64}" in
	amd64) node=x64 go=amd64 bun=x64 typst=x86_64 yq=amd64 mise=x64 sg=x86_64 ;;
	arm64) node=arm64 go=arm64 bun=aarch64 typst=aarch64 yq=arm64 mise=arm64 sg=aarch64 ;;
	*) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;;
esac
cd /tmp

curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node}.tar.xz" -o node.tar.xz
mkdir -p /usr/local/lib/nodejs
tar -xJf node.tar.xz -C /usr/local/lib/nodejs --strip-components=1
for binary in node npm npx; do
	ln -sf "/usr/local/lib/nodejs/bin/${binary}" "/usr/local/bin/${binary}"
done

curl -fsSL "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun}.zip" -o bun.zip
unzip -q bun.zip
install -m 0755 "bun-linux-${bun}/bun" /usr/local/bin/bun
ln -sf bun /usr/local/bin/bunx

curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${go}.tar.gz" | tar -xz -C /usr/local

curl -fsSL "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${typst}-unknown-linux-musl.tar.xz" |
	tar -xJ -C /usr/local/bin --strip-components=1 "typst-${typst}-unknown-linux-musl/typst"

curl -fsSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${yq}" -o /usr/local/bin/yq
chmod 0755 /usr/local/bin/yq /usr/local/bin/typst

# mise installs other dev tools on demand, such as Rust, Java, or Ruby.
curl -fsSL "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${mise}" -o /usr/local/bin/mise
chmod 0755 /usr/local/bin/mise

# ast-grep for structural code search. The archive also has `sg`, which would
# shadow the system's `sg` command, so install only ast-grep.
curl -fsSL "https://github.com/ast-grep/ast-grep/releases/download/${AST_GREP_VERSION}/app-${sg}-unknown-linux-gnu.zip" -o sg.zip
unzip -q sg.zip ast-grep -d /usr/local/bin

rm -rf /tmp/*
EOF

# Amp hardcodes /home/user and runs commands such as `install -o user -g user`.
# Give uid 1000 a second name, user, with that home. agent stays the first
# uid 1000 entry, so Docker Sandboxes and sudo still resolve uid 1000 to agent.
RUN <<'EOF'
groupadd -o -g 1000 user
useradd -o -u 1000 -g 1000 -d /home/user -M -s /bin/bash user
install -d -o 1000 -g 1000 /home/user /home/user/.local /home/user/.local/bin \
	/home/user/.local/state /home/user/.amp /home/user/.amp/bin /home/user/go /home/user/go/bin
cp /home/agent/.bashrc /home/agent/.bash_profile /home/user/
chown 1000:1000 /home/user/.bashrc /home/user/.bash_profile
EOF

USER agent

# Global npm tools go to the agent-owned prefix, so agents can upgrade them.
RUN npm install -g --no-fund --no-audit "pnpm@${PNPM_VERSION}" "agent-browser@${AGENT_BROWSER_VERSION}"

# Install Amp and agent-browser's Chrome under HOME=/home/user, the home Amp
# runs with. --with-deps installs Chrome's system libraries with sudo.
RUN <<'EOF'
export HOME=/home/user
curl -fsSL https://ampcode.com/install.sh | bash
agent-browser install --with-deps
sudo ln -sf /home/user/.amp/bin/amp /usr/local/bin/amp
# A fixed path for CHROME_PATH and PUPPETEER_EXECUTABLE_PATH.
chrome=$(ls -d /home/user/.agent-browser/browsers/chrome-*/chrome | sort -V | tail -1)
sudo ln -sf "$chrome" /usr/local/bin/google-chrome
sudo rm -rf /var/lib/apt/lists/*
rm -rf /home/user/.npm /home/user/.cache
EOF

COPY --chmod=0755 agent-env.sh /etc/profile.d/amp-orb.sh

# Fail the build when a tool is missing.
RUN <<'EOF'
export HOME=/home/user
for tool in amp agent-browser node npm pnpm bun go python3 uv typst git gh rg fd bat jq yq \
	fzf tmux gcc make docker sqlite3 shellcheck ffmpeg magick mise ast-grep google-chrome tini earlyoom; do
	command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
amp --version
agent-browser --version
node --version
pnpm --version
bun --version
go version
python3 --version
uv --version
typst --version
yq --version
mise --version
ast-grep --version
docker compose version
google-chrome --version
id user
EOF
