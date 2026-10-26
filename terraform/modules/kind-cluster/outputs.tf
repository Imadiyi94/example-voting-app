# Capstone 1 - The Voting App
# Kind Cluster Module Outputs

output "kubeconfig_path" {
  description = "Path to the exported kubeconfig file"
  value       = var.kubeconfig_output
}

output "cluster_name" {
  description = "Name of the Kind cluster"
  value       = var.cluster_name
}
