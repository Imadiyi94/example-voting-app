# Capstone 1 - The Voting App
# Kind Cluster Module Variables

variable "cluster_name" {
  description = "Name of the Kind cluster"
  type        = string
  default     = "voting-app"
}

variable "config_path" {
  description = "Path to Kind cluster config file"
  type        = string
  default     = "./kind-config.yaml"
}

variable "create_cluster" {
  description = "Whether to create the Kind cluster"
  type        = bool
  default     = true
}

variable "kubeconfig_output" {
  description = "Absolute path where the cluster kubeconfig should be written"
  type        = string
}