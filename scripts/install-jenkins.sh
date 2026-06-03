#!/usr/bin/env bash
#
# Idempotently install Jenkins LTS on the VPS host (NOT inside any LXD
# container) and put it behind the host nginx with a Let's Encrypt cert.
# Each stage probes current state and skips work that's already done, so
# this script is safe to re-run after partial failures or to pull
# upstream Jenkins LTS updates.
#
# Required env:
#   JENKINS_DOMAIN     Public hostname for Jenkins (e.g.
#                      jenkins.cntrlflix.com). DNS A record must already
#                      point at this VPS or the certbot HTTP-01 step
#                      will fail (and the script leaves the HTTP-only
#                      vhost in place — re-run after DNS is live).
#   LETSENCRYPT_EMAIL  Account contact email for Let's Encrypt.
#
# Optional env:
#   JENKINS_LISTEN_ADDR  Default 127.0.0.1 (Jenkins itself only listens
#                        on loopback; nginx is the public face). Set to
#                        0.0.0.0 only if you intentionally want Jenkins
#                        directly reachable on tcp/8080 — and then ALSO
#                        add a ufw rule yourself; the host's default
#                        policy denies inbound otherwise.
#   JENKINS_HTTP_PORT    Default 8080 (Jenkins servlet listener).
#   LE_STAGING           Default false. Set to "true" to issue against
#                        Let's Encrypt staging while iterating (avoids
#                        burning the 50/week production rate limit).
#
# Usage:
#   sudo JENKINS_DOMAIN='jenkins.cntrlflix.com' \
#        LETSENCRYPT_EMAIL='you@example.com' \
#        ./install-jenkins.sh

set -euo pipefail

: "${JENKINS_DOMAIN:?JENKINS_DOMAIN must be set (e.g. jenkins.cntrlflix.com)}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL must be set}"

JENKINS_LISTEN_ADDR="${JENKINS_LISTEN_ADDR:-127.0.0.1}"
JENKINS_HTTP_PORT="${JENKINS_HTTP_PORT:-8080}"
LE_STAGING="${LE_STAGING:-false}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)." >&2
  exit 1
fi

log()  { printf '\n==> %s\n' "$*"; }
skip() { printf '    skip: %s\n' "$*"; }
do_()  { printf '    do:   %s\n' "$*"; }

# ---------------------------------------------------------------------------
# git — Jenkins needs the git CLI to check out this repo. It must exist
# BEFORE the first build, and the pipeline's own bootstrap-host.sh can't
# provide it (that runs only after checkout, which already needs git). So we
# install it here, during host setup, where it's guaranteed to precede any
# Jenkins job. Idempotent: skip if git is already on PATH.
# ---------------------------------------------------------------------------
log "Checking git"
if command -v git >/dev/null 2>&1; then
  skip "git $(git --version | awk '{print $3}') already installed"
else
  do_ "installing git"
  apt-get update -qq
  apt-get install -y -qq git
fi

# ---------------------------------------------------------------------------
# Java — Jenkins LTS requires JDK 17 or 21. We use Temurin JDK 21 from the
# Adoptium apt repo (the upstream Jenkins docs' recommended path on Ubuntu).
# ---------------------------------------------------------------------------
log "Checking Java"
if command -v java >/dev/null 2>&1 \
   && java -version 2>&1 | grep -qE '"(17|21)\.'; then
  skip "java $(java -version 2>&1 | head -1) already installed"
else
  do_ "installing Temurin JDK 21"
  apt-get update -qq
  apt-get install -y -qq wget apt-transport-https gnupg ca-certificates
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/adoptium.gpg ]]; then
    wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
  fi
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  cat >/etc/apt/sources.list.d/adoptium.list <<EOF
deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${codename} main
EOF
  apt-get update -qq
  apt-get install -y -qq temurin-21-jdk
fi

# ---------------------------------------------------------------------------
# Jenkins LTS apt repo + package. Idempotent — apt no-ops on a satisfied
# install but `apt-get install jenkins` will pull point releases on re-run,
# which is what we want for security patches.
# ---------------------------------------------------------------------------
log "Configuring Jenkins apt repo"
# Jenkins rotates the LTS signing key periodically, AND the published key
# file at pkg.jenkins.io often lags behind the Release file's signer for
# weeks at a time (saw this in May 2026: jenkins.io-2023.key still served
# the previous keys while Release was signed by 5E386EAD...ABFC68).
#
# We work around it by fetching the *exact* key apt is demanding straight
# from an OpenPGP keyserver. The fingerprint is hardcoded because it IS
# the cryptographic identity we're trusting — keyservers don't validate
# uploads, so verifying the fingerprint after fetch is the only thing
# stopping a hostile keyserver from substituting a different key.
#
# On rotation, update JENKINS_KEY_FPR to whatever apt's error message
# says is "Missing key ...".
install -d -m 0755 /etc/apt/keyrings
JENKINS_KEY_FPR="5E386EADB55F01504CAE8BCF7198F4B714ABFC68"
JENKINS_KEYRING="/etc/apt/keyrings/jenkins.gpg"
JENKINS_KEYSERVERS=(
  "hkps://keyserver.ubuntu.com"
  "hkps://keys.openpgp.org"
)

key_ok=false
if [[ -f "$JENKINS_KEYRING" ]] \
   && gpg --no-default-keyring --keyring "$JENKINS_KEYRING" \
          --list-keys "$JENKINS_KEY_FPR" >/dev/null 2>&1; then
  skip "Jenkins key ${JENKINS_KEY_FPR:0:16}... already in keyring"
  key_ok=true
fi

if ! $key_ok; then
  do_ "fetching Jenkins key ${JENKINS_KEY_FPR:0:16}... from keyserver"
  tmp_gpg_home=$(mktemp -d)
  trap 'rm -rf "$tmp_gpg_home"' EXIT

  fetched=false
  for ks in "${JENKINS_KEYSERVERS[@]}"; do
    if gpg --homedir "$tmp_gpg_home" --batch \
           --keyserver "$ks" \
           --recv-keys "$JENKINS_KEY_FPR" >/dev/null 2>&1; then
      do_ "fetched from ${ks}"
      fetched=true
      break
    fi
    echo "    keyserver ${ks} did not return the key; trying next" >&2
  done

  if ! $fetched; then
    echo "ERROR: could not fetch ${JENKINS_KEY_FPR} from any keyserver." >&2
    echo "       Check VPS DNS / outbound 11371 + 443. As a fallback,"   >&2
    echo "       manually wget the key file from pkg.jenkins.io and"     >&2
    echo "       dearmor it to ${JENKINS_KEYRING}."                      >&2
    exit 1
  fi

  # Sanity-check: a keyserver could return any key. Verify the exported
  # keyring contains EXACTLY the fingerprint we asked for before we let
  # apt trust it. `--export <fpr>` filters to the requested key only.
  gpg --homedir "$tmp_gpg_home" --batch \
      --export "$JENKINS_KEY_FPR" > "$JENKINS_KEYRING"
  chmod 0644 "$JENKINS_KEYRING"

  if ! gpg --no-default-keyring --keyring "$JENKINS_KEYRING" \
           --list-keys "$JENKINS_KEY_FPR" >/dev/null 2>&1; then
    echo "ERROR: keyserver returned a key but it didn't match the" >&2
    echo "       requested fingerprint. Aborting."                  >&2
    rm -f "$JENKINS_KEYRING"
    exit 1
  fi
  rm -f /etc/apt/keyrings/jenkins.asc   # remove any stale armored copy
fi

list_line="deb [signed-by=${JENKINS_KEYRING}] https://pkg.jenkins.io/debian-stable binary/"
if [[ -f /etc/apt/sources.list.d/jenkins.list ]] \
   && [[ "$(cat /etc/apt/sources.list.d/jenkins.list)" == "$list_line" ]]; then
  skip "jenkins.list already points at binary keyring"
else
  printf '%s\n' "$list_line" > /etc/apt/sources.list.d/jenkins.list
  do_ "wrote /etc/apt/sources.list.d/jenkins.list"
fi

# Authoritative validation: if apt-get update still complains about the
# Jenkins repo, fail loudly here rather than letting `apt-get install
# jenkins` blow up later with a confusing message.
update_log=$(mktemp)
trap 'rm -f "$update_log"; rm -rf "${tmp_gpg_home:-}"' EXIT
apt-get update 2>&1 | tee "$update_log" >/dev/null
if grep -E 'pkg\.jenkins\.io.*(NO_PUBKEY|is not signed|Missing key)' "$update_log" >&2; then
  echo "ERROR: Jenkins repo still not verifying. apt says it needs a"   >&2
  echo "       different key than ${JENKINS_KEY_FPR}. Update"           >&2
  echo "       JENKINS_KEY_FPR in this script to the fingerprint apt"   >&2
  echo "       printed above and re-run."                                >&2
  exit 1
fi

log "Installing/upgrading Jenkins"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jenkins
do_ "jenkins package present ($(dpkg-query -W -f='${Version}' jenkins))"

# ---------------------------------------------------------------------------
# Bind Jenkins to loopback only. The public face is nginx + TLS; exposing
# 8080 directly would leak the Jenkins HTTP port and the login form
# without TLS during the brief window before certbot completes. The
# upstream systemd unit reads JENKINS_LISTEN_ADDRESS / HTTP_PORT from a
# drop-in env file — we manage just our overrides there so package
# upgrades that ship a new default unit don't clobber them.
# ---------------------------------------------------------------------------
log "Configuring Jenkins listener (${JENKINS_LISTEN_ADDR}:${JENKINS_HTTP_PORT})"
install -d -m 0755 /etc/systemd/system/jenkins.service.d
override=/etc/systemd/system/jenkins.service.d/10-listen.conf
desired=$(cat <<EOF
[Service]
Environment="JENKINS_LISTEN_ADDRESS=${JENKINS_LISTEN_ADDR}"
Environment="JENKINS_PORT=${JENKINS_HTTP_PORT}"
# Jenkins's first-boot plugin-index pass routinely takes 90-180s on a
# contended VPS (this one shares CPU/disk with 5 k3s clusters), well past
# systemd's 90s default. Without this bump, systemctl reports "Job for
# jenkins.service failed because a timeout was exceeded" even though the
# JVM is still healthily coming up and will reach "active (running)".
TimeoutStartSec=300
EOF
)
if [[ -f "$override" ]] && [[ "$(cat "$override")" == "$desired" ]]; then
  skip "systemd drop-in already in place"
else
  printf '%s\n' "$desired" > "$override"
  systemctl daemon-reload
  do_ "wrote ${override}, daemon-reloaded"
fi

log "Enabling + starting Jenkins"
systemctl enable jenkins >/dev/null 2>&1 || true
# `restart` (not just start) is needed when the drop-in changed; on a
# fresh install start is a no-op-after-restart. Either way, we wait for
# the listener to come up before moving on so the nginx config-test
# below has something to point at.
systemctl restart jenkins
deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) <= deadline )); do
  if ss -ltn "sport = :${JENKINS_HTTP_PORT}" | grep -q LISTEN; then
    do_ "Jenkins listening on ${JENKINS_LISTEN_ADDR}:${JENKINS_HTTP_PORT}"
    break
  fi
  sleep 2
done
if ! ss -ltn "sport = :${JENKINS_HTTP_PORT}" | grep -q LISTEN; then
  echo "ERROR: Jenkins did not start listening within 120s" >&2
  echo "       check: journalctl -u jenkins -n 100 --no-pager" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# nginx reverse proxy + Let's Encrypt cert. Two-stage like the per-cluster
# vhosts: drop an HTTP-only vhost first so certbot's HTTP-01 challenge can
# resolve, then promote to HTTPS once the cert is on disk.
# ---------------------------------------------------------------------------
log "Configuring nginx vhost for ${JENKINS_DOMAIN}"
if ! command -v nginx >/dev/null 2>&1; then
  do_ "installing nginx"
  apt-get install -y -qq nginx
fi
if ! command -v certbot >/dev/null 2>&1; then
  do_ "installing certbot"
  apt-get install -y -qq certbot
fi
install -d -m 0755 /var/www/certbot

avail="/etc/nginx/sites-available/jenkins.conf"
enabled="/etc/nginx/sites-enabled/jenkins.conf"
live_dir="/etc/letsencrypt/live/${JENKINS_DOMAIN}"

write_http_vhost() {
  cat >"$avail" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${JENKINS_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }

    location / {
        return 302 https://\$host\$request_uri;
    }
}
EOF
}

write_tls_vhost() {
  cat >"$avail" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${JENKINS_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    # nginx 1.25+ deprecated the inline 'http2' flag on listen; use the
    # standalone directive so a re-apply on Ubuntu 24.04 doesn't warn.
    http2 on;
    server_name ${JENKINS_DOMAIN};

    ssl_certificate     ${live_dir}/fullchain.pem;
    ssl_certificate_key ${live_dir}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    # Jenkins hard-codes some URLs based on the X-Forwarded-* headers.
    # Without these the agent JNLP endpoint and webhook callbacks emit
    # http:// URLs even though clients connect via TLS.
    location / {
        proxy_pass         http://${JENKINS_LISTEN_ADDR}:${JENKINS_HTTP_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        # Long-poll endpoints (job logs, blue-ocean SSE) need a generous
        # read timeout; default 60s causes spurious 504s mid-build.
        proxy_read_timeout 300s;
        proxy_buffering    off;
        # WebSocket upgrade for the new build console.
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}
EOF
}

install_vhost() {
  ln -sf "$avail" "$enabled"
  nginx -t
  systemctl reload nginx
}

# Stage 1 — always (re)write the HTTP-only vhost. Cheap and required for
# the ACME challenge to land.
write_http_vhost
install_vhost
do_ "HTTP vhost in place"

# Stage 2 — obtain cert if missing. Best-effort: if DNS isn't pointed yet
# we don't fail the script (matches the per-cluster vhost behavior).
if [[ ! -f "${live_dir}/fullchain.pem" ]]; then
  log "Acquiring TLS cert for ${JENKINS_DOMAIN}"
  staging_flag=""
  [[ "$LE_STAGING" == "true" ]] && staging_flag="--staging"
  if ! flock /var/lock/certbot-tf.lock \
        certbot certonly --webroot -w /var/www/certbot \
        -d "${JENKINS_DOMAIN}" \
        --non-interactive --agree-tos \
        --email "${LETSENCRYPT_EMAIL}" \
        --keep-until-expiring \
        $staging_flag; then
    echo "WARN: certbot failed for ${JENKINS_DOMAIN} — likely DNS not yet" >&2
    echo "      pointing at this VPS. Leaving HTTP-only vhost in place;"   >&2
    echo "      re-run this script once DNS is live."                       >&2
    exit 0
  fi
else
  skip "cert already on disk at ${live_dir}/fullchain.pem"
fi

# Stage 3 — promote to TLS vhost now that the cert exists.
write_tls_vhost
install_vhost
do_ "HTTPS vhost in place — Jenkins reachable at https://${JENKINS_DOMAIN}"

# ---------------------------------------------------------------------------
# Surface the initial admin password so the operator doesn't have to ssh
# in twice. After first login + creating a real admin account, this file
# is removed by Jenkins itself.
# ---------------------------------------------------------------------------
secret=/var/lib/jenkins/secrets/initialAdminPassword
if [[ -f "$secret" ]]; then
  log "Initial admin password (first-time setup only):"
  printf '    %s\n' "$(cat "$secret")"
  log "Open https://${JENKINS_DOMAIN} and paste the password above."
else
  log "Jenkins is already past first-time setup; use your existing admin account at https://${JENKINS_DOMAIN}"
fi
