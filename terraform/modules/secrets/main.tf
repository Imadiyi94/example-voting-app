# Capstone 1 - The Voting App
# Secrets Module
# Creates Kubernetes secrets for the application

resource "kubernetes_secret" "app_secrets" {
  metadata {
    name      = "voting-app-secrets"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "voting-app-secrets"
      "app.kubernetes.io/instance" = var.namespace
    }
  }
  data = {
    "db_password" = var.db_password
  }
  type = "Opaque"
}

# Service account for the application
resource "kubernetes_service_account" "app" {
  metadata {
    name      = "voting-app"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "voting-app"
      "app.kubernetes.io/instance"   = var.namespace
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
  automount_service_account_token = true
}

# Role for the service account
resource "kubernetes_role" "app" {
  metadata {
    name      = "voting-app-role"
    namespace = var.namespace
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "secrets", "persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "replicasets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

# Role binding
resource "kubernetes_role_binding" "app" {
  metadata {
    name      = "voting-app-role-binding"
    namespace = var.namespace
  }
  subject {
    kind      = "ServiceAccount"
    name      = "voting-app"
    namespace = var.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = "voting-app-role"
  }
}

output "secret_name" {
  value = kubernetes_secret.app_secrets.metadata[0].name
}

output "service_account_name" {
  value = kubernetes_service_account.app.metadata[0].name
}