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

参考：

- `docs/README.md`
- `docs/ai-contexts/README.md`
- `docs/troubleshooting-pitfalls.md`
- `.cursor/rules/documentation-maintenance.mdc`

## Development Workflow

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
推荐原型语言：

- Shell
- Python
- JavaScript

原型文件放在 `prototypes/`。
命名格式是 `YYYYMMDD-feature.ext`。

### Test Driven Fixes

- 修每一个 bug 都要补至少一条测试
- 新增外部自由结构数据解析时要补测试
- 单元测试使用 `ert`
- 集成测试放在 `tests/integration/`

### Verification

优先使用：

```bash
emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit
```

不要把 `tests/run-tests.sh` 当成唯一真相。

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
