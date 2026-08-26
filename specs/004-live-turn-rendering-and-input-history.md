# 004: Live Turn Rendering, Run Feedback, and Input History Spec

## Overview

一次 AI 回答不是一段文本，而是一段**过程**：一到多轮请求，每轮可能包含推理、
工具调用、中间说明和最终答案。本 spec 规定这段过程如何被记录、如何被送到
Emacs 前端、如何显示、以及在这段过程中用户能得到什么反馈、能做什么操作。

四条主线：

1. 会话与轮次的过程记录：元数据、每步的类型标记和时间戳
2. 每种输出的展示规则：前缀、字形、折叠
3. 运行反馈：任何时刻用户都能看出程序正在做什么
4. 输入体验：历史召回，以及全程不阻塞

## Current Status

已有的基础比缺口多，缺的主要是接线。

已经存在并可用：

- 会话记录。`chat-session` 带 `id` `name` `created-at` `updated-at` `model-id`
  `metadata`，持久化为 `~/.chat/sessions/<id>.jsonl`
  （`lisp/core/chat-session.el:45`，`chat-session--file-name` 在 226 行）
- 分类记录模型。`chat-transcript-stamp` 可以给消息打
  `:turn` `:step` `:category` `:work` `:reasoning`
  （`lisp/core/chat-transcript.el:204`）
- 折叠策略。`chat-transcript-fold-styles` 已把 `thinking` `tool-work`
  `system-detail` 定为默认折叠、`interim` 定为默认展开
  （`lisp/core/chat-transcript.el:76`）
- 字形区分。`chat-transcript-interim` 是斜体，`chat-transcript-thinking`
  `chat-transcript-tool-call` `chat-transcript-tool-result` 继承 `shadow`
- 多语言前缀。`channel-thinking`→推理、`channel-tool-work`→工具调用、
  `part-tool-call`→调用工具 等键已在 `lisp/core/chat-i18n-zh-cn.el:196`
- 流式传输。curl `-N` + process filter，SSE 逐块解析，推理字段
  `reasoning_content` / `reasoning` / `thinking` 已能提取
  （`lisp/core/chat-stream.el:165`、`273`）
- 异步骨架。agent 循环是事件回调驱动，不是阻塞轮询

确认存在的缺口：

- **事件黑洞。** agent 至少发出 16 种事件，UI 的处理器是一个只有 6 个分支、
  没有兜底 `t` 子句的 `cond`（`lisp/ui/chat-ui.el:2004`）。落地的只有
  `stream-chunk` `tool-event` `message-appended` `response` `followup`
  `agent-end`；被静默丢弃的包括 `stream-reasoning` `turn-start`
  `tool-batch-start` `tool-batch-end` `stream-result` `error`
  `context-transformed` `steering` `prepared-next-turn` `truncated`
- **推理内容全丢。** 推理模型在长思考期间发出的全部内容进入
  `stream-reasoning`，UI 没有该分支，所以整段思考期屏幕不动，只在结束时
  一次性画出最终答案
- **过程记录没被写下。** `chat-transcript-stamp` 只在测试里被调用；生产的
  agent 循环建消息时不打标记（`lisp/agent/chat-agent-loop.el:299`），
  所以磁盘上是一串扁平消息，轮次和步骤只能靠 role 猜
- **默认不流式。** `chat-ui-use-streaming` 默认 `nil`，而且被声明了两次：
  `lisp/ui/chat-ui.el:69` 是 `defvar`，2778 行又是 `defcustom`
- **历史文件路径不是会话字段。** 由 id 推导，前端拿不到一个可直接展示的路径
- **无输入历史。** `chat-mode-map` 没有 M-p / M-n；
  `chat-ui-previous-message` 是个打印"not yet implemented"的空壳
  （`lisp/ui/chat-ui.el:2712`）
- **反馈只有回显区一行。** `Getting response from AI...` 由
  `(message ...)` 打出，会被后续任何消息覆盖，且不区分阶段；
  `[Live]` 行要等 15 秒停顿阈值才出现

## Goals

1. 一次运行的每一步都有类型、时间戳和归属轮次，落在磁盘上可回放
2. 每种输出在屏幕上一眼可辨：前缀、字形、折叠状态各自不同
3. 任何时刻用户都能知道程序在做什么，不需要等 15 秒才看到线索
4. 输入历史可循环召回，跨重启保留
5. 全程不阻塞：用户随时可以移动光标、翻看任意位置

## Non-Goals

1. 不引入图形 widget，折叠与状态一律用 Emacs 原生手段
2. 不做跨会话的全局搜索界面
3. 不把推理内容当成最终答案的一部分送回模型
4. 不为了显示而在内存里保留整段历史的富文本副本

## Requirement 1: Run Record

### 1.1 会话元数据

会话必须携带并持久化以下字段，且前端可直接读取，不需要自己拼路径：

| 字段 | 含义 | 现状 |
|------|------|------|
| `id` | 会话唯一标识 | 已有 |
| `name` | 人类可读名称 | 已有 |
| `history-file` | 历史记录文件的绝对路径 | **要补** |
| `created-at` / `updated-at` | 创建与最后更新时间 | 已有 |
| `model-id` | 使用的模型 | 已有 |
| `metadata` | 其余元数据 alist | 已有 |

`history-file` 必须是取值函数而不是冗余存储的字符串，避免会话目录改名后
磁盘上留下失效路径。

### 1.2 步骤记录

一次运行由若干轮组成，一轮由若干步组成。每一步落成一条消息，必须带：

- `:turn` 轮次序号，从 1 起
- `:step` 该轮内的步序号，从 1 起
- `:category` 取值 `user` `ai-progress` `ai-final` `command-reply`
  `shell-output` `system-detail` 之一
- `:work` 当 `category` 为 `ai-progress` 时必填，取值 `thinking`
  `tool-call` `tool-result` `message` 之一
- `timestamp` 该步产生的时间

用户输入同样带 `:turn` 和时间戳，且与该轮的一到多条 AI 输出通过 `:turn`
关联。前端据此把一次提问和它引发的全部过程聚成一组展示。

### 1.3 事件契约

**UI 的事件处理器必须穷尽 agent 发出的事件类型，并且必须有兜底分支。**
未知事件不得被静默丢弃：至少记入日志，或作为 `system-detail` 落到记录里。

这条是硬约束，因为事件黑洞是本 spec 修的主要缺陷：`stream-reasoning`
在被发出后无人接收，症状是整段思考期界面不动，而没有任何一条错误信息。

新增事件类型时，必须同时在处理器中给出分支或明确纳入兜底，并补一条断言
"每个 agent 发出的事件类型都被处理"的测试。

## Requirement 2: Display Rules

### 2.1 前缀

每一步带一个本地化前缀，走 `(chat-i18n KEY DEFAULT)`：

| 内容 | 英文 | 中文 |
|------|------|------|
| 推理 | Thinking | 推理 |
| 工具调用 | Tool call | 调用工具 |
| 工具结果 | Tool result | 工具结果 |
| 中间说明 | Progress | 过程 |

### 2.2 字形

| 内容 | 字形 |
|------|------|
| 推理 | 暗色（继承 `shadow`） |
| 工具调用与结果 | 暗色 |
| 中间非推理非工具的文本 | **斜体**，正常亮度 |
| 最终答案 | 正常字体，正常亮度 |

### 2.3 折叠

四条规则，逐条对应验收项：

1. **工具调用默认折叠。** 折叠后显示一行摘要，含调用数量。
2. **推理只显示最新的一段。** 一旦其后有任何新内容开始产生（新的推理段、
   工具调用、中间文本或最终答案），前一段推理立即折叠。也就是说同一时刻
   最多一段推理是展开的，且它是最新的那段。
3. **中间的临时文本默认展开**，不折叠，用斜体区分于最终答案。
4. **最终答案默认展开**，正常字体，任何情况下不自动折叠。

用户手动展开或折叠的选择，在本次会话的后续重绘中必须保持，不被自动规则
覆盖。

## Requirement 3: Run Feedback

### 3.1 状态必须区分阶段

用户要能看出程序此刻在做什么，而不是只有一个"正在获取"。至少区分：

| 状态 | 含义 |
|------|------|
| 准备请求 | 组装上下文、裁剪预算 |
| 等待首字 | 请求已发出，还没有任何响应字节 |
| 推理中 | 正在接收推理内容 |
| 输出中 | 正在接收正文 |
| 调用工具 | 工具执行中，带工具名 |
| 等待审批 | 阻塞在用户审批 |
| 第 N 轮 | 多轮时的当前轮次 |
| 完成 / 取消 / 失败 | 终态 |

"等待首字"必须是独立状态且**立即**可见。实测一次 308KB 请求体的首字延迟
为 20 秒（`~/.chat/chat.log`，18:30:44 起进程，18:31:04 收到第一个字节），
这段时间内当前实现只有一行会被覆盖的回显消息，用户无法区分"在等"和"卡死"。

### 3.2 反馈不能依赖回显区

回显区会被任何 `(message ...)` 覆盖，不能作为持续状态的唯一载体。状态必须
有一个不会被覆盖的常驻位置，并在运行期间随阶段变化更新。

### 3.3 状态由事件派生

状态不得由调用点手工设置。它必须是事件流的函数：同一个事件流回放两次，
得到同一串状态。这样新增阶段只需新增事件，不需要在散落的调用点补
`message`。

## Requirement 4: Input History

- `M-p` 召回上一条输入，`M-n` 召回下一条，可来回循环
- 召回的内容放进输入区，可直接编辑后发送
- 召回不破坏用户已经键入但未发送的内容：首次 `M-p` 前先把当前输入存起来，
  `M-n` 走到底时还原
- 发送后该条进入历史；连续重复的相同输入只保留一条
- 历史跨 Emacs 重启保留，容量有上限
- 历史只记用户输入的原文，不记 AI 输出

## Requirement 5: Responsiveness

- 请求期间用户可以自由移动光标、切窗口、翻看缓冲区任意位置
- 渲染只重画变化的区域，不整段重排整个缓冲区
- 自动跟随输出只在光标本来就在尾部时生效；用户往上翻看后不得被拽回底部
- 请求路径上不得出现 `url-retrieve-synchronously` `accept-process-output`
  `sleep-for` `sit-for` 或等待进程的 `while` 循环
- 工具并发执行不得让前端失去响应

## Acceptance

### 记录

1. 一次含推理和工具调用的多轮运行结束后，磁盘记录里每条消息都有
   `:turn` `:step` `:category` 和时间戳，`ai-progress` 的还有 `:work`
2. 用户输入与它引发的全部 AI 步骤共享同一个 `:turn`
3. 会话能报出自己历史文件的绝对路径，且该路径确实存在
4. 存在一条测试：断言 agent 发出的每一个事件类型都被 UI 处理器覆盖，
   新增未处理的事件类型会让这条测试失败

### 展示

5. 工具调用初次出现即为折叠状态，显示带数量的摘要行
6. 产生第二段推理后，第一段自动折叠，第二段展开
7. 推理之后出现工具调用或最终答案时，最后一段推理也折叠
8. 中间临时文本以斜体展开显示，最终答案以正常字体展开显示
9. 用户手动展开一个折叠段后，后续重绘仍保持展开
10. 中英文环境下前缀分别显示为 `Thinking` / `推理` 等对应文案

### 反馈

11. 请求发出后到收到首字节之间，状态显示为"等待首字"且立即可见，
    不需要等待任何阈值
12. 接收推理内容期间状态显示"推理中"，接收正文期间显示"输出中"
13. 工具执行期间状态含工具名
14. 多轮时状态含当前轮次
15. 同一串事件回放两次得到同一串状态

### 输入

16. `M-p` 依次召回更早的输入，`M-n` 依次返回，可循环
17. 未发送的草稿在首次 `M-p` 前被保留，`M-n` 走到底时还原
18. 重启 Emacs 后历史仍在
19. 连续两次相同输入在历史里只占一条

### 响应

20. 流式接收期间，光标可移动、可翻页，缓冲区不被强制拉回底部
21. 请求路径上没有阻塞调用（以静态检查断言）

## Behavior Boundaries

推理内容只用于展示和记录，不回灌给模型作为后续轮次的输入。

未知事件走兜底分支落为 `system-detail`，默认折叠，不打断正文展示。

历史文件路径是取值函数，会话目录变更后取值随之变化，不会指向失效位置。
