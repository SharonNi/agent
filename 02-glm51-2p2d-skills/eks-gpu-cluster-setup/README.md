# EKS GPU Cluster Setup

一键创建支持 GPU (P5en/H200) 的 EKS 集群，包含完整网络、系统节点、GPU 节点及设备插件。

## 架构概览

```
┌─────────────────────────────────────────────────────────┐
│  VPC (eksctl auto-created, Single AZ)                   │
│                                                         │
│  ┌─────────────────┐     ┌─────────────────────────┐   │
│  │  Public Subnet  │     │    Private Subnet        │   │
│  │                 │     │                          │   │
│  │  NAT Gateway    │     │  System Nodes (m8g)      │   │
│  │  IGW            │     │  GPU Nodes (p5en, EFA)   │   │
│  └────────┬────────┘     └──────────┬───────────────┘   │
│           │                         │                   │
│           │    ┌────────────────────┘                   │
│           │    │  VPC Endpoints (ecr/s3/eks/sts/...)    │
│           └────┘                                        │
└─────────────────────────────────────────────────────────┘
```

## 前提条件

| 工具 | 最低版本 | 用途 |
|------|----------|------|
| AWS CLI | v2 | AWS API 调用 |
| eksctl | >= 0.200.0 | EKS 集群管理 |
| kubectl | 匹配 K8s 版本 | 集群操作 |
| helm | v3 | ALB Controller 安装 |
| jq | any | JSON 解析 |

AWS 账号需具备 EKS、EC2、IAM、VPC 相关权限。

## 快速开始

### 1. 配置环境变量

```bash
cd scripts/
cp .env.example .env
```

编辑 `.env`，至少填写：

```bash
AWS_REGION=ap-northeast-1
```

可选覆盖（有合理默认值）：

```bash
CLUSTER_NAME=gpu-eks-cluster    # 集群名称
K8S_VERSION=1.35                # Kubernetes 版本
TARGET_AZ=ap-northeast-1a       # 单 AZ（EFA 要求）
GPU_INSTANCE_TYPE=p5en.48xlarge # GPU 实例类型
GPU_NODE_COUNT=4                # GPU 节点数
GPU_PRICING=Spot                # Spot | OnDemand
```

完整变量列表见 `.env.example`。

### 2. 按顺序执行脚本

```bash
# Phase 1: 集群基础设施（~15 min）
./01-create-cluster.sh            # 创建 VPC + EKS 控制面
./01.1-create-vpc-endpoints.sh    # 创建 VPC Endpoints（省流量费）
./01.2-validate-cluster.sh        # 验证集群就绪（网络+addons，自动补装）
./02-create-system-nodegroup.sh   # 创建系统节点组
./03-install-addons.sh            # 安装 Cluster Autoscaler + ALB Controller

# Phase 2: GPU 节点（~10 min）
./04-create-gpu-nodegroup.sh      # 创建 GPU 节点组（EFA + NVMe LVM）
./05-install-device-plugins.sh    # 安装 NVIDIA + EFA device plugins

# Phase 3: 验证（~2 min）
./06-validate.sh                  # 全面验证集群健康
```

总耗时约 **30 分钟**。

### 3. 验证成功

```bash
# GPU 资源
kubectl get nodes -l nvidia.com/gpu=present -o wide

# EFA 资源
kubectl get nodes -o json | jq '.items[].status.allocatable["vpc.amazonaws.com/efa"]'
```

## 环境变量优先级

```
命令行 export > .env 文件 > env.sh 默认值
```

`env.sh` 加载顺序：
1. 读取 `scripts/.env`（如果存在）
2. 应用 `${VAR:-default}` 默认值
3. 命令行中已 export 的变量不会被覆盖

## 脚本说明

| 脚本 | 作用 | 幂等 |
|------|------|------|
| `env.sh` | 环境变量加载（被其他脚本 source） | - |
| `01-create-cluster.sh` | eksctl 创建 VPC + EKS 控制面 | ✅ 已存在则跳过 |
| `01.1-create-vpc-endpoints.sh` | 创建 9 个 Interface + 1 个 S3 Gateway Endpoint | ✅ 已存在则跳过 |
| `01.2-validate-cluster.sh` | 验证网络+addons，缺失 addon 自动补装 | ✅ 只读+自修复 |
| `02-create-system-nodegroup.sh` | Graviton4 系统节点（m8g.xlarge × 1） | ✅ |
| `03-install-addons.sh` | Cluster Autoscaler + ALB Controller (Pod Identity) | ✅ |
| `04-create-gpu-nodegroup.sh` | GPU 节点 Launch Template + Managed Node Group | ✅ |
| `05-install-device-plugins.sh` | NVIDIA + EFA DaemonSet | ✅ |
| `06-validate.sh` | 集群健康检查 | ✅ 只读 |

所有脚本幂等可重跑，已存在的资源会自动跳过。

## 设计决策

| 决策 | 原因 |
|------|------|
| 单 AZ 部署 | EFA/RDMA 要求节点在同 AZ 内通信 |
| eksctl 自动创建 VPC | 实验环境快速拉起，减少前置依赖 |
| NAT Gateway (Single) | 私有子网出公网（拉镜像等），单节点够用于实验 |
| VPC Endpoints | 减少 NAT 流量费（ECR/S3 镜像拉取走内网） |
| EKS API public+private | 方便本地 kubectl 管理，节点内部走 private |
| Pod Identity（非 IRSA） | EKS 新一代 IAM 方案，无需 OIDC Provider |
| Spot 定价 | GPU 实验节省 60-70% 成本 |

## 清理

```bash
# 省钱：GPU 节点缩到 0（保留集群）
aws eks update-nodegroup-config \
  --cluster-name gpu-eks-cluster \
  --nodegroup-name gpu-p5en-spot \
  --scaling-config desiredSize=0,minSize=0,maxSize=8 \
  --region $AWS_REGION

# 彻底删除（集群 + VPC + 所有资源）
eksctl delete cluster --name gpu-eks-cluster --region $AWS_REGION
```

## 故障排查

| 问题 | 排查 |
|------|------|
| eksctl 创建超时 | 检查 CloudFormation console，确认 Service Quota |
| 节点 NotReady | `kubectl describe node` 看 kubelet 日志 |
| GPU 不可见 | 确认 NVIDIA device plugin pod Running |
| EFA 设备数为 0 | 检查 Launch Template 网卡配置 + EFA plugin |
| 镜像拉取慢 | 运行 `01.5` 创建 VPC Endpoints |
| API server 不可达 | `01.6` 验证 public access 是否开启 |
