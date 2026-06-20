---
name: local-wechat-ocr
description: Use when Hermes on macOS needs to OCR local PDF or image files, create searchable PDF/A and Markdown, or batch-process scanned Chinese documents using macOS Vision framework (offline, no cloud, no Windows VM required).
license: MIT
metadata:
  hermes:
    version: 2.0.0
    platforms: [macos]
    tags: [OCR, PDF, PDFA, Markdown, Chinese, Legal-Documents, Vision, macOS-native]
    related_skills: [ocr-and-documents]
    requires_toolsets: [terminal]
---

# 本地 OCR（macOS Vision 引擎）

## Overview

使用 macOS 内置 Vision 框架对本地 PDF 或图片进行 OCR，生成 `*.md` 与可搜索的 `*.pdfa.pdf`。所有处理均在本机完成，不上传网络，无需微信、无需 Windows 虚拟机。

首次运行会自动编译 Swift OCR 引擎（约 30–60 秒），之后无需重新编译。

## Quick Reference

| 任务 | 命令 |
|---|---|
| 单个文件 | `~/.hermes/skills/productivity/local-wechat-ocr/scripts/run_mac_ocr.sh "/绝对路径/材料.pdf"` |
| 批量目录 | `~/.hermes/skills/productivity/local-wechat-ocr/scripts/run_mac_ocr.sh --continue-on-error "/绝对路径/材料目录"` |
| 递归目录 | `~/.hermes/skills/productivity/local-wechat-ocr/scripts/run_mac_ocr.sh --recursive --continue-on-error "/绝对路径/材料目录"` |
| 指定 DPI | `~/.hermes/skills/productivity/local-wechat-ocr/scripts/run_mac_ocr.sh --dpi 300 "/绝对路径/材料.pdf"` |
| 预检 | `~/.hermes/skills/productivity/local-wechat-ocr/scripts/run_mac_ocr.sh --dry-run "/绝对路径/材料.pdf"` |

支持 `.pdf`、`.png`、`.jpg`、`.jpeg`、`.bmp`、`.tiff`、`.tif`、`.webp`、`.gif`。目录模式只处理这些格式。

## Procedure

1. 确认输入是用户明确指定的本地文件或目录；输入不明确时先询问，不猜测路径。
2. 对单文件直接运行包装脚本。对目录按用户要求决定是否增加 `--recursive`；批量处理默认增加 `--continue-on-error`，避免一个坏文件中断整批。
3. 脚本会在 `~/.hermes/cache/local-wechat-ocr/jobs/` 创建隔离作业目录，将输入复制到其中。不得直接修改源文件。
4. 成功后读取脚本输出的 `result.json`，向用户报告作业目录、Markdown 文件和 PDF/A 文件的绝对路径。不要输出整份 OCR 正文，除非用户明确要求。
5. 批量任务应同时报告成功数、失败数及错误文件；不得把部分成功表述为全部完成。

## First-run Behavior

首次运行（或 OCR 引擎源码更新后）会自动调用 `swiftc` 编译 Swift OCR 引擎：

1. 如未安装 Xcode 命令行工具，先运行 `xcode-select --install`；
2. 编译完成后，OCR 引擎缓存于 `~/.hermes/cache/mac_vision_ocr`，后续无需重编译；
3. 对每个输入文件调用 Vision OCR，中简/中繁/英文自动识别；
4. 结果写入作业目录的 `output/` 子目录。

## Verification

只有同时满足以下条件才报告成功：

- 包装脚本退出状态为 `0`；
- 作业目录存在 `result.json`；
- `output/` 至少存在一个非空 `*.md`；
- `output/` 至少存在一个非空 `*.pdfa.pdf`。

若任一条件不满足，报告失败并引用终端中的最短必要错误；不得猜测 OCR 已完成。

## Privacy and Safety

- 所有处理均在本机完成，不通过网页、云 OCR、消息平台或第三方 API 传输文档。
- 不把身份证号、完整手机号、案号、客户姓名或文书全文写入回复或长期日志。
- 客户材料在实际展示或转发前应替换、遮盖或脱敏具体客户信息。
- 不删除源文件。只允许清理由本技能创建且路径位于 `~/.hermes/cache/local-wechat-ocr/jobs/` 的作业目录。

## Common Mistakes

1. **编译失败。** 若 `swiftc not found`，先运行 `xcode-select --install` 安装 Xcode 命令行工具。
2. **把普通文本 PDF 当作失败。** Vision OCR 对文本 PDF 同样有效；以结果文件为准。
3. **忽略部分失败。** 批量 JSON 中 `failed > 0` 时必须明确报告失败项。
4. **OCR 结果乱序。** 对版面复杂的文书可尝试 `--dpi 300` 提升识别精度。
