# Phase 5 — Container Orchestration and Cluster Lifecycle Safety

Phase 5 moves every application workload out of Terraform and into a single,
parameterised Helm chart, then proves that a broken deployment can be rolled
back to a healthy state without losing application traffic.

| PRD Section 3.5 requirement | Where it is implemented |
| --- | --- |
| Single-control chart | `helm/voting-app/` — all five services rendered from `values.yaml` |
| Dedicated persistent volume for DB durability | `database.persistence` → StatefulSet `volumeClaimTemplates` (5Gi) |
| ConfigMap + Secret runtime configuration | `configmap-config.yaml`, `secrets.existingSecret` (Terraform-owned) |
| Startup / liveness / readiness probes | `services.<svc>.probes` and `database.probes` |
| CPU/memory requests and limits per container | `services.<svc>.resources` and `database.resources` |
| Validated rollback after broken parameters | `scripts/rollback-drill.sh` → `docs/phase5-rollback-proof.log` |

---

## 1. Responsibility split: Terraform vs Helm

```
┌──────────────────────────────────────────────────────────────────────────┐
│ TERRAFORM — cluster lifecycle and infrastructure guardrails               │
│                                                                          │
│  • Kind cluster (1 control-plane + 2 workers)                            │
│  • Namespace + labels (pod-security: restricted)                         │
│  • ResourceQuota + LimitRange                                            │
│  • NetworkPolicies (default-deny, DNS egress, intra-namespace)            │
│  • Secret (db_password) + ServiceAccount / Role / RoleBinding             │
│  • NGINX ingress controller (not the Ingress rules)                       │
│  • Optional kube-prometheus-stack                                         │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ HELM — the application release                                           │
│                                                                          │
│  • Deployments: vote, redis, worker, result                              │
│  • StatefulSet: db (+ volumeClaimTemplates)                              │
│  • Services: vote, redis, worker (headless), result, db                  │
│  • ConfigMap: runtime config + DB bootstrap SQL                          │
│  • PVC: redis-data                                                       │
│  • Ingress rules: vote.local, result.local                                │
│  • PodDisruptionBudgets for multi-replica services                       │
└──────────────────────────────────────────────────────────────────────────┘
```

**Why the app is not installed by a Terraform `helm_release`:** `helm rollback`
must never create Terraform drift. Terraform owns infrastructure; Helm owns the
release history. Only the ingress *controller* is installed through Terraform
(`helm_release.nginx_ingress`) because it is cluster-level infrastructure.

Resource names (`vote`, `redis`, `worker`, `db`, `result`) are deliberately
stable because service DNS names are part of the application contract.

---

## 2. Chart layout

```
helm/voting-app/
├── Chart.yaml
├── values.yaml                     # single control surface
├── .helmignore
├── files/init.sql                  # DB bootstrap, shipped inside the chart
└── templates/
    ├── _helpers.tpl                # image ref, env, probe, securityContext helpers
    ├── deployment.yaml             # loops .Values.services
    ├── service.yaml                # one Service per stateless entry
    ├── pvc.yaml                    # per-service persistent claims (redis)
    ├── statefulset-db.yaml         # Postgres + volumeClaimTemplates
    ├── service-db.yaml             # governing Service for the StatefulSet
    ├── configmap-config.yaml       # non-secret runtime configuration
    ├── configmap-db-init.yaml      # init.sql from files/
    ├── ingress.yaml
    ├── pdb.yaml
    ├── serviceaccount.yaml         # optional; off because Terraform owns identity
    └── NOTES.txt
```

No template hard-codes a service, port, probe or quota: `deployment.yaml`
iterates `.Values.services`, so adding a service is a values change, not a
template change.

### Rendering

```bash
helm lint helm/voting-app
helm template voting-app helm/voting-app --namespace voting-app
```

Expected objects: 4 Deployments, 1 StatefulSet, 5 Services, 2 ConfigMaps,
1 PVC (plus 1 StatefulSet volume claim), 1 Ingress, 2 PodDisruptionBudgets.

---

## 3. `values.yaml` reference

### Image defaults

```yaml
images:
  registry: ""          # e.g. ghcr.io/imadiyi94/example-voting-app
  tag: local            # overridden per environment
  pullPolicy: IfNotPresent
  pullSecrets: []
```

Each service may override `registry`, `tag`, `digest` and `pullPolicy`. A
`digest` renders `repo:tag@sha256:…`, preserving the Phase 2 digest pinning for
`redis` and `postgres`.

### Runtime configuration (ConfigMap)

```yaml
config:
  redisHost: redis
  redisPort: "6379"
  dbHost: db
  dbPort: "5432"
  dbName: postgres
  dbUser: postgres
```

Rendered into `voting-app-config` and consumed with `configMapKeyRef`. Service
env entries support three forms:

```yaml
env:
  - name: REDIS_HOST
    configMapKey: redisHost     # -> ConfigMap created by the chart
  - name: DB_PASSWORD
    secretKey: db_password      # -> existing Secret (Terraform-owned)
  - name: LOG_LEVEL
    value: "info"               # -> literal
```

### Secrets

The database password is **never** in the chart:

```yaml
secrets:
  existingSecret: voting-app-secrets
  passwordKey: db_password
```

Terraform creates `voting-app-secrets` from the git-ignored `terraform.tfvars`.

### Probes (dynamic rollout safety)

Each service defines all three probes, and every probe handler/threshold is a
value:

| Service | Startup | Readiness | Liveness |
| --- | --- | --- | --- |
| `vote` | `GET /health` (5s × 40) | `GET /health` | `GET /health` |
| `result` | `GET /health` (5s × 40) | `GET /health` | `GET /health` |
| `redis` | `redis-cli ping` | `redis-cli ping` | `redis-cli ping` |
| `worker` | TCP check on DB + Redis | TCP check on DB + Redis | TCP check on DB + Redis |
| `db` | `pg_isready` (5s × 60) | `pg_isready` | `pg_isready` |

Supported handlers: `httpGet`, `exec`, `tcpSocket`. Tunables:
`initialDelaySeconds`, `periodSeconds`, `timeoutSeconds`, `successThreshold`,
`failureThreshold`.

Why all three:

* **startup** gates readiness/liveness until the process is warm, so a slow boot
  is never mistaken for a crash loop;
* **readiness** removes a pod from Service endpoints during rollouts, which is
  what keeps the old ReplicaSet serving while a new one is not yet trustworthy;
* **liveness** restarts a wedged process.

### Persistence

```yaml
services:
  redis:
    persistence:
      enabled: true
      size: 1Gi
      mountPath: /data
database:
  persistence:
    enabled: true
    size: 5Gi
    mountPath: /var/lib/postgresql/data
```

* Redis: standalone PVC `redis-data` (RWO) with `strategy: Recreate`.
* Postgres: StatefulSet `volumeClaimTemplates` → `data-db-0` (5Gi), so the claim
  follows the pod identity and survives pod/Helm churn.

### Resource controls

Every container declares requests and limits:

| Service | Requests | Limits |
| --- | --- | --- |
| `vote` | 100m / 64Mi | 500m / 256Mi |
| `redis` | 50m / 64Mi | 250m / 256Mi |
| `worker` | 100m / 128Mi | 500m / 512Mi |
| `db` | 100m / 128Mi | 500m / 512Mi |
| `result` | 100m / 64Mi | 500m / 256Mi |

These are enforced again at the namespace level by the Terraform LimitRange
(`max` 2 CPU / 2Gi per container).

### Rollout strategy and availability

```yaml
services:
  vote:
    replicaCount: 2
    strategy:
      rollingUpdate:
        maxUnavailable: 0
        maxSurge: 1
podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

`maxUnavailable: 0` means a rollout never takes capacity away before a
replacement is Ready. Combined with the PDB, a node drain can evict at most one
pod at a time.

> **Quota headroom:** the namespace quota allows 6 CPU of container limits while
> steady state uses ~3.5 CPU, leaving room for the two surge pods that `vote` and
> `result` need. A 4 CPU ceiling rejects surge pods with
> `exceeded quota: limits.cpu`, which stalls legitimate rollouts — see
> `terraform/modules/kubernetes-namespace/main.tf`.

---

## 4. Rollback assurance drill

`scripts/rollback-drill.sh` produces `docs/phase5-rollback-proof.log`.

It exercises the two failure classes that matter:

| Drill | Broken parameter | Recovery |
| --- | --- | --- |
| **A** | `services.vote.probes.readiness.httpGet.path=/does-not-exist` | manual `helm rollback <rev>` |
| **B** | `images.tag=broken-tag-does-not-exist` (`ImagePullBackOff`) | automatic `--rollback-on-failure` |

Drill A is deterministic and network-independent: the new pod starts but never
passes readiness, so the Deployment cannot complete the rollout while the old
pods keep serving traffic. Drill B reproduces the classic bad-image case and
lets Helm repair itself.

### Run it

```bash
./scripts/rollback-drill.sh
```

Tunables: `RELEASE`, `NAMESPACE`, `CLUSTER_NAME`, `BROKEN_TAG`, `FAIL_TIMEOUT`,
`RECOVER_TIMEOUT`, `LOG`.

### What the log proves

For each drill the script records: the failed `helm upgrade` and its exit code,
pod status with waiting reasons, the kubelet's readiness failures, the
Deployment's rollout state, the ingress response **during** the failure, the
release history, the recovery command with wall-clock duration, rollout
confirmation, and the ingress response **after** recovery.

Two properties matter for the PRD deliverable:

1. **No outage during the failure.** Because `maxUnavailable: 0` and the old
   ReplicaSet stays Ready, `vote.local` and `result.local` return HTTP 200 while
   the broken revision is being rejected.
2. **Recovery is a first-class release event.** Every rollback appears in
   `helm history` as its own revision (`Rollback to N`), so the recovery is
   auditable and repeatable.

### Operator commands

```bash
./deploy-local.sh history
./deploy-local.sh rollback          # previous healthy revision
./deploy-local.sh rollback 3        # explicit revision
HELM_ATOMIC=true ./deploy-local.sh apply   # auto-rollback on failed upgrade
```

### Recorded result

`docs/phase5-rollback-proof.log` (Helm 4.3.1, Kind 3-node cluster) contains:

| Drill | Broken revision | Failure observed | Recovery | Final |
| --- | --- | --- | --- | --- |
| A — probe | **8** `failed` | vote readiness returns 404 for the new pod; old pods stay `2/2`; ingress HTTP 200 | `helm rollback 7` → revision **9** `deployed` (1s) | HTTP 200 |
| B — image | **10** `failed` | `ImagePullBackOff` on `voting-app-result:broken-tag-does-not-exist`; old pods stay Ready | automatic `--rollback-on-failure` → revision **11** `deployed` | HTTP 200 |

Each broken upgrade was abandoned after its 90s readiness timeout; recovery
completed in seconds. The release ended on revision **11** with 7/7 pods Ready
and both PVCs (`data-db-0` 5Gi, `redis-data` 1Gi) Bound.

### Note on local timing

On a laptop Kind cluster, a broken *image* can occasionally take much longer to
report: the kubelet may sit in `ContainerCreating` while the CRI pull call
stalls, delaying `ImagePullBackOff`. An earlier run of this drill spent ~19
minutes there before Helm's timeout fired — the rollback itself still completed
in under a minute. That run also exposed a quota interaction: surge pods were
rejected with `exceeded quota: limits.cpu` (4 CPU ceiling, 3.5 CPU steady state),
which kept the failed Deployment churning. The ceiling is now 6 CPU, and the
same drill fails within its 90s timeout. The probe drill (Drill A) is the fast,
deterministic check and the recommended CI-style gate.

---

## 5. Verifying the running release

```bash
export KUBECONFIG=terraform/kubeconfig-voting-app

helm status voting-app -n voting-app
helm history voting-app -n voting-app
kubectl -n voting-app get deploy,statefulset,pods,pvc,ingress

curl -H "Host: vote.local"   http://localhost:30080/health
curl -H "Host: result.local" http://localhost:30080/api/votes
```

End-to-end behaviour is covered by `tests/integration` (8 tests) run against
port-forwards to the Helm-deployed stack.
