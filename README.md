# secure-vault-terraform
Secure-Vault-Terraform repository is an Infrastructure-as-Code (IaC) platform designed to automatically provision, configure, and manage a complete multi-environment hosting infrastructure for the Secure Vault (Digital Notes) microservices application.
Infrastructure-as-Code that provisions a complete **multi-environment hosting
platform for the Digital Notes / secure-vault microservices backend** on a
**single VPS**, using **LXD/LXC containers + Terraform**, driven by **Jenkins CI**.

One VPS hosts several isolated LXD containers — one per environment cluster
(`dev-a`, `dev-b`, `test`, `stage`, `prod`). Each container runs a full
**k3s** Kubernetes stack with all 5 microservices, plus Postgres+pgvector and
Kafka inside it. The host VPS is the public front door: nginx terminates TLS
and routes each request to the right container.

## Architecture
```
                Internet
                   │
        ┌──────────▼──────────────────────────────────┐
        │   VPS host (Ubuntu)                          │
        │                                              │
        │  nginx (L7)   → HTTPS per subdomain,         │
        │                 routes by Host header        │
        │  nginx stream → Postgres :5432 routed by     │
        │     (L4)        TLS SNI                       │
        │  certbot / Let's Encrypt   (TLS termination) │
        │  Jenkins                   (CI/CD)           │
        │  Tailscale                 (private PG access)│
        │                                              │
        │   lxdbr0 bridge — 10.86.216.0/24 (DHCP)      │
        │    ├── secure-vault-dev-a                    │
        │    ├── secure-vault-dev-b                    │
        │    ├── secure-vault-test    each container = │
        │    ├── secure-vault-stage   k3s + 5 services │
        │    └── secure-vault-prod    + Postgres+pgvector
        │                             + Kafka          │
        └──────────────────────────────────────────────┘
```

Inside each container, **Traefik** (the k3s ingress) does path-based routing
under the cluster's single public subdomain:

| Path        | Service          | Port | Public? |
|-------------|------------------|------|---------|
| `/auth/*`   | Authentication   | 3211 | yes     |
| `/notes/*`  | Notes            | 3213 | yes     |
| `/ai/*`     | ai-core-service  | 8001 | yes     |
| (internal)  | Roles            | —    | no — called by Authentication on `lxdbr0` |
| (internal)  | ai-worker        | —    | no — Kafka consumer |

### Naming
- **Container:** `<application_name>-<cluster_name>` → `secure-vault-dev-a`
- **Subdomain:** `<application_name>-<cluster_name>.<domain>` →
  `secure-vault-dev-a.cntrlflix.com`
- **Production** gets the bare apex form `<application_name>.<domain>` →
  `secure-vault.cntrlflix.com` (container name stays `secure-vault-prod`).

## Repository layout

| Path | Role |
|------|------|
| [scripts/bootstrap-host.sh](scripts/bootstrap-host.sh) | Idempotently turns a bare Ubuntu VPS into the platform host: installs LXD (snap, 5.21/stable), nginx, certbot, Terraform, Tailscale; configures the `lxdbr0` bridge, ufw firewall, kernel modules + sysctls for k3s-in-LXC. |
| [scripts/install-jenkins.sh](scripts/install-jenkins.sh) | Installs Jenkins LTS on the host behind nginx + Let's Encrypt TLS. Bootstraps the CI server itself. |
| [infra/terraform/main.tf](infra/terraform/main.tf) | The core. Creates one LXD container per cluster, then via `null_resource` + `local-exec`: bootstraps k3s inside each, writes per-cluster nginx vhosts, issues TLS certs, sets up SNI-based Postgres routing, ufw rules, and a renewal smoke test. |
| [infra/terraform/scripts/cluster-bootstrap.sh](infra/terraform/scripts/cluster-bootstrap.sh) | Runs *inside* each container (via `lxc exec`): installs k3s, helm, Postgres+pgvector, Kafka; creates the `digital-notes` namespace, DB, schema, and Kafka topics. |
| [infra/terraform/variables.tf](infra/terraform/variables.tf) | Inputs — `application_name`, `cluster_names`, `domain`, Let's Encrypt config, LXD connection. Heavily validated. |
| [infra/terraform/outputs.tf](infra/terraform/outputs.tf) | Per-cluster runtime info (IPs, container names, subdomains, service URLs, Postgres endpoints) for downstream pipelines. |
| [infra/terraform/templates/](infra/terraform/templates/) | nginx vhost, proxy-location, and default-SNI config templates (`.tftpl`). |
| [Jenkinsfile](Jenkinsfile) | CI pipeline: preflight → bootstrap host → `terraform init/plan/apply` → smoke test. Runs **on the VPS itself** (all local-exec, no SSH). |

## How it fits together

1. **`install-jenkins.sh`** bootstraps the CI server on the VPS.
2. Point Jenkins at this repo. On a push to **`develop`**, the
   [Jenkinsfile](Jenkinsfile) pipeline runs.
3. The pipeline re-runs **`bootstrap-host.sh`** (idempotent) to ensure LXD,
   nginx, certbot, Terraform, etc. are present and configured.
4. It then runs **`terraform apply`**, which creates/updates the LXD
   containers and runs **`cluster-bootstrap.sh`** inside each to bring up k3s
   and its dependencies.
5. nginx vhosts + TLS certs are issued, and the smoke stage verifies each
   container's Postgres is reachable.

## Quick start (manual, on the VPS)

> Terraform here uses `local-exec` with `sudo lxc exec` / `sudo tee
> /etc/nginx/...`, so it **must be invoked on the LXD host itself** — it
> cannot be applied from a developer workstation.

```bash
# 1. Bootstrap the host (installs LXD, nginx, certbot, terraform, tailscale)
sudo LXD_TRUST_PASSWORD='...' ALLOWED_IP='1.2.3.4' \
     bash scripts/bootstrap-host.sh

# 2. (optional) Install Jenkins to drive everything via CI
sudo JENKINS_DOMAIN='jenkins.cntrlflix.com' \
     LETSENCRYPT_EMAIL='you@example.com' \
     bash scripts/install-jenkins.sh

# 3. Provision the clusters
cd infra/terraform
sudo -E terraform init
sudo -E terraform apply \
  -var lxd_host=127.0.0.1 \
  -var lxd_trust_password="$LXD_TRUST_PASSWORD" \
  -var application_name=secure-vault \
  -var cluster_names=dev-a,dev-b,test,stage,prod \
  -var domain=cntrlflix.com \
  -var letsencrypt_email=you@example.com \
  -var letsencrypt_staging=true   # flip to false for real certs
```

DNS A records for each subdomain must point at the VPS before certbot can
issue real certs. If DNS isn't live yet, the run still succeeds — it leaves an
HTTP-only vhost and the next apply promotes it to HTTPS.

## Design decisions worth knowing

- **Idempotent everywhere.** Both shell scripts and the Terraform provisioners
  probe current state and skip completed work, so partial failures resume
  cleanly and re-applies on a healthy environment are no-ops.
- **`prevent_destroy = true`** on every container — Postgres data and Kafka
  topics live inside the container filesystem, so a stray `terraform destroy`
  or a mid-list rename can't silently wipe prod. Retiring a cluster requires a
  deliberate commit.
- **No pinned IPs.** `lxdbr0`'s DHCP assigns each container a free address;
  Terraform reads it back for vhosts and ufw rules. **Append** new clusters to
  the end of `cluster_names` — inserting in the middle renumbers later
  clusters' IPs, which `prevent_destroy` then refuses.
- **Two-stage TLS.** Drop an HTTP-only vhost → certbot HTTP-01 challenge →
  promote to HTTPS once the cert is on disk. Tolerates not-yet-pointed DNS.
- **Postgres via SNI.** An nginx `stream` block peeks at the TLS ClientHello
  (`ssl_preread`) and routes `:5432` to the matching container by subdomain —
  all clusters share one port. Postgres is **not** public; reach it from a
  laptop over **Tailscale** (the VPS advertises `10.86.216.0/24` as a subnet
  route). pgAdmin must use `sslmode=require` + `sslnegotiation=direct`.
- **k3s-in-LXC tuning.** Containers are privileged with `security.nesting`,
  syscall intercepts, `raw.lxc` (apparmor unconfined, `proc:rw sys:rw`), and
  pre-loaded kernel modules (`br_netfilter`, `overlay`, …) — the minimum to run
  k3s inside an LXD container. These fields are frozen via `ignore_changes`;
  drift would force a container recreate and wipe all data.
- **Secrets are out of scope.** This repo provisions infrastructure only. App
  secrets (JWT, OAuth, SMTP, OpenAI/Gemini keys, internal X-INTERNAL-KEY) are
  materialized as K8s Secrets by the separate app-deploy pipeline at deploy
  time. The Bitnami Postgres chart auto-generates the superuser password into
  the `<release>-postgresql` Secret.

## CI triggers (Jenkins)

- Single-branch Pipeline pointed at **`develop`** → automatic
  `terraform apply` on push.
- **Build with Parameters** lets you override `APPLICATION_NAME`,
  `CLUSTER_NAMES`, `DOMAIN`, and `LE_STAGING`.
- `disableConcurrentBuilds()` serializes runs — Terraform state is not
  concurrency-safe.

## Before installing the jenkins
-certbot certificates shows "No certificates found" — so the cert from this morning is genuinely gone (the cert files and renewal config were removed at some point). That also confirms there are no other certbot-managed certs on this host yet — which actually makes the recovery command safe to run right now, because wiping the accounts dir can't break any other cert (there are none).

So: just run the command, once by hand. Given the current clean-slate state, it's the right tool:

echo "--- cli.ini (would override --staging) ---"
cat /etc/letsencrypt/cli.ini 2>/dev/null || echo "(no cli.ini)"

echo "--- leftover account state ---"
ls -la /etc/letsencrypt/accounts/ 2>/dev/null || echo "(no accounts dir)"

rm -rf /etc/letsencrypt/accounts

certbot certonly --webroot -w /var/www/certbot \
  -d jenkins.cntrlflix.com \
  --non-interactive --agree-tos \
  --email 'YOUR_EMAIL_ID' \
  --dry-run -v

## Installation commands

Follow the below commands:

- root@srv1061621:~# cd ..
- root@srv1061621:/# cd scripts/
- root@srv1061621:/scripts# sed -i 's/\r$//' install-jenkins.sh
- root@srv1061621:/scripts# JENKINS_DOMAIN='jenkins.cntrlflix.com' \ LETSENCRYPT_EMAIL='YOUR_EMAIL_ID' \ bash install-jenkins.sh
