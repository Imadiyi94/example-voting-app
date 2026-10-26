# The Voting App — Capstone 1 (Ship It)

A five-service microservices application migrated from a local Docker Compose stack to a
Terraform-provisioned Kubernetes environment, with a GitHub Actions CI/CD pipeline that
tests, scans, builds, and publishes hardened container images. Workloads are delivered as
a single parameterised **Helm** release, so a failed rollout can be rolled back cleanly.

> Upstream reference: [dockersamples/example-voting-app](https://github.com/dockersamples/example-voting-app)

---

## Architecture

```
            +--------+      +---------+      +----------+      +------------+      +----------+
  users --> |  vote  | ---> |  redis  | ---> |  worker  | ---> |     db     | ---> |  result  |
            | Flask  |      |  queue  |      | .NET 8   |      | PostgreSQL |      | Node SSE |
            +--------+      +---------+      +----------+      +------------+      +----------+
              :8080            :6379            (no port)          :5432              :8080
```

| Service | Runtime | Internal port | Responsibility |
| --- | --- | --- | --- |
| `vote` | Python 3.12 / Flask + gunicorn | 8080 | Accepts votes, pushes them to Redis |
| `redis` | Redis 7 Alpine | 6379 | Durable in-memory vote queue |
| `worker` | .NET 8 | — | Polls Redis, writes tallies to PostgreSQL |
| `db` | PostgreSQL 16 Alpine | 5432 | Persistent vote storage |
| `result` | Node.js 20 / Express | 8080 | Reads tallies, streams updates via SSE |

Data path: **vote → redis → worker → postgres → result**

All application containers run as **non-root**, drop **ALL** Linux capabilities,
run with **no-new-privileges**, and build from **SHA256-pinned** base images.

---

## Repository layout

```
.
├── .github/workflows/ci-cd.yaml   # Phase 4/5 pipeline (tests, Trivy, Helm lint, GHCR publish)
├── docker-compose.yml             # Phase 1 local multi-container stack
├── vote/                          # Flask front end + Dockerfile
├── worker/                        # .NET 8 worker + Dockerfile
├── result/                        # Node.js results front end + Dockerfile
├── db/init.sql                    # Database bootstrap
├── helm/voting-app/               # Phase 5 chart: all five workloads from values.yaml
│   ├── values.yaml                #   single control surface
│   ├── files/init.sql             #   DB bootstrap shipped with the chart
│   └── templates/                 #   deployments, services, PVCs, probes, ingress
├── secrets/                       # db_password.example.txt (real secret is git-ignored)
├── scripts/rollback-drill.sh      # Phase 5 rollback assurance drill
├── docs/phase5-rollback-proof.log #   recorded evidence of the drill
├── docs/PHASE5.md                 # Phase 5 chart reference and rollback runbook
├── tests/integration/             # End-to-end pytest suite
├── terraform/                     # Phase 3 infrastructure as code
│   ├── main.tf                    # Root module wiring
│   ├── variables.tf               # Inputs (db_password has no committed value)
│   ├── kind-config.yaml           # 3-node local cluster (1 control-plane + 2 workers)
│   └── modules/
│       ├── kind-cluster/
│       ├── kubernetes-namespace/  # Namespace, quota, limit range, network policies
│       ├── secrets/               # Secret, ServiceAccount, Role, RoleBinding
│       ├── ingress/               # NGINX ingress controller (rules live in Helm)
│       └── monitoring/            # kube-prometheus-stack (optional)
├── deploy-local.sh                # Terraform infrastructure + Helm application driver
├── LOCAL_DEPLOYMENT.md            # Detailed local runbook
└── README.local.md                # Phase-by-phase notes
```

---

## Quick start (local Kubernetes via Kind)

Prerequisites: Docker Desktop, Terraform ≥ 1.6, Kind, kubectl, Helm 3.13+/4.x.

```bash
cd example-voting-app
./deploy-local.sh apply
```

This runs two layers:

1. **Terraform** creates the 3-node Kind cluster (exporting
   `terraform/kubeconfig-voting-app`), then the namespace, quota, limit range,
   network policies, the database Secret, RBAC, and the NGINX ingress controller.
2. **Helm** installs/upgrades the `voting-app` release from `helm/voting-app`,
   which builds `vote`, `worker`, `result` images, loads them into Kind, and
   renders the workloads, Services, ConfigMaps, PVCs and Ingress rules.

Access:

```bash
curl -H "Host: vote.local"   http://localhost:30080/health
curl -H "Host: result.local" http://localhost:30080/api/votes
```

Roll back or inspect the release:

```bash
./deploy-local.sh history
./deploy-local.sh rollback 3
```

Tear down with `./deploy-local.sh destroy` (uninstalls the release, then destroys
the infrastructure).

### Orchestration and rollout safety

Every workload is driven by `helm/voting-app/values.yaml`: images, replicas,
runtime config, startup/readiness/liveness probes, resource requests and limits,
persistent volumes, and rollout strategy. Rollbacks are proven by
`scripts/rollback-drill.sh`, which records a broken probe deployment and a broken
image tag, then verifies recovery — see
[`docs/PHASE5.md`](docs/PHASE5.md) and
[`docs/phase5-rollback-proof.log`](docs/phase5-rollback-proof.log).

### Docker Compose (development)

```bash
cp secrets/db_password.example.txt secrets/db_password.txt
docker compose up -d --build
curl http://localhost:5000/health
curl http://localhost:5001/health
```

---

## CI/CD pipeline (PRD Section 3.4)

`.github/workflows/ci-cd.yaml` runs on pushes to `main`/`develop` and pull requests
targeting `main`.

| Task | Job | What it does |
| --- | --- | --- |
| **A** | `test` | Validates each service, boots the full Compose stack, runs the end-to-end pytest suite (`tests/integration`) |
| **B** | `security` | Trivy filesystem scan (vuln/secret/misconfig → SARIF) plus image scans; fails on **CRITICAL** fixable vulnerabilities |
| **C** | `publish` | Authenticates to **GHCR** with `GITHUB_TOKEN` — no stored registry password |
| **D** | `publish` | Builds and pushes production images tagged `sha-<short7>`, branch name, and `latest` on the default branch |
| — | `infrastructure` | `terraform init -backend=false` + `terraform validate` for all modules |
| — | `helm` | `helm lint --strict` + `helm template`; asserts every expected object type renders, probes/resource controls exist, and no secret value leaks into the chart |

The `helm` job gates `publish`: a chart that cannot render never produces release
images.

**Secrets:** the only inputs are GitHub encrypted secrets (`DB_PASSWORD`, `GITHUB_TOKEN`).
No password is committed: `secrets/db_password.txt` and `terraform/terraform.tfvars`
are git-ignored, and `terraform/variables.tf` no longer ships a default password.

Published images:

```
ghcr.io/imadiyi94/example-voting-app/vote:sha-<short7>
ghcr.io/imadiyi94/example-voting-app/worker:sha-<short7>
ghcr.io/imadiyi94/example-voting-app/result:sha-<short7>
```

---

## Branch model

| Branch | Purpose |
| --- | --- |
| `main` | Production line; receives merges only, publishes `latest` images |
| `develop` | Integration line for ongoing work |
| `feature/*` | Short-lived work branches, merged into `develop` via pull request |
