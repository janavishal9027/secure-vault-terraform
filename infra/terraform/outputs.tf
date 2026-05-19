# ---------------------------------------------------------------------------
# Outputs — one rich per-cluster object that downstream pipelines (frontend
# deploy, smoke tests, pgAdmin config) can consume directly.
#
# Sensitive secrets (JWT, OAuth, SMTP, API keys) are intentionally NOT
# exposed here — they live only inside the K8s Secrets the bootstrap
# script materializes. If a downstream pipeline needs them it should read
# the K8s Secret, not the terraform state.
# ---------------------------------------------------------------------------

output "application_name" {
  description = "Logical application/product name (e.g. 'secure-vault'); echoes var.application_name so downstream pipelines don't have to know it independently."
  value       = var.application_name
}

output "cluster_names" {
  description = "Ordered list of cluster names parsed from var.cluster_names (e.g. ['dev-a','dev-b','test','stage','prod'])."
  value       = local.cluster_names
}

output "clusters" {
  description = "Per-cluster runtime info: bridge IP, container name, subdomain. `postgres` is the bridge IP:5432 — reachable from the VPS host and from any laptop on the tailnet (the VPS advertises 10.86.216.0/24 via Tailscale)."
  value = {
    for k, cluster in local.clusters_by_name : k => {
      cluster_name   = cluster.cluster_name
      container_name = lxd_instance.digital_notes[k].name
      ip             = lxd_instance.digital_notes[k].ipv4_address
      postgres_internal = "${lxd_instance.digital_notes[k].ipv4_address}:5432"
      postgres_public   = "${cluster.subdomain}:5432"
      subdomain         = cluster.subdomain
      service_urls = {
        auth  = "https://${cluster.subdomain}/auth"
        notes = "https://${cluster.subdomain}/notes"
        ai    = "https://${cluster.subdomain}/ai"
      }
    }
  }
}

output "container_ips" {
  description = "Map of cluster name → bridge IP. Convenience accessor when callers don't need the full per-cluster object."
  value       = { for k, v in lxd_instance.digital_notes : k => v.ipv4_address }
}

output "container_names" {
  description = "List of LXD container names (e.g. ['secure-vault-dev-a', 'secure-vault-dev-b', 'secure-vault-test', ...])."
  value       = [for c in lxd_instance.digital_notes : c.name]
}
