# Instructions for AI Agents and IDEs

本文档适用于所有在本仓库内工作的 AI Agent 和 IDE 插件。
开始工作前先读一遍。
结束工作前再对照检查一遍。

Copyright 2026 chat.el contributors.

## First Principles

### Safety First

- 不信任模型返回的工具参数
- 危险工具必须先审批
- 敏感信息只使用 `auth-source`
- 提交到 git 的任何文件都不得包含直接或间接泄露敏感信息的内容
- 敏感信息包括但不限于密码 密钥 token 用户环境 路径 凭证 内网信息和可识别用户身份的数据

### Code First

- 先看代码事实再下结论
- 所有需求 设计 开发都必须先调查可行性
- 只能采用切实可行 可以验证 可以落地的方案
- 不得基于假设或未验证能力做空想设计
- 外部依赖 API 调用 协议交互必须先验证可用性
- 复杂功能和外部系统集成功能必须先做原型验证
- 设计必须服从当前技术栈 时间 资源和维护成本这些现实约束
- 优先修根因而不是表层报错
- 不要继续叠加临时补丁
- 为了正确性可以直接重构

### Async First

- 所有 I/O 都不能阻塞 Emacs 主循环
- 长请求必须可取消
- 定时器和进程结束后必须清理
- 请求期间用户必须能自由移动光标、切窗口、翻看缓冲区任意位置
- 请求路径上禁止 `url-retrieve-synchronously`、`accept-process-output`、`sleep-for`、`sit-for` 和等待进程的 `while` 循环
- 增量渲染只重画变化的区域，不整段重排缓冲区
- 自动跟随输出只在光标本来就在尾部时生效，用户往上翻看后不得被拽回底部

## Absolutely Forbidden

### UI Popup Questions

- 禁止用界面提问控件向用户提问，包括结构化提问工具、多选题弹窗、选项卡、单选列表、确认对话框、表单式问卷
- 这类控件只放得下选项标签，装不下判断需要的背景、证据和推理，用户只能瞎选或者取消
- 提问一律写进对话正文，写法见 `Plan Before Business Code`
- 不得以选项太多、正文太长、这样更清晰、用户可以选 Other 为理由绕开
- 不得先弹窗再补充说明，也不得用弹窗代替正文
- 用户取消不等于同意，也不等于拒绝决策，只说明问题信息不足，必须在正文里重问

### Stage Commits

- 每完成一个可独立验证的阶段，并且该阶段相关测试已经通过后，必须立即直接提交一次
- 不要把多个已经完成且已验证的阶段长时间堆积在工作区里等待一次性提交
- 阶段提交使用 Conventional Commits：`type(scope): concise subject`
- `type` 按主变化选择一个 `feat`、`fix`、`test`、`docs`、`refactor`、`perf` 或 `chore`
- 一个标题只能有一个 type；测试和文档属于同一阶段时写进正文，不得把多个标题拼在一行
- 标题只写本阶段最核心变化，使用英文，保持简短
- 标题后必须追加英文正文，说明本次阶段提交完成了什么、覆盖了哪些验证、还有什么明确未完成项

## Documentation Must Be Updated

每次开发会话结束时必须同步更新知识库和必要的人类文档。

### Required Outputs

1. 在 `.agents/` 中更新当前阶段相关记录
2. 如果发现新的失败模式或修复模式 更新 `docs/troubleshooting-pitfalls.md`
3. 如果项目的人类使用方式、配置方式或公开行为发生变化 更新 `README.md` 或 `docs/`

### Troubleshooting Update Rule

更新 `docs/troubleshooting-pitfalls.md` 时必须遵守现有结构。

- 把新条目放到最接近的主题 section
- 使用固定字段顺序 `Problem` `Cause` `Solution`
- 先合并重复条目 再考虑新增条目
- 不要随意打乱 topic 顺序
- 如果确实需要新增 topic 只新增一级 `##` 主题

### Documentation Directory Structure

`docs/` 只存放面向人类使用者的项目文档。
agent 工作流、阶段记录、决策过程和历史调查材料不再放在 `docs/`，统一进入 `.agents/`。

`docs/` 目录按内容篇幅和深度分层：

| 目录 | 用途 | 内容示例 |
|------|------|----------|
| `tips/` | 短形式的灵感和速记 | 代码片段、快捷技巧、aha moments |
| `articles/` | 中等篇幅专题文章 | 技术深入、最佳实践、实现故事 |
| `books/` | 长篇系统性文档 | 架构指南、设计原则、完整规范 |

选择依据：
- 单条灵感或速记 → `tips/`
- 一个主题的完整探讨 → `articles/`
- 成体系的系统性内容 → `books/`

参考：

- `docs/README.md`
- `docs/troubleshooting-pitfalls.md`
- `.cursor/rules/documentation-maintenance.mdc`

## Agent Knowledge Base

- agent 专用知识库固定放在 `.agents/`
- `.agents/` 虽然是隐藏目录，但属于本项目正式目录结构的一部分，所有 agent 进入项目时必须主动读取，不得因隐藏目录而忽略
- `.agents/` 采用二维知识组织模型：
  - 注意力层级：
    - `00-entry`
    - `10-active`
    - `20-reference`
    - `30-records`
  - 知识类型：
    - `decisions`
    - `knowledge`
    - `lessons`
    - `logs`
    - `compatibility`
    - `progress`
- agent 在开始实现前，必须按以下顺序读取项目上下文：
  - `AGENTS.md`
  - `.agents/README.md`
  - `.agents/00-entry/current.md`
  - `.agents/00-entry/read-order.md`
  - `.agents/10-active/focus.md`
  - `.agents/10-active/risks.md`
  - 根据任务类型选择性读取：
    - 功能实现优先读 `20-reference/decisions/` 与 `20-reference/knowledge/`
    - 兼容性问题优先读 `20-reference/compatibility/`
    - 排障与复盘优先读 `30-records/lessons/` 与 `30-records/logs/`
    - 历史追溯优先读 `30-records/history/`
  - 默认禁止因为“多看一点更保险”而扫描整个 `.agents/`
- 每完成一个阶段并通过该阶段测试后，除了提交代码，还必须同步更新 `.agents/` 中对应记录
- `.agents/` 中的内容必须提交到 git，禁止只保留在本地工作区
- 共享知识层为 `00-entry`、`10-active`、`20-reference`、`30-records`
- 并行 agent 的私有工作区固定放在 `.agents/workspaces/<agent-id>/`
- 并行 agent 不得直接改写共享知识层，必须先写入各自 `workspaces/`，由主 agent 归并
- `.agents/00-entry/` 只存入口索引与最小必读上下文
- `.agents/10-active/` 只存当前阶段高热信息，不得长期堆积
- `.agents/20-reference/` 只存稳定参考知识
- `.agents/30-records/` 只存低频备查材料，包括经验、教训、日志、复盘、历史记录
- `.agents/templates/` 用于存放统一模板，保证后续记录格式稳定
- `.agents/` 中所有正式记录文件都应包含固定元数据字段：
  - `Type`
  - `Attention`
  - `Status`
  - `Scope`
  - `Tags`

## Development Workflow

### Standard Task Entry Flow

每次开发任务开始前都必须按这个顺序执行：

1. 先完整阅读 `AGENTS.md`
2. 阅读 `.agents/README.md`
3. 阅读 `.agents/00-entry/current.md`
4. 阅读 `.agents/00-entry/read-order.md`
5. 阅读 `.agents/10-active/focus.md`
6. 阅读 `.agents/10-active/risks.md`
7. 调查当前代码现状 已有实现 相关测试和必要文档
8. 反思当前目标 约束 风险和已有工作
9. 判断当前方向是否会掉进死胡同
10. 先给方案 再进入业务代码实施

这里的死胡同包括但不限于：

- 工作流陷入死循环
- 在同一个坑里反复修改却没有实质进展
- 补丁摞补丁导致结构越来越差
- 已经偏离目标却继续局部修补
- 明显应该重新审视设计或直接重构却还在硬撑

发现进入这些状态时必须停下来。
先重新调查现状。
再重新审视方案。
必要时直接重构而不是继续来回修补。

### Plan Before Business Code

任何业务代码改动都要先给用户方案。
需要用户决策时用同一套写法提问，方案和提问都写在对话正文里。
方案和提问至少包含：

1. 问题分析：触发它的具体事实，以及不决策会卡住什么
2. 改动范围：这个决策会改变后续哪些动作、哪些范围、哪些验收标准
3. 证据位置：文件路径和具体行号或函数名，必要时贴出关键代码片段
4. 可选方案和取舍：每个选项的成立前提、代价、风险，以及在什么条件下它才是对的
5. 推荐方案和理由：推荐哪个、为什么推荐，以及什么情况下推荐会翻转
6. 已核实与未核实：哪些事实已核实并给出核实方式，哪些还是推测，哪些要外部信息才能确认

只给选项名等于没给信息。
不允许只说代码里是这样的而不给位置。

调查、定位、日志采集、测试编写、纯文档修改可以直接进行。
凡是读代码、读文档、跑命令、查日志能确定的事实一律自己查，不许转手给用户。
只问真正属于用户的决策：价值取向、优先级、风险偏好、业务判断，以及需要权限或外部信息才能回答的事。
信息不足到用户无法判断时，先补齐信息再问，不要把不完整的问题抛出去。
相关的几个问题连同背景一次讲完，不要反复追问同一件事。

### Spike Tests Before Formal Integration

关键功能点要先做探针测试验证。
复杂功能或涉及外部系统的功能必须先验证可行性再进入正式实现。
推荐探针测试语言：

- Shell
- Python
- JavaScript

探针测试文件放在 `tests/spike/`。
命名格式是 `YYYYMMDD-feature.ext`。

探针测试用于验证外部服务、第三方API、基础设施、语言特性或技术方案的可行性。

### Test Driven Fixes

- 修每一个 bug 都要补至少一条测试
- 新增外部自由结构数据解析时要补测试

**测试目录分层结构：**

```
tests/
├── unit/            # 单元测试：针对业务函数、方法、类的逻辑正确性验证
│                   # 无外部依赖，独立可运行
├── integration/     # 集成测试：验证模块间、服务间、组件间协作流程
│                   # 涉及数据库、缓存、模型、内部接口等依赖
├── e2e/             # 端到端测试：模拟真实用户完整流程
│                   # 启动全系统黑盒验证，关注最终可用性功能
└── spike/           # 探针测试：验证外部服务、第三方API、基础设施
                    # 语言特性、技术方案可行性，无业务逻辑
```

- 单元测试使用 `ert`，放在 `tests/unit/`
- 集成测试放在 `tests/integration/`
- 端到端测试放在 `tests/e2e/`
- 探针测试放在 `tests/spike/`
- Spec 文件放在 `specs/`

### Verification

优先使用：

```bash
emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit
```

不要把 `tests/run-tests.sh` 当成唯一真相。

### Reflection During Execution

- 实施过程中要定期检查当前方向是否偏离目标
- 主动识别过度设计 补丁堆积 脱离现状这些陷阱
- 发现方案不可行或验证结果不成立时必须立即回退到调查和方案阶段
- 如果继续局部修补只会让工作陷入死循环 就应当重新审视设计或直接重构

## Emacs Lisp Rules

### Naming

- 公共符号统一使用 `chat-` 前缀
- 函数名使用 `chat-module-function-name`
- 变量名使用 `chat-module-variable-name`
- 常量使用 `chat-MODULE-CONSTANT`

### Libraries

- 使用 `cl-lib`
- 不使用旧的 `cl`
- 默认启用 `lexical-binding: t`

### Data Structures

- 复杂结构优先用 `cl-defstruct`
- 高频查找优先哈希表
- 配置和常量优先 `defconst`
- 运行时状态优先 `defvar`

### Error Handling

- 用 `condition-case` 捕获具体错误
- 报错信息要让用户看得懂
- 包装错误时保留原始错误文本

### Public API Layout

- 公共 API 放前面
- 内部辅助函数放后面
- 避免循环依赖

## System Specific Rules

### Pure Emacs Core

- 核心功能只依赖 Emacs 内置和标准库
- Python 和 Node 只能作为可选工具锻造执行环境
- 兼容 Emacs 27+

### Tooling Safety

- 文件工具必须做路径校验
- shell 工具不能依赖 shell 字符串执行
- AI 生成工具必须先审批
- elisp 工具源码必须是单个顶层 `lambda`

### Structured Protocol Format

- 任何结构化输入输出必须使用 JSON
- function call tool call approval payload patch 请求以及其他机器可读内容必须使用 JSON 格式
- 不得使用 XML YAML 自定义标签或自然语言伪结构替代 JSON
- 如果某个外部协议明确要求非 JSON 格式 必须先在代码和文档中证明该协议真实存在 再按协议执行

### Session and State

- 会话状态必须隔离
- 持久化边界必须清晰
- 不要跨 session 共享可变状态
- 会话必须能报出自己的历史记录文件路径，前端不许自己拼
- 一次运行的每一步都要落成记录，带轮次、步序、类别和时间戳
- 用户输入与它引发的全部 AI 步骤靠轮次号关联，前端据此聚合展示
- 类别至少区分用户输入、推理、工具调用、工具结果、中间文本、最终答案
- 推理内容只用于展示和记录，不回灌给模型

### Event Contract

- 事件处理器必须穷尽发出方的事件类型，并且必须有兜底分支
- 未知事件不得被静默丢弃，至少记日志或落成可见记录
- 新增事件类型时必须同时给出处理分支，并补一条断言每个事件类型都被处理的测试
- 静默丢事件的症状是界面不动而没有任何报错，比崩溃更难查，所以按硬约束对待

### Progress Must Be Visible

- 程序在做什么必须随时可见，不能只有一个"正在处理"
- 状态由事件流派生，不由调用点手工设置，同一串事件回放两次要得到同一串状态
- 回显区会被任何 `(message ...)` 覆盖，不能作为持续状态的唯一载体
- 等待首字节必须是独立且立即可见的状态，不许等停顿阈值才提示
- 长耗时阶段要能区分等待、接收、执行工具、等审批和当前轮次

### Input Normalization

规范化的范围由归属决定：只归一化 chat.el 自己解释的字符串。

- 判断依据不是「这段字符串长得像语法还是像数据」，而是「谁有解释权」。
  chat.el 解释它，就归一化；它要交给别处执行或阅读，就一个字节都不动。
- `！ls` 里的 `！` 是 chat.el 的命令（它就是 `/cmd` 的简写），要归一化；
  `ls` 是 `/cmd` 的参数、是交给执行器的内容，不是 chat.el 的命令，
  不许改写。执行器恰好是 shell 属于偶然，换成别的执行器规则不变。
- 参数是否归一化按位置逐个判断：`/auto` `/drop` `/model` `/help` 的参数
  会被拿去和固定名字比对，不出程序，要归一化；`/cmd` `/send` `/quick`
  `/queue` 的参数是要发出去的内容，不许动。
- 解析器负责语法位置，handler 负责自己解释的参数。解析器不能替 handler
  决定，因为同一个位置在下一个命令里就是 prompt。
- 全角折叠按 Unicode 区块做算术映射，不许写成字符对照表。规则是区间时
  用列表实现，就会变成「有人报一个补一个」，永远补不完。
- 扩大任何归一化范围时，必须同时补反向测试，断言数据位置**没有**被改写。
  否则下一次扩大会静默改写用户要发送的内容，而且不会有测试失败。

## Documentation Style

- 用自然行文
- 一句话只说一件事
- 避免层层嵌套
- 字面可读 读出来也通顺

示例：

- 不佳：`chat-files.el（文件操作模块）提供了read/grep/modify等功能`
- 良好：`chat-files.el provides file operations including read search and modify`

## Comment Rules

- 只在不明显但关键的逻辑前写注释
- 注释描述代码约束和业务意图
- 不要写叙述性注释
- 不要在注释里记录本次修改背景

## Commit Message Output

如果本次不是一个完成并通过验证的阶段，改动结束后提供一行英文 commit message 建议。
如果本次是一个完成并通过验证的阶段，必须直接执行 git 提交，并使用阶段提交格式。

允许的前缀：

- `feat`
- `fix`
- `refactor`
- `docs`
- `test`
- `chore`

## Scope

本文件适用于整个 `chat.el` 仓库内的代码、测试、文档、排障和重构工作。
如果只是纯答疑，也至少要在 `.agents/30-records/logs/` 中留下简短记录。
