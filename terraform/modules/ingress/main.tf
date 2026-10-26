# Capstone 1 - The Voting App
# Ingress Module
# Deploys NGINX Ingress Controller and Ingress resources for local access

# =========================================================================
# NGINX Ingress Controller (via Helm)
# =========================================================================

resource "helm_release" "nginx_ingress" {
  count = var.enable ? 1 : 0

  name             = "nginx-ingress"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  version          = "4.10.1"
  create_namespace = true

  values = [<<-EOT
controller:
  replicaCount: 1
  service:
    type: NodePort
    nodePorts:
      http: 30080
      https: 30443
  ingressClassResource:
    name: nginx
    default: true
    controllerValue: "k8s.io/ingress-nginx"
  admissionWebhooks:
    enabled: false
  metrics:
    enabled: true
    serviceMonitor:
      # Requires the Prometheus Operator CRDs (enable_monitoring); keep off otherwise
      enabled: false
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi
EOT
  ]

  depends_on = [kubernetes_namespace.ingress]
}

resource "kubernetes_namespace" "ingress" {
  count = var.enable ? 1 : 0
  metadata {
    name = "ingress-nginx"
  }
}

# =========================================================================
# Ingress rules for vote and result are rendered by the Helm chart
# (helm/voting-app, values.ingress). Terraform only owns the cluster-level
# controller below, so application routing rolls back with the app release.
# =========================================================================

# =========================================================================
# Outputs
# =========================================================================

output "vote_url" {
  value = var.enable ? "http://vote.local:30080" : "disabled"
}

output "result_url" {
  value = var.enable ? "http://result.local:30080" : "disabled"
}

output "ingress_nginx_service" {
  value = var.enable ? "ingress-nginx-controller (NodePort 30080/30443)" : "disabled"
}

output "hosts_hint" {
  description = "Add these entries to your hosts file to use the ingress hostnames, or send the Host header with curl"
  value       = var.enable ? "Add '127.0.0.1 vote.local result.local' to your hosts file, or: curl -H 'Host: vote.local' http://localhost:30080" : "ingress disabled"
}
