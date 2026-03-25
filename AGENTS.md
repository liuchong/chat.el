# Instructions for AI Agents and IDEs

本文档适用于所有在本仓库内工作的 AI Agent 和 IDE 插件。
开始工作前先读一遍。
结束工作前再对照检查一遍。


Copyright 2026 chat.el contributors.

## First Principles

### Safety First

- 不执行会修改 git 历史或远端状态的命令
- 不信任模型返回的工具参数
- 危险工具必须先审批
- 敏感信息只使用 `auth-source`
- 提交到 git 的任何文件都不得包含直接或间接泄露敏感信息的内容
- 敏感信息包括但不限于密码 密钥 token 用户环境 路径 凭证 内网信息和可识别用户身份的数据

### Code First

- 先看代码事实再下结论
- 所有需求 设计 开发都必须先调查可行性
- 只能采用切实可行 可以验证 可以落地的方案
- 不得基于假设或未验证能力做空想设计
- 外部依赖 API 调用 协议交互必须先验证可用性
- 复杂功能和外部系统集成功能必须先做原型验证
- 设计必须服从当前技术栈 时间 资源和维护成本这些现实约束
- 优先修根因而不是表层报错
- 不要继续叠加临时补丁
- 为了正确性可以直接重构

### Async First

- 所有 I/O 都不能阻塞 Emacs 主循环
- 长请求必须可取消
- 定时器和进程结束后必须清理

## Absolutely Forbidden

AI 和 IDE 不得执行以下命令或动作：

- `git commit`
- `git push`
- `git rebase`
- `git merge`
- `git cherry-pick`
- `git reset`
- `git tag`
- `gh pr create`
- `gh pr merge`

允许的 git 命令只限只读：

- `git status`
- `git log`
- `git show`
- `git diff`

违反这一条视为严重错误。

## Documentation Must Be Updated

每次开发会话结束时必须同步更新文档。

### Required Outputs

1. 在 `docs/ai-contexts/` 新建或更新会话记录
2. 如果发现新的失败模式或修复模式 更新 `docs/troubleshooting-pitfalls.md`

### AI Context Naming

使用这个格式：

```text
conversation-YYYY-MM-DD-topic.md
```

### Required AI Context Sections

- `Requirements`
- `Technical Decisions`
- `Completed Work`
- `Pending Work`
- `Key Code Paths`
- `Verification`
- `Issues Encountered`

如果本次没有新增避坑条目，需要在 ai-context 里明确写出。

### Troubleshooting Update Rule

更新 `docs/troubleshooting-pitfalls.md` 时必须遵守现有结构。

- 把新条目放到最接近的主题 section
- 使用固定字段顺序 `Problem` `Cause` `Solution`
- 先合并重复条目 再考虑新增条目
- 不要随意打乱 topic 顺序
- 如果确实需要新增 topic 只新增一级 `##` 主题

### Documentation Directory Structure

`docs/` 目录按内容篇幅和深度分层：

| 目录 | 用途 | 内容示例 |
|------|------|----------|
| `ai-contexts/` | 会话级开发记录 | 每次开发会话的完整记录 |
| `tips/` | 短形式的灵感和速记 | 代码片段、快捷技巧、aha moments |
| `articles/` | 中等篇幅专题文章 | 技术深入、最佳实践、实现故事 |
| `books/` | 长篇系统性文档 | 架构指南、设计原则、完整规范 |

选择依据：
- 单条灵感或速记 → `tips/`
- 一个主题的完整探讨 → `articles/`
- 成体系的系统性内容 → `books/`

参考：

- `docs/README.md`
- `docs/ai-contexts/README.md`
- `docs/troubleshooting-pitfalls.md`
- `.cursor/rules/documentation-maintenance.mdc`

## Development Workflow

### Standard Task Entry Flow

每次开发任务开始前都必须按这个顺序执行：

1. 先完整阅读 `AGENTS.md`
2. 调查当前代码现状 已有实现 相关测试和必要文档
3. 反思当前目标 约束 风险和已有工作
4. 判断当前方向是否会掉进死胡同
5. 先给方案 再进入业务代码实施

这里的死胡同包括但不限于：

- 工作流陷入死循环
- 在同一个坑里反复修改却没有实质进展
- 补丁摞补丁导致结构越来越差
- 已经偏离目标却继续局部修补
- 明显应该重新审视设计或直接重构却还在硬撑

发现进入这些状态时必须停下来。
先重新调查现状。
再重新审视方案。
必要时直接重构而不是继续来回修补。

### Plan Before Business Code

任何业务代码改动都要先给用户方案。
方案至少包含：

1. 问题分析
2. 改动范围
3. 可选方案和取舍
4. 推荐方案和理由

调查、定位、日志采集、测试编写、纯文档修改可以直接进行。

### Prototype Before Formal Integration

关键功能点要先做原型验证。
复杂功能或涉及外部系统的功能必须先验证可行性再进入正式实现。
推荐原型语言：

- Shell
- Python
- JavaScript

原型文件放在 `tests/prototypes/`。
命名格式是 `YYYYMMDD-feature.ext`。

原型测试是测试的一种，用于验证关键功能点或外部系统集成的可行性。

### Test Driven Fixes

- 修每一个 bug 都要补至少一条测试
- 新增外部自由结构数据解析时要补测试
- 单元测试使用 `ert`
- 集成测试放在 `tests/integration/`
- 原型测试放在 `tests/prototypes/`
- Spec 文件放在 `specs/`

### Verification

优先使用：

```bash
emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit
```

不要把 `tests/run-tests.sh` 当成唯一真相。

### Reflection During Execution

- 实施过程中要定期检查当前方向是否偏离目标
- 主动识别过度设计 补丁堆积 脱离现状这些陷阱
- 发现方案不可行或验证结果不成立时必须立即回退到调查和方案阶段
- 如果继续局部修补只会让工作陷入死循环 就应当重新审视设计或直接重构

## Emacs Lisp Rules

### Naming

- 公共符号统一使用 `chat-` 前缀
- 函数名使用 `chat-module-function-name`
- 变量名使用 `chat-module-variable-name`
- 常量使用 `chat-MODULE-CONSTANT`

### Libraries

- 使用 `cl-lib`
- 不使用旧的 `cl`
- 默认启用 `lexical-binding: t`

### Data Structures

- 复杂结构优先用 `cl-defstruct`
- 高频查找优先哈希表
- 配置和常量优先 `defconst`
- 运行时状态优先 `defvar`

### Error Handling

- 用 `condition-case` 捕获具体错误
- 报错信息要让用户看得懂
- 包装错误时保留原始错误文本

### Public API Layout

- 公共 API 放前面
- 内部辅助函数放后面
- 避免循环依赖

## System Specific Rules

### Pure Emacs Core

- 核心功能只依赖 Emacs 内置和标准库
- Python 和 Node 只能作为可选工具锻造执行环境
- 兼容 Emacs 27+

### Tooling Safety

- 文件工具必须做路径校验
- shell 工具不能依赖 shell 字符串执行
- AI 生成工具必须先审批
- elisp 工具源码必须是单个顶层 `lambda`

### Session and State

- 会话状态必须隔离
- 持久化边界必须清晰
- 不要跨 session 共享可变状态

## Documentation Style

- 用自然行文
- 一句话只说一件事
- 避免层层嵌套
- 字面可读 读出来也通顺

示例：

- 不佳：`chat-files.el（文件操作模块）提供了read/grep/modify等功能`
- 良好：`chat-files.el provides file operations including read search and modify`

## Comment Rules

- 只在不明显但关键的逻辑前写注释
- 注释描述代码约束和业务意图
- 不要写叙述性注释
- 不要在注释里记录本次修改背景

## Commit Message Output

每次改动结束后提供一行英文 commit message 建议。
只输出文本。
不要执行 git 提交。

允许的前缀：

- `feat`
- `fix`
- `refactor`
- `docs`
- `test`
- `chore`

## Scope

本文件适用于整个 `chat.el` 仓库内的代码、测试、文档、排障和重构工作。
如果只是纯答疑，也至少要在 ai-context 里留一条会话记录摘要。
