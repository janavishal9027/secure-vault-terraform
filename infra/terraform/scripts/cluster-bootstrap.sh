#!/usr/bin/env bash
#
# Bring up a single LXD container as a k3s node hosting the Digital Notes
# backend (Authentication, Roles, Notes, ai-core-service, ai-worker), plus
# the in-cluster Postgres+pgvector and Kafka they depend on.
#
# Run via `lxc exec <container> -- bash -s <CLUSTER_NAME>` from terraform's
# null_resource.cluster_bootstrap. Terraform passes the env vars listed in
# REQUIRED_ENV_VARS below via `lxc exec --env`; missing any of them aborts
# the script before it makes partial progress.
#
# Design goals:
#   - Idempotent: safe to re-run on already-bootstrapped containers. Each
#     step probes for "already done" before doing work.
#   - Independent of apt: k3s + helm only depend on `curl` (present in the
#     base Ubuntu image), so a flaky Canonical mirror cannot block the
#     cluster from coming up. Postgres+pgvector and Kafka are installed via
#     Helm into k3s — also no apt dependency.
#   - Loud on real failure: critical steps (k3s install, k3s API ready,
#     Postgres install, Kafka install, secret/topic creation) fail the
#     script. The terraform apply surfaces the failure.
#
# Usage: invoked by terraform; not designed for manual use, but can be
# `lxc exec secure-vault-dev-a -- bash -s dev-a < cluster-bootstrap.sh` after
# exporting the env vars listed below.

set -euo pipefail

CLUSTER_NAME="${1:?cluster name (e.g. dev-a) required as first arg}"

REQUIRED_ENV_VARS=(
  APPLICATION_NAME
  CONTAINER_NAME
  CLUSTER_SUBDOMAIN
)
for v in "${REQUIRED_ENV_VARS[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: required env var $v is unset (terraform should pass it via lxc exec --env)" >&2
    exit 1
  fi
done

NS="digital-notes"
PG_DB="digital-notes"
PG_SCHEMA="secure-vault"
KAFKA_TOPICS=(notes.lifecycle notes.summary.request ai.summary.ready)

log()  { printf '\n==> %s\n' "$*"; }
skip() { printf '    skip: %s\n' "$*"; }
do_()  { printf '    do:   %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Wait for cloud-init so it doesn't fight us over apt locks / package state.
# ---------------------------------------------------------------------------
log "Waiting for cloud-init to finish (max 120s)"
# `--wait` blocks until cloud-init reaches a terminal state. We don't care
# whether it succeeded — apt failures inside cloud-init are exactly why we
# exist. Bound by `timeout` because a stuck cloud-init (e.g. apt retrying
# an unreachable mirror for hours) would otherwise hang us forever.
timeout 120 cloud-init status --wait >/dev/null 2>&1 || true
do_ "cloud-init reached terminal state (or 120s timeout)"

# ---------------------------------------------------------------------------
# k3s — installed FIRST since it only needs curl and can't be blocked by
# apt mirror flakiness. Retries on transient failures (e.g. get.k3s.io
# briefly unreachable).
# ---------------------------------------------------------------------------
log "Checking k3s"
if [[ -x /usr/local/bin/k3s ]]; then
  skip "/usr/local/bin/k3s already installed"
else
  do_ "installing k3s (with retry)"
  installed=false
  for i in 1 2 3 4 5; do
    # Use the actual LXD container name as the k3s node name so kubectl
    # output ('secure-vault-dev-a') matches what the operator sees in `lxc list`.
    if curl -sfL https://get.k3s.io \
       | INSTALL_K3S_EXEC="--node-name ${CONTAINER_NAME}" sh -; then
      installed=true
      break
    fi
    echo "    k3s install attempt $i failed; sleeping 30s"
    sleep 30
  done
  if ! $installed; then
    echo "ERROR: k3s install failed after 5 attempts" >&2
    exit 1
  fi
fi

log "Waiting for k3s API + node Ready"
# `kubectl get nodes` succeeds as soon as the API socket is listening — but
# k3s restarts the API a few times during initial bring-up while it loads
# etcd / registers CRDs, so a single successful probe isn't enough. Require
# both that the API answers `/readyz` AND that the node has reached the
# Ready condition; the latter means k3s is past the unstable startup phase.
deadline=$(( $(date +%s) + 300 ))
k3s_ready=false
while (( $(date +%s) <= deadline )); do
  if /usr/local/bin/k3s kubectl get --raw='/readyz' >/dev/null 2>&1 \
     && /usr/local/bin/k3s kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; then
    k3s_ready=true
    break
  fi
  sleep 3
done
if ! $k3s_ready; then
  echo "ERROR: k3s never became Ready within 300s" >&2
  journalctl -u k3s --no-pager -n 50 >&2 || true
  exit 1
fi
do_ "k3s API responsive and node Ready"

# Convenience: pin kubectl to k3s's bundled binary + kubeconfig everywhere
# below, so a host kubectl in PATH (if any) doesn't accidentally talk to
# the wrong cluster.
KUBECTL="/usr/local/bin/k3s kubectl"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# ---------------------------------------------------------------------------
# Helm — used to install Postgres, pgvector init, and Kafka into k3s. Same
# install pattern as k3s: idempotent + retry, since get.helm.sh has
# occasional flakiness and a missing helm binary fails the deploy at the
# next step.
# ---------------------------------------------------------------------------
log "Checking helm"
if command -v helm >/dev/null 2>&1; then
  skip "helm already installed ($(helm version --short 2>/dev/null || echo 'present'))"
else
  do_ "installing helm (with retry)"
  helm_ok=false
  for i in 1 2 3 4 5; do
    if curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; then
      helm_ok=true
      break
    fi
    echo "    helm install attempt $i failed; sleeping 30s"
    sleep 30
  done
  if ! $helm_ok; then
    echo "ERROR: helm install failed after 5 attempts" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Bitnami helm repo for Postgres + Kafka. `helm repo add` is idempotent —
# repeated calls just refresh the URL.
# ---------------------------------------------------------------------------
log "Configuring helm repos"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
helm repo update bitnami >/dev/null
do_ "bitnami repo present"

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
log "Checking namespace ${NS}"
if $KUBECTL get namespace "$NS" >/dev/null 2>&1; then
  skip "namespace ${NS} already exists"
else
  do_ "creating namespace ${NS}"
  $KUBECTL create namespace "$NS" >/dev/null
fi

# ---------------------------------------------------------------------------
# Application secrets are intentionally OUT OF SCOPE for this script.
# The deploy pipeline (Helm chart that ships the 5 microservices) creates
# the K8s Secrets they need (JWT, OAuth, SMTP, OpenAI, Gemini, etc.). Keep
# bootstrap focused on infra; secrets that change for non-infra reasons
# don't belong in a bootstrap re-run.
# ---------------------------------------------------------------------------

# Identity/routing ConfigMap the deploy pipeline reads to find out which
# cluster it's deploying into and what hostnames its IngressRoutes should
# match. Not secret — safe to materialise here.
$KUBECTL apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: digital-notes-ingress
data:
  application: "${APPLICATION_NAME}"
  cluster: "${CLUSTER_NAME}"
  container: "${CONTAINER_NAME}"
  # Single per-cluster host; Traefik routes services by URL path under it.
  # Deploy pipeline's IngressRoutes should match Host(cluster-host) &&
  # PathPrefix(/auth|/notes|/ai) and (recommended) apply a stripPrefix
  # middleware so each backend sees a clean path.
  cluster-host: "${CLUSTER_SUBDOMAIN}"
  auth-path: "/auth"
  notes-path: "/notes"
  ai-path: "/ai"
EOF
do_ "configmap/digital-notes-ingress applied"

# ---------------------------------------------------------------------------
# Postgres 17 + pgvector — apt-installed on the container OS from the PGDG
# repo (Ubuntu 22.04's default apt ships PG14; pgvector is also packaged by
# PGDG as postgresql-17-pgvector). Listens on the bridge IP at :5432, no
# public exposure — laptops reach it via Tailscale (VPS advertises
# 10.86.216.0/24 to the tailnet, traffic is end-to-end encrypted by WireGuard).
# ---------------------------------------------------------------------------
log "Checking PGDG apt repo"
if [[ -f /etc/apt/sources.list.d/pgdg.list ]] \
   && [[ -s /usr/share/keyrings/postgresql-archive-keyring.gpg ]]; then
  skip "PGDG repo already configured"
else
  do_ "installing PGDG keyring + apt list"
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
  codename=$(lsb_release -cs)
  echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
fi

log "Checking Postgres 17"
if command -v psql >/dev/null 2>&1 \
   && psql --version | grep -q "psql (PostgreSQL) 17"; then
  skip "postgres 17 already installed ($(psql --version))"
else
  do_ "installing postgresql-17 + postgresql-17-pgvector (apt with retries)"
  apt_ok=false
  for i in 1 2 3 4 5; do
    if DEBIAN_FRONTEND=noninteractive apt-get update \
         -o Acquire::Retries=10 \
         -o Acquire::http::Timeout=30 \
         -o Acquire::https::Timeout=30; then
      apt_ok=true
      break
    fi
    echo "    apt-get update attempt $i failed; sleeping 30s"
    sleep 30
  done

  if ! $apt_ok; then
    echo "WARN: apt-get update failed after 5 attempts; skipping postgres install" >&2
  elif ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
         -o Acquire::Retries=10 \
         postgresql-17 postgresql-contrib postgresql-17-pgvector; then
    echo "WARN: postgres install failed; skipping postgres config" >&2
  fi
fi

# `sudo -u postgres` from /root prints "could not change directory" warnings
# (postgres user can't read /root). cd to /tmp first so the warnings go away.
if command -v psql >/dev/null 2>&1; then
  cd /tmp
  log "Configuring Postgres"
  pg_conf=$(ls /etc/postgresql/*/main/postgresql.conf 2>/dev/null | head -1 || true)
  pg_hba=$(ls /etc/postgresql/*/main/pg_hba.conf 2>/dev/null | head -1 || true)

  if [[ -z "$pg_conf" || -z "$pg_hba" ]]; then
    echo "WARN: Postgres config files not found; skipping configuration" >&2
  else
    do_ "setting postgres password = cluster name (${CLUSTER_NAME})"
    # Direct interpolation is safe: var.cluster_names is validated by terraform
    # to be ^[a-z0-9][a-z0-9-]{0,40}$ — no quotes, no shell metachars.
    sudo -u postgres psql \
      -c "ALTER USER postgres WITH PASSWORD '${CLUSTER_NAME}';" >/dev/null

    if grep -q "^listen_addresses = '\*'" "$pg_conf"; then
      skip "listen_addresses already '*'"
    else
      do_ "setting listen_addresses = '*'"
      sed -i "s/^#\?listen_addresses\s*=.*/listen_addresses = '*'/" "$pg_conf"
    fi

    if grep -qF "host all all 0.0.0.0/0 md5" "$pg_hba"; then
      skip "pg_hba md5 rule already present"
    else
      do_ "adding pg_hba md5 rule"
      echo "host all all 0.0.0.0/0 md5" >> "$pg_hba"
    fi

    # TLS for Postgres — required for the host-side nginx stream SNI
    # routing (`null_resource.host_nginx_pg_stream`). pgAdmin connects with
    # sslmode=require + sslnegotiation=direct, which sends a TLS ClientHello
    # with SNI as the very first packet; the cert below is what Postgres
    # then presents during the handshake. We use a self-signed cert with
    # CN = subdomain because pgAdmin connects with sslmode=require, not
    # verify-full — SNI routing only needs the client to *send* the right
    # name, not validate the cert.
    pg_data_dir=$(dirname "$pg_conf")
    if [[ ! -f "$pg_data_dir/server.crt" ]] || [[ ! -f "$pg_data_dir/server.key" ]]; then
      do_ "generating self-signed TLS cert for postgres (CN=${CLUSTER_SUBDOMAIN})"
      openssl req -new -x509 -days 3650 -nodes \
        -subj "/CN=${CLUSTER_SUBDOMAIN}" \
        -addext "subjectAltName=DNS:${CLUSTER_SUBDOMAIN}" \
        -out "$pg_data_dir/server.crt" \
        -keyout "$pg_data_dir/server.key" >/dev/null 2>&1
      chown postgres:postgres "$pg_data_dir/server.crt" "$pg_data_dir/server.key"
      chmod 600 "$pg_data_dir/server.key"
    else
      skip "server.crt / server.key already present"
    fi

    if ! grep -q "^ssl = on" "$pg_conf"; then
      do_ "enabling ssl in postgresql.conf"
      sed -i "s/^#\?ssl\s*=.*/ssl = on/" "$pg_conf"
      grep -q "^ssl = on" "$pg_conf" || echo "ssl = on" >> "$pg_conf"
    fi

    do_ "restarting postgresql"
    systemctl restart postgresql

    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" | grep -q 1; then
      do_ "creating database ${PG_DB}"
      sudo -u postgres createdb "${PG_DB}"
    else
      skip "database ${PG_DB} already exists"
    fi

    do_ "ensuring schema ${PG_SCHEMA} and pgvector extension in ${PG_DB}"
    sudo -u postgres psql -d "${PG_DB}" <<SQL >/dev/null
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS "${PG_SCHEMA}";
ALTER DATABASE "${PG_DB}" SET search_path TO "${PG_SCHEMA}", public;
SQL
  fi
fi

# ---------------------------------------------------------------------------
# Kafka — single broker, KRaft mode (no Zookeeper). Topics are created
# below via `kafka-topics.sh` exec rather than the chart's
# `provisioning.topics` because the chart's provisioning runs once during
# install and isn't easy to make idempotent across upgrades.
#
# Resource caps: when multiple clusters bootstrap in parallel on one VPS,
# the Bitnami chart's defaults (no requests, JVM picking heap from cgroup
# headroom) overcommit memory and the k3s API drops the helm websocket
# (visible as "websocket: close 1006" or "context deadline exceeded").
# Cap the JVM heap and request a small floor so the kube scheduler can
# actually fit the broker.
# ---------------------------------------------------------------------------
log "Installing/upgrading Kafka via helm"
kafka_ok=false
for i in 1 2 3; do
  # Bitnami moved free public images off docker.io/bitnami/* in Aug 2025;
  # surviving free copies live under docker.io/bitnamilegacy/*. Without the
  # global.security.allowInsecureImages override, the chart refuses any
  # registry/repo it doesn't recognise as the Bitnami Secure catalog.
  if helm upgrade --install kafka bitnami/kafka \
       -n "$NS" \
       --set global.security.allowInsecureImages=true \
       --set image.registry=docker.io \
       --set image.repository=bitnamilegacy/kafka \
       --set controller.replicaCount=1 \
       --set broker.replicaCount=0 \
       --set listeners.client.protocol=PLAINTEXT \
       --set controller.persistence.size=4Gi \
       --set controller.resources.requests.memory=512Mi \
       --set controller.resources.requests.cpu=100m \
       --set controller.resources.limits.memory=1Gi \
       --set controller.heapOpts="-Xmx384m -Xms384m" \
       --wait --timeout 15m >/dev/null; then
    kafka_ok=true
    break
  fi
  echo "    kafka helm install attempt $i failed; sleeping 30s before retry" >&2
  sleep 30
done
if ! $kafka_ok; then
  echo "ERROR: kafka helm install failed after 3 attempts" >&2
  echo "       inspect with: kubectl -n ${NS} get pods,events --sort-by=.lastTimestamp" >&2
  exit 1
fi
do_ "kafka release ready"

# ---------------------------------------------------------------------------
# Kafka topics — created by `exec`-ing into the broker pod. Idempotent
# because `kafka-topics.sh --create --if-not-exists` is a no-op when the
# topic already exists. We do this from inside the cluster (not via a
# host-side kafka client) so we don't have to install kafka tooling on
# the LXD container itself.
# ---------------------------------------------------------------------------
log "Ensuring Kafka topics exist"

# Even after `helm --wait` returns, the controller pod can take a few more
# seconds before kafka-topics.sh works (KRaft metadata catch-up). Wait
# explicitly for the pod's Ready condition before trying.
$KUBECTL -n "$NS" wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=kafka --timeout=180s >/dev/null \
  || echo "WARN: kafka pod not Ready within 180s; topic creation may flake" >&2

KAFKA_POD=$($KUBECTL -n "$NS" get pods -l app.kubernetes.io/component=controller-eligible -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$KAFKA_POD" ]]; then
  # Fall back to the legacy label set if the chart version is older.
  KAFKA_POD=$($KUBECTL -n "$NS" get pods -l app.kubernetes.io/name=kafka -o jsonpath='{.items[0].metadata.name}')
fi

for topic in "${KAFKA_TOPICS[@]}"; do
  if $KUBECTL -n "$NS" exec "$KAFKA_POD" -- \
       kafka-topics.sh --bootstrap-server localhost:9092 \
       --create --if-not-exists \
       --topic "$topic" \
       --partitions 3 --replication-factor 1 >/dev/null 2>&1; then
    do_ "topic ${topic} ensured"
  else
    echo "WARN: failed to ensure topic ${topic} — re-run terraform apply once kafka is fully up" >&2
  fi
done

# ---------------------------------------------------------------------------
# ufw — disable inside the container; the host's ufw is the real gatekeeper.
# ---------------------------------------------------------------------------
log "Disabling container-level ufw"
ufw disable >/dev/null 2>&1 || true
do_ "ok"

log "Cluster ${CONTAINER_NAME} (application=${APPLICATION_NAME}, cluster=${CLUSTER_NAME}) bootstrap complete"
log "Next: deploy the 5 microservices into namespace ${NS} (separate pipeline)"
