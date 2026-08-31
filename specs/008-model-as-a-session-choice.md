# 008: The Model As A Session Choice Spec

## Overview

**一条 provider 注册只带一个模型名，而且是注册那一刻的快照。** 这一句是这份 spec
存在的全部理由。

后果有证据。真实配置里为了把 Kimi 的模型从默认值换成 `k3`，必须伸手进 registry：

```elisp
(setq chat-llm-kimi-code-default-model "k3")
(dolist (p '(kimi-code kimi-code-anthropic))
  (when-let ((cfg (chat-llm-get-provider-config p)))
    (plist-put cfg :model chat-llm-kimi-code-default-model)))
```

配置里自己的注释解释了为什么要这一段："两个 provider 在注册时就把模型名快照进了
registry，晚于 require 的 setq 只影响 OpenAI 那条（它每次请求都重读变量），
Anthropic 那条会一直用旧值。"

用户不得不写这段代码，等于说产品没有"选模型"这件事。而实际上两家厂商各有多个
模型，实测 `GET /models` 的返回：

- Kimi Code（`api.kimi.com/coding/v1`）：`k3`、`k3-256k`、`kimi-for-coding`、
  `kimi-for-coding-highspeed`
- DeepSeek（`api.deepseek.com`）：`deepseek-v4-flash`、`deepseek-v4-pro`、
  `deepseek-v4-flash-vision-exp`

**厂商和模型是两个维度，今天只有一个。** provider 符号既表示"哪家"，又表示
"哪个模型"，还表示"走哪套协议"——三件事挤在一个符号里，所以 `kimi-code` 和
`kimi-code-anthropic` 在菜单里看着像两家厂商，而四个模型一个都看不见。

## Non-Goals

- 不做模型能力矩阵、价格、上下文长度的展示界面。
- 不改 provider 注册的调用方式。新增字段都有默认值，现有注册不动也能工作。
- 不在这一版做 `GET /models` 的自动发现（见 Requirement 5，它是下一层）。

## Requirement 1: 三个维度分开

### 1.1 provider 符号继续表示"怎么到达"

一条注册 = 一个 base URL + 一套协议 + 一套请求构造。这个含义不变，`chat-session`
的 `model-id` 继续存它。这个名字已经不准了，但改名要动持久化和一大片调用点，
收益只是名字更好——不做。

### 1.2 新增 `:vendor`：哪一家

同一家厂商的多条协议通道共享一个 vendor 符号。缺省是 provider 符号本身，所以
只有确实有变体的注册需要写这个字段。

vendor 是**分组依据**，不是新的选择维度：用户选的是"哪家的哪个模型"。

### 1.3 新增 `:protocol`：走哪套协议

`openai` 或 `anthropic`。两个兼容工厂自己知道答案，由工厂注入，直接注册的
provider 缺省 `openai`。

协议不进选择菜单。理由：它不在用户的心智模型里——"我要用 k3"是需求，"走 OpenAI
兼容还是 Anthropic 兼容"是实现细节。同一 vendor 的 Anthropic 变体仍然能用
`/model` 按名字切到，因为它确实是一条不同的代码路径，需要能单独测。

### 1.4 新增 `:models`：这家有哪些模型

模型 ID 列表。缺省是 `(list (plist-get config :model))`，即"只有默认那一个"，
这样没写这个字段的注册行为不变。

## Requirement 2: 模型名归会话

### 2.1 会话记住自己的模型名

`chat-session` 新增 `model-name`：字符串，或 nil 表示"用 provider 的默认"。

nil 必须是合法值而不是"未初始化"：绝大多数会话不需要指定模型，它们要的是"这家的
默认那个"，而默认值可能在配置里变。把 nil 写成具体值等于把一次快照钉死在会话
里——正是今天 registry 快照那个毛病，只是搬到了会话上。

### 2.2 Agent Run 冻结具体模型名

四条 payload 构造路径已经都认 `options` 里的 `:model`（`chat-llm.el:324`、
`chat-llm.el:899`、`chat-llm-kimi-code.el:61`、`chat-llm-claude.el:97`），
`:request-options` 也已经从 agent 配置贯通到 transport。Agent 启动时必须把 provider
与具体模型解析成两个独立字段：会话钉住模型时使用会话值，否则读取该 provider
当时的默认值。解析结果写入 Run，并由 Run 强制写入每一轮、重试和 follow-up 请求。

`model-name=nil` 仍表示“下一次 Run 使用 provider 当时的默认值”，不表示正在执行的
Run 可以随配置变化漂移。Run 启动后，Profile、后续请求选项、配置重载和 provider
默认值变化都不得改变它的具体模型。缺少非空具体模型时必须在 transport 前失败。

### 2.3 切换必须一次说清两件事

`chat-set-model` 接受可选的模型名。provider 和模型名必须一起换：先换 provider
再换模型名，中间那一刻会话指向的是"新厂商 + 旧模型名"，而那个组合可能不存在。

### 2.4 换 provider 时清掉不属于它的模型名

切到另一家时，如果没有指定新模型名，会话的模型名必须清空而不是留着。留着就是让
DeepSeek 收到 `k3`。

### 2.5 供应商身份与模型身份不可复用同一字段

provider 符号只选择 adapter、协议与端点；具体模型必须是单独的非空字符串。父 Agent、
子 Agent、Profile、后台任务和 Eval 都使用这一合同。任何把 provider 符号写进具体模型
字段，或只保存 provider 而在每轮重新猜模型的入口，均为合同错误。

## Requirement 3: 菜单是"厂商 → 模型"

### 3.1 一家一组，组里是它的模型

只列 vendor 的主协议 provider 的模型（`:protocol` 为 `openai` 的那条，或者唯一
的那条）。Anthropic 变体不进菜单——见 1.3。

### 3.2 只列配置过的厂商

沿用 spec 007 Requirement 4.0：取不到 key 就不出现，每次显示时现算。

### 3.3 当前项要能看出来

菜单里当前会话所用的那一项要有标记。用户点开菜单的第一个问题是"我现在在哪"。

## Requirement 4: 提示符显示会话真正会用的模型

沿用 spec 007 Requirement 3.1，但事实来源变了：先看会话的模型名，没有再退回
provider 的默认。提示符只要显示一个不等于真相的名字，它就从防误发变成造误发。

## Requirement 5: 自动发现（下一层，本版不实现）

两家厂商都答 `GET /models`，且返回的就是 `:models` 里写的那些——实测确认。所以
自动发现是可行的，但它不能同步做：菜单打开时发一个网络请求会阻塞界面，违反
non-blocking 约束。

正确形状：异步刷新 + 缓存 + 失败退回注册时的清单。`:models` 因此不是"权威清单"，
而是**发现结果不可用时的退路**，这也是为什么本版先落它。

本版必须保证的是：菜单的数据来源是一个函数（"这个 provider 有哪些模型"），
而不是散落在菜单构造里的 `plist-get`，否则下一层要改的地方不止一处。

## Acceptance

### 注册字段

1. 未写 `:vendor` 的 provider，其 vendor 是自己
2. 未写 `:models` 的 provider，其模型列表是它的默认模型一个
3. OpenAI 兼容工厂注册出的 provider，`:protocol` 是 `openai`
4. Anthropic 兼容工厂注册出的 provider，`:protocol` 是 `anthropic`
5. 同一 vendor 的两条协议通道，vendor 相同、protocol 不同

### 会话

6. 新会话的 `model-name` 是 nil
7. `model-name` 存盘后读回仍是同一个值，nil 也读回 nil
8. 会话有 `model-name` 时，Agent Run 冻结该具体模型，且每一轮请求都带上它
9. 会话没有 `model-name` 时，Agent Run 启动时冻结 provider 当时的默认模型；配置在
   Run 中途变化不影响后续轮次
10. `chat-set-model` 带模型名时，两者一起生效
11. `chat-set-model` 不带模型名切到另一家时，旧模型名被清掉
12. 切到 provider 不认识的模型名要报错，且会话不变

### 菜单与提示符

13. 菜单按 vendor 分组，每组列该 vendor 主协议 provider 的模型
14. Anthropic 变体不出现在菜单里，但 `/model` 仍可按名字切到
15. 菜单标出当前项
16. 未配置 key 的厂商不出现
17. 提示符显示会话的模型名；没有则显示 provider 默认
18. 选中某个模型后，提示符显示的是它

### 真实配置

19. Kimi Code 的四个模型 ID 与 DeepSeek 的三个都能被选中并发出请求
20. `deepseek` 注册项的默认模型是一个真实模型 ID，不是别名
21. Profile、follow-up options 和子 Agent 均不能覆盖已启动 Run 的具体模型
22. 每个真实请求均记录实际 provider 与具体模型，缺失或漂移使 live Eval 无效

## Notes

`deepseek-chat` 是别名。实测打 `api.deepseek.com/v1/chat/completions` 传
`deepseek-chat`，响应的 `model` 字段回的是 `deepseek-v4-flash`。所以旧注册不算
坏，但它让"这次用的是哪个模型"这个问题答不出来——注册项应当写真实 ID。

DeepSeek 的 Anthropic 兼容端点是 `api.deepseek.com/anthropic`，实测
`/anthropic/v1/messages` 可用，与 Kimi Code 的 `api.kimi.com/coding` 同形，所以
按同一个工厂注册。
