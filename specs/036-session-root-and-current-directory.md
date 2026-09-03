# Session Root Directory and Current Directory

Status: complete
Date: 2026-09-03
Roadmap: —
Decision: —

## Goal

一个会话有两个目录，回答两个不同的问题。本 spec 把它们正式分开，并把两者
都纳入模型可见的上下文。

- **对话根目录（root directory）**：会话的稳定锚点。项目指令（AGENTS.md
  收集）、目标（Goal）和项目范围以它为准。它必须稳定——根跟着 shell 漂移，
  模型的项目图景就会跟着漂移，行为因此不稳定。
- **当前目录（current working directory）**：shell 命令和相对路径实际解析的
  位置，`/cd`、`!cd`、`pushd` 会频繁移动它。它是既有概念，即 session 元数据里
  的 `working-directory`。

两者必须分开存储、分开变化、分开传达。用 `/cd` 的落点当项目根，是这次设计
要消灭的混淆。

## Contracts

### 存储与生命周期

- 根目录记录在 session 元数据 `root-directory`，随会话持久化。
- 首次打开会话时钉住（pin）：尚无记录的会话以"代码会话的 project root →
  工作目录"的顺序取一个锚点写入记录。写入之后，只有显式命令能移动它。
- `chat-session-root-directory` 的求值顺序：已记录的根 → 代码会话的
  project root → 工作目录。记录的根若已不存在，读作不存在并落入下一顺位。
- `/cd`、workspace 切换等任何路径**不得**移动根目录。移动根目录不移动
  当前目录——两者回答不同的问题，耦合其中之一都会让 shell 漫游悄悄改了
  项目的家。

### 命令

- `/root` 无参数：报告当前根目录与当前目录。
- `/root <dir>`：把根目录指向 `<dir>`（必须存在），不影响当前目录。
- 它不是可认领 plain input 的命令（不 sticky），也不在回复进行中运行。
- 中文别名 `/根目录`。

### 上下文传达

- 每次请求注入一个 `session-directories` fragment（kind `instruction`，
  authority `runtime`，scope `session`，residency `protected`，不得被压缩
  掉），内容包含：
  - 根目录与当前目录的完整路径，以及各自的角色说明；
  - 常驻规则：模型在做改动前**必须**读取并遵守根目录与当前目录里的
    AGENTS.md；发现机制注入的内容之外若存在未注入的 AGENTS.md，必须先用
    文件工具读取再动手。
- 项目指令图的收集起点从一个变成两个：根目录与当前目录各生成一份
  instruction graph，按 fragment id 去重合并。每份图自身已上溯到文件系统
  根，所以 cwd 在根之内时合并不产生新内容；合并真正覆盖的是 cwd 被 shell
  带出根之外的情形。
- agent 运行时的 `project-root` 缺省取会话根目录，而非工作目录；
  `target-path` 仍取工作目录（当前目录）。

## Acceptance

1. 未记录根的会话以工作目录为锚；钉住后移动工作目录，根不变。
2. 根目录随会话持久化，重新加载后不变。
3. `/root <dir>` 改变根目录且不动当前目录；`/root` 报告两者。
4. 上下文 fragment 同时出现根目录与当前目录的路径，并含必须阅读两处
   AGENTS.md 的规则；fragment 为 protected，不被压缩。
5. 根目录与根之外的当前目录各有 AGENTS.md 时，两者的内容都进入上下文。
6. agent 运行上下文缺省以根目录为 project-root。
7. `/根目录` 与 `/root` 等价。
