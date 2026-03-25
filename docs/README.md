# chat.el 文档

## Code Mode（AI 编程 IDE）

Code Mode 是 chat.el 的 AI 编程功能，提供代码生成、重构、测试集成等能力。

### 入门文档

| 文档 | 说明 |
|------|------|
| [code-mode-usage.md](code-mode-usage.md) | **完整使用指南** - 安装、配置、示例、故障排除 |
| [code-mode-cheatsheet.md](code-mode-cheatsheet.md) | **快速参考卡** - 一页速查，适合打印 |

### 设计文档

| 文档 | 说明 |
|------|------|
| [../specs/002-code-mode.md](../specs/002-code-mode.md) | 主设计 Spec |
| [../specs/002-code-mode-architecture.md](../specs/002-code-mode-architecture.md) | 架构详细说明 |
| [../specs/002-code-mode-summary.md](../specs/002-code-mode-summary.md) | 一页总结 |
| [../specs/002-code-mode-quickstart.md](../specs/002-code-mode-quickstart.md) | 快速入门 |

### 实现文档

| 文档 | 说明 |
|------|------|
| [../specs/002-code-mode-implementation.md](../specs/002-code-mode-implementation.md) | Phase 1 - 核心基础设施 |
| [../specs/002-code-mode-phase2.md](../specs/002-code-mode-phase2.md) | Phase 2 - LLM 集成和内联编辑 |
| [../specs/002-code-mode-phase3.md](../specs/002-code-mode-phase3.md) | Phase 3 - 代码智能和流式响应 |
| [../specs/002-code-mode-phase4.md](../specs/002-code-mode-phase4.md) | Phase 4 - 高级功能和优化 |

## 快速导航

### 我是新用户

1. 阅读 [快速入门](../specs/002-code-mode-quickstart.md)
2. 查看 [快速参考卡](code-mode-cheatsheet.md)
3. 详细阅读 [完整使用指南](code-mode-usage.md)

### 我是开发者

1. 阅读 [主设计 Spec](../specs/002-code-mode.md)
2. 查看 [架构说明](../specs/002-code-mode-architecture.md)
3. 参考实现文档（Phase 1-4）

### 我需要快速查阅

直接查看 [快速参考卡](code-mode-cheatsheet.md) 或打印它。

## 模块说明

```
chat-code.el              - 主入口和 UI
chat-context-code.el      - 智能上下文构建
chat-edit.el              - 编辑操作
chat-code-preview.el      - 预览 buffer
chat-code-intel.el        - 符号索引和调用图
chat-code-lsp.el          - LSP 集成
chat-code-refactor.el     - 多文件重构
chat-code-test.el         - 测试集成
chat-code-git.el          - Git 集成
chat-code-perf.el         - 性能优化
```

---

*Code Mode Documentation Index*
