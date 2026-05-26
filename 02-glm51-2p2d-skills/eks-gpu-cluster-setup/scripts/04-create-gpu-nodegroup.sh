#!/bin/bash
# =============================================================================
# Step 4: Create GPU Node Group with EFA + Local NVMe Instance Store
# Supports: p5en.48xlarge (default), p5.48xlarge, p6-b200, g7e.48xlarge
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Creating GPU Node Group: ${GPU_NODEGROUP_NAME} ==="

# Verify cluster
aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null || {
    echo "ERROR: Cluster not found. Run steps 01-03 first."
    exit 1
}

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# Get cluster info
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)
CLUSTER_SG_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
CLUSTER_ENDPOINT=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.endpoint' --output text)
CLUSTER_CA=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.certificateAuthority.data' --output text)
CLUSTER_SVC_CIDR=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.kubernetesNetworkConfig.serviceIpv4Cidr' --output text)

# Get private subnet in target AZ
PRIVATE_SUBNET=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=availability-zone,Values=${TARGET_AZ}" "Name=map-public-ip-on-launch,Values=false" \
    --query 'Subnets[0].SubnetId' --output text --region "${AWS_REGION}")

echo "VPC: ${VPC_ID}"
echo "Cluster SG: ${CLUSTER_SG_ID}"
echo "Private Subnet (${TARGET_AZ}): ${PRIVATE_SUBNET}"

# --- EFA interface count by instance type ---
get_efa_only_count() {
    case "$1" in
        p5.48xlarge)      echo 31 ;;
        p5en.48xlarge)    echo 15 ;;
        p6-b200.48xlarge) echo 7 ;;
        p6-b300.48xlarge) echo 16 ;;
        g7e.48xlarge)     echo 3 ;;
        g6e.48xlarge)     echo 3 ;;
        *)                echo 0 ;;
    esac
}

EFA_ONLY_COUNT=$(get_efa_only_count "${GPU_INSTANCE_TYPE}")
echo "EFA-only interfaces: ${EFA_ONLY_COUNT}"

# --- GPU IAM Role ---
echo ""
echo "Step 4.1: Creating GPU node IAM role..."
GPU_ROLE_NAME="GPUNodeRole-${CLUSTER_NAME}"

if ! aws iam get-role --role-name "${GPU_ROLE_NAME}" &>/dev/null; then
    aws iam create-role --role-name "${GPU_ROLE_NAME}" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }' --tags Key=Cluster,Value="${CLUSTER_NAME}"
fi

for POLICY in AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly AmazonSSMManagedInstanceCore; do
    aws iam attach-role-policy --role-name "${GPU_ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/${POLICY}" 2>/dev/null || true
done

aws iam put-role-policy --role-name "${GPU_ROLE_NAME}" \
    --policy-name "NodeadmDescribeInstances" \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"],
            "Resource": "*"
        }]
    }'

# S3 access for model download and DeepGEMM cache
S3_BUCKET="${S3_BUCKET}"
aws iam put-role-policy --role-name "${GPU_ROLE_NAME}" \
    --policy-name "S3ModelAccess" \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Action\": [\"s3:GetObject\", \"s3:ListBucket\", \"s3:PutObject\", \"s3:DeleteObject\"],
            \"Resource\": [\"arn:aws:s3:::${S3_BUCKET}\", \"arn:aws:s3:::${S3_BUCKET}/*\"]
        }]
    }"

# EKS access entry
if ! aws eks describe-access-entry --cluster-name "${CLUSTER_NAME}" \
    --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GPU_ROLE_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "Waiting for IAM propagation..."
    sleep 10
    aws eks create-access-entry --cluster-name "${CLUSTER_NAME}" \
        --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/${GPU_ROLE_NAME}" \
        --type EC2_LINUX --region "${AWS_REGION}"
fi

echo "GPU IAM Role ready: ${GPU_ROLE_NAME}"

# --- GPU Security Group ---
echo ""
echo "Step 4.2: Creating GPU security group..."
GPU_SG_NAME="${CLUSTER_NAME}-gpu-sg"

GPU_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${GPU_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null)

if [ -z "${GPU_SG_ID}" ] || [ "${GPU_SG_ID}" = "None" ]; then
    GPU_SG_ID=$(aws ec2 create-security-group \
        --group-name "${GPU_SG_NAME}" \
        --description "GPU nodes EFA full-mesh" \
        --vpc-id "${VPC_ID}" --region "${AWS_REGION}" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${GPU_SG_NAME}},{Key=Cluster,Value=${CLUSTER_NAME}}]" \
        --query 'GroupId' --output text)
fi

# Self-referencing ingress for EFA
aws ec2 authorize-security-group-ingress --group-id "${GPU_SG_ID}" \
    --protocol -1 --source-group "${GPU_SG_ID}" --region "${AWS_REGION}" 2>/dev/null || true

echo "GPU SG: ${GPU_SG_ID}"

# --- GPU AMI ---
echo ""
echo "Step 4.3: Getting GPU AMI..."
GPU_AMI_ID=$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${K8S_VERSION}/amazon-linux-2023/x86_64/nvidia/recommended/image_id" \
    --region "${AWS_REGION}" --query 'Parameter.Value' --output text)
echo "GPU AMI: ${GPU_AMI_ID}"

# --- Launch Template ---
echo ""
echo "Step 4.4: Creating Launch Template..."

# Generate user-data with LVM for containerd (EBS) + local NVMe Instance Store
USERDATA_FILE="/tmp/gpu-userdata-$$.txt"
cat > "${USERDATA_FILE}" <<'UDEOF'
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="==BOUNDARY=="

--==BOUNDARY==
Content-Type: text/cloud-boothook; charset="us-ascii"

#!/bin/bash
set -ex
exec > >(tee /var/log/gpu-node-bootstrap.log) 2>&1

echo "=== GPU Node LVM Setup ==="
systemctl stop containerd || true

# Find EBS data disk (not Instance Store, not root)
for i in $(seq 1 60); do
  for sys_path in /sys/block/nvme*n1; do
    [ -e "$sys_path" ] || continue
    MODEL=$(cat "$sys_path/device/model" 2>/dev/null | xargs)
    case "$MODEL" in *"Elastic Block Store"*) ;; *) continue ;; esac
    dev="/dev/$(basename "$sys_path")"
    PARTS=$(lsblk -no NAME "$dev" 2>/dev/null | wc -l)
    if [ "$PARTS" -eq 1 ]; then
      DISK="$dev"
      break 2
    fi
  done
  sleep 1
done

if [ -z "${DISK:-}" ]; then
  echo "No EBS data disk found"
  systemctl start containerd
else
  if vgs vg_data &>/dev/null; then
    mount /dev/vg_data/lv_containerd /var/lib/containerd || true
  else
    dnf install -y lvm2 rsync
    pvcreate "$DISK"
    vgcreate vg_data "$DISK"
    lvcreate -l 100%VG -n lv_containerd vg_data
    mkfs.xfs /dev/vg_data/lv_containerd
    mkdir -p /mnt/runtime/containerd
    mount /dev/vg_data/lv_containerd /mnt/runtime/containerd
    rsync -aHAX /var/lib/containerd/ /mnt/runtime/containerd/ || true
    umount /mnt/runtime/containerd
    mount /dev/vg_data/lv_containerd /var/lib/containerd
    grep -q "lv_containerd" /etc/fstab || \
      echo "/dev/vg_data/lv_containerd /var/lib/containerd xfs defaults,nofail 0 2" >> /etc/fstab
  fi
  systemctl start containerd
fi

echo "=== Local NVMe Instance Store LVM ==="
command -v lvcreate >/dev/null || dnf install -y lvm2

VG_NAME="__VG_NAME__"
LV_NAME="__LV_NAME__"
MOUNT_POINT="__MOUNT_POINT__"

LOCAL_DISKS=()
for sys_path in /sys/block/nvme*n1; do
  [ -e "$sys_path" ] || continue
  model=$(cat "$sys_path/device/model" 2>/dev/null | xargs)
  case "$model" in *"Instance Storage"*) LOCAL_DISKS+=("/dev/$(basename "$sys_path")") ;; esac
done

if [ ${#LOCAL_DISKS[@]} -gt 0 ]; then
  mkdir -p "$MOUNT_POINT"
  if ! mountpoint -q "$MOUNT_POINT"; then
    if vgs "$VG_NAME" >/dev/null 2>&1; then
      vgchange -ay "$VG_NAME"
      mount -o noatime,nodiratime,discard "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"
    else
      for d in "${LOCAL_DISKS[@]}"; do
        wipefs -a "$d" || true
        pvcreate -ff -y "$d"
      done
      vgcreate "$VG_NAME" "${LOCAL_DISKS[@]}"
      if [ ${#LOCAL_DISKS[@]} -gt 1 ]; then
        lvcreate -y -i "${#LOCAL_DISKS[@]}" -I 256 -l 100%FREE -n "$LV_NAME" "$VG_NAME"
      else
        lvcreate -y -l 100%FREE -n "$LV_NAME" "$VG_NAME"
      fi
      mkfs.xfs -f "/dev/$VG_NAME/$LV_NAME"
      mount -o noatime,nodiratime,discard "/dev/$VG_NAME/$LV_NAME" "$MOUNT_POINT"
      chmod 1777 "$MOUNT_POINT"
    fi
  fi
  echo "Local NVMe mounted at $MOUNT_POINT"
  df -h "$MOUNT_POINT"
fi

echo "=== EKS Node Bootstrap ==="
mkdir -p /etc/eks/nodeadm.d
cat > /etc/eks/nodeadm.d/nodeconfig.yaml <<NODECONFIG
---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: __CLUSTER_NAME__
    apiServerEndpoint: __CLUSTER_ENDPOINT__
    certificateAuthority: __CLUSTER_CA__
    cidr: __CLUSTER_SVC_CIDR__
NODECONFIG

nodeadm init --config-source file:///etc/eks/nodeadm.d/nodeconfig.yaml
systemctl enable kubelet containerd
echo "=== GPU Node Bootstrap Complete ==="

--==BOUNDARY==--
UDEOF

# Substitute placeholders
sed -i \
    -e "s|__VG_NAME__|${GPU_LVM_VG}|g" \
    -e "s|__LV_NAME__|${GPU_LVM_LV}|g" \
    -e "s|__MOUNT_POINT__|${GPU_LVM_MOUNT}|g" \
    -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
    -e "s|__CLUSTER_ENDPOINT__|${CLUSTER_ENDPOINT}|g" \
    -e "s|__CLUSTER_CA__|${CLUSTER_CA}|g" \
    -e "s|__CLUSTER_SVC_CIDR__|${CLUSTER_SVC_CIDR}|g" \
    "${USERDATA_FILE}"

USERDATA_B64=$(base64 -w 0 < "${USERDATA_FILE}")
rm -f "${USERDATA_FILE}"

# Generate Launch Template JSON with EFA network interfaces
LT_NAME="${CLUSTER_NAME}-gpu-${GPU_INSTANCE_TYPE//./-}-lt"
LT_DATA_FILE="/tmp/gpu-lt-data-$$.json"

python3 - <<PYSCRIPT > "${LT_DATA_FILE}"
import json

ami_id = "${GPU_AMI_ID}"
gpu_sg_id = "${GPU_SG_ID}"
cluster_sg_id = "${CLUSTER_SG_ID}"
efa_only_count = ${EFA_ONLY_COUNT}
instance_type = "${GPU_INSTANCE_TYPE}"
userdata_b64 = "${USERDATA_B64}"
root_volume = ${GPU_ROOT_VOLUME_SIZE}
data_volume = ${GPU_DATA_VOLUME_SIZE}

# Network interfaces
nis = []

# Primary NIC: EFA for most types, plain interface for p6-b300
primary_type = "interface" if instance_type == "p6-b300.48xlarge" else "efa"
nis.append({
    "NetworkCardIndex": 0,
    "DeviceIndex": 0,
    "InterfaceType": primary_type,
    "DeleteOnTermination": True,
    "Groups": [gpu_sg_id, cluster_sg_id],
})

# EFA-only NICs
for nci in range(1, efa_only_count + 1):
    nis.append({
        "NetworkCardIndex": nci,
        "DeviceIndex": 1,
        "InterfaceType": "efa-only",
        "DeleteOnTermination": True,
        "Groups": [gpu_sg_id, cluster_sg_id],
    })

lt_data = {
    "ImageId": ami_id,
    "UserData": userdata_b64,
    "NetworkInterfaces": nis,
    "BlockDeviceMappings": [
        {"DeviceName": "/dev/xvda", "Ebs": {"VolumeSize": root_volume, "VolumeType": "gp3", "Encrypted": True, "DeleteOnTermination": True}},
        {"DeviceName": "/dev/xvdb", "Ebs": {"VolumeSize": data_volume, "VolumeType": "gp3", "Iops": 3000, "Throughput": 125, "Encrypted": True, "DeleteOnTermination": True}},
    ],
    "MetadataOptions": {"HttpEndpoint": "enabled", "HttpTokens": "required", "HttpPutResponseHopLimit": 2},
    "TagSpecifications": [
        {"ResourceType": "instance", "Tags": [
            {"Key": "Name", "Value": "${CLUSTER_NAME}-gpu-node"},
            {"Key": "kubernetes.io/cluster/${CLUSTER_NAME}", "Value": "owned"},
        ]},
    ],
}

print(json.dumps(lt_data))
PYSCRIPT

if aws ec2 describe-launch-templates --launch-template-names "${LT_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    LT_ID=$(aws ec2 describe-launch-templates --launch-template-names "${LT_NAME}" \
        --region "${AWS_REGION}" --query 'LaunchTemplates[0].LaunchTemplateId' --output text)
    LT_VERSION=$(aws ec2 create-launch-template-version --launch-template-id "${LT_ID}" \
        --launch-template-data "file://${LT_DATA_FILE}" --region "${AWS_REGION}" \
        --query 'LaunchTemplateVersion.VersionNumber' --output text)
else
    LT_RESULT=$(aws ec2 create-launch-template --launch-template-name "${LT_NAME}" \
        --launch-template-data "file://${LT_DATA_FILE}" --region "${AWS_REGION}" --output json)
    LT_ID=$(echo "${LT_RESULT}" | jq -r '.LaunchTemplate.LaunchTemplateId')
    LT_VERSION=$(echo "${LT_RESULT}" | jq -r '.LaunchTemplate.LatestVersionNumber')
fi

rm -f "${LT_DATA_FILE}"
echo "Launch Template: ${LT_ID} v${LT_VERSION}"

# --- Create Managed Node Group ---
echo ""
echo "Step 4.5: Creating managed node group..."

# Determine market options
CAPACITY_TYPE="ON_DEMAND"
if [ "${GPU_PRICING}" = "Spot" ]; then
    CAPACITY_TYPE="SPOT"
fi

if aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${GPU_NODEGROUP_NAME}" --region "${AWS_REGION}" &>/dev/null; then
    echo "Node group '${GPU_NODEGROUP_NAME}' already exists."
    echo "To update scaling: aws eks update-nodegroup-config --cluster-name ${CLUSTER_NAME} --nodegroup-name ${GPU_NODEGROUP_NAME} --scaling-config desiredSize=${GPU_NODE_COUNT},minSize=${GPU_NODE_MIN},maxSize=${GPU_NODE_MAX} --region ${AWS_REGION}"
else
    aws eks create-nodegroup \
        --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${GPU_NODEGROUP_NAME}" \
        --node-role "arn:aws:iam::${ACCOUNT_ID}:role/${GPU_ROLE_NAME}" \
        --subnets "${PRIVATE_SUBNET}" \
        --instance-types "${GPU_INSTANCE_TYPE}" \
        --capacity-type "${CAPACITY_TYPE}" \
        --scaling-config "desiredSize=${GPU_NODE_COUNT},minSize=${GPU_NODE_MIN},maxSize=${GPU_NODE_MAX}" \
        --launch-template "id=${LT_ID},version=${LT_VERSION}" \
        --labels "nvidia.com/gpu.present=true,node.kubernetes.io/instance-type=${GPU_INSTANCE_TYPE}" \
        --taints "key=nvidia.com/gpu,value=true,effect=NO_SCHEDULE" \
        --tags "k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/${CLUSTER_NAME}=owned" \
        --region "${AWS_REGION}"

    echo "Waiting for node group creation..."
    aws eks wait nodegroup-active --cluster-name "${CLUSTER_NAME}" \
        --nodegroup-name "${GPU_NODEGROUP_NAME}" --region "${AWS_REGION}"
fi

# Wait for nodes
echo "Waiting for GPU nodes to be Ready..."
for i in $(seq 1 90); do
    READY=$(kubectl get nodes -l "node.kubernetes.io/instance-type=${GPU_INSTANCE_TYPE}" --no-headers 2>/dev/null | grep -cw Ready || echo 0)
    echo "  GPU nodes Ready: ${READY}/${GPU_NODE_COUNT}"
    [ "${READY}" -ge "${GPU_NODE_COUNT}" ] && break
    sleep 10
done

echo ""
echo "=== GPU Node Group Created ==="
kubectl get nodes -l "node.kubernetes.io/instance-type=${GPU_INSTANCE_TYPE}" -o wide
echo ""
echo "Next: ./05-install-device-plugins.sh"
