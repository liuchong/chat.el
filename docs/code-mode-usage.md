# Code Mode 使用指南

Code Mode 是 chat.el 的 AI 编程工作模式。
当前稳定主路径是单 buffer 对话、基础上下文拼装、基础 edit 接受/拒绝，以及从代码缓冲发起 explain、refactor、fix、docs、tests、complete 请求。
多文件重构、git 辅助、索引性能优化等高级模块目前仍在修整中，不应默认视为稳定能力。

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

## 命令参考

### 启动命令

| 命令 | 快捷键 | 描述 |
|------|--------|------|
| `chat-code-start` | - | 从当前项目启动 Code Mode |
| `chat-code-for-file` | - | 针对特定文件启动 |
| `chat-code-for-selection` | - | 使用当前选区作为上下文 |
| `chat-code-from-chat` | - | 从普通聊天会话切换 |
| `chat-code-quote-region` | - | 把当前选区引用到 code-mode 输入区 |
| `chat-code-quote-defun` | - | 把当前 defun 引用到 code-mode 输入区 |
| `chat-code-quote-near-point` | - | 把光标附近上下文引用到 code-mode 输入区 |
| `chat-code-quote-current-file` | - | 把当前文件引用到 code-mode 输入区 |
| `chat-code-ask-region` | - | 直接对当前选区提问 |
| `chat-code-ask-defun` | - | 直接对当前 defun 提问 |
| `chat-code-ask-near-point` | - | 直接对光标附近上下文提问 |
| `chat-code-ask-current-file` | - | 直接对当前文件提问 |

### Code Mode Buffer 命令

在 `*chat:code:<session>*` buffer 中：

| 快捷键 | 命令 | 描述 |
|--------|------|------|
| `RET` | `chat-code-send-message` | 发送消息 |
| `C-c C-a` | `chat-code-accept-last-edit` | 接受最后一个修改 |
| `C-c C-k` | `chat-code-reject-last-edit` | 拒绝最后一个修改 |
| `C-c C-v` | `chat-code-view-preview` | 查看预览（切换到 *chat-preview*） |
| `C-c C-f` | `chat-code-focus-file` | 更改焦点文件 |
| `C-c C-r` | `chat-code-refresh-context` | 刷新上下文 |
| `C-c C-q` | `chat-code-quote-region` | 把当前选区引用到输入区 |
| `C-c C-SPC` | `chat-code-ask-region` | 直接提问当前选区 |
| `C-c C-s` | `chat-code-show-current-request-status` | 查看当前请求的详细诊断 |
| `C-c C-p` | `chat-code-toggle-request-panel` | 切换请求过程面板 |
| `C-c C-e` | `chat-code-edit-last-user-message` | 编辑并重发最后一条用户消息 |
| `C-c C-g` | `chat-code-regenerate-last-response` | 重新生成最后一条 AI 回复 |
| `C-g` | `chat-code-cancel` | 取消当前操作 |

### 阅读代码时直接提问

推荐链路：

```text
1. 在源码 buffer 中选择最贴近当前阅读状态的入口
2. 选中代码时执行 `chat-code-quote-region` 或 `chat-code-ask-region`
3. 光标在函数内时执行 `chat-code-quote-defun` 或 `chat-code-ask-defun`
4. 正在看某行附近逻辑时执行 `chat-code-quote-near-point` 或 `chat-code-ask-near-point`
5. 当前文件整体不大时执行 `chat-code-quote-current-file` 或 `chat-code-ask-current-file`
6. 在 code-mode buffer 中继续补充问题，或直接让命令立即发送
7. AI 如需切换到其他文件，可调用 `open_file` 在 Emacs 中直接打开相关文件
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
| `chat-code-git-review` | AI 审查代码变更 |
| `chat-code-git-pre-commit` | 运行提交前检查 |

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

当前不推荐把 `code-mode` 直接当作批处理或 CI 非交互引擎使用。
它的主路径仍然以交互式缓冲工作流为中心。

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

*Code Mode Guide - Current Repair Edition*
