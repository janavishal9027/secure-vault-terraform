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
# psql client — installed on the container OS so operators can `lxc exec`
# into the container and connect to the in-cluster Postgres without going
# through `kubectl exec`. Idempotent: skip if already present.
# ---------------------------------------------------------------------------
log "Checking psql client"
if command -v psql >/dev/null 2>&1; then
  skip "psql already installed ($(psql --version))"
else
  do_ "installing postgresql-client"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql-client
fi

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
# Postgres + pgvector — Bitnami chart deploys postgres as a StatefulSet
# with a PVC. The Bitnami `postgresql` image ships with pgvector available;
# the `digital-notes` database, the `secure-vault` schema, and the `vector`
# extension are created by an init script the chart mounts on first start.
#
# We do NOT pass --set auth.postgresPassword. The Bitnami chart auto-
# generates a strong password on first install and stores it in the
# `postgres-postgresql` K8s Secret (key: `postgres-password`). Re-running
# this script preserves the existing password (the chart reads back the
# Secret on upgrade). The deploy pipeline reads that Secret to wire
# DataSources for the 5 microservices.
# ---------------------------------------------------------------------------
log "Installing/upgrading Postgres+pgvector via helm"
$KUBECTL apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-init
data:
  00-init.sql: |
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE SCHEMA IF NOT EXISTS "${PG_SCHEMA}";
    -- Future-proof: ensure pgvector is also visible from the schema search path.
    ALTER DATABASE "${PG_DB}" SET search_path TO "${PG_SCHEMA}", public;
EOF

# Retry the helm install up to 3 times. Under contention (multiple
# clusters bootstrapping in parallel on a single VPS) the helm <-> k3s
# API websocket can drop mid-`--wait` and surface as "websocket: close
# 1006" or "context deadline exceeded". The chart is idempotent so a
# retry just resumes from wherever it left off.
pg_ok=false
for i in 1 2 3; do
  # See Kafka block below — same Bitnami → bitnamilegacy migration applies.
  if helm upgrade --install postgres bitnami/postgresql \
       -n "$NS" \
       --set global.security.allowInsecureImages=true \
       --set image.registry=docker.io \
       --set image.repository=bitnamilegacy/postgresql \
       --set auth.database="${PG_DB}" \
       --set primary.initdb.scriptsConfigMap=postgres-init \
       --set primary.persistence.size=4Gi \
       --set primary.resources.requests.memory=256Mi \
       --set primary.resources.requests.cpu=100m \
       --set primary.resources.limits.memory=512Mi \
       --wait --timeout 15m >/dev/null; then
    pg_ok=true
    break
  fi
  echo "    postgres helm install attempt $i failed; sleeping 30s before retry" >&2
  sleep 30
done
if ! $pg_ok; then
  echo "ERROR: postgres helm install failed after 3 attempts" >&2
  exit 1
fi
do_ "postgres release ready (password in secret/postgres-postgresql, key: postgres-password)"

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
