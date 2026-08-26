# chat.el

> ⚠️ **Alpha 阶段免责声明**
>
> 本项目尚处于早期测试阶段，核心功能仍在快速迭代中，**稳定性无法保证**。使用过程可能遇到功能缺陷、意外崩溃或数据丢失。
>
> 本项目采用**纯 AI 驱动开发**模式，代码由大语言模型生成并经人工审核，非传统人工编码方式。
>
> **欢迎体验测试**，但请知悉：测试期间产生的一切风险由使用者自行承担，项目方不对任何问题或损失负责。
>
> 🤝 **我们诚邀您参与**
> - 提交 Bug 反馈和功能建议
> - 贡献代码、文档或测试用例
> - 分享您的使用场景和痛点
> - 投入 Token、算力或时间支持项目发展
>
> 您的每一份贡献都将推动这个项目变得更好。

`chat.el` is a pure Emacs AI chat client focused on coding workflows.
It supports multi turn chat, ordered tool transcripts, file operations, session persistence, context trimming, streaming display, scoped plugin tools, and AI assisted tool forging.
Streaming keeps visible text, reasoning, native tool input, stop reasons,
and terminal errors as distinct events. Tool batches preserve provider
order while allowing only non-conflicting asynchronous reads to overlap;
writes and approvals remain serialized and cancellable.

Copyright 2026 chat.el contributors.

## Current Capabilities

- Chat with Kimi, Kimi Code, and OpenAI compatible providers
- Keep multiple sessions in atomically updated JSONL files and inspect raw request and response data
- Curate long term memory in `~/.chat/memory.md`, injected into every system prompt (`M-x chat-edit-memory`)
- Stream or fetch responses through an async non blocking UI path
- Expose built in file tools with approval gates for risky operations
- Feed tool results back into the model through ordered assistant and `:tool` messages with provider `tool_call_id` pairing
- Queue normal input during an active response as steering for the running agent
- Rebuild context before each agent step and cancel registered work when a run is stopped
- Scope tools per session and roll back plugin-owned tools, hooks, and services when a plugin stops
- Restore replaced tools/services through one reverse-chronological
  plugin rollback stack, including teardown-failure cleanup
- Regenerate or edit-resend through non-destructive sibling branches
- Browse durable parent/branch session trees and explicitly recover interrupted tool runs
- Run cancellable background tasks with completion notifications
- Execute and resume session-local conditional workflows with approval checkpoints
- Use optional MCP JSON-RPC stdio/HTTP primitives and isolated sub-agent backends
- Apply code, office, and daily capability profiles so sessions expose scoped tool sets
- Compact long conversations into durable, tool-pair-safe summaries
- Generate custom tools and save them to disk after explicit approval

### Code Mode

A dedicated mode for software engineering with:

- **Smart Context** - Includes project structure, symbols, and project rules
- **Code Editing** - Explain, refactor, fix, document, and generate tests inline
- **Multi-file Refactoring** - Cross-file rename, extract to file, move functions
- **Test Integration** - Auto-detect test frameworks, run tests, auto-fix failures
- **Git Integration** - Review and analysis helpers remain available as experimental modules
- **LSP Integration** - Works with lsp-mode and eglot for enhanced context
- **Symbol Indexing** - Cross-references, call graph, related symbols
- **Streaming Responses** - Real-time code generation display

## Quick Start

Load the package:

```elisp
(add-to-list 'load-path "/path/to/chat.el")
(require 'chat)
```

Supported providers:

- `kimi`
- `kimi-code`
- `kimi-code-anthropic`
- `openai`
- `deepseek`
- `qwen`
- `grok`
- `claude`
- `gemini`
- `glm`
- `doubao`
- `hunyuan`
- `minimax`
- `mistral`
- `ark-code` and `ark-code-anthropic` (Volcengine Ark Coding Plan)

Two protocol adapters cover most vendors: any OpenAI compatible API
registers through `chat-llm-register-openai-compatible-provider`, and
any Anthropic Messages compatible API registers through
`chat-llm-register-anthropic-compatible-provider`.  Adding a new
vendor is a base URL, a key function, and a model name.

Configure providers in one of these files:

- `~/.chat.el`
- `~/.chat/config.el`
- `chat-config.local.el` in the repository root

Later files override earlier ones.

Minimal local config:

```elisp
(setq chat-default-model 'kimi)
(setq chat-llm-enabled-providers '(kimi openai deepseek qwen grok claude gemini))
(setq chat-llm-kimi-api-key "sk-kimi-...")
```

Or use `auth-source`:

```text
machine kimi-api user api-key password YOUR_KEY
machine claude-api user api-key password YOUR_KEY
machine gemini-api user api-key password YOUR_KEY
machine kimi-code-api user api-key password YOUR_KEY
machine openai-api user api-key password YOUR_KEY
```

Start a session:

```text
M-x chat
```

## Project Layout

```text
chat.el/
  chat.el
  chat-config.local.el.example
  lisp/
    agent/
    core/
    llm/
    tools/
    plugin/
    ui/
    code/
  tests/
    unit/
    integration/
    prototypes/
    manual/
  scripts/
    maintenance/
    migration/
  docs/
  specs/
```

Layout rules:

- `chat.el` stays at the repository root as the single entry point
- runtime modules live under `lisp/` by domain
- the agent kernel lives under `lisp/agent/`
- Emacs plugins live under `lisp/plugin/`
- stable regression tests live under `tests/unit/`
- exploratory scripts live under `tests/prototypes/` or `tests/manual/`
- one-off migration helpers live under `scripts/migration/`

## Common Commands

| Command | Purpose |
|---------|---------|
| `M-x chat` | Open or resume the current chat buffer |
| `M-x chat-new-session` | Create a new session |
| `M-x chat-list-sessions` | Switch to an existing session |
| `M-x chat-session-tree-open` | Browse saved sessions as a parent/branch tree |
| `M-x chat-context-compact-current-session` | Summarize compactable history with the session model |
| `M-x chat-show-help` | Open the native chat help buffer |
| `M-x chat-view-raw-message` | Inspect the last raw API exchange |
| `M-x chat-view-last-raw-exchange` | Open the latest assistant request and response |
| `M-x chat-ui-cancel-response` | Cancel the active response |
| `M-x chat-show-current-request-status` | Show the active request diagnostics buffer |
| `M-x chat-quote-region` | Quote the active region into a chat session |
| `M-x chat-quote-defun` | Quote the defun at point into a chat session |
| `M-x chat-quote-near-point` | Quote nearby context around point into a chat session |
| `M-x chat-quote-current-file` | Quote the current file into a chat session |
| `M-x chat-ask-region` | Ask AI about the active region in a chat session |
| `M-x chat-ask-defun` | Ask AI about the defun at point in a chat session |
| `M-x chat-ask-near-point` | Ask AI about nearby context in a chat session |
| `M-x chat-ask-current-file` | Ask AI about the current file in a chat session |

## In-Buffer Commands

Text typed in the input area is sent to the model unless it starts with a
command prefix.

| Input | Purpose |
|-------|---------|
| `!<cmd>` | Run a shell command |
| `/cmd <cmd>` | Same as `!<cmd>` |
| `!!` | Repeat the last shell command |
| `!cd <dir>` | Change the working directory; a bare `cd` goes home |
| `/cd [dir]` | Change the working directory; with no argument, prompt for one |
| `/pwd` | Show the working directory |
| `/send <message>` | Send and record it, as plain input does |
| `/quick <q>`, `?<q>` | Ask the model without recording the exchange |
| `/queue <note>`, `/flush`, `/drop` | Collect notes and send them as one |
| `/model [name]` | Retarget this session; with no name, prompt for one |
| `/new`, `/list`, `/save`, `/clear` | Session housekeeping |
| `/cancel` | Cancel the response in flight |
| `\<text>` | Send text as is, even when it starts with `!` or `/` |

A slash command that is not listed here stays ordinary text and reaches
the model, so prose that begins with a slash still works.

### Working Directory

The working directory belongs to the session rather than the buffer. It is
saved with the session and restored when the session is reopened, and the
tools the agent runs use it too, so `!` commands and the model act on the
same directory. An explicit change also outranks the project root that
code mode detects.

File tools still honor `chat-files-allowed-directories`, so pointing a
session at a directory does not by itself grant the model access to it.

### Shell Commands And Trust

A command the model proposes goes through the restricted tool path, which
accepts only `chat-tool-shell-allowed-commands` and rejects shell
metacharacters. A command a person typed is treated as a different trust
level: by default it runs through the system shell, so pipes, redirection
and variables work. Set `chat-ui-shell-unrestricted` to nil to hold typed
commands to the same restrictions as the model.

### Fullwidth Input

Command syntax accepts fullwidth characters, letters and digits as well as
punctuation, so an input method left in fullwidth mode reaches the same
commands. Folding is per character, so the prefix and the name may each be
either width, in any combination:

```
/help    ／help    /ｈｅｌｐ    ／ｈｅｌｐ    ／ＨＥＬＰ    /ｈeｌp
```

`！ls`, `！！`, `？why`, `＼literal` and a name separated by an ideographic
space all work the same way.

What gets folded is decided by ownership: a string is folded when chat.el
is the thing that interprets it. In `！ls`, the `！` is a chat.el command —
it is shorthand for `/cmd` — so it folds. The `ls` after it is that
command's argument, the content handed to whatever executes it, so it does
not.

| Position | Folded | Whose is it |
| --- | --- | --- |
| Prefix, slash command name, separator | yes | chat.el's syntax |
| `/auto`, `/drop`, `/model`, `/help` argument | yes | names a chat.el command, keyword, model or topic |
| `/cd` argument | `／` and `～` only | separator and home are syntax; the rest is a name on disk |
| Shell body, prompt, queued note, literal | no | on its way out |

So `!echo "你好，世界"` reaches the shell unchanged and `/queue 搜索 ＡＢＣ`
sends the characters you meant. A command named in Chinese is untouched
too: the fold covers one Unicode block and ideographs are outside it, so
`/发送` and `/自动` are unaffected.

One consequence: a shell body typed entirely in fullwidth mode, `！ｌｓ`,
reaches the shell as `ｌｓ` and fails there, naming the word it could not
run. That is the rule working rather than a gap in it — folding it would
rewrite a search for fullwidth text — and the error comes from the executor,
which is the honest place for it.

## Tool Model

Built-in tools cover coding, work orchestration, external capabilities,
office tasks, and simple daily work:

- `files_read`
- `files_read_lines`
- `open_file`
- `files_list`
- `files_grep`
- `files_write`
- `files_replace`
- `files_patch`
- `apply_patch`
- `emacs_buffers`
- `emacs_read_buffer`
- `emacs_imenu`
- `emacs_xref`
- `emacs_project`
- `work_task_start`
- `work_task_list`
- `work_task_output`
- `work_task_stop`
- `work_plan_enter`
- `work_plan_exit`
- `work_todo_add`
- `work_todo_update`
- `work_todo_list`
- `work_goal_add`
- `work_goal_update`
- `work_goal_list`
- `work_workflow_start`
- `work_workflow_resume`
- `work_workflow_cancel`
- `work_workflow_list`
- `mcp_server_list`
- `mcp_connect`
- `mcp_call`
- `subagent_run`
- `subagent_list`
- `subagent_status`
- `subagent_cancel`
- `subagent_external_start`
- `subagent_external_output`
- `programming_git_status`
- `programming_flymake_diagnostics`
- `programming_compile_task`
- `programming_completion_at_point`
- `web_eww_read`
- `office_org_headlines`
- `office_org_agenda`
- `office_org_capture`
- `office_org_todo_update`
- `office_org_schedule`
- `office_dired_list`
- `office_dired_open`
- `office_dired_copy`
- `office_dired_mkdir`
- `office_dired_rename`
- `office_calc_eval`
- `office_calc_convert`
- `daily_calendar_today`
- `daily_diary_read`
- `daily_diary_insert`
- `daily_notify`
- `daily_mail_draft_create`
- `daily_message_draft_buffer`
- `daily_mail_draft_list`
- `daily_mail_draft_delete`

Risky tools require approval before execution. The shared gate evaluates
tool sensitivity, effects, and call-specific policy, so new write,
outbound, personal, correspondence, credential, and network capabilities
do not depend on a manually maintained tool-id list.
Generated tools also require approval before registration.
File writing tools can also be whitelisted by directory, so future writes under an approved directory can run without repeated prompts.
Emacs live-buffer tools are scoped by default: buffer listing and reads stay within the current project or current non-file buffer, and credential-like buffers are hard-denied.

Generated elisp tools must be a single top level `lambda` form.
This prevents compile time side effects from arbitrary wrapper forms.

## Step Budget

A run works in steps: one model turn, which may call tools, then another
turn that reads the results. `chat-agent-max-steps` caps how many steps one
run may take and defaults to 300. Set it to `unlimited` to lift the ceiling
while keeping the parameter in place:

```elisp
(setq chat-agent-max-steps 300)        ; the default
(setq chat-agent-max-steps 'unlimited) ; no ceiling
```

The final step withdraws the tools, so a run that reaches its ceiling still
has to write a handoff -- what it finished, what is left, what to do next --
instead of dying mid-tool-call with nothing to show. You can then continue in
a new round from that summary.

How much of this the model is told is configurable:

| `chat-agent-budget-disclosure` | Behaviour |
|---|---|
| `nearing` (default) | Silent until the budget is tight, then asks the run to converge |
| `always` | Reports the step count on every step |
| `final-only` | Speaks once, on the final step |
| `never` | Keeps the budget entirely on this side |

`nearing` is the default because a countdown delivered early makes runs wrap
up work they had not finished. `chat-agent-budget-nearing-ratio` (default
`0.75`) sets when "tight" begins.

`chat-ui-tool-loop-max-steps` and `chat-code-tool-loop-max-steps` default to
nil and follow the global budget. Set one only to hold that display to a
tighter ceiling.

## Context Budget

The step budget is a count this client picks; the context window is a
ceiling the provider imposes. When the context fills up, earlier history is
summarized rather than dropped, and the run is told so -- a run that knows
its record will be condensed writes down conclusions, while a run that
merely knows it is running out of room starts hoarding.

Instruction files can declare which of their spans must never be
summarized:

```markdown
## Non-negotiables <!-- chat:resident -->

- RULE-01 — never thin these out
```

The marker is an HTML comment, so Markdown hides it and tools that do not
implement the scheme see an ordinary comment and behave as before.
Declared spans are also exempt from `chat-project-instructions-max-chars`,
which previously cut instructions at a character count and silently dropped
whatever sat at the end.

A declaration is bounded: `chat-context-protected-max-ratio` (35% of usable
context by default) caps the fixed region, and the excess is demoted to
compactable in document order rather than obeyed, so no file can leave a
session with no room to work in.

The window is divided per category, and each category declares what happens
when it overflows -- history summarizes, file excerpts are dropped and read
again, resident text demotes in document order, and tool schemas only warn,
because a missing definition produces a call that fails at the provider
rather than a context that fits.

`M-x chat-context-budget-panel` shows the allowances beside what the
session actually holds, and names the window an oversized tool set would
need.

See [docs/context-budget.md](docs/context-budget.md) for the allowance
table in tokens per model size, and
[docs/resident-context.md](docs/resident-context.md) for the residency
syntax.

## Self-Knowledge and Storage

Compaction means the context a run sees is not the conversation, it is a
condensed view of one. The full record is still on disk, so the run is told
where: the session file, its id and name, and the shape of its entries.

`session_log` reads it back. Because the transcript stamps every message
with turn, step, category and work, the file is already filterable -- by
kind of content, by time, by literal text -- and results group by turn, so
a question stays with the steps that answered it instead of being
interleaved with everything else that happened.

Two directories back that up. Each session gets scratch space under
`chat-scratch-directory` that the model may write freely -- drafts,
intermediate output, anything cheaper to re-read than to carry -- pruned
after `chat-scratch-max-age-days` and always sparing the session in use.
`chat-knowledge-directory` holds Markdown notes that persist across every
session and project, which is what makes the tool better the more it is
used.

Knowledge notes are separate from `chat-memory-file` because the trust
differs: the memory file is curated by the user and is authoritative,
while a note the model wrote about its own findings is evidence that may
be stale. The prompt carries only the note index -- names and titles --
and bodies are read on demand, since the store grows with use and anything
in every request must not.

Because notes are visible in every later session, including unrelated
work, they are held to general desensitized knowledge: the technique
rather than the case, no project names, paths, hostnames or credentials.
The bar is deliberately high and the prompt says to prefer writing
nothing -- a small store of durable observations beats a large one that
has to be distrusted. Credentials and machine-specific absolute paths are
refused outright.

The whole block is measured against the system prompt share and falls back
to paths alone on a small window. At 8K the full text would be larger than
the entire share, and a block explaining how to recover a lost
conversation is worthless if it crowds out the conversation.

See [docs/self-knowledge-and-storage.md](docs/self-knowledge-and-storage.md).

## Wiki

A structured knowledge base under `chat-wiki-root`, one command with
subcommands:

```
/wiki index             open the generated index
/wiki log               open the operation log
/wiki lint              report orphans, broken links, empty pages
/wiki search <text>     list pages matching text
/wiki find              pick a page to open
/wiki new <type> <name> create a page
/wiki ingest <file>     add a document and have it summarized
/wiki ask <question>    answer using the wiki
```

Pages are Markdown with YAML frontmatter, filed under `sources/`,
`entities/`, `concepts/`, `comparisons/` and `synthesis/`, linked to each
other as `[[Title]]`. Being ordinary files is the point: the store stays
greppable, versionable and editable by hand rather than living inside this
program.

`/wiki ingest` creates the source page and then asks the model to fill in
its summary, entities and concepts using the wiki tools, as a recorded
turn -- so both the request and the tool calls that answer it are on
screen. It used to write `Key takeaway 1` into the page and stop, which
also meant a freshly created page failed the module's own lint.

The model reaches the wiki through `wiki_search`, `wiki_read` and
`wiki_write` rather than through an index in the system prompt. This is
the opposite choice from knowledge notes, and deliberately: that store is
bounded by what runs happen to learn, while a wiki is meant to grow for
years, and a growing block in the fixed region of the context steadily
shrinks the room left to work in. `wiki_search` returns titles, never
bodies, for the same reason.

Subcommand names fold from fullwidth and take a localized alias, so
`/wiki search`, `/wiki ｓｅａｒｃｈ` and `/知识库 搜索` are one command.
What follows the subcommand does not fold: a path, a title or a question
is data. See [Fullwidth Input](#fullwidth-input).

## File Access Defaults

By default file tools can access:

- the current project directory
- `/tmp/`
- `/var/tmp/`

You can override this with `chat-files-allowed-directories`.

## Recommended Local Config

```elisp
(setq chat-default-model 'kimi)
(setq chat-llm-enabled-providers
      '(kimi openai deepseek qwen grok claude gemini glm doubao hunyuan minimax mistral))
(setq chat-ui-use-streaming t)
(setq chat-session-auto-save t)
(setq chat-files-allowed-directories
      (list default-directory "/tmp/" "/var/tmp/"))
```

## Two Ways of Asking

`/send` and `/quick` both reach the model, and the difference is what is
kept.

```
/send <message>     ; the conversation: recorded, tools, several steps
<message>           ; the same thing -- plain input is /send
/quick <question>   ; asked beside it: nothing recorded, no tools
?<question>         ; the same thing, shorter
```

`/send` is the surface. It writes the turn into the session, and the run
answering it can read files, call tools and work over several steps.
`/ask` and `/question` used to exist and are gone. Both read equally well
as either of these two commands, so whichever one they pointed at, you had
to remember which -- and a name you have to memorize to tell apart from
its neighbour is not carrying its weight.

`/quick` is a question asked next to the conversation. Nothing is
recorded and no tools are used, which is what makes it cheap and what
makes it forgettable. Its answer is labeled `Assistant (quick)` so a
reply that will not be there next turn does not look like one that will.

## Deferred Send

A request rarely arrives in one piece. It arrives as "also check X", "and
the file is at Y" -- each of which, sent on its own, spends a turn on a
fragment. Collect them instead:

```
/queue check the tests   ; collected, not sent; /queue also claims plain input
and the docs             ; another note
/queue                   ; list what is collected
/drop                    ; take the last one back (/drop all for everything)
/flush                   ; send them as one message
/send                    ; same thing, if that is the word you reach for
```

They go out as a single numbered user message rather than as several,
because consecutive messages in one role are not something every provider
accepts. The count shows in the status line, and the queue lives on the
session, so closing the buffer does not lose what you typed.

## Auto: The Default Command

Plain input runs through one command, and by default that command is
`/send`. Work that comes in runs claims it, so the prefix is needed once
rather than every line:

```
!ls                 ; runs ls, and makes /cmd the default
wc -l *.el          ; runs as a shell command, no prefix needed
?what does that do  ; asks the model -- and hands plain input back
\literally this     ; one line straight to the model, whatever auto says
/auto off           ; back to /send explicitly
```

Anything that asks the model releases the claim, which is the thing that
was wrong before: with only `/cmd` able to hold plain input, a session
that had run one shell command stayed a shell, and a question got an
answer without getting you out.

It is a mode, so it is visible in two places. The status line reads
`auto: /cmd`, and the input prompt itself becomes `❯ cmd>` -- the status
line is at the top of a buffer that scrolls, and the cursor is at the
bottom. An explicit `/command` always means itself, and while a response
is running plain input steers that run rather than the default command.

The prompt says what RET will do, so an unclaimed line names the provider
and the model it will reach instead:

```text
K moonshot-v1-8k>   ; the baseline: this line goes to Kimi
✳ claude-sonnet-4-5>
❯ cmd>              ; a shell line, which no model sees
≡ queue>
```

The mark is the provider's own where a character resembles it, and the
initial of its name otherwise; `✦` stands in when there is no provider
configuration to read. A glyph the frame cannot draw is dropped rather
than shown as a hollow box, so the prompt degrades to `cmd>` and
`moonshot-v1-8k>` on a terminal without them. `chat-ui-prompt-model-width`
truncates a long model name, and hovering shows it in full.

Clicking the model name opens a menu of the configured providers and
switches this session to the one picked, which is the same thing
`M-x chat-set-model` does -- the model was visible in one place and
changeable in another. It is refused mid-response for the same reason
`chat-set-model` refuses: the reply would come back from a provider that
was never asked.

Configured means a key can be fetched for it. chat.el registers every
vendor it knows how to speak to at load time, so `chat-llm-providers`
holds sixteen while a typical machine reaches two, and offering the
register would be offering a catalogue rather than a choice. The list is
sensed rather than declared -- there is nothing to keep in step, and a
key set halfway through a session counts from the next time the prompt is
drawn. The session's own provider is always offered, with or without a
key, so a session sitting on one can see where it is and leave; and the
click affordance appears only when that leaves more than one to pick
from.

`:default sticky` in `chat-ui--command-table` says a command may claim
plain input; `:default reset` says using it hands the claim back. `/quick`
resets rather than sticking: as a sticky default it would answer every
following line and record none of them, and nothing on screen
distinguishes an answer that was written down from one that was not.

## Language

```elisp
(setq chat-language 'zh-CN)      ; or 'en, or 'auto (the default)
(setq chat-reply-language 'follow)   ; what the model is told to answer in
(setq chat-prompt-language 'follow)  ; the language of the instructions sent
```

`auto` follows the Emacs language environment, then `LC_ALL`,
`LC_MESSAGES` and `LANG`. A key with no entry in the chosen catalog reads
as English rather than as nothing, so a partial translation degrades to
readable. `M-x chat-i18n-report` says how complete each catalog is.

**Command names** have translations: `/auto` and `/自动` are the same
command, resolved to one table entry so every property of it is declared
once. Completion offers the names of the language in use; names from any
language are always accepted, because refusing a name the user knows in
order to be consistent about locale is pedantry with no upside. Key
sequences stay in ASCII -- they are what you press, not what you read.

**What the model is told** is switched separately, because it is not
cosmetic. `chat-reply-language` is the reliable lever: models follow
"answer in Japanese" well regardless of what language the instruction
arrived in, and stating it beats leaving the model to infer it from
phrasing. `chat-prompt-language` is the language of the instructions
themselves, and translated guidance changes what a model does in ways
that cannot be measured from inside Emacs -- pin it to `en` if a
translated prompt starts behaving worse than the English one.

Machine-read parts of a prompt are never translated at either setting:
JSON keys, tool names, the `*** Begin Patch` envelope, the `code-edit`
fence language. A parser matches those literally. For the same reason the
coding rule lists stay English while the persona around them is
translated: they are dense with literal tool names, and a translation
would have to carry all of them through untouched for no change in what
the model does.

Simplified Chinese ships complete. Adding a language means calls to
`chat-i18n-register`, `chat-i18n-register-aliases` and optionally
`chat-i18n-register-prompts`; the tests require any shipped translation
of the help to name exactly the keys and slash commands the English one
does, and require every command to have an alias so a half-translated
command list cannot ship.

The default lives on the session, so it survives reopening.

## Reading a Reply

A run is not one answer. It reasons, calls a tool, reads the result,
reasons again, and only then replies. All of it is kept, and the display
draws it from the session record rather than from anything it is holding
in a buffer — so an intermediate step cannot be overwritten by the step
that follows it, and reopening a session shows what the run showed.

| Part of a run | How it appears |
|---------------|----------------|
| Your question | Ordinary text |
| Reasoning | Folded behind a summary row, dimmed |
| Tool calls and results | Folded behind a summary row; a call and its result are one group |
| Prose on the way to the answer | Shown, in italics — meant to be read, not to be mistaken for the answer |
| The answer | Ordinary text, never folded |

Press `RET` on a summary row, or click it, to open that group; press
again to fold it. `C-c C-d` opens or folds everything at once. A group
stays as you left it while later parts of the same kind arrive.

Fold defaults are configurable through `chat-transcript-fold-styles`,
which also offers `latest-expanded` for keeping only the newest part of a
channel in view.

## Code Capability (AI Programming)

Code capability is a property of a chat session, not a second interface.
Turning it on adds project context, coding prompts and edit proposals to
the same chat buffer; everything else -- rendering, streaming, status,
tool display, keys -- is the one implementation every session uses.

The capability travels with the session, so a coding session reopened
from `M-x chat-list-sessions` still knows its project root, focus file
and context strategy.

Refactoring, git assistance, indexing extras and performance helpers are
still under repair and should be treated as experimental.

### Turning It On

| Command | Description |
|---------|-------------|
| `M-x chat-code-start` | Start a session with the current project's context |
| `M-x chat-code-for-file` | Focus on a specific file |
| `M-x chat-code-for-selection` | Use the current selection as context |
| `M-x chat-code-from-chat` | Give the current session code capability, without restarting the conversation |

Reading commands are not code-specific: `M-x chat-quote-region`,
`chat-quote-defun`, `chat-quote-near-point` and
`chat-quote-current-file` fill the input area so you can refine the
question, and the matching `chat-ask-*` commands send immediately.
`M-x chat-show-help` covers every key in one place.

### Inline Editing Commands

| Command | Description |
|---------|-------------|
| `M-x chat-edit-explain` | Explain code at point |
| `M-x chat-edit-refactor` | Refactor with instruction |
| `M-x chat-edit-fix` | Fix code issues |
| `M-x chat-edit-docs` | Generate documentation |
| `M-x chat-edit-tests` | Generate unit tests |
| `M-x chat-edit-complete` | Complete code at point |

For section-by-section documentation drafting and revision, see [docs/tips/long-document-workflow.md](docs/tips/long-document-workflow.md).

### Experimental Advanced Commands

These commands exist in the repository but are still being repaired and validated:

### Multi-file Refactoring

| Command | Description |
|---------|-------------|
| `M-x chat-code-rename-symbol` | Rename symbol across project |
| `M-x chat-code-extract-to-file` | Extract code to new file |
| `M-x chat-code-move-function` | Move function between files |

### Test Integration

| Command | Description |
|---------|-------------|
| `M-x chat-code-run-tests` | Run tests for current file |
| `M-x chat-code-test-generate` | Generate tests for function |
| `M-x chat-code-test-coverage-current` | Show test coverage |

### Git Integration

| Command | Description |
|---------|-------------|
| `M-x chat-code-git-commit-suggest` | AI-suggested commit message |
| `M-x chat-code-git-review` | Review changes with AI |
| `M-x chat-code-git-pre-commit` | Run pre-commit checks |

### Code Intelligence

| Command | Description |
|---------|-------------|
| `M-x chat-code-index-project` | Index project symbols |
| `M-x chat-code-find-symbol` | Find symbol definition |
| `M-x chat-code-find-references` | Find symbol references |
| `M-x chat-code-incremental-index` | Update index incrementally |

### Code Mode Features

- **Single-window design** - Respects your window layout
- **4 context strategies** - minimal, focused, balanced, comprehensive
- **Streaming responses** - Real-time code generation toggle exists
- **Visible run state** - Header line shows running, success, failed, cancelled, or stopped
- **Structured request panel** - `C-c C-p` opens a dedicated panel for phases, approvals, tool calls, whitelist changes, and stalled-request context
- **Live streaming diagnostics** - the request panel now shows live state, recent chunk freshness, and recent request activity while a response is still running
- **Live transcript narrative** - code-mode now shows a transient `[Live] ...` line inside the active assistant slot so waiting, streaming, tool follow-up, and approval states stay visible without fabricating hidden reasoning
- **Fast approval shortcuts** - pending approval prompts accept `C-c C-a` once, `C-c C-s` session, `C-c C-t` tool, `C-c C-f` directory for file writes, `C-c C-c` command, and `C-c C-d` deny
- **Native prompt guidance** - approval prompts and pending-approval messages teach the same shortcut flow without inserting extra transcript noise
- **Persistent approval status** - pending approvals also surface in code mode `header-line` / mode line and in the chat buffer status line
- **Path-aware input** - code-mode input now auto-suggests absolute and project-relative file paths while you type
- **Sticky single-file focus** - after code-mode reads or edits one concrete file, short follow-up requests can keep working against that same target instead of rediscovering it
- **Multiline input** - `S-RET` inserts a newline in the code-mode input area without sending the message
- **Streaming auto-follow** - code-mode follows live output while you stay near the response edge, without force-scrolling if you manually move away
- **Status discipline** - persistent status surfaces are reserved for blocking states; transient activity stays in the request panel or echo area
- **Detailed request diagnostics** - `C-c C-s` opens the full current-request status buffer
- **Project rooted guardrails** - Prompt and tool execution stay anchored to the active project root
- **Stacked project rules** - `AGENTS.md` files are collected from the filesystem root down to the working file (root first, deduplicated, capped at 32 KiB), plus an optional global `~/.chat/AGENTS.md`; plain chat injects them too

### Chat Mode Updates

- **Live request narrative** - plain chat now shows the same transient `[Live] ...` request state inside the active assistant slot, so waiting, streaming, tool follow-up, and approval states stay visible without opening a separate panel
- **Shared live request panel** - plain chat request panels now refresh from the same diagnostics observer flow as code-mode, so chunk freshness and recent activity stay current during long requests
- **Sticky file follow-up hints** - after plain chat reads or edits one concrete file, later vague follow-up requests can reuse that recent file target instead of rediscovering it from scratch
- **LSP integration** - Optional integration points exist
- **Experimental modules** - Refactor, git, indexing extras, and perf helpers are under repair

See `specs/002-code-mode*.md` for detailed documentation.

## External Capabilities

Configure MCP servers in a normal chat configuration file. Connections
are lazy: no process or network request starts while loading chat.el.

```elisp
(setq chat-mcp-servers
      '((:id "local-tools"
         :transport stdio
         :command ("server-command" "--stdio"))
        (:id "team-service"
         :transport http
         :endpoint "https://example.invalid/mcp")))
```

The `mcp_connect` tool initializes a configured server, preserves a
Streamable HTTP session when supplied, discovers its input schemas, and
registers namespaced tools for the next agent step. Stdio and HTTP calls
are cancellable and pass through the standard approval and request-panel
lifecycle.

The `subagent_run` tool starts an isolated nested kernel run with a bounded
step budget. The parent receives only the final summary; child messages
remain in the child session. External subprocess agents use one JSONL
request on stdin and keep their JSONL output in
`chat-subagent-directory`. Starting or cancelling either backend uses the
same scoped tool and approval policy as other capabilities.

## Architecture Map

| File | Responsibility |
|------|----------------|
| `chat.el` | Entry point and command wiring |
| `lisp/ui/chat-ui.el` | Chat buffer rendering and response lifecycle |
| `lisp/ui/chat-mark.el` | Glyphs and brand colours for modes and providers |
| `lisp/core/chat-session.el` | Session and message persistence |
| `lisp/llm/chat-llm.el` | Provider abstraction and async request handling |
| `lisp/core/chat-stream.el` | SSE parsing and chunk handling |
| `lisp/tools/chat-tool-caller.el` | Tool prompt contract, parsing, and execution |
| `lisp/core/chat-approval.el` | Approval flow for risky tools and tool creation |
| `lisp/core/chat-files.el` | Built in file tools and path safety checks |
| `lisp/core/chat-context.el` | Context trimming and summary generation |
| `lisp/tools/chat-tool-forge.el` | Tool registry, compilation, loading, and execution |
| `lisp/tools/chat-tool-forge-ai.el` | AI assisted tool generation flow |
| `lisp/tools/chat-mcp.el` | Stdio/Streamable HTTP MCP lifecycle and remote tool discovery |
| `lisp/tools/chat-subagent.el` | Isolated nested and JSONL subprocess agents |
| `lisp/code/chat-code.el` | Code mode main entry |
| `lisp/code/chat-context-code.el` | Smart context building |
| `lisp/code/chat-edit.el` | Edit operations |
| `lisp/code/chat-code-preview.el` | Preview buffer for changes |
| `lisp/code/chat-code-intel.el` | Symbol indexing and call graph |
| `lisp/code/chat-code-lsp.el` | LSP client integration |
| `lisp/code/chat-code-refactor.el` | Multi-file refactoring |
| `lisp/code/chat-code-test.el` | Test framework integration |
| `lisp/code/chat-code-git.el` | Git integration helpers |
| `lisp/code/chat-code-perf.el` | Performance and indexing helpers |

## Testing

Run the canonical test entry:

```bash
emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit
```

Current baseline:

- 591 regression tests discovered
- 591 passing
- 0 skipped in the canonical batch suite

Run provider integration tests separately:

```bash
emacs -Q -batch -l tests/run-integration-tests.el -f ert-run-tests-batch-and-exit
```

Integration test notes:

- deterministic cross-module workflow/MCP persistence runs without credentials
- online provider checks run only when their credentials are available
- integration tests remain separate from the canonical unit suite

Run deterministic primary-loop end-to-end paths:

```bash
emacs -Q -batch -l tests/run-e2e-tests.el -f ert-run-tests-batch-and-exit
```

## Documentation Map

- `docs/README.md` for the document index
- `docs/PROJECT_STATUS.md` for the current status snapshot
- `docs/troubleshooting-pitfalls.md` for known issues and fixes
- `docs/context-budget.md` for the per-category context allowances and overflow policy
- `docs/resident-context.md` for declaring instructions that must not be summarized
- `.agents/` for agent workflow records, decisions, logs, and stage history

## Notes For Contributors

- Read `AGENTS.md` before making changes
- Read `.agents/README.md`, `.agents/00-entry/current.md`, `.agents/00-entry/read-order.md`, `.agents/10-active/focus.md`, and `.agents/10-active/risks.md` before implementation work
- Update `.agents/` after each completed stage
- Add regression tests for each bug fix
- Do not use destructive git commands

## License

Copyright 2026 chat.el contributors.
This project is licensed under the [One Public License (1PL)](./LICENSE).
