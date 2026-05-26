#!/bin/bash
# =============================================================================
# Step 1 (Optional): Build SGLang + nixl + UCCL container image
# Skip this step if the image already exists in ECR.
# Requires a build machine with ~100GB disk and Docker installed.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Building Container Image ==="
echo "  Target: ${SGLANG_IMAGE}"

# Check if image already exists in ECR
if aws ecr describe-images --repository-name "${IMAGE_REPO}" --image-ids imageTag="${IMAGE_TAG}" \
    --region "${AWS_REGION}" &>/dev/null; then
    echo ""
    echo "Image already exists in ECR: ${SGLANG_IMAGE}"
    echo "Skipping build. To force rebuild, change IMAGE_TAG or delete the image."
    exit 0
fi

# Ensure ECR repo exists
aws ecr describe-repositories --repository-names "${IMAGE_REPO}" --region "${AWS_REGION}" &>/dev/null || \
    aws ecr create-repository --repository-name "${IMAGE_REPO}" --region "${AWS_REGION}"

# ECR login
aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# Check for Dockerfile
DOCKERFILE="${SCRIPT_DIR}/../Dockerfile"
if [ ! -f "${DOCKERFILE}" ]; then
    echo "ERROR: Dockerfile not found at ${DOCKERFILE}"
    echo "Copy the Dockerfile.nixl-customer to ${DOCKERFILE}"
    exit 1
fi

BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VCS_REF=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo ""
echo "Building image (this takes ~40 minutes)..."
docker build --progress=plain \
    --build-arg IMAGE_VERSION="${IMAGE_TAG}" \
    --build-arg BUILD_DATE="${BUILD_DATE}" \
    --build-arg VCS_REF="${VCS_REF}" \
    --build-arg NIXL_VERSION="${NIXL_VERSION}" \
    --build-arg NIXL_REPO="${NIXL_REPO}" \
    --build-arg SGLANG_VERSION="${SGLANG_VERSION}" \
    --build-arg UCX_VERSION="${UCX_VERSION}" \
    --build-arg UCCL_REPO="${UCCL_REPO}" \
    --build-arg UCCL_REF="${UCCL_REF}" \
    -t "${SGLANG_IMAGE}" \
    -f "${DOCKERFILE}" \
    "${SCRIPT_DIR}/.."

echo "Pushing to ECR..."
docker push "${SGLANG_IMAGE}"

echo ""
echo "=== Image Build Complete ==="
echo "  Image: ${SGLANG_IMAGE}"
echo ""
echo "Next: ./02-deploy-model-download.sh"
