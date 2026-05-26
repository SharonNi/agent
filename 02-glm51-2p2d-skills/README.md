# GLM-5.1 2P2D on EKS — 端到端部署 Skill

从零搭建 EKS GPU 集群，部署 GLM-5.1 (671B FP8 MoE) Prefill-Decode 分离推理服务。

## 目标架构

```
4× p5en.48xlarge (H200 × 8, EFA × 16)
├── 2 Prefill nodes: PP=2, TP=8, NSA, DeepEP normal
├── 2 Decode nodes:  TP=16, DP=16, EAGLE speculative, DeepEP low_latency
└── KV cache transfer: nixl over EFA LIBFABRIC
```

## 前置条件

| 条件 | 说明 |
|------|------|
| AWS CLI v2 | 已配置，权限覆盖 EKS/EC2/IAM/S3/ECR |
| eksctl ≥ 0.200 | 用于创建集群 |
| kubectl + helm v3 | K8s 操作 |
| S3 bucket | 模型权重已上传至 `s3://<bucket>/models/GLM-5.1-FP8/` |
| Region capacity | 目标 region 有 p5en.48xlarge Spot 或 On-Demand 容量 |
| Docker | 构建 SGLang 容器镜像（可选，若 ECR 已有镜像则跳过） |

## 执行流程

### Phase 1: EKS GPU 集群（eks-gpu-cluster-setup）

从 VPC 到 GPU 节点就绪，约 20-30 分钟。

```bash
cd eks-gpu-cluster-setup/scripts

# 配置（必填 AWS_REGION，其余有默认值）
cp .env.example .env
vi .env

# 按顺序执行
bash 01-create-cluster.sh           # VPC + EKS 控制面
bash 01.1-create-vpc-endpoints.sh   # VPC Endpoints（降低 NAT 费用）
bash 01.2-validate-cluster.sh       # 校验集群就绪
bash 02-create-system-nodegroup.sh  # Graviton 系统节点
bash 03-install-addons.sh           # Autoscaler + ALB Controller
bash 04-create-gpu-nodegroup.sh     # GPU 节点（EFA + NVMe LVM）
bash 05-install-device-plugins.sh   # NVIDIA + EFA device plugin
bash 06-validate.sh                 # 验证 GPU/EFA 设备就绪
```

### Phase 2: 模型部署（glm51-2p2d-serving）

部署 2P2D 推理服务，冷启动约 15 分钟（含 DeepGEMM JIT），热启动约 2 分钟。

```bash
cd glm51-2p2d-serving/scripts

# 配置
vi env.sh  # 确认 S3_BUCKET、SGLANG_IMAGE 等

# 按顺序执行
bash 01-build-image.sh              # 构建镜像推送 ECR（可选）
bash 02-deploy-model-download.sh    # S3 → 各节点 NVMe
bash 03-deploy-serving.sh           # 部署 Prefill + Decode + Router
bash 04-validate.sh                 # 健康检查 + 推理测试
```

## 配置说明

两个 skill 各自有 `scripts/env.sh`，核心参数通过 `.env` 文件覆盖：

```bash
# eks-gpu-cluster-setup/scripts/.env
AWS_REGION=ap-northeast-1
CLUSTER_NAME=gpu-eks-cluster
GPU_INSTANCE_TYPE=p5en.48xlarge
GPU_NODE_COUNT=4
GPU_PRICING=Spot
S3_BUCKET=my-model-bucket-123456789012

# glm51-2p2d-serving/scripts/env.sh 读取同名环境变量
```

## 关键技术栈

| 层级 | 组件 | 作用 |
|------|------|------|
| AMI | EKS-optimized AL2023 nvidia | NVIDIA driver 580.x + EFA driver + nvidia-container-toolkit |
| K8s Plugin | NVIDIA device plugin + EFA plugin | 向 kubelet 注册 GPU/EFA 资源 |
| 容器 | SGLang 0.5.10 + nixl 1.0.1 + UCCL-EP | 推理引擎 + KV 传输 + MoE 通信 |
| 调度 | PD Router | Prefill/Decode 请求路由 + 负载均衡 |

## 清理

```bash
# 删除推理服务（保留集群）
kubectl delete namespace glm51-test

# 释放 GPU 节点（保留集群骨架）
aws eks update-nodegroup-config \
  --cluster-name gpu-eks-cluster \
  --nodegroup-name gpu-p5en-spot \
  --scaling-config desiredSize=0,minSize=0,maxSize=8 \
  --region $AWS_REGION

# 完全删除集群（包括 VPC）
eksctl delete cluster --name gpu-eks-cluster --region $AWS_REGION
```

## 目录结构

```
glm51-2p2d-skills/
├── README.md                        ← 本文件
├── eks-gpu-cluster-setup/
│   ├── SKILL.md                     — Skill 元信息
│   ├── ARCHITECTURE.md              — 架构设计详解
│   ├── README.md                    — 详细使用说明
│   └── scripts/                     — 6 步脚本 + env 配置
└── glm51-2p2d-serving/
    ├── SKILL.md                     — Skill 元信息
    ├── README.md                    — 详细使用说明
    ├── Dockerfile                   — SGLang + nixl + UCCL 容器构建
    ├── manifests/                   — K8s YAML（namespace/configmap/statefulset/router）
    └── scripts/                     — 4 步脚本 + env 配置
```
