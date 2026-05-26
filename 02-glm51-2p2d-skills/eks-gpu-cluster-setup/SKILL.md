# EKS GPU Cluster Setup Skill

## Overview

Create a production-ready EKS cluster with GPU (P5en/H200) node support on AWS.
This skill provisions the entire infrastructure stack from VPC to GPU-ready nodes.

## Target Architecture

- EKS cluster with private API endpoint
- Single-AZ deployment for EFA/RDMA topology requirements
- GPU nodes: p5en.48xlarge (Spot) with EFA + local NVMe Instance Store
- System nodes: Graviton4 (m8g.xlarge) for control plane workloads
- Cluster Autoscaler + ALB Controller installed

## Prerequisites

- AWS CLI v2 configured with appropriate permissions
- eksctl >= 0.200.0
- kubectl
- helm v3
- jq
- Target region with p5en.48xlarge Spot capacity

## Configuration

All configuration is done via `scripts/env.sh`. Key variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `CLUSTER_NAME` | EKS cluster name | `gpu-eks-cluster` |
| `AWS_REGION` | Deployment region | (required, no default) |
| `ACCOUNT_ID` | AWS Account ID | (auto-detected) |
| `K8S_VERSION` | Kubernetes version | `1.35` |
| `GPU_INSTANCE_TYPE` | GPU instance type | `p5en.48xlarge` |
| `GPU_NODE_COUNT` | Desired GPU nodes | `4` |
| `GPU_PRICING` | Spot or OnDemand | `Spot` |

## Execution Order

```
Phase 1: Cluster Infrastructure
  1.  scripts/01-create-cluster.sh          — VPC + EKS control plane (eksctl auto-creates VPC)
  1.1 scripts/01.1-create-vpc-endpoints.sh  — VPC Endpoints (reduce NAT traffic costs)
  1.2 scripts/01.2-validate-cluster.sh     — Validate cluster readiness (network + addons, auto-repair)
  2.  scripts/02-create-system-nodegroup.sh  — System nodes with LVM for containerd
  3.  scripts/03-install-addons.sh           — Cluster Autoscaler, ALB Controller, Metrics Server

Phase 2: GPU Node Group
  4. scripts/04-create-gpu-nodegroup.sh   — Launch Template + Managed Node Group (EFA + NVMe LVM)
  5. scripts/05-install-device-plugins.sh — NVIDIA + EFA device plugins

Phase 3: Validation
  6. scripts/06-validate.sh              — Cluster health, GPU/EFA device verification
```

## Important Notes

- eksctl auto-creates VPC + subnets + NAT Gateway; no separate VPC creation needed
- VPC Endpoints (Step 1.5) route AWS API traffic within VPC, avoiding NAT data transfer costs
- Single AZ is enforced via `availabilityZones` in eksctl config for EFA topology
- GPU AMI is auto-resolved from SSM Parameter Store (EKS-optimized AL2023 + NVIDIA driver)
- Node IAM role gets Pod Identity support for S3/ECR access from workloads
- `terminationGracePeriodSeconds` should be set to 120s for Spot interrupt handling

## Teardown

```bash
# Scale GPU nodes to 0 (release Spot capacity, keep cluster)
aws eks update-nodegroup-config \
  --cluster-name gpu-eks-cluster \
  --nodegroup-name gpu-p5en-spot \
  --scaling-config desiredSize=0,minSize=0,maxSize=8 \
  --region $AWS_REGION

# Full cluster deletion (destroys everything including VPC)
eksctl delete cluster --name gpu-eks-cluster --region $AWS_REGION
```
