#!/usr/bin/env bash
# Install the Kalari Vultr preset on a VX1 VM (Ubuntu 24.04) over SSH.
#
#   deploy/vultr/install.sh --host kalari [--source REPO_ROOT]
#
# Builds kalari from --source on the VM itself (a laptop glibc is newer than
# the VM's, so a laptop binary would not run there), installs Caddy, Lambo
# 0.9.0, the systemd unit and the static site, then starts everything.
# kalari serve holds the loopback evidence API itself. Re-running refreshes
# binaries, the unit and the site without touching the evidence store, the
# Lambo store, or the benchmark API sandboxes. It never touches the Vultr
# firewall group: opening ports 80 and 443 is the operator's own step (see README.md).
#
# The inference key comes from VULTR_INFERENCE_API_KEY or the system keyring
# (service vultr-inference, account kalari). It travels to the VM over SSH
# stdin only, lands in /etc/kalari/kalari.env (0600, kalari:kalari), and is
# never printed, logged, or committed.
set -euo pipefail
umask 022

HOST=""
SOURCE="$(cd "$(dirname "$0")/../.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST=${2:?--host needs a value}; shift 2;;
    --source) SOURCE=${2:?--source needs a value}; shift 2;;
    *) echo "usage: install.sh --host SSH_TARGET [--source REPO_ROOT]" >&2; exit 2;;
  esac
done
[[ -n "$HOST" ]] || { echo "usage: install.sh --host SSH_TARGET [--source REPO_ROOT]" >&2; exit 2; }
[[ -f "$SOURCE/lakefile.toml" ]] || { echo "not a Kalari checkout: $SOURCE" >&2; exit 1; }

if [[ -z "${VULTR_INFERENCE_API_KEY:-}" ]]; then
  VULTR_INFERENCE_API_KEY=$(secret-tool lookup service vultr-inference account kalari || true)
  export VULTR_INFERENCE_API_KEY
fi
if [[ -z "${VULTR_INFERENCE_API_KEY:-}" ]]; then
  echo "VULTR_INFERENCE_API_KEY is not set and the keyring has no entry" >&2
  exit 1
fi

LAMBO_SHA256=21f334dc4752625970ba1a4cf9760c7b901b7975ddf19f5ee024747678e7b0bd
LAMBO_URL=https://github.com/nrynss/lambo/releases/download/v0.9.0/lambo-0.9.0-linux-x86_64

say() { printf '%s\n' "$*"; }

say "== $HOST: users, directories, Caddy"
ssh "$HOST" 'set -euo pipefail; umask 022
if ! id kalari >/dev/null 2>&1; then
  sudo useradd -r -m -s /usr/sbin/nologin kalari
fi
sudo usermod -aG kvm kalari
sudo mkdir -p /opt/kalari/bin /etc/kalari /srv/kalari/www \
  /var/lib/kalari/candidate /var/lib/kalari/baseline /var/lib/kalari/checks /var/lib/kalari/evidence
sudo chown kalari:kalari /var/lib/kalari /var/lib/kalari/candidate /var/lib/kalari/baseline /var/lib/kalari/checks /var/lib/kalari/evidence
sudo chmod 755 /var/lib/kalari
if ! command -v caddy >/dev/null 2>&1 || ! command -v rg >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg ripgrep
  # ripgrep is a build dependency: Kalari.Search runs rg in a build-time check,
  # and CI installs it for the same reason.
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y caddy
fi
# The operator approved opening the demo ports (README.md step 2). On a host
# whose own filter drops everything but SSH, the Vultr rules alone do not
# reach Caddy, so allow the same two ports locally. SSH is untouched.
if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  sudo ufw allow 80/tcp comment "kalari demo HTTP" >/dev/null
  sudo ufw allow 443/tcp comment "kalari demo HTTPS" >/dev/null
fi'

say "== $HOST: build kalari from source on the VM"
rsync -az --delete --exclude=.lake --exclude=.git --exclude=target "$SOURCE/" "$HOST:kalari-src/"
ssh "$HOST" 'set -euo pipefail
export PATH="$HOME/.elan/bin:/usr/local/bin:/usr/bin:/bin"
if ! command -v lake >/dev/null 2>&1; then
  curl --proto "=https" --tlsv1.2 -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | sh -s -- -y --default-toolchain none
  export PATH="$HOME/.elan/bin:$PATH"
fi
cd ~/kalari-src && lake build kalari kalari-aashaan'

say "== $HOST: binaries, Lambo, configs, site"
ssh "$HOST" 'set -euo pipefail; umask 022
sudo install -o kalari -g kalari -m 755 "$HOME/kalari-src/.lake/build/bin/kalari" /opt/kalari/bin/kalari
sudo install -o kalari -g kalari -m 755 "$HOME/kalari-src/.lake/build/bin/kalari-aashaan" /opt/kalari/bin/kalari-aashaan
if [[ ! -x /opt/kalari/bin/lambo ]]; then
  tmp=$(mktemp)
  curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "'"$LAMBO_URL"'"
  got=$(sha256sum "$tmp" | awk "{print \$1}")
  [[ "$got" == "'"$LAMBO_SHA256"'" ]] || { echo "lambo checksum mismatch" >&2; exit 1; }
  sudo install -o kalari -g kalari -m 755 "$tmp" /opt/kalari/bin/lambo
  rm -f "$tmp"
fi
if [[ ! -f /var/lib/kalari/lambo.db ]]; then
  sudo -u kalari touch /var/lib/kalari/lambo.db
fi
if ! sudo -u kalari sh -c "umask 022; PATH=\"\$HOME/.local/bin:/usr/bin:/bin\" msb --version" >/dev/null 2>&1; then
  tmp=$(mktemp)
  curl -fsSL --retry 3 --retry-delay 2 https://install.microsandbox.dev -o "$tmp"
  chmod 644 "$tmp"
  sudo -u kalari sh -c "umask 022; sh $tmp"
  rm -f "$tmp"
fi
for attempt in 1 2 3; do
  if sudo -u kalari sh -c "umask 022; PATH=\"\$HOME/.local/bin:/usr/bin:/bin\" msb pull python:3.13-slim" >/dev/null 2>&1; then
    break
  elif [[ $attempt == 3 ]]; then
    echo "msb image pull failed three times; kalari will retry it at runtime" >&2
  else
    sleep 2
  fi
done'

rsync -az "$SOURCE/web/site/" "$HOST:kalari-site/"
if [[ -d "$SOURCE/site" ]]; then
  say "== local: build the docs site for /docs/"
  command -v node >/dev/null 2>&1 || { echo "node is required to build site/" >&2; exit 1; }
  (cd "$SOURCE/site" && npm install --no-audit --no-fund \
    && ASTRO_SITE=https://kalari.nryn.dev ASTRO_BASE=/docs npm run build)
  rsync -az --delete "$SOURCE/site/dist/" "$HOST:kalari-docs/"
else
  echo "site/ is absent; skipping the docs build" >&2
fi
rsync -az "$SOURCE/deploy/vultr/Caddyfile" "$SOURCE/deploy/vultr/kalari.service" "$SOURCE/deploy/vultr/kalari.json.example" "$SOURCE/deploy/vultr/session.json.example" "$SOURCE/deploy/vultr/lambo.toml.example" "$HOST:kalari-deploy/"
ssh "$HOST" 'set -euo pipefail; umask 022
sudo install -o root -g root -m 644 "$HOME/kalari-deploy/Caddyfile" /etc/caddy/Caddyfile
sudo install -o root -g root -m 644 "$HOME/kalari-deploy/kalari.service" /etc/systemd/system/kalari.service
sudo install -o kalari -g kalari -m 600 "$HOME/kalari-deploy/kalari.json.example" /etc/kalari/kalari.json
sudo install -o kalari -g kalari -m 600 "$HOME/kalari-deploy/session.json.example" /etc/kalari/session.json
sudo install -o kalari -g kalari -m 600 "$HOME/kalari-deploy/lambo.toml.example" /etc/kalari/lambo.toml
for spec in spec-v1.yaml spec-v2.yaml; do
  [[ -f /etc/kalari/$spec ]] || echo "# Placeholder spec for the idle demo endpoint. A live migration supplies its own session with real specs." | sudo tee /etc/kalari/$spec >/dev/null
done
sudo chown kalari:kalari /etc/kalari/spec-v1.yaml /etc/kalari/spec-v2.yaml
sudo chmod 600 /etc/kalari/spec-v1.yaml /etc/kalari/spec-v2.yaml
sudo rm -rf /srv/kalari/www
sudo mkdir -p /srv/kalari/www
sudo cp -r "$HOME/kalari-site/." /srv/kalari/www/
if [[ -d "$HOME/kalari-docs" ]]; then
  sudo rm -rf /srv/kalari/www/docs
  sudo mkdir -p /srv/kalari/www/docs
  sudo cp -r "$HOME/kalari-docs/." /srv/kalari/www/docs/
fi
sudo chmod -R a+rX /srv/kalari/www'

say "== $HOST: inference key to /etc/kalari/kalari.env over SSH stdin"
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | ssh "$HOST" 'read -r incoming
tmp=$(mktemp)
umask 077
printf "VULTR_INFERENCE_API_KEY=%s\n" "$incoming" > "$tmp"
sudo install -o kalari -g kalari -m 600 "$tmp" /etc/kalari/kalari.env
rm -f "$tmp"
unset incoming'
VULTR_INFERENCE_API_KEY="<redacted>"
unset VULTR_INFERENCE_API_KEY
ssh "$HOST" 'sudo awk -F= "{print \$1}" /etc/kalari/kalari.env; sudo stat -c "%a %U:%G" /etc/kalari/kalari.env'

say "== $HOST: provision Lambo, enable and start units"
ssh "$HOST" 'set -euo pipefail
if ! sudo -u kalari /opt/kalari/bin/lambo provision --config /etc/kalari/lambo.toml >/dev/null 2>&1; then
  echo "lambo provision needs attention (keeps an existing store)" >&2
fi
sudo systemctl daemon-reload
sudo systemctl enable --now kalari
sudo systemctl enable caddy
# enable --now is a no-op for an already-running Caddy, so a stock config from
# the package install would survive a new Caddyfile. Restart, not reload: a
# reload only reaches the running config admin endpoint, so a bad running
# config makes every later reload fail the same way. The admin endpoint stays
# on loopback for inspection.
sudo systemctl restart caddy
sleep 2
sudo systemctl is-active caddy kalari'

say "== $HOST: local check through Caddy"
ssh "$HOST" 'set -euo pipefail
R="--resolve kalari.nryn.dev:443:127.0.0.1"
curl -sS --max-time 10 $R https://kalari.nryn.dev/ | grep -o "<title>[^<]*</title>"
curl -sS --max-time 10 $R https://kalari.nryn.dev/api/runs; echo'

say "done. Verify from the laptop: curl https://kalari.nryn.dev and the judges page."
