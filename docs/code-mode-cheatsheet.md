# Code Mode 快速参考卡

当前可靠能力以 `chat-code.el` 的主对话链路为准。
重构、git、索引性能相关命令目前仍应按实验能力理解。

## 🚀 启动 Code Mode

```
M-x chat-code-start              从当前项目启动
M-x chat-code-for-file           针对特定文件
M-x chat-code-for-selection      使用当前选区
M-x chat-code-from-chat          从普通聊天切换
M-x chat-code-quote-region       把当前选区引用到输入框
M-x chat-code-ask-region         直接提问当前选区
```

## ✏️ 内联编辑（在代码缓冲区）

```
快捷键          命令                      功能
─────────────────────────────────────────────────────────
C-c e e    chat-edit-explain        解释代码
C-c e r    chat-edit-refactor       重构代码（需输入指令）
C-c e f    chat-edit-fix            修复问题
C-c e d    chat-edit-docs           生成文档
C-c e t    chat-edit-tests          生成测试
C-c e c    chat-edit-complete       代码补全
```

## 💬 Code Mode Buffer（*chat:code:<session>*）

```
快捷键          功能
─────────────────────────────────────────────────────────
RET           发送消息
C-c C-a       接受修改
C-c C-k       拒绝修改
C-c C-v       查看预览（切换到 *chat-preview*）
C-c C-f       更改焦点文件
C-c C-r       刷新上下文
C-c C-q       把当前选区引用到输入区
C-c C-SPC     直接提问当前选区
C-c C-s       查看当前请求诊断
C-c C-p       切换请求过程面板
C-c C-e       编辑并重发最后一条用户消息
C-c C-g       重新生成最后一条 AI 回复
C-g           取消操作
```

## 📖 阅读代码工作流

```text
1. 在源码 buffer 里选中正在阅读的代码
2. M-x chat-code-quote-region 或 C-c C-q
3. 在 code-mode buffer 中补充问题，或直接用 M-x chat-code-ask-region / C-c C-SPC
4. AI 如有需要可调用 open_file 直接打开相关文件
```

## 🔀 多文件重构（实验性）

```
M-x chat-code-rename-symbol          跨文件重命名
M-x chat-code-extract-to-file        提取到新文件
M-x chat-code-move-function          移动函数
```

## 🧪 测试集成（实验性）

```
M-x chat-code-run-tests              运行当前文件测试
M-x chat-code-run-test-at-point      运行光标处测试
M-x chat-code-test-generate          生成测试
M-x chat-code-test-coverage-current  查看覆盖率
```

## 📦 Git 集成（实验性）

```
M-x chat-code-git-diff               显示 git diff
M-x chat-code-git-commit-suggest     AI建议提交信息
M-x chat-code-git-review             审查变更
M-x chat-code-git-pre-commit         提交前检查
```

## 🧠 代码智能（实验性）

```
M-x chat-code-index-project          索引项目
M-x chat-code-find-symbol            查找符号定义
M-x chat-code-find-references        查找符号引用
M-x chat-code-incremental-index      增量更新索引
M-x chat-code-start-background-index 启动后台索引
M-x chat-code-cleanup-cache          清理缓存
```

## 👁️ 预览 Buffer（*chat-preview*）

```
快捷键      功能
─────────────────
a         接受修改
r         拒绝修改
q         关闭预览
n         下一个修改
p         上一个修改
```

## ⚡ 配置速查

```elisp
;; 启用
(setq chat-code-enabled t)

;; 上下文策略
(setq chat-code-default-strategy 'balanced)  ; minimal/focused/balanced/comprehensive

;; 自动应用（少于N行）
(setq chat-code-auto-apply-threshold 10)

;; 流式响应
(setq chat-code-use-streaming t)

;; 快捷键
(global-set-key (kbd "C-c c c") 'chat-code-start)
(add-hook 'prog-mode-hook
  (lambda ()
    (local-set-key (kbd "C-c e e") 'chat-edit-explain)
    (local-set-key (kbd "C-c e r") 'chat-edit-refactor)
    (local-set-key (kbd "C-c e f") 'chat-edit-fix)
    (local-set-key (kbd "C-c e t") 'chat-edit-tests)))
```

## 🎯 提示词示例

```
添加错误处理
优化性能
提取到函数
使用列表推导式
添加类型注解
生成单元测试
解释这段代码
修复潜在bug
重命名为 xxx
添加文档字符串
```

## 🔄 完整工作流程

```
1.  M-x chat-code-start
2.  输入需求
3.  AI 生成代码
4.  C-c C-a 接受 / C-c C-v 预览 / C-c C-k 拒绝
5.  M-x chat-edit-tests 生成测试
6.  M-x chat-code-run-tests 运行测试
7.  如有需要再使用实验性辅助命令
8.  人工审查后自行处理 git 操作
```

## 📁 文件说明

| 文件 | 功能 |
|------|------|
| chat-code.el | 主入口 |
| chat-context-code.el | 智能上下文 |
| chat-edit.el | 编辑操作 |
| chat-code-preview.el | 预览 buffer |
| chat-code-intel.el | 符号索引 |
| chat-code-lsp.el | LSP 集成 |
| chat-code-refactor.el | 多文件重构（实验性） |
| chat-code-test.el | 测试集成（实验性） |
| chat-code-git.el | Git 集成（实验性） |
| chat-code-perf.el | 性能优化（实验性） |

## 🐛 故障速查

| 问题 | 解决 |
|------|------|
| 响应慢 | `(setq chat-code-default-strategy 'focused)` |
| 不准确 | 使用 comprehensive 策略，提供更多上下文 |
| 索引慢 | `M-x chat-code-incremental-index` |
| 应用失败 | `M-x revert-buffer` 后重试 |
| LSP 不工作 | 确保 `M-x lsp` 或 `M-x eglot` 已启动 |

---

*打印此页放在手边参考*
