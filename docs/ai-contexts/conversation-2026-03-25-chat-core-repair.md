# Chat Core Repair

## Requirements

修复工具调用主链路
统一 prompt 解析和执行契约
让流式和非流式共用响应收尾逻辑
补齐消息持久化字段
修复工具生成链对 `chat-llm-request` 返回值的误用
补充关键回归测试

## Technical Decisions

工具调用协议以单个 JSON 对象为正式格式
解析层同时兼容裸 JSON 和 fenced JSON
工具参数按 `chat-forged-tool-parameters` 映射到 argv
流式结束后复用统一的 tool calling 后处理
会话持久化保存 `tool-calls` `tool-results` `raw-request` `raw-response`
内置无源码工具文件允许被加载但不会尝试编译空源码

## Completed Work

重写了 `chat-tool-caller.el`
修复了 `chat-ui.el` 中同步和流式响应链路的分叉
修复了 `chat-stream.el` 的 SSE 半包处理
修复了 `chat-session.el` 的消息持久化漂移
修复了 `chat-tool-forge-ai.el` 对 LLM 返回值的处理
为 `chat-tool-shell.el` 增加了真实参数 schema 和执行校验
为 `chat-tool-forge.el` 增加了空源码工具加载保护
更新并新增了 `test-chat-tool-caller.el` `test-chat-stream.el` `test-chat-ui.el` `test-chat-session.el` `test-chat-tool-forge-ai.el` `test-chat-tool-forge.el`

## Pending Work

根目录临时脚本仍然保留
这些文件属于历史尝试和一次性修补
因为它们不是本次新增文件且当前工作树已有用户改动
这次没有直接删除或搬迁

## Key Code Paths

`chat-tool-caller.el`
`chat-ui.el`
`chat-stream.el`
`chat-session.el`
`chat-tool-forge-ai.el`
`chat-tool-shell.el`
`chat-tool-forge.el`

## Verification

执行了 `emacs -Q -batch -l tests/run-tests.el`
共运行 83 个测试
81 个通过
2 个跳过
无失败

## Issues Encountered

流式路径原先只做增量显示没有执行工具调用
`content-start` marker 使用右插入语义会导致最终替换失败
tool call 持久化后嵌套参数 key 类型会漂移
内置工具保存为空源码文件后在加载阶段会触发 EOF
内置 `shell_execute` 会被磁盘中的同名空源码工具覆盖
覆盖后会丢失 `compiled-function` 和 `parameters`
这会导致 prompt 退回默认 `input` 参数并在执行时报 `Tool not compiled`
内置 `shell_execute` 注册时如果没有显式 `:is-active t`
工具执行层会因为 `Tool is not active` 拒绝执行
