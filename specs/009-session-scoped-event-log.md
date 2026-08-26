# 009: Session-Scoped Event Log Spec

## Overview

一个 119MB 的全局文本文件,其中 106.6MB —— 90% —— 是同一段对话的 77 份副本,每份
1.4MB。这不是日志写多了,是日志没有形状:所有会话往同一个文件追加自由文本,没有
轮转,没有分片,没有 schema,诊断信息和对话内容混在一起,写完就再也查不回来。

但要先把话说准:**chat.el 并不是没有 per-session 存储。**
`~/.chat/sessions/<id>.jsonl` 早就是分会话的、带类型的 JSONL。真正缺的是另一半 ——
一份**按会话记录的事件流**。`~/.chat/chat.log` 一直在试图充当那一半,而它是用
`chat-log` 这个自由格式的字符串接口写的,所以它注定只能被人眼读一次,不能被程序查。

这份 spec 要做的事,不是发明一套记录格式,而是**把已经存在的事件流落到盘上**。
`chat-agent--emit` 已经是所有事件的唯一出口,十五种事件类型全从那里过。它现在只喂
给 UI 一个回调,UI 认识八种,剩下七种落进一个 `cond` 的兜底分支——而那个兜底分支就是
上面那 106.6MB 的来源,因为每个事件都挂着 `:run`,`:run` 里是整个会话。

## Division Of Responsibility

三种东西必须分成三个流。它们的读者不同、生命周期不同、容量纪律不同,混在一起就是
现在这个局面。

- **context —— 模型续跑用的上下文。** 已存在,`~/.chat/sessions/<id>.jsonl`。
  只装会进下一次请求的东西:角色、最终内容、工具调用与结果、压缩检查点。它的读者
  是请求构造器。判断标准:**如果它不会被送回模型,它就不属于这里。**
- **wire —— UI 与回放用的事件流。** 本 spec 新增,按会话落盘。装会话真实发生过的
  过程:每一步的开始与结束、思考、流式片段的边界、工具调用的每个阶段、steering
  注入、压缩、取消、错误、每段耗时与 token 用量。它的读者是"这次到底发生了什么"
  这个问题——事后重放、事后归因。判断标准:**如果重放这次会话需要它,它属于这里。**
- **diagnostics —— 程序自身的诊断。** 已存在,`~/.chat/chat.log`,但要收窄。装程序
  自己的健康状况:加载、配置解析、外部命令、异常栈。它的读者是修 bug 的人。判断
  标准:**如果它讲的是程序而不是对话,它属于这里。**

由此得到一条贯穿全文的硬约束:**wire 里不许出现无界载荷。** 上面那 1.4MB 的教训是
结构性的,不是手误——`%S` 打一个挂着 `:run` 的事件,打出来的是整个会话。wire 记录
只写标量、标识符和有界摘要;真正的内容已经在 context 里了,wire 引用它,不复制它。

## Current Status

已经存在,并且是对的:

- **分会话的 context 存储。** `~/.chat/sessions/<id>.jsonl`,记录分
  `header` / `state` / `message` 三种,`message` 上带 `metadata`,里面已经有
  `:turn` / `:step` / `:category` / `:reasoning`。今晚写入的时间戳是正确的
  (`2026-08-27T01:58:25`);更早的文件里有 1970 的,是旧版本留下的历史数据
- **对 transcript 的查询层。** `lisp/core/chat-session-log.el` 已经能按 turn、
  category、work、时间把一个 run 自己的 transcript 过滤回来
- **单一的事件出口。** `chat-agent--emit`(`lisp/agent/chat-agent-loop.el:35`)
  给每个事件挂上 `:type` / `:step` / `:run`,十五种类型全从这里过:
  `agent-start` `context-transformed` `turn-start` `stream-chunk`
  `stream-reasoning` `stream-result` `tool-batch-start` `tool-event`
  `tool-batch-end` `message-appended` `truncated` `response` `followup`
  `steering` `agent-end`
- **分段计时。** `chat-log-timing-*`(`lisp/core/chat-log.el`)已经能按阶段打点
  并归因 GC,产出的 `[TIMING]` 行是这套东西里信息密度最高的一行

确认的缺口:

- **事件流不落盘。** 唯一的消费者是 UI 的那个回调。UI 没认的七种类型
  (`agent-start` `context-transformed` `turn-start` `stream-result`
  `tool-batch-start` `tool-batch-end` `steering`)既不显示也不记录,只在兜底分支
  里被打印一次就消失。会话结束后,"第 2 轮是被 steering 触发的""厂商首字节等了
  38 秒"这类事实无法复原
- **诊断日志没有容量纪律。** `chat-log.el` 里没有任何 rotate / max-size /
  truncate。119MB 是攒了几个月的结果,不是峰值
- **诊断日志不分会话。** 所有会话写同一个文件,没有 session_id 字段,所以无法回答
  "这个会话发生过什么"——只能按时间戳靠人眼在几十万行里对齐
- **token 用量没有落点。** 现在只有 `chat-context-budget` 的内部估算,请求真实
  消耗多少、缓存命中多少,没有任何地方记录
- **`[TIMING]` 与它描述的会话没有关联。** 那一行不带 session_id 也不带 turn,
  所以它只能被当场读,不能被聚合

## 参考实现

四个工具的做法(实测于本机),取其共识而非其细节。

| | 分会话键 | 事件流 | 上下文流 | 诊断 | 容量纪律 |
| --- | --- | --- | --- | --- | --- |
| Cursor | 路径 slug + uuid | JSONL,`role`/`message` + `turn_ended` | 另有 SQLite blob | 独立 `.log` / DB | 只有清理标记 |
| Codex | 日期树 + uuid | JSONL rollout,统一信封 `{timestamp, ordinal, type, payload}` | 同一份 rollout + SQLite 投影 | 独立 SQLite | **无上限,实测 2.7GB** |
| Kimi | md5(工作目录) + uuid | `wire.jsonl` | `context.jsonl`,压缩后归档为 `context_N.jsonl` | 独立按日轮转 `.log` | wire 无上限,context 压缩 |
| Termini | RuntimeSession id | notebook `entries.jsonl` | 会话控制面 `session.json` | 独立 `logs/` 与 audit | **显式上限**:保留 8 次调用 / 64MiB |

四家的共识,也是本 spec 直接采纳的部分:

1. **append-only JSONL** 作为持久事件流。不用 SQLite:Emacs 里没有随手可用的
   sqlite 依赖,而追加一行 JSON 是 `write-region` 一次调用
2. **统一信封 + 类型化载荷。** Codex 的
   `{timestamp, ordinal, type, payload}` 是最干净的形状,它让"加一种事件"不需要改
   读取方
3. **两级键:工作区身份 × 会话身份。** chat.el 已有会话 id,沿用
4. **软索引另存。** 列会话不该靠遍历大文件
5. **诊断与 transcript 分开**,四家都这么做
6. **压缩是一条被记录的事件,不是对文件的静默改写。** Codex 的 `compacted`、
   Kimi 的 `Compaction*` 都是这么做的。chat.el 现在的压缩会重写整个会话文件,
   这一点要改

两个明确不采纳的:

- **Codex 的无上限。** 2.7GB 的 rollout 证明"文件不会自己变小"。容量纪律必须在
  设计里,不能靠期望
- **Cursor 把工具结果从 transcript 里省掉。** 我们的 context 需要它——它就是要送回
  模型的东西

一个必须对齐的:chat.el 活在 Termini 的仓库里,所以字段名跟 Termini 的 notebook
对齐(`kind` / `turn_id` / `timestamp_ms` / `seq`),而不是再造第三套账本。

## Requirements

### 1. wire 流

**1.1** 每个会话有且仅有一份 wire 文件,与 context 文件同目录、同 id、不同后缀:
`~/.chat/sessions/<id>.wire.jsonl`。会话打开时以追加方式打开,关闭时落盘。

**1.2** 每条记录是一行 JSON,信封固定为
`{"schema_version":1,"seq":N,"timestamp_ms":T,"session_id":S,"kind":K,"payload":{…}}`。
`seq` 在会话内单调递增,`kind` 是事件类型的名字。读取方遇到不认识的 `kind` 必须
跳过而不是报错——这是"加一种事件不改读取方"的前提。

**1.3** wire 由 `chat-agent--emit` 的一个订阅者写入,不是由 UI 写入。理由:UI 只认
八种类型,而缺的正是它不认的那七种;把落盘挂在 UI 上,等于把记录能力绑在显示能力上。

**1.4** 十五种事件类型全部落盘,一种不漏。新增事件类型时必须同时给出它的 payload
形状,由测试断言覆盖率——**没有兜底分支**,因为兜底分支就是这次事故的成因。

**1.5** payload 只许出现标量、标识符和有界摘要。`:run`、buffer、process、
session 结构体一律不得序列化。大内容(消息正文、工具结果)以 context 里的
`message_id` / `tool_call_id` 引用,不复制。这条要由测试直接断言,而不是靠 review。

**1.6** 每条 `turn-start` 与其后的事件共享 `turn_id`,使一次提问和它引发的所有轮次
可以被聚合。steering 注入的消息必须带上它注入进的那个 `turn_id` 与 `step`。

### 2. 过程事实

**2.1** `steering` 事件的 payload 记录:注入了几条、每条的 `message_id`、注入进
第几个 step。这是"为什么这个 run 多跑了两轮"唯一的可回溯依据。

**2.2** 请求的时间事实落到 wire:发出时刻、首字节时刻、结束时刻。首字节延迟是
厂商侧成本,和本地耗时必须能分开看——实测有 38–53 秒的首字节,而这在现在的日志里
只能靠两行的时间戳相减手算。

**2.3** `chat-log-timing-*` 产出的分段计时以一条 wire 记录落盘,带
`session_id` 与 `turn_id`,而不只是打一行文本。GC 归因一并保留。

**2.4** token 用量落盘:每次请求的输入、输出、缓存命中(厂商返回什么就记什么),
以及本地预算估算值。两者并存是有意的——它们不一致的时候,那本身就是要查的 bug。

**2.5** 压缩记录为事件,payload 记录压缩前后的消息数与估算 token 数。context 文件
的重写必须可以从 wire 复原出"何时压缩、压掉了什么"。

### 3. 容量纪律

**3.1** wire 文件有字节上限(默认 32MiB,可配置)。超限时归档为
`<id>.wire.<n>.jsonl` 并新开一份,不截断、不静默丢弃。归档动作本身记一条事件。

**3.2** 诊断日志按日轮转,并有总量上限;超限时删最旧的。默认值要能在长期使用下
把总量压在百 MB 量级以内——现在是 119MB 且只会涨。

**3.3** 单条 wire 记录有字节上限(默认 64KiB)。超限的 payload 截断并标记
`"truncated":true`。这是 1.5 的兜底:即使有人往 payload 里塞了不该塞的东西,
也不会再出现 1.4MB 一条。

### 4. 诊断日志收窄

**4.1** `chat-log` 的调用点分流:讲对话过程的改走 wire,讲程序健康的留在诊断。

**4.2** 诊断日志里的量必须是上线的量。`[BUILD-REQUEST]` 现在报"51k chars",那是
**只统计了消息正文**;同一次请求实际上线 325KB,差六倍。差额是工具结果和工具
schema,而它们恰恰是首字节延迟的主要来源,所以这个口径必须改成上线字节数,并把
差额的构成分开报。

**4.3** 日志参数的求值必须和日志开关一起被短路。`chat-log` 本身有
`chat-log-enabled` 前置判断,但**参数在进入它之前就已经求值完了**——
`chat-llm--message-shape` 要遍历全部消息,`chat-ui--event-payload-keys` 要走一遍
plist,关掉日志也照付。凡是参数本身有计算量的调用点,要么改成宏形式延迟求值,
要么把计算挪进被判断的一侧。

### 5. 索引

**5.1** 一份软索引记录每个会话的 id、标题、模型、创建与更新时刻、轮次数、wire 与
context 的字节数。列会话只读索引,不遍历会话文件。

**5.2** 索引可以从会话文件重建。索引丢失或损坏不构成数据丢失——它是投影,不是
事实来源。

## 非目标

- **不做 SQLite。** 追加一行 JSON 就够,引依赖不值得
- **不做跨会话的全局搜索。** 那是索引之上的一层,等真的需要再说
- **不把 wire 当成 context 的替代品。** 两者会有重叠字段,这是有意的:一个要能
  重放,一个要能续跑,压缩会让它们分叉,而分叉本身就是要记录的事实
- **不在这份 spec 里做 UI。** 那七种事件该怎么显示在状态栏,是 004 的范围;这里
  只保证它们被记下来

## 验收

- 一次带工具调用、带 steering、带压缩、带取消的会话跑完后,只读 wire 文件就能
  复原:提问几次、每次几轮、每轮为什么继续、工具跑了什么、首字节等了多久、
  压缩发生在哪里、token 花了多少
- 十五种事件类型每一种都有一条测试断言它落盘,且断言 payload 里没有 `:run`
- 一条 wire 记录的字节数上限被测试覆盖:构造一个超限 payload,断言它被截断并标记
- 关掉诊断日志后,发送路径上不产生任何日志相关的开销,包括参数求值(可由分配
  计数断言:同一次发送在开关两侧的分配差应当只剩写盘那部分)
- 索引删掉后能从会话文件重建,重建结果与删除前一致
- 诊断日志在一次典型会话后的增量,由测试给出一个具体的字节上界
