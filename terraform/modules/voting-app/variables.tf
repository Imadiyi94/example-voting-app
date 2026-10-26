# Capstone 1 - The Voting App
# Voting App Module Variables

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "voting-app"
}

variable "image_registry" {
  description = "Docker registry (empty for local images)"
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Docker image tag"
  type        = string
  default     = "local"
}

variable "replica_counts" {
  description = "Replica counts for each service"
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
  description = "Resource limits for each service"
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