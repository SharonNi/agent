#!/bin/bash
# =============================================================================
# Step 3: Install Cluster Addons
# - Cluster Autoscaler (with Pod Identity)
# - AWS Load Balancer Controller (with Pod Identity)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

echo "=== Installing Cluster Addons ==="

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

# --- Cluster Autoscaler Pod Identity ---
echo ""
echo "Step 3.1: Setting up Cluster Autoscaler..."

CA_SA_NAME="cluster-autoscaler"
CA_NAMESPACE="kube-system"
CA_ROLE_NAME="${CLUSTER_NAME}-cluster-autoscaler"

# Create IAM policy for Cluster Autoscaler
CA_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CA_ROLE_NAME}-policy"
if ! aws iam get-policy --policy-arn "${CA_POLICY_ARN}" &>/dev/null; then
    aws iam create-policy --policy-name "${CA_ROLE_NAME}-policy" --policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeScalingActivities",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup",
                "ec2:DescribeImages",
                "ec2:DescribeInstanceTypes",
                "ec2:DescribeLaunchTemplateVersions",
                "ec2:GetInstanceTypesFromInstanceRequirements",
                "eks:DescribeNodegroup"
            ],
            "Resource": "*"
        }]
    }'
fi

# Create IAM role for Pod Identity
if ! aws iam get-role --role-name "${CA_ROLE_NAME}" &>/dev/null; then
    aws iam create-role --role-name "${CA_ROLE_NAME}" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "pods.eks.amazonaws.com"},
                "Action": ["sts:AssumeRole", "sts:TagSession"]
            }]
        }'
    aws iam attach-role-policy --role-name "${CA_ROLE_NAME}" --policy-arn "${CA_POLICY_ARN}"
fi

# Create ServiceAccount
kubectl create serviceaccount "${CA_SA_NAME}" -n "${CA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Create Pod Identity Association
aws eks create-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace "${CA_NAMESPACE}" \
    --service-account "${CA_SA_NAME}" \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${CA_ROLE_NAME}" \
    --region "${AWS_REGION}" 2>/dev/null || echo "Pod Identity association may already exist"

# Deploy Cluster Autoscaler
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-autoscaler
rules:
  - apiGroups: [""]
    resources: ["events", "endpoints"]
    verbs: ["create", "patch"]
  - apiGroups: [""]
    resources: ["pods/eviction"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/status"]
    verbs: ["update"]
  - apiGroups: [""]
    resources: ["endpoints"]
    resourceNames: ["cluster-autoscaler"]
    verbs: ["get", "update"]
  - apiGroups: [""]
    resources: ["nodes", "pods", "services", "replicationcontrollers", "persistentvolumeclaims", "persistentvolumes", "namespaces"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["extensions", "apps"]
    resources: ["replicasets", "daemonsets", "statefulsets"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["watch", "list"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "csinodes", "csidrivers", "csistoragecapacities"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create", "get", "list", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-autoscaler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-autoscaler
subjects:
  - kind: ServiceAccount
    name: ${CA_SA_NAME}
    namespace: ${CA_NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-autoscaler
  namespace: ${CA_NAMESPACE}
  labels:
    app: cluster-autoscaler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-autoscaler
  template:
    metadata:
      labels:
        app: cluster-autoscaler
    spec:
      serviceAccountName: ${CA_SA_NAME}
      nodeSelector:
        ${SYSTEM_LABEL_KEY}: "${SYSTEM_LABEL_VALUE}"
      containers:
        - name: cluster-autoscaler
          image: registry.k8s.io/autoscaling/cluster-autoscaler:${CLUSTER_AUTOSCALER_VERSION}
          command:
            - ./cluster-autoscaler
            - --v=4
            - --stderrthreshold=info
            - --cloud-provider=aws
            - --skip-nodes-with-local-storage=false
            - --expander=least-waste
            - --node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/${CLUSTER_NAME}
            - --balance-similar-node-groups
            - --skip-nodes-with-system-pods=false
          resources:
            requests:
              cpu: 100m
              memory: 300Mi
            limits:
              memory: 600Mi
EOF

kubectl wait --for=condition=available --timeout=300s deployment/cluster-autoscaler -n kube-system
echo "Cluster Autoscaler deployed."

# --- AWS Load Balancer Controller ---
echo ""
echo "Step 3.2: Setting up AWS Load Balancer Controller..."

ALB_ROLE_NAME="${CLUSTER_NAME}-alb-controller"
ALB_SA_NAME="aws-load-balancer-controller"

# Download IAM policy
ALB_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${ALB_ROLE_NAME}-policy"
if ! aws iam get-policy --policy-arn "${ALB_POLICY_ARN}" &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json \
        -o /tmp/alb-policy.json
    aws iam create-policy --policy-name "${ALB_ROLE_NAME}-policy" \
        --policy-document file:///tmp/alb-policy.json
    rm -f /tmp/alb-policy.json
fi

if ! aws iam get-role --role-name "${ALB_ROLE_NAME}" &>/dev/null; then
    aws iam create-role --role-name "${ALB_ROLE_NAME}" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "pods.eks.amazonaws.com"},
                "Action": ["sts:AssumeRole", "sts:TagSession"]
            }]
        }'
    aws iam attach-role-policy --role-name "${ALB_ROLE_NAME}" --policy-arn "${ALB_POLICY_ARN}"
fi

kubectl create serviceaccount "${ALB_SA_NAME}" -n kube-system --dry-run=client -o yaml | kubectl apply -f -

aws eks create-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace kube-system \
    --service-account "${ALB_SA_NAME}" \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/${ALB_ROLE_NAME}" \
    --region "${AWS_REGION}" 2>/dev/null || echo "Pod Identity association may already exist"

# Get VPC ID for helm values
VPC_ID=$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update eks

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="${CLUSTER_NAME}" \
    --set serviceAccount.create=false \
    --set serviceAccount.name="${ALB_SA_NAME}" \
    --set vpcId="${VPC_ID}" \
    --set region="${AWS_REGION}" \
    --set "nodeSelector.${SYSTEM_LABEL_KEY}=${SYSTEM_LABEL_VALUE}" \
    --set replicaCount=1 \
    --version "${ALB_CONTROLLER_CHART_VERSION}"

kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system
echo "ALB Controller deployed."

echo ""
echo "=== Addons Installation Complete ==="
echo "  Cluster Autoscaler: Running"
echo "  ALB Controller: Running"
echo ""
echo "Next: ./04-create-gpu-nodegroup.sh"
