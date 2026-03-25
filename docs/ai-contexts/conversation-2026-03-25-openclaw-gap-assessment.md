# OpenClaw Gap Assessment

## Requirements

评估当前仓库距离一个基本 openclaw 形态还有多远
判断是否已经达到纯 Emacs AI 对话和 coding assistant 的最低可用线
给出可以分阶段补齐的缺口判断

## Technical Decisions

评估口径以纯 Emacs 内 coding assistant 为主
不把多渠道消息 语音 智能家居当作当前阶段必需项
优先看对话 会话 流式 工具调用 文件读写 Shell 执行 审批 上下文管理这些最小闭环
结论同时参考源码事实和本地测试结果

## Completed Work

阅读了 `chat.el` `chat-ui.el` `chat-session.el` `chat-tool-caller.el` `chat-tool-forge.el` `chat-files.el` `chat-stream.el` `chat-context.el` `chat-llm.el` `chat-tool-shell.el` `chat-tool-forge-ai.el` `chat-llm-kimi-code.el`
阅读了关键测试文件
执行了 `emacs -Q -batch -l tests/run-tests.el`
测试结果为 87 个测试里 85 个通过 2 个跳过 无失败
确认当前仓库已经具备会话持久化 多 provider 抽象 基础流式 基础 tool loop 自定义工具锻造和文件操作函数库
确认当前仓库离基本 openclaw 的主要缺口不在聊天外壳 而在工具暴露 非阻塞执行 审批链路和工作流闭环

## Pending Work

需要把 `chat-files.el` 中的文件能力真正注册为内置工具
需要把 LLM 请求从当前同步阻塞链路改成真正异步可取消链路
需要加入危险操作审批
需要补一个更接近 coding agent 的 built in tool set
需要提升上下文和多步任务能力

## Key Code Paths

`chat.el`
`chat-ui.el`
`chat-session.el`
`chat-tool-caller.el`
`chat-tool-forge.el`
`chat-files.el`
`chat-stream.el`
`chat-context.el`
`chat-llm.el`
`chat-tool-shell.el`
`chat-tool-forge-ai.el`

## Verification

执行了 `emacs -Q -batch -l tests/run-tests.el`
结果为通过

## Issues Encountered

`tests/run-tests.sh` 目前不能直接跑通
原因是脚本没有把 `chat-tool-caller.el` 相关加载链补全
仓库内真正可用的测试入口是 `tests/run-tests.el`
`chat-files.el` 目前只提供 tool spec 没有完成内置注册
这意味着默认情况下模型并不能直接获得文件读写工具
`chat-ui.el` 虽然把请求放进 timer 里启动 但真正网络请求仍然走 `url-retrieve-synchronously`
这不是严格意义上的非阻塞实现
`chat-llm.el` 目前没有消费 provider 自定义的 `:build-request-fn`
像 `chat-llm-kimi-code.el` 里的 provider hook 现在没有完全进入主链路
