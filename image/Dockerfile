# syntax=docker/dockerfile:1
#
# Amp's orb image, made bootable on Docker Sandboxes Cloud.
#
# Docker Cloud pulls inline images only from Docker Hub and dhi.io, so this
# layer also republishes Amp's image there. Build and push it, then point the
# provider at it with AMP_ORBS_IMAGE:
#   docker buildx build --pull --platform linux/amd64 -t docker.io/<user>/amp-orb:<tag> --push image/
# For arm64, add:
#   --build-arg BASE_IMAGE=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb-arm64:latest

ARG BASE_IMAGE=us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest
FROM ${BASE_IMAGE}

ARG PLAYWRIGHT_VERSION=latest

USER root
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Amp's image ships agent-browser with a bundled Chrome and Chrome's libraries,
# but not Playwright or the WebKitGTK stack. Agents that run Playwright then
# download browsers and print "Host system is missing dependencies" on first
# use. Install the latest Playwright and all three browsers here so new orbs
# start ready. PLAYWRIGHT_BROWSERS_PATH puts them somewhere every user can
# read, instead of root's cache.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Docker Sandboxes runs commands as an `agent` account with uid 1000 and home
# /home/agent. Amp's image names uid 1000 `user`. Add `agent` as a second name
# for the same uid, after `user`, so files and processes still show as `user`.
# Keep the sandbox proxy settings across sudo.
#
# earlyoom kills Chrome before memory runs out. Amp's own OOM protection runs
# through systemd, which does not manage a Docker Sandboxes VM.
RUN <<'EOF'
export DEBIAN_FRONTEND=noninteractive
groupadd -o -g 1000 agent
useradd -o -u 1000 -g 1000 -G "$(id -Gn user | tr ' ' '\n' | grep -vx user | paste -sd,)" \
	-d /home/agent -M -s /bin/bash agent
install -d -o 1000 -g 1000 /home/agent
cat >/etc/sudoers.d/agent <<'SUDOERS'
agent ALL=(ALL) NOPASSWD:ALL
Defaults env_keep += "HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy"
SUDOERS
chmod 0440 /etc/sudoers.d/agent
visudo -cf /etc/sudoers.d/agent
apt-get update
apt-get upgrade -y -o Dpkg::Options::=--force-confold
apt-get install -y --no-install-recommends earlyoom
npm install -g "playwright@${PLAYWRIGHT_VERSION}"
playwright install --with-deps chromium firefox webkit
rm -rf /var/lib/apt/lists/*
chmod -R a+rX /ms-playwright
EOF

USER agent
CMD ["bash"]
