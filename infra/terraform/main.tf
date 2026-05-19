# ---------------------------------------------------------------------------
# Digital Notes Backend — per-cluster LXD container running k3s with all
# 5 microservices (Authentication, Roles, Notes, ai-core-service, ai-worker)
# plus Postgres+pgvector and Kafka inside.
#
# Topology is driven by two repo variables:
#   APPLICATION_NAME (e.g. "secure-vault")
#   CLUSTER_NAMES    (comma-delimited, e.g. "dev-a,dev-b,test,stage,prod")
# The Cartesian product becomes one container per cluster:
#   secure-vault-dev-a, secure-vault-dev-b, secure-vault-test,
#   secure-vault-stage, secure-vault-prod
#
# Public ingress (host nginx → container Traefik):
#   <application>-<cluster>.<domain>   → single per-cluster subdomain.
#   Traefik inside the cluster does PATH-based routing under it:
#     /auth/*   → Authentication  (3211)
#     /notes/*  → Notes           (3213)
#     /ai/*     → ai-core-service (8001)
#   Roles is internal-only (called by Authentication via Feign on lxdbr0).
#
# Each container also gets a host ufw allow rule for its bridge IP, so it
# can reach back to host-side services (certbot webroot, future tooling)
# without being blocked by the VPS firewall — see null_resource.host_ufw_allow.
#
# IMPORTANT: every null_resource here uses `local-exec` with `sudo lxc exec`
# / `sudo tee /etc/nginx/...`. This means terraform MUST be invoked on the
# LXD host itself (the Bitbucket pipeline ships the code there and applies
# it). It cannot be applied from a developer workstation.
# ---------------------------------------------------------------------------

provider "lxd" {
  generate_client_certificates = true
  accept_remote_certificate    = true

  remote {
    name     = "my-remote"
    address  = "https://${var.lxd_host}:8443"
    password = var.lxd_trust_password
    default  = true
  }
}

locals {
  # Parse the comma-delimited CLUSTER_NAMES string into a deduped, ordered
  # list. trimspace tolerates "dev-a, dev-b , test" (whitespace around
  # commas). Empty entries (trailing comma) are dropped.
  cluster_names = [
    for s in split(",", var.cluster_names) : trimspace(s)
    if trimspace(s) != ""
  ]

  # Stable IPs derived from cluster index — first cluster gets <network>.10,
  # second .11, etc. Starts at .10 so .1 (gateway) and .2-.9 stay reserved
  # for the host / future infra. Capped at .254 by the validation below.
  #
  # Pinning IPs (rather than letting lxdbr0's DHCP assign them) makes
  # /etc/hosts entries on laptops, Tailscale subnet routes, and operator
  # muscle memory stable across container recreates.
  bridge_prefix = join(".", slice(split(".", split("/", var.bridge_cidr)[0]), 0, 3))

  clusters_by_name = {
    for idx, name in local.cluster_names :
    name => {
      cluster_name   = name
      container_name = "${var.application_name}-${name}"
      ipv4_address   = "${local.bridge_prefix}.${10 + idx}"
      subdomain      = "${var.application_name}-${name}.${var.domain}"
    }
  }

  # Map of cluster → routing details. host_nginx_vhost iterates this so each
  # cluster gets exactly ONE vhost on the host nginx, forwarding all paths
  # to the cluster's bridge IP. Traefik inside k3s then does path-based
  # routing to the right K8s Service.
  #
  # `ip` is the statically pinned address from clusters_by_name above —
  # known at plan time, doesn't depend on the lxd_instance.
  vhosts = {
    for cluster_name, cluster in local.clusters_by_name :
    cluster_name => {
      cluster_name = cluster_name
      subdomain    = cluster.subdomain
      ip           = cluster.ipv4_address
    }
  }
}

# ---------------------------------------------------------------------------
# The container itself. Same painfully-tuned k3s-in-LXC settings as before
# (raw.lxc, kernel modules, syscall intercepts) — these are the bare minimum
# to run k3s inside an unprivileged-feeling LXD container.
# ---------------------------------------------------------------------------

resource "lxd_instance" "digital_notes" {
  for_each = local.clusters_by_name

  name  = each.value.container_name
  image = "ubuntu:22.04"

  config = {
    "security.nesting"                     = "true"
    "security.privileged"                  = "true"
    "security.syscalls.intercept.mknod"    = "true"
    "security.syscalls.intercept.setxattr" = "true"
    # k3s/kubelet writes to a handful of /proc/sys/{vm,kernel}/* paths during
    # ContainerManager startup. LXD bind-mounts those read-only by default
    # even in privileged containers, so kubelet aborts with "read-only file
    # system" on /proc/sys/vm/overcommit_memory, kernel.panic, etc.
    # `lxc.mount.auto=proc:rw sys:rw` remounts both rw inside the container,
    # bypassing the masking. The other directives unblock cgroup/device and
    # capability checks that k3s also trips over in unconfined LXC.
    "raw.lxc" = <<-EOT
      lxc.apparmor.profile=unconfined
      lxc.cap.drop=
      lxc.cgroup.devices.allow=a
      lxc.mount.auto=proc:rw sys:rw
    EOT
    # Modules required by k3s networking (kube-proxy iptables rules, flannel
    # overlay, br_netfilter for service routing). Loaded on the host before
    # the container starts so k3s doesn't have to discover them missing.
    "linux.kernel_modules" = "ip_tables,ip6_tables,netlink_diag,nf_nat,overlay,br_netfilter"
    # Cloud-init is intentionally minimal — just enough so the container is
    # routable. Everything else (k3s, helm, postgres+pgvector, kafka,
    # namespace, secrets, topics) is handled by null_resource.cluster_bootstrap,
    # which runs the idempotent scripts/cluster-bootstrap.sh via `lxc exec`.
    # That gives us apt-resilient bring-up and per-step retry, neither of
    # which cloud-init offers, and surfaces failures in `terraform apply`
    # output instead of burying them in /var/log/cloud-init-output.log.
    "cloud-init.user-data" = <<-EOF
      #cloud-config
      runcmd:
        - ufw disable || true
    EOF
  }

  # Static IP per cluster (derived by index in locals.clusters_by_name), so
  # /etc/hosts entries on laptops and Tailscale subnet routes stay stable
  # across container recreates. LXD honors `ipv4.address` as a DHCP
  # reservation tied to the container's MAC.
  device {
    name = "eth0"
    type = "nic"
    properties = {
      "name"         = "eth0"
      "network"      = "lxdbr0"
      "ipv4.address" = each.value.ipv4_address
    }
  }

  device {
    name = "kmsg"
    type = "unix-char"
    properties = {
      source = "/dev/kmsg"
      path   = "/dev/kmsg"
    }
  }

  # Postgres listens at <container-ip>:5432 on the lxdbr0 bridge. Not
  # exposed on the public internet — laptops reach it via Tailscale, which
  # advertises 10.86.216.0/24 as a subnet route from this VPS.

  lifecycle {
    # Postgres data + Kafka topics live inside this container's filesystem.
    # Without prevent_destroy, a stray `terraform destroy` (or a rename in
    # var.cluster_names that turns the for_each key over) wipes prod data
    # silently. To intentionally retire a cluster, flip this off in a
    # deliberate commit — the friction is the point.
    prevent_destroy = true

    # The fields below were tuned painfully (raw.lxc unblocks k3s-in-LXC,
    # kernel_modules pre-loads what kube-proxy/flannel need, the syscall
    # intercepts unblock package installers). Any drift here would force the
    # LXD provider to RECREATE the container — wiping k3s, postgres data,
    # kafka topics, and everything inside. Once they work, freeze them; if
    # you genuinely need to change one, edit + comment the line out of
    # ignore_changes, apply, then re-add. cluster_bootstrap owns runtime
    # state, so behavior changes belong there, not in container config.
    ignore_changes = [
      config["raw.lxc"],
      config["linux.kernel_modules"],
      config["security.nesting"],
      config["security.privileged"],
      config["security.syscalls.intercept.mknod"],
      config["security.syscalls.intercept.setxattr"],
      config["cloud-init.user-data"],
    ]
  }
}

# ---------------------------------------------------------------------------
# Per-container host ufw allow rules.
#
# The "VPS firewall whitelist" for each cluster's auto-assigned bridge IP.
# bootstrap-host.sh sets the host's default policies (deny incoming on the
# external interface); per-container rules here let the container reach
# host-side services (certbot webroot share, future tooling) on the bridge
# without being blocked.
#
# `ufw allow from <ip>` is host-wide for that source IP. Idempotent: ufw
# silently no-ops on a duplicate rule. The destroy provisioner removes the
# rule when the cluster is decommissioned so stale entries don't accumulate.
# ---------------------------------------------------------------------------

resource "null_resource" "host_ufw_allow" {
  for_each = local.clusters_by_name

  triggers = {
    container_ip   = lxd_instance.digital_notes[each.key].ipv4_address
    container_name = lxd_instance.digital_notes[each.key].name
    # If the container is recreated (new MAC + likely new DHCP IP) we
    # need to drop the old ufw rule and add the new one — that's exactly
    # what triggering on instance_mac achieves.
    instance_mac = lxd_instance.digital_notes[each.key].mac_address
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      CONTAINER_IP   = self.triggers.container_ip
      CONTAINER_NAME = self.triggers.container_name
    }
    command = <<-EOT
      set -euo pipefail
      # `ufw allow from X comment Y` — the comment makes the rule
      # discoverable later via `ufw status verbose | grep <container_name>`,
      # which matters when manually auditing or pruning rules. ufw treats a
      # second invocation with identical from/comment as a duplicate and
      # silently skips it, so this is safe to re-run on every apply.
      sudo ufw allow from "$CONTAINER_IP" comment "lxd:$CONTAINER_NAME"
      sudo ufw reload >/dev/null
      echo "==> ufw: allow from $CONTAINER_IP ($CONTAINER_NAME)"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    environment = {
      CONTAINER_IP = self.triggers.container_ip
    }
    command = <<-EOT
      set -euo pipefail
      # `ufw delete allow from X` removes the rule even if its comment has
      # drifted. Tolerate "Could not delete non-existent rule" so a partial
      # earlier destroy doesn't block a re-run.
      sudo ufw delete allow from "$CONTAINER_IP" >/dev/null 2>&1 || true
      sudo ufw reload >/dev/null || true
      echo "==> ufw: removed allow-from $CONTAINER_IP"
    EOT
  }

  depends_on = [lxd_instance.digital_notes]
}

# ---------------------------------------------------------------------------
# Cluster bootstrap: install k3s + helm + Postgres+pgvector + Kafka inside
# each LXD container by `lxc exec`-ing a resilient shell script. We keep
# this OUT of cloud-init because cloud-init can't retry across apt-mirror
# flakiness and silently swallows failures into /var/log inside the
# container — instead, terraform owns the bring-up, retries on `apply`,
# and reports failure loudly.
#
# The script is idempotent (each step probes "already done" first), so a
# re-apply on a healthy env is a no-op, and a re-apply on a partially-
# bootstrapped env picks up where it left off.
#
# Application secrets are passed in as env vars and rendered into K8s
# Secrets in the `digital-notes` namespace. Rotating any secret triggers
# the resource via the secrets_hash trigger below.
# ---------------------------------------------------------------------------

resource "null_resource" "cluster_bootstrap" {
  for_each = local.clusters_by_name

  triggers = {
    container = lxd_instance.digital_notes[each.key].name
    # filemd5 makes terraform re-run the bootstrap whenever we change the
    # script (tweak retries, fix a bug, add a step).
    script_hash = filemd5("${path.module}/scripts/cluster-bootstrap.sh")
    # `mac_address` is the only stable-but-recreate-sensitive attribute the
    # terraform-lxd/lxd provider exposes (it doesn't expose `id`). LXD
    # assigns a new MAC on every fresh container, so a destroy+recreate
    # changes this fingerprint and forces cluster_bootstrap to re-run.
    # Without it, terraform leaves the bootstrap state alone and a fresh
    # container comes up bare.
    instance_mac = lxd_instance.digital_notes[each.key].mac_address
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      LXD_CONTAINER    = self.triggers.container
      SCRIPT_PATH      = "${path.module}/scripts/cluster-bootstrap.sh"
      APPLICATION_NAME = var.application_name
      CLUSTER_NAME     = each.value.cluster_name
      CONTAINER_NAME   = each.value.container_name
      CLUSTER_SUBDOMAIN = each.value.subdomain
    }
    # Pass the identity/routing env vars through `lxc exec --env` so the
    # bootstrap script sees them. App secrets are NOT terraform's concern —
    # the deploy pipeline materializes K8s Secrets when it ships the apps.
    # Serialize the bootstrap across clusters with flock. Each cluster runs
    # k3s + Postgres + Kafka install — five of those starting concurrently on
    # one VPS OOM-kills k3s (TLS handshake timeout on 127.0.0.1:6443, websocket
    # 1006 on the lxc exec channel itself). flock holds an exclusive lock on
    # a host-side file so terraform-parallel cluster_bootstrap invocations
    # queue up instead of dogpiling. The lock is released as soon as the
    # bootstrap exits; subsequent applies (everything idempotent) re-acquire
    # quickly and skip steps already done.
    command = <<-EOT
      set -euo pipefail
      sudo flock /var/lock/cluster-bootstrap.lock bash -c '
        sudo lxc exec "$1" \
          --env APPLICATION_NAME="$2" \
          --env CLUSTER_NAME="$3" \
          --env CONTAINER_NAME="$4" \
          --env CLUSTER_SUBDOMAIN="$5" \
          -- bash -s "$3" < "$6"
      ' _ "$LXD_CONTAINER" "$APPLICATION_NAME" "$CLUSTER_NAME" \
          "$CONTAINER_NAME" "$CLUSTER_SUBDOMAIN" "$SCRIPT_PATH"
    EOT
  }

  # Need the container itself AND its host ufw allow rule before bootstrap
  # runs — the bootstrap pulls k3s/helm from the internet via the host's
  # NAT, which the ufw rule lets through.
  depends_on = [
    lxd_instance.digital_notes,
    null_resource.host_ufw_allow,
  ]
}

# ---------------------------------------------------------------------------
# Default SNI catch-all: refuses TLS for any unmatched hostname instead of
# falling through to the alphabetically-first 443 vhost. Without this, a
# request for a subdomain that has no HTTPS vhost (e.g. an env whose
# certbot run failed) gets served the wrong cert. Lives in /etc/nginx/conf.d
# so it loads BEFORE sites-enabled/* and wins the default_server slot.
# ---------------------------------------------------------------------------

resource "null_resource" "host_nginx_default_sni" {
  triggers = {
    config = file("${path.module}/templates/nginx-default-tls.conf")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      CONFIG = self.triggers.config
    }
    command = <<-EOT
      set -euo pipefail
      printf '%s' "$CONFIG" \
        | sudo tee /etc/nginx/conf.d/00-default-sni.conf >/dev/null
      sudo nginx -t
      sudo systemctl reload nginx
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      sudo rm -f /etc/nginx/conf.d/00-default-sni.conf
      sudo nginx -t && sudo systemctl reload nginx || true
    EOT
  }
}

# ---------------------------------------------------------------------------
# Cert-presence probe: queries the host filesystem each apply to detect
# whether certbot has successfully issued a cert for each subdomain. Feeding
# the result into host_nginx_vhost.triggers makes the vhost null_resource
# re-run automatically once a cert lands — even if it was issued out-of-band
# (manual `certbot certonly`, future certbot.timer renewal of a previously
# missing cert). Without this, the vhost would stay stuck on the HTTP-only
# variant until someone manually `terraform taint`-ed it.
# ---------------------------------------------------------------------------

data "external" "cert_status" {
  for_each = local.vhosts

  program = ["bash", "-c", <<-EOT
    if sudo test -f "/etc/letsencrypt/live/${each.value.subdomain}/fullchain.pem"; then
      printf '{"exists":"true"}'
    else
      printf '{"exists":"false"}'
    fi
  EOT
  ]
}

# ---------------------------------------------------------------------------
# Host nginx reverse proxy: one vhost per (env, public-service) pair —
# 3 services × N envs. All three vhosts for an env point at the same
# container IP because Traefik inside k3s routes by Host header to the
# correct backend service (Authentication / Notes / ai-core-service).
#
# This runs as `local-exec` because terraform itself is invoked on the LXD
# host. `sudo` is required because /etc/nginx is root-owned; the SSH user
# already has passwordless sudo (verified by the preflight step).
# ---------------------------------------------------------------------------

resource "null_resource" "host_nginx_vhost" {
  for_each = local.vhosts

  # We render BOTH flavors here so the trigger captures every input and the
  # provisioner can swap between them at runtime (depending on whether the
  # cert already exists on disk).
  triggers = {
    name      = each.value.cluster_name
    subdomain = each.value.subdomain

    # Note: the template uses `$$` everywhere it wants nginx to see a literal
    # `$` (e.g. `$$host`, `$$uri`). `templatefile()` only treats `$${` as an
    # escape — `$$` followed by anything else passes through unchanged — so
    # we post-process to collapse `$$` to `$` before writing to disk.
    config_http = replace(
      templatefile("${path.module}/templates/nginx-vhost.conf.tftpl", {
        name      = each.value.cluster_name
        subdomain = each.value.subdomain
        ip        = each.value.ip
        tls_ready = false
      }),
      "$$",
      "$"
    )
    config_tls = replace(
      templatefile("${path.module}/templates/nginx-vhost.conf.tftpl", {
        name      = each.value.cluster_name
        subdomain = each.value.subdomain
        ip        = each.value.ip
        tls_ready = true
      }),
      "$$",
      "$"
    )

    # Catch-all location snippet for this vhost. Same `$$` → `$` post-
    # processing as the vhost templates above.
    proxy_snippet = replace(
      templatefile("${path.module}/templates/proxy-location.conf.tftpl", {
        name = each.value.cluster_name
        ip   = each.value.ip
      }),
      "$$",
      "$"
    )

    le_email   = var.letsencrypt_email
    le_staging = tostring(var.letsencrypt_staging)

    # Re-run when the cert appears (or disappears). Without this, an
    # out-of-band cert issuance — manual `certbot certonly`, a successful
    # retry on a later apply, etc. — wouldn't promote the vhost from the
    # HTTP-only variant to the TLS variant until someone manually
    # `terraform taint`-ed this resource.
    cert_present = data.external.cert_status[each.key].result.exists

    # Re-run when the underlying container is recreated (new MAC). The
    # routing IP doesn't change (we pin it via the eth0 device), but the
    # k3s/Traefik install is fresh and the snippet should be re-dropped.
    instance_mac = lxd_instance.digital_notes[each.value.cluster_name].mac_address
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      VHOST_NAME    = self.triggers.name
      SUBDOMAIN     = self.triggers.subdomain
      VHOST_HTTP    = self.triggers.config_http
      VHOST_TLS     = self.triggers.config_tls
      PROXY_SNIPPET = self.triggers.proxy_snippet
      LE_EMAIL      = self.triggers.le_email
      LE_STAGING    = self.triggers.le_staging
    }
    command = <<-EOT
      set -euo pipefail

      AVAIL="/etc/nginx/sites-available/$VHOST_NAME.conf"
      ENABLED="/etc/nginx/sites-enabled/$VHOST_NAME.conf"
      LIVE_DIR="/etc/letsencrypt/live/$SUBDOMAIN"
      SNIPPET_DIR="/etc/nginx/snippets/$VHOST_NAME"
      SNIPPET_FILE="$SNIPPET_DIR/proxy.location.conf"

      install_vhost() {
        local content="$1"
        printf '%s' "$content" | sudo tee "$AVAIL" >/dev/null
        sudo ln -sf "$AVAIL" "$ENABLED"
        sudo nginx -t
        sudo systemctl reload nginx
      }

      # Stage 0: drop the catch-all location snippet that the vhost's
      # `include /etc/nginx/snippets/$VHOST_NAME/*.location.conf` line picks
      # up. Without this, a freshly-provisioned env's HTTPS vhost has no
      # location blocks and nginx falls back to its default site.
      sudo mkdir -p "$SNIPPET_DIR"
      printf '%s' "$PROXY_SNIPPET" | sudo tee "$SNIPPET_FILE" >/dev/null

      # Stage 1: install the HTTP-only vhost. This is always safe (no cert
      # paths referenced) and serves the ACME challenge from /var/www/certbot.
      install_vhost "$VHOST_HTTP"

      # Stage 2: acquire a cert if we don't already have one for this domain.
      # This is best-effort — if DNS hasn't been pointed at the host yet
      # certbot will fail HTTP-01, but we don't fail the apply: the vhost
      # stays HTTP-only and the next run picks up where we left off.
      if [ ! -f "$LIVE_DIR/fullchain.pem" ]; then
        echo "==> No cert for $SUBDOMAIN; running certbot"
        sudo mkdir -p /var/www/certbot

        STAGING_FLAG=""
        if [ "$LE_STAGING" = "true" ]; then
          STAGING_FLAG="--staging"
        fi

        # `flock` serializes certbot across the parallel host_nginx_vhost
        # null_resources. Without it, certbot's own lockfile rejects all but
        # one concurrent invocation with "Another instance of Certbot is
        # already running". The lockfile path doesn't have to be certbot's
        # own; we just need one shared file the parallel applies serialize on.
        if ! sudo flock /var/lock/certbot-tf.lock \
              certbot certonly --webroot -w /var/www/certbot \
              -d "$SUBDOMAIN" \
              --non-interactive --agree-tos \
              --email "$LE_EMAIL" \
              --keep-until-expiring \
              $STAGING_FLAG; then
          echo "WARN: certbot failed for $SUBDOMAIN — likely DNS not yet pointing here." >&2
          echo "WARN: leaving HTTP-only vhost in place; re-run terraform apply once DNS is live." >&2
          exit 0
        fi
      else
        echo "==> Cert for $SUBDOMAIN already present on disk"
      fi

      # Stage 3: cert is on disk — promote to the TLS-enabled vhost.
      if [ -f "$LIVE_DIR/fullchain.pem" ]; then
        install_vhost "$VHOST_TLS"
        echo "==> $SUBDOMAIN is now serving HTTPS"
      fi
    EOT
  }

  # Remove the symlink + config file when the vhost is destroyed. We
  # intentionally do NOT delete the cert from /etc/letsencrypt — keeping
  # it around is harmless and saves a re-issue if the vhost is recreated
  # (Let's Encrypt rate-limits issuance per domain).
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    environment = {
      VHOST_NAME = self.triggers.name
    }
    command = <<-EOT
      set -euo pipefail
      sudo rm -f "/etc/nginx/sites-enabled/$VHOST_NAME.conf" \
                 "/etc/nginx/sites-available/$VHOST_NAME.conf"
      sudo rm -rf "/etc/nginx/snippets/$VHOST_NAME"
      sudo nginx -t && sudo systemctl reload nginx || true
    EOT
  }

  # Don't proxy traffic at a container until its k3s + Traefik are actually
  # up; don't apply per-subdomain vhosts before the default-SNI catch-all
  # exists, otherwise the brief window between "first vhost applied" and
  # "default-SNI applied" would have nginx leak that vhost's cert for
  # unknown SNIs.
  depends_on = [
    lxd_instance.digital_notes,
    null_resource.cluster_bootstrap,
    null_resource.host_nginx_default_sni,
  ]
}

# ---------------------------------------------------------------------------
# Renewal smoke test: simulate the full ACME renewal flow against the real
# Let's Encrypt servers (no actual cert issued, just validation), so we
# discover problems with renewal infrastructure (DNS, port 80, nginx,
# webroot perms, deploy hook) at apply time — not 60 days later when the
# first real renewal silently fails. The actual auto-renewal is handled by
# the certbot.timer systemd unit set up in scripts/bootstrap-host.sh; this
# resource just verifies the timer's job will succeed when it fires.
#
# Re-runs whenever the set of vhosts changes (cert issued/replaced).
# ---------------------------------------------------------------------------

resource "null_resource" "certbot_renew_dryrun" {
  triggers = {
    # When any vhost is created/replaced, the cert may be new — re-test.
    vhost_ids = join(",", [
      for k, v in null_resource.host_nginx_vhost : v.id
    ])
    # Newline-delimited list of this stack's subdomains. Passed into the
    # provisioner so the dry-run only touches certs we own — a bare
    # `certbot renew` would sweep every cert on the host, including ones
    # belonging to other applications sharing this VPS.
    subdomains = join("\n", [for v in local.vhosts : v.subdomain])
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      SUBDOMAINS = self.triggers.subdomains
    }
    command = <<-EOT
      set -euo pipefail
      echo "==> Running 'certbot renew --dry-run' for THIS stack's certs only"
      echo "    (other apps' certs on the host are intentionally skipped)"

      # `certbot renew` has no positional domain filter, but `--cert-name`
      # scopes a renewal to a single lineage. We iterate this stack's
      # subdomains, skipping any that don't have a cert on disk yet (those
      # are HTTP-only vhosts waiting on DNS — certbot would error 'no such
      # certificate' for them and abort the smoke test).
      any_tested=false
      while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        if sudo test -f "/etc/letsencrypt/live/$domain/fullchain.pem"; then
          echo "    -> dry-run: $domain"
          sudo certbot renew --cert-name "$domain" --dry-run \
            --no-random-sleep-on-renew
          any_tested=true
        else
          echo "    -> skip:    $domain (no cert on disk yet)"
        fi
      done <<< "$SUBDOMAINS"

      if [ "$any_tested" = "false" ]; then
        echo "WARN: none of this stack's subdomains have certs on disk yet." >&2
        echo "      DNS likely not pointed at this VPS — re-apply once DNS is live." >&2
        exit 0
      fi
      echo "==> Renewal dry-run succeeded for this stack's certs"
    EOT
  }

  depends_on = [null_resource.host_nginx_vhost]
}
