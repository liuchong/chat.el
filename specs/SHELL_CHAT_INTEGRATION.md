# Shell-Chat Integration Specification

## Overview

统一的无缝 Shell 与 Chat 集成规范，允许用户在任何项目的 REPL 中快速执行跨模式操作，无需完全切换上下文。

## Design Philosophy

**最小上下文切换成本**: 用户可以在当前 REPL 中直接输入另一种模式的命令，而不必先退出、再进入。

## Universal Commands

### 1. In Chat Mode - Quick Shell

在 Chat REPL 中，使用 `!` 前缀直接执行 shell 命令：

```
chat> !ls -la                    # 列出文件
chat> !pwd                       # 显示当前目录  
chat> !git status                # git 操作
chat> !make build                # 构建项目
chat> !cd /path/to/dir           # 切换目录（重要：会保持状态）
```

**Requirements**:
- [ ] `!` 前缀识别为 shell 命令
- [ ] 执行结果直接显示在 REPL 中
- [ ] `!cd` 特殊处理：改变当前工作目录，后续命令使用新目录
- [ ] 目录状态在 chat 和 shell 模式间共享

### 2. Enter Shell REPL Mode

从 Chat 模式进入专门的 Shell REPL：

```
chat> /shell                     # 进入 shell 模式
[/project] $                     # 提示符显示当前目录
```

**Requirements**:
- [ ] `/shell` 命令可用
- [ ] 提示符显示当前工作目录（缩短形式如 `~/project`）
- [ ] Shell 模式保持当前目录状态

### 3. In Shell Mode - Direct Commands

在 Shell REPL 中，直接输入即 shell 命令：

```
[/project] $ ls                  # 直接执行
[/project] $ cat file.txt        # 查看文件
[/project] $ cd src              # 切换目录
```

**Requirements**:
- [ ] 无前缀输入 = shell 命令
- [ ] 所有标准 shell 命令可用
- [ ] 管道、重定向等 shell 特性支持（可选）

### 4. In Shell Mode - Ask AI

在 Shell REPL 中，使用 `?` 前缀问 AI：

```
[/project] $ ?how to fix this error        # AI 回答
[/project] $ ?explain this code            # AI 解释
[/project] $ ?convert to Python            # AI 转换代码
```

**Requirements**:
- [ ] `?` 前缀识别为 AI 查询
- [ ] 不退出 shell 模式即可获得 AI 回答
- [ ] 回答显示后仍在 shell 模式

### 5. Return to Chat Mode

从 Shell 模式返回 Chat：

```
[/project] $ /chat               # 返回 chat 模式
chat>                            # 回到 chat 提示符

# 或
[/project] $ exit                # 同样返回 chat
```

**Requirements**:
- [ ] `/chat` 命令返回 chat 模式
- [ ] `exit` 或 `quit` 同样返回
- [ ] 目录状态保持

## Prompt Design

### Chat Prompt
```
chat>                           # 基本形式
[~/project] chat>              # 显示目录（推荐）
```

### Shell Prompt
```
$                              # 基本形式
[~/project] $                  # 显示目录（推荐）
shell $                        # 明确标识 shell 模式
```

## State Management

### Working Directory Persistence

```
chat> !cd /tmp                 # 在 chat 中切目录
chat> /shell                   # 进入 shell
[/tmp] $ pwd                   # 确认目录已同步
/tmp
[/tmp] $ cd /var               # 在 shell 中切目录
[/tmp] $ /chat                 # 返回 chat
chat> !pwd                     # 确认目录同步
/var
```

**Requirements**:
- [ ] 工作目录在所有模式间共享
- [ ] `!cd` 和 `cd` 都改变共享状态

## Implementation Checklist

### d/ (Rust CLI) ✅ COMPLETE
- [x] `!<cmd>` 在 chat 中执行 shell
- [x] `!cd <dir>` 目录切换
- [x] `/shell` 进入 shell REPL
- [x] Shell REPL 直接命令
- [x] `?<question>` 在 shell 中问 AI
- [x] `/chat` 返回 chat
- [x] 目录状态共享

**Files**: `crates/cli/src/chat.rs`, `crates/cli/src/shell_repl.rs`

### chat.zig (Zig) ⏸️ ARCHIVED
- [ ] `!<cmd>` 在 chat 中执行 shell
- [ ] `!cd <dir>` 目录切换
- [ ] `/shell` 进入 shell REPL
- [ ] Shell REPL 直接命令
- [ ] `?<question>` 在 shell 中问 AI
- [ ] `/chat` 返回 chat
- [ ] 目录状态共享

**Status**: 项目已归档（作为学习参考）。当前仅实现基础 chat 功能，通过 LSP 模式运行。Hybrid mode 非优先。

### chat.el (Emacs) 📋 PLANNED
- [x] Shell tool 作为 AI callable（`chat-tool-shell.el` 已存在）
- [ ] `!<cmd>` 在 chat 中执行 shell（用户快捷方式）
- [ ] `!cd <dir>` 目录切换
- [ ] `/shell` 进入 shell REPL 模式
- [ ] Shell REPL 直接命令
- [ ] `?<question>` 在 shell 中问 AI
- [ ] `/chat` 返回 chat
- [ ] 目录状态共享

**Note**: chat.el 当前通过 RPC 调用 d/ 的核心功能。Shell 执行目前是 AI tool，需要添加用户直接 `!` 和 `?` 前缀快捷方式。

### chatbook (Tauri) 📋 PLANNED
- [ ] `!<cmd>` 在 chat 中执行 shell
- [ ] `!cd <dir>` 目录切换
- [ ] `/shell` 进入 shell REPL
- [ ] Shell REPL 直接命令
- [ ] `?<question>` 在 shell 中问 AI
- [ ] `/chat` 返回 chat
- [ ] 目录状态共享

**Status**: GUI 应用，与 d/ 共享核心。需要设计适合 GUI 的 hybrid mode（可能通过标签页或面板切换）。

## UI/UX Guidelines

### Visual Feedback
- Shell 命令执行前显示 `$ <command>`（黄色）
- AI 查询显示 `🤖 Asking AI...`
- 目录切换后显示 `📁 /new/path`

### Error Handling
- Shell 命令失败：显示红色错误信息，保持在当前模式
- 目录不存在：`cd: no such file or directory: /path`

### Help Text
在每个 REPL 的 `/help` 中必须包含：

```
Quick Shell:
  !<cmd>     - Execute shell command
  !cd <dir>  - Change directory
  /shell     - Enter shell mode

In Shell Mode:
  <cmd>      - Shell command
  ?<q>       - Ask AI
  /chat      - Return to chat
```

## Security Considerations

- `!` 命令执行前可能需要确认（在 plan mode）
- 危险命令（rm -rf /）应有警告或阻止
- Shell 执行权限可配置（允许/禁止某些命令）

## Future Enhancements

- [ ] Tab 补全 shell 命令
- [ ] Shell 命令历史
- [ ] 多行 shell 命令（heredoc）
- [ ] 环境变量共享
- [ ] 自定义快捷别名

## Version

**Spec Version**: 1.0  
**Last Updated**: 2026-04-11  
**Applies To**: All chat projects (d/, chat.zig, chat.el, chatbook)
