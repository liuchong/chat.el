# Instructions for AI Agents and IDEs

本文档面向**所有**在本仓库参与开发的 AI、Agent、IDE 插件（包括但不限于 Cursor、GitHub Copilot、Windsurf、Claude Code、Codeium 等）。请在任何开发对话开始或结束时读取并遵守以下规则。

---

## 强制规则：开发文档必须同步更新

**Rule (mandatory):** At the end of every development session (or at the end of each logical phase), you **must**:

1. **AI 上下文文档 (ai-context)**  
   Create or update a session document under `docs/ai-contexts/` with the naming convention `conversation-{YYYY-MM-DD}-{topic}.md`. Include: requirements, technical decisions, completed/pending work, key code paths, and any issues encountered (which should also be reflected in the troubleshooting doc).

2. **疑难杂症与避坑记录 (troubleshooting & pitfalls)**  
   Update `docs/troubleshooting-pitfalls.md` with any **new** problems discovered and their causes/solutions. If the session introduced no new issues, add a short note in that document or in the ai-context file (e.g. "本次无新增避坑条目").

**Why:** This keeps project knowledge and pitfall history in the repo so future humans and AIs can avoid repeating mistakes and understand past decisions.

**Where to read more:**
- `docs/ai-contexts/README.md` — ai-context format and update requirements
- `docs/troubleshooting-pitfalls.md` — current list of known issues and fixes

---

## Git 操作限制（强制，绝对禁止违反）

**AI/Agent/IDE 禁止执行任何会修改 git 历史或向远端推送代码的命令。** 具体包括但不限于：
- `git commit`（任何形式）
- `git push`（任何形式，包括 `--force`、`--set-upstream` 等）
- `git rebase`、`git merge`、`git cherry-pick`、`git reset`（`--hard`/`--mixed`/`--soft`）
- `git tag`（创建或删除）
- `gh pr create`、`gh pr merge` 等会触发远端变更的 gh 命令

允许使用的 git 命令仅限只读操作：`git status`、`git log`、`git show`、`git diff`。

**违反此规则视为严重错误，不论用户是否明确要求。**

---

## 文档行文风格（强制）

- **自然行文**：不使用括号等解释性标点符号，用自然的行文表达
- **可读性优先**：确保字面能读懂、读出来也能听懂
- **直接清晰**：避免嵌套从句和复杂的修饰语，一句话只说一件事
- **示例**：
  - 不佳：`chat-files.el（文件操作模块）提供了read/grep/modify等功能`
  - 良好：`chat-files.el provides file operations including read search and modify`

---

## Emacs Lisp 代码规范（强制）

### 基础风格
- **遵循 Emacs Lisp 惯例**：使用 `chat-` 作为所有公共符号的前缀
- **命名规范**：函数用 `chat-module-function-name`，变量用 `chat-module-variable-name`，常量用 `chat-MODULE-CONSTANT`
- **使用 `cl-lib` 而非 `cl`**：需要 Common Lisp 特性时，`(require 'cl-lib)` 并使用 `cl-defun`、`cl-letf` 等带前缀的宏
- **避免动态作用域**：除非必要，否则使用 `lexical-binding: t`；动态变量需明确文档说明

### 数据结构
- **优先使用 `cl-defstruct`**：复杂数据结构应定义为结构体，而非松散的多值返回或关联列表
- **哈希表 vs 列表**：频繁查找的场景使用哈希表，顺序遍历的场景使用列表
- **不可变优先**：配置数据、常量定义使用 `defconst`；运行时状态使用 `defvar`

### 异步与并发
- **Emacs 是单线程**：任何"异步"操作实际都是基于 `run-at-time`、`make-process` 或 `deferred`
- **不阻塞 UI**：耗时操作（LLM 请求、工具执行）必须使用异步 API，配合 callback 或 Promise 模式
- **Process 管理**：外部进程调用必须通过 `make-process` 而非 `shell-command`，以便实时输出和取消

### 错误处理
- **使用 `condition-case`**：捕获特定错误类型，而非通配捕获
- **错误信息用户友好**：面向用户的错误信息必须清晰说明问题和解决办法
- **保留原始错误**：使用 `(error "用户友好的信息: %s" (error-message-string err))` 包装而非吞掉原错误

### 代码组织
- **一个文件一个主题**：`chat-llm.el` 处理 LLM 相关，`chat-tool-forge.el` 处理工具锻造
- **公共 API 前置**：文件开头放 `;;;###autoload` 标记的公共函数，内部辅助函数后置
- **避免循环依赖**：模块间依赖关系应为有向无环图

---

## 系统设计基本原则（强制）

### 异步非阻塞
- **所有 I/O 必须异步**：LLM API 调用、工具执行、文件读写都不得阻塞 Emacs 主循环
- **流式处理优先**：LLM 响应使用流式 API，边接收边渲染，而非等待完整响应
- **可取消性**：长时间运行的操作必须支持 `C-g` 取消，并正确清理资源

### 状态管理
- **显式状态优于隐式**：避免全局状态，优先通过参数传递上下文
- **会话隔离**：每个 chat session 拥有独立的状态，禁止跨会话共享可变状态
- **持久化边界**：内存中的临时状态与磁盘持久化数据必须明确区分

### 安全性
- **工具执行审批**：危险操作（文件写入、命令执行）默认需要用户确认
- **不信任外部输入**：LLM 返回的工具调用参数必须经过验证，防止注入攻击
- **敏感信息安全**：API keys 使用 `auth-source` 存储，禁止硬编码或明文存储

### 性能考虑
- **大列表分批处理**：消息历史、工具列表等大数据量操作使用分页或惰性加载
- **避免重复渲染**：使用 `inhibit-read-only` 和 `save-excursion` 优化缓冲区更新
- **定时器清理**：所有 `run-at-time`、`run-with-timer` 创建的定时器必须在适当时机取消

---

## 开发工作流规则（强制）

### 原型开发与脚本验证（强制，配合TDD）
- **关键功能点必须采用原型开发模式**：先用简单脚本语言快速验证可行性，再进入正式实现
- **原型验证推荐语言**：Shell、JavaScript(Node.js)、Python，按实际场景选择最方便的
- **也可选择独立项目片段验证**：如创建临时 crate/package 验证核心逻辑
- **原型验证必须覆盖**：
  - 外部API调用是否正确返回预期格式
  - 关键算法/逻辑的正确性
  - 协议编解码是否符合预期
  - 第三方库集成是否可行
- **原型脚本保存位置**：`prototypes/` 目录，命名格式 `{YYYYMMDD}-{feature}.{ext}`
- **原型通过后方可正式实现**：原型代码可作为参考保留
- **集成测试必须包含脚本化验证**：使用独立脚本调用API或功能点，验证端到端正确性
- **脚本化集成测试保存位置**：`scripts/integration-tests/` 目录
- **未进行原型验证的功能点视为未完成设计**

### 先方案后代码
- **任何问题，无论大小，都不允许直接动手写代码**。必须先向用户提供完整的修改方案：
  1. 问题分析
  2. 改动范围说明
  3. 可选方案及取舍对比
  4. 推荐方案及理由
- **等待用户明确确认后方可动手实现**
- **仅业务代码改动需要确认**：调查、定位、日志采集、测试编写等非业务代码可直接修改

### 禁止补丁摞补丁
- 发现现有实现已经依赖临时兼容、热修、兜底脚本或局部修补维持时，**必须停止继续叠加补丁**
- 回到任务目标重新分析，从最合适的层级直接修正根因

### 按任务目标决定改动规模
- 实现任务目标时，若最佳方案需要重构结构、调整分层或重写链路，**必须直接采用**
- **禁止为了少改几行而牺牲正确性、可维护性、可验证性或长期稳定性**

### 先修结构性问题，再修表象报错
- 如果根因位于流程设计、模块职责、系统边界或数据流方向，**必须优先修正对应结构**
- **禁止只处理最外层报错、局部症状或表面返回值**

### 以代码事实为依据
- 排查任何问题（性能、阻塞、消息丢失等）时，**必须先通过代码阅读追踪完整调用链路**，得出自己的结论
- **不得盲从用户的假设或描述**，须用代码事实验证或推翻

### 测试驱动开发（TDD）
- 针对功能需求，**先编写测试**，确认测试通过后再完成实现
- **单元测试**：纯函数、无副作用的逻辑，使用 `ert` 编写，无外部依赖
- **集成测试**：端到端流程验证，放在 `tests/integration/` 目录下，可依赖外部 API

### Commit 信息
- 每次修改代码后，提供一行简洁的英语 commit message（仅输出文本，不执行 git 命令）
- 格式遵循上述文档行文风格，使用 Conventional Commits 前缀
- 前缀包括 `feat` `fix` `refactor` `docs` `test` `chore`
- 详细说明记录在 ai-context 文档中，commit message 保持简洁

---

## 注释规范（强制）

### 注释原则
- **只在逻辑确实不显而易见、且对理解代码至关重要时才写注释**，其余情况不写
- **注释必须严格描述代码本身的业务意图或约束**，禁止以下内容：
  - 解释代码在做什么（叙述性注释）
  - 提及规范文档或工具名称（如 AGENTS.md、Cursor 等）
  - 记录本次修改原因或 issue 背景（这些应记录在 ai-context）

### 文件头注释
```elisp
;;; chat-module.el --- Short description -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: convenience, tools, llm

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Longer description of the module's purpose and usage.

;;; Code:

;; 代码从这里开始

(provide 'chat-module)
;;; chat-module.el ends here
```

### 函数文档字符串
- **所有公共函数必须有文档字符串**，说明函数用途、参数、返回值
- **使用 Emacs 标准格式**：参数大写，可选参数用 `&optional`，余参用 `&rest`
```elisp
(defun chat-session-create (name &optional model)
  "Create a new chat session with NAME.

NAME is a string identifying the session.
MODEL is an optional symbol specifying the LLM model to use;
if nil, the default model from `chat-default-model' is used.

Returns the newly created session object."
  ;; ...
  )
```

---

## 项目特定约束（强制）

### 纯 Emacs 原则
- **零外部依赖**：核心功能仅使用 Emacs 内置功能和标准库
- **可选依赖**：外部工具（如 Python、Node）仅作为工具锻造的可选语言，核心不依赖
- **兼容性**：支持 Emacs 27+，优先使用广泛支持的 API

### API 设计规范
- **向后兼容**：公共 API 变更需保持向后兼容，或提供废弃周期
- **配置优先**：可配置的行为使用 `defcustom` 而非硬编码
- **钩子支持**：扩展点提供标准 Emacs 钩子（`defvar chat-some-hook`）

### 工具锻造层特殊规则
- **多语言支持**：工具锻造支持多种语言，但必须有明确的执行策略和安全沙箱
- **依赖管理**：外部语言工具的依赖必须在执行前检查，提供清晰的安装引导
- **版本隔离**：用户自定义工具与系统内置工具命名空间隔离，防止冲突

---

## 适用范围 / Scope

- **chat.el** 仓库内任何由 AI/Agent/IDE 参与的开发、重构、排错、文档修改均需遵守上述规则。
- 若本次对话未改动代码或仅做纯答疑，可仅在 ai-context 中记录会话概要，并在 troubleshooting 中注明"本次无新增避坑条目"（或等效说明）。

---

*此文件为与工具无关的规范，任何 AI 或 IDE 在参与本仓库开发时均应遵守。*
