#!/bin/bash
# =============================================================================
# Step 2: Create System Node Group with LVM for containerd
# Graviton4 instances for cost-effective system workloads (CoreDNS, autoscaler)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Creating System Node Group ==="

# Verify cluster exists
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 || {
    echo "ERROR: Cluster '${CLUSTER_NAME}' not found. Run 01-create-cluster.sh first."
    exit 1
}

# Get cluster info
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.endpoint' --output text)
CLUSTER_CA=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.certificateAuthority.data' --output text)
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)
CLUSTER_SVC_CIDR=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text)

# Get private subnets from VPC
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:*Private*,Values=*" \
    --query 'Subnets[].SubnetId' --output text --region "${AWS_REGION}" | tr '\t' ',')

if [ -z "${PRIVATE_SUBNETS}" ]; then
    PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=false" \
        --query 'Subnets[].SubnetId' --output text --region "${AWS_REGION}" | tr '\t' ',')
fi

echo "VPC: ${VPC_ID}"
echo "Private Subnets: ${PRIVATE_SUBNETS}"

# --- IAM Role ---
echo ""
echo "Step 2.1: Creating IAM Role..."
if aws iam get-role --role-name "${NODE_ROLE_NAME}" &>/dev/null; then
    echo "IAM Role ${NODE_ROLE_NAME} already exists."
else
    aws iam create-role \
        --role-name "${NODE_ROLE_NAME}" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }' \
        --tags Key=Cluster,Value="${CLUSTER_NAME}"
fi

for POLICY in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
    aws iam attach-role-policy --role-name "${NODE_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/${POLICY}" 2>/dev/null || true
done

aws iam put-role-policy --role-name "${NODE_ROLE_NAME}" \
    --policy-name "NodeadmDescribeInstances" \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"],
            "Resource": "*"
        }]
    }'

# Instance Profile
if ! aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" &>/dev/null; then
    aws iam create-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}"
    aws iam add-role-to-instance-profile \
        --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
        --role-name "${NODE_ROLE_NAME}"
    echo "Waiting for instance profile propagation..."
    sleep 10
fi

echo "IAM Role ready: ${NODE_ROLE_NAME}"

# --- AMI ---
echo ""
echo "Step 2.2: Getting EKS-optimized AMI..."

if [[ "${SYSTEM_INSTANCE_TYPE}" =~ ^[a-z][0-9]+g ]]; then
    AMI_ARCH="arm64"
else
    AMI_ARCH="x86_64"
fi

AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/${AMI_ARCH}/standard/recommended/image_id" \
    --region "${AWS_REGION}" --query 'Parameter.Value' --output text)

echo "AMI: ${AMI_ID} (${AMI_ARCH})"

# --- User Data with LVM ---
echo ""
echo "Step 2.3: Creating Launch Template..."
USERDATA_FILE="/tmp/system-userdata-$$.txt"
cat > "${USERDATA_FILE}" <<UDEOF
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
set -ex
exec > >(tee /var/log/lvm-setup.log) 2>&1

echo "=== LVM Setup for containerd ==="
systemctl stop containerd || true

# Find unpartitioned data disk
for i in \$(seq 1 60); do
  for dev in \$(lsblk -dpno NAME | grep nvme); do
    PARTS=\$(lsblk -no NAME "\$dev" 2>/dev/null | wc -l)
    if [ "\$PARTS" -eq 1 ]; then
      DISK="\$dev"
      break 2
    fi
  done
  sleep 1
done

if [ -z "\${DISK:-}" ]; then
  echo "No data disk found, starting containerd on root volume"
  systemctl start containerd
  exit 0
fi

if vgs vg_data &>/dev/null; then
  mount /dev/vg_data/lv_containerd /var/lib/containerd || true
  systemctl start containerd
else
  dnf install -y lvm2 rsync
  pvcreate "\$DISK"
  vgcreate vg_data "\$DISK"
  lvcreate -l 100%VG -n lv_containerd vg_data
  mkfs.xfs /dev/vg_data/lv_containerd

  mkdir -p /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /mnt/runtime/containerd
  rsync -aHAX /var/lib/containerd/ /mnt/runtime/containerd/ || true
  umount /mnt/runtime/containerd
  mount /dev/vg_data/lv_containerd /var/lib/containerd

  grep -q "lv_containerd" /etc/fstab || \
    echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab
  systemctl start containerd
fi

echo "=== EKS Node Bootstrap ==="
mkdir -p /etc/eks/nodeadm.d
cat > /etc/eks/nodeadm.d/nodeconfig.yaml <<NODECONFIG
---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    apiServerEndpoint: ${CLUSTER_ENDPOINT}
    certificateAuthority: ${CLUSTER_CA}
    cidr: ${CLUSTER_SVC_CIDR}
NODECONFIG

nodeadm init --config-source file:///etc/eks/nodeadm.d/nodeconfig.yaml
systemctl enable kubelet containerd

--==BOUNDARY==--
UDEOF

# --- Launch Template ---
LT_NAME="${CLUSTER_NAME}-system-lt"
LT_DATA="{
  \"ImageId\": \"${AMI_ID}\",
  \"InstanceType\": \"${SYSTEM_INSTANCE_TYPE}\",
  \"UserData\": \"$(base64 -w 0 < ${USERDATA_FILE})\",
  \"BlockDeviceMappings\": [
    {\"DeviceName\": \"/dev/xvda\", \"Ebs\": {\"VolumeSize\": ${SYSTEM_ROOT_VOLUME}, \"VolumeType\": \"gp3\", \"Encrypted\": true, \"DeleteOnTermination\": true}},
    {\"DeviceName\": \"/dev/xvdb\", \"Ebs\": {\"VolumeSize\": ${SYSTEM_DATA_VOLUME}, \"VolumeType\": \"gp3\", \"Iops\": 3000, \"Throughput\": 125, \"Encrypted\": true, \"DeleteOnTermination\": true}}
  ],
  \"MetadataOptions\": {\"HttpEndpoint\": \"enabled\", \"HttpTokens\": \"required\", \"HttpPutResponseHopLimit\": 2},
  \"TagSpecifications\": [{\"ResourceType\": \"instance\", \"Tags\": [{\"Key\": \"Name\", \"Value\": \"${CLUSTER_NAME}-system-node\"}]}]
}"

if aws ec2 describe-launch-templates --launch-template-names "${LT_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    LT_ID=$(aws ec2 describe-launch-templates --launch-template-names "${LT_NAME}" \
        --region "${AWS_REGION}" --query 'LaunchTemplates[0].LaunchTemplateId' --output text)
    LT_VERSION=$(aws ec2 create-launch-template-version --launch-template-id "${LT_ID}" \
        --launch-template-data "${LT_DATA}" --region "${AWS_REGION}" \
        --query 'LaunchTemplateVersion.VersionNumber' --output text)
else
    LT_RESULT=$(aws ec2 create-launch-template --launch-template-name "${LT_NAME}" \
        --launch-template-data "${LT_DATA}" --region "${AWS_REGION}" --output json)
    LT_ID=$(echo "${LT_RESULT}" | jq -r '.LaunchTemplate.LaunchTemplateId')
    LT_VERSION=$(echo "${LT_RESULT}" | jq -r '.LaunchTemplate.LatestVersionNumber')
fi

rm -f "${USERDATA_FILE}"
echo "Launch Template: ${LT_ID} v${LT_VERSION}"

# --- Create Node Group via eksctl ---
echo ""
echo "Step 2.4: Creating managed node group..."

# Get first private subnet for eksctl
FIRST_SUBNET=$(echo "${PRIVATE_SUBNETS}" | cut -d',' -f1)

TEMP_CONFIG="/tmp/eksctl-system-ng-$$.yaml"
cat > "${TEMP_CONFIG}" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${K8S_VERSION}"
vpc:
  id: "${VPC_ID}"
  subnets:
    private:
      ${TARGET_AZ}:
        id: "${FIRST_SUBNET}"
managedNodeGroups:
  - name: eks-utils
    launchTemplate:
      id: ${LT_ID}
      version: "${LT_VERSION}"
    iam:
      instanceRoleARN: arn:aws:iam::${ACCOUNT_ID}:role/${NODE_ROLE_NAME}
    desiredCapacity: ${SYSTEM_NODE_COUNT}
    minSize: ${SYSTEM_NODE_MIN}
    maxSize: ${SYSTEM_NODE_MAX}
    privateNetworking: true
    labels:
      ${SYSTEM_LABEL_KEY}: "${SYSTEM_LABEL_VALUE}"
      node-group-type: "system"
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
EOF

if aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name eks-utils --region "${AWS_REGION}" &>/dev/null; then
    echo "Nodegroup 'eks-utils' already exists, skipping."
else
    eksctl create nodegroup -f "${TEMP_CONFIG}"
fi

rm -f "${TEMP_CONFIG}"

# Wait for nodes
echo "Waiting for system nodes..."
for i in $(seq 1 60); do
    READY=$(kubectl get nodes -l "${SYSTEM_LABEL_KEY}=${SYSTEM_LABEL_VALUE}" --no-headers 2>/dev/null | grep -cw Ready || echo 0)
    echo "  Ready: ${READY}/${SYSTEM_NODE_COUNT}"
    [ "${READY}" -ge "${SYSTEM_NODE_COUNT}" ] && break
    sleep 10
done

echo ""
echo "=== System Node Group Created ==="
kubectl get nodes -l "${SYSTEM_LABEL_KEY}=${SYSTEM_LABEL_VALUE}" -o wide
echo ""
echo "Next: ./03-install-addons.sh"
