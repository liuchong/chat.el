# Code Mode 使用指南

Code Mode 是统一 chat buffer 上的一组编程能力，不是第二套对话界面。
当前稳定主路径覆盖结构化项目上下文、版本化读写、语义检索与 repo map、
预览编辑、项目验证与有界修复、TODO 计划、隔离执行、只读审查和受控子任务合并。
历史索引命令只作为兼容入口保留；新调用应使用语义 facade 和 repo map。

## 目录

1. [快速开始](#快速开始)
2. [基础工作流程](#基础工作流程)
3. [命令参考](#命令参考)
4. [配置指南](#配置指南)
5. [使用示例](#使用示例)
6. [故障排除](#故障排除)
7. [高级用法](#高级用法)

## 快速开始

### 安装与加载

```elisp
;; 添加到 Emacs 配置
(add-to-list 'load-path "~/path/to/chat.el")
(require 'chat)

;; 配置 API Key（选择一种方式）
;; 方式 1: 直接设置
(setq chat-llm-kimi-code-api-key "your-api-key")

;; 方式 2: 使用 auth-source（推荐）
;; 在 ~/.authinfo 添加：
;; machine kimi-code-api user api-key password YOUR_KEY
```

### 启动 Code Mode

```text
M-x chat-code-start              ; 从当前项目启动
M-x chat-code-for-file           ; 针对特定文件启动
M-x chat-code-for-selection      ; 使用当前选区启动
M-x chat-code-from-chat          ; 从普通聊天切换
```

### 第一次使用

```text
1. 打开你的项目中的任意文件
2. M-x chat-code-start
3. 在底部输入区域输入需求，例如：
   "帮我把这个函数改成异步的"
4. 按 RET 发送
5. AI 会生成代码并显示 [Apply: C-c C-a] [Preview: C-c C-v] [Reject: C-c C-k]
6. 按 C-c C-a 接受修改，或 C-c C-v 查看 diff 预览
```

## 基础工作流程

### 场景 1: 添加新功能

```text
1. 打开相关文件
2. M-x chat-code-start
3. 输入: "添加用户登录功能，包括验证和错误处理"
4. AI 分析后可能：
   - 询问具体细节
   - 生成多个文件的修改
   - 显示每个修改的预览
5. 审查每个修改，选择接受或拒绝
6. 运行测试验证
```

### 场景 2: 理解代码

```text
1. 将光标放在函数上
2. M-x chat-edit-explain
3. 或选中代码后执行 M-x chat-edit-explain
4. AI 解释代码逻辑、用途、潜在问题
```

### 场景 3: 修复 Bug

```text
1. 定位到问题代码
2. M-x chat-edit-fix
3. 或：在 *chat-code* 中描述问题
4. AI 分析并生成修复
5. 预览修改（C-c C-v）
6. 应用修复（C-c C-a）
7. 运行测试确认修复
```

### 场景 4: 当前推荐开发循环

```text
1. M-x chat-code-start
2. 实现功能（与 AI 对话迭代）
3. M-x chat-edit-tests（生成测试）
4. 运行项目测试验证修改
5. 必要时查看 preview buffer
6. 人工审查后再决定后续 git 操作
```

### 场景 5: 写长文档

```text
1. M-x chat-code-start
2. 先让 AI 生成文档提纲和第一节
3. 新文档先按 section 写，不要一次要求完整长文
4. 修改现有文档时优先选中一个标题块后执行 quote-region 或 ask-region
5. AI 产出修改后先看 preview
6. 用 git diff 或 Magit 审查后再继续下一节
```

## 命令参考

### 启动命令

| 命令 | 快捷键 | 描述 |
|------|--------|------|
| `chat-code-start` | - | 从当前项目启动 Code Mode |
| `chat-code-for-file` | - | 针对特定文件启动 |
| `chat-code-for-selection` | - | 使用当前选区作为上下文 |
| `chat-code-from-chat` | - | 给当前会话加上代码能力，不重开对话 |

引用和提问命令不属于代码能力，任何会话都能用：`chat-quote-region`、
`chat-quote-defun`、`chat-quote-near-point`、`chat-quote-current-file`
把内容填进输入区，对应的 `chat-ask-*` 直接发送。

### Chat Buffer 命令

代码能力是会话属性，没有独立的 code buffer，也没有第二张键位表。
下面这些键在任何 chat buffer 里都是同一套；标注“需代码能力”的几个在
普通会话里按下去会明确告诉你该会话没有代码能力。

| 快捷键 | 命令 | 描述 |
|--------|------|------|
| `RET` | `chat-ui-send-message` | 发送消息 |
| `S-RET` | `chat-ui-insert-newline` | 在输入区插入换行而不直接发送 |
| `C-g` | `chat-cancel-request` | 取消当前请求 |
| `C-c C-n` | `chat-new-session` | 新建会话 |
| `C-c C-l` | `chat-list-sessions` | 列出会话 |
| `C-c C-m` | `chat-set-model` | 切换本会话的模型 |
| `C-c C-e` | `chat-edit-last-user-message` | 编辑并重发最后一条用户消息 |
| `C-c C-g` | `chat-regenerate-last-response` | 重新生成最后一条 AI 回复 |
| `C-c C-s` | `chat-show-current-request-status` | 查看当前请求的详细诊断 |
| `C-c C-p` | `chat-toggle-request-panel` | 切换请求过程面板 |
| `C-c C-t` | `chat-toggle-auto-approve-session` | 切换本会话的自动批准 |
| `C-c C-q` | `chat-quote-region` | 把当前选区引用到输入区 |
| `C-c C-SPC` | `chat-ask-region` | 直接提问当前选区 |
| `C-c C-d` | `chat-ui-toggle-all-folds` | 一次展开或折叠全部细节 |
| `C-c C-h` | `chat-show-help` | 打开帮助 |
| `C-c C-a` | `chat-code-accept-last-edit` | 接受最后一个修改（需代码能力） |
| `C-c C-k` | `chat-code-reject-last-edit` | 拒绝最后一个修改（需代码能力） |
| `C-c C-v` | `chat-code-view-preview` | 查看预览（需代码能力） |
| `C-c C-f` | `chat-code-focus-file` | 更改焦点文件（需代码能力） |
| `C-c C-r` | `chat-code-refresh-context` | 重建项目上下文（需代码能力） |

`C-c C-a` 曾在两张键位表里各有含义：一边接受修改，一边自动批准。
合表时自动批准让到 `C-c C-t`。

### 一次运行里保留下来的东西

一次运行不等于一个答案：它会推理、调工具、读结果、再推理，最后才回答。
这些全部保留在会话记录里，界面直接照记录画，所以中间步骤不会被后一步覆盖，
重开会话看到的和当时看到的一样。

| 内容 | 默认呈现 |
|------|----------|
| 用户问题 | 正常文本 |
| 推理（thinking） | 折叠在一行摘要后，暗色 |
| 工具调用与结果 | 折叠在一行摘要后，调用和结果算同一组 |
| 中间过程文字 | 直接显示，斜体——要读，但不要当成答案 |
| 最终答案 | 正常文本，不折叠 |

摘要行上按 `RET` 或点一下展开该组，再按一次收起。`C-c C-d` 一次展开或
折叠全部。折叠状态按组记住，后续同类内容到达时该组保持你选的状态。

### 运行阶段与可操作错误

顶部状态只投影当前运行事实，不另存一份任务状态：

| 阶段 | 含义 |
|------|------|
| `planning` | 创建或恢复有证据要求的 TODO 计划 |
| `understanding` | 读取规则、文件和语义上下文 |
| `editing` | 生成、预览或应用受版本保护的修改 |
| `verifying` | 执行项目要求的 format、lint、type、test 或 build |
| `repairing` | 在预算内根据验证失败修复并重验 |
| `reviewing` | 在独立只读上下文中复核 diff 和证据 |

流式输出导致状态更新时，输入区内的 point 和可见窗口的 `window-start`
保持不变。计划仍显示在输入区上方的原生进度区域，不会在顶部重复一份。

错误分为 `unavailable`、`blocked`、`stale`、`failed`、`timeout` 和
`cancelled`。错误正文后的 `Next:` 是可执行恢复动作，例如重新读取漂移文件、
打开目标文件建立语义上下文、补齐验证能力、选择可用隔离 backend，或确认权限
后重试。不要通过重复发送同一句话绕过 stale 或 blocked 状态。

### Repo Map 与最终验收

完整刷新用于发现未知外部变化；编辑器已知刚写入的路径通过
`chat-repo-map-update-paths-async` 只更新受影响关系。兼容索引命令仍可用，
但新扩展不应直接依赖其内部 hash table 或后台 timer。

可复现性能命令：

```text
/Users/liu/projects/.agent-tools/capped.sh 1500 emacs -Q -batch -l tests/performance/run-repo-map-benchmark.el
```

在 Emacs 中，`M-x chat-coding-acceptance-run-performance` 会把性能门槛写成
不可变 Eval。最终 live 验收使用 `M-x chat-coding-eval-run-live`，固定 provider、
具体 model、五次重复、campaign id 和角色。M9 checkout 使用 `baseline`，M19
checkout 使用 `current`；两边必须使用同一 manifest、模型和 capability snapshot。
运行前 tracked worktree 必须干净，避免无法复现的本地修改冒充固定 revision。
历史 M9 checkout 会保留当时的 2,000 文件 Eval 上限；加载当前 campaign harness
后必须显式把 `chat-coding-eval-max-fixture-files` 设为 12,000，才能接受当前固定
10,000-indexed-file task。只生成 `campaign.json` 是兼容性预检，不算 live trial。

仓库提供可复现的 batch runner。先用无网络预检确认 campaign 身份、任务数、
重复次数、manifest digest 和两个 checkout revision：

```text
CHAT_CAMPAIGN_PREFLIGHT=1 \
CHAT_CAMPAIGN_ID=<unique-id> \
CHAT_CAMPAIGN_ROLE=current \
CHAT_CAMPAIGN_PROVIDER=<provider> \
CHAT_CAMPAIGN_MODEL=<concrete-model> \
CHAT_IMPLEMENTATION_ROOT=<clean-checkout> \
CHAT_IMPLEMENTATION_REVISION=<implementation-head> \
CHAT_HARNESS_REVISION=<current-harness-head> \
  emacs -Q -batch -l tests/live/run-coding-campaign.el
```

真实运行移除 `CHAT_CAMPAIGN_PREFLIGHT`，并增加
`CHAT_CAMPAIGN_SETUP_FILE=<trusted-local-file>`。该本地文件只负责载入凭据，不得
提交。runner 会拒绝 revision 不匹配或不干净的 implementation/harness checkout，
并在创建 campaign 目录前向指定 provider/model 发出一个 30 秒、64 token 的就绪
请求。历史 baseline 应使用独立 `CHAT_CAMPAIGN_RUNTIME_HOME`，避免当前用户状态
污染旧实现。

每次运行只写入 `~/.chat/evaluations/coding-campaigns/<campaign-id>/`。目录中的
`campaign.json` 在开始前固定模型及其 capability snapshot、profile、transport、
approval mode、manifest digest、实现 revision、任务数和预期结果数；每条 trial
保存相同的 configuration digest 和唯一 repetition/task 身份；全部结束后才生成
`completion.json`。进程中断或主动取消后，用
`M-x chat-coding-eval-resume-live` 校验并只补齐缺失 trial。恢复不会接受不同
manifest、revision、运行配置、重复身份或并发执行，也不能向已有
`completion.json` 的 campaign 追加结果。模型请求在未收到任何 payload 的 DNS、TLS、
连接和超时故障上使用可取消的有界退避。重试耗尽，或 provider 返回 429、
502/503/504、用量上限、服务不可用或容量不足时，live campaign 会把该次结果移入
`attempts/` 审计目录、释放运行锁并暂停；它不会占用正式 repetition/task 身份。
这是 campaign 级可用性边界，不会扩大 Agent 对单次模型请求的重试范围。provider
恢复后对同一目录执行 `M-x chat-coding-eval-resume-live`，即可重试该缺失身份。
分别得到 150 条 M9 与 150 条 M19 结果后运行
`M-x chat-coding-acceptance-run-final`。验收会拒绝混合 campaign、相同实现
revision、不同 manifest、非 30-by-5 唯一 trial 矩阵、缺失可信 token usage 或
不真实的 large-repo 样本，结果不会被误判为通过。最终验收还必须读取同一 clean
implementation revision 上生成的完整 runtime、quality 与 canonical JSON 记录。聚合器会复算
runtime 的九个 gate，检查 17 次 Goal/Plan 定向检查和 20 个 Goal 投影样本；同时从
quality 原始语义查询、48 个固定场景、20 个 plan/work-note prompt 样本和 Review
finding sets 重算 20 个质量 gate。手工填写汇总字段、遗漏语言或把 skip 当 pass 都会
得到 blocked。canonical 来源门还会读取仓库中精确的 `ert-deftest` 清单，逐项核对
同一次全量运行的结果；缺项、改名、expected failure、skip、abort、dirty 或 revision
不符同样会得到 blocked。

标准生产命令为：

```sh
CHAT_RELIABILITY_OUTPUT=/absolute/path/runtime-reliability.json \
  /Users/liu/projects/.agent-tools/capped.sh 2048 \
  emacs -Q -batch -l tests/performance/run-runtime-reliability.el

CHAT_QUALITY_RELIABILITY_OUTPUT=/absolute/path/quality-reliability.json \
  /Users/liu/projects/.agent-tools/capped.sh 4096 \
  emacs -Q -batch -l tests/performance/run-quality-reliability.el

CHAT_CANONICAL_OUTPUT=/absolute/path/canonical.json \
  /Users/liu/projects/.agent-tools/capped.sh 4096 \
  emacs -Q -batch -l tests/run-tests.el
```

调用 `chat-coding-acceptance-run-final` 时，runtime 完整顶层对象作为第三个
`metadata` 参数，quality 完整顶层对象作为第四个 `quality-metadata` 参数，canonical
完整顶层对象作为第五个 `canonical-metadata` 参数传入。

固定 manifest 保持 30 个任务的语言和类别平衡，其中 `python-locate` 是
`large-repo` task。版本化生成描述符在隔离 workspace 内物化 10,000 个可索引
Python 源文件；结果保存实际 indexed-file count 和生成器 digest。验收器同时检查
这两个证据，不能只添加 tag 冒充大型仓库。

当文件写工具触发审批时，原生审批提示除了单次、session、tool 级放行外，还会在可判定目录范围时提供 directory 级放行。
这适合文档目录、测试目录或你愿意交给 AI 连续修改并用 `git diff` 审查的子树。
request panel 现在也会把 directory 级审批范围直接显示出来，方便确认放行边界。
对于 streaming 响应，request panel 现在还会显示 live state、last chunk 和 recent activity，方便判断模型是否还在持续工作。
主对话区里的当前 assistant 槽位也会显示一条临时的 `[Live] ...` 叙事行，用真实的 waiting、streaming、tool-loop 和 approval 状态解释后台正在发生什么。
当 AI 用单文件工具读过或改过某个文件后，具备代码能力的会话会把它自动当成后续 vague follow-up 的默认 focus，这样像“再优化一轮”这类短指令不会轻易丢目标；普通会话不会因此获得 focus。

### 阅读代码时直接提问

推荐链路：

```text
1. 在源码 buffer 中选择最贴近当前阅读状态的入口
2. 选中代码时执行 `chat-quote-region` 或 `chat-ask-region`
3. 光标在函数内时执行 `chat-quote-defun` 或 `chat-ask-defun`
4. 正在看某行附近逻辑时执行 `chat-quote-near-point` 或 `chat-ask-near-point`
5. 当前文件整体不大时执行 `chat-quote-current-file` 或 `chat-ask-current-file`
6. 在 chat buffer 中继续补充问题，或直接让 ask 命令立即发送
7. AI 如需切换到其他文件，可调用 `open_file` 在 Emacs 中直接打开相关文件
```

### 写长文档时的建议

推荐做法：

```text
1. 先列出章节结构
2. 每次只让 AI 处理一个标题或一个 section
3. 新文件用 files_write，已有文档的小改动优先 apply_patch 或 files_replace
4. 如果 quote-current-file 因文件太大而拒绝，就退回到 region 或 near-point
5. 始终把 preview 和 git diff 当最终审查面
6. 如果上一轮已经 review 或修改过某个单文件，下一轮可以直接说“继续改”或“优化一轮”，代码会话会优先沿用那个 focus
```

如果你正在持续编辑同一个文档目录，审批提示里的 directory 级放行通常比 tool 级放行更稳妥。
它只对白名单目录内的文件写工具生效，不会放大到 shell 或其他无目录语义的工具。

### 输入区路径补全

在 chat buffer 底部输入区里：

```text
1. 输入绝对路径，例如 /tmp/demo.md
2. 或输入相对项目根目录的路径，例如 docs/guide.md
3. 当当前 token 看起来像路径时，会自动触发文件补全
4. 继续输入以缩小候选，或用你的 completion 前端直接选择
5. 需要多行提示词时，用 S-RET 插入换行，不会直接发送
```

### Streaming 可见性

如果模型正在长时间生成内容：

```text
1. 用 C-c C-p 打开 request panel
2. 看 Live、Chunks、Last chunk、Last event
3. 主对话区当前 assistant 槽位会显示 `[Live] ...`，包括等待首个 chunk、持续 streaming、tool follow-up、pending approval
4. 如果你仍停留在响应尾部附近，code-mode 会自动跟随最新输出
5. 如果你手动滚走，auto-follow 不会继续抢你的视图
5. 如果长时间没有新 chunk，再结合 stall 提示判断是否真的卡住
```

### 内联编辑命令（在代码缓冲区）

| 命令 | 推荐绑定 | 描述 |
|------|----------|------|
| `chat-edit-explain` | `C-c e e` | 解释代码 |
| `chat-edit-refactor` | `C-c e r` | 重构代码（需输入指令） |
| `chat-edit-fix` | `C-c e f` | 修复代码问题 |
| `chat-edit-docs` | `C-c e d` | 生成文档 |
| `chat-edit-tests` | `C-c e t` | 生成单元测试 |
| `chat-edit-complete` | `C-c e c` | 代码补全 |

### 实验性高级命令

以下命令已经存在，但当前仍应按实验能力对待，使用前建议先阅读实现并在小范围验证：

### 多文件重构命令

| 命令 | 描述 |
|------|------|
| `chat-code-rename-symbol` | 跨文件重命名符号 |
| `chat-code-extract-to-file` | 提取代码到新文件 |
| `chat-code-move-function` | 移动函数到其他文件 |

### 测试命令

| 命令 | 描述 |
|------|------|
| `chat-code-run-tests` | 运行当前文件的测试 |
| `chat-code-run-test-at-point` | 运行光标处的测试 |
| `chat-code-test-generate` | 为函数生成测试 |
| `chat-code-test-coverage-current` | 显示测试覆盖率 |

### Git 命令

| 命令 | 描述 |
|------|------|
| `chat-code-git-diff` | 显示 git diff |
| `chat-code-git-commit-suggest` | 获取 AI 建议的提交信息 |
| `chat-code-git-review` | 在独立只读上下文中审查代码变更 |
| `chat-code-git-pre-commit` | 运行提交前检查 |

`chat-code-git-review` 不继承编辑 Agent 的推理记录。它只接收目标、base revision、
有界 diff、相关 repo map 和验证证据，并把输出解析为带路径、行号、级别和证据的
finding。结果显示在 `*chat-code-review*` 中，按 `RET` 跳转到对应源码行。

可调配置：

```elisp
;; 送入审查模型的 diff 和证据上限。
(setq chat-code-review-diff-limit 120000)
(setq chat-code-review-evidence-limit 24000)

;; critical/high finding 默认由第二个只读 Agent 复核。
(setq chat-code-review-verify-high-severity t)
```

代码型子 Agent 使用 `chat-code-collaboration-declare` 声明目标、允许路径、资源、
profile/model、预算和完成证据，再由 `chat-code-collaboration-start` 调度。写路径重叠
的 child 不会并行；不重叠的 child 使用各自的 session-owned worktree。只有通过
base、路径所有权、父工作区漂移和 patch 检查的结果才可由
`chat-code-collaboration-merge` 合并，合并后会重新运行项目 required verification。

### 代码智能命令

| 命令 | 描述 |
|------|------|
| `chat-code-index-project` | 索引项目符号 |
| `chat-code-find-symbol` | 查找符号定义 |
| `chat-code-find-references` | 查找符号引用 |
| `chat-code-incremental-index` | 增量更新索引 |
| `chat-code-start-background-index` | 启动后台索引 |

### 预览 Buffer 命令

在 `*chat-preview*` buffer 中：

| 快捷键 | 描述 |
|--------|------|
| `a` | 接受修改 |
| `r` | 拒绝修改 |
| `q` | 关闭预览 |
| `n` | 下一个修改 |
| `p` | 上一个修改 |

## 配置指南

### 基础配置

```elisp
;; 启用 code mode
(setq chat-code-enabled t)

;; 默认模型
(setq chat-default-model 'kimi-code)

;; 默认上下文策略
;; 'minimal - 当前文件（~2k tokens）
;; 'focused - 当前+相关文件（~4k tokens）
;; 'balanced - +符号+导入（~8k tokens，默认）
;; 'comprehensive - 完整项目（~16k tokens）
(setq chat-code-default-strategy 'balanced)

;; 自动应用小修改（行数差异小于此值）
(setq chat-code-auto-apply-threshold 10)

;; 使用流式响应
(setq chat-code-use-streaming t)
```

### 快捷键配置

```elisp
;; 全局快捷键
(global-set-key (kbd "C-c c c") 'chat-code-start)
(global-set-key (kbd "C-c c f") 'chat-code-for-file)
(global-set-key (kbd "C-c c s") 'chat-code-for-selection)

;; 编程模式专用快捷键
(add-hook 'prog-mode-hook
          (lambda ()
            (local-set-key (kbd "C-c e e") 'chat-edit-explain)
            (local-set-key (kbd "C-c e r") 'chat-edit-refactor)
            (local-set-key (kbd "C-c e f") 'chat-edit-fix)
            (local-set-key (kbd "C-c e t") 'chat-edit-tests)
            (local-set-key (kbd "C-c e d") 'chat-edit-docs)
            (local-set-key (kbd "C-c e c") 'chat-edit-complete)))
```

### 高级配置

```elisp
;; 文件类型映射（添加新语言）
(add-to-list 'chat-code-filetype-map '("\\.vue$" . vue))
(add-to-list 'chat-code-filetype-map '("\\.php$" . php))

;; 自定义系统提示词
(setq chat-code-system-prompt
      "You are an expert programmer specializing in clean, maintainable code.")

;; 性能优化配置
(setq chat-code-perf-cache-max-size (* 100 1024 1024))  ; 100MB
(setq chat-code-perf-cache-max-age (* 7 24 60 60))      ; 7天
```

### LSP 集成配置

如果安装了 lsp-mode 或 eglot，Code Mode 会自动检测并使用：

```elisp
;; 确保 LSP 优先加载
(with-eval-after-load 'lsp-mode
  (require 'chat-code-lsp))

(with-eval-after-load 'eglot
  (require 'chat-code-lsp))
```

## 使用示例

### 示例 1: 函数重构

**初始代码：**
```python
def process_data(data):
    result = []
    for item in data:
        if item > 0:
            result.append(item * 2)
    return result
```

**操作：**
```text
1. 光标放在函数内
2. M-x chat-edit-refactor
3. 输入："使用列表推导式简化"
4. AI 生成：
   def process_data(data):
       return [item * 2 for item in data if item > 0]
5. C-c C-a 接受
```

### 示例 2: 生成单元测试

**目标函数：**
```python
def divide(a, b):
    """Divide two numbers."""
    return a / b
```

**操作：**
```text
1. 光标在函数上
2. M-x chat-edit-tests
3. AI 生成 pytest 测试：
   
   def test_divide_normal():
       assert divide(10, 2) == 5
       assert divide(7, 2) == 3.5
   
   def test_divide_negative():
       assert divide(-10, 2) == -5
   
   def test_divide_by_zero():
       with pytest.raises(ZeroDivisionError):
           divide(10, 0)

4. 选择保存位置或复制到测试文件
```

### 示例 3: 跨文件重命名（实验性）

**操作：**
```text
1. 光标在要重命名的函数上
2. M-x chat-code-rename-symbol
3. Old name: old_function（自动检测）
4. New name: new_function
5. Scope: project
6. 显示预览：将在 5 个文件中修改 12 处
7. a - 应用所有修改
```

### 示例 4: 提取代码到新文件（实验性）

**操作：**
```text
1. 选中要提取的代码
2. M-x chat-code-extract-to-file
3. Target file: src/utils/helpers.py
4. AI 创建文件并更新原文件的导入
5. 预览两个文件的修改
6. 接受修改
```

### 示例 5: Git 辅助（实验性）

**操作：**
```text
1. 修改代码后
2. M-x chat-code-git-review
   AI 分析：
   - 代码质量：良好
   - 潜在问题：缺少错误处理
   - 建议：在文件操作处添加 try-except

3. 根据建议修改
4. M-x chat-code-git-commit-suggest
   AI 返回建议的提交信息文本
5. 人工决定是否采用该信息并自行处理 git 提交
```

### 示例 6: 测试驱动修复（实验性）

**操作：**
```text
1. M-x chat-code-run-tests
   显示：2 个测试失败
   
2. 在失败测试上按 'f'
   AI 分析失败原因
   
3. AI 生成修复代码
   
4. 审查修复，应用
   
5. M-x chat-code-run-tests
   显示：所有测试通过
```

### 示例 7: 复杂功能开发

**操作：**
```text
1. M-x chat-code-start

2. > 设计一个缓存系统，支持：
   > - TTL 过期
   > - LRU 淘汰
   > - 线程安全

3. AI 询问：使用 Redis 还是内存？
   > 内存，Python 实现

4. AI 生成代码，分多个文件：
   - cache.py（核心实现）
   - cache_test.py（测试）

5. 审查每个文件的修改

6. 运行项目测试
7. 需要时请求 AI 给出提交信息建议
```

## 故障排除

### 问题：AI 响应很慢

**原因：** 上下文太大

**解决：**
```elisp
;; 使用更小的策略
(setq chat-code-default-strategy 'focused)

```

### 问题：生成的代码不准确

**原因：** 上下文不够或提示不明确

**解决：**
1. 切换到 comprehensive 策略
2. 使用更精确的选区
3. 在提示中包含更多细节
4. 手动添加相关文件到上下文

### 问题：索引太慢

**原因：** 项目太大

**解决：**
```text
优先只在必要时手动执行索引相关命令
大型项目请先在小仓库验证索引行为
```

### 问题：修改应用失败

**原因：** 文件在外部被修改

**解决：**
1. 刷新文件：`M-x revert-buffer`
2. 重新尝试应用
3. 使用预览模式手动应用

### 问题：LSP 信息未显示

**原因：** LSP 未启用或不支持

**解决：**
```text
;; 确保 LSP 已启动
M-x lsp 或 M-x eglot

;; 检查支持的语言
;; Python, JavaScript, TypeScript, Go, Rust 等
```

### 问题：流式响应卡顿

**原因：** 网络或 Emacs 性能

**解决：**
```elisp
;; 禁用流式响应
(setq chat-code-use-streaming nil)
```

## 高级用法

### 自定义上下文构建

```elisp
(defun my-custom-context-builder (code-session)
  "自定义上下文构建函数。"
  (let ((context (chat-context-code-build code-session)))
    ;; 添加自定义信息
    (chat-context-code-add-source
     context
     "Custom Rules"
     "Always use type hints in Python.")
    context))

;; 使用自定义构建器
(advice-add 'chat-context-code-build :override #'my-custom-context-builder)
```

统一 chat surface 的主路径仍然以交互式缓冲工作流为中心。批处理或 CI 应调用
明确的 Eval、verification 或 performance 入口，不应模拟按键驱动 UI。

### 与 Projectile 集成

```elisp
(with-eval-after-load 'projectile
  (defun chat-code-for-projectile-project ()
    "Start code mode for projectile project."
    (interactive)
    (chat-code-start (projectile-project-root))))
  
  (define-key projectile-command-map (kbd "a c") 'chat-code-for-projectile-project))
```

### 与 Magit 集成

```elisp
(with-eval-after-load 'magit
  (defun chat-code-magit-review-commit ()
    "Review current commit with AI."
    (interactive)
    (let ((diff (magit-git-string "show" "--no-patch" "--format=" "HEAD")))
      (chat-code-start)
      (chat-code--send-to-llm (format "Review this commit:\n%s" diff))))
  
  (transient-append-suffix 'magit-commit "c"
    '("r" "Review with AI" chat-code-magit-review-commit)))
```

## 最佳实践

1. **从小处开始** - 先让 AI 处理小任务，建立信任
2. **始终审查** - 即使是小修改也要快速浏览
3. **使用版本控制** - 在干净的工作区使用 Code Mode
4. **保存会话** - 有价值的对话保存为会话以便后续参考
5. **增量索引** - 大项目使用增量索引保持性能
6. **提供上下文** - 清晰的提示词得到更好的结果
7. **结合 LSP** - 启用 LSP 获得更准确的上下文

## 相关文档

- [快速参考卡](code-mode-cheatsheet.md) - 一页速查
- [主设计文档](../specs/002-code-mode.md) - 架构设计
- [实现文档](../specs/002-code-mode-implementation.md) - 实现细节

---

*Code Mode Guide - Productized Coding Workflow*
