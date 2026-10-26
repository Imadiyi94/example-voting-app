# Capstone 1 - The Voting App
# Ingress Module Variables

variable "enable" {
  description = "Enable NGINX Ingress Controller"
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "voting-app"
}