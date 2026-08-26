# 011: 命令闸门（Command Gate）

## Owner

chat.el contributors

## 核心问题

模型给出的 shell 命令，"能不能跑"这个判断此前有两个地方在做，因此做出了两个答案。

- `shell_execute` 有一份 19 个只读命令的硬白名单，`git` 不在其中。校验在审批之前，
  所以不存在"批准一下就能跑"的路径。
- `work_task_start` 没有任何校验，直接把模型给的字符串交给 `sh -c`。而子代理会话
  创建时带 `autoApprove: true`，`chat-session-auto-approve-p` 一旦为真就绕过
  `chat-approval-auto-approve-tools` 列表，所以这条路上既没有名单也没有弹窗。

严格的门旁边开着一扇窗，不构成边界，只构成一个形状像边界的不便。一次真实事故里，
这个不便的代价是 8 分钟：

| 时刻 | 发生了什么 |
|---|---|
| 02:30:31 | `shell_execute` 拒绝 `cd … && git rev-parse … && git log -1 … && git tag -l … \| head -10`，回复只有 `Error: Command not allowed:` 加原命令 |
| 02:30:53–02:37:00 | 六分钟在读 `.git` 内部：`refs/remotes/origin/main`、`packed-refs`、`logs/HEAD` |
| 02:36:18 | 改派子代理，用 `work_task_start` 跑 `git rev-parse … && echo … \|\| echo …`，含 `&&` 和 `\|\|`，直接通过 |
| 02:36:38 | 子代理的 `git log` 撞上 pager，日志里只有 `less` 的两行，20 秒后任务被取消 |
| 02:37:11 | 同一条命令加 `--no-pager` 后立刻成功 |

那六分钟结构上不可能成功：reflog 只有 SHA 没有 subject，commit 对象是 zlib 压缩的，
靠 `cat`/`grep` 永远读不出提交标题。走上死路的原因是拒绝信息没有说这是死路——那条
命令有四个可能的死因（`git` 不在名单、`&&`、`|`、引号），一句"not allowed"对四个死因
覆盖得同样好，也就是一个都没有区分，读到它的人无法修改命令，只能放弃整个方向。

pager 的根因不是 git，也不是 work 工具：`process-connection-type` 默认为 `t`，
Emacs 默认给子进程分配 pty，git 看到终端就起 pager，`less` 在管道上等一个永远
到不了的按键。前台 `shell_execute` 同样中招——实测 `git tag -l` 跑满 60 秒超时。

## 方案

一个决定，两份策略，外加一份非交互环境。

- `lisp/tools/chat-command-gate.el` 是唯一的判断处。`shell_execute` 与
  `work_task_start` 调同一个函数，各自传自己的策略。
- 拒绝是数据（`chat-command-gate-refusal`），带 code、失败的 token、可行形式，
  不是一句话。调用方负责措辞。
- `git` 按子命令放开，不是按首词。白名单按首词匹配，往 `allowed-commands` 里塞一个
  `"git"` 等于放开 `git push --force`。
- 子进程一律用 pipe 而非 pty，并注入禁 pager / 禁凭据提示的环境变量。

## 范围与行为边界

本版覆盖：模型提供的 shell 命令的准入判断、拒绝措辞、工具描述生成、子进程的非交互
环境。不改审批层（谁需要弹窗、什么会被自动批准），那是 spec 001 的范围。

本版验证的判断：把只读 `git` 放进来、并把两条执行路径收到同一个判断上之后，
发版、review、changelog 这类必须读 commit 区间的工作可以在一次会话内完成，
而写操作仍然进不来。

## 全局规则

### 1. 拒绝必须可执行

每个拒绝带三样东西，缺一不可：

| 字段 | 含义 | 为什么必需 |
|---|---|---|
| `code` | 规则符号 | 测试可断言，调用方可分支 |
| `token` | 失败的那个词 | 读者不必拿整条命令去比对名单 |
| `hint` | 可行形式 | 只说"不行"的拒绝只能用"放弃"来回应 |

`chat-command-gate-explain` 把三者拼成模型读到的句子，顺序是 token、原因、出路。

### 2. 策略是参数，不是全局

| 调用方 | 程序名单 | 分隔符 | 理由 |
|---|---|---|---|
| `shell_execute` | `chat-tool-shell-allowed-commands` | 不允许 | 经 `make-process` 跑单个程序，管道无法履行 |
| `work_task_start` | `chat-work-task-allowed-commands` | 允许，逐段校验 | 后台任务本身就是 shell 行，`cd build && make` 是它的用途 |

共享的是判断，不是名单。一份名单同时服务两者，要么禁掉第二个的用途，
要么放开第一个刻意避开的东西。

### 3. 任何策略都不接受的元字符

`>` `<` `` ` `` `$` 换行，以及不构成 `&&` 的单个 `&`。

- 重定向写到命令输出之外的地方去。
- 反引号和 `$` 运行或读取命令没有命名的东西。
- 单个 `&` 是后台化：后台任务活得比启动它的这次调用更久，逃出了本该约束它的超时，
  也不向任何人汇报。`&&` 两者都不是，所以必须和它区分开——这是 `&` 不写进正则、
  而由 `chat-command-gate--lone-ampersand` 单独扫描的原因。

引号内的分隔符是数据。`grep 'a;b' file` 里的分号是搜索模式的一部分，拒绝它就是在
拒绝一个搜索模式。

### 4. git 按子命令判断

| 类别 | 内容 | 规则 |
|---|---|---|
| 只读 | `log` `show` `diff` `status` `rev-parse` `rev-list` `describe` `blame` `shortlog` `ls-files` `ls-tree` `cat-file` `for-each-ref` `merge-base` `name-rev` `grep` `count-objects` `whatchanged` | 直接通过 |
| 列出即读、否则写 | `tag` `branch` `stash` `worktree` `remote` `note` | 仅当无位置参数、或带列出类 flag 时通过 |
| 其他 | `push` `commit` `reset` `checkout` `clean` `rebase` `config` `symbolic-ref` … | 拒绝 |

刻意不收的三个看起来像查询而不是查询：`config` 加一个 flag 就写，`remote` 收
`add`，`symbolic-ref` 给第二个参数就移动 HEAD。

子命令之前的选项也要检查，不能跳过：只允许 `--no-pager`、`--literal-pathspecs`
和 `-C DIR`。`-c` 必须挡住——`git -c alias.log='!sh' log` 拼写成一个只读子命令，
但不是。

参数里出现 `--output` `--exec` `--upload-pack` `--receive-pack` `--ext` 前缀时拒绝：
`git log --output=FILE` 写文件，`--exec` 运行程序，外层子命令再只读也不是查询。

### 5. 子进程不许等人

`:connection-type 'pipe` 加 `chat-command-gate-environment`，两者都要，缺一不可：

- 变量只覆盖能点名的程序，pipe 通过移除它们检查的那个终端覆盖其余。
- 强制配置的 `core.pager` 不查终端，所以 pipe 单独也不够。

注入的变量及其理由：

| 变量 | 挡住的挂起方式 |
|---|---|
| `GIT_PAGER=cat` `PAGER=cat` | pager 等按键 |
| `GIT_TERMINAL_PROMPT=0` | git 等密码 |
| `TERM=dumb` | 同上，且让 ANSI 颜色不进入结果 |
| `GIT_OPTIONAL_LOCKS=0` | 只读 git 不取 index lock，不让并发命令失败 |

环境是追加而不是替换，否则命令丢掉 `PATH`，连自己点名的程序都找不到。

### 6. 工具描述从变量生成

`chat-command-gate-describe` 生成描述文本。此前描述是写死的字符串，往变量里加一个
命令，描述仍然说它不可用——而模型读描述，不读变量，两者一漂移就无法察觉，
直到模型拒绝使用一个其实能用的命令。

`chat-code.el` 的系统提示词同步改：读拒绝信息里的 token 和可行形式重新组织，
不要重复同样的形状，也不要因此放弃这条命令；链式命令拆成多次调用。

### 7. 运行中的工具不是卡住的流

`chat-request-diagnostics-stall-message` 在有工具在飞时返回 nil。

事故里最糟的一条信息就出在这里：子代理干了两分半，主请求在等，界面报的是
"Stream has stalled without a new chunk"。流已经正常结束了，在进行的是流要求的
东西，所以这条通知点错了组件、暗示了一个没发生的失败，并且确实被当成失败读了。

- 工具计数而非置标志位：一步可以调多个工具，被第一个结果清掉的标志位会把其余
  还在跑的工具报成沉默。
- `tool-call` 把 phase 置为 `tool-loop`。此前整个工具调用期间 phase 停在
  `streaming`，这正是"已结束的流"被描述成"卡住的流"的原因。
- 不报 stall 不够，还要解释等待：`Running <tool> (Ns)`，秒数会动。读者在长工具
  调用期间的问题是"还有没有在动"，只有会动的数字能回答。
- 提示定时器改为重复触发、说出一次后自停。此前是一次性的：单次触发落在长工具调用
  期间就被消耗掉，之后真的卡住反而不报了——把误报换成沉默，不是改进。

## 功能规格

### 模块：chat-command-gate.el

| 接口 | 用途 |
|---|---|
| `chat-command-gate-check (command &key commands separators)` | 返回 nil 或 refusal |
| `chat-command-gate-refusal-p` / `-code` / `-token` / `-hint` | 读 refusal |
| `chat-command-gate-explain (refusal &optional command)` | 拼成给模型的句子 |
| `chat-command-gate-split (command)` | 唯一的 argv 切分 |
| `chat-command-gate-segments (command)` | 按引号外的分隔符切段 |
| `chat-command-gate-describe (commands)` | 生成工具描述里的命令清单 |
| `chat-command-gate-environment ()` | 非交互环境 |

切分只有一份：门和执行器必须对"词在哪里"达成一致，第二个切分器会批准一条命令
而运行另一条。

### 模块：chat-tool-shell.el

- `chat-tool-shell-refusal (command)` 返回原因；`chat-tool-shell-validate` 保留
  布尔问法，供既有调用方与测试使用。
- `cd DIR && COMMAND` 前缀仍然支持，由本模块在进门之前剥离。因此拒绝 `&&` 时要
  补一句这个例外——否则读者拿到的规则比事实更严，会以为没有办法选目录。
- `chat-tool-shell-execute-unrestricted` 不变：那是人敲进去的命令，人已经决定了
  要跑什么。模型提供的参数永远不走这条。

### 模块：chat-work.el

- `chat-work-task-refusal (command)` 用允许分隔符的策略校验。
- 拒绝发生在启动之前，且抛错而不是建一条失败任务：事后两者在任务列表里长得一样，
  含义完全不同——一个是命令坏了，一个是门关着。
- `unknown-command` 的拒绝点名 `chat-work-task-allowed-commands`，让缺口自己说明
  怎么补。构建/测试运行器刻意不进默认名单：猜项目用哪套工具，猜出来的名单对每个
  项目都是错的，却对所有项目都显得可靠。

## 验收标准

1. `git log --oneline -20`、`git rev-parse --abbrev-ref HEAD`、`git status --short`、
   `git tag -l`、`git describe --always` 在 `shell_execute` 下通过并返回真实输出。
2. `git push` / `commit` / `reset --hard` / `checkout` / `clean` / `rebase` /
   `config` / `symbolic-ref HEAD refs/heads/x` 被拒，code 为 `git-subcommand`。
3. `git tag` 与 `git tag -l 'v*'` 通过；`git tag v1.0`、`git tag -d v1.0`、
   `git branch topic`、`git branch -d topic` 被拒，code 为 `git-writes`。
4. `git -c alias.log=x log` 被拒，code 为 `git-option`，token 为 `-c`；
   `git --no-pager log -1` 与 `git -C /tmp status` 通过。
5. `git log --output=/tmp/x`、`git diff --output /tmp/x` 被拒，code 为
   `denied-argument`。
6. `git` 单独一个词被拒，hint 里列出只读子命令。
7. 未在名单上的程序被拒，token 是该程序名，hint 里列出全部允许的程序。
8. 每一种拒绝都带非空 hint。
9. `cd /tmp && git log` 在无分隔符策略下 token 为 `&&`，hint 含"own call"；
   经 `shell_execute` 时结果里另有 `cd DIR` 例外说明。
10. `echo hi > /tmp/x`、`cat < /tmp/x`、`` echo `whoami` ``、`echo $HOME` 在两种
    策略下都被拒。
11. `make build &` 被拒且 token 为 `&`；`make build && make test` 在允许分隔符的
    策略下通过。
12. `grep 'a;b' file` 与 `grep "a|b" file` 通过；`grep a;b file` 被拒。
13. 允许分隔符的策略逐段校验：`make build && rm -rf /` 与 `git log | rg x` 被拒，
    且 token 是链中被拒的那个程序名。
14. 空字符串、纯空白、nil 被拒，code 为 `empty`。
15. `chat-command-gate-split` 保持 `awk 'BEGIN{print 1}' file`、`echo "a b" c`、
    `echo a\ b` 的分词。
16. `chat-command-gate-describe` 的输出随传入名单变化；名单含 `git` 时点名只读
    子命令。
17. `shell_execute` 与 `work_task_start` 的注册描述包含各自变量里的每个程序名。
18. `chat-command-gate-environment` 含 `GIT_PAGER=cat`、`PAGER=cat`、`TERM=dumb`、
    `GIT_TERMINAL_PROMPT=0`，且 `process-environment` 的每一项都仍在其中。
19. `git log -1 --format=%H` 经 `shell_execute` 在 10 秒内返回 40 位 SHA，
    输出不含 `timed out`，也不含 `Press RETURN`。
20. `git log -1 --format=%H` 作为后台任务在 15 秒内 `succeeded`，
    任务日志不含 `Press RETURN`。
21. `chat-work-task-refusal` 通过 `git log --oneline`、`cd /tmp && git log -1`、
    `git log --format=%s | head -20`；拒绝 `rm -rf /tmp/x`、`curl … | sh`、
    `git log && rm -rf /`、`git log && git push`。
22. 被拒的后台命令不创建任务：`chat-work--tasks` 数量保持为 0，且抛错。
23. `cargo build` 的拒绝信息里出现 `chat-work-task-allowed-commands`。
24. 有工具在飞时 `chat-request-diagnostics-stall-message` 返回 nil；
    工具开始前与结束后返回非 nil。
25. 两个 `tool-call` 后 `:tools-in-flight` 为 2，收到第一个结果后仍不报 stall，
    两个结果都到齐后计数归零并恢复报 stall。
26. `tool-error` 同样使计数归零。
27. `tool-call` 使 phase 变为 `tool-loop`，`:running-tool` 为该工具名。
28. `chat-request-diagnostics-live-detail` 在 `tool-loop` 且有 `:running-tool`
    与 `:tool-started-at` 时输出 `Running <tool> (Ns)`。

## 待确认问题

**子代理会话的 auto-approve 越过了 spec 001 自己写下的边界。** spec 001 §1.3 说
"默认 shell_execute 不纳入自动同意范围（需额外配置）"，但
`chat-approval--auto-approve-p` 的实现是
`(or session-auto-approve always-auto-approve (and global-auto-approve in-auto-approve-list))`——
session 级开关一旦为真就短路，`chat-approval-auto-approve-tools` 列表完全不参与。
子代理会话创建时带 `autoApprove: true`（见 `~/.chat/sessions/child-session-*.jsonl`
的 state 行），所以子代理里任何需要审批的工具都自动通过。

本 spec 的硬闸门与审批层无关、在审批之前，所以上述实现已经把这个洞在执行层堵住了：
现在子代理跑 `sh -c` 也过不了名单。但"什么可以不经人同意就跑"这个问题本身仍然
悬着，属于 spec 001 的范围，需要单独决定，不在本版处理。
