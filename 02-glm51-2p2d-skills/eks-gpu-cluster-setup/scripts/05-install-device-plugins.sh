#!/bin/bash
# =============================================================================
# Step 5: Install NVIDIA + EFA Device Plugins
# These DaemonSets expose GPU and EFA resources to the Kubernetes scheduler.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Installing Device Plugins ==="

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# --- NVIDIA Device Plugin ---
echo ""
echo "Step 5.1: NVIDIA Device Plugin (${NVIDIA_PLUGIN_VERSION})..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      priorityClassName: system-node-critical
      containers:
        - name: nvidia-device-plugin-ctr
          image: ${NVIDIA_PLUGIN_IMAGE}
          env:
            - name: FAIL_ON_INIT_ERROR
              value: "false"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
EOF

echo "NVIDIA device plugin deployed."

# --- EFA Device Plugin ---
echo ""
echo "Step 5.2: EFA Device Plugin (${EFA_PLUGIN_VERSION})..."

kubectl apply -f "https://raw.githubusercontent.com/aws-samples/aws-efa-eks/main/manifest/efa-k8s-device-plugin.yml" 2>/dev/null || \
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: aws-efa-k8s-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: aws-efa-k8s-device-plugin
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: aws-efa-k8s-device-plugin
    spec:
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      priorityClassName: system-node-critical
      hostNetwork: true
      containers:
        - name: aws-efa-k8s-device-plugin
          image: 602401143452.dkr.ecr.${AWS_REGION}.amazonaws.com/eks/aws-efa-k8s-device-plugin:${EFA_PLUGIN_VERSION}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
EOF

echo "EFA device plugin deployed."

# --- Verify ---
echo ""
echo "Step 5.3: Verifying device plugins..."
echo "Waiting 30s for plugins to register..."
sleep 30

echo ""
echo "GPU resources per node:"
kubectl get nodes -l "node.kubernetes.io/instance-type=${GPU_INSTANCE_TYPE}" \
    -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,EFA:.status.allocatable.vpc\.amazonaws\.com/efa'

echo ""
echo "=== Device Plugins Installed ==="
echo "  nvidia.com/gpu: should show 8 per p5en node"
echo "  vpc.amazonaws.com/efa: should show 16 per p5en node"
echo ""
echo "Next: ./06-validate.sh"
