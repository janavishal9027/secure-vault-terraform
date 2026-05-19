# ---------------------------------------------------------------------------
# LXD host + provider connection
# ---------------------------------------------------------------------------

variable "lxd_host" {
  description = "LXD server IP address (use 127.0.0.1 when terraform is invoked on the host itself)."
  type        = string
}

variable "lxd_trust_password" {
  description = "LXD trust password (set via core.trust_password by the bootstrap script)."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Public DNS
# ---------------------------------------------------------------------------

variable "domain" {
  description = "Public DNS apex for all environment subdomains (e.g. 'cntrlflix.com'). No default so a missing value fails loud rather than silently using a stale domain."
  type        = string

  validation {
    condition     = !startswith(var.domain, ".") && !endswith(var.domain, ".") && length(var.domain) > 0
    error_message = "domain must be a bare apex like 'example.com' (no leading/trailing dot)."
  }
}

variable "letsencrypt_email" {
  description = "Contact email for Let's Encrypt account + expiry warnings."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.letsencrypt_email))
    error_message = "letsencrypt_email must look like a valid email address."
  }
}

variable "letsencrypt_staging" {
  description = "Use Let's Encrypt staging CA (untrusted certs but no rate limits). Flip to true while iterating, false for real certs."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Per-cluster topology
#
# An "application" is a logical product (e.g. "secure-vault"). Each application
# can have N clusters (e.g. dev-a, dev-b, test, stage, prod). One LXD
# container per cluster runs k3s with all 5 microservices (Authentication,
# Roles, Notes, ai-core-service, ai-worker), Postgres+pgvector, and Kafka
# inside. Roles is intentionally NOT exposed publicly — it's only called
# by Authentication on the internal network.
#
# Container names are `<application_name>-<cluster_name>`, e.g. secure-vault-dev-a.
# Public subdomains follow `<service>-<cluster_name>.<domain>`, e.g.
# auth-dev-a.cntrlflix.com.
# ---------------------------------------------------------------------------

variable "application_name" {
  description = "Logical application/product name (e.g. 'secure-vault'). Used as the prefix for every container name and as a label propagated into k3s metadata."
  type        = string

  validation {
    # Must satisfy LXD instance-name rules AND leave headroom for
    # `<application_name>-<cluster_name>` to stay under LXD's 63-char limit.
    # Cap the application name itself at 20 chars so even the longest
    # plausible cluster name still fits.
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,19}$", var.application_name))
    error_message = "application_name must be lowercase alphanumeric with hyphens, 1-20 chars, no leading hyphen."
  }
}

variable "cluster_names" {
  description = "Comma-delimited list of cluster names (e.g. 'dev-a,dev-b,test,stage,prod'). Each entry produces an LXD container '<application_name>-<cluster_name>'. Stored as a string so Bitbucket repo variables (which only hold strings) can drive it directly. APPEND new clusters at the END of the list — inserting in the middle renumbers the auto-assigned bridge IPs of every later cluster, which prevent_destroy will then refuse."
  type        = string

  validation {
    # Every trimmed entry must satisfy LXD instance-name rules. Empty
    # entries (trailing comma, double comma) are tolerated by the split
    # logic in main.tf, but anything non-empty must be a valid name.
    condition = alltrue([
      for n in [for s in split(",", var.cluster_names) : trimspace(s) if trimspace(s) != ""] :
      can(regex("^[a-z0-9][a-z0-9-]{0,40}$", n))
    ])
    error_message = "Each cluster name (between commas) must be lowercase alphanumeric with hyphens, 1-40 chars, no leading hyphen."
  }
}

variable "postgres_password" {
  description = "Postgres superuser password used inside every cluster's container. Set via Jenkins credential — DO NOT default. Public-internet-exposed Postgres requires a strong password."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.postgres_password) >= 16
    error_message = "postgres_password must be at least 16 chars (Postgres is exposed on a public TCP port; weak passwords get brute-forced)."
  }
}

variable "bridge_cidr" {
  description = "lxdbr0 subnet — must match BRIDGE_CIDR in the bootstrap script. Terraform doesn't carve IPs out of this range itself; lxdbr0's built-in DHCP server assigns each container a free address from this subnet automatically. The variable is kept here so the bootstrap-host.sh side can still see it via the pipeline."
  type        = string
  default     = "10.86.216.0/24"

  validation {
    condition     = can(cidrnetmask(var.bridge_cidr))
    error_message = "bridge_cidr must be a valid IPv4 CIDR (e.g. '10.86.216.0/24')."
  }
}

# ---------------------------------------------------------------------------
# Application secrets are intentionally OUT OF SCOPE here.
#
# This Terraform provisions infrastructure only (LXD container, k3s, Postgres,
# Kafka, namespace). The 5 microservices' secrets — JWT, OAuth, SMTP, OpenAI,
# Gemini, internal X-INTERNAL-KEY — are created by the app-deploy pipeline
# (Helm chart values → K8s Secrets) at deploy time, not bootstrap time.
#
# The Bitnami Postgres chart auto-generates a superuser password and stores
# it in `<release>-postgresql` Secret; the deploy pipeline reads that Secret
# to wire DataSources for the apps.
# ---------------------------------------------------------------------------
