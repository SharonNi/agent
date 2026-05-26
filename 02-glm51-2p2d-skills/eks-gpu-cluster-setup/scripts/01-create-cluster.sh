#!/bin/bash
# =============================================================================
# Step 1: Create EKS Cluster with auto-provisioned VPC
# eksctl handles VPC, subnets, NAT Gateway, route tables automatically.
# Single AZ is enforced for EFA topology.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Creating EKS Cluster: ${CLUSTER_NAME} ==="

# Check if cluster already exists
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "Cluster '${CLUSTER_NAME}' already exists, skipping creation."
    aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
        --query 'cluster.{Status:status,Endpoint:endpoint,Version:version}' --output table
    exit 0
fi

# Generate eksctl cluster config
CLUSTER_CONFIG="/tmp/${CLUSTER_NAME}-config.yaml"
cat > "${CLUSTER_CONFIG}" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"
  tags:
    cluster-autoscaler: enabled

availabilityZones:
  - ${TARGET_AZ}
  - ${SECONDARY_AZ}

autoModeConfig:
  enabled: false

kubernetesNetworkConfig:
  serviceIPv4CIDR: "${SERVICE_IPV4_CIDR}"

vpc:
  nat:
    gateway: Single
  clusterEndpoints:
    privateAccess: true
    publicAccess: true

accessConfig:
  authenticationMode: API_AND_CONFIG_MAP

iam:
  withOIDC: false

managedNodeGroups: []

addons:
  - name: vpc-cni
    version: latest
    configurationValues: |
      env:
        AWS_VPC_K8S_CNI_EXTERNALSNAT: "false"
        WARM_ENI_TARGET: "0"
        WARM_IP_TARGET: "5"
        MINIMUM_IP_TARGET: "3"
  - name: kube-proxy
    version: latest
  - name: eks-pod-identity-agent
    version: latest
  - name: coredns
    version: latest
    configurationValues: |
      replicaCount: 1
  - name: metrics-server
    version: latest
    configurationValues: |
      replicas: 1

cloudWatch:
  clusterLogging:
    logRetentionInDays: 30
    enableTypes:
      - "api"
      - "audit"
      - "authenticator"
      - "controllerManager"
      - "scheduler"
EOF

echo "Generated cluster config:"
cat "${CLUSTER_CONFIG}"
echo ""

echo "Creating cluster (this takes ~12 minutes)..."
eksctl create cluster -f "${CLUSTER_CONFIG}"

# Wait for cluster to be active
aws eks wait cluster-active --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# Update kubeconfig
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# Capture VPC info for subsequent scripts
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo ""
echo "=== Cluster Created Successfully ==="
echo "  Name:    ${CLUSTER_NAME}"
echo "  VPC:     ${VPC_ID}"
echo "  Region:  ${AWS_REGION}"
echo "  AZ:      ${TARGET_AZ}"
echo ""
echo "Next: ./02-create-system-nodegroup.sh"

rm -f "${CLUSTER_CONFIG}"
