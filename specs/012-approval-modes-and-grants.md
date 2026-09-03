# 012: 审批模式与授权记录（Approval Modes and Grants）

## Owner

chat.el contributors

## 核心问题

"这次工具调用能不能跑"目前没有一个可以命名的答案。它由六个各自独立的开关拼出来，
其中三个的行为和它们的名字不一致，还有一个把用户配置和程序运行时写入混在同一个变量里。

### 现状：六个开关，没有一个叫"模式"

| 开关 | 位置 | 实际作用 |
|---|---|---|
| `chat-approval-enabled` | `chat-approval.el:25` | 为 nil 时跳过全部审批，但**不影响硬闸门** |
| `chat-approval-auto-approve-global` | `:68` | 与 `auto-approve-tools` 联合生效 |
| `chat-approval-auto-approve-tools` | `:75` | 全局开关为真时可自动通过的工具 |
| `chat-approval-always-approve-tools` | `:82` | 永远自动通过，且**被运行时写入** |
| session 的 `auto-approve` | `chat-session.el:61` | 为真时短路上面全部 |
| `chat-approval-noninteractive-policy` | `:57` | 批处理下 approve / deny / ask |

要回答"现在是什么模式"，得同时读这六个值再在脑子里跑一遍 `chat-approval--auto-approve-p`。
用户想开"危险模式"时，最接近的做法是把 `chat-approval-enabled` 设为 nil——而这不管用，
因为硬闸门（spec 011）在审批之前、与审批无关，`git push` 照样被拒。**"允许一切命令执行"
现在无法表达。**

### 现状：三处坏掉的行为

**一、`allow-session` 的作用域是整个会话的全部工具，不是被批准的那一项。**

```elisp
;; chat-approval.el:401
('allow-session
 (when (and session (fboundp 'chat-session-set-auto-approve))
   (chat-session-set-auto-approve session t))
 t)
```

用户为一条 `shell_execute` 选了"本 session 允许"，得到的是这个 session 里**所有**需要
审批的工具从此都不再问——包括 `files_write`、`apply_patch` 和后台任务。选项名字说的是
"这一项"，做的是"全部"。

**二、session 级 auto-approve 短路了按工具的名单。**

```elisp
;; chat-approval.el:249
(and (or session-auto-approve
         always-auto-approve
         (and global-auto-approve in-auto-approve-list))
     t)
```

`chat-approval-auto-approve-tools` 只在"全局开关"这条分支里参与判断。session 级一为真，
名单完全不参与。所以 spec 001 §1.3 写下的"默认 shell_execute 不纳入自动同意范围"在
session 级开关打开后不成立。

实测：`~/.chat/sessions/` 下 `Code: intent-backend` 与子会话 `git-log-reader` 的 state 行
都是 `"autoApprove": true`，而 `chat-subagent--child-session`（`chat-subagent.el:88`）
并不设这个字段——也就是说它是在运行中被设上的，而运行中唯一会设它的路径就是上面那条
`allow-session`。**一次"本 session 允许"就足以让整个会话变成自动通过模式，用户不会知道。**

**三、运行时授权写进了用户的 `defcustom`，而且不持久化。**

```elisp
;; chat-approval.el:408 / :413
(push tool-id chat-approval-always-approve-tools)
(push directory chat-approval-always-approve-directories)
;; chat-tool-shell.el:302
(push pattern chat-tool-shell-whitelist)
```

三个都是 `defcustom`。后果有三条：`M-x customize` 里会出现用户没写过的条目；
`custom-file` 可能把它们存下来，等于用户的配置被程序悄悄改写；想清掉运行时授权就必须
连用户自己的配置一起清。而"以后都允许"其实一次重启就没了，因为没有任何持久化。

### 现状：白名单只服务 shell

`chat-tool-caller--shell-whitelist-approve-p`（`chat-tool-caller.el:760`）明确只处理
`shell_execute`。文件工具走另一套（`always-approve-directories`），别的工具没有任何
"这一条允许"的表达方式，只有"这个工具永远允许"。

## 方案

一个模式，三种取值；一份授权记录，三个来源；硬闸门的权威性由模式决定。

```
        ┌──────────────────────────────────────────────┐
        │  chat-approval-authorize (tool call session)  │  唯一入口
        └───────────────────┬──────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
   dangerous              auto               manual
   闸门跳过             闸门权威            闸门只是意见
   从不询问             从不询问            未授权则询问
                                            人的同意可越过闸门
```

## 范围与行为边界

本版覆盖：模式的定义与切换、授权记录的三个来源与持久化、模式与硬闸门的关系、
交互式审批的三种许可范围、以及这套机制在**所有**工具调用上生效（不只是 shell）。

不覆盖：审批 UI 从 minibuffer 换成别的形态；用户自定义规则的配置语言。后者留出接口
（规则是函数列表，用户规则前置）但本版不设计 DSL——先让内建规则跑起来，等真实需求
出现再定语言，否则设计出来的语言只服务于想象中的场景。

本版验证的判断：把六个开关收成一个可命名的模式之后，用户能一句话说清当前会话的
授权状态，并且"人已经看着命令点了同意"这件事不再被闸门作废。

## 全局规则

### 1. 三种模式

| 值 | 中文名 | 闸门 | 询问 | 适用 |
|---|---|---|---|---|
| `dangerous` | 自动通过模式 | 跳过 | 从不 | 隔离环境、一次性容器、明知风险的批量作业 |
| `auto` | 自动审批模式 | 权威 | 从不 | 日常无人值守：规则说行就行，说不行就拒，不打扰 |
| `manual` | 人工审批模式 | 仅作意见 | 未授权则询问 | 默认。规则之外的事交给人判断 |

- 默认值 `manual`。不是 `auto`，因为 `auto` 的拒绝是终局的——规则没覆盖到的合理命令
  会被直接拒掉而没有申诉途径，这在用户不知道自己处于什么模式时是最难排查的形态。
- `chat-approval-mode` 是全局默认，session 可覆盖（`chat-session-approval-mode`），
  session 值为 `inherit` 或 nil 时用全局值。
- 子会话（子代理）**继承父会话的模式**，不得自行提升。现状是子会话的
  `auto-approve` 在运行中被设成 t，等于静默提升为自动通过，这在新模型下必须不可能。
- `dangerous` 必须显式设置，不得由任何交互式选项间接达成。"本 session 允许"不再是
  它的入口——那正是现状最危险的地方。

### 2. `dangerous` 的含义是完整的

- 硬闸门跳过：`shell_execute` 与 `work_task_start` 都不再校验程序名、子命令、元字符。
- 审批跳过。
- 执行隔离同步解除：`shell_execute` 在 `dangerous` 下改用无限制的 `local` 后端执行
  （继承完整环境、真实 HOME、有网络、不生成 sandbox profile），见 spec 023 的修订。
  `manual` / `guarded` 保持 `inspect` 沙箱不变。一次性同意（人批准一次、guard 裁决
  一次）不解除隔离——只有模式本身才解除，否则"同意过一条命令"就会变成"整个会话
  都出了沙箱"。
- 不跳过的只有两件：文件工具的 `chat-files-allowed-directories`（那是路径边界，
  不是审批），以及 session 的工具启停（`chat-session-tool-enabled-p`，那是"这个会话
  有没有这个能力"）。理由是这两个不是"要不要问用户"的问题，用户开危险模式表达的是
  "别问我"，不是"忘掉我配的边界"。
- 非交互环境下的 pager / 凭据提示环境（spec 011 §5）照旧注入。那是防挂死，与权限无关。

### 3. `auto` 的规则集

规则是一个函数列表，按顺序求值，第一个给出明确意见的胜出：

```elisp
;; (tool call session) → 'allow | 'deny | nil
(defcustom chat-approval-rules
  '(chat-approval-rule-granted
    chat-approval-rule-command-gate
    chat-approval-rule-read-only
    chat-approval-rule-effects))
```

内建四条：

| 规则 | 意见 | 依据 |
|---|---|---|
| `rule-granted` | 命中授权记录 → `allow` | 三份白名单，见 §4 |
| `rule-command-gate` | 有 `command` 参数时问 spec 011 的闸门；通过 → `allow`，拒绝 → `deny` 并带上原因 | 闸门已经是一套成文规则，不该在这里重写一遍 |
| `rule-read-only` | 工具 effects 只有 `read` → `allow` | 只读不需要人同意 |
| `rule-effects` | effects 命中 `chat-approval-required-effects` → `deny` | 兜底：无人值守时不做写操作 |

用户规则前置到这个列表即可，无需新语法：一个函数拿到 tool、call、session，返回三态。
`nil` 表示不表态，交给后面的规则——这是让用户规则能只管自己关心的那一小块的原因。

`auto` 下的拒绝必须带原因，且原因就是 spec 011 那套（点名失败的 token 和可行形式）。
无人值守模式里的拒绝没有人能追问，所以它比交互模式更需要说清。

### 4. 授权记录：三个来源，三份存储

一条授权记录（grant）说明"什么可以不经询问"：

```elisp
(cl-defstruct chat-approval-grant
  tool      ; 工具 id，nil 表示任意工具
  scope     ; 'tool | 'command | 'directory
  pattern   ; command/directory 的匹配串，scope 为 tool 时为 nil
  source)   ; 'builtin | 'user | 'runtime | 'session
```

| 来源 | 存储 | 谁写 | 生命周期 |
|---|---|---|---|
| 内建 | `chat-approval-builtin-grants`（defconst） | 没人，代码里定死 | 永久 |
| 用户 | `chat-approval-user-grants`（defcustom） | 只有用户 | 永久 |
| 运行时 | `chat-approval--runtime-grants` + `~/.chat/approvals.eld` | 只有程序 | 永久，可整体清除 |
| 会话 | session 内，不落盘 | 程序 | 随会话结束消失 |

用户列了三份（内建、用户配置、运行时自动维护），这里多出的"会话"那一份是
"本 session 允许"的落点——它必须是一份独立的、不持久化的记录，否则就只能像现状那样
退化成整会话全开。

**匹配语义沿用现有的**，不发明新的：`command` 用 `chat-tool-shell` 的模式规则
（末尾空格表示前缀匹配，否则精确匹配），`directory` 用现有的规范化前缀比较。
理由是这两套语义已经有测试和用户配置，换一套等于让用户已有的白名单含义发生变化。

**兼容**：`chat-tool-shell-whitelist`、`chat-tool-shell-default-whitelist`、
`chat-approval-always-approve-tools`、`chat-approval-always-approve-directories`
继续被读取，分别映射为 user 与 builtin 来源的 grant。程序不再往它们里 `push`。

### 5. 交互式审批的许可范围

`manual` 下未命中授权时询问，选项与现状一致，语义修正：

| 选项 | 作用 | 落点 |
|---|---|---|
| allow once | 本次 | 不留记录 |
| allow for session | 本会话内这一项 | session grant，**不再是整会话全开** |
| always allow this tool | 这个工具 | runtime grant，scope `tool` |
| always allow this command | 这条命令 | runtime grant，scope `command` |
| always allow this directory | 这个目录 | runtime grant，scope `directory` |
| deny | 拒绝 | 不留记录 |

"本会话内这一项"的粒度与"以后都允许"相同，只是存储位置不同：同一条命令、同一个工具、
或同一个目录，取决于用户选的是哪一项。

### 6. 人的同意在 `manual` 下高于闸门

这是本 spec 要修掉的最后一处矛盾。当前顺序是审批在前、闸门在后
（`chat-tool-caller.el:991` 审批，`:994` 执行，闸门在工具函数内部），所以交互式会话里：

1. 模型调 `work_task_start`，参数 `make test`
2. 用户收到弹窗，看到这条命令
3. 用户点同意
4. 闸门拒绝：`the program make is not on the allowed list`

用户点了头，它还是不跑。这个仓库自己已经写下了正确的原则，在
`chat-tool-shell-execute-unrestricted` 的文档串里：*"It is meant for a command a person
typed, where the person already decided what to run."* 人已经决定了要跑什么的时候，
名单不增加任何安全性，只是让人的决定作废。

所以 `manual` 下：闸门的判断作为**询问时的附加信息**呈现（"这条命令在规则之外，
原因是……，仍然允许吗？"），用户同意即执行。`auto` 下闸门是终局的，因为那时没有人可以
承担这个判断。

实现上，工具函数内部的闸门保留，作为直接调用（不经 `chat-tool-caller`）的最后一道；
经过 `chat-approval-authorize` 并获得人工同意的调用，通过一个动态绑定告知工具"这次
已经有人看过了"。保留的理由是 `chat-tool-shell-execute` 确实有直接调用方
（`chat-ui--execute-shell-safe`），去掉工具内的闸门会给它们开一个洞。

### 7. 模式必须可见

- 提示符区域显示当前模式。`dangerous` 用警示色，不得与其他两种同色——一个用户忘记
  自己开了危险模式，就是这套机制最坏的失败方式。
- `/approve` 命令报告与切换模式（`/auto` 已被"默认命令"占用，不复用）。
- 切到 `dangerous` 需要二次确认，并在会话里留一条系统消息。
- 请求面板（`C-c C-p`）显示本次调用的判定路径：命中了哪一条规则或哪一份授权记录。

### 8. 授权记录可审计、可清除

- `M-x chat-approval-list-grants` 列出四个来源的全部记录，标明来源。
- `M-x chat-approval-revoke-grant` 删除一条运行时或会话记录；不能删内建与用户配置的
  （那两份不属于程序）。
- `M-x chat-approval-clear-runtime-grants` 清空运行时记录并落盘。
- 每条运行时记录带创建时间与产生它的 session id，否则"以后都允许"积累三个月之后
  没人知道哪条是为什么加的。

## 功能规格

### 模块：chat-approval.el（模式与判定）

| 接口 | 用途 |
|---|---|
| `chat-approval-mode` | 全局默认模式 |
| `chat-approval-effective-mode (&optional session)` | 会话覆盖后的实际模式 |
| `chat-approval-set-mode (mode &optional session)` | 切换，`dangerous` 需确认 |
| `chat-approval-mode-report (&optional session)` | 当前模式与它来自哪里 |
| `chat-approval-authorize (tool call session observer)` | 唯一入口 |
| `chat-approval-rules` | `auto` 下按序求值的规则函数表 |
| `chat-approval-command-consent-p ()` | 工具内闸门用：这次调用是否已有人看过 |

`chat-approval-authorize` 的返回值不是 t/nil，而是 nil 或 `dangerous` / `grant` /
`rule` / `human` 之一——即"这次是怎么被允许的"。工具内的闸门需要区分"人看过"和
"命中授权"，而一个布尔值区分不了；调用方把它绑到 `chat-approval-consent` 上，
工具据此判断。旧名 `chat-approval-request-tool-call` 保留为别名，只判真假的外部
调用方不受影响。

### 模块：chat-approval-grants.el（授权记录）

单独一个模块，因为这四份存储、持久化和匹配语义与"谁来判定"是两件事，而且
`chat-tool-shell` 需要用到匹配规则却不该因此依赖整个审批流程。

| 接口 | 用途 |
|---|---|
| `chat-approval-grants (&optional session)` | 四个来源合并，narrowest first |
| `chat-approval-grant-match (tool-id arguments &optional session)` | 命中的记录或 nil |
| `chat-approval-grant-pattern-match-p (value pattern)` | 沿用的白名单匹配语义 |
| `chat-approval-add-grant (grant &optional session)` | 写运行时或会话记录 |
| `chat-approval-revoke-grant (grant &optional session)` | 删记录，拒绝删内建与用户的 |
| `chat-approval-clear-runtime-grants ()` | 清空运行时记录并落盘 |
| `chat-approval-list-grants ()` | 列出全部记录及其来源 |

跨模块的两处依赖用函数变量交出去，而不是反向 require：
`chat-approval-grant-target-paths-function` 由 `chat-files` 设置（目录记录要知道这次
调用会碰哪些文件），`chat-approval-grant-command-tail-function` 由 `chat-tool-shell`
设置（`cd DIR && git log` 要能命中 `git log ` 的记录，而授权存储不该懂 shell 语法）。

### 模块：chat-session.el（扩展）

- 新增 `approval-mode` 槽，取值 `manual` / `auto` / `dangerous` / `inherit` / nil。
- 新增 `approval-grants` 槽，存会话级记录，**不进持久化**。
- `auto-approve` 槽保留并**只作为读取来源**：t 映射为 `auto`，nil 映射为 `inherit`。
  理由是已有会话文件里存着这个字段，直接丢弃会让老会话的授权状态在升级后变成默认值
  而没有任何提示。
- 关键在于"只作为读取来源"：这个 flag 不得在判定里再有自己的分支。第一版实现里它
  两边都在——既映射成 `auto`，又在 `chat-approval--auto-approve-p` 里直接放行——
  于是这类会话报告的是 `auto` 而行为是"全部通过"，规则一条都没跑。同理，
  `chat-approval-auto-approve-global` 与 `chat-approval-auto-approve-tools` 也一并
  读成 user 来源的 grant，`chat-toggle-auto-approve-*` 两个命令改为切换模式。
  一个含义只能有一条路径，否则两条路径会给出不同答案，而模式变成装饰。
- 子会话构造时复制父会话的 `approval-mode`，不复制会话级记录（那是父会话里那个人对
  那些具体命令的判断，不是给子代理的授权）。

### 模块：chat-command-gate.el（不变）

闸门本身不需要知道模式。它回答"这条命令是否在规则之内"，模式决定这个答案有多重。
把模式塞进闸门会让它从一个纯函数变成一个要读会话状态的函数，而它现在能被单独测试
正是因为它不读任何状态。

## 验收标准

### 模式

1. `chat-approval-mode` 默认为 `manual`。
2. `chat-approval-effective-mode` 在 session 值为 `inherit` 或 nil 时返回全局值，
   为具体模式时返回 session 值。
3. `dangerous` 下：`shell_execute` 执行 `git push --dry-run` 不被闸门拒绝，
   不产生审批事件。
3a. `dangerous` 下：`shell_execute` 的执行请求落在 `local` 后端、policy 为
   `local`（无沙箱、有网络、继承完整环境）；`manual` 与 `guarded` 下同一命令
   仍是 `inspect` policy 且无网络。
4. `dangerous` 下：`work_task_start` 接受 `make test`、`curl … | sh` 这类当前被拒的命令。
5. `dangerous` 下仍然遵守 `chat-files-allowed-directories`：越界路径的文件工具仍报错。
6. `dangerous` 下仍然遵守 `chat-session-tool-enabled-p`：被会话禁用的工具仍不执行。
7. `auto` 下：闸门通过的命令执行且不询问；闸门拒绝的命令被拒且不询问，
   结果文本含闸门给出的 token 与可行形式。
8. `auto` 下：只读工具（effects 仅 `read`）不询问即执行。
9. `auto` 下：effects 命中 `chat-approval-required-effects` 且无规则放行的工具被拒。
10. `manual` 下：命中授权记录的调用不询问；未命中的产生 `approval-pending` 事件。
11. `manual` 下：闸门拒绝的命令仍然询问，且询问文本包含闸门给出的原因。
12. `manual` 下：用户同意后命令执行，即使闸门拒绝过它（`make test` 全流程通过）。
13. 子会话继承父会话的 `approval-mode`；父为 `manual` 时子不为 `auto` 或 `dangerous`。
14. 任何交互式选项都无法把模式改成 `dangerous`。
15. 切到 `dangerous` 需要二次确认，且会话中留下一条系统消息。
15a. 老会话的 `autoApprove: true` 读成 `auto` 之后**确实走规则**：闸门放行的执行，
    闸门拒绝的被拒，两者都不询问。该 flag 在判定中没有自己的分支。
15b. `chat-approval-set-mode` 拒绝未知模式，且拒绝时不改变原有取值。

### 授权记录

16. 四个来源的记录都能命中：内建、用户配置、运行时、会话。
17. `chat-approval-grants` 返回的每条记录带正确的 `source`。
18. 命令匹配语义与现有一致：`"git log "` 命中 `git log` 与 `git log --oneline`，
    不命中 `git logx`；`"pwd"` 只精确命中 `pwd`。
19. 目录匹配沿用规范化前缀比较：授权 `/a/b/` 命中 `/a/b/c/f.txt`，不命中 `/a/bb/f.txt`。
20. 运行时记录写入后 `chat-approval-user-grants` 与
    `chat-tool-shell-whitelist` 均未被修改。
21. 运行时记录落盘到 `~/.chat/approvals.eld`，重启后仍然命中。
22. 会话记录不落盘：保存并重新载入会话后不再命中。
23. 每条运行时记录带创建时间与来源 session id。
24. `chat-approval-clear-runtime-grants` 清空运行时记录，且内建与用户记录仍在。
25. `chat-approval-revoke-grant` 拒绝删除内建与用户来源的记录。

### 交互式许可范围

26. `allow-session` 只授权被批准的那一项：为一条 `shell_execute` 选它之后，
    同会话的 `files_write` 仍然询问。
27. `allow-session` **不再**把 session 的 `auto-approve` 设为 t。
28. `allow-tool` 产生 scope 为 `tool` 的运行时记录；`allow-command` 产生 scope 为
    `command` 的；`allow-directory` 产生 scope 为 `directory` 的。
29. `allow-once` 不产生任何记录：同一条命令第二次仍然询问。
30. 每种许可都产生 `whitelist-update` 事件，带 scope 与 pattern。

### 覆盖面

31. 授权与模式对**所有**注册工具生效，不只 `shell_execute`：
    `work_task_start`、`files_write`、`apply_patch` 走同一个入口。
32. `chat-tool-caller` 的同步与异步两条执行路径都经过 `chat-approval-authorize`。
33. 直接调用 `chat-tool-shell-execute`（不经 tool-caller）时，工具内闸门仍然生效。
34. `chat-approval-mode` 为 `manual` 且经人工同意的调用，
    `chat-approval-command-consent-p` 为真，工具内闸门放行。

### 可见性

35. 提示符显示当前模式，`dangerous` 使用与其他模式不同的警示面。
36. `/approve` 无参数时报告当前模式与来源（全局还是会话覆盖）。
37. 请求面板显示本次调用命中的规则名或授权记录来源。

## 实现记录

一处在实现中发现、值得写下来的事：**测试必须能隔离运行时授权。** 第一版实现跑测试时，
`allow-command` 那条测试写下的运行时记录被后面几条测试命中，于是"应该弹窗"的测试
拿不到弹窗事件而失败。这不是测试写错，而是这份存储确实是全局可变状态；同一个问题在
真实使用里表现为"我不记得什么时候允许过这条命令"。所以 `test-helper` 把
`chat-approval-grants-file` 指向临时目录并默认关掉持久化，另提供
`chat-test-with-grants` 清空运行时记录——跑一次测试不该在开发者的 Emacs 里留下授权。

## 待确认问题

**升级路径。** 现有会话文件里 `autoApprove: true` 的会话（实测至少两个）在新模型下
会被读成 `auto` 模式。这比读成 `manual` 保守（会话原来是全部自动通过），但比原状态严
（`auto` 会拒绝规则外的写操作，原状态不会）。三个选项：读成 `auto`（推荐，最接近原意
且不静默放宽）、读成 `manual`（最安全，但会让原本无人值守的会话开始弹窗）、
读成 `dangerous`（保持原行为，但等于把危险模式静默塞给一批老会话，与 §1 冲突）。
本 spec 取第一个，已按此实现，需要确认。

**规则的配置语言。** 本版把 `chat-approval-rules` 定成函数列表，用户要自定义就写一个
函数。这满足"后期也可以支持用户自定义"，但不是声明式配置。要不要一套声明式规则
（类似 `((tool . shell_execute) (command-prefix . "git ") → allow)`）留到有真实需求
之后再定——现在设计的语言只会服务于想象中的场景。

**`chat-approval-enabled` 的去向。** 它现在的含义（跳过全部审批但不跳过闸门）在三模式
下没有对应物：最接近的是 `auto` 加上一条"全部 allow"的用户规则，或者直接是
`dangerous`。保留它会出现"模式说 manual 而它说别问"的矛盾。倾向是把它标记为废弃、
读到 nil 时映射为 `dangerous` 并给一次警告，但这会把一批人的配置静默升级成危险模式，
需要确认。
