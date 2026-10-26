# Capstone 1 - The Voting App
# Root Terraform configuration
# Provisions the local multi-node Kind cluster and ALL application resources
# (namespace, secrets, workloads, services) exclusively through Terraform modules.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }

  backend "local" {
    path = "./terraform.tfstate"
  }
}

# =========================================================================
# Providers
# The kubeconfig is exported by the kind-cluster module into this directory.
# =========================================================================

provider "kubernetes" {
  config_path    = "${abspath(path.root)}/kubeconfig-${var.cluster_name}"
  config_context = "kind-${var.cluster_name}"
}

provider "helm" {
  kubernetes {
    config_path    = "${abspath(path.root)}/kubeconfig-${var.cluster_name}"
    config_context = "kind-${var.cluster_name}"
  }
}

# =========================================================================
# MODULE: Kind Cluster (1 control-plane + 2 workers)
# =========================================================================

module "kind_cluster" {
  source            = "./modules/kind-cluster"
  cluster_name      = var.cluster_name
  config_path       = var.kind_config_path
  create_cluster    = var.create_kind_cluster
  kubeconfig_output = "${abspath(path.root)}/kubeconfig-${var.cluster_name}"
}

# =========================================================================
# MODULE: Namespace, quota, limit range and default-deny network policy
# =========================================================================

module "kubernetes_namespace" {
  source     = "./modules/kubernetes-namespace"
  namespace  = var.namespace
  depends_on = [module.kind_cluster]
}

# =========================================================================
# MODULE: Secrets + ServiceAccount + RBAC
# =========================================================================

module "secrets" {
  source      = "./modules/secrets"
  namespace   = var.namespace
  db_password = var.db_password
  depends_on  = [module.kubernetes_namespace]
}

# =========================================================================
# MODULE: Voting App workloads (vote, redis, worker, db, result)
# =========================================================================

module "voting_app" {
  source          = "./modules/voting-app"
  namespace       = var.namespace
  image_registry  = var.image_registry
  image_tag       = var.image_tag
  replica_counts  = var.replica_counts
  resource_limits = var.resource_limits
  depends_on      = [module.secrets]
}

# =========================================================================
# MODULE: Ingress (optional)
# =========================================================================

module "ingress" {
  source     = "./modules/ingress"
  enable     = var.enable_ingress
  namespace  = var.namespace
  depends_on = [module.voting_app]
}

# =========================================================================
# MODULE: Monitoring - kube-prometheus-stack (optional)
# =========================================================================

module "monitoring" {
  source     = "./modules/monitoring"
  enable     = var.enable_monitoring
  namespace  = var.namespace
  depends_on = [module.voting_app]
}

# =========================================================================
# Outputs (endpoints and local access)
# =========================================================================

output "cluster_name" {
  description = "Kind cluster name"
  value       = var.cluster_name
}

output "kube_context" {
  description = "kubectl context for the local cluster"
  value       = "kind-${var.cluster_name}"
}

output "kubeconfig_path" {
  description = "Kubeconfig exported by Terraform"
  value       = module.kind_cluster.kubeconfig_path
}

output "api_server_endpoint" {
  description = "Local Kubernetes API endpoint"
  value       = "https://127.0.0.1:6443"
}

output "namespace" {
  description = "Application namespace"
  value       = var.namespace
}

output "vote_endpoint" {
  description = "Vote service access URL"
  value       = var.enable_ingress ? "http://vote.local:30080" : "http://localhost:5000"
}

output "result_endpoint" {
  description = "Result service access URL"
  value       = var.enable_ingress ? "http://result.local:30080" : "http://localhost:5001"
}
