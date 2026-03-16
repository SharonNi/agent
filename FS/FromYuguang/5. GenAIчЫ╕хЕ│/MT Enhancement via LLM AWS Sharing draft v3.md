# MT Enhancement via LLM — AWS Sharing draft v3

> **原文件：** `s3://huiqingdnbpcustomer/FS/FromYuguang/GenAI/MT Enhancement via LLM AWS Sharing draft v3.pptx`
> **大小：** 71MB | **页数：** 40页
> **来源：** From Yuguang

---

## 概述

给 FS 全球翻译团队的技术方案分享 — 如何用 AWS Bedrock/SageMaker + LLM 替代或增强现有机器翻译流程，降低人工审核成本。

---

## 内容结构

### AWS 简介 (Slide 1-8)

- **参与专家：** 马远科 (Sr. Specialist BD, AI/ML/GenAI GCR GTMS)、马一民 (Principal BD, China Strategic Accounts)、许涛 (Lead Demand Gen Rep)
- **技术专家：** 王鹤男 (Senior Applied Scientist, AI Lab GCR)、谢川 (GenAI Specialist SA GCR)
- AWS 云计算发展史
- GenAI 普惠使命 (Andy Jassy 语录)

### 客户场景理解 (Slide 9-10)

- **AS-IS 现状：**
  - 英文→多语种翻译（对外客户文档 + 内部支持文档）
  - 已有传统机器翻译工具 + 人工最终审核
  - 已积累关键词多语种对照词库
  - 痛点：人工介入程度高，成本优化是核心诉求
- **TO-BE 预期：**
  - 通过 GenAI 优化翻译结果，提升效率、降低人工成本
  - 全球服务团队可用
  - 已成立评估项目（技术方案、架构设计、成本估算）
  - 部署方式和数据安全是重要议题

### GenAI 技术框架 (Slide 11-28)

- 基础模型 vs 传统 ML 模型
- 端到端构建 GenAI 应用的关键路径
- 模型适配方式：Prompt Engineering、RAG、Fine-tuning
- Amazon SageMaker 上的基础模型微调与部署
- 创新工作坊：发现 GenAI 创新场景，通过原型加速方案落地

### 客户案例 (Slide 29-31)

- 某航空行业客户 — 英译中案例
- 某旅行行业客户 — 多语种翻译案例

### 演示 & 平台 (Slide 32-40)

- Amazon Bedrock 构建 GenAI 应用
- 生成式 AI 合作伙伴地图 — ISV / SI
- GenAI 工程化"最后三公里"的挑战
