# Capstone 1 - The Voting App
# Terraform Outputs for Local Cloud Emulation

output "kubeconfig" {
  description = "Kubeconfig for the Kind cluster"
  value       = "~/.kube/config"
}

output "prometheus_endpoint" {
  description = "Local endpoint for Prometheus (if monitoring enabled)"
  value       = "http://localhost:30090"
}

output "grafana_endpoint" {
  description = "Local endpoint for Grafana (if monitoring enabled)"
  value       = "http://localhost:30300 (admin/admin)"
}

output "helm_release" {
  description = "Helm release that owns the application workloads (deployed by deploy-local.sh)"
  value       = "voting-app"
}

output "services_summary" {
  description = "Summary of deployed services and their ports"
  value = {
    vote   = { port = 5000, service = "vote",   protocol = "HTTP" }
    result = { port = 5001, service = "result", protocol = "HTTP" }
    redis  = { port = 6379, service = "redis",  protocol = "TCP" }
    db     = { port = 5432, service = "postgres", protocol = "TCP" }
  }
}