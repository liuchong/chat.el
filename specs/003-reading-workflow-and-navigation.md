# 003: In-Emacs Reading Workflow and Navigation Spec

## Overview

为 `chat.el` 增加一条更完整的 in-Emacs 阅读与提问工作流，让用户在读代码时可以自然地把正在看的内容带进 AI 对话，并让 AI 在需要时直接帮助打开相关文件。

本 spec 同时覆盖三个紧密相关的目标：

1. 让已经实现的 session regenerate 和 edit-resend 更容易被发现和使用
2. 让用户可以从正在阅读的代码直接引用上下文提问，而不是手工复制粘贴
3. 让 AI 在 Emacs 内直接导航到相关文件，而不是只回答一个路径字符串

## Current Status

当前仓库已经有以下可用基础：

- `chat-code-for-selection` 可以从选区启动 code mode session
- `chat-edit-explain` / `chat-edit-fix` / `chat-edit-refactor` 等命令可以基于当前选区或 defun 发起一次内联请求
- code mode 已有 `focus-file`、request panel、tool calling、project-root 限制和 file tools
- chat mode 和 code mode 已有 regenerate / edit-last-user 的底层能力

但当前仍有几个明显缺口：

- 正在阅读代码时，没有一套统一的“引用当前上下文并提问”的命令层
- regenerate / edit-resend 还缺少足够的发现性
- AI 不能用 Emacs 原生方式直接帮助打开文件
- 阅读上下文、项目上下文和导航行为还没有统一 spec

## Goals

1. 让“读代码时问 AI”成为 Emacs 内自然动作，而不是切换心智模型
2. 让上下文引用显式、可控、可测试，而不是隐式猜测
3. 让 AI 导航文件时遵守项目和路径安全边界
4. 保持 Emacs 原生交互，不引入重型 widget UI
5. 让 chat mode 和 code mode 在阅读工作流上保持一致的数据模型

## Non-Goals

1. 不做任意路径的无边界 AI 导航
2. 不做类 IDE 的复杂图形按钮层
3. 不让模型直接操纵窗口布局策略
4. 不把普通阅读工作流退化成 shell 命令驱动
5. 不在第一阶段引入任意历史片段拼接或复杂多片段引用编辑器

## Problem Breakdown

### 1. Session Command Discoverability

regenerate 和 edit-resend 已可用，但用户在主工作流中不容易发现。

这会导致：

- 已实现能力被低估
- 用户继续重复输入相近问题
- session UX 与 request panel、approval flow 的成熟度不匹配

### 2. Reading Context Capture

当前“正在读某段代码，想马上问 AI”还不够自然。

用户需要的是：

- 引用当前 region
- 或引用 point 所在 defun
- 或引用当前文件附近上下文
- 自动带上文件路径与行号
- 直接把这些内容送进 chat/code 会话

而不是：

- 手工复制粘贴代码
- 手动说明文件名
- 重新建立一个 selection-only session 才能开始问

### 3. AI-Driven File Navigation

当前 AI 可以回答“去看哪个文件”，但不能真正帮用户在 Emacs 中打开它。

这会让链路中断：

- AI 提示路径
- 用户手动复制
- 再手动 `find-file`

在 in-Emacs 工作流里，这一步应该能被收敛成安全、可控的原生命令。

## Proposed Architecture

```
reading buffer
   │
   ├─ capture current region / defun / nearby context
   │
   ├─ build explicit source reference payload
   │
   ├─ open or reuse chat/code session
   │
   ├─ insert structured question with source reference
   │
   └─ optional AI tool call: open_file(path, line, column)
```

核心原则：

- 引用上下文必须显式
- session 内保存的是正常 user message，不额外引入隐藏消息类型
- 导航能力作为受限工具或受限动作进入现有 request/tool flow
- 所有路径仍受 project root 和 allowed directories 约束

## Design

### A. Reading Context Capture Model

引入统一的“阅读上下文引用”数据模型，至少包含：

- source buffer file path
- line range
- selected text or extracted code
- capture kind: `region` / `defun` / `near-point`
- optional project root

建议内部 helper：

```elisp
(chat-reading-capture-region)      ;; current region
(chat-reading-capture-defun)       ;; defun around point
(chat-reading-capture-near-point)  ;; bounded lines around point
```

这些 helper 只负责采集和格式化，不直接发请求。

### B. Question Insertion Format

引用内容进入会话时，使用显式的可读格式，而不是隐式 metadata：

```text
Question about this code:

File: path/to/file.el
Lines: 120-168
Kind: region

```elisp
...
```

Question:
这里为什么要这样设计？
```

这样做的好处：

- 对模型可见
- 对用户可见
- session 持久化后可追踪
- 不需要为了这类问题额外发明新 message role

### C. Session Entry Commands

新增一组阅读导向命令，优先走现有 code mode session：

```elisp
(chat-code-ask-region QUESTION)
(chat-code-ask-defun QUESTION)
(chat-code-ask-near-point QUESTION)
(chat-code-ask-current-file QUESTION)
```

行为：

- 如果当前 buffer 在项目内，优先复用或创建 code mode session
- 自动把对应 file 设为 focus file
- 把捕获的代码片段和用户问题组装成 user message
- 直接发送或先填入输入区，取决于命令语义

建议第一阶段提供两类入口：

- `...-ask-*`：立即发送
- `...-quote-*`：只插入输入区，用户可再编辑

### D. Discoverability For Session Commands

为现有 regenerate / edit-resend 增加原生可发现性：

- code mode key bindings
- mode help text
- 轻量 echo-area 提示或 header hint
- README / cheatsheet / usage docs

建议命令集：

```elisp
(chat-ui-regenerate-last-response)
(chat-ui-edit-last-user-message)
(chat-code-regenerate-last-response)
(chat-code-edit-last-user-message)
```

第一阶段不要求 chat mode 复杂 keymap 重构，但至少要：

- 提供 `M-x` 命令名文档
- 在 code mode 里给出稳定快捷键
- 在 README 和 cheatsheet 中可查

### E. AI-Driven File Navigation

新增一个安全的 Emacs 内导航能力：

```elisp
open_file(path, line?, column?)
```

设计要求：

- 只允许打开项目根或允许目录中的文件
- 默认无审批，但必须经过安全路径检查
- 如果路径非法或越界，返回工具错误而不是退化成 shell
- 打开文件时使用 Emacs 原生 buffer/file API，不调用外部命令

建议运行时行为：

- `find-file-noselect` 获取 buffer
- `pop-to-buffer` 或 `switch-to-buffer` 交给 Emacs 原生显示逻辑
- 如果提供 line/column，则定位到对应位置

建议把它作为一个低风险内置工具暴露给模型，而不是把“打开文件”硬编码进响应解析器。原因是：

- 与现有 tool-calling 架构一致
- request panel 能自然显示导航动作
- 可记录、可测试、可失败
- 后续可扩展到 `open_file` + `reveal_range`

### F. Safety Rules

#### Reading Context

- 只捕获用户显式选择的 region，或点附近有明确边界的 defun / lines
- 不自动把整个大文件无边界塞进问题
- 生成的问题文本必须带文件路径和行号

#### File Navigation

- `open_file` 必须复用 `chat-files` 的安全路径规则
- 不允许通过导航工具绕过 allowed directories
- 不允许通过 `../`、symlink escape、绝对路径越界打开文件
- 非法路径必须显示成工具错误

## Implementation Phases

### Phase 1: Spec and Command Surface

- 完成本 spec
- 为 session regenerate / edit-resend 定义 discoverability 方案
- 明确阅读上下文 capture helpers 和 navigation tool contract

### Phase 2: Reading Context Capture

- 新增 capture helpers
- 新增 `ask-*` / `quote-*` 命令
- 补 tests 覆盖 region / defun / near-point / current-file 四类场景

### Phase 3: File Navigation Tool

- 新增 `open_file` 内置工具
- 接到 request panel 和 tool events
- 补安全路径、定位、buffer opening 的单测

### Phase 4: Discoverability and Docs

- 给 code mode 增加快捷键和帮助文案
- README、usage、cheatsheet 补阅读工作流
- 评估 chat mode 是否需要独立 key bindings

## Testing Strategy

### Unit Tests

- reading capture helpers return stable file/line metadata
- ask/quote commands build expected user messages
- code mode session reuse and focus-file update behavior
- `open_file` obeys path safety rules
- `open_file` opens the right buffer and moves point correctly
- session command discoverability surfaces expected bindings or help text

### Integration Checks

- manual in-Emacs flow: read code -> quote region -> ask AI -> open related file
- code mode flow: ask on region -> AI opens sibling file -> continue editing

## Acceptance Criteria

### Reading Context

- 用户在代码 buffer 里不需要复制粘贴，就能把当前阅读内容带进 AI 问题
- 生成的 user message 中明确包含文件路径、行号和代码片段
- 相同命令在 code mode 中优先复用当前 session

### Navigation

- AI 可以通过 `open_file` 打开项目内相关文件
- request panel 能显示这次导航动作
- 非法路径会失败，不会绕过安全边界

### Discoverability

- regenerate / edit-resend 在 code mode 中可直接发现
- 用户文档中明确描述“阅读代码 -> 引用提问 -> AI 导航文件”的推荐链路

## Recommended First Implementation Slice

先做最小但高价值的组合：

1. `chat-code-ask-region`
2. `chat-code-quote-region`
3. `open_file`
4. code mode 中 regenerate / edit-resend 快捷键与帮助文案

理由：

- 这条链路最贴近你的真实需求
- 改动集中在 code mode 和现有 tool stack
- 不需要先大改普通 chat mode 结构
- 最容易形成一条可演示、可测试、可继续扩展的 in-Emacs AI 工作流
