# Capstone 1 - The Voting App
## Local Cloud Emulation Deployment Guide

This guide covers deploying the Voting App to a local Kind (Kubernetes in Docker) cluster using Terraform for infrastructure and Helm for the application release, replacing the AWS EKS deployment for local development.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Local Machine                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ Kind Cluster (voting-app): 1 control-plane + 2 workers              │  │
│  │                                                                   │  │
│  │  Terraform: namespace, quota, limit range, network policies,      │  │
│  │             Secret/RBAC, NGINX ingress controller                 │  │
│  │                                                                   │  │
│  │  Helm release "voting-app"                                        │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │ vote x2  │  │ redis x1 │  │ worker   │  │ db (STS) │          │  │
│  │  │ :8080    │  │ :6379    │  │          │  │ :5432    │          │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘          │  │
│  │  ┌──────────┐   Services, ConfigMaps, PVCs, Ingress rules         │  │
│  │  │result x2 │   PDBs, startup/readiness/liveness probes           │  │
│  │  │ :8080    │                                                     │  │
│  │  └──────────┘                                                     │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  Access: http://vote.local:30080 | http://result.local:30080            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | 24+ | https://docker.com |
| Kind | 0.22+ | `go install sigs.k8s.io/kind@latest` |
| Kubectl | 1.29+ | https://kubernetes.io/docs/tasks/tools/ |
| Terraform | 1.6+ | https://terraform.io |
| Helm | 3.13+ or 4.x | https://helm.sh/docs/intro/install/ |
| Go | 1.21+ | https://go.dev |

> The rollback drill uses `helm upgrade --rollback-on-failure`, which is Helm 4
> syntax. On Helm 3 use `--atomic` instead.

---

## Quick Start

```bash
# Navigate to project
cd example-voting-app

# Make deploy script executable (Linux/macOS)
chmod +x deploy-local.sh scripts/rollback-drill.sh

# Deploy everything (builds images, creates cluster, applies infra, installs the chart)
./deploy-local.sh apply

# Access the application
# Vote:   http://vote.local:30080
# Result: http://result.local:30080

# Inspect the release and roll back if needed
./deploy-local.sh status
./deploy-local.sh history
./deploy-local.sh rollback 3
```

---

## Manual Deployment Steps

The one-command path is:

```bash
cd example-voting-app
./deploy-local.sh apply
```

If you prefer to run the individual steps (they must happen in this order):

### 1. Create the Kind Cluster (Terraform stage 1)

```bash
cd terraform
terraform init
terraform apply -target=module.kind_cluster
```

This creates the 3-node `voting-app` cluster (1 control-plane + 2 workers) and exports
`terraform/kubeconfig-voting-app`. The Kubernetes/Helm providers read that file, so the
cluster must exist before the full apply.

### 2. Build and Load Images

```bash
cd ..

docker build -t voting-app-vote:local ./vote
docker build -t voting-app-worker:local ./worker
docker build -t voting-app-result:local ./result

kind load docker-image voting-app-vote:local --name voting-app
kind load docker-image voting-app-worker:local --name voting-app
kind load docker-image voting-app-result:local --name voting-app
```

### 3. Apply Infrastructure (Terraform stage 2)

```bash
cd terraform
terraform apply
```

This provisions the namespace, quota, limit range, network policies, RBAC, the
database Secret and the NGINX ingress controller. It no longer creates
application workloads - those belong to the Helm release.

### 4. Install the Application Release (Helm)

```bash
cd ..

helm upgrade --install voting-app helm/voting-app \
  --namespace voting-app \
  --kube-context kind-voting-app \
  --set images.tag=local \
  --wait --timeout 10m
```

Everything the application needs is rendered from `helm/voting-app/values.yaml`:
five workloads, five Services, two ConfigMaps, two persistent volumes, the
Ingress rules and two PodDisruptionBudgets.

### 5. Verify Deployment

```bash
export KUBECONFIG="$PWD/terraform/kubeconfig-voting-app"

kubectl get nodes
helm status voting-app -n voting-app
kubectl get pods,svc,pvc,ingress -n voting-app

# Ingress health checks
curl -H "Host: vote.local"   http://localhost:30080/health
curl -H "Host: result.local" http://localhost:30080/health

# Or use port-forward for direct access
kubectl -n voting-app port-forward svc/vote 5000:80 &
kubectl -n voting-app port-forward svc/result 5001:80 &

curl http://localhost:5000/health
curl http://localhost:5001/api/votes
```

---

## Configuration Options

Application settings are values, not Terraform variables. Override them per
environment with `--set` or a values file:

```bash
# Scale a service
helm upgrade voting-app helm/voting-app -n voting-app \
  --reuse-values --set services.vote.replicaCount=3

# Change an image tag (all services)
helm upgrade voting-app helm/voting-app -n voting-app \
  --reuse-values --set images.tag=v1.0.0

# Point at a published registry
helm upgrade voting-app helm/voting-app -n voting-app \
  --reuse-values --set images.registry=ghcr.io/imadiyi94/example-voting-app

# Tune a probe (e.g. give vote longer to start)
helm upgrade voting-app helm/voting-app -n voting-app \
  --reuse-values --set services.vote.probes.startup.failureThreshold=60

# Resize persistent storage (new PVCs only)
helm upgrade voting-app helm/voting-app -n voting-app \
  --reuse-values --set database.persistence.size=10Gi
```

Terraform still owns infrastructure toggles:

```bash
terraform apply -var='enable_ingress=false'
terraform apply -var='enable_monitoring=false'
```

See `docs/PHASE5.md` for the full values reference.

---

## Release Management and Rollback

```bash
# Current state
helm status voting-app -n voting-app
helm history voting-app -n voting-app

# Roll back to the previous healthy revision
helm rollback voting-app -n voting-app --wait

# Roll back to a specific revision
helm rollback voting-app 3 -n voting-app --wait

# Upgrade with automatic rollback if the rollout fails (Helm 4)
helm upgrade voting-app helm/voting-app -n voting-app \
  --reuse-values --wait --rollback-on-failure
# Helm 3 equivalent: --atomic

# Prove the whole loop (broken probe + broken image, then recovery)
./scripts/rollback-drill.sh
```

The drill appends timestamped evidence to `docs/phase5-rollback-proof.log` and
leaves the release on a healthy revision.

---

## Accessing Services

| Service | Direct Port | Ingress URL (if enabled) |
|---------|-------------|--------------------------|
| Vote    | http://localhost:5000 | http://vote.local:30080 |
| Result  | http://localhost:5001 | http://result.local:30080 |
| Prometheus | - | http://localhost:30090 |
| Grafana | - | http://localhost:30300 (admin/admin) |
| Alertmanager | - | http://localhost:30093 |

> **Note**: For ingress URLs, add to `/etc/hosts`:
> ```
> 127.0.0.1 vote.local result.local
> ```

---

## Project Structure

```
terraform/
├── main.tf                 # Root module (infrastructure only)
├── variables.tf            # Input variables (incl. required db_password)
├── outputs.tf              # Endpoints + helm_release name
├── kind-config.yaml        # Kind cluster config
└── modules/
    ├── kind-cluster/       # Kind cluster management
    ├── kubernetes-namespace/   # Namespace + quota + limit range + network policies
    ├── secrets/            # Secret + ServiceAccount + RBAC
    ├── ingress/            # NGINX ingress controller (not the rules)
    └── monitoring/         # Prometheus + Grafana (optional)

helm/voting-app/
├── Chart.yaml
├── values.yaml             # single control surface for the whole app
├── files/init.sql          # DB bootstrap
└── templates/              # deployments, services, PVCs, probes, ingress, PDBs
```

---

## Useful Commands

```bash
# View Terraform plan
terraform plan

# View current state
terraform show

# Refresh state
terraform refresh

# Destroy everything
terraform destroy -auto-approve

# Check Kind cluster status
kind get clusters
kubectl get nodes

# Helm release
helm status voting-app -n voting-app
helm history voting-app -n voting-app
helm get values voting-app -n voting-app --all
helm lint helm/voting-app
helm template voting-app helm/voting-app --namespace voting-app

# View pod logs
kubectl logs -n voting-app -l app=vote
kubectl logs -n voting-app -l app=worker

# Watch a rollout
kubectl rollout status deployment/vote -n voting-app
kubectl rollout status statefulset/db -n voting-app

# Port forward for direct access
kubectl port-forward -n voting-app svc/vote 5000:80
kubectl port-forward -n voting-app svc/result 5001:80

# Clean up completely
helm uninstall voting-app -n voting-app
kind delete cluster --name voting-app
terraform destroy -auto-approve
```

---

## Troubleshooting

### Kind cluster creation fails
```bash
# Check Docker is running
docker info

# Delete and recreate
kind delete cluster --name voting-app
terraform apply
```

### Images not found in Kind
```bash
# Rebuild and reload
docker build -t voting-app-vote:local ./vote
kind load docker-image voting-app-vote:local --name voting-app
```

### Pods stuck in Pending
```bash
# Check node resources
kubectl describe nodes
kubectl describe pod <pod-name> -n voting-app

# PVC binding (a Pending pod can be waiting for storage)
kubectl get pvc -n voting-app
```

### Rollout stuck or pods in ImagePullBackOff
```bash
# Which revision is active, and did the last one fail?
helm history voting-app -n voting-app
kubectl -n voting-app get pods -o wide

# Recover to the last healthy revision
helm rollback voting-app -n voting-app --wait

# If the image tag is wrong, fix the value and upgrade again
helm upgrade voting-app helm/voting-app -n voting-app \
  --reuse-values --set images.tag=local --wait
```

### `exceeded quota: limits.cpu` during an upgrade
Surge pods are being rejected. The namespace quota must leave room for
`maxSurge` on top of steady-state limits; see the 6000m ceiling in
`terraform/modules/kubernetes-namespace/main.tf`. Check current usage with:

```bash
kubectl -n voting-app describe resourcequota voting-app-quota
```

### Port conflicts
```bash
# Check what's using ports 5000, 5001, 6443, 30080, 30090, 30300
lsof -i :5000
lsof -i :5001
```

---

## Clean Up

```bash
# Uninstall the application release first
helm uninstall voting-app -n voting-app

# Destroy Terraform resources
cd terraform
terraform destroy -auto-approve

# Delete Kind cluster
kind delete cluster --name voting-app

# Remove Docker images
docker rmi voting-app-vote:local voting-app-worker:local voting-app-result:local
```

> `./deploy-local.sh destroy` performs the uninstall and the Terraform destroy in
> the correct order.

---

## Next Steps

Phase 5 (Helm orchestration and rollback safety) is complete. Remaining
production-hardening ideas:

1. **GitOps** - ArgoCD/Flux watching `helm/voting-app` instead of a local script
2. **EKS migration** - swap the Kind module for AWS EKS with managed node groups
3. **Progressive delivery** - canary or blue/green using the same probe gates