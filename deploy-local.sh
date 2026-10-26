#!/usr/bin/env bash
# Capstone 1 - The Voting App
# Local Deployment Script - 100% Terraform driven (Kind cloud emulation)
#
# Usage: ./deploy-local.sh [apply|plan|destroy|status]
#
# Everything (cluster, namespace, secrets, workloads, services) is created by
# Terraform modules/providers. kubectl is only used for read-only validation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"
CLUSTER_NAME="${CLUSTER_NAME:-voting-app}"
KUBECONFIG_PATH="${TERRAFORM_DIR}/kubeconfig-${CLUSTER_NAME}"

# Git Bash on Windows: make locally installed terraform/kind/kubectl/docker visible
export PATH="${HOME}/bin:/c/Program Files/Docker/Docker/resources/bin:${PATH}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."
    for tool in terraform kind kubectl docker; do
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

    docker build -t voting-app-vote:local ./vote
    docker build -t voting-app-worker:local ./worker
    docker build -t voting-app-result:local ./result

    log_info "Loading images into Kind cluster '${CLUSTER_NAME}'..."
    kind load docker-image voting-app-vote:local --name "${CLUSTER_NAME}"
    kind load docker-image voting-app-worker:local --name "${CLUSTER_NAME}"
    kind load docker-image voting-app-result:local --name "${CLUSTER_NAME}"
    log_info "Images built and loaded."
}

# Stage 2: everything else (namespace, quota, RBAC, secrets, workloads, services,
# optional ingress/monitoring) is applied by the root Terraform modules.
terraform_app() {
    log_info "Stage 2/2 - Applying application resources with Terraform..."
    cd "${TERRAFORM_DIR}"
    terraform plan -out=tfplan
    terraform apply tfplan
    rm -f tfplan
}

deploy() {
    check_prerequisites
    ensure_secret_inputs
    terraform_init
    terraform_cluster
    build_images
    terraform_app
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
    log_info "Application resources in namespace '${NAMESPACE:-voting-app}':"
    kubectl get all -n "${NAMESPACE:-voting-app}"
    echo ""
    log_info "Services:"
    kubectl get svc -n "${NAMESPACE:-voting-app}"
    echo ""
    log_info "Ingresses (if enabled):"
    kubectl get ingress -n "${NAMESPACE:-voting-app}" 2>/dev/null || true
}

show_status() {
    status
    echo ""
    log_info "=== Deployment complete ==="
    echo ""
    echo "Ingress (enabled by default):"
    echo "  Vote   -> http://vote.local:30080   (or: curl -H 'Host: vote.local' http://localhost:30080)"
    echo "  Result -> http://result.local:30080 (or: curl -H 'Host: result.local' http://localhost:30080)"
    echo ""
    echo "Port-forward alternative:"
    echo "  kubectl --kubeconfig ${KUBECONFIG_PATH} -n ${NAMESPACE:-voting-app} port-forward svc/vote 5000:80"
    echo "  kubectl --kubeconfig ${KUBECONFIG_PATH} -n ${NAMESPACE:-voting-app} port-forward svc/result 5001:80"
    echo ""
    echo "Kubeconfig: ${KUBECONFIG_PATH}"
    echo "kubectl context: kind-${CLUSTER_NAME}"
}

destroy() {
    check_prerequisites
    log_warn "Destroying all Terraform-managed resources (cluster + workloads)..."
    cd "${TERRAFORM_DIR}"
    terraform destroy -auto-approve
    log_info "Destruction complete."
}

ACTION="${1:-apply}"
NAMESPACE="${NAMESPACE:-voting-app}"

case "${ACTION}" in
    apply)   deploy ;;
    plan)    plan ;;
    status)  status ;;
    destroy) destroy ;;
    *)
        log_error "Unknown action: ${ACTION}"
        echo "Usage: $0 [apply|plan|status|destroy]"
        exit 1
        ;;
esac
