---
name: local-ocr-anonymize
description: Use when Hermes on macOS needs to OCR local PDF or image files, create searchable PDF/A and Markdown, batch-process scanned Chinese documents, or anonymize sensitive legal data — all using macOS Vision framework and local Ollama (100% offline, no cloud, no Windows VM required).
license: MIT
metadata:
  hermes:
    version: 2.1.0
    platforms: [macos]
    tags: [OCR, PDF, PDFA, Markdown, Chinese, Legal-Documents, Vision, macOS-native, Anonymization, Ollama, Privacy]
    related_skills: [ocr-and-documents]
    requires_toolsets: [terminal]
---

# 本地 OCR（macOS Vision 引擎 + Ollama 智能脱敏）

## Overview

使用 macOS 内置 Vision 框架对本地 PDF 或图片进行 OCR，生成 `*.md` 与可搜索的 `*.pdfa.pdf`。所有处理均在本机完成，不上传网络，无需微信、无需 Windows 虚拟机。

加上 `--anonymize` 后，OCR 完成时自动通过本地 Ollama 对每份 Markdown 执行语义脱敏：姓名替换为 `[张某甲]`、身份证号替换为 `[身份证号X]` 等，全程不出局域网。

首次运行会自动编译 Swift OCR 引擎（约 30–60 秒），之后无需重新编译。

## Quick Reference

| 任务 | 命令 |
|---|---|
| 单个文件 | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh "/绝对路径/材料.pdf"` |
| 批量目录 | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh --continue-on-error "/绝对路径/材料目录"` |
| 递归目录 | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh --recursive --continue-on-error "/绝对路径/材料目录"` |
| 指定 DPI | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh --dpi 300 "/绝对路径/材料.pdf"` |
| **OCR + 脱敏** | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh --anonymize "/绝对路径/材料.pdf"` |
| **脱敏（指定模型）** | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh --anonymize --anonymize-model qwen2.5:7b "/绝对路径/材料.pdf"` |
| **脱敏 + 去页码** | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh --anonymize --anonymize-model deepseek-r1:32b --merge-pages "/绝对路径/材料.pdf"` |
| 仅去页码 | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh --merge-pages "/绝对路径/材料.pdf"` |
| 预检（含脱敏参数） | `~/.hermes/skills/productivity/local-ocr-anonymize/scripts/run_mac_ocr.sh --anonymize --merge-pages --dry-run "/绝对路径/材料.pdf"` |

支持 `.pdf`、`.png`、`.jpg`、`.jpeg`、`.bmp`、`.tiff`、`.tif`、`.webp`、`.gif`。目录模式只处理这些格式。

## Procedure

1. 确认输入是用户明确指定的本地文件或目录；输入不明确时先询问，不猜测路径。
2. 对单文件直接运行包装脚本。对目录按用户要求决定是否增加 `--recursive`；批量处理默认增加 `--continue-on-error`，避免一个坏文件中断整批。
3. 用户明确提到"脱敏"、"隐私"、"遮盖"、"保密"等需求时，追加 `--anonymize`；如用户指定模型，同时追加 `--anonymize-model <模型名>`。用户提到"去页码"、"连续文本"、"合并页面"时，追加 `--merge-pages`。
4. 脚本会在 `~/.hermes/cache/local-ocr-anonymize/jobs/` 创建隔离作业目录，将输入复制到其中。不得直接修改源文件。
5. 成功后读取脚本输出的 `result.json`，向用户报告作业目录、Markdown 文件和 PDF/A 文件的绝对路径。不要输出整份 OCR 正文，除非用户明确要求。
6. 批量任务应同时报告成功数、失败数及错误文件；不得把部分成功表述为全部完成。

## Ollama Anonymization

### 前提条件

- 本地已安装并运行 [Ollama](https://ollama.com)（`open -a Ollama`）
- 已拉取目标模型：`ollama pull gemma3:latest`（或其他中文理解能力较强的模型）
- 默认模型：`gemma3:latest`；通过环境变量或 `--anonymize-model` 覆盖

### 工作流程

```
PDF / 图片
    ↓ macOS Vision OCR
raw.md（含真实姓名、证件号等）
    ↓ Ollama /api/chat（本地，无网络）
anonymized.md（[张某甲]、[身份证号X] 等占位符）
```

脱敏在每个文件 OCR 完成后立即执行，原地覆盖 `.md`；PDF/A 保持原始 OCR 文本不变。

### 脱敏规则（内置 System Prompt）

| 敏感实体 | 替换示例 |
|---|---|
| 自然人姓名 | `[张某甲]`、`[李某乙]` |
| 代理律师姓名 | `[代理律师A]` |
| 律所名称 | `[某律师事务所]` |
| 企业/公司名称 | `[某技术公司]`、`[某商贸公司]` |
| 18 位身份证号 | `[身份证号X]` |
| 手机号 / 固话 | `[电话X]` |
| 银行卡号 / 账号 | `[账号X]` |
| 具体门牌住址 | `[住址X]` |
| 电子邮件 | `[邮箱X]` |

**保留不变：** 案件事实、证据描述、涉案金额、法律条文、日期、案号、Markdown 排版结构。同一人物在全文使用同一占位符，保持逻辑一致性。

### 推荐模型

| 模型 | 中文能力 | 速度 | 显存占用 |
|---|---|---|---|
| `gemma3:latest` | 良好 | 快 | ~5 GB |
| `qwen2.5:7b` | 优秀 | 中 | ~5 GB |
| `qwen2.5:14b` | 极佳 | 慢 | ~9 GB |

M4 Pro 统一内存充裕，`qwen2.5:14b` 对复杂诉讼材料脱敏精度最高。

## First-run Behavior

首次运行（或 OCR 引擎源码更新后）会自动调用 `swiftc` 编译 Swift OCR 引擎：

1. 如未安装 Xcode 命令行工具，先运行 `xcode-select --install`；
2. 编译完成后，OCR 引擎缓存于 `~/.hermes/cache/mac_vision_ocr`，后续无需重编译；
3. 对每个输入文件调用 Vision OCR，中简/中繁/英文自动识别；
4. 结果写入作业目录的 `output/` 子目录。

## Verification

只有同时满足以下条件才报告成功：

- 包装脚本退出状态为 `0`；
- 作业目录存在 `result.json`，其中 `"success": true`；
- `output/` 至少存在一个非空 `*.md`；
- `output/` 至少存在一个非空 `*.pdfa.pdf`。

开启脱敏时，额外确认 `result.json` 中 `"anonymize_applied": true`。

若任一条件不满足，报告失败并引用终端中的最短必要错误；不得猜测 OCR 已完成。

## Privacy and Safety

- 所有处理均在本机完成，不通过网页、云 OCR、消息平台或第三方 API 传输文档。
- `--anonymize` 调用的是本地 Ollama，文档内容仅在物理机内部流转，不离开局域网。
- 不把身份证号、完整手机号、案号、客户姓名或文书全文写入回复或长期日志。
- 未开启 `--anonymize` 时，OCR 输出的 Markdown 含原始敏感信息，展示或转发前须手动脱敏。
- 不删除源文件。只允许清理由本技能创建且路径位于 `~/.hermes/cache/local-ocr-anonymize/jobs/` 的作业目录。

## Common Mistakes

1. **编译失败。** 若 `swiftc not found`，先运行 `xcode-select --install` 安装 Xcode 命令行工具。
2. **把普通文本 PDF 当作失败。** Vision OCR 对文本 PDF 同样有效；以结果文件为准。
3. **忽略部分失败。** 批量 JSON 中 `failed > 0` 时必须明确报告失败项。
4. **OCR 结果乱序。** 对版面复杂的文书可尝试 `--dpi 300` 提升识别精度。
5. **脱敏失败：Ollama 未启动。** 错误提示 `Ollama is not reachable`，运行 `open -a Ollama` 后重试。
6. **脱敏失败：模型未拉取。** 错误提示 `Model '...' not available`，运行 `ollama pull <模型名>` 后重试。
7. **脱敏后占位符不一致。** 极少数情况下模型对同一人物使用了不同占位符，人工核对后统一替换即可。
8. **去页码后正文有多余空行。** `--merge-pages` 已自动将连续空行压缩为单行；若仍有异常，检查原始 OCR 输出是否存在非标准页码格式（如 `第一页`），可手动删除。
