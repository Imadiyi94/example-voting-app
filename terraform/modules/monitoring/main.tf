# Capstone 1 - The Voting App
# Monitoring Module
# Deploys Prometheus, Grafana, and ServiceMonitors for local observability

# =========================================================================
# Prometheus Stack (via Helm - kube-prometheus-stack)
# =========================================================================

resource "helm_release" "prometheus_stack" {
  count = var.enable ? 1 : 0

  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  version    = "55.5.0"
  create_namespace = true

  values = [<<-EOT
prometheus:
  prometheusSpec:
    replicaCount: 1
    retention: 24h
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: standard
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
    resources:
      limits:
        cpu: 1000m
        memory: 1Gi
      requests:
        cpu: 200m
        memory: 512Mi
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector:
      matchLabels:
        release: prometheus

alertmanager:
  alertmanagerSpec:
    replicaCount: 1
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: standard
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 1Gi

grafana:
  enabled: true
  adminPassword: "admin"
  persistence:
    enabled: true
    size: 2Gi
    storageClassName: standard
  service:
    type: NodePort
    nodePort: 30300
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://prometheus-operated.monitoring.svc:9090
          access: proxy
          isDefault: true
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: 'Default'
          orgId: 1
          folder: ''
          type: file
          disableDeletion: false
          updateIntervalSeconds: 10
          allowUiUpdates: true
          options:
            path: /var/lib/grafana/dashboards/default
  dashboards:
    default:
      voting-app-dashboard:
        json: |
          {
            "dashboard": {
              "title": "Voting App Dashboard",
              "tags": ["voting-app"],
              "timezone": "browser",
              "panels": [
                {
                  "id": 1,
                  "title": "Vote Service Request Rate",
                  "type": "graph",
                  "targets": [
                    {
                      "expr": "rate(http_requests_total{job=\"vote\",namespace=\"voting-app\"}[5m])",
                      "legendFormat": "{{method}} {{handler}}"
                    }
                  ]
                },
                {
                  "id": 2,
                  "title": "Result Service Request Rate",
                  "type": "graph",
                  "targets": [
                    {
                      "expr": "rate(http_requests_total{job=\"result\",namespace=\"voting-app\"}[5m])",
                      "legendFormat": "{{method}} {{handler}}"
                    }
                  ]
                },
                {
                  "id": 3,
                  "title": "Vote Counts",
                  "type": "stat",
                  "targets": [
                    {
                      "expr": "sum by (vote) (votes_total{namespace=\"voting-app\"})",
                      "legendFormat": "{{vote}}"
                    }
                  ]
                },
                {
                  "id": 4,
                  "title": "Redis Memory Usage",
                  "type": "graph",
                  "targets": [
                    {
                      "expr": "redis_memory_used_bytes{namespace=\"voting-app\"}",
                      "legendFormat": "Used"
                    },
                    {
                      "expr": "redis_memory_max_bytes{namespace=\"voting-app\"}",
                      "legendFormat": "Max"
                    }
                  ]
                }
              ],
              "time": {
                "from": "now-1h",
                "to": "now"
              },
              "refresh": "10s"
            },
            "overwrite": true
          }
EOT
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

resource "kubernetes_namespace" "monitoring" {
  count = var.enable ? 1 : 0
  metadata {
    name = "monitoring"
  }
}

# =========================================================================
# ServiceMonitors for Vote and Result Services
# =========================================================================

resource "kubernetes_manifest" "vote_servicemonitor" {
  count = var.enable ? 1 : 0

  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "vote-servicemonitor"
      namespace = var.namespace
      labels = {
        release = "prometheus"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          app = "vote"
        }
      }
      endpoints = [
        {
          port     = "http"
          path     = "/metrics"
          interval = "30s"
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "result_servicemonitor" {
  count = var.enable ? 1 : 0

  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "result-servicemonitor"
      namespace = var.namespace
      labels = {
        release = "prometheus"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          app = "result"
        }
      }
      endpoints = [
        {
          port     = "http"
          path     = "/metrics"
          interval = "30s"
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "redis_servicemonitor" {
  count = var.enable ? 1 : 0

  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "redis-servicemonitor"
      namespace = var.namespace
      labels = {
        release = "prometheus"
      }
    }
    spec = {
      selector = {
        matchLabels = {
          app = "redis"
        }
      }
      endpoints = [
        {
          port     = "redis"
          path     = "/metrics"
          interval = "30s"
        }
      ]
    }
  }
}

output "prometheus_url" {
  value = var.enable ? "http://localhost:30090" : "disabled"
}

output "grafana_url" {
  value = var.enable ? "http://localhost:30300 (admin/admin)" : "disabled"
}

output "alertmanager_url" {
  value = var.enable ? "http://localhost:30093" : "disabled"
}