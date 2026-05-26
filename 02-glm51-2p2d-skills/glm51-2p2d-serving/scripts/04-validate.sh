#!/bin/bash
# =============================================================================
# Step 4: Validate Serving Stack
# - Check pod status
# - Health check endpoints
# - Smoke test inference request
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Validating GLM-5.1 2P2D Serving Stack ==="

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# 1. Pod Status
echo ""
echo "--- Pod Status ---"
kubectl get pods -n "${NAMESPACE}" -o wide

PREFILL_RUNNING=$(kubectl get pods -n "${NAMESPACE}" -l app=sglang-prefill --no-headers 2>/dev/null | grep -c Running || echo 0)
DECODE_RUNNING=$(kubectl get pods -n "${NAMESPACE}" -l app=sglang-decode --no-headers 2>/dev/null | grep -c Running || echo 0)
ROUTER_RUNNING=$(kubectl get pods -n "${NAMESPACE}" -l app=sglang-router --no-headers 2>/dev/null | grep -c Running || echo 0)

echo ""
echo "  Prefill pods running: ${PREFILL_RUNNING}/${PREFILL_REPLICAS}"
echo "  Decode pods running:  ${DECODE_RUNNING}/${DECODE_REPLICAS}"
echo "  Router pods running:  ${ROUTER_RUNNING}/1"

if [ "${PREFILL_RUNNING}" -lt "${PREFILL_REPLICAS}" ] || [ "${DECODE_RUNNING}" -lt "${DECODE_REPLICAS}" ]; then
    echo ""
    echo "WARNING: Not all serving pods are running yet."
    echo "This is normal during startup (model loading + JIT warmup takes 5-20 min)."
    echo ""
    echo "Check logs:"
    echo "  kubectl logs -n ${NAMESPACE} sglang-prefill-0 -c sglang --tail=30"
    echo "  kubectl logs -n ${NAMESPACE} sglang-decode-0 -c sglang --tail=30"
    echo ""
    echo "Check DeepGEMM cache sidecar:"
    echo "  kubectl logs -n ${NAMESPACE} sglang-prefill-0 -c deepgemm-cache-sync --tail=10"
    exit 0
fi

# 2. Health Check
echo ""
echo "--- Health Check ---"

PREFILL_POD="sglang-prefill-0"
DECODE_POD="sglang-decode-0"

echo "Checking prefill health..."
PREFILL_HEALTH=$(kubectl exec -n "${NAMESPACE}" "${PREFILL_POD}" -c sglang -- \
    curl -s -o /dev/null -w "%{http_code}" http://localhost:30082/health 2>/dev/null || echo "000")
echo "  Prefill /health: HTTP ${PREFILL_HEALTH}"

echo "Checking decode health..."
DECODE_HEALTH=$(kubectl exec -n "${NAMESPACE}" "${DECODE_POD}" -c sglang -- \
    curl -s -o /dev/null -w "%{http_code}" http://localhost:30081/health 2>/dev/null || echo "000")
echo "  Decode /health: HTTP ${DECODE_HEALTH}"

if [ "${PREFILL_HEALTH}" != "200" ] || [ "${DECODE_HEALTH}" != "200" ]; then
    echo ""
    echo "WARNING: Services not fully healthy yet (still warming up)."
    echo "Wait for JIT compilation to complete and retry."
    exit 0
fi

# 3. Smoke Test via Router
echo ""
echo "--- Smoke Test ---"

ROUTER_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=sglang-router -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${ROUTER_POD}" ]; then
    echo "Sending test request via router..."
    RESPONSE=$(kubectl exec -n "${NAMESPACE}" "${ROUTER_POD}" -- \
        curl -s --max-time 60 http://localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{
            "model": "glm-5-fp8-long-pd",
            "messages": [{"role": "user", "content": "Say hello in one word."}],
            "max_tokens": 10,
            "temperature": 0
        }' 2>/dev/null || echo "TIMEOUT")

    if [ "${RESPONSE}" = "TIMEOUT" ]; then
        echo "  Request timed out (model may still be loading)"
    elif echo "${RESPONSE}" | jq -e '.choices[0].message.content' &>/dev/null; then
        ANSWER=$(echo "${RESPONSE}" | jq -r '.choices[0].message.content')
        echo "  Response: ${ANSWER}"
        echo "  SMOKE TEST PASSED"
    else
        echo "  Unexpected response: ${RESPONSE}"
    fi
else
    echo "  Router pod not found, skipping smoke test"
fi

# 4. Cache Sidecar Status
echo ""
echo "--- DeepGEMM Cache Sidecar ---"
kubectl logs -n "${NAMESPACE}" sglang-prefill-0 -c deepgemm-cache-sync --tail=5 2>/dev/null || echo "  (sidecar not yet running)"
kubectl logs -n "${NAMESPACE}" sglang-decode-0 -c deepgemm-cache-sync --tail=5 2>/dev/null || echo "  (sidecar not yet running)"

# 5. Summary
echo ""
echo "=== Validation Summary ==="
echo "  Prefill:  ${PREFILL_HEALTH:-pending}"
echo "  Decode:   ${DECODE_HEALTH:-pending}"
echo "  Router:   port 8000"
echo ""
echo "Access the service:"
echo "  kubectl port-forward -n ${NAMESPACE} svc/sglang-router 8000:8000"
echo "  curl http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\": \"glm-5-fp8-long-pd\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
