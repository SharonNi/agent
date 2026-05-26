#!/bin/bash
# =============================================================================
# Step 1.2: Validate Cluster Readiness
# Comprehensive pre-nodegroup check: network + addons + API access.
# Auto-repairs missing addons if cluster exists but addons were not installed.
#
# Prerequisites: 01-create-cluster.sh (and optionally 01.1-create-vpc-endpoints.sh)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

ERRORS=0
WARNINGS=0
PASSED=0

pass()  { echo "  [PASS] $1"; PASSED=$((PASSED + 1)); }
warn()  { echo "  [WARN] $1"; WARNINGS=$((WARNINGS + 1)); }
fail()  { echo "  [FAIL] $1"; ERRORS=$((ERRORS + 1)); }

echo "=== Cluster Readiness Validation: ${CLUSTER_NAME} ==="
echo ""

# --- Discover cluster ---
if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "ERROR: Cluster ${CLUSTER_NAME} not found. Run 01-create-cluster.sh first."
    exit 1
fi

CLUSTER_STATUS=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.status' --output text)
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)

echo "Cluster: ${CLUSTER_NAME} (${CLUSTER_STATUS})"
echo "VPC:     ${VPC_ID}"
echo ""

if [ "${CLUSTER_STATUS}" != "ACTIVE" ]; then
    fail "Cluster status is ${CLUSTER_STATUS}, expected ACTIVE"
    echo "RESULT: FAILED"
    exit 1
fi

# =====================================================================
# SECTION 1: Network
# =====================================================================
echo "--- 1. Network ---"
echo ""

# 1.1 DNS
echo "1.1 VPC DNS"
DNS_SUPPORT=$(aws ec2 describe-vpc-attribute --vpc-id "${VPC_ID}" --attribute enableDnsSupport \
    --query 'EnableDnsSupport.Value' --output text --region "${AWS_REGION}")
DNS_HOSTNAMES=$(aws ec2 describe-vpc-attribute --vpc-id "${VPC_ID}" --attribute enableDnsHostnames \
    --query 'EnableDnsHostnames.Value' --output text --region "${AWS_REGION}")

[[ "${DNS_SUPPORT}" =~ [Tt]rue ]] && pass "DNS Support enabled" || fail "DNS Support disabled"
[[ "${DNS_HOSTNAMES}" =~ [Tt]rue ]] && pass "DNS Hostnames enabled" || fail "DNS Hostnames disabled"
echo ""

# 1.2 Internet Gateway
echo "1.2 Internet Gateway"
IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId' --output text --region "${AWS_REGION}")

if [ -n "${IGW_ID}" ] && [ "${IGW_ID}" != "None" ]; then
    pass "IGW attached: ${IGW_ID}"
else
    fail "No Internet Gateway"
fi
echo ""

# 1.3 NAT Gateway
echo "1.3 NAT Gateway"
NAT_COUNT=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
    --query 'length(NatGateways)' --output text --region "${AWS_REGION}")

if [ "${NAT_COUNT}" -eq 0 ]; then
    fail "No NAT Gateway (private subnets have no internet)"
else
    pass "NAT Gateway(s): ${NAT_COUNT}"
fi
echo ""

# 1.4 Private Subnet Routing
echo "1.4 Private Subnet Routing"
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" \
    --query 'Subnets[*].SubnetId' --output text --region "${AWS_REGION}")

for SID in ${PRIVATE_SUBNETS}; do
    NAT_ROUTE=$(aws ec2 describe-route-tables \
        --filters "Name=association.subnet-id,Values=${SID}" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId' \
        --output text --region "${AWS_REGION}" 2>/dev/null)

    if [ -n "${NAT_ROUTE}" ] && [ "${NAT_ROUTE}" != "None" ]; then
        pass "Subnet ${SID} → NAT"
    else
        fail "Subnet ${SID} has no NAT route"
    fi
done
echo ""

# 1.5 VPC Endpoints
echo "1.5 VPC Endpoints"
declare -a CORE_ENDPOINTS=("eks" "eks-auth" "sts" "ecr.api" "ecr.dkr" "logs" "s3")
declare -a OPT_ENDPOINTS=("ec2" "autoscaling" "elasticloadbalancing")

MISSING_EP=0
for svc in "${CORE_ENDPOINTS[@]}"; do
    svc_name="com.amazonaws.${AWS_REGION}.${svc}"
    EP_STATE=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${svc_name}" \
        --query 'VpcEndpoints[0].State' --output text --region "${AWS_REGION}" 2>/dev/null)

    if [ -n "${EP_STATE}" ] && [ "${EP_STATE}" != "None" ]; then
        pass "${svc}: ${EP_STATE}"
    else
        warn "${svc}: not found (traffic via NAT)"
        MISSING_EP=$((MISSING_EP + 1))
    fi
done

for svc in "${OPT_ENDPOINTS[@]}"; do
    svc_name="com.amazonaws.${AWS_REGION}.${svc}"
    EP_STATE=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=${svc_name}" \
        --query 'VpcEndpoints[0].State' --output text --region "${AWS_REGION}" 2>/dev/null)

    if [ -n "${EP_STATE}" ] && [ "${EP_STATE}" != "None" ]; then
        pass "${svc}: ${EP_STATE}"
    else
        warn "${svc}: not found (optional)"
    fi
done

[ ${MISSING_EP} -gt 0 ] && echo "  Tip: Run ./01.1-create-vpc-endpoints.sh to reduce NAT costs"
echo ""

# 1.6 EKS API Access
echo "1.6 EKS API Access"
PUBLIC_ACCESS=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
PRIVATE_ACCESS=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' --output text)

[[ "${PUBLIC_ACCESS}" =~ [Tt]rue ]] && pass "Public access: enabled" || warn "Public access: disabled"
[[ "${PRIVATE_ACCESS}" =~ [Tt]rue ]] && pass "Private access: enabled" || fail "Private access: disabled (nodes can't reach API)"
echo ""

# =====================================================================
# SECTION 2: EKS Managed Addons
# =====================================================================
echo "--- 2. EKS Managed Addons ---"
echo ""

declare -A REQUIRED_ADDONS=(
    ["vpc-cni"]="Pod networking (CNI)"
    ["kube-proxy"]="Service load balancing"
    ["coredns"]="Cluster DNS"
    ["eks-pod-identity-agent"]="Pod Identity credentials"
    ["metrics-server"]="Resource metrics"
)

ADDONS_MISSING=()
ADDONS_DEGRADED=()

for addon in "${!REQUIRED_ADDONS[@]}"; do
    desc="${REQUIRED_ADDONS[$addon]}"
    STATUS=$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "${addon}" \
        --region "${AWS_REGION}" --query 'addon.status' --output text 2>/dev/null)

    if [ -z "${STATUS}" ] || [ "${STATUS}" = "None" ]; then
        warn "${addon} (${desc}): NOT INSTALLED"
        ADDONS_MISSING+=("${addon}")
    elif [ "${STATUS}" = "ACTIVE" ]; then
        pass "${addon}: ACTIVE"
    elif [ "${STATUS}" = "CREATING" ]; then
        warn "${addon}: CREATING (still provisioning)"
        ADDONS_DEGRADED+=("${addon}")
    else
        warn "${addon}: ${STATUS}"
        ADDONS_DEGRADED+=("${addon}")
    fi
done
echo ""

# --- Auto-repair missing addons ---
if [ ${#ADDONS_MISSING[@]} -gt 0 ]; then
    echo "  Auto-repairing: installing ${#ADDONS_MISSING[@]} missing addon(s)..."
    for addon in "${ADDONS_MISSING[@]}"; do
        # Get latest compatible version
        ADDON_VER=$(aws eks describe-addon-versions --addon-name "${addon}" \
            --kubernetes-version "${K8S_VERSION}" --region "${AWS_REGION}" \
            --query 'addons[0].addonVersions[0].addonVersion' --output text 2>/dev/null)

        if [ -z "${ADDON_VER}" ] || [ "${ADDON_VER}" = "None" ]; then
            fail "Cannot find version for ${addon}"
            continue
        fi

        # Addon-specific config
        CONFIG_VALUES=""
        if [ "${addon}" = "vpc-cni" ]; then
            CONFIG_VALUES='{"env":{"AWS_VPC_K8S_CNI_EXTERNALSNAT":"false","WARM_ENI_TARGET":"0","WARM_IP_TARGET":"5","MINIMUM_IP_TARGET":"3"}}'
        fi

        if [ -n "${CONFIG_VALUES}" ]; then
            aws eks create-addon --cluster-name "${CLUSTER_NAME}" --addon-name "${addon}" \
                --addon-version "${ADDON_VER}" --configuration-values "${CONFIG_VALUES}" \
                --region "${AWS_REGION}" --output text >/dev/null 2>&1 && \
                echo "    ${addon} ${ADDON_VER}: installing..." || \
                echo "    ${addon}: failed to install"
        else
            aws eks create-addon --cluster-name "${CLUSTER_NAME}" --addon-name "${addon}" \
                --addon-version "${ADDON_VER}" \
                --region "${AWS_REGION}" --output text >/dev/null 2>&1 && \
                echo "    ${addon} ${ADDON_VER}: installing..." || \
                echo "    ${addon}: failed to install"
        fi
    done
    echo ""
fi

# --- Wait for vpc-cni to be ACTIVE (critical for node Ready) ---
if [ ${#ADDONS_MISSING[@]} -gt 0 ] || [ ${#ADDONS_DEGRADED[@]} -gt 0 ]; then
    echo "  Waiting for vpc-cni to become ACTIVE (required for node networking)..."
    for i in $(seq 1 30); do
        CNI_STATUS=$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name "vpc-cni" \
            --region "${AWS_REGION}" --query 'addon.status' --output text 2>/dev/null)
        if [ "${CNI_STATUS}" = "ACTIVE" ]; then
            pass "vpc-cni is ACTIVE"
            break
        fi
        echo "    vpc-cni: ${CNI_STATUS} (${i}/30)..."
        sleep 10
    done

    if [ "${CNI_STATUS}" != "ACTIVE" ]; then
        fail "vpc-cni did not become ACTIVE within 5 minutes"
    fi
    echo ""
fi

# =====================================================================
# SECTION 3: Summary
# =====================================================================
echo "==========================================="
echo "  PASSED:   ${PASSED}"
echo "  WARNINGS: ${WARNINGS}"
echo "  FAILED:   ${ERRORS}"
echo "==========================================="

if [ ${ERRORS} -gt 0 ]; then
    echo ""
    echo "RESULT: FAILED — fix errors before creating nodegroups."
    exit 1
else
    echo ""
    echo "RESULT: PASSED — ready for ./02-create-system-nodegroup.sh"
    exit 0
fi
