# Basic OpenClaw P2

## Requirements

让上下文准备更接近 coding assistant
让模型在长对话里优先保住系统提示和最后用户问题
补一个更像 openclaw 的 patch 工作流接口
让编辑后结果能直接回给模型用于下一步判断

## Technical Decisions

不引入复杂索引和外部存储
上下文截断使用轻量摘要策略
始终保留前置 system messages
始终尽量保留最后一条非 system 消息
新增 `apply_patch` 作为 `chat-files-patch` 的工作流别名
patch 结果里直接返回 diff 预览

## Completed Work

在 `chat-context.el` 中加入摘要型截断
在 `chat-context.el` 中新增消息摘要和工具结果摘要逻辑
在 `chat-context.el` 中保证截断时优先保留 leading system messages
在 `chat-context.el` 中保证截断时优先保留最后一条非 system 消息
在 `chat-files.el` 中新增 `chat-files-apply-patch`
在 `chat-files.el` 中让 `chat-files-patch` 返回 `:diff`
在 `chat-files.el` 中注册 built in tool `apply_patch`
在 `chat-tool-caller.el` 中加入更明确的 coding workflow 提示
提示内容包括先读再改 优先 patch 改已有文件 改后检查 diff
新增 `tests/unit/test-chat-context.el`
扩充 `tests/unit/test-chat-files.el`
扩充 `tests/unit/test-chat-tool-caller.el`
扩充 `tests/unit/test-chat.el`
在 `chat-approval.el` 中把 `apply_patch` 纳入审批范围

## Pending Work

上下文摘要仍然是启发式文本拼接
还没有项目级文件选择和语义检索
还没有针对 Emacs Lisp 的结构化编辑工具
还没有更强的 diff review 和 revert 工作流

## Key Code Paths

`chat-context.el`
`chat-files.el`
`chat-tool-caller.el`
`chat-approval.el`

## Verification

执行了 `emacs -Q -batch -l tests/run-tests.el`
本次结果为 105 个测试里 103 个通过 2 个跳过 无失败

## Issues Encountered

本次无新增避坑条目
