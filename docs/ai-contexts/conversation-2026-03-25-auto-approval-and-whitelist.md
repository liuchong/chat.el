# 2026-03-25: Auto-Approval Mode and Command Whitelist Implementation

## Requirements

实现两个安全相关功能：
1. **默认同意模式 (Auto-Approval Mode)**：启用后执行工具不需要每次征求用户同意
2. **命令白名单模式 (Command Whitelist)**：白名单内的 shell 命令可以直接执行

## Technical Decisions

### 1. Auto-Approval Design

**Global Control:**
- `chat-approval-auto-approve-global` - 全局开关，默认 nil
- `chat-approval-auto-approve-tools` - 可自动同意的工具列表，默认 `(files_read files_grep apply_patch)`
- `shell_execute` 默认不包含在自动同意列表中（安全考虑）

**Session-Level Control:**
- 在 `chat-session` 结构中添加 `auto-approve` 字段（nil, t, or 'inherit）
- Session 级别设置优先于全局设置
- 使用 `chat-session-auto-approve-p` 获取实际生效的设置
- 使用 `chat-session-set-auto-approve` 修改设置

**Approval Decision Flow:**
1. 检查工具是否在 `chat-approval-required-tools` 中 - 不在则直接执行
2. 检查工具是否在 `chat-approval-auto-approve-tools` 白名单中
3. 检查 session 级别的 auto-approve
4. 检查全局 auto-approve
5. 否则弹出 y-or-n-p 询问用户

### 2. Command Whitelist Design

**Matching Rules:**
- 白名单项以空格结尾 → 前缀匹配（如 "ls " 匹配 "ls"、"ls -l"）
- 白名单项无空格 → 完全匹配（如 "ls" 只匹配 "ls"）
- 边界保护："ls " 不会匹配 "lsxxx"

**Implementation:**
```elisp
(defun chat-tool-shell-whitelist-match-p (command)
  "Check if COMMAND matches any pattern in whitelist."
  ;; Pattern ending with space: prefix match with word boundary check
  ;; Pattern without space: exact match only
  )
```

### 3. Integration Points

**Modified Files:**
- `chat-approval.el` - 添加全局配置和审批逻辑
- `chat-session.el` - 添加 session 级别 auto-approve 支持
- `chat-tool-shell.el` - 添加白名单功能
- `chat-tool-caller.el` - 整合审批和白名单检查
- `chat.el` - 添加交互命令

**Interaction Commands:**
- `chat-toggle-auto-approve-global` - 切换全局自动同意
- `chat-toggle-auto-approve-session` (C-c C-a) - 切换当前 session 自动同意
- `chat-add-to-shell-whitelist` - 添加命令到白名单
- `chat-remove-from-shell-whitelist` - 从白名单移除命令
- `chat-show-shell-whitelist` - 显示当前白名单

## Completed Work

### Core Implementation

1. **chat-approval.el:**
   - Added `chat-approval-auto-approve-global` (defcustom)
   - Added `chat-approval-auto-approve-tools` (defcustom)
   - Added `chat-approval--auto-approve-p` helper function
   - Modified `chat-approval-request-tool-call` to accept optional session parameter

2. **chat-session.el:**
   - Added `auto-approve` field to `chat-session` struct
   - Added `chat-session-auto-approve-p` function
   - Added `chat-session-set-auto-approve` function
   - Updated `chat-session--serialize` to handle auto-approve
   - Updated `chat-session--deserialize` to restore auto-approve

3. **chat-tool-shell.el:**
   - Added `chat-tool-shell-whitelist` (defcustom)
   - Added `chat-tool-shell-whitelist-match-p` function
   - Added `chat-tool-shell-whitelist-add` function
   - Added `chat-tool-shell-whitelist-remove` function

4. **chat-tool-caller.el:**
   - Added `chat-tool-caller--shell-whitelist-approve-p` helper
   - Modified `chat-tool-caller-execute` to check whitelist and pass session to approval

5. **chat.el:**
   - Added `chat-toggle-auto-approve-global` command
   - Added `chat-toggle-auto-approve-session` command
   - Added `chat-add-to-shell-whitelist` command
   - Added `chat-remove-from-shell-whitelist` command
   - Added `chat-show-shell-whitelist` command
   - Added C-c C-a keybinding for session auto-approve toggle

### Testing

Created prototype tests:
- `tests/prototypes/20260325-whitelist-matching.el` - 白名单匹配逻辑测试
- `tests/prototypes/20260325-auto-approve-flow.el` - 自动同意流程测试
- `tests/prototypes/20260325-session-serialize.el` - Session 序列化测试

All tests pass.

### Documentation

- Created `specs/001-auto-approval-and-whitelist.md` - 详细设计规范
- Created this AI context file

## Verification

### Test Results

```
=== Whitelist Matching Tests ===
PASS: 'ls' matches 'ls '
PASS: 'ls -l' matches 'ls '
PASS: 'lsxxx' does not match 'ls '
PASS: 'lsxxx -l' does not match 'ls '
PASS: 'ls' matches 'ls'
PASS: 'ls -l' does not match 'ls'
PASS: 'git status' matches 'git status'
PASS: 'git status --short' does not match 'git status'
PASS: 'git status' matches 'git '
PASS: 'git log && git status' matches 'git log && git status'

=== Auto-Approval Flow Tests ===
Test 1: Default behavior (auto-approve disabled) - OK
Test 2: Global auto-approve with tool in list - AUTO-APPROVED
Test 3: Global auto-approve with tool NOT in list - NEEDS APPROVAL
Test 4: Session-level auto-approve - AUTO-APPROVED (session override)

=== Session Serialization Tests ===
Test 1: Create session with auto-approve = t - PASS
Test 2: Create session with auto-approve = nil - PASS
Test 3: Deserialize and verify - PASS
```

## Usage Examples

```elisp
;; Global configuration
(setq chat-approval-auto-approve-global t)
(setq chat-approval-auto-approve-tools '(files_read files_grep apply_patch))

;; Shell whitelist configuration
(setq chat-tool-shell-whitelist
      '("ls " "cat " "pwd" "echo " "head " "tail "
        "grep " "find " "wc " "git status" "git log "
        "git diff " "git log && git status"))

;; Interactive commands
M-x chat-toggle-auto-approve-global    ; Toggle global setting
M-x chat-toggle-auto-approve-session   ; Toggle current session (C-c C-a)
M-x chat-add-to-shell-whitelist        ; Add pattern to whitelist
M-x chat-remove-from-shell-whitelist   ; Remove pattern from whitelist
M-x chat-show-shell-whitelist          ; Show current whitelist
```

## Key Code Paths

**Tool Execution with Approval:**
```
chat-tool-caller-execute
├── Check if shell_execute and whitelisted
│   └── chat-tool-caller--shell-whitelist-approve-p
│       └── chat-tool-shell-whitelist-match-p
├── If not whitelisted: chat-approval-request-tool-call
│   ├── Check if tool requires approval
│   ├── Check chat-approval--auto-approve-p
│   │   ├── Check session auto-approve
│   │   └── Check global auto-approve
│   └── y-or-n-p if needed
└── chat-tool-forge-execute
```

## Security Considerations

1. **Default Safe:** All features default to disabled/off
2. **shell_execute Excluded:** Shell commands not in auto-approve list by default
3. **Word Boundary Protection:** Whitelist patterns ending with space require word boundary
4. **Session Isolation:** Per-session settings don't affect other sessions
5. **Explicit Opt-in:** Users must explicitly enable auto-approval for each session

## Issues Encountered

1. **Byte-compiled file stale:** Tests failed initially due to stale `.elc` files
   - Solution: Remove `.elc` files or recompile after changes

2. **Forward declarations:** `chat-approval.el` uses functions from `chat-tool-forge` and `chat-session`
   - Solution: Added `declare-function` statements

## No New Pitfalls Added

本次修改没有新增需要记录到 troubleshooting-pitfalls.md 的失败模式。
