# In-Process Streaming Transport and Link Resilience

Status: complete
Date: 2026-09-03
Roadmap: —
Decision: —

## Goal

流式传输不再依赖外部 curl 进程，改为 Emacs 进程内实现；断链与线路不稳
不再以 curl 退出码的形式裸奔到用户面前，而是被一层通用韧性逻辑吸收、
分类、翻译，并在失败积累时对出问题的端点做临时、动态、可恢复的针对性
调整。

明确不做的：**不按失败频率重排模型或线路的顺序**。顺序是用户表达出来的
偏好，稳定性调整只做"临时绕开一个正在出问题的端点"，不动摇偏好本身。

## Scope

- 替换的唯一路径：`chat-stream-request` 的 curl 子进程实现。所有流式请求
  （OpenAI 兼容、Anthropic 兼容、Kimi Code）都走这一条，替换后全部改走
  进程内传输。
- 不在本期范围：`chat-llm--post-async-curl` 承载的非流式异步路径
  （`:async-transport 'curl` 的 kimi-code 注册）保持原样；它是另一份合同，
  不是流式链路。

## Contracts

### 1. 进程内传输层

- 传输由 `open-network-stream`（TLS 经 GnuTLS）实现，协议为 HTTP/1.1：
  `Connection: close`，请求体一次性发送，响应按流读取。
- 支持 chunked transfer-encoding 的增量拆包；SSE 行解析复用既有的
  半行缓冲逻辑（`chat-stream--handle-output`）。
- 密钥不再落临时配置文件：请求头直接写入进程输入。
- 传输的终止状态是结构化的：进程属性 `chat-stream-terminal` 携带
  `(:status ok|:error :message ...)`。运行时包装（chat-model-runtime）
  读取该属性，不再解析进程事件字符串。
- 连接建立非阻塞（`:nowait`），任何时候都不得卡住 Emacs 主循环。

### 2. 错误分类（自有分类法，替代 curl 退出码）

传输层把失败归为数个类别，消息面向用户、可翻译、带下一步建议：

| 类别 | 判定 | 用户可读含义 |
|---|---|---|
| `dns` | 名称解析失败 | 域名解析不了：网络未连接或 DNS 问题 |
| `connect` | 连接被拒/建连超时 | 连不上端点：线路不可达 |
| `tls` | TLS 握手失败 | 加密协商失败 |
| `http` | 状态码非 2xx | 服务端明确拒绝（沿用错误体里的 message） |
| `mid-stream-close` | 收到过数据但未收到 `[DONE]` 连接就断了 | 传输中途被对端掐断：中转/上游线路不稳 |

### 3. 通用韧性（对所有 provider、所有网络位置一视同仁）

- 慢速提示（只提示、绝不取消）：只要网络连接还活着，请求就一直等。
  首个 token 慢（大上下文预填）或流中途慢都是常见且合法的；超过
  `chat-stream-slow-notice-seconds`（默认 120 秒）没有新数据时，写入一条
  "超出预期、仍在等待"的诊断提示并随实时状态展示，仅此而已。取消只有
  一个入口：用户手动 C-g / C-c C-c。
- 无字节重试（既有合同不变）：一个 payload 都没收到的瞬态失败，按
  `chat-agent-model-transport-retry-delays` 退避自动重发。瞬态判定扩展为
  新的错误分类文本（见 §4），不再匹配 curl 退出码。
- 半截续传：已经流出部分内容后连接被对端断开（`mid-stream-close`）
  切断的模型回合，自动整体重发该回合，上限
  `chat-agent-model-stream-resume-retries`（默认 2）次。重发不携带半截
  内容、不写入会话记录——模型重新生成，用户看到回答重新开始并收到一条
  断流重试提示。工具调用不会在半截回合里发生（工具只在回合完成后执行），
  因此重发没有副作用风险；代价是重复的 token 消耗，这是用户选择保护的
  代价，以次数上限封顶。

### 4. 失败探测与端点临时动态调整

- 每个端点（base URL 的 host+path）有一张内存健康记录：最近的传输类失败
  （`dns`/`connect`/`tls`/`mid-stream-close`/HTTP 5xx）计数与
  冷却截止时间。HTTP 4xx 不计入——那不是端点不稳。
- 同一端点连续传输类失败达到 `chat-stream-endpoint-failure-threshold`
  （默认 3）次，进入冷却：选择端点时跳过它，冷却期
  `chat-stream-endpoint-cooldown-seconds`（默认 60 秒）随连续失败翻倍、
  上限 30 分钟。
- provider 可注册 `:base-urls`（有序列表）。请求按序选第一个未冷却的
  端点；全部在冷却时取冷却最早结束的一个放行（半开试探）：成功则清除
  该端点记录，失败则重新冷却并翻倍。
- 成功完成（2xx 且收到 `[DONE]`）即清除端点记录。
- 记录只在内存，不持久化；重启即重置。
- 这套调整是临时的、针对单个端点的、可自愈的；它永不修改注册信息、
  永不改变用户可见的模型顺序。

### 5. 用户可见错误

错误消息由分类生成，包含：发生了什么、大概率原因、下一步怎么做
（重试按键或换线建议）。运行时固定提示语（"Next: ..."）保持不变。

## Acceptance

1. 流式请求全程无外部进程：密钥不出现在临时文件，Emacs 主循环不阻塞。
2. 正常 SSE 流完整解析：文本、reasoning、tool_calls、usage 与 curl 时代
   一致。
3. 对端在 `[DONE]` 前断开：分类为 `mid-stream-close`，消息可读；无 payload
   时按退避重试；有 payload 时按上限续传重发。
4. 连接存活但长时间无数据：只记提示，不终止；connect/dns/tls 各自分类正确。
5. HTTP 非 2xx 沿用错误体 message，不计入端点健康记录（5xx 计入）。
6. 端点连续失败达阈值后被跳过；注册 `:base-urls` 的 provider 自动落到
   下一条线路；冷却结束后半开试探，成功即恢复。
7. 全部测试通过；新传输层有针对 chunked 拆包、半截断流、停滞、错误体的
   单元测试（用 Emacs 进程内 TCP server 起本地 HTTP 服务，不依赖外网）。
