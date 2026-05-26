# GLM-5.1 2P2D Serving Skill

## Overview

Deploy GLM-5.1 (671B FP8 MoE) in Prefill-Decode disaggregation mode on EKS with 4× p5en.48xlarge (H200) nodes.

Architecture: 2 Prefill nodes (PP=2, TP=8) + 2 Decode nodes (TP=16, DP=16) + PD Router

## Key Technologies

| Component | Purpose | Version |
|-----------|---------|---------|
| SGLang | LLM serving framework | 0.5.10 |
| nixl | KV cache transfer (LIBFABRIC/EFA) | 1.0.1 (xqun3 fork) |
| UCCL-EP / DeepEP | MoE All-to-All expert routing | 8ac850bd |
| DeepGEMM | FP8 GEMM JIT kernels for Hopper | Bundled |
| EAGLE | Speculative decoding (decode only) | Built-in |
| NSA | Native Sparse Attention | Built-in |

## Prerequisites

- EKS cluster with 4× p5en.48xlarge nodes ready (use `eks-gpu-cluster-setup` skill)
- NVIDIA + EFA device plugins installed
- NVMe Instance Store mounted at `/data`
- S3 bucket `glm51-nixl-test-<ACCOUNT_ID>` with:
  - `models/GLM-5.1-FP8/` — Model weights
  - `cache/deep_gemm/` — (optional) Pre-compiled JIT cache

## Configuration

Edit `scripts/env.sh` for your environment:

| Variable | Description | Default |
|----------|-------------|---------|
| `ACCOUNT_ID` | AWS Account ID | (auto-detected) |
| `AWS_REGION` | Region | (required, no default) |
| `CLUSTER_NAME` | EKS cluster name | `gpu-eks-cluster` |
| `NAMESPACE` | K8s namespace | `glm51-test` |
| `S3_BUCKET` | Model + cache bucket | `glm51-nixl-test-<ACCOUNT_ID>` |
| `SGLANG_IMAGE` | Container image | `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/sglang-nixl:latest` |

## Execution Order

```
Phase 1: Image Build (optional — skip if image exists in ECR)
  1. scripts/01-build-image.sh           — Build + push container image to ECR

Phase 2: Model Distribution
  2. scripts/02-deploy-model-download.sh — S3 → NVMe on all 4 GPU nodes

Phase 3: Deploy Serving Stack
  3. scripts/03-deploy-serving.sh        — Prefill + Decode StatefulSets + Router + Cache Sidecar

Phase 4: Validation
  4. scripts/04-validate.sh              — Health check + smoke test query
```

## Architecture Diagram

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

## Startup Timeline

```
T+0:     Pods scheduled, image pull (if not cached)
T+1min:  Containers start, S3 cache restore begins
T+2min:  Cache restored (or JIT begins if no cache)
T+5min:  Model loaded into GPU memory
T+7min:  (warm) Server ready / T+20min: (cold) JIT complete, server ready
```

## DeepGEMM Cache Management

- **Startup**: Restore from S3 (`aws s3 sync` in launcher.sh)
- **Runtime**: Sidecar syncs `/data/sglang/deep_gemm/` to S3 every 5 minutes
- **Cold start without cache**: ~15 min JIT compilation (278 prefill / 251 decode kernels)
- **Warm start with cache**: <2 min (just loading .cubin files)

## Important Notes

- Pod anti-affinity ensures prefill pods on different nodes (same for decode)
- nixl uses EFA LIBFABRIC backend (not UCX) for KV cache transfer
- UCCL and nixl share all 16 EFA devices (no device split)
- `terminationGracePeriodSeconds=120` for Spot interrupt handling
- DeepGEMM sidecar uses `--size-only` for efficient S3 sync

## Teardown

```bash
# Delete workloads (keep cluster + nodes)
kubectl delete namespace glm51-test

# Scale down GPU nodes (release Spot)
aws eks update-nodegroup-config \
  --cluster-name gpu-eks-cluster \
  --nodegroup-name gpu-p5en-spot \
  --scaling-config desiredSize=0,minSize=0,maxSize=8 \
  --region $AWS_REGION
```
