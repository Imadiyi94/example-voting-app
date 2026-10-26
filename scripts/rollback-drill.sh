#!/usr/bin/env bash
# =============================================================================
# Capstone 1 - The Voting App
# Phase 5 - Rollback assurance drill
#
# Proves the Helm release can absorb a deliberately broken deployment and be
# restored to a healthy state, for the two failure classes that matter:
#
#   Drill A (manual)    : a broken rollout probe parameter makes the new pod
#                         permanently unready (readiness gate). The old pods keep
#                         serving; the operator recovers with `helm rollback`.
#   Drill B (automatic) : a broken image tag produces ImagePullBackOff.
#                         `helm upgrade --rollback-on-failure` restores the
#                         previous revision without operator action.
#
# Every step is timestamped and written to docs/phase5-rollback-proof.log, so
# the run is auditable and durations are attributable to a specific phase.
#
# Usage: ./scripts/rollback-drill.sh
# Tunables: RELEASE, NAMESPACE, CLUSTER_NAME, BROKEN_TAG, FAIL_TIMEOUT,
#           RECOVER_TIMEOUT, LOG
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${HOME}/bin:${HOME}/scoop/shims:/c/Program Files/Docker/Docker/resources/bin:${PATH}"

RELEASE="${RELEASE:-voting-app}"
NAMESPACE="${NAMESPACE:-voting-app}"
CLUSTER_NAME="${CLUSTER_NAME:-voting-app}"
BROKEN_TAG="${BROKEN_TAG:-broken-tag-does-not-exist}"
BROKEN_PROBE_PATH="${BROKEN_PROBE_PATH:-/does-not-exist}"
FAIL_TIMEOUT="${FAIL_TIMEOUT:-90s}"
RECOVER_TIMEOUT="${RECOVER_TIMEOUT:-5m}"
LOG="${LOG:-${ROOT_DIR}/docs/phase5-rollback-proof.log}"

export KUBECONFIG="${KUBECONFIG:-${ROOT_DIR}/terraform/kubeconfig-${CLUSTER_NAME}}"
export NO_COLOR=1

mkdir -p "$(dirname "${LOG}")"

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

section() {
    {
        echo ""
        echo "==============================================================================="
        echo "$1"
        echo "==============================================================================="
    } | tee -a "${LOG}"
}

step() {
    {
        echo ""
        echo "--- $1"
    } | tee -a "${LOG}"
}

# Run a command, capture stdout+stderr, its exit code and wall-clock duration.
record() {
    local description="$1"; shift
    step "${description}"
    local output status start end
    start=$(date +%s)
    echo "started  : $(utc)" | tee -a "${LOG}"
    output="$("$@" 2>&1)"
    status=$?
    end=$(date +%s)
    echo "${output}" | tee -a "${LOG}"
    echo "finished : $(utc)   (duration: $((end - start))s)" | tee -a "${LOG}"
    echo "[exit=${status}]" | tee -a "${LOG}"
    return ${status}
}

pods_state() {
    kubectl -n "${NAMESPACE}" get pods \
        -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,WAITING:.status.containerStatuses[*].state.waiting.reason,RESTARTS:.status.containerStatuses[*].restartCount' \
        2>&1
}

image_state() {
    kubectl -n "${NAMESPACE}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{.image}{end}{"\n"}{end}' 2>&1
}

wait_ready() {
    kubectl -n "${NAMESPACE}" rollout status deployment/vote --timeout="${RECOVER_TIMEOUT}" 2>&1
    kubectl -n "${NAMESPACE}" rollout status deployment/result --timeout="${RECOVER_TIMEOUT}" 2>&1
    kubectl -n "${NAMESPACE}" rollout status deployment/worker --timeout="${RECOVER_TIMEOUT}" 2>&1
    kubectl -n "${NAMESPACE}" rollout status deployment/redis --timeout="${RECOVER_TIMEOUT}" 2>&1
    kubectl -n "${NAMESPACE}" rollout status statefulset/db --timeout="${RECOVER_TIMEOUT}" 2>&1
}

app_health() {
    # Public interface check through the ingress controller
    curl -s -o /dev/null -w 'vote.local   -> HTTP %{http_code}\n' \
        -H 'Host: vote.local' http://localhost:30080/health
    curl -s -o /dev/null -w 'result.local -> HTTP %{http_code}\n' \
        -H 'Host: result.local' http://localhost:30080/health
}

# Highest revision that is actually serving traffic. A failed revision must
# never be used as rollback target.
baseline_revision() {
    helm history "${RELEASE}" -n "${NAMESPACE}" -o json 2>/dev/null | python -c '
import json, sys
releases = json.load(sys.stdin)
healthy = [r["revision"] for r in releases if r.get("status") == "deployed"]
print(max(healthy) if healthy else 1)
'
}

# =============================================================================
# 0. Pre-flight
# =============================================================================
: > "${LOG}"

section "PHASE 5 - ROLLBACK ASSURANCE EVIDENCE"
{
    echo "Generated : $(utc)"
    echo "Release   : ${RELEASE} (namespace ${NAMESPACE})"
    echo "Chart     : helm/voting-app"
    echo "Cluster   : kind-${CLUSTER_NAME}"
    echo "Helm      : $(helm version --short)"
    echo ""
    echo "Failure injection parameters:"
    echo "  probe drill : services.vote.probes.readiness.httpGet.path=${BROKEN_PROBE_PATH}"
    echo "  image drill : images.tag=${BROKEN_TAG}"
    echo "Failure timeout : ${FAIL_TIMEOUT}"
    echo "Recovery timeout: ${RECOVER_TIMEOUT}"
} | tee -a "${LOG}"

step "Baseline workload state"
pods_state | tee -a "${LOG}"

step "Baseline public interface"
app_health | tee -a "${LOG}"

BASELINE="$(baseline_revision)"
step "Baseline release revision: ${BASELINE}"
helm history "${RELEASE}" -n "${NAMESPACE}" --max 10 | tee -a "${LOG}"

step "Baseline release values (single control surface in effect)"
helm get values "${RELEASE}" -n "${NAMESPACE}" --all 2>&1 | tee -a "${LOG}"

# =============================================================================
# DRILL A - broken readiness probe parameter, manual rollback
# =============================================================================
section "DRILL A - BROKEN ROLLOUT PROBE THEN MANUAL 'helm rollback'"

step "Injecting broken probe parameter: vote readiness path ${BROKEN_PROBE_PATH}"
record "helm upgrade (expected to fail: vote never becomes Ready)" \
    helm upgrade "${RELEASE}" "${ROOT_DIR}/helm/voting-app" \
        --namespace "${NAMESPACE}" \
        --kube-context "kind-${CLUSTER_NAME}" \
        --set "services.vote.probes.readiness.httpGet.path=${BROKEN_PROBE_PATH}" \
        --wait --timeout "${FAIL_TIMEOUT}"

step "Pod status after the failed rollout"
pods_state | tee -a "${LOG}"

step "Readiness gate observed by the kubelet"
kubectl -n "${NAMESPACE}" get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp 2>&1 | tail -6 | tee -a "${LOG}"

step "Deployment rollout state (new revision not available)"
kubectl -n "${NAMESPACE}" get deployment vote result worker -o wide 2>&1 | tee -a "${LOG}"

step "Availability during the failed rollout (old pods still serving)"
app_health | tee -a "${LOG}"

step "Release history shows the failed revision"
helm history "${RELEASE}" -n "${NAMESPACE}" --max 10 | tee -a "${LOG}"

record "helm rollback to revision ${BASELINE}" \
    helm rollback "${RELEASE}" "${BASELINE}" \
        --namespace "${NAMESPACE}" \
        --kube-context "kind-${CLUSTER_NAME}" \
        --wait --timeout "${RECOVER_TIMEOUT}"

step "Workload state after rollback"
pods_state | tee -a "${LOG}"

step "Rollout confirmation"
wait_ready | tee -a "${LOG}"

step "Public interface after rollback"
app_health | tee -a "${LOG}"

step "History after rollback"
helm history "${RELEASE}" -n "${NAMESPACE}" --max 10 | tee -a "${LOG}"

# =============================================================================
# DRILL B - broken image tag, automatic rollback-on-failure
# =============================================================================
section "DRILL B - BROKEN IMAGE TAG WITH AUTOMATIC '--rollback-on-failure'"

step "Injecting broken image parameter: images.tag=${BROKEN_TAG}"
record "helm upgrade --rollback-on-failure (Helm restores the previous revision itself)" \
    helm upgrade "${RELEASE}" "${ROOT_DIR}/helm/voting-app" \
        --namespace "${NAMESPACE}" \
        --kube-context "kind-${CLUSTER_NAME}" \
        --set "images.tag=${BROKEN_TAG}" \
        --wait --timeout "${FAIL_TIMEOUT}" \
        --rollback-on-failure

step "Image pull failure reported by the cluster"
image_state | tee -a "${LOG}"

step "Helm history after the automatic rollback"
helm history "${RELEASE}" -n "${NAMESPACE}" --max 10 | tee -a "${LOG}"

step "Workload state after automatic recovery"
pods_state | tee -a "${LOG}"

step "Rollout confirmation"
wait_ready | tee -a "${LOG}"

step "Public interface after automatic recovery"
app_health | tee -a "${LOG}"

# -----------------------------------------------------------------------------
section "RESULT"
{
    echo "Final release status:"
    helm status "${RELEASE}" -n "${NAMESPACE}" | sed -n '1,6p'
    echo ""
    echo "Final pod state:"
    pods_state
    echo ""
    echo "Final public interface:"
    app_health
} | tee -a "${LOG}"
