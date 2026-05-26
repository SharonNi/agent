# GLM-5.1 2P2D Serving on AWS EKS (P5en H200)

## 项目简介

本 Skill 提供了一套完整的、可直接复用的 EKS 生产部署模板，用于在 AWS P5en.48xlarge（H200 GPU）集群上以 Prefill-Decode 分离架构（2P2D）部署 GLM-5.1（671B FP8 MoE，256 experts，202K context）模型。

### 背景

GLM-5.1 原本构建在 InfiniBand RoCE 网络上。MoE 模型的 All-to-All 通信对网络延迟极为敏感，从 IB 迁移到云上 EFA 不是简单的"换一层网络"。本项目通过系统性的对比测试，验证了 EFA 环境下 MoE 大模型推理的可行性，并提供了经过验证的生产部署方案。

### 核心技术栈

| 组件　　　　　　 | 用途　　　　　　　　　　　　　　　 | 版本　　　　　　　　　 |
| ------------------| ------------------------------------| ------------------------|
| SGLang　　　　　 | LLM 推理框架　　　　　　　　　　　 | 0.5.10　　　　　　　　 |
| nixl　　　　　　 | KV cache 传输（LIBFABRIC/EFA）　　 | 1.0.1 (xqun3 fork)　　 |
| Mooncake　　　　 | KV cache 传输（EFA，对比方案）　　 | main branch + CQ patch |
| UCCL-EP / DeepEP | MoE All-to-All expert routing　　　| 8ac850bd　　　　　　　 |
| DeepGEMM　　　　 | FP8 GEMM JIT kernels for Hopper　　| Bundled　　　　　　　　|
| EAGLE　　　　　　| Speculative decoding (decode only) | Built-in　　　　　　　 |
| NSA　　　　　　　| Native Sparse Attention　　　　　　| Built-in　　　　　　　 |

## 部署架构

```
                    ┌─────────────┐
                    │   Client    │
                    └──────┬──────┘
                           │ :8000
                    ┌──────▼──────┐
                    │  PD Router  │  (sglang_router mini-lb)
                    └──┬───────┬──┘
           Prefill     │       │     Decode
        ┌──────────────▼─┐   ┌▼──────────────────┐
        │  Prefill (PP=2) │   │  Decode (TP=16)    │
        │  Node 0: TP=8   │   │  Node 0: DP=16     │
        │  Node 1: TP=8   │   │  Node 1: DP=16     │
        │  NSA attention   │   │  EAGLE speculative  │
        │  DeepEP normal   │   │  DeepEP low_latency │
        └────────┬─────────┘   └───────┬────────────┘
                 │     nixl LIBFABRIC    │
                 └────── KV Transfer ────┘
                      (EFA RDMA)
```

- **4 节点 P5en.48xlarge**：每节点 8×H200 + 16×EFA 网卡
- **Prefill**：2 节点，PP=2，TP=8，DeepEP normal mode，NSA attention
- **Decode**：2 节点，TP=16，DP=16，DeepEP low_latency，EAGLE speculative decoding
- **KV Transfer**：nixl LIBFABRIC backend over EFA

## 文件结构

```
glm51-2p2d-serving/
├── README.md                      ← 本文件
├── SKILL.md                       ← Skill 元数据
├── Dockerfile                     ← 容器镜像构建（SGLang + nixl + UCCL-EP + EFA）
├── plan.md                        ← 执行计划
├── manifests/
│   ├── 00-namespace.yaml          ← K8s namespace
│   ├── 01-prefill-configmap.yaml  ← Prefill launcher 配置
│   ├── 02-decode-configmap.yaml   ← Decode launcher 配置
│   ├── 03-prefill-statefulset.yaml← Prefill StatefulSet（2 replicas）
│   ├── 04-decode-statefulset.yaml ← Decode StatefulSet（2 replicas）
│   └── 05-router.yaml            ← PD Router 部署
└── scripts/
    ├── env.sh                     ← 环境变量配置
    ├── 01-build-image.sh          ← 构建 + 推送镜像到 ECR
    ├── 02-deploy-model-download.sh← S3 → NVMe 模型分发
    ├── 03-deploy-serving.sh       ← 部署推理服务
    └── 04-validate.sh             ← 健康检查 + 冒烟测试
```

## 快速开始

```bash
# 1. 配置环境变量
vim scripts/env.sh

# 2. 构建镜像（可选，已有镜像可跳过）
bash scripts/01-build-image.sh

# 3. 分发模型到各 GPU 节点
bash scripts/02-deploy-model-download.sh

# 4. 部署推理服务
bash scripts/03-deploy-serving.sh

# 5. 验证
bash scripts/04-validate.sh
```

预计时间：
- 已有镜像 + S3 JIT cache：~12 分钟
- 全新构建 + 冷启动 JIT：~65 分钟

## Benchmark：NIXL vs Mooncake KV Transfer Engine

### 测试条件

| 参数 | 值 |
|------|-----|
| 模型 | GLM-5.1 671B FP8 MoE (256 experts) |
| 部署方案 | 1P1D（1 Prefill + 1 Decode） |
| 硬件 | P5en.48xlarge × 2（H200, 16×EFA/node） |
| Input tokens | 120K（固定长度） |
| Output tokens | 1K（固定长度） |
| Request rate | 0.36 req/s |
| Max concurrency | 128 |
| Number of prompts | 128 |
| EFA 分配 | 不分卡（nixl/UCCL-EP 共享 16 张 EFA） |

### 测试结果对比

| 指标 | NIXL (LIBFABRIC) | Mooncake (EFA + CQ patch) | 差异 |
|------|:-----------------:|:-------------------------:|:----:|
| **Successful requests** | 128 | 128 | - |
| **Benchmark duration (s)** | 382.92 | 352.95 | Mooncake 快 8% |
| **Request throughput (req/s)** | 0.33 | 0.36 | Mooncake +9% |
| **Input token throughput (tok/s)** | 40,113 | 43,519 | Mooncake +8.5% |
| **Output throughput (tok/s)** | 342.30 | 362.66 | Mooncake +6% |
| **Peak output throughput (tok/s)** | 176 | 170 | NIXL +3.5% |
| **Peak concurrent requests** | 18 | 20 | Mooncake +11% |
| **Total token throughput (tok/s)** | 40,456 | 43,881 | Mooncake +8.5% |
| **Concurrency** | 10.16 | 11.24 | Mooncake +11% |

#### 延迟对比

| 指标 | NIXL | Mooncake | 差异 |
|------|:----:|:--------:|:----:|
| **Mean E2E Latency (ms)** | 30,405 | 31,006 | NIXL 低 2% |
| **Median E2E Latency (ms)** | 29,637 | 31,367 | NIXL 低 5.5% |
| **P90 E2E Latency (ms)** | 40,786 | 39,300 | Mooncake 低 3.6% |
| **P99 E2E Latency (ms)** | 45,825 | 44,499 | Mooncake 低 3% |
| **Mean TTFT (ms)** | 12,499 | 12,977 | NIXL 低 3.7% |
| **Median TTFT (ms)** | 12,431 | 12,626 | NIXL 低 1.5% |
| **P99 TTFT (ms)** | 27,017 | 25,432 | Mooncake 低 5.9% |
| **Mean TPOT (ms)** | 17.50 | 18.05 | NIXL 低 3% |
| **Median TPOT (ms)** | 17.30 | 17.85 | NIXL 低 3% |
| **P99 TPOT (ms)** | 23.90 | 25.01 | NIXL 低 4.4% |
| **Mean ITL (ms)** | 51.07 | 54.92 | NIXL 低 7% |
| **Median ITL (ms)** | 52.20 | 55.76 | NIXL 低 6.4% |
| **P99 ITL (ms)** | 60.35 | 66.98 | NIXL 低 10% |
| **Max ITL (ms)** | 147.08 | 116.99 | Mooncake 低 20% |

### 结论

在 GLM-5.1 1P1D 120K input 场景下：

1. **吞吐量**：Mooncake 整体吞吐略高于 NIXL（约 8-9%），主要得益于更高的并发度和 input token 处理速率。

2. **延迟**：NIXL 在 token 级延迟（TPOT、ITL）上全面优于 Mooncake（约 3-10%），平均 TTFT 也更低。NIXL 的 decode 阶段逐 token 输出更平稳。

3. **尾部延迟**：P99 E2E 和 P99 TTFT 上 Mooncake 略好；P99 TPOT 和 P99 ITL 上 NIXL 明显更好。Max ITL 方面 Mooncake 更低（117ms vs 147ms）。

4. **稳定性**（参考 DeepSeek-V4-Pro 测试）：在高并发场景下，NIXL 的稳定性大幅优于 Mooncake——100% 成功率 vs 仅 23%，吞吐量高近 5 倍。Mooncake 在高并发时容易出现 KV transfer timeout 和 bootstrap hung 的问题。

5. **工程复杂度**：NIXL 无需额外 patch 即可稳定运行；Mooncake 需要 CQ polling thread patch + yield→sleep 修改才能正常工作。

**综合建议**：对于生产环境，推荐使用 NIXL LIBFABRIC backend。虽然在低并发稳态吞吐上 Mooncake 略有优势，但 NIXL 在延迟一致性、高并发稳定性和工程简洁性上的优势使其更适合生产部署。

## 已知问题与 Workaround

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| DP rank 0 token 断言失败 | UCCL-EP 不允许 topk_idx_ptr=0 | Patch: dispatch 前 pad 1 个 dummy token |
| Disagg decode deadlock | DP=16 时 idle rank 未参与 all_gather | Patch: idle batch 走 num_tokens=0 路径 |
| NIXL libibverbs 冲突 | nixl 自带库与 UCCL-EP 冲突 | 启动时删除 nixl bundled 库 |
| DeepGEMM warmup timeout | 模型 ready 前 DeepEP 超时 | 重启即可，或使用预编译 JIT cache |
| MegaMoE 在 H200 crash | silu_and_mul_masked_post_quant kernel 不兼容 | 不启用 MegaMoE（等待上游修复） |

## EFA 设备分配策略

经测试，对于当前的 1P1D / 2P2D 方案：

- **不分卡**（nixl + UCCL-EP + NCCL 共享 16 张 EFA）的性能与分卡策略相当甚至更好
- 分卡（如 UCCL-EP 8 张 + nixl 8 张）会轻微影响 ITL 延迟
- 建议生产环境使用不分卡方案，简化配置

## 相关资源

- 前置 Skill：`eks-gpu-cluster-setup`（EKS 集群 + GPU 节点组创建）
- 技术细节：https://github.com/yuhuiaws/ML-study/blob/main/生成式AI/Claude-code-Skills/eks-h200-deepseek-v4-pd.skill
