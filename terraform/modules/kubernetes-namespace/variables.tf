# Capstone 1 - The Voting App
# Kubernetes Namespace Module Variables

variable "namespace" {
  description = "Kubernetes namespace name"
  type        = string
  default     = "voting-app"
}