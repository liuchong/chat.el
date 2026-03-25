# Basic OpenClaw P0

## Requirements

把仓库推进到基础 openclaw 的最低可用线
先完成默认文件工具暴露
先补危险操作审批
先增强最小 tool loop

## Technical Decisions

本阶段只做 P0
不处理真正异步请求
不处理复杂上下文选择
审批只覆盖高风险工具
默认把文件工具作为内置工具注册到 forge
工具执行结果统一转成字符串再回灌给模型

## Completed Work

新增 `chat-approval.el`
增加统一审批入口
默认要求审批的工具包括 `files_write` `files_replace` `files_patch` `shell_execute`
在 `chat-files.el` 中增加内置文件工具注册
默认注册 `files_read` `files_read_lines` `files_list` `files_grep` `files_write` `files_replace` `files_patch`
在 `chat-tool-caller.el` 中接入审批检查
在 `chat-tool-caller.el` 中把非字符串工具结果统一转成字符串
在 `chat-tool-caller.el` system prompt 中加入审批提示
在 `chat.el` 中确保 load all 之后重新注册内置文件工具
在 `chat-ui.el` 中把 tool loop 上限从 3 提到 6
在 `chat-ui.el` follow up prompt 中加入审批拒绝后的约束
新增 `tests/unit/test-chat-approval.el`
扩充 `test-chat.el` 和 `test-chat-tool-caller.el`

## Pending Work

`chat-llm.el` 仍然使用同步请求
真正的非阻塞和取消能力仍属于 P1
上下文仍然是简单滑窗
还没有 `apply_patch` 风格的专用编辑工具

## Key Code Paths

`chat-approval.el`
`chat-files.el`
`chat-tool-caller.el`
`chat-ui.el`
`chat.el`

## Verification

执行了 `emacs -Q -batch -l tests/run-tests.el`
本次结果为 93 个测试里 91 个通过 2 个跳过 无失败

## Issues Encountered

本次无新增避坑条目
