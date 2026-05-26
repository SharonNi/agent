#!/bin/bash
# =============================================================================
# Step 6: Validate Cluster Health
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Cluster Validation ==="

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# 1. Cluster status
echo ""
echo "--- Cluster Status ---"
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' --output table

# 2. Node status
echo ""
echo "--- All Nodes ---"
kubectl get nodes -o wide

# 3. GPU resources
echo ""
echo "--- GPU Node Resources ---"
kubectl get nodes -l "node.kubernetes.io/instance-type=${GPU_INSTANCE_TYPE}" \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,GPU:.status.allocatable.nvidia\.com/gpu,EFA:.status.allocatable.vpc\.amazonaws\.com/efa,MEMORY:.status.allocatable.memory'

# 4. System pods
echo ""
echo "--- System Pods ---"
kubectl get pods -n kube-system --no-headers | awk '{print $1, $3}' | column -t

# 5. NVMe mount check (on first GPU node)
echo ""
echo "--- NVMe Mount Check ---"
GPU_NODE=$(kubectl get nodes -l "node.kubernetes.io/instance-type=${GPU_INSTANCE_TYPE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${GPU_NODE}" ]; then
    echo "Checking ${GPU_LVM_MOUNT} on ${GPU_NODE}..."
    kubectl debug node/"${GPU_NODE}" -it --image=busybox -- \
        sh -c "df -h /host${GPU_LVM_MOUNT} 2>/dev/null && echo 'NVMe OK' || echo 'NVMe NOT mounted'" \
        2>/dev/null || echo "  (debug pod requires permissions, check manually with SSM)"
else
    echo "  No GPU nodes found yet."
fi

# 6. Device plugin status
echo ""
echo "--- Device Plugin DaemonSets ---"
kubectl get daemonset -n kube-system -l 'name in (nvidia-device-plugin-ds, aws-efa-k8s-device-plugin)' \
    2>/dev/null || kubectl get daemonset -n kube-system

# Summary
echo ""
echo "=== Validation Summary ==="
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l)
GPU_NODES=$(kubectl get nodes -l "node.kubernetes.io/instance-type=${GPU_INSTANCE_TYPE}" --no-headers 2>/dev/null | wc -l)
SYSTEM_NODES=$(kubectl get nodes -l "${SYSTEM_LABEL_KEY}=${SYSTEM_LABEL_VALUE}" --no-headers 2>/dev/null | wc -l)

echo "  Total nodes:  ${TOTAL_NODES}"
echo "  System nodes: ${SYSTEM_NODES}"
echo "  GPU nodes:    ${GPU_NODES}"
echo ""

if [ "${GPU_NODES}" -ge "${GPU_NODE_COUNT}" ]; then
    echo "  CLUSTER READY for workload deployment."
    echo ""
    echo "  Next step: Deploy workloads using glm51-2p2d-serving skill"
else
    echo "  WARNING: Expected ${GPU_NODE_COUNT} GPU nodes, got ${GPU_NODES}."
    echo "  Check: aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name ${GPU_NODEGROUP_NAME} --region ${AWS_REGION}"
fi
