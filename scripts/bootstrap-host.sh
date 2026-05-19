#!/usr/bin/env bash
#
# Idempotently bootstrap an Ubuntu host as an LXD server, configure the
# bridge / firewall, and install Terraform. Each stage probes current
# state and skips work that's already done.
#
# Required env:
#   LXD_TRUST_PASSWORD  Password for clients to add themselves as trusted.
#
# Optional env:
#   ALLOWED_IP     External client IP allowed on tcp/HTTPS_PORT (omit to
#                  skip the external whitelist; loopback always works).
#   HTTPS_PORT     Default 8443.
#   BRIDGE_NAME    Default lxdbr0.
#   BRIDGE_CIDR    Network CIDR (e.g. 10.86.216.0/24). Gateway is .1.
#
# Usage:
#   sudo LXD_TRUST_PASSWORD='...' ALLOWED_IP='1.2.3.4' ./bootstrap-host.sh

set -euo pipefail

# Snap binaries (lxd, lxc) live in /snap/bin, which is only added to PATH by
# /etc/profile.d/apt.sh for login shells. SSH/non-interactive invocations
# (e.g. Bitbucket Pipelines) skip that, so ensure it's present.
export PATH="/snap/bin:$PATH"

# `sudo` strips PATH and replaces it with `secure_path` from /etc/sudoers,
# which on Debian/Ubuntu does NOT include /snap/bin. Without this drop-in
# `sudo lxc ...` returns "command not found" even though /snap/bin/lxc exists.
# We use a drop-in (not visudo) so a syntax slip can't lock the host out.
sudoers_dropin=/etc/sudoers.d/99-snap-path
expected_sudoers='Defaults secure_path="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
if [[ -f "$sudoers_dropin" ]] && [[ "$(cat "$sudoers_dropin")" == "$expected_sudoers" ]]; then
  : # already configured; defer logging until after the log() helpers exist
else
  printf '%s\n' "$expected_sudoers" > "$sudoers_dropin"
  chmod 0440 "$sudoers_dropin"
  # Validate before leaving it in place — a broken file in /etc/sudoers.d
  # makes ALL sudo invocations fail.
  if ! visudo -c -f "$sudoers_dropin" >/dev/null; then
    rm -f "$sudoers_dropin"
    echo "ERROR: failed to validate ${sudoers_dropin}; removed." >&2
    exit 1
  fi
fi

: "${LXD_TRUST_PASSWORD:?LXD_TRUST_PASSWORD must be set}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
BRIDGE_NAME="${BRIDGE_NAME:-lxdbr0}"
BRIDGE_CIDR="${BRIDGE_CIDR:-10.86.216.0/24}"
ALLOWED_IP="${ALLOWED_IP:-}"
# 5.21/stable is LTS and supports trust tokens (the modern auth flow used
# by terraform-lxd/lxd >= 1.9). 5.0 lacks tokens; 6.x dropped passwords.
LXD_CHANNEL="${LXD_CHANNEL:-5.21/stable}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)." >&2
  exit 1
fi

log()  { printf '\n==> %s\n' "$*"; }
skip() { printf '    skip: %s\n' "$*"; }
do_()  { printf '    do:   %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Apt prerequisites
# ---------------------------------------------------------------------------
log "Checking apt prerequisites"
# nginx          — front-door reverse proxy that splits public traffic by
#                  Host header to each LXD container's k3s/Traefik.
# gettext-base   — provides envsubst, used by the UI deploy.sh to render
#                  parameterized k8s manifests on this host.
# certbot + nginx plugin — TLS for the public subdomains (terminated here).
# rsync          — used by the digi-banking-deploy-helm Bitbucket pipeline
#                  to push the chart + values to this host before each helm
#                  upgrade. Required on both ends of the rsync transfer.
need_pkgs=()
for pkg in snapd wget gnupg lsb-release ufw ca-certificates python3 \
           nginx gettext-base certbot python3-certbot-nginx rsync; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    need_pkgs+=("$pkg")
  fi
done
if (( ${#need_pkgs[@]} == 0 )); then
  skip "all prerequisites already installed"
else
  do_ "installing: ${need_pkgs[*]}"
  apt-get update
  apt-get install -y "${need_pkgs[@]}"
fi

# ---------------------------------------------------------------------------
# 2. LXD (snap)
# ---------------------------------------------------------------------------
log "Checking LXD snap (channel ${LXD_CHANNEL})"
needs_install=true
if snap list lxd >/dev/null 2>&1; then
  current_channel=$(snap list lxd | awk 'NR==2 {print $4}')
  if [[ "$current_channel" == "$LXD_CHANNEL" ]] && lxd waitready --timeout=10 >/dev/null 2>&1; then
    skip "lxd on ${LXD_CHANNEL} and daemon healthy"
    needs_install=false
  elif [[ "$current_channel" == "$LXD_CHANNEL" ]]; then
    # Right channel but daemon won't start — usually a corrupted state from
    # a previous failed downgrade. Purge wipes the broken DB.
    do_ "lxd on ${LXD_CHANNEL} but daemon unhealthy; purging"
    snap remove lxd --purge
  else
    # LXD doesn't support cross-version downgrades (DB schema is forward-only).
    do_ "channel mismatch (${current_channel} -> ${LXD_CHANNEL}); purging"
    snap remove lxd --purge
  fi
fi
if $needs_install; then
  do_ "installing lxd from ${LXD_CHANNEL}"
  snap install lxd --channel="$LXD_CHANNEL"
fi
lxd waitready --timeout=120

# ---------------------------------------------------------------------------
# 3. LXD storage init
# ---------------------------------------------------------------------------
log "Checking LXD storage init"
if lxc storage show default >/dev/null 2>&1; then
  skip "default storage pool already exists"
else
  do_ "running lxd init --preseed"
  cat <<EOF | lxd init --preseed
config: {}
networks: []
storage_pools:
  - name: default
    driver: dir
profiles:
  - name: default
    devices:
      root:
        path: /
        pool: default
        type: disk
EOF
fi

# ---------------------------------------------------------------------------
# 4. HTTPS listener
# ---------------------------------------------------------------------------
log "Checking core.https_address"
current_https=$(lxc config get core.https_address 2>/dev/null || true)
if [[ "$current_https" == ":${HTTPS_PORT}" ]]; then
  skip "core.https_address already :${HTTPS_PORT}"
else
  do_ "setting core.https_address=:${HTTPS_PORT} (was '${current_https}')"
  lxc config set core.https_address ":${HTTPS_PORT}"
fi

# ---------------------------------------------------------------------------
# 5. Trust password (cannot be read back; always set — overwrite is harmless)
# ---------------------------------------------------------------------------
log "Setting core.trust_password"
do_ "setting trust password (idempotent overwrite)"
lxc config set core.trust_password "${LXD_TRUST_PASSWORD}"

# ---------------------------------------------------------------------------
# 6. Bridge network
# ---------------------------------------------------------------------------
log "Checking bridge ${BRIDGE_NAME}"

# Compute LXD's gateway form (10.86.216.0/24 -> 10.86.216.1/24)
GATEWAY_CIDR=$(python3 - <<PY
import ipaddress
n = ipaddress.ip_network("${BRIDGE_CIDR}", strict=False)
print(f"{n.network_address + 1}/{n.prefixlen}")
PY
)

if lxc network show "${BRIDGE_NAME}" >/dev/null 2>&1; then
  current_addr=$(lxc network get "${BRIDGE_NAME}" ipv4.address 2>/dev/null || true)
  current_nat=$(lxc network get "${BRIDGE_NAME}" ipv4.nat 2>/dev/null || true)
  if [[ "$current_addr" == "$GATEWAY_CIDR" && "$current_nat" == "true" ]]; then
    skip "${BRIDGE_NAME} already at ${GATEWAY_CIDR} with NAT"
  else
    do_ "reconfiguring ${BRIDGE_NAME} to ${GATEWAY_CIDR}"
    lxc network set "${BRIDGE_NAME}" ipv4.address "${GATEWAY_CIDR}"
    lxc network set "${BRIDGE_NAME}" ipv4.nat true
    lxc network set "${BRIDGE_NAME}" ipv6.address none
  fi
else
  do_ "creating ${BRIDGE_NAME} at ${GATEWAY_CIDR}"
  lxc network create "${BRIDGE_NAME}" \
    ipv4.address="${GATEWAY_CIDR}" \
    ipv4.nat=true \
    ipv6.address=none
fi

# ---------------------------------------------------------------------------
# 7. Default profile eth0 attached to bridge
# ---------------------------------------------------------------------------
log "Checking default profile eth0 device"
existing_parent=$(lxc profile device get default eth0 parent 2>/dev/null || true)
if [[ "$existing_parent" == "$BRIDGE_NAME" ]]; then
  skip "default profile eth0 already on ${BRIDGE_NAME}"
else
  do_ "attaching eth0 to ${BRIDGE_NAME} on default profile"
  lxc profile device remove default eth0 2>/dev/null || true
  lxc profile device add default eth0 nic nictype=bridged parent="${BRIDGE_NAME}"
fi

# ---------------------------------------------------------------------------
# 8. ufw — `ufw allow` is itself idempotent ("Skipping adding existing rule")
# ---------------------------------------------------------------------------
log "Checking ufw rules"

# LXD containers use the bridge and need traffic forwarded through the host.
# ufw's default FORWARD policy is DROP, which breaks LXD networking (containers
# can't get DHCP leases or reach the internet).
if grep -q '^DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw 2>/dev/null; then
  do_ "switching ufw DEFAULT_FORWARD_POLICY DROP -> ACCEPT (required for LXD)"
  sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  forward_policy_changed=true
else
  forward_policy_changed=false
fi

ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH          >/dev/null

# Allow all traffic on the LXD bridge itself (DHCP, DNS to dnsmasq) and
# permit container traffic to be routed in/out.
ufw allow in on "${BRIDGE_NAME}"        >/dev/null
ufw route allow in on "${BRIDGE_NAME}"  >/dev/null
ufw route allow out on "${BRIDGE_NAME}" >/dev/null

if [[ -n "$ALLOWED_IP" ]]; then
  ufw allow from "$ALLOWED_IP" to any port "$HTTPS_PORT" proto tcp >/dev/null
  do_ "ufw rules ensured (OpenSSH + ${BRIDGE_NAME} bridge + ${ALLOWED_IP}:${HTTPS_PORT})"
else
  do_ "ufw rules ensured (OpenSSH + ${BRIDGE_NAME} bridge only — no ALLOWED_IP set)"
fi

# Public HTTP/HTTPS for the host nginx reverse proxy. These need to be
# world-open (not gated by ALLOWED_IP) since real users hit them.
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
do_ "ufw 80/tcp + 443/tcp open for public reverse-proxy traffic"

# Postgres: exposed publicly on host port 5432. A host-side HAProxy reads
# the TLS SNI from each incoming connection and routes to the right
# cluster's container. Per-cluster Postgres uses TLS with a self-signed
# cert whose CN matches the subdomain. Clients MUST use sslmode=require
# and sslnegotiation=direct (PG17 client feature) so the first packet is
# a TLS ClientHello rather than a Postgres SSLRequest.
ufw allow 5432/tcp >/dev/null
do_ "ufw 5432/tcp open for HAProxy SNI-routed Postgres"

if ufw status | grep -q "Status: active"; then
  if $forward_policy_changed; then
    do_ "ufw active; reloading to pick up FORWARD policy change"
    ufw reload >/dev/null
  else
    skip "ufw already active"
  fi
else
  do_ "enabling ufw"
  ufw --force enable
fi

# ---------------------------------------------------------------------------
# 9. HashiCorp apt repo + Terraform
# ---------------------------------------------------------------------------
log "Checking HashiCorp apt repo"
if [[ -s /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
  skip "hashicorp keyring present"
else
  do_ "installing hashicorp keyring"
  install -d -m 0755 /usr/share/keyrings
  wget -qO- https://apt.releases.hashicorp.com/gpg \
    | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
fi

codename=$(lsb_release -cs)
expected_repo="deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${codename} main"
if [[ -f /etc/apt/sources.list.d/hashicorp.list ]] \
   && grep -qF "$expected_repo" /etc/apt/sources.list.d/hashicorp.list; then
  skip "hashicorp.list already configured for ${codename}"
else
  do_ "writing /etc/apt/sources.list.d/hashicorp.list"
  echo "$expected_repo" > /etc/apt/sources.list.d/hashicorp.list
  apt-get update
fi

log "Checking Terraform"
if command -v terraform >/dev/null 2>&1; then
  skip "terraform already installed ($(terraform version | head -n1))"
else
  do_ "apt-get install terraform"
  apt-get install -y terraform
fi

# ---------------------------------------------------------------------------
# HAProxy — fronts Postgres on host :5432. Terraform writes the actual
# haproxy.cfg (it knows each cluster's bridge IP and subdomain); here we
# only ensure the binary is installed and the unit is enabled. Terraform's
# null_resource.host_haproxy_config drops in the config and reloads.
# ---------------------------------------------------------------------------
log "Checking HAProxy"
if command -v haproxy >/dev/null 2>&1; then
  skip "haproxy already installed ($(haproxy -v 2>/dev/null | head -1))"
else
  do_ "apt-get install haproxy"
  DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy
fi
if systemctl is-enabled --quiet haproxy 2>/dev/null; then
  skip "haproxy unit already enabled"
else
  do_ "enabling haproxy (terraform writes the config)"
  systemctl enable haproxy >/dev/null
fi

# ---------------------------------------------------------------------------
# 10. Kernel modules + sysctl for k3s in nested containers
# ---------------------------------------------------------------------------
log "Checking host nginx default site"
# Debian's nginx ships with a default catch-all server on port 80. Leaving
# it enabled risks shadowing our terraform-managed cluster vhosts when the
# request's Host header doesn't match (e.g. raw-IP probes), and complicates
# certbot's vhost rewriting. Disable it; terraform owns the vhosts now.
if [[ -L /etc/nginx/sites-enabled/default ]]; then
  do_ "disabling /etc/nginx/sites-enabled/default"
  rm -f /etc/nginx/sites-enabled/default
  if systemctl is-active --quiet nginx; then
    nginx -t && systemctl reload nginx
  fi
else
  skip "nginx default site already disabled"
fi

if systemctl is-enabled --quiet nginx 2>/dev/null; then
  skip "nginx unit already enabled"
else
  do_ "enabling + starting nginx"
  systemctl enable --now nginx
fi

# ---------------------------------------------------------------------------
# 11. Certbot — webroot, renewal deploy hook, automatic-renewal timer
# ---------------------------------------------------------------------------
log "Checking certbot ACME webroot"
# Shared between nginx (which serves /.well-known/acme-challenge from here)
# and certbot (which writes the challenge files into here during HTTP-01).
if [[ -d /var/www/certbot ]]; then
  skip "/var/www/certbot already exists"
else
  do_ "creating /var/www/certbot"
  mkdir -p /var/www/certbot
  chown -R www-data:www-data /var/www/certbot
fi

log "Checking certbot renewal deploy hook"
# certbot.timer runs renewals; this hook fires after a successful renewal so
# nginx picks up the new cert without us touching anything. Without this,
# renewals succeed silently but the running nginx keeps the old cert in
# memory until the next manual reload.
hook_file=/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
expected_hook=$'#!/bin/sh\n# Managed by bootstrap-host.sh — reload nginx after each cert renewal.\nset -e\nsystemctl reload nginx\n'
mkdir -p "$(dirname "$hook_file")"
if [[ -f "$hook_file" ]] && [[ "$(cat "$hook_file")" == "$expected_hook" ]] \
   && [[ -x "$hook_file" ]]; then
  skip "${hook_file} already configured"
else
  do_ "writing ${hook_file}"
  printf '%s' "$expected_hook" > "$hook_file"
  chmod 0755 "$hook_file"
fi

log "Checking certbot.timer (auto-renewal)"
# The certbot package ships certbot.timer enabled by default on Ubuntu, but
# we re-assert it here so a previous `systemctl disable` doesn't silently
# break renewals.
if systemctl is-enabled --quiet certbot.timer 2>/dev/null \
   && systemctl is-active --quiet certbot.timer 2>/dev/null; then
  skip "certbot.timer already enabled and active"
else
  do_ "enabling + starting certbot.timer"
  systemctl enable --now certbot.timer
fi

log "Checking k3s host kernel prep"

modules_file=/etc/modules-load.d/k3s.conf
expected_modules=$'overlay\nbr_netfilter'
if [[ -f "$modules_file" ]] && [[ "$(cat "$modules_file")" == "$expected_modules" ]]; then
  skip "${modules_file} already configured"
else
  do_ "writing ${modules_file}"
  printf '%s\n' "$expected_modules" > "$modules_file"
fi

for mod in overlay br_netfilter; do
  if lsmod | awk '{print $1}' | grep -qx "$mod"; then
    skip "module ${mod} already loaded"
  else
    do_ "modprobe ${mod}"
    modprobe "$mod"
  fi
done

sysctl_file=/etc/sysctl.d/99-k3s.conf
expected_sysctl=$'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1'
if [[ -f "$sysctl_file" ]] && [[ "$(cat "$sysctl_file")" == "$expected_sysctl" ]]; then
  skip "${sysctl_file} already configured"
else
  do_ "writing ${sysctl_file} and reloading sysctl"
  printf '%s\n' "$expected_sysctl" > "$sysctl_file"
  sysctl --system >/dev/null
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "Done"
cat <<SUMMARY
    LXD listening   : :${HTTPS_PORT}
    Bridge          : ${BRIDGE_NAME} (${GATEWAY_CIDR})
    External access : ${ALLOWED_IP:-<none — loopback only>}
    Terraform       : $(terraform version | head -n1)
SUMMARY
