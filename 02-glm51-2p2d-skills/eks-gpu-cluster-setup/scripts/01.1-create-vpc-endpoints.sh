#!/bin/bash
# =============================================================================
# Step 1.5: Create VPC Endpoints after eksctl cluster creation
# Reduces NAT Gateway traffic costs by routing AWS API calls through VPC
# endpoints directly (PrivateLink for interface, Gateway for S3).
#
# Prerequisites: 01-create-cluster.sh has completed.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Creating VPC Endpoints for ${CLUSTER_NAME} ==="

# --- Discover VPC and subnet info from the existing cluster ---
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)

if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
    echo "ERROR: Could not find VPC for cluster ${CLUSTER_NAME}. Run 01-create-cluster.sh first."
    exit 1
fi

VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "${VPC_ID}" --region "${AWS_REGION}" \
    --query 'Vpcs[0].CidrBlock' --output text)

# Get private subnets (eksctl tags them with kubernetes.io/role/internal-elb=1)
PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
    --query 'Subnets[*].SubnetId' --output text --region "${AWS_REGION}")

if [ -z "${PRIVATE_SUBNET_IDS}" ]; then
    # Fallback: get all subnets that have NAT route (private)
    PRIVATE_SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
                  "Name=map-public-ip-on-launch,Values=false" \
        --query 'Subnets[*].SubnetId' --output text --region "${AWS_REGION}")
fi

if [ -z "${PRIVATE_SUBNET_IDS}" ]; then
    echo "ERROR: No private subnets found in VPC ${VPC_ID}"
    exit 1
fi

echo "  VPC:     ${VPC_ID} (${VPC_CIDR})"
echo "  Subnets: ${PRIVATE_SUBNET_IDS}"
echo ""

# --- Create Security Group for VPC Endpoints ---
echo "Step 1: Security Group for VPC Endpoints..."
SG_NAME="${CLUSTER_NAME}-vpce-sg"

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null)

if [ -z "${SG_ID}" ] || [ "${SG_ID}" = "None" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${SG_NAME}" \
        --description "Allow HTTPS from VPC to VPC Endpoints" \
        --vpc-id "${VPC_ID}" \
        --region "${AWS_REGION}" \
        --query 'GroupId' --output text)

    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp --port 443 \
        --cidr "${VPC_CIDR}" \
        --region "${AWS_REGION}" >/dev/null

    aws ec2 create-tags --resources "${SG_ID}" --region "${AWS_REGION}" \
        --tags "Key=Name,Value=${SG_NAME}" "Key=Cluster,Value=${CLUSTER_NAME}"

    echo "  Created: ${SG_ID}"
else
    echo "  Exists:  ${SG_ID}"
fi
echo ""

# --- Helper function ---
create_interface_endpoint() {
    local service="$1"
    local description="$2"
    local service_name="com.amazonaws.${AWS_REGION}.${service}"

    printf "  %-25s" "${description}..."

    EXISTING=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${service_name}" \
        --query 'VpcEndpoints[0].VpcEndpointId' --output text --region "${AWS_REGION}" 2>/dev/null)

    if [ -n "${EXISTING}" ] && [ "${EXISTING}" != "None" ]; then
        echo "exists (${EXISTING})"
        return
    fi

    ENDPOINT_ID=$(aws ec2 create-vpc-endpoint \
        --vpc-id "${VPC_ID}" \
        --service-name "${service_name}" \
        --vpc-endpoint-type Interface \
        --subnet-ids ${PRIVATE_SUBNET_IDS} \
        --security-group-ids "${SG_ID}" \
        --private-dns-enabled \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${CLUSTER_NAME}-${service}},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
        --query 'VpcEndpoint.VpcEndpointId' --output text --region "${AWS_REGION}" 2>/dev/null)

    if [ -n "${ENDPOINT_ID}" ]; then
        echo "created (${ENDPOINT_ID})"
    else
        echo "FAILED"
    fi
}

# --- Create Interface Endpoints ---
echo "Step 2: Interface Endpoints (PrivateLink)..."

# Core EKS
create_interface_endpoint "eks"          "EKS API"
create_interface_endpoint "eks-auth"     "EKS Auth (Pod Identity)"
create_interface_endpoint "sts"          "STS"

# Container registry
create_interface_endpoint "ecr.api"      "ECR API"
create_interface_endpoint "ecr.dkr"      "ECR Docker"

# Observability
create_interface_endpoint "logs"         "CloudWatch Logs"

# Addons (Autoscaler, LB Controller)
create_interface_endpoint "ec2"          "EC2 (EBS CSI)"
create_interface_endpoint "autoscaling"  "Auto Scaling"
create_interface_endpoint "elasticloadbalancing" "ELB (ALB Controller)"

echo ""

# --- Create S3 Gateway Endpoint ---
echo "Step 3: S3 Gateway Endpoint..."
S3_SERVICE="com.amazonaws.${AWS_REGION}.s3"

EXISTING_S3=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${S3_SERVICE}" \
    --query 'VpcEndpoints[0].VpcEndpointId' --output text --region "${AWS_REGION}" 2>/dev/null)

if [ -n "${EXISTING_S3}" ] && [ "${EXISTING_S3}" != "None" ]; then
    echo "  S3 Gateway:              exists (${EXISTING_S3})"
else
    # Get route table IDs for private subnets
    RT_IDS=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=route.nat-gateway-id,Values=*" \
        --query 'RouteTables[*].RouteTableId' --output text --region "${AWS_REGION}")

    if [ -z "${RT_IDS}" ]; then
        # Fallback: all non-main route tables
        RT_IDS=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=${VPC_ID}" \
            --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
            --output text --region "${AWS_REGION}")
    fi

    S3_ID=$(aws ec2 create-vpc-endpoint \
        --vpc-id "${VPC_ID}" \
        --service-name "${S3_SERVICE}" \
        --vpc-endpoint-type Gateway \
        --route-table-ids ${RT_IDS} \
        --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=${CLUSTER_NAME}-s3-gw},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
        --query 'VpcEndpoint.VpcEndpointId' --output text --region "${AWS_REGION}" 2>/dev/null)

    if [ -n "${S3_ID}" ]; then
        echo "  S3 Gateway:              created (${S3_ID})"
    else
        echo "  S3 Gateway:              FAILED"
    fi
fi

echo ""
echo "=== VPC Endpoints Created ==="
echo ""
echo "Summary:"
aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Cluster,Values=${CLUSTER_NAME}" \
    --query 'VpcEndpoints[*].[VpcEndpointType,ServiceName,State]' \
    --output table --region "${AWS_REGION}"
echo ""
echo "Note: Interface endpoints take 1-2 min to reach 'available' state."
echo "Next: ./02-create-system-nodegroup.sh"
