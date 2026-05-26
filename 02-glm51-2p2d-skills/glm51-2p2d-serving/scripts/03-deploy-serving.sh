#!/bin/bash
# =============================================================================
# Step 3: Deploy GLM-5.1 2P2D Serving Stack
# - Prefill StatefulSet (PP=2, TP=8, DeepEP normal, NSA, nixl LIBFABRIC)
# - Decode StatefulSet (TP=16, DP=16, DeepEP low_latency, EAGLE)
# - DeepGEMM cache sidecar (S3 sync every 5 min)
# - PD Router (sglang_router mini-lb)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Deploying GLM-5.1 2P2D Serving Stack ==="

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# Create namespace
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Substitute placeholders in manifests and apply
echo ""
echo "Applying manifests (substituting image + bucket placeholders)..."

MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
RENDERED_DIR="/tmp/glm51-rendered-$$"
mkdir -p "${RENDERED_DIR}"

for f in "${MANIFESTS_DIR}"/*.yaml; do
    sed \
        -e "s|SGLANG_IMAGE_PLACEHOLDER|${SGLANG_IMAGE}|g" \
        -e "s|S3_BUCKET_PLACEHOLDER|${S3_BUCKET}|g" \
        -e "s|AWS_REGION_PLACEHOLDER|${AWS_REGION}|g" \
        "$f" > "${RENDERED_DIR}/$(basename $f)"
done

kubectl apply -f "${RENDERED_DIR}/"
rm -rf "${RENDERED_DIR}"

echo ""
echo "Waiting for pods to be scheduled..."
sleep 10

echo ""
echo "--- Pod Status ---"
kubectl get pods -n "${NAMESPACE}" -o wide

echo ""
echo "=== Serving Stack Deployed ==="
echo ""
echo "Startup timeline:"
echo "  - Prefill pods: loading model + JIT warmup (~5-15 min depending on cache)"
echo "  - Decode pods:  loading model + JIT warmup (~5-15 min depending on cache)"
echo "  - Router: ready immediately after prefill/decode endpoints are up"
echo ""
echo "Monitor progress:"
echo "  kubectl logs -n ${NAMESPACE} -l app=sglang-prefill -f --tail=20"
echo "  kubectl logs -n ${NAMESPACE} -l app=sglang-decode -f --tail=20"
echo ""
echo "Next: ./04-validate.sh (run after pods are Ready)"
