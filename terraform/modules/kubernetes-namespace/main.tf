# Capstone 1 - The Voting App
# Kubernetes Namespace Module
# Creates the application namespace with labels and resource quotas

resource "kubernetes_namespace" "app" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "voting-app"
      "app.kubernetes.io/instance"   = var.namespace
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = "local"
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# Resource quota for the namespace
resource "kubernetes_resource_quota" "app" {
  metadata {
    name      = "voting-app-quota"
    namespace = var.namespace
  }
  spec {
    hard = {
      "requests.cpu"    = "2000m"
      "requests.memory" = "4Gi"
      # 6000m leaves room for rolling-update surge pods. The steady state uses
      # 3500m of container CPU limits (7 pods at the 500m LimitRange default),
      # so a 4000m ceiling would reject the two extra surge pods that vote and
      # result need for maxUnavailable: 0 rollouts.
      "limits.cpu"      = "6000m"
      "limits.memory"   = "8Gi"
      "pods"            = "20"
      "services"        = "10"
      "secrets"         = "20"
      "configmaps"      = "20"
      "persistentvolumeclaims" = "10"
    }
  }
}

# Limit range for containers
resource "kubernetes_limit_range" "app" {
  metadata {
    name      = "voting-app-limits"
    namespace = var.namespace
  }
  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "100m"
        memory = "128Mi"
      }
      max = {
        cpu    = "2"
        memory = "2Gi"
      }
    }
  }
}

# Network policy - default deny all
resource "kubernetes_network_policy" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = var.namespace
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
    # No ingress/egress rules = deny all
  }
}

# Allow DNS resolution for every pod in the namespace
resource "kubernetes_network_policy" "allow_dns" {
  metadata {
    name      = "allow-dns-egress"
    namespace = var.namespace
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
    }
  }
}

# Allow pods in this namespace to talk to each other (vote->redis, worker->db, ...)
resource "kubernetes_network_policy" "allow_same_namespace" {
  metadata {
    name      = "allow-same-namespace"
    namespace = var.namespace
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {}
      }
    }

    egress {
      to {
        pod_selector {}
      }
    }
  }
}

output "namespace_name" {
  value = kubernetes_namespace.app.metadata[0].name
}