# Stability Repair

## Requirements

根据前一轮 review 结果做一轮稳定性修复
优先处理真实可复现的安全边界和参数结构问题
补充回归测试并确认全量测试通过

## Technical Decisions

文件路径校验统一使用真实路径解析
非存在路径通过最近存在祖先目录做 `truename` 归一化
shell 工具不再走 shell 字符串执行
shell 工具只接受白名单命令并拒绝元字符
`files_patch` 同时兼容 plist 和 JSON 解码后的 alist patch
`chat-llm-stream` 先回退到异步单次回调接口
UI 在请求未结束前禁止再次发送消息
AI 工具锻造必须经过显式审批
AI 生成的 elisp 工具源码只允许单个 `lambda` 顶层表达式
异步 HTTP 请求必须绑定超时 timer 并在取消时清理
默认文件访问范围收紧到当前目录和临时目录

## Completed Work

修复了 `chat-files.el` 的 symlink 越权访问问题
修复了 `chat-files.el` 对 JSON 风格 patch 参数无法识别的问题
统一了 `chat-files-list` 递归和非递归返回结构
收紧了 `chat-tool-shell.el` 的命令校验
将 `chat-tool-shell.el` 从 `call-process-shell-command` 改为 `process-file`
修复了 `chat-llm.el` 中 `chat-llm-stream` 调用不存在函数的问题
在 `chat-ui.el` 增加了请求互斥保护
扩展了流式 sentinel 对 `exited` 事件的处理
补充了 `test-chat-files.el` `test-chat-tool-shell.el` `test-chat-session.el` `test-chat-llm.el` `test-chat-ui.el`
确认 session role 的 keyword round trip 是正常的
为 `chat-approval.el` 增加了工具生成审批
为 `chat-tool-forge.el` 增加了单一 lambda 编译约束
为 `chat-tool-forge-ai.el` 接入了审批检查
为 `chat-context.el` 增强了 tool call 和 tool result 的摘要与 token 估算
为 `chat-llm.el` 补上了异步请求 timeout timer 与取消清理
将 `chat-files.el` 默认访问目录从家目录收紧到当前目录与临时目录
修正文档中 `chat-files-replace` 对 regex 的误导性描述

## Pending Work

本轮 review 中列出的剩余修复点已经完成
暂时没有新增待办

## Key Code Paths

`chat-files.el`
`chat-tool-shell.el`
`chat-approval.el`
`chat-tool-forge-ai.el`
`chat-tool-forge.el`
`chat-llm.el`
`chat-context.el`
`chat-ui.el`
`tests/unit/test-chat-files.el`
`tests/unit/test-chat-approval.el`
`tests/unit/test-chat-tool-forge-ai.el`
`tests/unit/test-chat-tool-forge.el`
`tests/unit/test-chat-tool-shell.el`
`tests/unit/test-chat-session.el`
`tests/unit/test-chat-llm.el`
`tests/unit/test-chat-ui.el`

## Verification

执行了 `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
共运行 122 个测试
120 个通过
2 个跳过
无失败

## Issues Encountered

macOS 临时目录会把 `/var` 解析到 `/private/var`
symlink 修复后测试里的路径断言需要改为真实路径
review 中关于 session role 反序列化的担忧经过回归测试验证后未复现
收紧工具锻造后 旧测试里使用 `defun` 形式的源码需要改成单个 `lambda`
`chat-llm--post-async` 增加 timeout timer 时很容易出现括号不平衡
这种嵌套结构必须先用 `check-parens` 再跑全量测试
