#!/bin/bash
# =============================================================================
# Step 2: Download model from S3 to all GPU nodes' local NVMe
# Uses indexed Job with s5cmd for high-speed parallel transfer (~8-10 GB/s)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Deploying Model Download Job ==="

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# Total GPU nodes = prefill + decode replicas
TOTAL_NODES=$((PREFILL_REPLICAS + DECODE_REPLICAS))

# Create namespace if not exists
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Apply manifests
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: glm51-model-download-script
  namespace: ${NAMESPACE}
data:
  download.sh: |
    #!/usr/bin/env bash
    set -eux

    S3_BUCKET="${S3_BUCKET}"
    S3_PREFIX="${MODEL_S3_PREFIX}"
    DEST="${MODEL_PATH}"
    SENTINEL="\$DEST/.download-complete"

    if [ -f "\$SENTINEL" ]; then
      echo "\$(date -u +%FT%TZ) Model already downloaded at \$DEST"
      du -sh "\$DEST"
      exit 0
    fi

    mkdir -p "\$DEST"

    # Install s5cmd
    if ! command -v s5cmd &> /dev/null; then
      echo "\$(date -u +%FT%TZ) Installing s5cmd..."
      cd /tmp
      yum install -y wget tar gzip >/dev/null 2>&1 || apt-get install -y wget tar gzip >/dev/null 2>&1
      wget -q https://github.com/peak/s5cmd/releases/download/v2.2.2/s5cmd_2.2.2_Linux-64bit.tar.gz
      tar -xzf s5cmd_2.2.2_Linux-64bit.tar.gz
      chmod +x s5cmd && mv s5cmd /usr/local/bin/
      rm -f s5cmd_2.2.2_Linux-64bit.tar.gz
    fi

    echo "\$(date -u +%FT%TZ) Downloading from s3://\$S3_BUCKET/\$S3_PREFIX/ to \$DEST"
    time s5cmd --numworkers 256 sync "s3://\$S3_BUCKET/\$S3_PREFIX/*" "\$DEST/"

    touch "\$SENTINEL"
    echo "\$(date -u +%FT%TZ) Download complete: \$(du -sh \$DEST | cut -f1)"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: glm51-model-download
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 2
  completions: ${TOTAL_NODES}
  parallelism: ${TOTAL_NODES}
  completionMode: Indexed
  template:
    metadata:
      labels:
        app: glm51-model-download
    spec:
      restartPolicy: Never
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      nodeSelector:
        node.kubernetes.io/instance-type: ${GPU_INSTANCE_TYPE}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: glm51-model-download
      containers:
        - name: download
          image: public.ecr.aws/amazonlinux/amazonlinux:2023
          imagePullPolicy: IfNotPresent
          env:
            - name: AWS_DEFAULT_REGION
              value: "${AWS_REGION}"
          command: ["/bin/bash", "/scripts/download.sh"]
          volumeMounts:
            - name: data
              mountPath: /data
            - name: scripts
              mountPath: /scripts
          resources:
            requests:
              cpu: "16"
              memory: "32Gi"
            limits:
              cpu: "32"
              memory: "64Gi"
      volumes:
        - name: data
          hostPath:
            path: /data
            type: Directory
        - name: scripts
          configMap:
            name: glm51-model-download-script
            defaultMode: 0755
EOF

echo ""
echo "Job deployed. Waiting for completion..."
kubectl wait --for=condition=complete --timeout=600s job/glm51-model-download -n "${NAMESPACE}" || {
    echo "WARNING: Job not complete in 10 min. Check status:"
    kubectl get pods -n "${NAMESPACE}" -l app=glm51-model-download
    echo ""
    echo "Logs from first pod:"
    kubectl logs -n "${NAMESPACE}" -l app=glm51-model-download --tail=20
    exit 1
}

echo ""
echo "=== Model Download Complete ==="
echo "  Model: s3://${S3_BUCKET}/${MODEL_S3_PREFIX}"
echo "  Location: ${MODEL_PATH} (on all ${TOTAL_NODES} GPU nodes)"
echo ""
echo "Next: ./03-deploy-serving.sh"
