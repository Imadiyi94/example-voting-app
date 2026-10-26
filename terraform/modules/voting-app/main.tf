# Capstone 1 - The Voting App
# Voting App Module
# Deploys all 5 services: vote, redis, worker, db, result

# =========================================================================
# VOTE SERVICE
# =========================================================================

resource "kubernetes_deployment" "vote" {
  metadata {
    name      = "vote"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "vote"
      "app.kubernetes.io/instance"   = var.namespace
      "app.kubernetes.io/component"  = "frontend"
      "app.kubernetes.io/part-of"    = "voting-app"
    }
  }
  spec {
    replicas = var.replica_counts.vote
    selector {
      match_labels = {
        app = "vote"
      }
    }
    template {
      metadata {
        labels = {
          app = "vote"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8080"
          "prometheus.io/path"   = "/health"
        }
      }
      spec {
        service_account_name = "voting-app"
        security_context {
          run_as_non_root             = true
          run_as_user                 = 1000
          run_as_group                = 1000
          fs_group                    = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "vote"
          image = "${var.image_registry}${var.image_registry != "" ? "/" : ""}voting-app-vote:${var.image_tag}"
          port {
            container_port = 8080
            name           = "http"
          }
          env {
            name  = "REDIS_HOST"
            value = "redis"
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }
          resources {
            limits = {
              cpu    = var.resource_limits.vote.cpu
              memory = var.resource_limits.vote.memory
            }
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
          startup_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 5
            failure_threshold     = 40
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            run_as_non_root = true
            run_as_user     = 1000
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "vote" {
  metadata {
    name      = "vote"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "vote"
      "app.kubernetes.io/instance" = var.namespace
    }
  }
  spec {
    selector = {
      app = "vote"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# =========================================================================
# REDIS SERVICE
# =========================================================================

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "redis"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "redis"
      "app.kubernetes.io/instance"   = var.namespace
      "app.kubernetes.io/component"  = "cache"
      "app.kubernetes.io/part-of"    = "voting-app"
    }
  }
  spec {
    replicas = var.replica_counts.redis
    selector {
      match_labels = {
        app = "redis"
      }
    }
    template {
      metadata {
        labels = {
          app = "redis"
        }
      }
      spec {
        service_account_name = "voting-app"
        security_context {
          run_as_non_root = true
          run_as_user     = 999
          run_as_group    = 999
          fs_group        = 999
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "redis"
          image = "redis:7-alpine@sha256:57e4255cc971b1c8d6f8a6ca283ac01bc3ecdd914273ef6bfaede87aaecd6541"
          command = [
            "redis-server",
            "--appendonly", "yes",
            "--maxmemory", "256mb",
            "--maxmemory-policy", "allkeys-lru"
          ]
          port {
            container_port = 6379
            name           = "redis"
          }
          volume_mount {
            name       = "redis-data"
            mount_path = "/data"
          }
          resources {
            limits = {
              cpu    = var.resource_limits.redis.cpu
              memory = var.resource_limits.redis.memory
            }
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            run_as_non_root = true
            run_as_user     = 999
            run_as_group    = 999
          }
          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 5
          }
          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }
        volume {
          name = "redis-data"
          persistent_volume_claim {
            claim_name = "redis-pvc"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "redis"
      "app.kubernetes.io/instance" = var.namespace
    }
  }
  spec {
    selector = {
      app = "redis"
    }
    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# Redis PVC
resource "kubernetes_persistent_volume_claim" "redis" {
  metadata {
    name      = "redis-pvc"
    namespace = var.namespace
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
    storage_class_name = "standard"
  }
}

# =========================================================================
# WORKER SERVICE
# =========================================================================

resource "kubernetes_deployment" "worker" {
  metadata {
    name      = "worker"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "worker"
      "app.kubernetes.io/instance"   = var.namespace
      "app.kubernetes.io/component"  = "processor"
      "app.kubernetes.io/part-of"    = "voting-app"
    }
  }
  spec {
    replicas = var.replica_counts.worker
    selector {
      match_labels = {
        app = "worker"
      }
    }
    template {
      metadata {
        labels = {
          app = "worker"
        }
      }
      spec {
        service_account_name = "voting-app"
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "worker"
          image = "${var.image_registry}${var.image_registry != "" ? "/" : ""}voting-app-worker:${var.image_tag}"
          env {
            name  = "REDIS_HOST"
            value = "redis"
          }
          env {
            name  = "REDIS_PORT"
            value = "6379"
          }
          env {
            name  = "DB_HOST"
            value = "db"
          }
          env {
            name  = "DB_PORT"
            value = "5432"
          }
          env {
            name  = "DB_NAME"
            value = "postgres"
          }
          env {
            name  = "DB_USER"
            value = "postgres"
          }
          env {
            name      = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "voting-app-secrets"
                key  = "db_password"
              }
            }
          }
          resources {
            limits = {
              cpu    = var.resource_limits.worker.cpu
              memory = var.resource_limits.worker.memory
            }
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
          startup_probe {
            exec {
              command = ["sh", "-c", "nc -z redis 6379 && nc -z db 5432"]
            }
            period_seconds    = 5
            timeout_seconds   = 3
            failure_threshold = 40
          }
          liveness_probe {
            exec {
              command = ["sh", "-c", "nc -z redis 6379 && nc -z db 5432"]
            }
            initial_delay_seconds = 20
            period_seconds        = 15
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            exec {
              command = ["sh", "-c", "nc -z redis 6379 && nc -z db 5432"]
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            run_as_non_root = true
            run_as_user     = 1000
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "worker" {
  metadata {
    name      = "worker"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "worker"
      "app.kubernetes.io/instance" = var.namespace
    }
  }
  spec {
    selector = {
      app = "worker"
    }
    cluster_ip = "None"
  }
}

# =========================================================================
# DATABASE SERVICE
# =========================================================================

resource "kubernetes_stateful_set" "db" {
  metadata {
    name      = "db"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "db"
      "app.kubernetes.io/instance"   = var.namespace
      "app.kubernetes.io/component"  = "database"
      "app.kubernetes.io/part-of"    = "voting-app"
    }
  }
  spec {
    service_name = "db"
    replicas     = var.replica_counts.db
    selector {
      match_labels = {
        app = "db"
      }
    }
    template {
      metadata {
        labels = {
          app = "db"
        }
      }
      spec {
        service_account_name = "voting-app"
        security_context {
          run_as_non_root = true
          run_as_user     = 70
          run_as_group    = 70
          fs_group        = 70
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "db"
          image = "postgres:16-alpine@sha256:f4610795587492cd4fb887c2dc3de301b813278bb6f616992061141b5f15ac36"
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }
          env {
            name      = "POSTGRES_DB"
            value     = "postgres"
          }
          env {
            name      = "POSTGRES_USER"
            value     = "postgres"
          }
          env {
            name      = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "voting-app-secrets"
                key  = "db_password"
              }
            }
          }
          port {
            container_port = 5432
            name           = "postgres"
          }
          volume_mount {
            name       = "db-data"
            mount_path = "/var/lib/postgresql/data"
          }
          volume_mount {
            name       = "init-script"
            mount_path = "/docker-entrypoint-initdb.d"
          }
          resources {
            limits = {
              cpu    = var.resource_limits.db.cpu
              memory = var.resource_limits.db.memory
            }
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            run_as_non_root = true
            run_as_user     = 70
            run_as_group    = 70
          }
          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres", "-d", "postgres"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "postgres", "-d", "postgres"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
        }
        volume {
          name = "init-script"
          config_map {
            name = "db-init-script"
          }
        }
      }
    }
    volume_claim_template {
      metadata {
        name = "db-data"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = {
            storage = "5Gi"
          }
        }
        storage_class_name = "standard"
      }
    }
  }
}

resource "kubernetes_service" "db" {
  metadata {
    name      = "db"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "db"
      "app.kubernetes.io/instance" = var.namespace
    }
  }
  spec {
    selector = {
      app = "db"
    }
    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# Database init script ConfigMap
resource "kubernetes_config_map" "db_init" {
  metadata {
    name      = "db-init-script"
    namespace = var.namespace
  }
  data = {
    "init.sql" = file("${path.module}/../../../db/init.sql")
  }
}

# =========================================================================
# RESULT SERVICE
# =========================================================================

resource "kubernetes_deployment" "result" {
  metadata {
    name      = "result"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "result"
      "app.kubernetes.io/instance"   = var.namespace
      "app.kubernetes.io/component"  = "frontend"
      "app.kubernetes.io/part-of"    = "voting-app"
    }
  }
  spec {
    replicas = var.replica_counts.result
    selector {
      match_labels = {
        app = "result"
      }
    }
    template {
      metadata {
        labels = {
          app = "result"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8080"
          "prometheus.io/path"   = "/health"
        }
      }
      spec {
        service_account_name = "voting-app"
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "result"
          image = "${var.image_registry}${var.image_registry != "" ? "/" : ""}voting-app-result:${var.image_tag}"
          env {
            name  = "DB_HOST"
            value = "db"
          }
          env {
            name  = "DB_PORT"
            value = "5432"
          }
          env {
            name  = "DB_NAME"
            value = "postgres"
          }
          env {
            name  = "DB_USER"
            value = "postgres"
          }
          env {
            name      = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "voting-app-secrets"
                key  = "db_password"
              }
            }
          }
          port {
            container_port = 8080
            name           = "http"
          }
          resources {
            limits = {
              cpu    = var.resource_limits.result.cpu
              memory = var.resource_limits.result.memory
            }
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }
          startup_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 5
            failure_threshold     = 40
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
            run_as_non_root = true
            run_as_user     = 1000
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "result" {
  metadata {
    name      = "result"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "result"
      "app.kubernetes.io/instance" = var.namespace
    }
  }
  spec {
    selector = {
      app = "result"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}