#!/bin/bash
# =============================================================================
# GLM-5.1 2P2D Serving - Environment Configuration
# =============================================================================
set -e
export AWS_PAGER=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load .env if present ---
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a; source "${SCRIPT_DIR}/.env"; set +a
elif [ -z "${AWS_REGION:-}" ]; then
    echo "ERROR: No .env file found and AWS_REGION not set."
    echo "  cp ${SCRIPT_DIR}/.env.example ${SCRIPT_DIR}/.env"
    echo "  Then edit .env to set AWS_REGION (required) and other parameters."
    exit 1
fi

# --- Core Settings ---
export CLUSTER_NAME="${CLUSTER_NAME:-gpu-eks-cluster}"
export AWS_REGION="${AWS_REGION:?Set AWS_REGION before running (e.g. export AWS_REGION=us-west-2)}"
export NAMESPACE="${NAMESPACE:-glm51-test}"

# Auto-detect Account ID
if [ -z "${ACCOUNT_ID:-}" ]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
        echo "ERROR: Failed to get AWS Account ID."
        exit 1
    }
fi
export ACCOUNT_ID
export AWS_DEFAULT_REGION="${AWS_REGION}"

# --- S3 ---
export S3_BUCKET="${S3_BUCKET:-glm51-nixl-test-${ACCOUNT_ID}}"
export MODEL_S3_PREFIX="${MODEL_S3_PREFIX:-models/GLM-5.1-FP8}"
export CACHE_S3_PREFIX="${CACHE_S3_PREFIX:-cache/deep_gemm}"

# --- Container Image ---
export ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
export IMAGE_REPO="${IMAGE_REPO:-sglang-nixl}"
export IMAGE_TAG="${IMAGE_TAG:-latest}"
export SGLANG_IMAGE="${ECR_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

# --- Model ---
export MODEL_PATH="${MODEL_PATH:-/data/models/GLM-5.1-FP8}"
export MODEL_NAME="${MODEL_NAME:-glm-5-fp8-long-pd}"

# --- Cluster Topology ---
export GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-p5en.48xlarge}"
export PREFILL_REPLICAS="${PREFILL_REPLICAS:-2}"
export DECODE_REPLICAS="${DECODE_REPLICAS:-2}"

# Prefill: PP=2 across 2 nodes, TP=8 within each node
export PREFILL_PP="${PREFILL_PP:-2}"
export PREFILL_TP="${PREFILL_TP:-8}"

# Decode: TP=16 across 2 nodes, DP=16
export DECODE_TP="${DECODE_TP:-16}"
export DECODE_DP="${DECODE_DP:-16}"

# --- DeepGEMM Cache ---
export DEEPGEMM_CACHE_DIR="${DEEPGEMM_CACHE_DIR:-/data/sglang/deep_gemm}"
export DEEPGEMM_SYNC_INTERVAL="${DEEPGEMM_SYNC_INTERVAL:-300}"

# --- Image Build (optional) ---
export NIXL_REPO="${NIXL_REPO:-https://github.com/xqun3/nixl.git}"
export NIXL_VERSION="${NIXL_VERSION:-ac46102d8d1c971e5f36a5568cbd3b8a2ca23cb1}"
export SGLANG_VERSION="${SGLANG_VERSION:-0.5.10}"
export UCX_VERSION="${UCX_VERSION:-v1.18.0}"
export UCCL_REPO="${UCCL_REPO:-https://github.com/uccl-project/uccl.git}"
export UCCL_REF="${UCCL_REF:-8ac850bd}"

# --- Summary ---
echo "=== GLM-5.1 2P2D Serving Config ==="
echo "  Cluster:   ${CLUSTER_NAME}"
echo "  Namespace: ${NAMESPACE}"
echo "  Image:     ${SGLANG_IMAGE}"
echo "  Model:     s3://${S3_BUCKET}/${MODEL_S3_PREFIX}"
echo "  Prefill:   ${PREFILL_REPLICAS} nodes (PP=${PREFILL_PP}, TP=${PREFILL_TP})"
echo "  Decode:    ${DECODE_REPLICAS} nodes (TP=${DECODE_TP}, DP=${DECODE_DP})"
echo "  Cache:     sync every ${DEEPGEMM_SYNC_INTERVAL}s"
echo "=================================="
