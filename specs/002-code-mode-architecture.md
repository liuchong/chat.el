# Code Mode Architecture

## 设计原则

**单窗口设计 (Single Window Principle)**

- 不强制分割窗口，不弹出多窗口界面
- 所有功能在独立 buffer 中实现，用户自己控制窗口布局
- 用 `C-x b` 或 `C-x C-b` 切换 buffer，而不是切换窗口
- preview 在独立 buffer 中，按需查看

---

## 系统架构图

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              User Interface Layer                             │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────────────┐  │
│  │                         Code Chat UI (chat-code.el)                     │  │
│  │                                                                         │  │
│  │  Single buffer showing:                                                 │  │
│  │  - Session info (header line)                                           │  │
│  │  - Context summary (compact)                                            │  │
│  │  - Conversation history                                                 │  │
│  │  - Input area                                                           │  │
│  │                                                                         │  │
│  │  Preview in separate buffer (*chat-preview*), user switches manually    │  │
│  └────────────────────────────┬────────────────────────────────────────────┘  │
│                               │                                               │
│           ┌───────────────────┴────────────────────────┐                      │
│           │              Context Manager               │                      │
│           │         (chat-context-code.el)             │                      │
│           └───────────────────┬────────────────────────┘                      │
│                               │                                               │
│  ┌────────────────────────────┼──────────────────────────────────────────┐   │
│  │                     Context Strategies                                │   │
│  │                                                                        │   │
│  │  Strategy    │  Contents                    │  Tokens  │  Use Case     │   │
│  │  ────────────┼──────────────────────────────┼──────────┼─────────────  │   │
│  │  minimal     │  Current file only           │  ~2k     │  Quick edits  │   │
│  │  focused     │  + Related files             │  ~4k     │  Feature work │   │
│  │  balanced    │  + Symbols + Imports         │  ~8k     │  Refactoring  │   │
│  │  comprehensive│ + Full project structure    │  ~16k    │  Architecture │   │
│  └────────────────────────────────────────────────────────────────────────┘   │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
                                       │
┌──────────────────────────────────────┼───────────────────────────────────────┐
│                         Code Intelligence Layer                               │
├──────────────────────────────────────┼───────────────────────────────────────┤
│                                      │                                       │
│  ┌───────────────────────────────────┴───────────────────────────────────┐   │
│  │                    Code Analyzer (chat-code-intel.el)                  │   │
│  │                                                                        │   │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐        │   │
│  │  │  Symbol Index   │  │  Dependency     │  │  Code Metrics   │        │   │
│  │  │                 │  │  Analysis       │  │                 │        │   │
│  │  │  • Definitions  │  │                 │  │  • Complexity   │        │   │
│  │  │  • References   │  │  • Import graph │  │  • Hotspots     │        │   │
│  │  │  • Call tree    │  │  • File deps    │  │  • Coupling     │        │   │
│  │  │  • Hierarchy    │  │  • Cycle detect │  │  • Cohesion     │        │   │
│  │  └─────────────────┘  └─────────────────┘  └─────────────────┘        │   │
│  │                                                                        │   │
│  │  Storage: ~/.chat/index/<project>/                                     │   │
│  │  - symbols.json        (Definition locations)                          │   │
│  │  - references.json     (Call relationships)                            │   │
│  │  - dependencies.json   (Import graph)                                  │   │
│  └───────────────────────────────────┬───────────────────────────────────┘   │
│                                      │                                       │
└──────────────────────────────────────┼───────────────────────────────────────┘
                                       │
┌──────────────────────────────────────┼───────────────────────────────────────┐
│                         Edit Engine Layer                                     │
├──────────────────────────────────────┼───────────────────────────────────────┤
│                                      │                                       │
│  ┌───────────────────────────────────┴───────────────────────────────────┐   │
│  │                     Edit Manager (chat-edit.el)                        │   │
│  │                                                                        │   │
│  │  Edit Types:                                                           │   │
│  │  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐         │   │
│  │  │  Generate  │ │   Patch    │ │  Rewrite   │ │   Insert   │         │   │
│  │  │            │ │            │ │            │ │            │         │   │
│  │  │ Create new │ │ Line-level │ │ Function   │ │ Add to     │         │   │
│  │  │ code       │ │ changes    │ │ replacement│ │ position   │         │   │
│  │  └────────────┘ └────────────┘ └────────────┘ └────────────┘         │   │
│  │                                                                        │   │
│  │  Lifecycle:                                                            │   │
│  │  Proposed → Preview (in *chat-preview*) → [Accept | Reject | Modify]  │   │
│  │                                                                        │   │
│  │  Features:                                                             │   │
│  │  • Atomic transactions (all-or-nothing)                                │   │
│  │  • Undo history (per-edit and global)                                  │   │
│  │  • Conflict detection (concurrent modifications)                       │   │
│  │  • Backup creation                                                     │   │
│  └───────────────────────────────────┬───────────────────────────────────┘   │
│                                      │                                       │
└──────────────────────────────────────┼───────────────────────────────────────┘
                                       │
┌──────────────────────────────────────┼───────────────────────────────────────┐
│                         Tool Extensions Layer                                 │
├──────────────────────────────────────┼───────────────────────────────────────┤
│                                      │                                       │
│  ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐ ┌─────────────┐ │
│  │  Enhanced File  │ │   Code Edit     │ │    Project      │ │    Git      │ │
│  │     Tools       │ │    Tools        │ │    Tools        │ │   Tools     │ │
│  │                 │ │                 │ │                 │ │             │ │
│  │ files_read      │ │ code_patch      │ │ project_list    │ │ git_diff    │ │
│  │ files_write     │ │ code_rewrite    │ │ project_search  │ │ git_history │ │
│  │ files_grep      │ │ code_insert     │ │ project_deps    │ │ git_blame   │ │
│  │ files_structure │ │ code_delete     │ │ project_stats   │ │ git_stash   │ │
│  └─────────────────┘ └─────────────────┘ └─────────────────┘ └─────────────┘ │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
                                       │
┌──────────────────────────────────────┼───────────────────────────────────────┐
│                         Core chat.el Stack                                    │
├──────────────────────────────────────┼───────────────────────────────────────┤
│                                      │                                       │
│  ┌─────────────┐ ┌─────────────┐ ┌───┴─────────┐ ┌─────────────┐ ┌─────────┐ │
│  │ chat-session│ │  chat-llm   │ │ chat-files  │ │ chat-tools  │ │chat-    │ │
│  │             │ │             │ │             │ │             │ │approval │ │
│  │ • Persist   │ │ • Kimi      │ │ • Read      │ │ • Registry  │ │ • ACL   │ │
│  │ • History   │ │ • OpenAI    │ │ • Write     │ │ • Execution │ │ • Audit │ │
│  │ • Branch    │ │ • Streaming │ │ • Search    │ │ • Forging   │ │ • Auto  │ │
│  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘ └─────────┘ │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

## 数据流

### 1. 代码生成流程

```
User Input → Context Builder → LLM Request → Response Parser
                                               │
                                               v
                         ┌──────────────────────────────────┐
                         │         Response Type?           │
                         └──────────────────────────────────┘
                           │              │              │
                           v              v              v
                      ┌─────────┐   ┌──────────┐   ┌──────────┐
                      │  Text   │   │  Tool    │   │  Code    │
                      │         │   │  Call    │   │  Block   │
                      └────┬────┘   └────┬─────┘   └────┬─────┘
                           │             │              │
                           v             v              v
                      Display to    Execute Tool   Create Edit
                      User          │              Object
                                    v              │
                              Return Result        v
                                    │         Create/Update
                                    │         *chat-preview* buffer
                                    │              │
                              Continue Flow   (User switches
                                                  manually)
```

### 2. 上下文构建流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Context Building Pipeline                       │
└─────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐
  │  User Input  │
  └──────┬───────┘
         │
         v
  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
  │   Detect     │────▶│   Collect    │────▶│   Prioritize │
  │   Request    │     │   Sources    │     │   Content    │
  └──────────────┘     └──────┬───────┘     └──────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
         v                    v                    v
  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
  │ Current File │     │  Git Status  │     │  Symbol      │
  │  - Content   │     │  - Modified  │     │  Index       │
  │  - Cursor    │     │  - Diff      │     │  - Related   │
  │  - Selection │     │  - Log       │     │  - Hierarchy │
  └──────────────┘     └──────────────┘     └──────────────┘

                              │
                              v
  ┌─────────────────────────────────────────────────────────────────┐
  │                     Token Budget Manager                         │
  │  ┌─────────────────────────────────────────────────────────────┐ │
  │  │  Budget: 8000 tokens                                        │ │
  │  │                                                             │ │
  │  │  Priority Queue:                                            │ │
  │  │  1. Current function    [250 tokens]  ████                  │ │
  │  │  2. Imports             [200 tokens]  ███                   │ │
  │  │  3. Related function    [300 tokens]  █████                 │ │
  │  │  4. Class definition    [400 tokens]  ██████                │ │
  │  │  5. Test file          [1500 tokens]  ████████████████████  │ │
  │  │     └─ Truncated to 1000 tokens                           │ │
  │  │  6. Other refs...          [SKIP]  (budget exhausted)      │ │
  │  │                                                             │ │
  │  │  Total: 2150 tokens / 8000 used                            │ │
  │  └─────────────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────┘
                              │
                              v
  ┌─────────────────────────────────────────────────────────────────────┐
  │                         Context Object                               │
  │                                                                      │
  │  {                                                                   │
  │    "strategy": "balanced",                                           │
  │    "sources": ["file", "git", "symbols"],                            │
  │    "files": [                                                        │
  │      {"path": "src/main.py", "content": "...", "lines": [1, 50]},    │
  │      {"path": "src/utils.py", "content": "...", "symbols": ["helper"]}│
  │    ],                                                                │
  │    "symbols": [                                                      │
  │      {"name": "connect", "type": "function", "file": "src/main.py"}  │
  │    ],                                                                │
  │    "git": {                                                          │
  │      "modified": ["src/main.py"],                                    │
  │      "diff": "..."                                                   │
  │    },                                                                │
  │    "tokens": 2150                                                    │
  │  }                                                                   │
  └─────────────────────────────────────────────────────────────────────┘
```

### 3. 编辑应用流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Edit Application Flow                            │
└─────────────────────────────────────────────────────────────────────────┘

  ┌──────────────┐
  │  AI Response │
  │  with Code   │
  └──────┬───────┘
         │
         v
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     Parse Response                                   │
  │                                                                      │
  │  Input: "```python\ndef connect():\n    pass\n```"                   │
  │                                                                      │
  │  Extracted:                                                          │
  │  - Language: python                                                  │
  │  - Content: "def connect():\n    pass"                               │
  │  - Target: src/database.py (inferred from context)                   │
  │  - Position: Replace function "connect"                              │
  └────────────────────────────────┬────────────────────────────────────┘
                                   │
                                   v
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     Create Edit Object                               │
  │                                                                      │
  │  {                                                                   │
  │    "id": "edit-123",                                                 │
  │    "type": "rewrite",                                                │
  │    "file": "src/database.py",                                        │
  │    "range": {"start": 45, "end": 52},                                │
  │    "original": "def connect():\n    # TODO\n    pass",                │
  │    "replacement": "def connect():\n    pass",                        │
  │    "timestamp": "2026-03-26T10:00:00Z"                               │
  │  }                                                                   │
  └────────────────────────────────┬────────────────────────────────────┘
                                   │
                                   v
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     Validate Edit                                    │
  │                                                                      │
  │  ✓ File exists and is writable                                       │
  │  ✓ Range is valid (lines 45-52 exist)                                │
  │  ✓ Original text matches (hash check)                                │
  │  ✓ No syntax errors in replacement (for supported languages)         │
  │  ⚠ Warning: Function signature changed (may break callers)           │
  └────────────────────────────────┬────────────────────────────────────┘
                                   │
                                   v
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     Update Preview Buffer                            │
  │                                                                      │
  │  1. Create/update *chat-preview* buffer (no window split)            │
  │  2. Show message: "Preview in *chat-preview* (C-c C-v to view)"      │
  │  3. User can:                                                        │
  │     - Press C-c C-a to accept without viewing                        │
  │     - Press C-c C-v to switch to preview buffer                      │
  │     - Use C-x b to manually switch                                   │
  └────────────────────────────────┬────────────────────────────────────┘
                                   │
                                   v
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     User Action                                      │
  │                                                                      │
  │  Case 1: Direct Accept (C-c C-a)                                     │
  │     → Skip preview, apply directly                                   │
  │                                                                      │
  │  Case 2: View Preview First                                          │
  │     → User switches to *chat-preview*                                │
  │     → Review diff in preview buffer                                  │
  │     → Press 'a' to accept or 'r' to reject in preview buffer         │
  │                                                                      │
  │  Case 3: Reject (C-c C-k)                                            │
  │     → Discard edit, keep original                                    │
  └────────────────────────────────┬────────────────────────────────────┘
                                   │
                                   v
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     Apply Transaction                                │
  │                                                                      │
  │  BEGIN TRANSACTION                                                   │
  │    1. Create backup: src/database.py.bak.123                         │
  │    2. Write to temp: src/database.py.tmp.123                         │
  │    3. Verify temp file syntax: OK                                    │
  │    4. Atomic rename: src/database.py.tmp.123 → src/database.py       │
  │  COMMIT                                                              │
  │                                                                      │
  │  Result: ✓ Success                                                   │
  │  Backup kept for: 7 days (configurable)                              │
  └────────────────────────────────┬────────────────────────────────────┘
                                   │
                                   v
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     Post-Apply Actions                               │
  │                                                                      │
  │  • Update session edit history                                       │
  │  • Update symbol index (async)                                       │
  │  • Refresh any open buffers                                          │
  │  • Update git gutter (if enabled)                                    │
  │  • Trigger syntax check (if flymake/flycheck enabled)                │
  └─────────────────────────────────────────────────────────────────────┘
```

## 模块依赖图

```
                         ┌──────────────┐
                         │   chat.el    │
                         │   (main)     │
                         └──────┬───────┘
                                │
            ┌───────────────────┼───────────────────┐
            │                   │                   │
            v                   v                   v
   ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
   │ chat-session│      │  chat-llm   │      │ chat-files  │
   └──────┬──────┘      └──────┬──────┘      └──────┬──────┘
          │                    │                    │
          │    ┌───────────────┴────────────────────┘
          │    │
          v    v
   ┌─────────────────────────────────────────────────────┐
   │                    chat-code.el                      │
   │  (Entry point, session management, orchestration)    │
   └─────────────────────────────────────────────────────┘
          │
          ├──▶ ┌──────────────────┐
          │    │chat-context-code │ (Context building)
          │    └──────────────────┘
          │
          ├──▶ ┌──────────────────┐
          │    │ chat-code-intel  │ (Symbol indexing, analysis)
          │    └──────────────────┘
          │
          ├──▶ ┌──────────────────┐
          │    │   chat-edit.el   │ (Edit operations)
          │    └──────────────────┘
          │
          └──▶ ┌──────────────────┐
               │ chat-code-preview│ (Diff/preview UI - separate buffer)
               └──────────────────┘
```

## Buffer 设计

### 1. Code Chat Buffer

```
*chat:code:my-project*
════════════════════════════════════════════════════════════════════
Project: my-project | Strategy: balanced | Context: 2400/8000 tokens
════════════════════════════════════════════════════════════════════

You: Add error handling to the connect function

Assistant: I'll add error handling to the connect function...

[Tool Call] files_read: src/database.py (lines 45-52)

```python
def connect(host, port):
    try:
        conn = socket.create_connection((host, port))
        return conn
    except socket.error as e:
        logger.error(f"Connection failed: {e}")
        raise ConnectionError(...) from e
```

[Apply: C-c C-a] [Preview: C-c C-v] [Reject: C-c C-k]

────────────────────────────────────────────────────────────────────
> _
```

### 2. Preview Buffer

```
*chat-preview*
================================================================================
Preview: src/database.py                                    [Accept: a] [Reject: r]
================================================================================

--- a/src/database.py
+++ b/src/database.py
@@ -45,7 +45,10 @@ class Database:
     def connect(self, host, port):
-        # TODO: add error handling
-        pass
+        try:
+            self.conn = socket.create_connection((host, port))
+        except socket.error as e:
+            logger.error(f"Connection failed: {e}")
+            raise
```

**Keybindings in preview buffer:**
- `a` - Accept changes
- `r` - Reject changes  
- `q` - Quit preview
- `n` - Next change
- `p` - Previous change

## 文件结构

```
chat.el/
├── chat.el                    # Main entry
├── chat-session.el            # Session management
├── chat-llm.el                # LLM providers
├── chat-files.el              # File operations
├── chat-tool-*.el             # Tool system
│
├── chat-code.el               # Code mode main
├── chat-context-code.el       # Context management
├── chat-code-intel.el         # Code intelligence
├── chat-edit.el               # Edit operations
└── chat-code-preview.el       # Preview buffer (diff-mode based)

~/.chat/
├── sessions/
│   └── ...
├── tools/
│   └── ...
└── index/                     # Code index cache
    └── <project-hash>/
        ├── symbols.json
        ├── references.json
        ├── dependencies.json
        └── config.json
```

---

*Architecture Version: 0.2*
*Last Updated: 2026-03-26*
*Change: Single window design principle*
