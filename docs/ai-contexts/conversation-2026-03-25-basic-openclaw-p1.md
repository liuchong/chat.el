# Basic OpenClaw P1

## Requirements

把非流式请求主链路改成真正异步
让 UI 通过统一 callback 流程处理请求成功和失败
让流式结束后的 follow up 也走异步 tool loop
让 provider 的 request hook 和 stream hook 真正进入主链路

## Technical Decisions

保留 `chat-llm-request` 作为同步兼容接口
新增 `chat-llm-request-async` 和 `chat-llm-cancel-request`
同步和异步都复用统一的请求构造和响应解码逻辑
provider request hook 同时兼容 `:request-fn` 和 `:build-request-fn`
provider response hook 和 stream hook 在主链路统一消费
UI 取消操作同时覆盖流式 process 和非流式 request handle

## Completed Work

在 `chat-llm.el` 中新增异步请求接口
在 `chat-llm.el` 中新增异步取消接口
在 `chat-llm.el` 中抽出统一的 request builder response parser request url 和 response decode 逻辑
在 `chat-ui.el` 中把非流式请求改成真正 callback 式
在 `chat-ui.el` 中新增异步 tool loop 解析函数
在 `chat-ui.el` 中新增统一错误渲染
在 `chat-ui.el` 中让取消操作同时支持非流式请求
在 `chat-ui.el` 中让流式结束后的 follow up 走异步 tool loop
在 `chat-stream.el` 中消费 provider `:stream-fn`
在 `chat-llm-kimi.el` `chat-llm-kimi-code.el` `chat-llm-openai.el` 以及 `chat-llm.el` 默认解析器里兼容 list 和 vector 两种 choices 形态
扩充了 `tests/unit/test-chat-llm.el`
扩充了 `tests/unit/test-chat-stream.el`
扩充了 `tests/unit/test-chat-ui.el`

## Pending Work

当前异步 HTTP 仍基于 `url-retrieve`
还没有更强的超时和中断状态管理
上下文仍然是简单滑窗
还没有更适合 coding workflow 的 patch 编辑工具

## Key Code Paths

`chat-llm.el`
`chat-ui.el`
`chat-stream.el`
`chat-llm-kimi.el`
`chat-llm-kimi-code.el`
`chat-llm-openai.el`

## Verification

执行了 `emacs -Q -batch -l tests/run-tests.el`
本次结果为 100 个测试里 98 个通过 2 个跳过 无失败

## Issues Encountered

流式 provider parser 对 `choices` 的容器类型假设过强
测试和不同 JSON 解码路径可能产生 list 或 vector
需要在 provider parser 中同时兼容这两种结构
