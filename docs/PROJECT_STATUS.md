# Project Status

Last updated: 2026-08-29

## Summary

`chat.el` is now at a usable coding assistant baseline inside Emacs.
The core chat flow, native and JSON tool calling, ordered assistant/tool transcript persistence, durable session tree metadata, work orchestration, MCP/sub-agent backends, capability packs, per-step agent context hooks, cancellation callbacks, scoped plugin runtime, session tool overlays, file tools, approval gates, async request path, context trimming, and tool forging path are all implemented and covered by tests.
Coding capability now runs on the unified chat surface with versioned edits,
semantic context, verification, repair, plans, isolation, review and controlled
collaboration. Historical indexing commands remain compatibility wrappers.
Runtime source files live under `lisp/agent`, `lisp/core`, `lisp/llm`, `lisp/tools`, `lisp/plugin`, `lisp/ui`, and `lisp/code`, with `chat.el` kept at the repository root as the single entry point.
The agent loop is extracted from UI and code mode. Tool results reenter the transcript as ordered `:tool` messages instead of bundled assistant fields for new runs. Emacs-native read-only tools are registered through the plugin host with default project-scoped buffer access, owner metadata, and rollback on plugin stop.
The provider layer now supports mainstream official models across domestic and international vendors, with `kimi` kept as the default and local config files loaded from user and project locations.
The repository now uses `.agents/` as the formal agent knowledge base, with legacy workflow logs migrated out of `docs/ai-contexts/`.
The Agent Runtime roadmap M0 through M8 is complete: a versioned
lifecycle event contract now unifies runtime hooks and session-scoped audit for
turns, prompts, tools, permissions, compaction, background tasks and child
agents. Model capabilities now resolve from explicit versioned facts, and
streaming and asynchronous requests share one normalized event stream. Named
runtime hooks, lazy skills and resolved agent profiles now extend the same loop
behind explicit trust and non-widening authority rules. Foreground runs,
background commands, workflows and subagents now share one durable task state
machine, bounded resource scheduler, parent/child cancellation contract and
native tree/detail view. Typed image and file content now persists through a
content-addressed attachment store, capability preflight and provider-specific
wire adapters. Checkpoints, owned worktrees, execution backends, attributable
memory, derived Trace reconstruction, deterministic evaluations and the optional
versioned App Server bridge are implemented. M9-M18 of the active M9-M19
coding-reliability roadmap are complete: isolated real-task evaluation,
versioned edits, semantic code intelligence, automatic verification and
scoped structured work context, plus durable evidence-linked TODO plans with a
native progress UI, capability-tested execution isolation, independent typed
review and conflict-safe coding children. Durable Goal contracts now survive
turns, compaction and restart with scoped evidence and explicit lifecycle
control. Independent Plan Mode enforces read-only research until the user
approves the exact submitted work-plan revision. M19 runtime phases, actionable
diagnostics, strict acceptance aggregation and the 10,000-file performance path
are implemented. Live coding Eval now writes each run to a fresh versioned
campaign with immutable configuration and completion records. Interrupted
campaigns can resume only validated missing repetition/task identities; stale
locks recover, concurrent runs and configuration drift fail closed, and terminal
evidence requires the exact unique result matrix. The immutable M9 baseline is
complete with 150/150 results. The latest valid historical M19 current campaign
also completed 150/150 with 112 passed, 37 cancelled and one failed, but its
74.67 percent success rate misses the 80 percent floor. Post-run diagnosis fixed
rustup access in the Darwin sandbox, native work-plan item schemas and explicit
build-output accounting. A live Rust smoke now passes all five checks with one
scoped source change and no scope leak. The historical campaigns remain
immutable; final acceptance still needs fresh same-manifest baseline/current
campaigns with complete trusted token usage. The fixed corpus includes a
measured 10,000-indexed-file large-repository task.

Goal and Plan acceptance facts now have a standalone producer rather than a
hand-authored metadata contract. The runner executes 17 gate-linked checks over
15 unique directed scenarios, measures 20 Goal prompt projections, validates
all nine facts through the final aggregator and refuses to certify a dirty
worktree. A clean run at revision `251706ebab8950ec89301e610ad0b2ce0de47d8f`
passed all nine gates with rates of `1.0`, safety counts of `0`, and a
`0.0032043746239855107` Goal projection median. Its complete JSON record is
stored outside the repository under the coding-acceptance evidence directory
with SHA-256
`fb5156cff6abbefd8617cb66d049db16a3545a49409b1798b752f0e08139eb8f`.
The final aggregator now adds a provenance gate that recomputes the nine
measurements and requires the exact clean current revision, 17 directed checks
and 20 projection samples; a hand-written nine-field object remains blocked.

Deterministic non-live quality gates now have the same provenance discipline.
The clean quality record at revision `251706e` contains 48 exact directed
scenarios, raw semantic rows for five languages, 20 plan/work-note prompt
samples and raw Review finding sets. Definition accuracy, reference
precision/recall and Top-5 are all `1.0` overall and per language; Review recall
is `1.0`, precision is `0.875`, and prompt median ratio is
`0.003149300780049963`. All 20 quality gates pass, and the record SHA-256 is
`1f3228bc39d9b381ff566aaf005bb0e66436e9aab13eb86b88bbe6b55f695c62`.
Final aggregation rejects a dirty or mismatched record, missing language,
skipped scenario, incomplete sample set, or rewritten source facts.

An initial replacement current run exposed one more live reliability defect:
multi-file TODO items could not be completed because evidence was double-encoded,
successful tools did not return their event identity to the Agent, and tool-call
scope was mistaken for Agent-task scope. Progress tools now accept native
Evidence ID arrays, successful tracked tools return exact IDs, and post-tool
events carry a separately resolved `agent_task_id`. The incomplete 10-result
campaign is retained only as incident evidence. The canonical suite passes
1808/1808. A focused multi-file trace confirms scoped post-tool identities and
native plan transitions; runtime now also accepts the explicitly declared
legacy JSON-string evidence shape without weakening the provider array schema.
The provider exhausted its seven-day allowance before the smoke could write or
verify, so it was correctly recorded as infrastructure error. A passing focused
smoke and fresh final campaigns remain after provider availability returns.

Replacement campaigns now have a committed frozen batch runner with explicit
implementation/harness revisions, clean-worktree checks, a no-network
descriptor preflight and a bounded provider/model readiness gate before any
campaign directory is created. Mid-run transport exhaustion, rate limiting,
quota, service-unavailable and capacity failures archive the attempt and pause
without consuming a trial identity, preventing one availability outage from
filling the remaining matrix with infrastructure errors.
Both replacement roles pass clean descriptor preflight under harness revision
`251706ebab8950ec89301e610ad0b2ce0de47d8f`: the current implementation uses
that same revision and the baseline uses `e4e6cbcec89a8a0d5f67d15a861ace9d9b4965d3`.
Each descriptor contains 30 tasks, five repetitions and 150 expected results,
with the shared manifest digest
`4ef1e36f8ae44456e2bc4dcf8f661adfdbe916e3a57024dca384107773e3fd38`.
The live readiness gate currently stops on the provider's explicit HTTP 403
seven-day quota response before creating a campaign directory.

## Implemented Areas

### Chat Core

- session creation and atomically replaced JSONL persistence
- parent/branch/leaf session metadata and a tabulated-list tree browser
- durable summary records for branch and compaction workflows
- interrupted tool-run recovery metadata on load
- ordered assistant/tool transcript persistence for new agent runs
- raw request and response inspection
- async non streaming request path
- optional streaming UI path
- response cancellation
- agent cancellation callbacks and cancelled tool-batch termination
- durable foreground, process, workflow and subagent task identities
- bounded parallel task scheduling with read/write resource conflicts
- native task tree, checkpoint details, cancellation and workflow resume
- versioned typed message parts with legacy text projection
- durable image and file attachments across reload, branch and edit-resend
- native file attach, clipboard image, preview and staged removal commands
- native in-buffer Markdown document rendering with reversible markers, syntax-coloured
  fences, stable streaming tails, CJK-safe tables, actionable image resources and a
  safe semantic HTML subset
- independent bounded MDP codec with document/machine dual views, linear duplicate
  detection and width-limited typed record tables

### LLM Providers

- official OpenAI, Kimi, Claude, Gemini, DeepSeek, Qwen, Grok, Mistral, GLM, Doubao, Hunyuan, and MiniMax provider entries
- provider specific auth headers and request URLs
- provider enable and disable list via configuration
- config loading from `~/.chat.el`, `~/.chat/config.el`, and project `chat-config.local.el`
- provider and model capability declarations with explicit unknown values
- versioned dynamic discovery cache with static fallback and user precedence
- pre-dispatch validation for known unsupported request combinations
- one normalized event vocabulary for streaming and asynchronous transports
- capability-driven image and file request encoding at provider boundaries

### Tool Calling

- provider tool calling plus JSON-in-text fallback
- built in file tools and project-scoped Emacs buffer/imenu/xref/project tools
- approval for risky tool execution
- bounded follow up tool loop
- tool results fed back as ordered `:tool` messages with provider call ids
- session overlays for advertised and executable tools
- owner, sensitivity, and effect metadata on tool events

### File Operations

- read and line range reads
- directory listing and grep
- write replace and patch flows
- diff previews for patch operations
- symlink aware path safety checks

### Context Management

- token estimation
- leading system message preservation
- omitted history summary messages
- summary inclusion of tool calls and tool results
- per-step agent context transform and next-turn prepare hooks
- persisted summary coverage with tool-pair-safe cut points
- iterative automatic compaction and asynchronous model summaries
- typed standing-context fragments with authority, provenance, scope and budget policy
- scoped project-instruction dependency graphs with cycle and traversal diagnostics
- revisioned session work notes with key, kind and tag indexes across restart
- request-only projection of project rules, code context and applicable active notes
- bounded request-only projection of the active durable work-plan slice and newly added evidence
- protected bounded projection of the selected Goal contract, plus an independent
  Plan Mode instruction fragment that survives compaction and reload

### Durable Sessions

- same-directory atomic JSONL updates
- session format version 1 plus transparent migration from the earlier
  single-JSON format, covered by a compatibility fixture
- parent/child branching without destructive history edits
- explicit mark-failed, discard, and keep recovery for interrupted tool runs

### Agent Runtime Events

- versioned lifecycle identity, correlation, provenance and bounded payloads
- ordered synchronous blockers with modify/refuse outcomes and timeout policy
- isolated post-persistence observers that cannot fail the run
- session-wire audit for turns, tools, permissions, compaction, tasks and
  child agents
- runtime-owned audit metadata protected from producer context spoofing
- Guard review records routed through the same event pipeline

### Tool Forging

- AI assisted tool generation
- explicit approval before tool registration
- lambda only elisp source validation
- registry loading and persistence
- persisted parameter schemas for generated tools
- owner, sensitivity, and effect metadata for generated or plugin-owned tools

### Plugin Runtime

- pending, active, failed, and disposed plugin lifecycle states
- dependency retry when pending services become available
- owned service, tool, and hook tracking
- reverse-order rollback when a plugin stops or setup fails
- plugin-owned named runtime hooks backed by the unified lifecycle event bus

### Agent Extensions

- versioned blocker and observer declarations with deterministic ordering
- explicit trust boundary for project-local hooks, skills and profiles
- lazy declarative skill discovery with provenance and schema validation
- ordered profile inheritance with cycle and conflict diagnostics
- pre-dispatch model capability validation for resolved profiles and skills
- non-widening tool overlays, monotonic approval and bounded execution limits
- session-level profile selection and audited reproducibility snapshots
- code, office, daily, review and all-tools built-in profiles

### Work Orchestration

- cancellable background process tasks with persisted state, logs, and
  terminal notifications
- bounded output reads and explicit task stop support
- versioned durable Goal contracts with scoped evidence, optimistic revisions,
  pause/resume/block/complete transitions and bounded history
- independent persisted Plan Mode with read-only tool gating and exact-revision
  user approval
- session-local compatibility records for legacy plan and TODO callers
- ordered conditional workflows with approval checkpoints, per-step
  persistence, failure pause, cancellation, and durable resume
- work tools registered with owner and effect metadata
- revisioned session/task work plans with DAG dependencies, one current item,
  scoped evidence, restart recovery and tool-boundary enforcement
- native folded plan progress above the input area with point and scroll stability
- six-phase runtime projection with deduplicated repaint and stable input/window anchors
- actionable unavailable, blocked, stale, failed, timeout and cancelled diagnostics

### MCP and Sub-agents

- lazy configured stdio MCP clients with request ids, async callbacks,
  timeout/cancel notification, reconnect, and teardown
- Streamable HTTP JSON-RPC with JSON/SSE responses and session-id reuse
- discovery of namespaced schema-aware remote tools in the shared registry
- in-process nested kernel runs with isolated child sessions, depth limits,
  budgets, cancellation, and parent-safe summaries
- external subprocess-agent JSONL protocol with captured output and cancellation
- read-only independent review sessions with typed, source-navigable findings
- declared coding-child path ownership, hierarchical scheduler locks and owned worktrees
- merge refusal for stale base, ownership drift, parent drift and patch conflicts
- bounded parent summaries and mandatory post-merge verification evidence
- immutable final coding acceptance with exact live sample and identity gates
- 10,000-file repo-map benchmark with known-path incremental refresh

### Capability Packs

- code, office, daily, review and combined session profiles backed by
  provider-visible tool overlays
- programming tools for read-only status, Flymake diagnostics, native
  completion-at-point, web documentation, and compile/test background tasks
- office tools for Org agenda/capture/TODO/scheduling, Dired-style
  open/copy/mkdir/rename operations, and Calc evaluation/unit conversion
- daily tools for calendar/diary, rendered web reading, notifications,
  local draft records, and unsent message-mode draft buffers

## Current Quality Baseline

### Test Status

- canonical command: `emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit`
- 1782 regression tests discovered
- 1782 passing
- 0 skipped in the canonical batch suite
- 0 known failures in the current baseline
- optional provider integration command: `emacs -Q -batch -l tests/run-integration-tests.el -f ert-run-tests-batch-and-exit`
- deterministic end-to-end command: `emacs -Q -batch -l tests/run-e2e-tests.el -f ert-run-tests-batch-and-exit`
- deterministic coding-fixture and workflow/MCP integration: 2 passing;
  2 online provider checks skip when credentials are absent
- primary-loop MCP and nested-agent end-to-end paths: 2 passing
- five built-in offline Eval scenarios passing; run them directly with
  `chat-eval-run-all` after loading `chat.el`
- 10,000-file performance gates passing: 31.0ms maximum wall slice and
  111.3ms warm query p95 in the recorded M19 environment

### Stability Highlights

- no thread based request deadlocks in the main request path
- async requests now have timeout timers and cleanup
- empty assistant messages are filtered before API submission
- risky tools require approval before execution
- sensitivity, effects, and call-specific predicates feed the same
  approval gate, including opted-in out-of-project buffer reads
- AI generated tools require approval before registration
- shell execution no longer goes through shell expansion
- code mode supports stable input, multi turn requests, cancel, preview creation, and explicit `code-edit` parsing
- code mode now reuses the shared JSON tool calling contract and follow up tool loop
- code mode follow up rendering now returns to the UI buffer before touching markers
- debug logs stay in `~/.chat/chat.log` unless minibuffer echo is explicitly enabled
- inline JSON tool calls are stripped from displayed assistant text before rendering
- code mode now shows a safety limit notice instead of raw tool JSON when automatic tool follow up stops
- code mode tool execution now inherits the active project root for file access and shell working directory
- builtin readonly shell whitelist now covers common inspection commands and safe `cd DIR && CMD` exploration
- code mode now shows explicit running, success, failed, cancelled, and stopped status in the buffer header line
- code mode prompt now includes project rooted operational guardrails to reduce aimless tool retries
- code mode now injects project `AGENTS.md` into context when present
- code mode now sends hard coded non-negotiable engineering rules in every programming request
- request diagnostics now expose current phase, recent events, and stalled-request hints in both chat and code mode
- request execution state now has a dedicated request panel so tool steps no longer clutter assistant transcript output
- request panel now includes approval choices, command-level approval context, and shell whitelist mutations
- approval prompts now support direct shortcut decisions that match the request panel action hints
- approval shortcut guidance now also appears in native prompt text and first-occurrence minibuffer feedback in chat mode and code mode
- pending approvals now remain visible in persistent native status surfaces instead of only transient prompts
- file-write approvals now also support directory-level whitelisting, so repeated edits under one approved subtree can run without repeated prompts while shell and non-directory tools remain outside that scope
- request panel now also shows directory-scoped approval context for file-write whitelists, making the approval boundary visible before and after acceptance
- code-mode input now supports path-aware completion for absolute and project-relative file paths, and `S-RET` now inserts a newline without submitting the current prompt
- request diagnostics now support observers, code-mode uses them to refresh live status surfaces during streaming, and the request panel now shows live state, chunk freshness, and recent activity while a response is still running
- code-mode streaming output now follows the live response edge when the user is still near the active output, which makes long-running generation less visually stale without hijacking manual navigation
- code-mode transcript now shows a transient live narrative line in the active assistant slot, driven by diagnostics and tool events so waiting, tool-loop, and approval states stay visible during long requests
- code-mode now promotes the most recently inspected single-file tool target into session focus, which makes vague follow-up edit requests like "optimize it" more likely to continue on the intended file instead of broad rescanning
- code-mode tool-loop follow-up requests now use a dedicated timeout budget instead of sharing the shorter generic non-streaming request timeout
- plain chat now refreshes its transcript and request panel from the same diagnostics observer path, so streaming state and tool-loop progress stay visible while a request is still active
- plain chat now also tracks recent single-file tool targets and feeds them back into later vague follow-up requests, which reduces rediscovery when the user says things like "optimize it" after a file-specific review
- persistent native status surfaces are now explicitly limited to blocking states, while transient activity stays out of header and mode lines
- `.agents/` now holds the formal agent workflow records, phase history, reference decisions, and imported legacy logs
- sessions create child branches at durable message boundaries so regenerate and edit-resend preserve the original lineage
- chat mode regenerates on a sibling branch and restores the last user turn into the branched input area for editing
- code mode supports the same non-destructive regenerate and edit-resend flow, and buffer rebuilds replay the active branch history
- code mode now supports explicit reading captures for region, defun, and nearby context, all routed through the same quoted question flow
- code mode now also supports bounded current-file capture on top of a shared reading capture module
- plain chat now exposes the same shared reading capture model for region, defun, near-point, and bounded current-file questions
- AI can already open project files in Emacs through the built in `open_file` tool, keeping reading and navigation inside the editor
- active chat and code-mode input now steers the running agent instead of being rejected when a response is in progress
- agent runs now support per-step context transforms, next-turn prepare hooks, FIFO/LIFO queue delivery, cancel callbacks, and tool-batch cancellation before later tools run
- streaming completion now emits a normalized `stream-result` event carrying accumulated text and native tool metadata before regular result handling
- stream normalization now also carries typed reasoning, native partial
  tool input, nested stop reasons, and terminal provider errors
- model requests now normalize streaming and asynchronous transports into
  ordered text, reasoning, tool, usage and terminal events
- reasoning-capable tool continuations replay the producing assistant step's
  reasoning metadata without exposing it to unknown or unsupported models
- tool batches preserve provider result order, overlap only
  non-conflicting asynchronous reads, serialize writes and approvals,
  and cancel active asynchronous handles with the parent run
- native provider schemas now encode zero-argument tools as empty objects and forged-tool parameter schemas survive reload
- runtime tool calls now enforce required fields, JSON types,
  enumerations, and unknown-field rejection before execution
- Emacs live-buffer tools now hide credential-like buffers and default to project/session-scoped exposure
- plugin runtime now tracks lifecycle state, retries pending dependency injection, and rolls back owned services, tools, and hooks
- plugin rollback now follows one reverse-chronological stack across
  resource types, restores replaced registrations, and still completes
  after teardown errors
- optional user plugin loading evaluates only explicitly enabled files
  and completes registration before enabled plugins start
- persisted forged tools retain owner, sensitivity, effects, and
  parameter enumerations used by provider schemas
- session tool overlays now filter provider-visible tools and direct execution, with tool events carrying owner, sensitivity, and effect metadata
- plain chat now has a native help buffer that exposes the new reading commands alongside the existing chat command set
- code mode now also has a native help buffer and `C-c C-h` shortcut so reading commands, preview flow, request-panel usage, and regenerate/edit-resend are discoverable inside the main coding surface
- shared reading helpers now have denser regression coverage around naming, fallback behavior, minimal captures, and help-buffer behavior
- shared reading and plain-chat bootstrap paths now also have denser refusal, default-limit, and fallback-session coverage
- region capture now correctly keeps end-line metadata stable when selections stop at the next line boundary, and reused plain-chat sessions now replace stale input before quoting or asking
- reading captures now also reject empty regions instead of producing blank code blocks, and root-directory reading sessions now keep a visible fallback name
- empty-file current-file and near-point captures are now rejected before they can produce blank quoted code blocks
- whitespace-only region, near-point, and current-file captures are now also rejected before they can produce useless quoted prompts
- whitespace-only and empty-context guardrails continue to tighten at the shared reading helper layer, with empty-file capture rejection now covered explicitly
- `open_file` now reports the actual Emacs landing line and column when requested positions run past EOF or past the end of a line
- basic `chat-files` operations now have denser regression coverage for partial reads, size guards, overwrite protection, recursive deletion, nested mkdir, and directory type reporting
- `files_read_lines` now normalizes invalid start lines and keeps empty line ranges coherent when callers ask beyond EOF
- session helpers now have denser regression coverage for clearing history, missing message ids, default last-message lookup, and invalid saved-session files
- sessions now persist parent/branch/leaf metadata, message parent/branch fields, durable summary records, and expose a tabulated-list tree browser
- JSONL updates now repair partial tails in a same-directory temporary file
  before atomic rename, and loading offers explicit recovery for unfinished
  assistant/tool pairs
- compaction helpers now find tool-pair-safe cut indices so summaries do not split an assistant tool call from its matching tool result
- work orchestration now executes and resumes conditional registered-tool
  workflows with approval checkpoints and per-step persistence
- MCP and sub-agent tools now cover cancellable stdio/Streamable HTTP
  discovery, primary-loop remote calls, nested kernel isolation, and JSONL
  subprocess agents
- capability packs now provide concrete programming, office, and daily
  tools with provider-visible profile filtering
- file editing helpers now create missing parent directories on write, allow append-to-new-file flows, keep `apply_patch` atomic across multiple operations, and support regexp capture-group replacements
- `apply_patch` now uses hunk headers to resolve repeated source blocks and accepts the codex-compatible `*** End of File` marker
- `apply_patch` add-file operations now honor codex-style `*** End of File` newline semantics instead of always forcing a trailing newline
- `apply_patch` move paths now have explicit regression coverage for both successful renames and atomic refusal when the move target already exists
- update-style `apply_patch` operations now also honor EOF markers when removing a trailing newline from the rewritten file
- `files_replace` now has explicit regression coverage showing that `line_hint` narrows ambiguous matches and participates in post-filter count validation
- `apply_patch` now supports pure insertion hunks such as `@@ -0,0 +1 @@` and `@@ -N,0 +M @@`, which are common in AI-generated unidiff output
- `apply_patch` now has explicit regression coverage for pure deletion hunks and end-of-file pure insertion hunks, covering two more high-frequency AI patch shapes
- `apply_patch` now also has explicit regression coverage for later hunks landing correctly after earlier pure insert and pure delete hunks, reducing the risk of header-drift regressions
- `apply_patch` now accepts both codex-style `*** End of File` and standard unified-diff `\\ No newline at end of file` markers for add-file and update paths
- `apply_patch` now tolerates optional unified-diff metadata such as `diff --git`, `index`, and `---`/`+++` file labels before update hunks
- `apply_patch` now rejects malformed hunk payload lines early instead of trying to interpret non-unified helper output as valid patch data
- `apply_patch` now rejects malformed hunk headers and metadata-only update blocks while still accepting bare `@@` shorthand headers that are common in AI-generated codex patches
- `files_replace` and `files_patch` now also have explicit regression coverage for replace-all success, exact expected-count success, and atomic refusal when a later search patch fails
- `files_replace` now also has explicit regression coverage for regexp replace-all and exact expected-count success after line filtering, and `apply_patch` now has explicit regression coverage for move-only rename patches
- invalid regexp input in `files_replace` and `files_patch` now fails with a stable replace-specific error instead of leaking raw regexp exceptions, and both paths are covered to leave files unchanged
- `files_replace` now also has explicit regression coverage showing that `line_hint` still refuses ambiguous same-line matches, and `apply_patch` add-file parsing now has explicit regression coverage for rejecting unprefixed payload lines
- `files_replace` and `files_patch` now reject empty search text before entering the replace engine, and regexp replace paths now also reject patterns that can match empty text
- `apply_patch` now uses actual hunk payload counts instead of blindly trusting header counts when later hunk placement depends on line deltas, which keeps AI-generated patches with inaccurate counts from drifting into ambiguous follow-up placement
- `apply_patch` now rejects directory paths with stable verification errors instead of leaking lower-level directory read failures through update and delete flows
- `files_write`, `files_replace`, and `files_patch` now also reject directory targets with the same stable path-level validation instead of leaking lower-level file and stream errors
- `files_replace` and `files_patch` now also reject missing edit targets with stable edit-level errors instead of leaking raw `insert-file-contents` failures
- `files_insert_at` now reuses the same direct-edit validation, so missing and directory targets fail with the same stable edit-level errors as the other direct editing entrypoints
- direct edit entrypoints now use `Edit failed: ...` semantics while patch parsing and application still use `apply_patch verification failed: ...`, which keeps non-patch edit failures distinct from patch-engine failures
- patch application failures that happen after parsing now also receive the `apply_patch verification failed: ...` prefix, so parser-time and apply-time patch failures now share one stable error family
- multi-operation `apply_patch` flows now have explicit regression coverage for delete-then-add replacement, add-then-update composition, move-then-update composition, and move-then-recreate-source composition
- nested `apply_patch` add and move targets now have explicit regression coverage for parent-directory creation, and failed nested add operations are covered to leave no partial directory tree behind
- `apply_patch` now also keeps ambiguous hunk failures and invalid pure-insert locations inside the same stable `apply_patch verification failed: ...` family, reducing one more class of AI-unfriendly error drift
- `apply_patch` empty-file semantics are now covered so empty add-file output and updates that delete the entire file content no longer leave stray trailing newline bytes behind
- chained `apply_patch` path reuse now has explicit regression coverage for add-then-delete cleanup, move-then-delete cleanup, and multi-step move chains across intermediate paths
- `apply_patch` conflict paths now also have explicit regression coverage for add-existing refusal, delete-missing refusal, and move-missing-source refusal, keeping those verification errors stable and atomic
- `files_replace` and `files_patch` now refuse no-op edits instead of reporting false success when the replacement would leave file content unchanged
- `files_patch` now also refuses multi-step patch sequences that net out to the original file content, removing another false-success path for automated edit loops
- `files_replace` and `files_patch` now preserve `line_hint` scope in no-match, count-mismatch, and ambiguous-match diagnostics, making automated retry decisions less guessy
- `files_replace` and `files_patch` now reject nonpositive `expected_count` and `line_hint` selectors before matching begins, keeping selector bugs out of the normal no-match error path
- `files_replace` now also rejects non-string `search` and `replace` inputs with stable replace-family errors instead of leaking lower-level type failures from malformed tool arguments
- `apply_patch` now explicitly requires the closing `*** End Patch` envelope and has regression coverage for empty patch text, whitespace-only patch text, illegal top-level `*** Move to:` lines, and unique-match fallback when hunk header start positions drift
- code-mode help and docs now include a documented long-document workflow that recommends section-by-section drafting, targeted existing-file edits, and preview-plus-git review for larger writing tasks

## Known Boundaries

- token counting is still heuristic rather than model exact
- streaming currently falls back to the async request path in `chat-llm-stream`
- default providers still depend on external API availability and local keys
- some provider default remote model names are best effort defaults and may need local adjustment as vendor catalogs change
- provider integration tests now live outside the canonical batch suite and should be run explicitly with credentials and network access
- code mode refactor, git helper, indexing extras, and performance helpers should still be treated as experimental
- the repository still does not meet a tests-to-runtime-lines ratio above 1, so further test-heavy stages are still needed if a much denser safety net is desired

## Recommended Next Work

- freeze the updated coding manifest and implementation, then run fresh
  baseline and current 30-by-5 campaigns with the same provider, model and
  capability identity
- record the immutable comparison, trusted usage sample and failure taxonomy;
  do not mark M19 complete before every strict acceptance gate passes
- retain both complete runtime and quality reliability JSON records from the
  same clean frozen revision and pass them intact to final aggregation
- make true provider streaming and fallback behavior share one transport abstraction
- extend the reading workflow from code mode into other surfaces only when the shared capture model stays intact
- consider a current-file reading command after the new region, defun, and near-point captures settle
- expose the shared reading capture model to plain chat without duplicating formatting or session bootstrap logic
- keep increasing focused unit coverage around new workflow modules rather than only growing end-to-end surface area
- keep growing test density around shared reading helpers and remaining refusal edges without fragmenting the shared reading workflow
- add denser tests around plain-chat reading commands beyond the current helper and bootstrap matrix
- keep growing deterministic refusal and fallback coverage before adding more reading-surface features
- keep adding helper-level tests that can still expose real metadata and reuse bugs instead of only increasing broad end-to-end coverage
- keep pushing helper-level refusal and naming coverage before widening the reading workflow surface again
- keep closing blank-context edge cases before spending more effort on wider reading-surface discoverability
- keep treating whitespace-only context as invalid input so helper-level guardrails match actual AI usefulness
- keep pushing helper-level blank-context coverage until quoted reading prompts cannot be created from useless input
- add live-server integration cases only for intentionally provisioned
  environments; deterministic workflow, remote-tool, and nested-agent
  paths are covered
- consider a richer session browser and export flow

## Key Files

| File | Area |
|------|------|
| `lisp/agent/chat-agent.el` | agent kernel |
| `lisp/core/chat-agent.el` | load-path shim |
| `lisp/plugin/chat-plugin.el` | plugin host |
| `lisp/ui/chat-ui.el` | UI and response lifecycle |
| `lisp/core/chat-session.el` | persistence |
| `lisp/core/chat-goal.el` | durable Goal contracts and lifecycle |
| `lisp/core/chat-plan-mode.el` | read-only planning permission state |
| `lisp/llm/chat-llm.el` | provider abstraction |
| `lisp/core/chat-stream.el` | stream parsing |
| `lisp/tools/chat-tool-caller.el` | tool protocol |
| `lisp/core/chat-approval.el` | approvals |
| `lisp/core/chat-files.el` | file tools |
| `lisp/core/chat-context.el` | context trimming |
| `lisp/tools/chat-tool-forge.el` | tool registry and compilation |
| `lisp/tools/chat-tool-forge-ai.el` | AI tool generation |
