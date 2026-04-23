# Imported Log

- Type: logs
- Attention: records
- Status: imported
- Scope: legacy-session
- Tags: imported, legacy, ai-context

## Original Record

# Code Mode Tool Calling Fix
## Requirements
修复 `code-mode` 把工具调用漂移成 XML 的问题。
恢复 `code-mode` 中 `function_call` 的实际可用性。
保证 `code-mode` 与主聊天模式共享同一套 JSON tool calling 契约。
## Technical Decisions
不再让 `code-mode` 维护独立的工具协议提示词。
`chat-code.el` 改为通过 `chat-tool-caller-build-system-prompt` 构造系统提示。
`chat-code.el` 最终响应统一通过 `chat-tool-caller-process-response-data` 和 follow-up tool loop 处理。
顺手修正了 `tests/unit/test-chat-tool-caller.el` 中 approval mock 的过期参数签名。
工具 follow-up 的异步回调必须回到原始 `code-mode` buffer 后再操作 marker 和 UI。
调试日志默认只落盘到 `~/.chat/chat.log`，不再默认刷到 minibuffer。
正文里夹带的 inline JSON tool call 也必须被识别并从展示文本里剥离。
如果自动 tool follow-up 到达安全上限，界面必须显示可读提示而不是最后一段原始 tool JSON。
`code-mode` 的工具执行上下文必须继承当前项目根目录，而不是退回到 chat.el 默认允许目录。
shell 工具需要内建只读白名单，并安全支持 `cd <allowed-dir> && <readonly command>` 这种无 shell 扩展的探索形式。
`code-mode` 需要一个明确的运行状态通道，让用户知道 AI 仍在执行、已经完成、失败、取消或因 loop limit 停止。
`code-mode` prompt 需要升级为生产力工具级约束，明确当前项目根目录、工具优先级、失败回退和停止条件。
编程场景需要把项目内的 `AGENTS.md` 自动纳入上下文，而不是依赖模型自行发现。
一些工程纪律必须写死并每次发送，例如项目规则优先、代码事实优先于注释和文档、不要伪造结论。
## Completed Work
更新了 `chat-code-system-prompt`，去掉静态且错误的工具清单。
让 `code-mode` 请求链路复用共享 JSON tool calling prompt。
让 `code-mode` 在非流式和流式完成后都走统一的 tool call 解析和 follow-up 流程。
让 `code-mode` 在会话历史中保存 assistant 内容、tool calls、tool results 和 raw request/response。
新增了 `chat-code-send-to-llm-builds-json-tool-prompt` 回归测试。
新增了 `chat-code-finalize-response-resolves-json-tool-call` 回归测试。
修正了 `tests/unit/test-chat-tool-caller.el` 中的 approval mock 参数签名。
修复了 `code-mode` tool follow-up 在请求哨兵上下文里直接操作 UI marker 导致的 `integer-or-marker-p nil` 崩溃。
修复了 `chat-tool-caller` 对 JSON `false` 的参数处理，避免 `recursive` 被错误当成真值。
修复了 `chat-files-list` 在未提供 pattern 时的默认过滤逻辑。
把 `code-mode` 的工具结果可视摘要收敛为简短摘要，不再把整段结果直接展示给用户。
新增了 `chat-tool-caller-normalizes-json-false-to-nil` 回归测试。
增强了 `chat-code-finalize-response-resolves-json-tool-call`，覆盖异步回调不在 UI buffer 的场景。
为 `chat-tool-caller` 增加了 balanced inline JSON fragment 提取逻辑，并在渲染前剥离可执行 tool JSON。
让 `chat-code` 在 tool loop 达到安全上限时记录 `:tool-loop-limit-reached`，展示安全提示并继续保留工具摘要。
新增了 `chat-tool-caller-extracts-content-from-inline-json` 回归测试。
新增了 `chat-code-display-processed-response-hides-tool-json-at-loop-limit` 回归测试。
让 `chat-tool-caller-execute` 在 `code-mode` 下自动把当前项目根目录加入有效文件访问根目录，并把 shell 工作目录对齐到项目根目录。
为 shell 工具加入了 builtin readonly whitelist，覆盖 `pwd` `ls` `find` 等常见只读探索命令。
为 shell 工具加入了安全解析的 `cd <allowed-dir> && <readonly command>` 支持，仍然通过 `process-file` 执行而不是走 shell。
新增了 `chat-tool-caller-allows-code-project-root-for-file-tools` 回归测试。
新增了 `chat-tool-caller-uses-project-root-as-shell-working-directory` 回归测试。
新增了 `chat-tool-shell-whitelist-includes-common-readonly-commands` 回归测试。
新增了 `chat-tool-shell-executes-safe-cd-prefix` 回归测试。
把 `chat-code-system-prompt` 升级为生产力工具级指导，补充项目根目录、只读探索优先级、失败回退和停止纪律。
新增了 `chat-code--operation-guardrails`，把当前 session 的 project root 和 focus file 注入到运行时约束中。
让 `code-mode` 使用 header line 持续显示状态，并覆盖 `idle` `running` `success` `failed` `cancelled` `stopped`。
把 `chat-code-tool-loop-max-steps` 默认值改为 `100`，并同步把 `chat-ui-tool-loop-max-steps` 默认值改为 `100`。
新增了 `chat-code-handle-llm-error-updates-status` 回归测试。
新增了 `chat-code-cancel-updates-status` 回归测试。
新增了 `chat-code-tool-loop-default-is-production-sized` 回归测试。
在 `chat-context-code.el` 中加入了项目 `AGENTS.md` 自动发现和注入逻辑，并作为高优先级上下文源发送。
把 `chat-code` 的 prompt 结构化为 `Non-negotiable rules`、`Programming best practices`、`Operational guardrails` 三层。
新增了 `chat-context-code-build-includes-project-agents-file` 回归测试。
在 `chat.el` 入口启用了 `load-prefer-newer`，并清理了陈旧 `.elc`，避免旧字节码覆盖新源码。
把 `code-mode` 请求入口改为先经过 `chat-context-prepare-messages`，对较早历史生成系统摘要，而不是简单裁掉旧消息。
新增了 `chat-code-history-max-tokens`、`chat-code-max-output-tokens`、`chat-code-request-timeout`、`chat-code-request-safety-margin` 这些预算和超时控制项。
`chat-code` 现在会读取 provider 的 `:context-window` 和 `:max-output-tokens` 元数据，用来计算安全的请求预算。
工具 follow-up 消息不再塞入完整原始结果，而是优先对 plist 风格文件结果、文件列表结果和普通文本结果做摘要压缩。
流式和非流式请求都会显式带上输出 token 预算，非流式和 tool follow-up 还会带上更高的 coding 场景 timeout。
新增了 `chat-code-send-to-llm-summarizes-older-history-before-request` 回归测试。
新增了 `chat-code-tool-followup-summarizes-structured-results` 回归测试。
`code-mode` 的流式渲染改为持续对累计内容做 `chat-tool-caller-extract-content` 净化，不再先把原始 `function_call` JSON 直接刷到聊天区。
`code-mode` 现在同时在 header line 和 mode line 显示 `状态 + 模型 + 阶段`，让用户在 Emacs 下方也能看到运行态。
`code-mode` 在请求启动时会先展示一条简短的人类可读进度文本，而不是直接显示结构化工具内容。
`chat-files-register-built-in-tools` 现在注册 `files_find`，用于目录级递归文本发现，避免模型错误地拿 `files_grep` 去读目录。
工具提示词现在明确区分 `files_find` 和 `files_grep` 的适用范围。
运行时约束现在明确允许“用户明确要求创建或修改文件”时使用写工具，不再被只读提示误导成把文件内容打印到对话框。
目录列表摘要对短列表会尽量保留全部文件名，而不是只保留前两三个名字。
补充了 tool prompt 的 `Tool usage guidance` 区块，明确 `files_list`、`files_find`、`files_grep`、`files_read`、`files_read_lines`、`files_write`、`files_patch`、`shell_execute` 的用法边界。
`chat-tool-caller-process-response-data` 现在接受可选 session，并把它传给执行层审批逻辑。
`code-mode` 与 `chat-ui` 的 tool loop 现在都会把当前 session 传入 tool 执行，避免 session 级 auto-approve 在这些入口失效。
`code-mode` 的 mode line 不再依赖默认 `mode-line-process` 插槽，而是显式设置本地 `mode-line-format` 显示 `模型|状态|阶段`。
工具结果摘要新增了对 `files_find` 返回的 `:matches` 和 `files_read_lines` 返回的 `:lines` 的可读摘要，避免模型只能看到 `(:directory` 或 `msg.go ok` 这种无效反馈。
新增了 `chat-code-tool-summary-shows-files-find-matches`、`chat-code-tool-summary-shows-read-lines-content`、`chat-tool-caller-process-response-data-uses-session-for-approval` 回归测试。
## Pending Work
建议后续做一轮真实 Emacs 交互冒烟，确认 `code-mode` 中工具执行后的界面展示和 tool follow-up 体验符合预期。
如果后续发现某个 provider 会返回特别大的结构化 tool result，可以继续为特定 tool 增加更细粒度的领域摘要，而不是回退到粗暴裁剪。
如果外部项目里仍然偶发 `files_read` 的 `number-or-marker-p nil`，需要再单独做一次最小复现，因为当前仓库单测尚未稳定复现这个错误。
如果用户仍然在真实界面里看不到底部状态栏，需要进一步确认是否是其 Emacs 配置隐藏了 mode line，而不是 `chat-code` 本身未设置。
## Key Code Paths
`chat-code.el`
`chat-tool-caller.el`
`chat-llm.el`
`chat-llm-kimi-code.el`
`chat-files.el`
`chat-log.el`
`chat-ui.el`
`tests/unit/test-chat-code.el`
`tests/unit/test-chat-tool-caller.el`
`tests/unit/test-chat-ui.el`
## Verification
运行了 `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`。
结果为 156 tests discovered，154 passing，2 skipped，0 failures。
## Issues Encountered
`code-mode` 自己维护系统提示和响应后处理，导致它脱离了共享 JSON tool calling 契约。
新增了一个 troubleshooting 条目来记录这种 mode specific prompt drift 问题。
请求哨兵和异步回调默认不在 UI buffer 中执行，不能直接依赖 buffer-local marker。
调试日志同时写文件和 echo 到 minibuffer 会把大 payload 暴露到界面下方，严重影响体验。
同一轮响应里如果是“说明文字 + inline JSON tool call”，执行层和展示层会走出两套不同结果，必须用同一套可识别 fragment 做剥离。
工具循环被安全上限截断时，如果不显式标记 limit case，最后一轮 raw JSON 会让用户误以为界面卡死。
如果 `code-mode` 在外部项目里运行，但工具执行上下文没有继承 session project root，模型会在文件工具和 shell 工具之间来回试错直到撞上 loop limit。
只读目录探索如果既没有 builtin whitelist 又不支持安全 `cd` 前缀，用户就会在批准弹窗和命令拒绝之间反复打断。
如果状态只存在内部 request handle 而没有用户可见展示，用户会把正常执行误判成卡死或中断。
如果 prompt 不明确强调当前项目根目录、工具优先级和失败回退，模型会更容易退化成无效探索循环。
如果项目规则文件只是“可能存在”，而没有被主动送入上下文，模型很容易忽略掉本应严格遵守的工程规范。
如果陈旧 `.elc` 仍然优先于源码加载，调试会出现“明明改了但运行表现没变”的假象。
这一次没有新增独立的 troubleshooting 条目，因为本轮主要是把已有 `chat-context` 摘要能力和请求预算控制接入 `code-mode`，属于已有修复方向的深化而不是新的 failure mode。
另一个直接暴露出来的问题是：如果把“只读问题禁止写工具”写成无条件规则，模型在用户明确要求新建 spec 时也会退化成只打印文件内容而不真正落盘。
日志进一步暴露出一个产品层问题：即使底层工具本身可用，只要摘要层把 `files_find` 压成 `(:directory`、把 `files_read_lines` 压成 `ok`，模型就等于没真正读到结果，最终仍会表现成“没读全”。
