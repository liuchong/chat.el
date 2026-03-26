# 002: Code Mode - AI 编程 IDE 功能 Spec

## 文档链接

- [完整使用指南](../docs/code-mode-usage.md) - 详细的安装、配置和使用说明
- [快速参考卡](../docs/code-mode-cheatsheet.md) - 一页速查表
- [架构详细说明](002-code-mode-architecture.md) - 系统架构和数据流
- [Phase 1 实现](002-code-mode-implementation.md) - 核心基础设施
- [Phase 2 实现](002-code-mode-phase2.md) - LLM 集成和内联编辑
- [Phase 3 实现](002-code-mode-phase3.md) - 代码智能和流式响应
- [Phase 4 实现](002-code-mode-phase4.md) - 高级功能和优化

## Overview

为 chat.el 添加 AI 自动编程 IDE 功能（Code Mode），让用户能够在 Emacs 中获得类似 Cursor 或 kimi-cli 的 AI 编程体验。

Code Mode 是一个专门用于代码编辑、项目理解和自动修改的工作模式。它深度集成 Emacs 的编辑能力，同时提供 AI 辅助的代码生成、重构、理解和项目级操作。

## Current Status

本 spec 现在同时承担“设计目标”和“现状约束”的说明。
当前仓库中已经有基础可用的 code chat 主路径，但外围能力仍在修整中。
凡是与当前源码不一致的历史草案接口，应以下列模块为准：
- `chat-code.el`
- `chat-edit.el`
- `chat-context-code.el`
- `chat-code-preview.el`
- `tests/unit/test-chat-code.el`

## Goals

1. **无缝集成**: 作为 Emacs 的自然扩展，不破坏原有编辑体验
2. **项目感知**: AI 理解项目结构、依赖关系和代码上下文
3. **精准编辑**: 支持多种代码修改策略（patch、rewrite、insert）
4. **双向同步**: 聊天窗口与代码缓冲区实时同步
5. **可验证性**: 修改后可以验证、回滚、对比

## Non-Goals

1. 不替代 Emacs 的编程功能，而是增强它
2. 不实现完整的 LSP 客户端，而是与现有 LSP 共存
3. 不做复杂的 GUI，保持 Emacs 的简洁风格

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Code Mode Architecture                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐ │
│  │   Code Chat UI  │    │  Inline Editing │    │ Experimental    │ │
│  │  (chat-code.el) │    │  (chat-edit.el) │    │ Helper Modules  │ │
│  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘ │
│           │                      │                      │          │
│           └──────────────────────┼──────────────────────┘          │
│                                  │                                 │
│           ┌──────────────────────┴──────────────────────┐          │
│           │              Context Manager                │          │
│           │         (chat-context-code.el)              │          │
│           └──────────────────────┬──────────────────────┘          │
│                                  │                                 │
│           ┌──────────────────────┴──────────────────────┐          │
│           │              Code Intelligence              │          │
│           │    (Symbols, Dependencies, AST, Git)        │          │
│           └──────────────────────┬──────────────────────┘          │
│                                  │                                 │
│  ┌───────────────────────────────┴───────────────────────────────┐ │
│  │                    Existing chat.el Stack                     │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │ │
│  │  │chat-llm  │  │chat-files│  │chat-tools│  │chat-approval│    │ │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘      │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Code Chat Mode (`chat-code.el`)

专门的聊天模式，针对编程场景优化。

#### 1.1 Entry Points

```elisp
;;;###autoload
(defun chat-code-start (&optional project-root)
  "Start a code mode session for the current project.")

;;;###autoload
(defun chat-code-for-file (file-path)
  "Start code mode focused on a specific file.")

;;;###autoload
(defun chat-code-for-selection ()
  "Start code mode with current selection as context.")

;;;###autoload
(defun chat-code-from-chat ()
  "Switch current chat session to code mode.")
```

#### 1.2 Session Types

| Session Type | Description | Auto-context |
|--------------|-------------|--------------|
| `project` | 整个项目 | 项目结构、README、关键文件 |
| `file` | 单个文件 | 文件内容、符号列表 |
| `selection` | 选中代码 | 选中内容、 surrounding context |
| `function` | 单个函数 | 函数定义、调用链 |
| `diff` | 代码变更 | Git diff、未保存变更 |

#### 1.3 Code Chat Buffer Layout

保持单窗口设计，所有内容在一个 buffer 中显示：

```
════════════════════════════════════════════════════════════════════
Code: my-project/src/main.py                    Strategy: balanced
Context: 3 files, 2400/8000 tokens
────────────────────────────────────────────────────────────────────

You: Add error handling to the connect function

Assistant: I'll add error handling to the connect function. Let me 
first look at the current implementation...

[Tool Call] files_read: src/database.py

Here's the updated code:

```python
def connect(host, port):
    try:
        conn = socket.create_connection((host, port))
        return conn
    except socket.error as e:
        logger.error(f"Connection failed: {e}")
        raise ConnectionError(f"Failed to connect to {host}:{port}") from e
```

[Apply: C-c C-a]  [Preview: C-c C-v]  [Reject: C-c C-k]

────────────────────────────────────────────────────────────────────
> _
```

**设计原则**：不分割窗口，所有信息在一个 buffer 中展示。用户可以用 `C-x b` 或 `C-x C-b` 自行切换窗口。


### 2. Inline Editing (`chat-edit.el`)

直接在代码缓冲区中进行 AI 辅助编辑。

#### 2.1 Commands

```elisp
;;;###autoload
(defun chat-edit-complete ()
  "Complete the current code at point.")

;;;###autoload
(defun chat-edit-explain ()
  "Explain the code at point or selection.")

;;;###autoload
(defun chat-edit-refactor (instruction)
  "Refactor code according to INSTRUCTION.")

;;;###autoload
(defun chat-edit-fix ()
  "Fix issues in the code at point.")

;;;###autoload
(defun chat-edit-docs ()
  "Generate documentation for the code at point.")

;;;###autoload
(defun chat-edit-tests ()
  "Generate tests for the code at point.")
```

#### 2.2 Inline Preview

不提供侵入式 overlay，而是在单独 buffer 中显示 diff：

```elisp
(defun chat-edit--show-preview (edit)
  "Show AI-generated code in a diff buffer.")
```

操作方式：
- 执行编辑命令后，自动弹出 `*chat-preview*` buffer（但不用分割窗口）
- 用户可以用 `C-x b` 切换查看
- 在 diff buffer 中按 `a` 接受，`r` 拒绝
- 或者直接在原 buffer 中按 `C-c C-a` 接受修改

**设计原则**：尊重用户的窗口布局，用 buffer 切换代替窗口分割。


### 3. Project Context Manager (`chat-context-code.el`)

智能管理代码相关的上下文信息。

#### 3.1 Context Sources

当前实现由 `chat-context-code.el` 内部策略控制上下文来源。
不要把本节理解为已经存在可配置的 `chat-code-context-sources` 变量。

#### 3.2 Context Strategies

| Strategy | Description | Token Budget |
|----------|-------------|--------------|
| `minimal` | 仅当前文件 | 2k |
| `focused` | 当前文件 + 相关文件 | 4k |
| `balanced` | 当前文件 + 导入 + 符号 | 8k |
| `comprehensive` | 完整项目结构 | 16k |

#### 3.3 Smart Context Building

```elisp
(defun chat-code-build-context (strategy &optional file)
  "Build context for AI using STRATEGY.")
```

实现要点：
1. 优先包含当前光标所在函数/类
2. 包含相关的导入语句
3. 包含调用当前函数的父函数
4. 包含当前函数调用的子函数
5. 智能截断长文件（保留函数签名，截断实现）

### 4. Code Intelligence (`chat-code-intel.el`)

代码分析和理解功能。

#### 4.1 Symbol Indexing

```elisp
(defun chat-code-index-symbols (project-root)
  "Build symbol index for the project.")

(defun chat-code-find-references (symbol)
  "Find all references to SYMBOL.")

(defun chat-code-find-definition (symbol)
  "Find definition of SYMBOL.")
```

#### 4.2 Dependency Analysis

```elisp
(defun chat-code-analyze-imports (file)
  "Analyze imports/dependencies of FILE.")

(defun chat-code-find-related (file)
  "Find files related to FILE based on imports and references.")
```

#### 4.3 Code Metrics

```elisp
(defun chat-code-calculate-complexity (function)
  "Calculate cyclomatic complexity.")

(defun chat-code-identify-hotspots (project-root)
  "Identify frequently modified files.")
```

## Future Tool Extensions

本节是未来方向，不代表当前仓库已提供这些接口。

### 1. Enhanced File Tools

扩展现有的 `chat-files.el`，添加代码感知功能。

```elisp
;; 读取文件，附带代码结构信息
(chat-code-read-file "src/main.py" :with-symbols t :with-outline t)

;; 搜索代码符号
(chat-code-search-symbols "connect" :type 'function)

;; 获取函数定义
(chat-code-get-function "src/main.py" "connect")
```

### 2. Code Edit Tools

新增代码编辑专用工具。

```elisp
;; 应用代码补丁（行级精确）
(chat-code-apply-patch "src/main.py"
  '((:line 42 :old "def connect():" :new "def connect(timeout=30):")))

;; 重写函数
(chat-code-rewrite-function "src/main.py" "connect" new-code)

;; 批量插入
(chat-code-insert-at "src/main.py" 100 "# TODO: error handling")
```

### 3. Project Tools

```elisp
;; 获取项目结构
(chat-code-project-structure :depth 2)

;; 搜索项目
(chat-code-grep-project "class.*View" :glob "*.py")

;; 获取文件依赖图
(chat-code-dependency-graph "src/main.py")
```

### 4. Git Tools

```elisp
;; 获取当前变更
(chat-code-git-diff :staged nil :untracked t)

;; 获取文件历史
(chat-code-file-history "src/main.py" :limit 5)

;; 获取提交信息
(chat-code-git-log :limit 10)
```

## Integration Points

### 1. With Existing chat.el

| Component | Integration |
|-----------|-------------|
| `chat-session` | Code mode 是一种特殊的 session type |
| `chat-ui` | 扩展以支持代码预览和 diff 显示 |
| `chat-llm` | 复用现有的 LLM 请求逻辑 |
| `chat-files` | 扩展以支持代码感知操作 |
| `chat-tools` | 注册 code mode 专用工具 |
| `chat-approval` | 代码修改也需要审批 |

### 2. With Emacs Built-ins

| Feature | Usage |
|---------|-------|
| `project.el` | 项目根目录检测和管理 |
| `xref` | 符号跳转和引用查找 |
| `eldoc` | 显示 AI 生成的文档 |
| `flymake`/`flycheck` | 显示代码问题 |
| `vc` | Git 操作和 diff |
| `imenu` | 代码结构导航 |
| `which-func` | 当前函数显示 |
| `hideshow` | 代码折叠 |

### 3. With External Packages

| Package | Integration |
|---------|-------------|
| `lsp-mode`/`eglot` | 复用 LSP 的符号和诊断信息 |
| `magit` | 更丰富的 Git 集成 |
| `company` | AI 补全建议 |
| `yasnippet` | 代码模板 |
| `smartparens` | 代码编辑辅助 |

## Workflows

### Workflow 1: 新功能开发

```
1. 用户: C-c c n (chat-code-start)
   → 启动 code mode，自动检测项目根目录

2. 系统: 构建项目上下文
   → 读取项目结构、README、关键文件

3. 用户: "Add a user authentication system"

4. AI: 分析需求，列出计划
   "I'll help you add a user authentication system.
    Here's my plan:
    1. Create User model (models/user.py)
    2. Add password hashing utilities (utils/crypto.py)
    3. Create authentication middleware (middleware/auth.py)
    4. Add login/logout endpoints (routes/auth.py)
    
    Shall I proceed?"

5. 用户: [Confirm]

6. AI: [逐一生成文件，每个文件经过审批]
   → files_write, files_read (verify), apply_patch

7. 系统: 显示生成的文件列表
   → 提供一键测试、提交选项
```

### Workflow 2: Bug 修复

```
1. 用户: 在错误上执行 chat-code-fix
   → 自动收集错误信息和上下文

2. AI: 分析错误原因
   "I see the issue. The 'user' variable is None
    because the query didn't find a match.
    We need to add a null check."

3. AI: 生成修复
   → 显示 diff 预览

4. 用户: [Accept]

5. 系统: 应用修复，保持光标位置
```

### Workflow 3: 代码重构

```
1. 用户: 选中代码，执行 chat-edit-refactor
   "Extract this into a separate function"

2. AI: 分析选中代码，确定依赖
   → 使用 files_read 确认外部依赖

3. AI: 生成重构方案
   → 显示原代码和新代码对比

4. 用户: [预览] 或 [接受]

5. 系统: 原子性应用修改
   → 如果失败，自动回滚
```

### Workflow 4: 理解代码

```
1. 用户: 在函数上执行 chat-edit-explain

2. AI: 分析函数逻辑
   "This function implements the OAuth2 flow:
   1. Validates the client credentials
   2. Generates an authorization code
   3. Stores the code with expiration
   4. Returns the redirect URL"

3. 系统: 在单独窗口显示解释
   → 提供追问选项
```

## UI Components

**核心设计原则：单窗口，不分割，不弹窗**

所有功能通过 buffer 切换实现，不强制任何窗口布局。用户完全控制窗口管理。

### 1. Code Preview Mode

在独立 buffer 中预览修改，不分割窗口。

```elisp
(define-derived-mode chat-code-preview-mode diff-mode "Code-Preview"
  "Major mode for previewing AI-generated code changes.")
```

工作流程：
1. AI 生成修改后，创建/更新 `*chat-preview*` buffer
2. 显示消息："Preview in *chat-preview* (C-c C-v to view)"
3. 用户按需切换查看
4. 可在原 buffer 直接接受/拒绝，无需查看 preview

快捷键（在 preview buffer 中）：
- `a` - 接受修改
- `r` - 拒绝修改
- `q` - 关闭 preview

### 2. Context 信息

Context 信息显示在 chat buffer 的顶部，格式简洁：

```
════════════════════════════════════════════════════════════════════
Project: my-project | File: src/main.py | Context: 3 files, 2400/8000 tokens
════════════════════════════════════════════════════════════════════
```

当前仓库中没有稳定的 `chat-code-show-context` 命令。
如需查看详细上下文，应直接检查 `chat-context-code.el` 的构建结果或后续补充调试命令。

### 3. Minibuffer Prompts

所有交互式输入都在 minibuffer 完成：

```elisp
(defun chat-code-read-instruction ()
  "Read code instruction with context-aware completion.")
```

- 历史指令：M-p / M-n 翻阅
- 模板选择：TAB 补全
- 参数提示：minibuffer 底部显示

## Configuration

```elisp
(defgroup chat-code nil
  "AI code editing for chat.el."
  :group 'chat)

;; 启用/禁用 code mode
(defcustom chat-code-enabled t
  "Enable code mode features."
  :type 'boolean)

;; 默认策略
(defcustom chat-code-default-strategy 'balanced
  "Default context strategy."
  :type '(choice (const minimal)
                 (const focused)
                 (const balanced)
                 (const comprehensive)))

;; 文件类型映射
(defcustom chat-code-filetype-map
  '(("\.py$" . python)
    ("\.js$" . javascript)
    ("\.ts$" . typescript)
    ("\.el$" . emacs-lisp)
    ("\.go$" . go)
    ("\.rs$" . rust))
  "File extensions to language mapping.")

;; 代码模式提示词
(defcustom chat-code-system-prompt
  "You are an expert programmer. Help the user write, understand, and modify code.
   When making changes:
   - Follow existing code style
   - Add error handling where appropriate
   - Include tests for new functionality
   - Document public APIs"
  "System prompt for code mode.")

;; 最大 token 限制
(defcustom chat-code-max-tokens 16000
  "Maximum tokens for code mode context."
  :type 'integer)

;; 自动应用小修改
(defcustom chat-code-auto-apply-threshold 10
  "Automatically apply changes smaller than this many lines."
  :type 'integer)
```

## Historical Implementation Plan

以下内容保留为最初设计分期记录。
当前仓库状态应以实际源码、测试和修整文档为准。

### Phase 1: Core Infrastructure

**Week 1-2: Foundation**
- [ ] 创建 `chat-code.el`，实现 code session 类型
- [ ] 集成 `project.el` 进行项目检测
- [ ] 实现基础的 context builder
- [ ] 扩展 chat-ui 支持代码预览

**Week 3-4: File Operations**
- [ ] 扩展 `chat-files.el` 添加代码感知功能
- [ ] 实现符号索引和查询
- [ ] 实现代码 patch 工具
- [ ] 添加代码 diff 显示

### Phase 2: Inline Editing

**Week 5-6: Inline Commands**
- [ ] 实现 `chat-edit.el` 核心功能
- [ ] 实现 overlay 预览系统
- [ ] 添加 generate/complete/explain 命令
- [ ] 集成到常用编程 mode

**Week 7-8: Refactoring**
- [ ] 实现 refactor/fix/docs/tests 命令
- [ ] 添加智能上下文收集
- [ ] 实现原子性修改和回滚
- [ ] 添加修改历史

### Phase 3: Advanced Features

**Week 9-10: Project Intelligence**
- [ ] 实现项目结构分析
- [ ] 添加依赖图生成
- [ ] 集成 Git 信息
- [ ] 实现代码搜索

**Week 11-12: Integration & Polish**
- [ ] 集成 LSP 诊断信息
- [ ] 优化 token 使用
- [ ] 添加更多语言支持
- [ ] 性能优化

### Phase 4: Tooling

**Week 13-14: Tools Ecosystem**
- [ ] 创建代码专用工具集
- [ ] 实现工具自动发现
- [ ] 添加自定义代码模板
- [ ] 实现代码审查工作流

## API Reference

### Session Management

```elisp
(chat-code-session-p session) → boolean
(chat-code-session-create project-root strategy) → session
(chat-code-session-switch-strategy session strategy)
(chat-code-session-refresh-context session)
```

### Context Operations

```elisp
(chat-code-context-add-file context file)
(chat-code-context-add-symbol context symbol)
(chat-code-context-add-selection context start end)
(chat-code-context-calculate-tokens context) → integer
(chat-code-context-to-string context) → string
```

### Edit Operations

```elisp
(chat-code-edit-generate buffer point description) → edit
(chat-code-edit-apply edit) → success-p
(chat-code-edit-preview edit) → overlay
(chat-code-edit-reject edit)
(chat-code-edit-history buffer) → list
```

### Project Operations

```elisp
(chat-code-project-detect) → root-path
(chat-code-project-analyze root) → project-info
(chat-code-project-related-files file) → list
(chat-code-project-search query) → results
```

## Testing Strategy

1. **Unit Tests**: 每个编辑操作、context builder
2. **Integration Tests**: 完整工作流、多文件修改
3. **Mock LLM**: 可重现的测试响应
4. **Fixtures**: 示例项目结构

## Security Considerations

1. **Path Validation**: 所有文件操作经过 `chat-files--safe-path-p`
2. **Approval for Destructive Ops**: 删除、大段重写需要确认
3. **Git Integration**: 鼓励在干净的工作区操作
4. **Sandbox Mode**: 可选的沙箱模式，限制文件系统访问

## Future Enhancements

1. **Multi-file Refactoring**: 跨文件重命名、提取
2. **Test Generation**: 基于覆盖率的测试生成
3. **Documentation Sync**: 代码和文档同步更新
4. **CI Integration**: 自动验证修改
5. **Code Review**: AI 辅助代码审查
6. **Learning**: 学习用户的编码风格

---

*Spec Version: 0.2*
*Created: 2026-03-26*
*Status: Active Repair Spec*
