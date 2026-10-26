# Capstone 1 - The Voting App
## Local Cloud Emulation Deployment Guide

This guide covers deploying the Voting App to a local Kind (Kubernetes in Docker) cluster using Terraform, replacing the AWS EKS deployment for local development.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Local Machine                                  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Kind Cluster (voting-app)                                  │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │  │
│  │  │ vote:1   │  │ redis:1  │  │ worker:1 │  │ db:1     │   │  │
│  │  │ (5000)   │  │ (6379)   │  │          │  │ (5432)   │   │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │  │
│  │  ┌──────────┐                                              │  │
│  │  │ result:1 │                                              │  │
│  │  │ (5001)   │                                              │  │
│  │  └──────────┘                                              │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  Access: http://localhost:5000 (vote) | http://localhost:5001 (result) │
└─────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | 24+ | https://docker.com |
| Kind | 0.22+ | `go install sigs.k8s.io/kind@latest` |
| Kubectl | 1.29+ | https://kubernetes.io/docs/tasks/tools/ |
| Terraform | 1.6+ | https://terraform.io |
| Go | 1.21+ | https://go.dev |

---

## Quick Start

```bash
# Navigate to project
cd example-voting-app

# Make deploy script executable (Linux/macOS)
chmod +x deploy-local.sh

# Deploy everything (builds images, creates cluster, deploys app)
./deploy-local.sh apply

# Access the application
# Vote:  http://localhost:5000
# Result: http://localhost:5001
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

### 3. Apply All Application Resources (Terraform stage 2)

```bash
cd terraform
terraform apply
```

This provisions the namespace, quota, limit range, network policies, RBAC, secrets,
all five workloads and their Services - entirely through Terraform modules.

### 4. Verify Deployment

```bash
export KUBECONFIG="$PWD/kubeconfig-voting-app"

kubectl get nodes
kubectl get pods -n voting-app
kubectl get svc -n voting-app

# Expose the services on the host
kubectl -n voting-app port-forward svc/vote 5000:80 &
kubectl -n voting-app port-forward svc/result 5001:80 &

curl http://localhost:5000/health
curl http://localhost:5001/health
curl http://localhost:5001/api/votes
```

---

## Configuration Options

Edit `terraform/variables.tf` or pass via CLI:

```bash
# Custom replica counts
terraform apply -var='replica_counts={"vote":2,"redis":1,"worker":2,"db":1,"result":2}'

# Disable ingress
terraform apply -var='enable_ingress=false'

# Disable monitoring
terraform apply -var='enable_monitoring=false'

# Custom image tag
terraform apply -var='image_tag=v1.0.0'
```

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

## Terraform Module Structure

```
terraform/
├── main.tf                 # Root module
├── root.tf                 # Module orchestration
├── variables.tf            # Input variables
├── outputs.tf              # Outputs
├── kind-config.yaml        # Kind cluster config
├── kind-cluster/           # Kind cluster management
├── kubernetes-namespace/   # Namespace + quotas + network policies
├── secrets/                # Secrets + ServiceAccount + RBAC
├── voting-app/             # All 5 services (Deployments, Services, PVCs)
├── ingress/                # NGINX Ingress + Ingress resources
└── monitoring/             # Prometheus + Grafana + ServiceMonitors
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

# View pod logs
kubectl logs -n voting-app -l app=vote
kubectl logs -n voting-app -l app=worker

# Port forward for direct access
kubectl port-forward -n voting-app svc/vote 5000:80
kubectl port-forward -n voting-app svc/result 5001:80

# Clean up completely
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
# Destroy Terraform resources
cd terraform
terraform destroy -auto-approve

# Delete Kind cluster
kind delete cluster --name voting-app

# Remove Docker images
docker rmi voting-app-vote:local voting-app-worker:local voting-app-result:local
```

---

## Next Steps (Phase 3+)

1. **GitHub Actions CI/CD** - Build, test, scan, and deploy on push
2. **ArgoCD/Flux** - GitOps deployment to Kind
3. **Helm Charts** - Package as reusable Helm charts
4. **EKS Migration** - Swap Kind provider for AWS EKS when cloud available