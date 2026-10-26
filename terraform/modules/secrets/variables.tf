# Capstone 1 - The Voting App
# Secrets Module Variables

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "voting-app"
}

variable "db_password" {
  description = "PostgreSQL password supplied by the root module (never committed)"
  type        = string
  sensitive   = true
}