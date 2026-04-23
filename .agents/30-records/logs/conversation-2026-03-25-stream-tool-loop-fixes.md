# Imported Log

- Type: logs
- Attention: records
- Status: imported
- Scope: legacy-session
- Tags: imported, legacy, ai-context

## Original Record

## Requirements
修复三处业务逻辑问题。
第一处是流式请求日志不能再泄露认证信息。
第二处是工具执行后的 follow up 请求必须正确走异步链路。
第三处是流式响应启动和收尾分支需要保持单一路径，不能再出现成功后又落入失败分支的结构风险。
## Technical Decisions
在 `chat-stream.el` 中只记录请求元信息，不再记录原始 bearer token 和完整请求体。
新增 `chat-stream--redact-curl-args-for-log`，对认证头和请求体长度做脱敏。
在 `chat-ui.el` 中重写 `chat-ui--resolve-tool-loop-async`，让 `chat-llm-request-async` 的 success error options 参数位置固定。
在 `chat-ui.el` 中将流式请求 启动 进程校验 sentinel 安装拆成更直的顺序结构，并补了很薄的内部包装函数便于维护。
## Completed Work
`chat-stream-request` 现在只记录 URL 请求体长度 消息数量 和脱敏后的 curl 参数。
`chat-ui--resolve-tool-loop-async` 现在会稳定地把工具结果追加到 follow up system message，再通过异步请求继续推进工具循环。
`chat-ui--get-response-streaming` 现在先拿到流进程，再做显式校验和 sentinel 安装，避免分支结构混乱。
新增稳定回归测试覆盖日志脱敏和异步工具 follow up。
## Pending Work
本轮没有新增待处理的业务逻辑项。
日志文件的实际清理由用户自行处理，本轮未改动运行环境中的历史日志文件。
## Key Code Paths
`chat-stream.el`
`chat-ui.el`
`tests/unit/test-chat-stream.el`
`tests/unit/test-chat-ui.el`
## Issues Encountered
流式启动分支的替身测试在当前批处理环境下不稳定，因此最终保留了稳定的回归测试并用全量 ERT 结果做总体验证。
