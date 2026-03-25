# 001: Auto-Approval Mode and Command Whitelist Spec

## Overview

为 chat.el 增加两个安全相关的功能：
1. **默认同意模式 (Auto-Approval Mode)**：启用后执行工具不需要每次征求用户同意
2. **命令白名单模式 (Command Whitelist)**：白名单内的 shell 命令可以直接执行

## Requirements

### 1. 默认同意模式

#### 1.1 全局控制
- 全局开关 `chat-approval-auto-approve-global`，默认 nil
- 当设为 t 时，所有 session 默认自动同意（除非 session 单独覆盖）

#### 1.2 Session 级别控制
- 在 `chat-session` 结构中添加 `auto-approve` 字段
- Session 级别设置优先于全局设置
- 提供函数切换当前 session 的 auto-approve 状态

#### 1.3 安全边界
- 即使启用 auto-approve，仍需遵守 `chat-approval-required-tools` 配置
- 提供 `chat-approval-auto-approve-tools` 配置，指定哪些工具可以自动同意
- 默认 shell_execute 不纳入自动同意范围（需额外配置）

### 2. 命令白名单模式

#### 2.1 白名单配置
- `chat-tool-shell-whitelist`：字符串列表，存储允许自动执行的白名单
- 白名单仅对 shell_execute 工具有效

#### 2.2 匹配规则
- **前缀匹配**：白名单项必须匹配命令的开头
- **单词边界保护**：白名单项必须以空格结尾或匹配完整命令
  - "ls" 可以匹配 "ls"、"ls -l"、"ls -la /path"
  - "ls" 不能匹配 "lsxxx"、"lssomething"
- **复杂命令整体匹配**：如 "git log && git status" 作为整体匹配，不需要拆分

#### 2.3 匹配算法示例

```elisp
;; 白名单项 "ls " 的匹配
"ls"           -> 不匹配（缺少空格）
"ls "          -> 匹配
"ls -l"        -> 匹配
"lsxxx"        -> 不匹配
"lsxxx -l"     -> 不匹配

;; 白名单项 "ls"（不带空格）的匹配
"ls"           -> 匹配（完全相等）
"ls -l"        -> 不匹配（以空格结尾的才匹配前缀）

;; 实际使用建议：用户应该添加 "ls "、"cat "、"git " 这样的条目
```

#### 2.4 安全实现
```elisp
(defun chat-tool-shell--whitelist-match-p (command whitelist-entry)
  "Check if COMMAND matches WHITELIST-ENTRY."
  (let ((entry-len (length whitelist-entry)))
    (cond
      ;; 如果白名单项以空格结尾，匹配前缀
      ((and (> entry-len 0) (= (aref whitelist-entry (1- entry-len)) ? ))
       (string-prefix-p whitelist-entry command))
      ;; 否则必须完全匹配
      (t
       (string-equal whitelist-entry command)))))
```

### 3. 审批流程整合

#### 3.1 审批决策流程

```
chat-approval-request-tool-call
│
├─ 检查 tool 是否在 chat-approval-required-tools 中
│  └─ 不在列表中 → 无需审批，直接执行
│
├─ 检查是否在 auto-approve-tools 白名单中
│  └─ 在列表中 → 自动同意
│
├─ 检查 session 级别的 auto-approve
│  └─ 启用 → 自动同意
│
├─ 检查全局 auto-approve
│  └─ 启用 → 自动同意
│
└─ 弹出 y-or-n-p 询问用户
```

#### 3.2 Shell 命令特殊处理

对于 shell_execute 工具，额外检查命令白名单：

```
chat-tool-shell-execute
│
├─ 检查 shell tool 是否启用
├─ 检查命令是否通过 validate
├─ 检查命令是否在白名单中
│  └─ 在白名单中 → 直接执行，无需审批
│
└─ 走正常审批流程
```

## Implementation Plan

### Phase 1: 修改 chat-approval.el

1. 添加全局配置变量：
   - `chat-approval-auto-approve-global`
   - `chat-approval-auto-approve-tools`

2. 添加 session 级别支持：
   - 修改 `chat-approval-request-tool-call` 函数，接受可选 session 参数
   - 在函数内部检查 session 的 auto-approve 状态

### Phase 2: 修改 chat-session.el

1. 在 `chat-session` 结构中添加字段：
   ```elisp
   auto-approve  ; nil, t, or 'inherit (inherit from global)
   ```

2. 添加辅助函数：
   - `chat-session-auto-approve-p`：获取 session 的实际 auto-approve 状态
   - `chat-session-set-auto-approve`：设置 session 的 auto-approve 状态

### Phase 3: 修改 chat-tool-shell.el

1. 添加白名单配置：
   ```elisp
   (defcustom chat-tool-shell-whitelist '()
     "List of command prefixes that can auto-execute without approval."
     :type '(repeat string))
   ```

2. 实现白名单匹配函数：
   - `chat-tool-shell--whitelist-match-p`

3. 修改 `chat-tool-shell-execute`：
   - 检查白名单，匹配则直接执行
   - 不匹配则返回需要审批的标记（由上层处理）

### Phase 4: 整合到 chat-tool-caller.el

1. 修改 `chat-tool-caller-execute`：
   - 传递 session 参数给审批函数
   - 对于 shell_execute，检查是否需要跳过审批

### Phase 5: 添加交互命令

1. `chat-toggle-auto-approve-global`：切换全局自动同意
2. `chat-toggle-auto-approve-session`：切换当前 session 自动同意
3. `chat-add-to-shell-whitelist`：添加命令到白名单

## Configuration Examples

```elisp
;; 全局启用自动同意（默认，session 可覆盖）
(setq chat-approval-auto-approve-global t)

;; 设置可以自动同意的工具（默认不包括 shell_execute）
(setq chat-approval-auto-approve-tools
      '(files_read apply_patch))

;; Shell 命令白名单配置
(setq chat-tool-shell-whitelist
      '("ls " "cat " "pwd" "echo " "head " "tail "
        "grep " "find " "wc " "git status" "git log "
        "git diff " "git log && git status"))
```

## Security Considerations

1. **默认安全**：
   - 所有功能默认关闭
   - shell_execute 默认不纳入自动同意

2. **白名单严格匹配**：
   - 必须以空格或命令结尾作为边界
   - 防止前缀匹配导致的误匹配

3. **Session 隔离**：
   - 每个 session 独立设置
   - 不会影响其他 session

4. **审计日志**：
   - 自动同意的命令应记录到日志（可选）
   - 便于事后审查

## API Reference

### 新增函数

```elisp
;; chat-approval.el
(chat-approval-auto-approve-p &optional session tool-id) → boolean

;; chat-session.el  
(chat-session-auto-approve-p session) → boolean
(chat-session-set-auto-approve session value)

;; chat-tool-shell.el
(chat-tool-shell-whitelist-add pattern)
(chat-tool-shell-whitelist-remove pattern)
(chat-tool-shell-whitelist-match-p command) → boolean
```

### 新增变量

```elisp
;; chat-approval.el
global: chat-approval-auto-approve-global (boolean, default nil)
global: chat-approval-auto-approve-tools (list of symbols)

;; chat-session.el
session: auto-approve (nil, t, or 'inherit)

;; chat-tool-shell.el
global: chat-tool-shell-whitelist (list of strings)
```
