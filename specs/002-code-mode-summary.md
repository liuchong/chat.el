# Code Mode Spec Summary

## 核心设计原则

**单窗口设计 (Single Window Design)**
- 不强制分割窗口
- 不弹出新窗口
- 所有功能通过 buffer 切换实现
- 用户完全控制窗口布局

## 架构概览

```
┌─────────────────────────────────────────────────────────────────┐
│                      User Interface                              │
│                     (Single Buffer)                              │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Code Chat Buffer (*chat:code:project*)                    │ │
│  │  - Compact header (project, strategy, tokens)              │ │
│  │  - Conversation history                                    │ │
│  │  - Input area                                              │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Preview Buffer (*chat-preview*) - optional, manual switch │ │
│  │  - Diff format                                             │ │
│  │  - Accept/Reject keys                                      │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                              │
                              v
┌─────────────────────────────────────────────────────────────────┐
│                      Core Modules                                │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐            │
│  │chat-code.el  │ │chat-context- │ │ chat-edit.el │            │
│  │(entry point) │ │ code.el      │ │(operations)  │            │
│  └──────────────┘ └──────────────┘ └──────────────┘            │
│  ┌──────────────┐ ┌──────────────┐                             │
│  │chat-code-    │ │chat-code-    │                             │
│  │intel.el      │ │preview.el    │                             │
│  └──────────────┘ └──────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              v
┌─────────────────────────────────────────────────────────────────┐
│                      Existing Stack                              │
│         (chat-session, chat-llm, chat-files, chat-tools)        │
└─────────────────────────────────────────────────────────────────┘
```

## 主要功能

### 1. 启动方式

```elisp
chat-code-start              ;; 从当前项目启动
chat-code-for-file           ;; 针对特定文件
chat-code-for-selection      ;; 使用选区
chat-code-from-chat          ;; 从普通聊天切换
```

### 2. 编辑命令

```elisp
chat-edit-generate  ;; 生成代码
chat-edit-complete  ;; 代码补全
chat-edit-explain   ;; 解释代码
chat-edit-refactor  ;; 重构代码
chat-edit-fix       ;; 修复问题
chat-edit-docs      ;; 生成文档
chat-edit-tests     ;; 生成测试
```

### 3. 修改处理

```
AI 生成修改
    │
    ├─→ 创建 *chat-preview* buffer（不显示）
    │
    ├─→ 在 chat buffer 显示操作选项
    │    "[Apply: C-c C-a] [Preview: C-c C-v] [Reject: C-c C-k]"
    │
    └─→ 用户选择:
         • C-c C-a: 直接接受
         • C-c C-v: 切换到 preview buffer 查看
         • C-c C-k: 拒绝
         • C-x b: 手动切换查看
```

## 工作流程

### 标准编程流程

```
1. 编辑代码文件 (src/main.py)
2. M-x chat-code-for-selection
3. 输入需求: "添加错误处理"
4. AI 生成修改
5. C-c C-a 接受 / C-c C-v 查看 / C-c C-k 拒绝
6. C-x b 切换回原文件
```

### 窗口管理流程

```
单窗口切换 (推荐):
  C-x b src/main.py RET     ;; 回到代码
  C-x b *chat:code* RET     ;; 回到聊天

手动分割 (可选):
  C-x 3                     ;; 垂直分割
  C-x b *chat-preview* RET  ;; 在右窗口打开预览
```

## 配置要点

```elisp
;; 启用 code mode
(setq chat-code-enabled t)

;; 默认策略
(setq chat-code-default-strategy 'balanced)

;; 小修改自动应用
(setq chat-code-auto-apply-threshold 10)

;; 上下文策略
(setq chat-code-context-sources
      '(file-content file-symbols imports git-status))
```

## 实现阶段

| 阶段 | 周期 | 内容 |
|------|------|------|
| Phase 1 | Week 1-4 | 核心骨架、context builder、文件操作 |
| Phase 2 | Week 5-8 | 编辑命令、preview buffer、编辑引擎 |
| Phase 3 | Week 9-12 | 代码智能、符号索引、项目分析 |
| Phase 4 | Week 13-14 | 工具扩展、优化完善 |

## 文件清单

```
specs/
├── 002-code-mode.md              # 完整 spec
├── 002-code-mode-architecture.md # 架构详细说明
├── 002-code-mode-quickstart.md   # 快速入门
└── 002-code-mode-summary.md      # 本文件

待实现:
├── chat-code.el                  # 主入口
├── chat-context-code.el          # 上下文管理
├── chat-code-intel.el            # 代码智能
├── chat-edit.el                  # 编辑操作
└── chat-code-preview.el          # 预览 buffer
```

## 关键设计决策

1. **不分割窗口**：所有操作在当前窗口，用户自己控制布局
2. **Buffer 命名清晰**：`*chat:code:project*`, `*chat-preview*`
3. **快捷键统一**：`C-c C-a` 接受, `C-c C-k` 拒绝, `C-c C-v` 查看预览
4. **Preview 可选**：可以直接接受，也可以先查看
5. **尊重 Emacs 习惯**：`C-x b` 切换, `C-x 2/3` 手动分割

## 下一步行动

1. 开始 Phase 1 实现
2. 创建 `chat-code.el` 骨架
3. 实现基础的 context builder
4. 集成到现有的 chat session 系统

---

*Summary Version: 0.1*
*Date: 2026-03-26*
