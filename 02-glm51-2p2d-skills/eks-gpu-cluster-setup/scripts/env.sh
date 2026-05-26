#!/bin/bash
# =============================================================================
# EKS GPU Cluster - Environment Configuration
# =============================================================================
# Modify these variables before running any scripts.
# ACCOUNT_ID is auto-detected if not set.
# =============================================================================

set -e
export AWS_PAGER=""

# --- Load .env if present (same dir or parent dir) ---
if [ -f "${SCRIPT_DIR:-.}/.env" ]; then
    set -a; source "${SCRIPT_DIR:-.}/.env"; set +a
elif [ -f "${SCRIPT_DIR:-..}/../.env" ]; then
    set -a; source "${SCRIPT_DIR:-..}/../.env"; set +a
elif [ -z "${AWS_REGION:-}" ]; then
    echo "ERROR: No .env file found and AWS_REGION not set."
    echo "  cp ${SCRIPT_DIR:-.}/.env.example ${SCRIPT_DIR:-.}/.env"
    echo "  Then edit .env to set AWS_REGION (required) and other parameters."
    exit 1
fi

# --- Core Settings ---
export CLUSTER_NAME="${CLUSTER_NAME:-gpu-eks-cluster}"
export AWS_REGION="${AWS_REGION:?Set AWS_REGION before running (e.g. export AWS_REGION=us-west-2)}"
export K8S_VERSION="${K8S_VERSION:-1.35}"
export SERVICE_IPV4_CIDR="${SERVICE_IPV4_CIDR:-172.20.0.0/16}"

# Auto-detect Account ID
if [ -z "${ACCOUNT_ID:-}" ]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
        echo "ERROR: Failed to get AWS Account ID. Configure AWS CLI or set ACCOUNT_ID."
        exit 1
    }
fi
export ACCOUNT_ID
export AWS_DEFAULT_REGION="${AWS_REGION}"

# --- Single AZ for EFA topology ---
# EFA/RDMA requires all GPU nodes in the same AZ for optimal performance.
# eksctl will auto-create VPC with subnets in this AZ.
export TARGET_AZ="${TARGET_AZ:-${AWS_REGION}a}"  # Primary AZ for GPU/EFA nodes
export SECONDARY_AZ="${SECONDARY_AZ:-${AWS_REGION}c}"  # Secondary AZ (eksctl requires >=2 AZ for VPC)

# --- GPU Node Group ---
export GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-p5en.48xlarge}"
export GPU_NODE_COUNT="${GPU_NODE_COUNT:-4}"
export GPU_NODE_MIN="${GPU_NODE_MIN:-0}"
export GPU_NODE_MAX="${GPU_NODE_MAX:-8}"
export GPU_PRICING="${GPU_PRICING:-Spot}"  # Spot | OnDemand
export GPU_ROOT_VOLUME_SIZE="${GPU_ROOT_VOLUME_SIZE:-500}"
export GPU_DATA_VOLUME_SIZE="${GPU_DATA_VOLUME_SIZE:-200}"
export GPU_NODEGROUP_NAME="${GPU_NODEGROUP_NAME:-gpu-p5en-spot}"

# Local NVMe Instance Store (striped into LVM, mounted at /data)
export GPU_LVM_VG="${GPU_LVM_VG:-vg_local}"
export GPU_LVM_LV="${GPU_LVM_LV:-lv_scratch}"
export GPU_LVM_MOUNT="${GPU_LVM_MOUNT:-/data}"

# --- System Node Group ---
export SYSTEM_INSTANCE_TYPE="${SYSTEM_INSTANCE_TYPE:-m8g.xlarge}"
export SYSTEM_NODE_COUNT="${SYSTEM_NODE_COUNT:-1}"
export SYSTEM_NODE_MIN="${SYSTEM_NODE_MIN:-1}"
export SYSTEM_NODE_MAX="${SYSTEM_NODE_MAX:-3}"
export SYSTEM_ROOT_VOLUME="${SYSTEM_ROOT_VOLUME:-50}"
export SYSTEM_DATA_VOLUME="${SYSTEM_DATA_VOLUME:-100}"
export SYSTEM_LABEL_KEY="${SYSTEM_LABEL_KEY:-app}"
export SYSTEM_LABEL_VALUE="${SYSTEM_LABEL_VALUE:-eks-utils}"

# --- Device Plugins ---
export EFA_PLUGIN_VERSION="${EFA_PLUGIN_VERSION:-v0.5.17}"
export NVIDIA_PLUGIN_VERSION="${NVIDIA_PLUGIN_VERSION:-v0.15.0}"
export NVIDIA_PLUGIN_IMAGE="${NVIDIA_PLUGIN_IMAGE:-nvcr.io/nvidia/k8s-device-plugin:${NVIDIA_PLUGIN_VERSION}}"

# --- Addons ---
export CLUSTER_AUTOSCALER_VERSION="${CLUSTER_AUTOSCALER_VERSION:-v1.35.0}"
export ALB_CONTROLLER_CHART_VERSION="${ALB_CONTROLLER_CHART_VERSION:-1.16.0}"

# --- IAM ---
export NODE_ROLE_NAME="EKSNodeRole-${CLUSTER_NAME}"
export INSTANCE_PROFILE_NAME="${NODE_ROLE_NAME}"

# --- S3 ---
export S3_BUCKET="${S3_BUCKET:-glm51-nixl-test-${ACCOUNT_ID}}"

# --- Derived ---
export ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# --- Summary ---
echo "=== EKS GPU Cluster Config ==="
echo "  Cluster:    ${CLUSTER_NAME} (K8s ${K8S_VERSION})"
echo "  Region:     ${AWS_REGION} (AZ: ${TARGET_AZ})"
echo "  Account:    ${ACCOUNT_ID}"
echo "  GPU:        ${GPU_NODE_COUNT}× ${GPU_INSTANCE_TYPE} (${GPU_PRICING})"
echo "  System:     ${SYSTEM_NODE_COUNT}× ${SYSTEM_INSTANCE_TYPE}"
echo "  NVMe Mount: ${GPU_LVM_MOUNT}"
echo "==============================="
