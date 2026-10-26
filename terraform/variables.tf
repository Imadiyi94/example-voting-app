# Capstone 1 - The Voting App
# Terraform Variables for Local Cloud Emulation
# All values optimized for Kind cluster on local machine

variable "kube_context" {
  description = "Kubernetes context to use (should point to Kind cluster)"
  type        = string
  default     = "kind-voting-app"
}

variable "cluster_name" {
  description = "Name of the Kind cluster"
  type        = string
  default     = "voting-app"
}

variable "namespace" {
  description = "Kubernetes namespace for the application"
  type        = string
  default     = "voting-app"
}

variable "image_tag" {
  description = "Docker image tag for all services"
  type        = string
  default     = "local"
}

variable "image_registry" {
  description = "Docker registry (empty for local images)"
  type        = string
  default     = ""
}

variable "replica_counts" {
  description = "Replica counts for each service (dev-sized)"
  type = object({
    vote   = number
    redis  = number
    worker = number
    db     = number
    result = number
  })
  default = {
    vote   = 1
    redis  = 1
    worker = 1
    db     = 1
    result = 1
  }
}

variable "resource_limits" {
  description = "Resource limits for each service (dev-sized)"
  type = object({
    vote = object({
      cpu    = string
      memory = string
    })
    redis = object({
      cpu    = string
      memory = string
    })
    worker = object({
      cpu    = string
      memory = string
    })
    db = object({
      cpu    = string
      memory = string
    })
    result = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    vote = {
      cpu    = "500m"
      memory = "256Mi"
    }
    redis = {
      cpu    = "250m"
      memory = "256Mi"
    }
    worker = {
      cpu    = "500m"
      memory = "512Mi"
    }
    db = {
      cpu    = "500m"
      memory = "512Mi"
    }
    result = {
      cpu    = "500m"
      memory = "256Mi"
    }
  }
}

variable "db_password" {
  description = "PostgreSQL password. Supply via terraform.tfvars (git-ignored) or TF_VAR_db_password; never commit it."
  type        = string
  sensitive   = true
}

variable "enable_ingress" {
  description = "Enable NGINX ingress controller for local access on NodePort 30080"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Enable Prometheus/Grafana monitoring stack"
  type        = bool
  default     = false
}

variable "kind_config_path" {
  description = "Path to Kind cluster config file"
  type        = string
  default     = "./kind-config.yaml"
}

variable "create_kind_cluster" {
  description = "Whether to create Kind cluster via null_resource"
  type        = bool
  default     = true
}