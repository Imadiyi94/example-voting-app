#!/usr/bin/env bash
# Capstone 1 - The Voting App
# Local deployment driver: Terraform for infrastructure, Helm for the app.
#
# Usage: ./deploy-local.sh [apply|plan|status|rollback|history|destroy]
#          apply  - build images, provision infra, install/upgrade the Helm release
#          plan   - Terraform plan only
#          status - cluster + release + workload state
#          rollback [revision] - roll the Helm release back (default: previous)
#          history- show Helm release history
#          destroy- uninstall the release, then Terraform destroy
#
# Responsibility split (Phase 5):
#   Terraform -> Kind cluster, namespace guardrails, Secret/RBAC, ingress controller
#   Helm      -> vote, redis, worker, db, result (Deployments/StatefulSet,
#                Services, ConfigMaps, PVCs, Ingress rules)
# kubectl is only used for read-only validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
CHART_DIR="${SCRIPT_DIR}/helm/voting-app"
CLUSTER_NAME="${CLUSTER_NAME:-voting-app}"
NAMESPACE="${NAMESPACE:-voting-app}"
RELEASE_NAME="${RELEASE_NAME:-voting-app}"
IMAGE_TAG="${IMAGE_TAG:-local}"
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"
KUBECONFIG_PATH="${TERRAFORM_DIR}/kubeconfig-${CLUSTER_NAME}"

# Git Bash on Windows: make locally installed terraform/kind/kubectl/helm visible
export PATH="${HOME}/bin:${HOME}/scoop/shims:/c/Program Files/Docker/Docker/resources/bin:${PATH}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."
    for tool in terraform kind kubectl helm docker; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "$tool is not installed or not on PATH."
            exit 1
        fi
    done
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running. Start Docker Desktop and retry."
        exit 1
    fi
    log_info "Terraform: $(terraform version -json | sed -n 's/.*"terraform_version":"\([^"]*\)".*/\1/p')"
    log_info "Helm:      $(helm version --short)"
    log_info "All prerequisites met."
}

ensure_secret_inputs() {
    # Terraform requires db_password and it is never committed.
    # Prefer an existing local value, then the docker secret file, then a random one.
    local tfvars="${TERRAFORM_DIR}/terraform.tfvars"
    if [ -f "${tfvars}" ]; then
        return 0
    fi

    local pw=""
    if [ -n "${DB_PASSWORD:-}" ]; then
        pw="${DB_PASSWORD}"
    elif [ -f "${SCRIPT_DIR}/secrets/db_password.txt" ]; then
        pw="$(tr -d '\r\n' < "${SCRIPT_DIR}/secrets/db_password.txt")"
    else
        pw="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    fi

    printf 'db_password = "%s"\n' "${pw}" > "${tfvars}"
    log_warn "Created ${tfvars} with a local-only database password (git-ignored)."
}

terraform_init() {
    log_info "Initializing Terraform..."
    cd "${TERRAFORM_DIR}"
    terraform init -upgrade
}

# Stage 1: create the Kind cluster so the kubeconfig exists before the
# Kubernetes/Helm providers are configured.
terraform_cluster() {
    log_info "Stage 1/2 - Provisioning multi-node Kind cluster with Terraform..."
    cd "${TERRAFORM_DIR}"
    terraform apply -auto-approve -target=module.kind_cluster
    export KUBECONFIG="${KUBECONFIG_PATH}"
}

build_images() {
    log_info "Building application images locally..."
    cd "${SCRIPT_DIR}"

    docker build -t "voting-app-vote:${IMAGE_TAG}" ./vote
    docker build -t "voting-app-worker:${IMAGE_TAG}" ./worker
    docker build -t "voting-app-result:${IMAGE_TAG}" ./result

    log_info "Loading images into Kind cluster '${CLUSTER_NAME}'..."
    kind load docker-image "voting-app-vote:${IMAGE_TAG}" --name "${CLUSTER_NAME}"
    kind load docker-image "voting-app-worker:${IMAGE_TAG}" --name "${CLUSTER_NAME}"
    kind load docker-image "voting-app-result:${IMAGE_TAG}" --name "${CLUSTER_NAME}"
    log_info "Images built and loaded."
}

# Stage 2: infrastructure concerns only - namespace, quotas, network policies,
# Secret, ServiceAccount/RBAC and the ingress controller.
terraform_infra() {
    log_info "Stage 2/2 - Applying infrastructure (namespace, secrets, RBAC, ingress controller)..."
    cd "${TERRAFORM_DIR}"
    terraform plan -out=tfplan
    terraform apply tfplan
    rm -f tfplan
}

# Application layer: one Helm release renders every workload in the chart.
helm_deploy() {
    log_info "Deploying application with Helm (release '${RELEASE_NAME}')..."
    export KUBECONFIG="${KUBECONFIG_PATH}"

    local atomic_flag=()
    if [ "${HELM_ATOMIC:-false}" = "true" ]; then
        atomic_flag=(--rollback-on-failure)
        log_warn "HELM_ATOMIC=true - a failed rollout will roll back automatically."
    fi

    helm upgrade --install "${RELEASE_NAME}" "${CHART_DIR}" \
        --namespace "${NAMESPACE}" \
        --kube-context "kind-${CLUSTER_NAME}" \
        --set "images.tag=${IMAGE_TAG}" \
        --wait \
        --timeout "${HELM_TIMEOUT}" \
        "${atomic_flag[@]}"

    log_info "Helm release '${RELEASE_NAME}' is deployed and healthy."
}

deploy() {
    check_prerequisites
    ensure_secret_inputs
    terraform_init
    terraform_cluster
    build_images
    terraform_infra
    helm_deploy
    show_status
}

plan() {
    check_prerequisites
    ensure_secret_inputs
    terraform_init
    cd "${TERRAFORM_DIR}"
    terraform plan
}

status() {
    export KUBECONFIG="${KUBECONFIG_PATH}"
    log_info "Cluster nodes:"
    kubectl get nodes -o wide
    echo ""
    log_info "Helm release:"
    helm status "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null || log_warn "Release '${RELEASE_NAME}' not installed."
    echo ""
    log_info "Application resources in namespace '${NAMESPACE}':"
    kubectl get all -n "${NAMESPACE}"
    echo ""
    log_info "Persistent volume claims:"
    kubectl get pvc -n "${NAMESPACE}"
    echo ""
    log_info "Ingress:"
    kubectl get ingress -n "${NAMESPACE}" 2>/dev/null || true
}

show_status() {
    status
    echo ""
    log_info "=== Deployment complete ==="
    echo ""
    echo "Ingress:"
    echo "  Vote   -> http://vote.local:30080   (or: curl -H 'Host: vote.local' http://localhost:30080)"
    echo "  Result -> http://result.local:30080 (or: curl -H 'Host: result.local' http://localhost:30080)"
    echo ""
    echo "Rollback:"
    echo "  ./deploy-local.sh history"
    echo "  ./deploy-local.sh rollback [revision]"
    echo ""
    echo "Kubeconfig: ${KUBECONFIG_PATH}"
    echo "kubectl context: kind-${CLUSTER_NAME}"
}

rollback() {
    export KUBECONFIG="${KUBECONFIG_PATH}"
    local revision="${1:-0}"
    log_warn "Rolling back '${RELEASE_NAME}' to revision ${revision} (0 = previous)..."
    helm rollback "${RELEASE_NAME}" "${revision}" \
        --namespace "${NAMESPACE}" \
        --kube-context "kind-${CLUSTER_NAME}" \
        --wait \
        --timeout "${HELM_TIMEOUT}"
    helm status "${RELEASE_NAME}" -n "${NAMESPACE}"
}

history() {
    export KUBECONFIG="${KUBECONFIG_PATH}"
    helm history "${RELEASE_NAME}" -n "${NAMESPACE}" --max 20
}

destroy() {
    check_prerequisites
    export KUBECONFIG="${KUBECONFIG_PATH}"
    if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        log_warn "Uninstalling Helm release '${RELEASE_NAME}'..."
        helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait || true
    fi
    log_warn "Destroying all Terraform-managed infrastructure..."
    cd "${TERRAFORM_DIR}"
    terraform destroy -auto-approve
    log_info "Destruction complete."
}

ACTION="${1:-apply}"
shift || true

case "${ACTION}" in
    apply)    deploy ;;
    plan)     plan ;;
    status)   status ;;
    rollback) rollback "${1:-0}" ;;
    history)  history ;;
    destroy)  destroy ;;
    *)
        log_error "Unknown action: ${ACTION}"
        echo "Usage: $0 [apply|plan|status|rollback [revision]|history|destroy]"
        exit 1
        ;;
esac
