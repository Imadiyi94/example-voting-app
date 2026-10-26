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

# Image tags, replica counts and resource limits are no longer Terraform
# inputs: they live in helm/voting-app/values.yaml (single control surface) and
# are overridden per environment with --set/--values at helm upgrade time.

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