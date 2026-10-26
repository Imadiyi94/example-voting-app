# Capstone 1 - The Voting App
# Monitoring Module Variables

variable "enable" {
  description = "Enable Prometheus/Grafana monitoring stack"
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Kubernetes namespace for the application"
  type        = string
  default     = "voting-app"
}