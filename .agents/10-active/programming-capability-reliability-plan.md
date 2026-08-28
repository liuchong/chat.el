# Programming Capability Reliability Plan

- Type: progress
- Attention: active
- Status: active
- Scope: coding-agent-reliability
- Tags: coding, evaluation, code-intelligence, editing, verification, context, planning, sandbox, review

## 1. 文档目的

本文定义 `chat.el` 下一阶段编程能力建设的唯一活动方案。它把“提高编程能力”拆成可实现、可测试、可比较和可验收的工程合同，覆盖：

1. 真实编程任务评测；
2. 语义代码理解和仓库上下文选择；
3. 文件读取与写入一致性；
4. 修改后的自动验证和有限修复；
5. 可替换的执行隔离后端；
6. 独立代码审查和多 Agent 协作；
7. 性能、可观测性、兼容性和最终验收。

本文不以工具数量、界面项目数量或模型输出观感作为成功标准。最终判断只看固定任务集上的可重复结果、确定性测试、安全性证据和运行指标。

### 1.1 术语和判定口径

- **canonical suite**：不访问在线模型和外部服务、从干净 Emacs 启动、必须稳定通过的 unit、integration、e2e 和 offline Eval 集合。
- **live Eval**：显式选择 provider/model 后运行真实 Agent loop 的独立评测，不属于 canonical suite。
- **task**：具有固定 ID、revision、fixture digest、setup、允许修改范围和确定性 judge 的任务定义。
- **trial**：某个 task 在一个固定 runtime/model/config snapshot 下的一次完整运行。
- **valid trial**：fixture setup 成功并且 Agent 已开始的 trial。Agent 开始后的超时、取消、权限阻塞、工具错误和基础设施错误都算失败，不得从分母删除。
- **invalid trial**：Agent 开始前即因评测框架自身损坏、fixture 无法 setup 或 judge 无法启动而终止的 trial。它不进入成功率，但必须单独报告、修复并重跑。
- **success**：Agent 以 completed 结束、确定性 judge 通过、required verification 全部通过、无越界修改、无未处理 stale write，并且工作区最终状态满足 task 合同。缺少任一条件即失败。
- **allowed paths**：task 或 child task 显式声明可写的 canonical path 集合；只读不等于允许写。
- **required verification**：profile 中 `required-p` 为真的 step；not-run、blocked、timeout、cancelled 和 failed 都不是通过。
- **baseline**：M9 使用固定 task revisions、fixture digests、provider/model、capability snapshot、profile 和运行参数产生的结果集合。任一身份变化后不得与旧 baseline 直接比较，必须重跑对应 baseline。
- **large-repo task**：task manifest 明确带有 `large-repo` tag，并使用不少于 10,000 个受索引文件的固定 fixture；不得在看到结果后临时改变该分类。
- **百分点**：成功率的绝对差，例如 70% 到 85% 为提高 15 个百分点，不是相对提高 15%。

## 2. 当前基线

### 2.1 已具备的基础

- Agent 循环已经从 UI 中独立，支持流式与异步模型事件、工具续轮、取消和 step budget。
- Session 使用持久 JSONL，支持分支、压缩、恢复、Trace 和审计事件。
- 文件层已有读、写、替换、patch、路径保护、diff 和多操作预规划提交。
- Checkpoint、session-owned workspace、worktree 和 execution backend 合同已经存在。
- 后台命令、workflow、task 和 subagent 共用持久任务状态机。
- Guard、审批、授权条目和 session 审查记录已经存在。
- `chat-eval` 已提供版本化场景、不可变结果、原子持久化和同版本比较。
- 内置 Eval 目前只有 editing、Guard、recovery、compaction、provider protocol 五个离线场景。
- Code 上下文已有 token budget、自研符号索引和可选 LSP 辅助模块。
- 当前自研符号索引主要通过语言特定正则和轻量扫描提取符号及调用。
- 当前 LSP 模块依赖部分客户端内部函数，缺少定义、引用、实现、调用层级的统一异步合同。
- 当前测试运行模块按文件扩展名猜测框架，尚未形成项目级验证计划和 Agent 自动闭环。
- 规范回归基线为 1567/1567 通过；该数字必须在实施开始时重新测量并写入 M9 基线结果。

### 2.2 已确认的核心差距

| 编号 | 差距 | 直接后果 |
|---|---|---|
| G1 | 没有覆盖真实仓库任务的重复模型评测 | 无法证明一次改动提升了实际编程成功率 |
| G2 | 语义查询没有统一后端和可靠降级顺序 | 定义、引用和影响范围可能依赖猜测 |
| G3 | 缺少按相关性排序的 repo map | 大仓库上下文容易过量或遗漏关键依赖 |
| G4 | Agent 写入不强制绑定运行时记录的读取版本 | 外部编辑可能被陈旧内容静默覆盖 |
| G5 | 测试、诊断和构建不是默认的修改后闭环 | Agent 可能在未验证时宣告完成 |
| G6 | execution backend 抽象已有但隔离后端不足 | 命令审批不能替代 OS 级文件和网络隔离 |
| G7 | 缺少只读、结构化、独立上下文的 Review Agent | 自己修改后自己确认，漏判和确认偏差较高 |
| G8 | 多 Agent 已能运行但缺少面向代码变更的合并合同 | 并行任务可能重复编辑或在合并时互相覆盖 |

## 3. 最终目标

最终系统应当满足以下可观察行为：

1. Agent 在修改现有文件前必须读取该文件，并以运行时记录的内容版本作为写入前置条件。
2. Agent 能通过统一代码智能接口获得定义、引用、实现、诊断和调用关系；不可用时明确降级，不伪造语义结果。
3. 系统在有限上下文预算内优先提供与任务、当前 diff、焦点文件和失败诊断最相关的代码。
4. 每个代码修改批次都产生验证计划、执行记录和最终验证结论；未执行或失败不得显示为已验证成功。
5. 失败可在明确预算内反馈给同一 Agent 修复；预算耗尽后留下可继续的证据，不进入无限循环。
6. Agent 能把目标、约束、事实、决策、阻塞和下一步写入可查询的结构化工作笔记；压缩前后保持身份、来源和作用域。
7. 上下文由带类型、来源、权限、作用域、优先级和预算策略的 fragment 组成；AGENTS 文件及其显式依赖形成可检查规则图，而不是无标识字符串拼接。
8. 除明确的单步或只读问答外，编码任务具有持久 TODO 计划；修改状态、证据和阻塞会进入事件并在聊天 UI 原生展示。
9. 命令运行在声明了文件、网络、环境和时间权限的 execution backend 中；后端能力不足时必须显式降级或拒绝。
10. Review Agent 默认只读，输出结构化、可定位、去重并带证据的发现，不直接修改代码。
11. 所有关键行为进入现有 session event、Trace、task、checkpoint 和 Eval 体系，不创建第二套事实来源。
12. 最终能力由固定任务集重复测量，并满足第 13 节全部验收门槛。

## 4. 非目标

- 不绑定任何单一模型或供应商。
- 不用模型名称推断模型能力；继续使用现有 capability facts。
- 不在核心中强制安装语言服务器、容器运行时或第三方工具。
- 不以自动修改用户未授权的文件来换取更高任务通过率。
- 不把模型评分作为唯一成功判定；能用编译、测试、文件状态和确定性规则判定时必须优先使用它们。
- 不把 worktree 当作安全沙箱；worktree 只负责 Git 状态隔离。
- 不重建 session、task、event、Trace、checkpoint 或 execution 的平行存储。
- 不改变 Markdown、MDP、普通聊天和非编码 session 的现有行为。
- 本阶段不处理发布、版本号和远程部署。

## 5. 总体架构

```text
User objective
      |
      v
Coding task planner
      |
      +--> Work context store -------> scoped notes / rules / artifacts
      |
      +--> Durable work plan --------> TODO state / evidence / native UI
      |
      +--> Code intelligence facade --> semantic backends --> repo map
      |
      +--> Versioned file tools ------> read set / write set gate
      |
      +--> Checkpoint + Workspace ----> reversible owned changes
      |
      +--> Verification planner ------> execution backend
      |                                      |
      |                                      v
      |                              diagnostics / tests / build
      |                                      |
      +<----------- bounded repair feedback-+
      |
      +--> Read-only review agent --> structured findings
      |
      v
Session events + Trace + Eval result
```

### 5.1 单一事实来源

- 会话事实只写 session wire。
- 任务状态只写 `chat-task`。
- 工作区归属只写 `chat-workspace`。
- 回滚证据只写 `chat-checkpoint`。
- 命令状态只写 `chat-execution`。
- 运行中目标、规则、工作笔记和计划只写版本化 work-context / work-plan 合同；prompt 和 UI 只是投影。
- Eval 结果只写不可变 `chat-eval-result`。
- repo map、符号索引和 LSP 结果都是可重建缓存，不具有用户数据权威性。

### 5.2 默认降级顺序

代码智能查询按以下顺序选择后端，并在结果中记录来源：

1. 当前项目中已经运行且可异步访问的语义服务；
2. Emacs 公共 `xref`、`imenu`、`flymake` 和 `treesit` API；
3. 项目缓存中的结构索引；
4. 当前轻量正则索引；
5. 文本搜索。

后端不可用、超时或不支持某操作时返回 typed unavailable，不得返回看似成功的空语义结果。空结果和不可用是两个不同状态。

## 6. 核心数据合同

### 6.1 文件观察版本

新增运行时记录 `chat-file-observation`，至少包含：

```elisp
(cl-defstruct chat-file-observation
  path                 ; file-truename 后的绝对路径
  kind                 ; file 或 absent
  digest               ; file 为 SHA-256，absent 为 nil
  size                 ; 原始字节数
  observed-at          ; 毫秒时间戳
  session-id
  turn-id
  run-id)
```

规则：

- `files_read` 和成功的精确行读取必须记录观察版本。
- 只读取部分内容仍记录整个文件的 digest，避免局部读取后覆盖未知内容。
- 新文件通过 `kind=absent` 表达，不使用空字符串 digest。
- 所有 Agent 可见写工具必须从当前 run 的 read set 读取观察版本。
- 模型传入的 `expected_version` 只能引用运行时已经记录的版本，不能扩大权限或替代 read set。
- 写入前再次计算当前版本；不一致时返回 `stale-file`，保持文件不变。
- 多文件 patch 在规划完成后、第一次落盘前重新验证整个 read set；任一文件漂移则整批不提交。

### 6.2 统一代码智能结果

新增 facade 合同，所有操作返回：

```elisp
(:status ok|unavailable|timeout|error
 :operation definition|references|implementations|symbols|callers|callees|diagnostics
 :backend eglot|xref|treesit|index|text
 :revision STRING
 :items LIST
 :diagnostics LIST)
```

每个 item 至少包含 `:path`、`:line`、`:column`、`:name`、`:kind`、`:confidence` 和 `:source`。路径必须位于允许的项目范围内。结果顺序必须确定：先按得分降序，再按路径、行、列升序。

### 6.3 Repo map

`chat-repo-map` 是可重建缓存，至少存储：

- 文件节点；
- 符号定义节点；
- import/require/module 边；
- definition-reference 边；
- test-target 边；
- 当前 Git diff、焦点文件和诊断标签；
- 文件 digest、解析后端和缓存版本。

每个候选上下文的分数使用可测试的显式分量：

```text
score = query_match
      + symbol_relation
      + changed_file_proximity
      + focus_proximity
      + diagnostic_relevance
      + test_relation
      - token_cost
      - duplicate_penalty
```

权重使用常量或配置声明，禁止散落在提示词和调用点中。相同输入、索引版本和预算必须得到相同排序。

### 6.4 验证计划

新增 `chat-verification-profile` 和 `chat-verification-step`：

```elisp
(cl-defstruct chat-verification-step
  id kind argv directory timeout-seconds max-output-bytes
  trigger required-p approval-class)

(cl-defstruct chat-verification-profile
  id project-root source revision steps repair-limit)
```

规则：

- `argv` 必须是字符串列表，不得将模型文本拼成 `bash -c`。
- `kind` 只能是 `format`、`diagnostics`、`lint`、`typecheck`、`test` 或 `build`。
- profile 来源按用户配置、项目配置、确定性探测、保守默认的顺序解析。
- 自动探测只读取 manifest 和既有项目命令，不安装依赖、不修改配置。
- required step 未执行、超时、取消或失败时，整个验证状态不得为 passed。
- 所有输出必须限长，完整日志使用 execution 现有持久路径保存引用。

### 6.5 Review finding

Review Agent 只能输出以下结构化记录：

```elisp
(:severity critical|high|medium|low
 :confidence NUMBER
 :category correctness|security|data-loss|concurrency|performance|compatibility|test-gap
 :path STRING
 :line INTEGER
 :title STRING
 :evidence STRING
 :recommendation STRING
 :verification STRING)
```

缺少有效项目内路径、正整数行号或具体证据的记录不得进入正式 findings。样式、偏好和无行为影响的建议默认不报告。

### 6.6 结构化上下文 fragment 与工作笔记

新增 `chat-context-fragment`、`chat-context-bundle` 和 `chat-work-note`。每个
fragment 必须携带 stable ID、kind、authority、source、scope、priority、budget
policy、digest 和 typed payload；每个工作笔记必须携带 key、kind、value、tags、
source、scope、status、revision 和 timestamps。

规则：

- `instruction`、`objective`、`working-note`、`history`、`code`、`tool-schema` 和
  `verification` 等区域在运行时保持分离，只在 transport adapter 最后序列化。
- scope 至少支持 global、project、directory subtree、exact path、session、turn、
  task 和 child task；不匹配的 fragment 不得进入请求。
- authority 至少区分 system、user/developer instruction、project rule、runtime
  fact、Agent note 和 untrusted content；工作笔记不能升级为规则。
- AGENTS 文件按 filesystem root 到目标路径排序；每个源文件保留自身目录作用域、
  digest 和 precedence。显式依赖继承声明它的规则作用域，必须限制在可信项目根，
  并有 cycle、depth、file count 和 byte limit。
- 工作笔记按 scope + key、tag 和 kind 建索引；upsert 必须使用 revision，避免旧
  Agent step 覆盖新记录。删除、归档和 supersede 均可审计。
- compaction 只能压缩允许压缩的 fragment；目标、活动计划、未解决 blocker、
  resident rule 和当前任务关键笔记以结构身份重新投影，不能依赖旧 prompt 文本幸存。

### 6.7 持久 TODO 计划

新增 `chat-work-plan` 和 `chat-work-plan-item`：

```elisp
(cl-defstruct chat-work-plan
  schema-version id revision session-id task-id objective status mode items
  created-at updated-at completed-at metadata)

(cl-defstruct chat-work-plan-item
  id title status order depends-on acceptance evidence-ids
  started-at completed-at blocked-reason metadata)
```

状态集固定为 plan 的 `active|completed|blocked|cancelled` 和 item 的
`pending|in-progress|completed|blocked|skipped`。同一 plan 最多一个
`in-progress` item；依赖未完成时不得启动；completed 必须附可追溯 evidence，
blocked 必须附原因。`auto` 模式只允许 answer-only、read-only 或确定性单步任务以
枚举 reason 跳过建表，任何多文件修改、child task 或 repair loop 都必须先有计划。

## 7. 施工阶段

阶段编号延续已完成的 M0-M8。每个阶段必须遵循：先测试合同，再实现；阶段测试和规范测试全部通过后立即提交；未满足退出条件不得开始依赖它的下一阶段。

### M9：建立真实编程 Eval 基线

#### 目标

让后续每项能力建设都能回答“相同模型和任务下，实际成功率是否提高”。

#### 修改范围

- 扩展 `lisp/core/chat-eval.el` 的 metadata 投影，不改变 schema v1 已有字段语义。
- 在 `lisp/agent/` 新增编码任务 Eval runner；保留现有五个离线场景。
- 在 `tests/fixtures/coding-eval/` 建立小型、可复制的 Git fixture 仓库。
- 在 `tests/integration/` 增加 worktree、checkpoint、Agent loop、判定器集成测试。
- 增加独立命令运行 live coding eval；不得加入 canonical offline suite。

#### 任务集

首批至少 30 个任务，六类各不少于 5 个：

1. 定位并解释代码；
2. 单文件缺陷修复；
3. 多文件行为修改；
4. 重构并保持行为；
5. 根据失败测试修复；
6. 只读审查并定位预埋缺陷。

任务至少覆盖 Emacs Lisp、Python、JavaScript/TypeScript、Go、Rust 五类项目形态。fixture 可以很小，但每个任务必须有确定性 setup、判定命令、允许修改范围和超时。

#### 结果字段

- task id 和 revision；
- fixture digest；
- model capability snapshot；
- success/failure；
- setup、Agent、judge 各阶段耗时；
- 输入、输出、reasoning 和 cache token；
- turn、step、tool error、approval、stale write、verification retry 次数；
- changed files 和越界修改数；
- 最终判定命令及 exit status；
- session、task、workspace、checkpoint、Trace 标识。

#### 测试步骤

1. 单测任务清单解析、fixture digest、结果隐私裁剪和不可变持久化。
2. 集成测试每个 fixture 都能在临时 worktree 中 setup、判定和清理。
3. 注入 Agent 崩溃、超时、取消和非法越界修改，确认结果为失败且无残留进程。
4. 运行现有五个离线场景，确认结果兼容。
5. 运行 canonical suite。
6. 使用固定 provider、model 和 capability snapshot，对 30 个任务各跑 3 次形成开发基线；最终验收时各跑 5 次。

#### 退出条件

- 30 个任务全部可独立重复 setup 和判定。
- 判定不依赖模型自评。
- 同一完成状态重复判定结果一致。
- 每次运行都可追溯到 session、Trace 和不可变 Eval 结果。
- 失败和取消后无遗留 worktree、execution 或后台进程。

### M10：文件 read set / write set 一致性

#### 目标

消除 Agent 用旧内容覆盖用户或其他任务新修改的可能。

#### 修改范围

- `lisp/core/chat-files.el`：版本计算、观察记录、写前验证、错误类型。
- `lisp/tools/chat-tool-caller.el`：run-local read set 和工具参数投影。
- `lisp/agent/chat-agent-loop.el`：run 生命周期创建和清理 read set。
- `lisp/core/chat-checkpoint.el`：沿用原始/完成 digest，不重复保存文件正文。
- `tests/unit/test-chat-files.el` 及 Agent 工具集成测试。

#### 实施步骤

1. 为完整读取、行读取和不存在路径增加版本结果。
2. 实现 runtime-owned read set，key 为 canonical path。
3. 先让写工具在兼容模式记录缺失观察告警，不改变普通 Lisp 调用者。
4. 迁移内置 Agent 工具 schema，使写、替换、insert 和 patch 对现有文件强制要求观察版本。
5. 多文件 patch 增加提交前全量二次校验。
6. 将 `stale-file`、`file-not-read` 和 `version-mismatch` 作为 typed tool error 写入 event 和 Trace。
7. 兼容期测试通过后，将 Agent 暴露路径默认切换为强制模式；普通非 Agent API 保留显式 opt-out。

#### 必测场景

- 读后未变更，写入成功。
- 未读取直接写现有文件，拒绝。
- 读取后由外部进程修改，拒绝且不覆盖。
- 读取后 visiting buffer 存在未保存修改，拒绝。
- 新文件以 absent 版本创建成功；竞争创建时拒绝。
- 多文件 patch 的任一文件漂移，所有文件保持原状。
- move、delete、delete-then-add 和 move chain 均验证源与目标版本。
- session 分支和 subagent 不能继承另一个 run 的 read set。

#### 退出条件

- 上述竞争测试 100% 通过。
- Agent 路径不存在未检测的陈旧写入。
- 现有 patch 原子性测试全部继续通过。

#### 完成记录（2026-08-28）

- 状态：completed。
- 完整读取和行读取返回全文件 SHA-256 版本；运行时以 canonical path 保存带 session、turn、run 和观察时间的 `chat-file-observation`。
- 每个 Agent run 创建独立 read set，异步审批回调恢复同一个执行上下文；普通 Lisp API 在没有 read set 时保持兼容。
- write、replace、insert、legacy patch、multi-file patch、move 和 delete 在 Agent 路径强制校验观察版本；模型提供的 `expected_version` 只能匹配运行时已有观察。
- multi-file patch 在规划完成后、第一次落盘前整体复检；checkpoint 与版本层共用文件 digest 实现，不复制文件正文。
- `file-not-read`、`stale-file` 和 `version-mismatch` 进入 tool error event，现有 Trace 继续投影该事件。
- 15 个 read set、竞态、run 隔离和 typed error 定向测试全部通过；覆盖未读写入、外部修改、未保存 buffer、新建竞争、提交前漂移、move、delete、delete-then-add 和 move chain。
- 文件工具回归 155/155 通过；Agent 与工具调用回归 91/91 通过；canonical suite 1590/1590 通过；integration 2/2 通过，2 个凭证依赖测试按既有条件 skip。

### M11：统一语义代码智能与 repo map

#### 目标

让 Agent 优先依据确定的符号关系理解代码，并在语义能力不可用时可解释地降级。

#### 修改范围

- 重构 `lisp/code/chat-code-lsp.el`，移除对客户端内部变量和内部函数的直接依赖。
- 将 `lisp/code/chat-code-intel.el` 定位为 fallback backend，不再代表统一接口。
- 新增代码智能 facade 和 backend registry。
- 新增 `lisp/code/chat-repo-map.el`。
- 修改 `lisp/code/chat-context-code.el` 使用 facade 和 repo map。
- 增加每个后端的 fixture 测试和降级测试。

#### 实施步骤

1. 先定义 typed result、backend capability 和异步 callback 合同。
2. 包装 Emacs 公共 xref、imenu、flymake 和 treesit API。
3. 为已经存在的语义服务实现可选 adapter；探测不得自动启动或安装服务。
4. 将当前正则索引接入 fallback adapter，并保留索引文件兼容读取。
5. 建立增量 repo map：只重建 digest 变化的文件和相邻边。
6. 实现显式评分函数和 token-cost 去重。
7. 将上下文来源、backend、revision 和裁剪原因写入 request diagnostics。
8. 在 Code session 中默认启用新 facade；异常时降级，不影响普通聊天。

#### 测试语料

每种支持语言至少包含：重名符号、跨文件引用、嵌套定义、接口/实现、测试关联、无效语法、UTF-8/CJK 路径和大文件跳过场景。

#### 退出条件

- 定义定位准确率不低于 98%。
- 引用集合 precision 不低于 95%，recall 不低于 90%。
- 固定查询的相关文件 Top-5 命中率不低于 90%。
- 后端不可用、超时、空结果三种状态可区分。
- 相同输入得到确定性排序。
- 10,000 文件 fixture 上，主循环单次不可让出时间不超过 50ms；warm query 的 p95 不超过 200ms。

#### 完成记录（2026-08-28）

- 状态：completed。
- 新增统一异步代码智能 facade、typed result、backend registry、确定性排序、项目路径约束、总超时和同步热缓存读取；`ok`、`empty`、`unavailable`、`timeout`、`error` 以及逐后端 attempts 均可区分。
- 公共语义 adapter 仅使用 `xref`、`imenu`、`flymake` 和 `treesit` 公共 API；不会探测客户端内部状态，不会自动启动或安装语言服务。已有语义服务可通过公共 xref backend 自动参与。
- 现有轻量索引作为 `index` fallback 接入，旧 JSON 索引读写保持兼容；同时修正 TypeScript 分派、跨行符号误吞、Lisp 引用遗漏、定义行误计引用和最近包含函数判断，并补充 class、interface、trait、struct、generic 和 method 结构提取。
- 新增可重建 repo map，保存 canonical path、digest、语言、符号、import、test relation、大文件跳过原因和 revision；扫描、解析和边重建均按 timer slice 与条目上限让出主循环，后续刷新只解析 digest 变化文件并重建变化节点及邻边。
- 上下文排序权重集中声明，综合 query、symbol、focus、changed file、diagnostic、test relation、token cost，按预算去重；相同 revision、查询和预算产生完全相同结果。
- Code session 请求只消费热缓存并异步安排刷新；来源、backend、revision、attempts、预算和截断原因写入现有 request diagnostics。普通聊天不会创建 repo map 或进入代码上下文路径。
- 五语言基础指标 fixture 的 definition accuracy 为 100%，reference precision 和 recall 均不低于方案门槛；扩展语料覆盖重名、跨文件引用、嵌套定义、接口/实现、无效语法和 CJK 路径。
- 固定相关文件查询 Top-5 命中 10/10；10,000 文件 fixture 的单 slice 不超过 50ms，20 次 warm query 的 p95 不超过 200ms。
- M11 与既有代码模块定向回归 18/18 通过；canonical suite 1601/1601 通过；integration 2/2 通过，2 个凭证依赖测试按既有条件 skip。

### M12：项目级自动验证与有限修复

#### 目标

把“代码已经写入”与“任务已经验证”彻底分开，并形成默认验证闭环。

#### 修改范围

- 新增 `lisp/code/chat-code-verify.el`。
- 收敛或替换 `lisp/code/chat-code-test.el` 中按文件猜测和 `bash -c` 拼接的实验路径。
- 扩展 capability pack，提供 plan、run、read-result 三类验证工具。
- 使用 `chat-execution`、`chat-task` 和 runtime events 持久化过程。
- 在 request panel 和 observability view 中展示验证状态。

#### 实施步骤

1. 定义 profile、step、result 和 overall status。
2. 实现项目配置读取和确定性探测；所有命令规范化为 argv。
3. 根据 changed files、repo map 和 manifest 选择最小 targeted checks。
4. 执行顺序固定为 format check、diagnostics、lint/typecheck、targeted test、required build。
5. 将失败压缩为有界反馈，包含命令、exit status、相关日志片段和定位。
6. 默认 repair limit 为 2，允许项目配置 0 到 3；每轮必须产生新 diff 或新失败证据，否则停止。
7. repair 后重跑所有曾失败步骤和受影响的 required steps。
8. 最终状态只能是 passed、failed、cancelled、timed-out、not-run 或 blocked。
9. Agent 最终回复必须从验证结果投影事实，不能仅凭提示词声称通过。

#### 必测场景

- 格式、lint、类型、测试和构建分别失败。
- 命令不存在、依赖缺失、超时、取消和输出超限。
- 第一次失败、一次修复后通过。
- 连续两次相同失败，提前停止。
- repair 产生无关文件修改，拒绝并回滚该轮。
- 项目无可识别验证命令，状态为 not-run，不能显示 passed。
- 预存失败与本次引入失败能通过 preflight fingerprint 区分。

#### 退出条件

- 预埋失败 100% 被检测，0 次假 passed。
- 所有循环在预算内结束。
- 执行日志、验证结果、修改 checkpoint 和最终回复可互相追溯。

#### 完成记录（2026-08-28）

- 已落地 schema 化的 profile、step、step result 和 overall result，终态限定为
  `passed`、`failed`、`cancelled`、`timed-out`、`not-run`、`blocked`。
- 项目配置、确定性探测和 capability 工具统一生成 argv；旧的扩展名猜测与
  `bash -c` 路径已收敛为兼容适配器。
- 验证通过 `chat-execution` 执行，并以 `chat-task`、session event、execution
  record 和 checkpoint 关联；重启后可由 durable task 重建结果。
- 有限修复支持 0 到 3 轮、重复失败指纹提前停止、无新 diff 停止、越界修改
  拒绝与回滚；preflight 指纹区分预存失败和本轮引入失败。
- request panel、observability view 和 Agent 最终答复均从验证结果投影事实；
  最终答复的热路径只读取当前进程、当前 session/turn 的验证缓存。
- 定向模块测试 38/38、Agent 最终投影测试 3/3、隔离 coding fixture 集成测试
  1/1 通过；canonical suite 1615/1615 通过，零 unexpected result。

### M13：结构化工作上下文、笔记与作用域规则图

#### 目标

把 prompt 从若干大字符串升级为可组合、可筛选、可审计的 typed context bundle，
并提供面向当前工作、可跨压缩恢复的结构化笔记区。

#### 修改范围

- 新增 `lisp/core/chat-work-context.el`，定义 fragment、bundle、note、scope 和索引。
- 重构 `lisp/core/chat-project.el`，让 AGENTS 文件与显式依赖输出规则 fragment 图。
- 扩展 `lisp/core/chat-context.el`、`chat-context-budget.el` 和 Agent request projection。
- 扩展 capability pack，提供 note upsert/query/archive/delete 和 context inspect。
- 增加 `tests/unit/test-chat-work-context.el`、project scope/inclusion、compaction 与
  integration 覆盖。

#### 实施步骤

1. 先冻结 schema、enum、scope matching、authority precedence、revision 与限额。
2. 实现 session-owned 原子存储和 `(scope, key)`、kind、tag 索引；不复制 transcript。
3. 将 objective、runtime facts、memory、history、code context、tool schemas 和验证
   证据适配为 fragment；兼容 API 仍可接收字符串，但立即包装并记录来源。
4. AGENTS discovery 输出每个文件独立 fragment；解析显式依赖并建立 parent/child
   图，限制 canonical project root、最大深度 8、文件 64 个、总量 256KiB。
5. 目标路径筛选 scope，按 authority、目录 specificity、显式 priority 和稳定 ID
   排序；冲突不静默覆盖，保留 shadowed provenance 供 inspect。
6. context budget 按 fragment 计量、选择、demote、compact 或 trim；serializer 只在
   provider 边界生成有标签的 messages。
7. compaction 前保存未解决 blocker、决策、下一步和任务事实；压缩后按 stable ID
   重建活动工作上下文，过期/归档笔记不注入。
8. Trace 和 observability 显示候选/选中 fragment、scope、来源、裁剪原因和 note
   读写事件，不保存完整敏感正文。

#### 必测场景

- root 与嵌套 AGENTS 规则只在各自目录 subtree 生效，兄弟目录不泄漏。
- 显式依赖相对路径、重复 include、cycle、越界 path、symlink escape、深度和总量上限。
- 同 key 并发 revision 冲突、supersede、archive、delete 和重启恢复。
- Agent note 不能覆盖 system/user/project instruction，也不能伪装成 verified fact。
- context 压缩前后 objective、active blockers、current decisions 和 next step 等价。
- 8K/32K/128K 预算下选择确定，单次构建主循环无无界扫描。

#### 退出条件

- AGENTS 与依赖的 scope corpus 100% 选对，0 次跨目录规则泄漏。
- 工作笔记可按 key/kind/tag 在重启和 compaction 后确定性查询。
- request diagnostics 能解释每个 fragment 为什么进入、被遮蔽或被裁剪。
- legacy string API 行为兼容，canonical suite 零 unexpected result。

#### 完成记录（2026-08-28）

- 已落地 typed fragment、bundle 与 revisioned work note；scope、authority、
  residency、budget reason 和 provenance 在 provider 投影前保持独立。
- AGENTS discovery 生成目录作用域规则图，显式 include 受 canonical project
  root、cycle、depth、file count 和 byte budget 约束，失败以 diagnostics 可见。
- project instructions、code context 和 active work notes 在每个 Agent step
  重新筛选，投影消息带 ephemeral metadata，不进入 transcript 或 session。
- note 工具覆盖 upsert/query/resolve/supersede/archive/delete；stale revision
  fail closed，事件不记录敏感 value。
- 定向 context/project/agent/capability/UI/wire 测试通过；canonical 验收结果
  记录在本阶段提交及项目状态中。

### M14：持久 TODO 计划合同与聊天 UI

#### 目标

让非简单编码任务先形成可执行计划，并用计划状态约束循环、保留证据和稳定展示进度。

#### 修改范围

- 新增 `lisp/core/chat-work-plan.el`，持久化 plan/item 状态机与 evidence 关联。
- 在 programming capability pack 注册 plan create/update/read/skip 工具。
- 在 Agent tool boundary 增加 plan-required checkpoint 和复杂度可解释判定。
- 在 `lisp/ui/chat-ui.el` 增加紧凑计划摘要与可折叠明细，复用 runtime events。
- 增加 plan contract、recovery、agent-loop、UI point/window stability 和 Eval 测试。

#### 实施步骤

1. 冻结 plan/item schema、迁移、状态转换、单 active item 和 dependency 规则。
2. plan 绑定 session + foreground task；只持久化意图、状态和 evidence ID，不保存回调。
3. `auto` 策略在 mutation、child task、repair 或第二个实质步骤前要求活动计划；允许
   answer-only、read-only、single-bounded-action 使用枚举 skip reason 并写审计事件。
4. tool result、verification、checkpoint、review finding 和 workspace diff 可作为
   evidence；completed item 缺 evidence 时拒绝转换。
5. Agent turn 前投影 objective、active item、remaining dependencies、blockers 和完成
   比例；不把全部历史计划逐轮重复注入。
6. UI 在输入区上方显示固定单行摘要 `Plan current/total · changed files · diff`；
   `TAB`/鼠标切换原生折叠明细，更新时保持输入 point、window-start 和用户滚动位置。
7. 重启从 durable plan 重建；运行中 item 变为 blocked/interrupted，需要显式 resume，
   不自动假装继续执行。
8. Trace 记录 plan-created、item-started/completed/blocked、plan-completed/skipped，
   Eval 统计无计划 mutation、重复完成、停滞和计划偏离。

#### 必测场景

- 问答和单次只读查询不强制计划；多文件修改在无计划时 fail closed 并可恢复。
- 非法状态跳转、两个 active item、未完成依赖、无 evidence 完成全部拒绝。
- 用户在运行中修改目标，plan revision 更新且旧 step 不能覆盖。
- restart、cancel、compaction、repair 和 child task 后计划状态、当前项和证据不丢。
- 流式回复持续增长时计划 UI 不移动输入 point、不重置 window-start、不跳回中间。
- 折叠/展开、窄窗口、CJK 标题、长路径和无图形终端均可读。

#### 退出条件

- fixture 中所有非简单编码任务 100% 在首次 mutation 前建立活动计划。
- plan 状态机、证据和 task/session/event 关联可在重启后完整重建。
- UI 状态与 durable plan 一致，连续 1,000 次状态更新无 point/window 跳动和残留 timer。
- 计划额外 prompt token 在 large task 中位数不超过总输入的 5%。

#### 完成记录（2026-08-28）

- schema v1、revision 冲突拒绝、DAG、单 `in-progress`、task/session scope、
  interrupted recovery 和 evidence resolver 已实现。
- `auto`、`required`、`off` 三种模式及枚举 skip 审计已进入真实 tool boundary；
  活动计划没有当前执行项时仍然 fail closed。
- 活动切片是 request-only typed context，独立限制为 2,000 字符，只投影上一轮
  后新增 evidence；完整历史由 plan read 查询。
- 输入区上方原生折叠 UI 与 durable revision 同源；CJK 和连续 1,000 次更新的
  point、window-start、timer、overlay 稳定性测试通过。
- plan 核心 19/19 定向测试通过；Agent gate、capability surface 和全量回归通过，
  M14 独立提交保存可复现验收证据。

### M15：执行隔离后端

#### 目标

在审批之外，用运行环境限制命令实际能够读取、写入和联网的范围。

#### 修改范围

- 扩展 `lisp/core/chat-execution.el` backend capability 合同。
- 视探针结果新增平台受限后端和可选容器后端。
- 验证 profile 声明所需 filesystem、network 和 environment capability。
- 增加 `tests/spike/` 平台探针以及 unit/integration 隔离测试。

#### 实施步骤

1. 先编写探针验证当前平台可用的文件、网络、进程和信号隔离机制。
2. 探针必须在前台、带超时运行，并证明退出后没有残留进程。
3. 定义 backend capabilities：read roots、write roots、network、environment inheritance、timeout、process tree cleanup。
4. 提供 `inspect`、`build`、`networked-build` 三种最小策略；network 默认关闭。
5. `networked-build` 必须经过现有审批和 Guard，且审批记录写入 session。
6. 后端不满足 step capability 时返回 blocked，不得偷偷回退到 unrestricted local。
7. 保留显式 local backend 作为用户选择，不把它伪装成隔离模式。

#### 安全测试

- 尝试读取项目外敏感路径。
- 尝试写入项目外、父目录和 symlink escape。
- 尝试默认联网。
- 尝试继承未声明环境变量。
- fork 子进程后超时和取消。
- execution 崩溃后检查监听端口、子进程和临时目录。

#### 退出条件

- 隔离模式下全部禁止场景 100% 被阻止。
- 允许的项目内编译和测试能够完成。
- 超时和取消后无孤儿进程、监听端口和不可回收临时目录。
- 后端能力和实际行为一致，并由集成测试证明。

#### 完成记录（2026-08-28）

- execution schema 升级为 v2，策略要求与测得的 backend capability 分离；v1
  记录迁移为显式 `local`，不会被误标为隔离执行。
- Darwin 前台探针在硬超时内证明 deny-default sandbox 可用，公开事实为
  `scoped` filesystem、`controlled` network、`explicit` environment、backend
  timeout 和 process-tree cleanup；能力不可用时 fail closed，绝不回退 local。
- `inspect`、`build`、`networked-build` 已实现。默认网络关闭；联网构建经共享
  approval/Guard 路径取得与 request/session 绑定的一次性授权，retry 必须重新审批。
- 真实测试覆盖项目外读取、父目录写入、symlink escape、默认联网、环境泄漏、
  Clang 项目编译、获批 socket、超时、主动取消、启动准备异常和临时目录清理。
- shell tool、background work 和 project verification 已接入策略选择；显式 local
  仍保留为非隔离用户选择。平台隔离 16/16、三个调用方 47/47 定向测试通过。

### M16：独立 Review Agent 与代码型多 Agent 协作

**实施状态：完成（2026-08-28）。** 实现位于
`lisp/code/chat-code-review.el` 与 `lisp/code/chat-code-collaboration.el`。
Review 使用独立 child session 和只读 profile；finding parser 强制路径、行号、
证据与去重合同。代码 child 使用层级路径资源、session-owned worktree 和拒绝冲突的
merge gate；合并后重新运行 M12 verification。决策与验收证据见 Decision 0030 和
`stage-2026-08-28-independent-review-and-coding-collaboration.md`。

#### 目标

用独立上下文检查变更，并让并行 Agent 在明确资源和 worktree 所有权下协作。

#### 修改范围

- 新增只读 review profile 和 typed finding parser。
- 基于现有 subagent、task、workspace、checkpoint 和 scheduler 扩展 coding role。
- 增加 review 视图或复用现有 observability view 展示 findings。
- 增加 worktree 合并前检查和冲突结果合同。

#### Review 实施步骤

1. Review profile 只暴露读取、搜索、代码智能、diff 和验证证据工具。
2. 输入由目标、base revision、diff、相关 repo map 和验证结果组成，不继承编辑 Agent 的 reasoning。
3. 结构化解析 findings，拒绝无路径、无行号、无证据和重复项。
4. critical/high finding 可选启动第二个只读 verifier；verifier 只能确认、降级或拒绝，不能改写原 finding。
5. findings 写入 session event，并可跳转到文件行。

#### 多 Agent 实施步骤

1. Planner 为每个 child 声明目标、允许路径、读写资源、模型/profile、预算和完成证据。
2. 有写冲突的 child 不得并行调度；无冲突 child 使用独立 session-owned worktree。
3. Parent 只接收有界 summary、changed files、verification 和 checkpoint 标识，不接收完整子 transcript。
4. 合并前验证 base revision、dirty state 和路径所有权。
5. 冲突返回 blocked/conflicted，不自动选择任一方内容。
6. 合并后必须重新执行受影响的 required verification steps。

#### 退出条件

- Review 预埋 critical/high 缺陷 recall 不低于 85%，precision 不低于 80%。
- Review Agent 在所有测试中 0 次写文件和运行写作用命令。
- 无冲突并行任务可以安全合并并通过验证。
- 有冲突任务 100% 被调度器或合并门识别，不发生静默覆盖。

### M17：产品化、性能与最终验收

#### 目标

把前述能力接入默认编码工作流，完成迁移、文档、性能和最终基准。

#### 实施步骤

1. 清理被新 facade 和 verifier 替代的实验调用路径，保留必要兼容 wrapper 并标记删除条件。
2. 在统一 chat surface 中展示当前阶段：planning、understanding、editing、verifying、repairing、reviewing。
3. 为 stale write、semantic backend、verification 和 sandbox 增加可操作错误说明。
4. 更新用户文档、配置示例、帮助命令和故障排查。
5. 对 10,000 文件 fixture 做索引、增量更新、查询、上下文构建和内存测试。
6. 对 30 个 live coding tasks 各执行 5 次最终基准。
7. 对每个失败分类复核：模型能力、上下文遗漏、工具错误、验证错误、权限阻塞或基础设施错误。
8. 运行全部 unit、integration、e2e、offline eval 和平台隔离测试。
9. 生成不可变验收结果和与 M9 基线的比较报告。

#### 退出条件

满足第 13 节全部项目级验收标准。

## 8. 测试矩阵

| 层级 | 内容 | 是否进入 canonical suite |
|---|---|---|
| Unit | 数据合同、digest、scope、排序、解析、状态机、错误类型、UI 纯投影 | 是 |
| Integration | Agent loop + scoped context + plan gate + file gate + checkpoint + execution + verifier | 是，外部依赖缺失时只允许明确 skip |
| E2E | 临时 Git fixture 中完成计划、编辑、压缩恢复、验证、review | 是，必须确定性 |
| Offline Eval | 五个现有合同及新增非模型 coding contracts | 是 |
| Live Eval | 固定模型执行 30 个真实任务 | 否，单独命令 |
| Spike | 平台隔离、外部服务和语言服务器可行性 | 否，正式实现前运行 |
| Performance | 10,000 文件索引与上下文基准 | 单独命令，最终验收必跑 |

所有测试必须遵守：

- 使用临时目录或 session-owned worktree；
- 不读取用户真实项目数据和凭证；
- 不依赖测试顺序；
- 失败后清理 timer、process、buffer、worktree 和临时目录；
- 异步测试有明确 timeout；
- 进程输出和 fixture 大小有上限；
- 禁止用 sleep 猜测完成，必须等待事件或 sentinel；
- canonical suite 继续使用 `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`。

## 9. 施工提交规则

每个 M 阶段至少一个独立提交。只有该阶段退出条件和相关测试全部满足后才能提交。提交不得混入下一阶段内容。

标题示例：

```text
feat(files): enforce versioned writes
test(files): cover stale write refusal
docs(files): record M10 evidence
```

正文必须使用英文说明：

- implemented contracts；
- tests and commands run；
- measured result；
- explicit remaining work。

如果一个阶段需要多个提交，每个提交仍必须是独立可验证的垂直切片，不允许先提交不可运行骨架再长期等待后续补齐。

## 10. 兼容与迁移

### 10.1 文件工具

- 先对 Agent 工具路径强制 version，普通 Lisp API 保持兼容。
- 所有内置调用迁移完成后，再决定公共 API 是否升级主版本合同。
- 旧 session 没有 read set，恢复后第一次写必须重新读取。

### 10.2 代码索引

- 旧索引可读取时只作为 fallback；缓存 schema 改变时允许丢弃重建。
- 不对缓存做复杂迁移，因为缓存不是事实来源。
- 新 facade 稳定前保留现有公共命令作为 wrapper。

### 10.3 验证

- 未配置项目先进入 report-only：生成计划但不自动执行写作用步骤。
- 确定性只读诊断和用户已经配置的测试命令验证稳定后，才默认开启。
- repair 默认在 M12 验收后开启，且始终受 step budget、approval 和 checkpoint 控制。

### 10.4 隔离后端

- local backend 不删除，但必须明确显示 unrestricted。
- 隔离后端不可用时允许用户显式选择 local；系统不得自动无提示降级。

### 10.5 上下文与工作笔记

- 现有字符串 prompt API 保留为 adapter，并立即包装为带来源的 fragment。
- `memory.md` 和 `chat-memory-item` 继续表示长期记忆；不会自动迁入工作笔记。
- 现有 session scratch 文件保持可读；结构化 note 使用独立 schema，普通文件不被
  猜测为 note。
- 旧 session 没有 work-context state 时按空集合加载，不修改原 session 文件。

### 10.6 TODO 计划

- `chat-task` 继续表示可调度工作生命周期；plan 只描述一个 task 内的步骤和证据。
- 旧 task 没有 plan 时可查看和取消；仅在它再次执行 mutation 时触发 plan-required。
- UI 只从 public plan API 和 events 投影，不把折叠状态写回 runtime 事实。

## 11. 可观测性与审计

新增或规范化以下事件，不改变现有 event 总线：

- `code-intel-query-started/completed/failed`；
- `repo-map-updated`；
- `file-observed`；
- `file-version-refused`；
- `verification-planned/step-started/step-completed/completed`；
- `repair-started/stopped`；
- `context-bundle-built/fragment-selected/fragment-omitted`；
- `work-note-created/updated/archived/deleted/conflicted`；
- `work-plan-created/item-started/item-completed/item-blocked/completed/skipped`；
- `review-started/finding/completed`；
- `workspace-merge-started/completed/conflicted`。

事件 payload 只保存标识、状态、计数、digest、耗时和有界错误摘要。不得复制完整文件、prompt、reasoning、凭证或命令完整环境。

Trace 至少新增：

- semantic query 数、backend 分布、timeout 数；
- context candidate/selected/token 数；
- context scope refusal、dependency cycle 和 truncation 数；
- work note query/hit/conflict 数；
- plan item、blocked、skipped、无计划 mutation refusal 和停滞数；
- stale write refusal 数；
- verification step、失败和 retry 数；
- review finding 按 severity 计数；
- merge conflict 数。

## 12. 风险控制

| 风险 | 控制措施 |
|---|---|
| 为追求评测分数对 fixture 特化 | 任务 revision 固定，保留隐藏变体，评测代码与 Agent prompt 分离 |
| LSP 查询阻塞 Emacs | 只允许异步合同、缓存结果和 timeout；主循环切片测试作为门禁 |
| repo map 占用过多内存 | 增量索引、上限、LRU 和可重建磁盘缓存 |
| digest 增加大文件成本 | 沿用文件大小上限，分块 hash，并复用同一 file identity 缓存 |
| 自动验证进入死循环 | repair limit、step budget、相同失败 fingerprint 停止条件 |
| 自动格式化扩大 diff | format step 受 allowed paths 和 checkpoint 控制，越界立即拒绝 |
| 工作笔记把猜测固化成规则 | authority 固定、source/provenance 可见、note 不得升级 instruction |
| AGENTS 依赖泄漏或循环 | canonical root、scope matching、cycle/depth/count/byte limit |
| TODO 变成提示词负担或形式主义 | 只投影 active slice、简单任务可审计 skip、token 与成功率门禁 |
| UI 进度更新打断输入 | runtime/UI 分离、保留 point/window、批量事件和 1,000 次更新测试 |
| sandbox 能力被高估 | 先 spike，capability 与实际测试绑定，不可用就明确 blocked |
| Review 产生大量低价值意见 | typed finding、证据门槛、severity/precision Eval 和去重 |
| 并行 Agent 互相覆盖 | scheduler 资源冲突、独立 worktree、base revision 和 merge gate |
| live Eval 成本和波动过大 | 开发 3 次、验收 5 次；固定模型快照并分别报告方差 |

## 13. 最终验收标准

以下条件必须全部满足，M17 才能标记 complete。

### 13.0 指标计算

- live Eval 成功率 = successful valid trials / all valid trials。开发基线每 task 3 次，最终验收每 task 5 次；最终比较时必须另外用相同次数重放 baseline 配置，禁止比较 3 次样本和 5 次样本。
- definition accuracy = 定义位置完全命中的查询数 / 有唯一预期定义的查询数。允许位置以 canonical path 和起始行判定。
- references precision = 正确返回引用数 / 全部返回引用数；references recall = 正确返回引用数 / fixture 标注引用总数。空分母语料不得进入该指标。
- Top-5 命中率 = 预期必要文件至少一个出现在前五个非重复候选中的查询数 / 全部相关性查询数。
- Review precision = 被 fixture 或独立确定性证据确认的 finding 数 / 全部正式 findings；Review recall = 被找到的预埋 critical/high 缺陷数 / 预埋 critical/high 缺陷总数。
- 延迟 p95 使用全部有效样本按毫秒升序排列，取 `ceil(0.95 * N)` 的第 N 项；样本数少于 20 时不得报告 p95 为验收证据。
- token 指标只比较 provider 返回了可信 usage 的 valid trials；缺少 usage 的比例必须单独报告，超过 5% 时 token 门槛状态为 blocked。
- 性能测试必须记录机器、操作系统、Emacs 版本、冷/热缓存、fixture digest 和重复次数。最终值取至少 30 次 warm query；环境变化后不得与旧绝对值混用。

### 13.1 正确性

- canonical unit/integration/e2e/offline eval 全部通过，0 known failure。
- 现有五个内置离线 Eval 场景继续通过。
- 30 个 coding task 最终成功率不得低于 M9 基线，且不得低于 80%。
- 同时必须满足：最终成功率达到 90%，或相对 M9 基线提高至少 15 个百分点。
- 越界文件修改数为 0。
- 未验证却报告 passed 的次数为 0。

### 13.2 编辑安全

- 所有陈旧写入、竞争创建、dirty buffer 和多文件中途漂移测试 100% 拒绝。
- 拒绝后目标文件字节、mode、symlink 和目录树保持预期原状。
- checkpoint rollback 的 drift 检查继续通过。

### 13.3 代码理解

- definition accuracy >= 98%。
- references precision >= 95%，recall >= 90%。
- 相关上下文 Top-5 命中率 >= 90%。
- 所有指标按语言和整体分别报告；任一语言的对应指标不得比该指标的整体值低超过 10 个百分点。

### 13.4 验证闭环

- 预埋格式、lint、type、test、build 失败检出率 100%。
- repair loop 全部在配置预算内终止。
- 每个 passed 任务都有 required steps 的 execution evidence。
- 缺少验证能力的任务明确为 not-run 或 blocked。

### 13.5 隔离与资源

- 隔离测试中的项目外读写、symlink escape、默认网络和环境泄漏全部被阻止。
- timeout/cancel/crash 后没有本轮创建的孤儿进程、监听端口或 worktree。
- 10,000 文件 fixture 的主循环单切片 <= 50ms，warm semantic query p95 <= 200ms。
- 最终成功任务的中位输入 token 不高于 M9 同任务基线的 110%；large-repo tasks 的中位输入 token 必须至少降低 15%。

### 13.6 上下文连续性与计划

- AGENTS scope corpus 和依赖图选择准确率 100%，跨 project/directory 泄漏为 0。
- compaction/restart 后 objective、active blocker、decision、next step 和 current plan
  的 identity 与内容等价；关键工作项丢失为 0。
- work note revision 冲突 100% 拒绝，Agent note 升级为 instruction 的次数为 0。
- 非简单编码任务在首次 mutation 前具有活动计划的比例为 100%；非法 plan 状态为 0。
- completed plan item 的 evidence 可解析率 100%，UI 与 durable plan 状态一致率 100%。
- 计划 UI 1,000 次更新不移动输入 point、用户 window-start 或产生残留 timer。
- plan + active work note 的中位 prompt 开销不超过输入 token 的 5%。

### 13.7 Review 与协作

- critical/high 预埋缺陷 recall >= 85%，precision >= 80%。
- Review Agent 写操作次数为 0。
- 并行冲突静默覆盖次数为 0。
- 合并后的变更全部重新通过 required verification。

### 13.8 文档与可运维性

- 所有新增 public command、配置和状态都有用户文档。
- `.agents/` 包含每阶段决策、实施证据、测试命令和未完成项。
- 错误信息可以区分 unavailable、blocked、stale、failed、timeout 和 cancelled。
- 从干净 checkout 按文档可以复现 canonical suite、performance benchmark 和 live Eval。

## 14. 验收报告格式

最终报告必须包含：

1. commit 和配置快照；
2. 环境、Emacs 版本、backend capability；
3. M9 基线与 M17 结果对比；
4. 每个任务类别及语言的成功率；
5. token、延迟、tool error、retry 和 approval 分布；
6. semantic corpus 指标；
7. stale write、安全隔离和进程清理结果；
8. context scope/compaction continuity 和 plan adherence/UI stability；
9. Review precision/recall；
10. canonical suite 完整计数；
11. 失败任务分类和仍然存在的风险。

报告不得只给总分，也不得删除失败样本。任何未达到门槛的项目必须使总状态为 failed 或 blocked，不能用平均分掩盖。

## 15. 开工顺序

严格执行：

```text
M9 baseline
  -> M10 versioned edits
  -> M11 semantic intelligence and repo map
  -> M12 verification and bounded repair
  -> M13 structured work context and scoped rules
  -> M14 durable TODO plans and native UI
  -> M15 execution isolation
  -> M16 review and coding multi-agent
  -> M17 rollout and acceptance
```

M10 可以在 M9 基线建立后与 M11 的后端合同设计并行调查，但共享的 Agent loop、
tool caller 和 context 文件不得并行修改。M12 依赖 M10 和 M11；M14 依赖 M13；
M16 依赖 M12、M14 和 M15。最终默认开启任何能力前，必须先在 live Eval 中证明
不降低成功率。
