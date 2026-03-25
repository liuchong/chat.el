## Requirements
修复两个运行时问题。
第一是流式响应启动后仍然错误渲染为启动失败。
第二是 Kimi Code 在工具 follow up 阶段走异步请求时返回 403，导致执行流程卡死。
## Technical Decisions
Kimi Code 的异步请求改为使用 curl 传输。
这样 follow up 请求和已验证可用的流式传输保持一致，避免继续依赖 `url.el` 的兼容性表现。
流式启动判断单独提炼为 `chat-ui--stream-started-p`，明确只要拿到非空句柄就视为启动成功。
## Completed Work
在 `chat-llm.el` 中新增 `chat-llm--post-async-curl` 和 `chat-llm--post-async-dispatch`。
在 `chat-llm-kimi-code.el` 中为 `kimi-code` 配置 `:async-transport 'curl`。
在 `chat-ui.el` 中新增 `chat-ui--stream-started-p` 并用于流式启动分支。
新增回归测试覆盖 provider 异步 curl 分派和流式启动判断。
## Pending Work
建议用户重新加载当前 Emacs 会话中的相关模块后再复测真实聊天链路。
本轮未清理已有日志文件。
## Key Code Paths
`chat-llm.el`
`chat-llm-kimi-code.el`
`chat-ui.el`
`tests/unit/test-chat-llm.el`
`tests/unit/test-chat-ui.el`
## Verification
运行 `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`。
结果是 126 个测试中 124 个通过，2 个 Kimi 实网测试保持跳过。
## Issues Encountered
基于 `cl-letf` 的流式启动分支集成替身测试在当前批处理环境中不稳定，所以改为抽出纯判断函数并用稳定单元测试锁定该规则。
