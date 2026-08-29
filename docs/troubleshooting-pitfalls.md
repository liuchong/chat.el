# Troubleshooting and Pitfalls

This file is the canonical handbook for failure modes and fix patterns in `chat.el`.

## How To Update This File

When adding a new entry:

1. Put it under the closest topic section
2. Reuse this exact field order
3. Merge duplicates instead of appending near copies
4. Keep examples minimal and directly actionable

Required field order:

- `Problem`
- `Cause`
- `Solution`

## Topic Index

- Authentication and Provider Setup
- Request Building and JSON
- Async Requests and Streaming
- Session and Persistence
- File Tools and Security
- Tool Calling and Tool Forging
- Work Orchestration
- MCP and Sub-agents
- Capability Packs
- Testing and Batch Mode
- Development Hygiene
- Display and Rendering

---

## Authentication and Provider Setup

### 401 Invalid Authentication

**Problem**: API key works on the website but returns 401 in Emacs.

**Cause**: Kimi Code China keys from `console.kimi.com` are not compatible with the standard Moonshot endpoint at `api.moonshot.cn`.

**Solution**: Use the provider that matches the API key and endpoint.

```elisp
;; Wrong
(setq chat-llm-kimi-api-key "sk-kimi-...")
(setq chat-default-model 'kimi)

;; Right
(setq chat-llm-kimi-code-api-key "sk-kimi-...")
(setq chat-default-model 'kimi-code)
```

### Wrong Model ID For The Kimi Code Endpoint

**Problem**: The API returns 401 with `Your model id does not exist, recognized as other:<id>`.

**Cause**: Kimi Code and the Kimi open platform use different model IDs for the
same model. `kimi-k3` belongs to `api.moonshot.cn`; the Kimi Code endpoint only
accepts `k3`, `k3-256k`, `kimi-for-coding` and `kimi-for-coding-highspeed`. The
`k3[1m]` spelling is exclusive to Claude Code environment variables and is
rejected as a model ID in plain API requests.

**Solution**: Use the ID that belongs to the endpoint.

```elisp
;; Wrong
(setq chat-llm-kimi-code-default-model "kimi-k3")

;; Right
(setq chat-llm-kimi-code-default-model "k3")
```

Both `kimi-code` and `kimi-code-anthropic` snapshot this variable into the
provider registry at load time, so a `setq` that runs after `chat` is loaded
only reaches the OpenAI channel, which re-reads the variable on every request.
Update the registry too when the Anthropic channel matters:

```elisp
(dolist (p '(kimi-code kimi-code-anthropic))
  (when-let ((cfg (chat-llm-get-provider-config p)))
    (plist-put cfg :model chat-llm-kimi-code-default-model)))
```

### 403 Access Denied For Kimi Code

**Problem**: The API returns `Kimi For Coding is currently only available for Coding Agents`.

**Cause**: Historically the endpoint was believed to allow only recognized
coding agents, which is why the provider used to send `claude-code/0.1.0`. That
premise did not hold up when measured: with a valid key, `chat.el/0.1.0`,
`curl/8.0` and even a request with no `User-Agent` at all all returned 200 on
both `/coding/v1/chat/completions` and `/coding/v1/messages`. The provider now
reports its own identity, which the community guidelines require — forging
client identity risks membership suspension.

**Solution**: Send the client's real identity. If a genuine 403
`access_terminated_error` ever appears, reproduce it first, then ask for the
client to be recognized through the feedback channel.

Two traps when investigating this:

- The endpoint validates the key **before** the `User-Agent`. With a dead key
  every UA value returns the same 401, so no UA change can be verified in that
  state. Get a working key first.
- Emacs `url` does not reliably pass a `User-Agent` request header through. The
  transport layer extracts it from the provider headers and binds
  `url-user-agent`, so declaring it in `:headers` is correct — but a bare
  `url-retrieve` that ignores that binding will silently drop it.

### Config File Override Order Can Hide Provider Settings

**Problem**: a provider key or default model seems to be ignored or unexpectedly changed after startup.

**Cause**: `chat.el` loads `~/.chat.el`, then `~/.chat/config.el`, then project local `chat-config.local.el`, and later files override earlier values.

**Solution**: keep provider settings in one place when possible, or intentionally rely on the override order.

```elisp
;; Global defaults
;; ~/.chat.el
(setq chat-default-model 'kimi)

;; Machine specific overrides
;; ~/.chat/config.el
(setq chat-llm-enabled-providers '(kimi claude gemini))

;; Project local override
;; ./chat-config.local.el
(setq chat-default-model 'claude)
```

---

## Request Building and JSON

### Nested Property Lists Break JSON Encoding

**Problem**: `json-encode` produces malformed payloads when nested plists are used as message objects.

**Cause**: plists are not encoded as the object shape required by the provider request format.

**Solution**: Use alists inside a vector for message arrays.

```elisp
;; Wrong
(json-encode (list :role "user" :content "hello"))

;; Right
(json-encode
 (vconcat '(((role . "user") (content . "hello")))))
```

### Hand Written JSON In Tests Drifts Easily

**Problem**: test payloads written as raw JSON strings become fragile and hard to update.

**Cause**: escaping and nested object shape are easy to get wrong by hand.

**Solution**: build test payloads from elisp data and then call `json-encode`.

```elisp
(json-encode
 '((choices . [((delta . ((content . "text"))))])))
```

### Fenced Block Parsers Must Match Newlines Explicitly

**Problem**: code mode can miss valid fenced `code-edit` blocks or ordinary code blocks even when the response text looks correct.

**Cause**: Emacs regular expressions do not let `.` cross line breaks, so a naive fenced block pattern stops at the first newline.

**Solution**: use an explicit multiline body pattern like `\\(?:.\\|\n\\)*?` and keep block extraction in one helper shared by all fenced block parsing paths.

---

## Async Requests and Streaming

### Thread Based Request Flow Can Freeze Emacs

**Problem**: `make-thread` with synchronous HTTP calls can freeze the UI.

**Cause**: Emacs threading and the event loop interact badly with `url-retrieve-synchronously`.

**Solution**: use async request APIs or timer based scheduling for non blocking behavior.

```elisp
;; Prefer async requests or timer based scheduling
(run-with-idle-timer 0.1 nil (lambda () ...))
```

### Async Request Timeout Must Clean Up Buffer State

**Problem**: async HTTP requests can hang forever and leave stale request state behind.

**Cause**: the transport accepted a timeout option but did not tie a timer to the request buffer.

**Solution**: install a timeout timer on the request buffer and cancel it on success or explicit cancellation.

```elisp
(setq-local chat-llm--timeout-timer
            (run-at-time timeout-secs nil ...))
```

### Streaming Choices May Decode As Lists Or Vectors

**Problem**: stream parsing returns nil even when the payload contains content.

**Cause**: some decode paths produce lists and others produce vectors for the same JSON array.

**Solution**: provider parsers and stream helpers must accept both shapes.

```elisp
(let ((first-choice (and choices
                         (if (vectorp choices)
                             (aref choices 0)
                           (car choices)))))
  ...)
```

### Streaming Path Can Bypass Tool Post Processing

**Problem**: streaming mode shows tool JSON but never executes the tool chain.

**Cause**: chunks were appended directly to the UI without running the same final response processing used by the non streaming path.

**Solution**: finalize streaming responses through the same tool processing path as the async non streaming flow.

### SSE Partial Lines Can Lose Content

**Problem**: stream chunks can break JSON boundaries and drop content.

**Cause**: parsing each process chunk independently ignores incomplete SSE lines.

**Solution**: keep a per process partial line buffer and parse only complete lines.

### Stream Metadata Must Not Be Flattened Into Text

**Problem**: reasoning leaks into visible output, native tool arguments are incomplete, or a truncated tool call executes.

**Cause**: the stream adapter handles only text deltas and ignores provider-specific tool starts, partial JSON input, nested stop reasons, reasoning deltas, or typed error events.

**Solution**: normalize each event into distinct text, reasoning, tool, finish-reason, and terminal-error fields. Map token-limit stop reasons to `length` before the kernel decides whether tool arguments are complete.

### Mode Specific Stream Adapters Can Drift From The Core API

**Problem**: a mode specific streaming path fails with wrong number of arguments or never finalizes the response.

**Cause**: the mode layer invents its own callback contract instead of following the actual `chat-stream-request` signature and sentinel flow.

**Solution**: keep mode integrations on the same four argument `chat-stream-request` contract and finalize the completed response from the process sentinel.

### Diagnostics Event Order Can Change In Fast Async Tests

**Problem**: diagnostics tests fail because the last recorded event is not the response event even though the request lifecycle is correct.

**Cause**: request lifecycle bookkeeping can append a later metadata event such as handle attachment after an immediate success callback fires in a mocked async transport.

**Solution**: validate diagnostics semantically by checking phase and searching the event timeline for the expected response event instead of asserting that one exact event must be last.

### Cancellation Must Reach The Kernel Batch

**Problem**: cancelling a run stops the UI but later tool calls in the same model response still execute.

**Cause**: cancellation is treated only as a transport/UI state and the tool batch loop does not re-check the run state between calls.

**Solution**: register cancellers on the run, mark the run cancelled in the kernel, check cancellation between synchronous calls, and invoke every active asynchronous tool handle. Late callbacks must not append transcript messages.

### Concurrent Tool Results Must Keep Provider Order

**Problem**: two independent asynchronous reads finish out of order and their results are paired with the wrong tool-call ids.

**Cause**: completion order is used as transcript order.

**Solution**: allocate the result vector in provider order before dispatch. Overlap only resource-compatible asynchronous reads; serialize writes, destructive operations, and approval-bearing calls.

### Vague Code-Mode Follow-Ups Can Drift Away From The Reviewed File

**Problem**: after reviewing one file, a short follow-up such as "do one round of optimization" can time out or continue analyzing without editing the intended file.

**Cause**: the session did not automatically promote the most recently inspected single-file tool target into `focus-file`, so the next request lost its strongest document target and the model had to rediscover it.

**Solution**: track file-specific tool targets, keep the latest single-file target as `focus-file`, add it back into context for the next request, and give tool-loop follow-up requests their own timeout budget.

---

## Session and Persistence

### Model Changes Do Not Affect Existing Sessions

**Problem**: changing `chat-default-model` does not update old sessions.

**Cause**: the selected model is persisted with the session.

**Solution**: create a new session after changing the default model.

```elisp
(setq chat-default-model 'kimi-code)
;; Then create a new session
```

### Session Creation Must Respect `chat-default-model`

**Problem**: `chat-session-create` can drift to a hardcoded model.

**Cause**: fallback logic that ignores `chat-default-model`.

**Solution**: always compute the model with configuration first.

```elisp
:model-id (or model-id (bound-and-true-p chat-default-model) 'kimi)
```

### Timestamp Serialization Must Stay Stable

**Problem**: `decode-time` depends on a predictable timestamp format.

**Cause**: loosely formatted timestamps break deserialization.

**Solution**: always serialize timestamps as ISO 8601 strings.

```elisp
(format-time-string "%Y-%m-%dT%H:%M:%S" (current-time))
```

### Session Metadata Must Stay JSON Serializable

**Problem**: adding a message can fail during auto save with a `json-error` when session metadata contains runtime objects.

**Cause**: live structs like `chat-code-session` can form circular references back to the owning `chat-session`.

**Solution**: keep runtime only session state in buffer local variables or serialize only primitive metadata values into `chat-session-metadata`.

### Session Metadata Reads Back As An Alist Keyed By Plain Symbols

**Problem**: metadata written with `plist-put` and a keyword key reads as `nil` after the session is reopened, even though the value is present in the session file.

**Cause**: metadata goes through JSON. A keyword plist encodes as a JSON object and decodes as an alist whose keys are plain symbols, so `:working-directory` comes back as `working-directory` and `plist-get` no longer matches. The value is intact; only the lookup fails, which makes this look like data loss.

**Solution**: go through `chat-session-metadata-get` and `chat-session-metadata-set`, which store an alist keyed by plain symbols so the in-memory and on-disk shapes agree. Accept either a keyword or a plain symbol as the key.

```elisp
(chat-session-metadata-set session 'working-directory "/tmp/")
(chat-session-metadata-get session :working-directory) ; => "/tmp/"
```

### Persistence Stubs Must Not Masquerade As Real Load Paths

**Problem**: higher level features like incremental indexing appear to exist but silently rebuild everything every time.

**Cause**: the save path writes index files while the corresponding load path still returns `nil` as a placeholder.

**Solution**: finish the load path at the same time as the save path or explicitly disable the feature until both directions are implemented and covered by tests.

### Mid-Save Crashes Must Not Brick Sessions

**Problem**: a session disappears from the list and cannot be resumed after Emacs is killed during a save.

**Cause**: session files were truncated and rewritten in place, and load signaled on the partially written JSON.

**Solution**: write to a temporary file and rename it over the target atomically, make `chat-session-load` return nil on unreadable files, and never push nil sessions into `chat-session-list`.

### Tool Pairs Must Persist In Transcript Order

**Problem**: a reloaded session can fail the next provider request after a tool call, or the model repeats a completed tool call.

**Cause**: saving one aggregated assistant message with bundled tool results loses the provider's ordered assistant/tool pair contract.

**Solution**: persist each loop-emitted assistant and `:tool` message in order. Keep bundled `tool-results` expansion only as compatibility for older sessions.

### JSONL Append Must Preserve Record Boundaries

**Problem**: after a crash during append, the next message can merge with a partial trailing JSON line and become unreadable too.

**Cause**: appending new JSONL records without first checking the existing file's final newline lets the partial line and new record share one line.

**Solution**: before appending, ensure the file ends with a newline. Loading should skip corrupt partial lines while preserving later complete records.

### Interrupted Tool Runs Must Stay Interrupted

**Problem**: a resumed session appears to have completed a tool call even though Emacs stopped before the tool result was saved.

**Cause**: recovery code fabricates a successful result or silently drops the unfinished assistant tool call.

**Solution**: compute recovery metadata during load. Keep the assistant tool call in history, mark missing `tool_call_id` values, and let the UI or next workflow decide how to recover.

### One Mutable Response Region Destroys Every Intermediate Step

**Problem**: after a run that used tools, the transcript shows the first question and the last answer, and everything the run did in between is gone.

**Cause**: the display allocated a single region for the whole assistant turn and redrew it on every event, deleting from the region start to the end marker each time. A run emits many things -- reasoning, prose before a tool call, the call, its result, more prose -- so each step overwrote the previous one and only the last survived. The session file was always complete; only the drawing threw work away.

**Solution**: render an append-only list of typed parts from `chat-transcript-plan`. Keep at most one replaceable region, for the streaming tail of the step currently arriving. Never reuse a region across steps.

### Session Messages Double As The Request Context

**Problem**: a display-only entry added to the session for the reader shows up in the next request, and the model starts imitating the client's own chrome.

**Cause**: `chat-session-messages` is both the stored record and the source of the request context. Anything appended for display is sent.

**Solution**: keep the record as the superset and project it. `chat-transcript-model-messages` drops the categories that exist for the reader alone. Every request path must go through it; there is one per display.

### Excluding On A Fallback Category Drops The System Prompt

**Problem**: after adding a request projection, the model loses its instructions and any recovered history.

**Cause**: unstamped `:system` messages fall back to the `system-detail` category, and `system-detail` is display-only. But an unstamped system message is a system prompt or a compaction summary, both of which the model must see.

**Solution**: exclude only on an **explicit** stamp. Read the raw metadata field, not the role-based fallback, when deciding what a request may carry.

### Message Metadata Comes Back As Strings

**Problem**: a symbol or number stored in message metadata fails a `eq` or arithmetic comparison after the session is reloaded.

**Cause**: `chat-session--message-metadata-to-json` stringifies symbols, and JSON numbers can decode as strings, so `'thinking` returns as `"thinking"`.

**Solution**: coerce on read. Never compare a metadata value against a symbol or number without normalizing it first.

### An `nreverse` In A Constructor Silently Shortens A Later Field

**Problem**: a plist reported an overflow of 14 tokens when the demoted text was over 19000, while the text itself was correct.

**Cause**: the constructor called `nreverse` on the accumulator for one field and then read the same variable for a later field. `nreverse` rewires the list in place, so the variable was left pointing at what had become the last cons -- a one-element list. Argument order made the corruption invisible: the field built first was right, the one built after it measured a fragment.

**Solution**: build each string once, into a `let`, before assembling the return value, and derive the counts from those strings. A test asserting only `(> overflow 0)` passes on the broken version; assert that the count equals the measurement of the text actually returned.

**Detection**: found by running the code against a real 20228-token instructions file and checking that kept plus overflow equalled the input. Unit tests with small fixtures did not surface it.

### A Character Cap On Instructions Drops The Last Rules

**Problem**: a long `AGENTS.md` loses the rules at its end, with no warning.

**Cause**: merged instructions were truncated at `chat-project-instructions-max-chars` by taking a prefix, so whatever sat past that offset disappeared. Rule files put important material at the end as often as anywhere else.

**Solution**: apply the cap to the compactable part only, and exempt declared resident spans. Over-long history should be summarized, which keeps a trace, rather than cut, which does not.

### A Budget Countdown Makes A Run Quit Early

**Problem**: telling the model how many steps remain makes it abandon tasks it was close to finishing.

**Cause**: a shrinking budget is read as "produce a final answer immediately", so the run discards work in progress to get something out.

**Solution**: state that running out is survivable in the same breath as the count -- the user can open another round that continues from the summary -- and stay silent while there is comfortable room left. Withdraw tools on the final step instead of asking the model not to call them.

---

## File Tools and Security

### UTF-8 Writes Can Trigger Interactive Prompts

**Problem**: writing logs or output can trigger a coding system selection prompt.

**Cause**: the write path relies on implicit encoding choice.

**Solution**: bind `coding-system-for-write` explicitly.

```elisp
(let ((coding-system-for-write 'utf-8))
  (write-region ...))
```

### Symlink Paths Can Escape Allowed Roots

**Problem**: a lexical prefix check can treat a symlink under an allowed directory as safe even when it points outside that root.

**Cause**: `expand-file-name` normalizes text paths but does not validate the resolved filesystem target.

**Solution**: normalize target paths and allowed roots through real path resolution.
For paths that do not exist yet resolve the nearest existing ancestor first.

```elisp
(let* ((ancestor (chat-files--existing-ancestor expanded))
       (ancestor-truename (file-truename ancestor))
       (relative (file-relative-name expanded ancestor)))
  (expand-file-name relative ancestor-truename))
```

### JSON Patch Arguments Lose Keyword Keys

**Problem**: `files_patch` can receive decoded JSON alists while the patch engine expects plist keys like `:search`.

**Cause**: nested JSON objects do not preserve plist structure after decoding.

**Solution**: normalize each patch object before applying it.

```elisp
(list :search (or (cdr (assoc 'search patch))
                  (cdr (assoc "search" patch)))
      :replace (or (cdr (assoc 'replace patch))
                   (cdr (assoc "replace" patch))))
```

### Apply Patch Input Must Keep Full Envelope

**Problem**: `apply_patch` can fail immediately on otherwise plausible patch text with a missing begin or end marker.

**Cause**: the patch parser accepts only the Codex envelope format and now explicitly requires both `*** Begin Patch` and `*** End Patch`.

**Solution**: always send the full envelope and keep `*** Move to:` inside an `*** Update File:` block.

```text
*** Begin Patch
*** Update File: path/to/file
@@
-old line
+new line
*** End Patch
```

### Default File Access Can Be Too Broad

**Problem**: using the home directory as the default allowed root gives the AI more read and write scope than necessary.

**Cause**: permissive defaults were convenient for early prototyping.

**Solution**: prefer the current project directory plus temporary directories as the default baseline.

```elisp
'("./" "/tmp/" "/var/tmp/")
```

---

## Tool Calling and Tool Forging

### Prompt Parse Execute Drift

**Problem**: tool calling fails even when the model returns a JSON object.

**Cause**: the system prompt format, response parser, and executor argument mapping drift apart.

**Solution**: keep one formal contract across all three layers.
Use a single `function_call` object.
Parse both bare JSON and fenced JSON.
Map arguments by declared parameter names instead of hardcoded `input`.

### Built In Tools Can Be Overridden By Saved Copies

**Problem**: `shell_execute` can show wrong argument names or fail with `Tool not compiled`.

**Cause**: a saved tool with the same id can overwrite the in memory built in registration.

**Solution**: load saved tools first and then register built in tools.
Do not persist tools that only have an in memory compiled function and no source body.

### Built In Tools Must Be Explicitly Active

**Problem**: a built in tool appears in the prompt but fails with `Tool is not active`.

**Cause**: `chat-forged-tool` defaults to inactive unless `:is-active t` is set.

**Solution**: mark built in tools active during registration and cover that path with a regression test.

### Tool Results Must Reenter The Conversation

**Problem**: the model repeats the same command instead of answering after a tool succeeds.

**Cause**: tool results are stored in metadata only and do not reenter the visible conversation history.

**Solution**: feed tool results back as `:tool` messages with `tool_call_id`. Render readable summaries in UI surfaces without rebundling them into new assistant history.

### Tool Parameter Schemas Must Be Real JSON Objects

**Problem**: native provider tool calling advertises `input` for zero-argument tools or reloads generated tools without their declared parameters.

**Cause**: fallback schemas and forged-tool persistence used implicit plist/list JSON encoding instead of explicit object shapes.

**Solution**: encode zero-argument tools as an empty object schema with empty `required`, convert parameter plists to JSON object alists before saving them, and enforce required fields, types, enumerations, and unknown-field rejection again at runtime.

### Session Disabled Tools Must Not Execute Directly

**Problem**: a tool hidden from the provider still runs if a direct tool call reaches the executor.

**Cause**: provider advertisement and direct execution used separate availability paths.

**Solution**: check `chat-session-tool-config` in both paths. Provider tool lists and `chat-tool-caller-execute` must use the same enabled/disabled overlay.

### Permission Metadata Must Enforce Approval

**Problem**: a newly registered write, outbound, personal, or network tool executes without prompting even though its event displays sensitivity and effects.

**Cause**: approval checks use a fixed tool-id list while treating permission metadata as display-only data.

**Solution**: derive the approval requirement from tool ids, sensitivity, effects, and call-specific predicates through one shared gate. Use dynamic predicates when only some targets, such as opted-in out-of-project buffers, require approval.

### Plugin Resources Must Roll Back On Stop

**Problem**: stopping a plugin leaves its tools, hooks, or services available in later sessions.

**Cause**: setup registered global Emacs resources without owner tracking.

**Solution**: register plugin-owned tools, services, and hooks through one newest-first ownership stack. Roll it back across resource types, restore replaced values, and put cleanup in the teardown unwind path so teardown failures cannot leak resources.

### User Plugins Must Register Before Startup

**Problem**: an explicitly enabled user plugin is loaded but never becomes active.

**Cause**: enabled plugins are started before their user files define and register them.

**Solution**: when user plugin loading is explicitly enabled, load only enabled NAME.el files first, then start enabled plugins and retry dependencies provided during setup.

### Mode Specific Tool Prompt Drift Reintroduces Wrong Protocols

**Problem**: a specialized mode like `code-mode` starts emitting XML style tool calls even though the shared chat flow already uses JSON `function_call`.

**Cause**: the mode builds its own system prompt and final response path instead of reusing the shared tool calling prompt and post processing contract.

**Solution**: mode specific request paths must build their system prompt through `chat-tool-caller-build-system-prompt` and finalize responses through `chat-tool-caller-process-response-data` plus the same follow up tool loop pattern.

### Shell Whitelists Fail If Execution Still Uses A Shell

**Problem**: a whitelist that validates only the first token can still be bypassed with pipes and command chaining.

**Cause**: `call-process-shell-command` hands the full string back to the shell for expansion.

**Solution**: reject shell metacharacters and execute argv directly rather than through a shell.

```elisp
(chat-command-gate-check command
                         :commands chat-tool-shell-allowed-commands
                         :separators nil)
```

### AI Tool Source Can Execute During Compilation

**Problem**: generated tool source can run arbitrary top level code while being compiled.

**Cause**: compiling unrestricted forms with `eval` allows wrapper forms like `progn` to execute immediately.

**Solution**: accept exactly one top level form and require that form to be a `lambda`.

```elisp
(unless (chat-tool-forge--lambda-form-p form)
  (error "Tool source must be exactly one lambda form"))
```

### Empty Source Tools Break Loading

**Problem**: loading a saved built in tool with no source body raises EOF or compile errors.

**Cause**: the loader treats trailing whitespace as source code.

**Solution**: trim loaded bodies and convert empty content to nil before attempting compilation.

### Plain Chat Repository Queries Can Hit Allowed Root Denials

**Problem**: asking repository questions from a plain chat session can produce `Access denied: path outside allowed directories` even though the files exist inside the current project.

**Cause**: plain chat sessions do not automatically carry a code session project root into the file tool allowlist, so recursive file tools only see the generic allowed directories.

**Solution**: start the conversation from code mode for repository work, or surface a clear hint when file-tool access fails so the user can switch to code mode instead of retrying shell commands.

### Unclosed JSON Fence Hangs The Parser

**Problem**: a truncated model response with an unclosed ```json fence hangs Emacs until C-g.

**Cause**: the fenced block extractor never advanced its scan position when no closing fence existed, so the same opener matched forever.

**Solution**: skip past the opener when no closing fence exists and cover truncated responses with a regression test.

### Truncated Responses Must Not Execute Tools

**Problem**: a length-truncated reply still runs a half-written tool call.

**Cause**: the loop treated any parsed `function_call` as executable, even when `finish_reason` was `length`.

**Solution**: refuse those calls, emit a `truncated` event, and return the synthetic truncated tool result so the model can re-issue a complete call.

### Tool-Only Provider Replies Look Like Parse Failures

**Problem**: a native `tool_calls` response with null `content` raises unexpected response format.

**Cause**: the OpenAI parser required a string `content` field.

**Solution**: treat JSON null content as an empty string and keep `tool_calls` on the transport result.

### Silent Tool Call Parse Failures End The Loop

**Problem**: a malformed tool call JSON is shown to the user as if it were a final answer and the tool loop stops.

**Cause**: parse failures were swallowed with no feedback signal to the model.

**Solution**: flag `:parse-error` in `chat-tool-caller-process-response-data` when content looks like a tool call attempt, and let both tool loops send a parse error follow-up so the model retries within the loop limit.

### Summarized Tool Results Blind The Model

**Problem**: code mode answered as if it had not read the file right after `files_read` succeeded.

**Cause**: tool follow-up messages carried only a 240 character whitespace-collapsed summary of each result.

**Solution**: feed real result content back up to `chat-tool-caller-result-max-chars` (default 8000) with an explicit omission marker beyond the cap.

### Two Authorization Points Make A Grant Apply To Half The Tools

**Problem**: a grant, or an approval mode, takes effect for one tool and not for another with the same name and the same arguments.

**Cause**: the synchronous and asynchronous execution paths each authorized separately, so which check ran depended on whether the tool happened to declare an `async-function`.

**Solution**: authorize once in `chat-tool-caller-execute-async` before the sync/async split. A second entry point that cannot reach the current authorization mechanism must refuse rather than fall back to an older one, because a fallback silently downgrades the policy instead of reporting that it could not be applied.

### An Approved Call Refused Again By The Tool's Own Gate

**Problem**: a command is approved — by a person, or by the guard under `guarded` — and the tool then refuses it because the program is not on an allowlist.

**Cause**: the tool's gate ran again after approval, so the approval decided nothing.

**Solution**: tools consult `chat-approval-command-consent-p`, which is true for `human`, `guard` and `dangerous`. The gate stays in place for callers that never went through approval. What this costs is that a wrong verdict skips the gate, which is why `chat-approval-guard-never-allow-p` runs before any request and is a predicate rather than a rule the guard weighs.

### A Struct Default Written At Twenty Construction Sites

**Problem**: a tool registered programmatically fails on execution with `Wrong type argument: number-or-marker-p, nil`, not on registration.

**Cause**: `usage-count` had no default in `chat-forged-tool`, and every one of the twenty construction sites wrote `:usage-count 0`; the site that forgot produced a tool that registered cleanly and died where the counter is incremented, a layer away from the omission.

**Solution**: give the slot its default in the `cl-defstruct`. A value every caller must supply identically is a default in the wrong place.

### `split-string-and-unquote` Mangles Single Quotes

**Problem**: model generated commands like `awk 'BEGIN{...}' file` fail with confusing errors and the model retries until the loop limit.

**Cause**: `split-string-and-unquote` does not group single quoted segments inside a word.

**Solution**: tokenize shell commands with `chat-tool-shell--split-command`, which handles single quotes, double quotes, and backslash escapes.

---

## Work Orchestration

### Cancelled Tasks Must Stay Cancelled

**Problem**: a background task briefly shows `cancelled` and then changes to `failed`.

**Cause**: the process sentinel runs after `delete-process` and overwrites the explicit cancellation state with the process exit status.

**Solution**: make the sentinel preserve an existing `cancelled` status and only derive `succeeded` or `failed` for tasks that were still running.

### Workflow Records Must Stay Declarative

**Problem**: a saved workflow can run arbitrary code when reloaded or resumed.

**Cause**: workflow steps are stored as executable Lisp forms instead of structured data.

**Solution**: store workflow steps as JSON-compatible records. Execution layers may interpret known step kinds later, but loading and cancellation must never evaluate record contents.

---

## MCP and Sub-agents

### MCP Responses Must Be Matched By JSON-RPC Id

**Problem**: a later MCP response is delivered to the wrong request or a request appears to time out even though the server answered.

**Cause**: stdio chunks can contain partial or multiple JSON lines, and responses may arrive out of order.

**Solution**: buffer incomplete lines, decode only complete JSONL records, and store responses by JSON-RPC `id`.

### Child Transcripts Must Not Leak Into Parent Context

**Problem**: a parent conversation grows rapidly or exposes low-level child-agent details after a sub-agent finishes.

**Cause**: the backend appends the child transcript directly into the parent session.

**Solution**: keep child work in an isolated child session or subprocess log, then return only a parent-safe summary and lifecycle metadata.

---

## Capability Packs

### Profiles Must Not Advertise The Global Tool Catalog

**Problem**: an office or daily session sees programming and file mutation tools that are unrelated to the current surface.

**Cause**: tools are registered globally but no session overlay is applied.

**Solution**: apply a capability profile with `chat-capability-apply-profile`; provider tool exposure and direct execution both honor the session's `:enabled-tools` overlay.

### Mail Tools Must Stay Draft-only

**Problem**: a daily task sends mail when the user expected only a prepared draft.

**Cause**: sending behavior was bundled with draft creation.

**Solution**: keep mail draft CRUD separate from sending. No mail-send tool should be registered by default, and any future sending capability must require explicit approval.

---

## Testing and Batch Mode

### `tests/run-tests.sh` Is Not The Canonical Runner

**Problem**: `bash tests/run-tests.sh` can fail before tests even start.

**Cause**: the shell wrapper can drift from the actual source loading sequence.

**Solution**: use `tests/run-tests.el` as the canonical entry.

```bash
emacs -Q -batch -l tests/run-tests.el -f ert-run-tests-batch-and-exit
```

### Source Files Must Load Before Test Files

**Problem**: tests fail because required source modules are missing from the load path or never loaded.

**Cause**: batch mode does not infer repository local load paths reliably, and this repository now keeps runtime modules under multiple `lisp/` subdirectories.

**Solution**: bootstrap one shared test path file, then load `chat.el` before loading test files. Reuse the same helper from prototypes and manual scripts instead of maintaining per script path logic.

```elisp
(load (expand-file-name "test-paths.el" test-dir) nil t)
(load (expand-file-name "../chat.el" test-dir) nil t)
```

### Idle Timer Tests Can Flake In Batch Mode

**Problem**: tests built around `run-with-idle-timer` pass interactively but fail or hang in batch mode.

**Cause**: batch test runs do not provide a reliable idle loop, so the timer callback may never fire even when the code under test is correct.

**Solution**: stub `run-with-idle-timer` and assert on the captured callback closure instead of waiting for real idle execution.

```elisp
(cl-letf (((symbol-function 'run-with-idle-timer)
           (lambda (&rest args)
             (setq callback (nth 2 args)))))
  (run-with-idle-timer 0.01 nil (lambda () ...)))
(funcall callback)
```

### Relative Paths In `--eval` Are Fragile

**Problem**: ad hoc batch commands often fail to find files when launched with `--eval`.

**Cause**: current working directory and file local assumptions are easy to drift.

**Solution**: prefer `-l` with explicit file paths or a checked shell wrapper.

### `chat-test-with-temp-dir` Does Not Move `default-directory`

**Problem**: two empty directories named `one` and `two` kept appearing in the repository root, recreated by every test run.

**Cause**: the macro binds `temp-dir` and a temporary state directory, but it does not rebind `default-directory`. A test that says `(expand-file-name "one")` therefore resolves against wherever the runner happens to be -- the repository root -- and writes there. The test still passed, so nothing pointed at it.

**Solution**: pass `temp-dir` explicitly to `expand-file-name`. Anything a test creates on disk has to name the directory it is created in.

```elisp
(chat-test-with-temp-dir
 (let ((first (expand-file-name "one" temp-dir)))   ; not (expand-file-name "one")
   ...))
```

### A Test That Errors Mid-Body Leaves State For Later Tests

**Problem**: a test that had passed for weeks started failing, and the real defect was in a new test that ran earlier in the alphabet.

**Cause**: a `let` unwinds on a signal, but a test that dies partway through has already done whatever it did before dying — registered something, created a session, written a file. The failure surfaces in whichever later test depends on that state, which is not where the fault is.

**Solution**: when an unrelated test starts failing, first check whether an earlier one is erroring rather than merely failing an assertion. Renaming the suspect so it sorts last is enough to confirm the direction in one run; `git stash` on the new test file confirms it in the other. Fix the erroring test, not the test that reported.

### External Process Calls Must Not Trust Ambient `default-directory`

**Problem**: tests or tooling that invoke `diff` or `process-file` can fail with `Setting current directory` even though the target files and commands are valid.

**Cause**: batch runners or temp HOME isolation can leave the current buffer with a stale `default-directory`, and child processes inherit that invalid path unless the caller overrides it.

**Solution**: bind `default-directory` to a known existing directory before every external process call, and set the batch runner `default-directory` explicitly before loading the package.

---

## Development Hygiene

### Complex Nested Forms Need Structural Checks

**Problem**: nested async callbacks and timers are easy to break with unmatched parentheses.

**Cause**: Lisp syntax is compact and callback heavy code can hide a missing close paren for a long time.

**Solution**: run `check-parens` before full test runs whenever deeply nested forms are edited.

### New Feature Work Needs Prototypes

**Problem**: provider integrations and protocol assumptions can be wrong even when the code looks plausible.

**Cause**: external APIs and transport details are easy to misread from docs alone.

**Solution**: validate the critical path with a small prototype in `tests/prototypes/` before formal integration.

### `string-match-p` Does Not Expose Match Data

**Problem**: `match-end` after a `string-match-p` call reads stale data from an unrelated earlier match, so position logic works only by luck.

**Cause**: `string-match-p` deliberately preserves the caller's match data instead of publishing its own.

**Solution**: use `string-match` when the code needs `match-beginning` or `match-end`, and keep `string-match-p` only for pure predicates.

### Stale `.elc` Files Shadow Source Fixes

**Problem**: a fresh source fix appears to do nothing in probes, and `byte-code-function-p` unexpectedly returns t for a just edited function.

**Cause**: stray `.elc` files next to the sources are loaded preferentially over newer `.el` files.

**Solution**: delete stray `.elc` files before investigating surprising behavior and keep them out of version control.

### String Literals Eat Backslash Alternation

**Problem**: a regex like `"finished\|exited"` written with a single backslash silently matches nothing, and the failure stays invisible until a guard or sentinel never fires.

**Cause**: in Emacs Lisp string literals `\|` is not an escape sequence, so the backslash is dropped and the regex engine sees a literal `|` instead of alternation. Alternation in a string literal needs `\\|`.

**Solution**: write `\\|` inside string literals, and when a `string-match-p` guard behaves like dead code, suspect the string first. Three instances of this class were fixed in one week: the `!cd` guard, the tool-call attempt heuristic, and the stream sentinel completion check whose failure also leaked stream buffers.

### Stderr Buffers Collect Sentinel Status Lines

**Problem**: subprocess results captured from a `:stderr` buffer contain a trailing `Process <name> stderr finished` line that was never written by the command.

**Cause**: Emacs attaches a default sentinel to the stderr pseudo process, and that sentinel appends a status line to the buffer. The process name may also carry a `<N>` suffix when instances overlap.

**Solution**: strip the status line when reading the buffer, allowing an optional `<N>` suffix and trailing newline, or install a no-op sentinel.

## Quick Reference

| Area | Rule |
|------|------|
| JSON requests | use alists and vectors |
| Async I/O | do not block the Emacs main loop |
| File safety | resolve real paths not just lexical paths |
| Shell safety | validate argv and avoid shell expansion |
| Tool forging | require approval and a single top level lambda |
| Tests | use `tests/run-tests.el` as the canonical entry |

### Stream Debug Logs Must Be Redacted

**Problem**: streaming request debug logs can leak bearer tokens or full request payloads.

**Cause**: logging raw curl arguments or raw request bodies exposes secrets and user content.

**Solution**: log only request metadata and use explicit redaction for authorization headers and payload size.

### Async Tool Follow Up Needs Full Argument Arity

**Problem**: tool loop follow up requests can fail with wrong number of arguments when callback parameters drift.

**Cause**: nested async calls are easy to mis-parenthesize and silently change how success error and options are passed.

**Solution**: keep the `chat-llm-request-async` call in a flat structure and add a regression test that requires the full async signature.

### Streaming Setup Should Use A Straight Branch

**Problem**: stream startup code can become hard to reason about and accidentally mix success and failure handling.

**Cause**: process creation validation sentinel installation and finalization are all nested in one callback heavy block.

**Solution**: keep the startup flow linear, validate the returned process first, then install the sentinel in a separate obvious step.

### Async Follow Up Must Return To The UI Buffer

**Problem**: a follow up request can crash with `Wrong type argument: integer-or-marker-p, nil` after a tool call completes.

**Cause**: async callbacks and sentinels run in request buffers or process contexts, but the code still tries to touch buffer local markers from the original UI buffer.

**Solution**: capture the target UI buffer before starting async follow up work and wrap later marker or rendering updates in `with-current-buffer` guarded by `buffer-live-p`.

### Inline Tool JSON Must Be Removed From Display Text

**Problem**: the assistant can visibly print raw `{"function_call": ...}` JSON in the chat area even though the tool call was already parsed and executed.

**Cause**: the parser can recognize inline JSON fragments for execution, but display text cleanup only removes fenced JSON blocks or responses that are pure JSON.

**Solution**: extract balanced inline JSON fragments, validate them as tool calls, and strip those exact fragments from user facing content before rendering or persistence.

### Code Mode Tool Access Must Inherit The Active Project Root

**Problem**: `code-mode` can get stuck in repeated `Access denied: path outside allowed directories` errors when analyzing a project outside the chat.el workspace.

**Cause**: generic file tools only see the global allowed directory list unless the active code session project root is injected into the execution context.

**Solution**: derive the effective tool access roots from the current `code-mode` session and include its project root for file validation and shell working directory setup.

### Kimi Code Async Follow Up Needs Curl Transport

**Problem**: Kimi Code can accept the streaming request but reject the tool follow up async request with HTTP 403.

**Cause**: the `url.el` async transport is not always compatible with Kimi Code agent style request requirements even when the same payload works through curl.

**Solution**: route Kimi Code async follow up requests through the curl based async transport so the non streaming request path matches the proven streaming transport behavior.

### Debug Logging Should Not Flood The Minibuffer

**Problem**: large request bodies and tool results can spill into the echo area and make the UI feel unsafe or broken.

**Cause**: the logger writes to the log file and also mirrors every line to the minibuffer with `message`.

**Solution**: keep persistent logging in the log file and make minibuffer echo opt in for debugging instead of the default behavior.

### Tool Loop Limit Must Not Render Raw JSON As The Final Answer

**Problem**: when automatic tool follow up stops at the safety limit the buffer can appear stuck on the last raw tool call instead of a readable status.

**Cause**: the final processed payload still contains a tool call JSON blob, and the UI renders it as ordinary assistant text when no synthesis turn is performed.

**Solution**: mark the loop limit case explicitly, suppress raw tool JSON from the rendered content, and show a short safety limit notice plus the tool summary instead.

### Safe Readonly Shell Navigation Should Not Depend On Approval Spam

**Problem**: harmless exploration commands like `pwd`, `ls`, `find`, or `cd DIR && ls` can still trap the user in repeated approval prompts or command rejections.

**Cause**: the shell tool may know a command is readonly, but the auto approval whitelist is empty or the executor cannot interpret a safe `cd` prefix without invoking a shell.

**Solution**: ship builtin readonly whitelist patterns and support a parsed `cd <allowed-dir> && <readonly command>` form that validates the directory and executes the follow up command with `process-file`.

### Long Running Agent Work Needs Visible Buffer Status

**Problem**: users cannot tell whether the agent is still working, has completed, has failed, or was cancelled.

**Cause**: request state only exists in internal handles and process objects, while the chat buffer lacks a dedicated status channel.

**Solution**: expose an explicit buffer visible status indicator with clear running, success, failed, cancelled, and stopped states, and update it at each major request phase.

### Stale Bytecode Must Not Override Newer Source

**Problem**: Emacs can keep running outdated behavior even after source fixes are applied.

**Cause**: older `.elc` artifacts may still be loaded before newer `.el` source when `load-prefer-newer` is not enabled or stale bytecode is left behind.

**Solution**: prefer newer source at package entry, and remove stale `.elc` artifacts when they no longer match the current source tree.

### Session Compaction Must Respect Tool Call Boundaries

**Problem**: a compacted transcript can start with a tool result whose
assistant tool call was removed.

**Cause**: choosing a cut point solely from token count can split one
assistant/tool protocol unit.

**Solution**: move the cut backward until no tool call remains open, then
persist summary coverage through the last fully covered message id.

### Durable JSONL Updates Cannot Append In Place Safely

**Problem**: a crash during an append can leave another partial record
even after an older partial tail was repaired.

**Cause**: in-place append exposes the destination while bytes are still
being written.

**Solution**: build the complete replacement in a same-directory
temporary file, flush it, and rename it atomically. Encode message
metadata as JSON objects so tool-call ids keep their key/value shape.

### Workflow Resume Must Persist Before Continuing

**Problem**: a restarted workflow repeats an already completed side
effect or skips a failed step.

**Cause**: advancing an in-memory loop before saving the step result and
next index makes process interruption ambiguous.

**Solution**: persist each result and transition before dispatching the
next step. Keep the index unchanged on failure, require an explicit
decision at approval checkpoints, and execute tools through the normal
session overlay and approval path.

### MCP Discovery Must Not Connect During Startup

**Problem**: loading chat.el hangs or launches untrusted server processes
before a conversation needs them.

**Cause**: treating configured MCP definitions as eager connections mixes
configuration with execution.

**Solution**: create inert clients at startup and connect only through an
approved tool call. After initialize and tool discovery, register
namespaced schemas so normal tool overlays, effects, cancellation, and
request diagnostics apply.

### Nested Agents Must Not Leak Child Transcripts

**Problem**: parent context grows unpredictably or receives internal child
tool chatter.

**Cause**: appending every nested event directly to the parent transcript.

**Solution**: use an isolated child session with a copied capability
overlay, bounded depth and steps, and return only the final summary as the
parent tool result. Keep child messages available through their own
session for diagnostics.

### Capability Profiles Must Filter Provider Schemas

**Problem**: a model sees tools outside the selected programming, office,
or daily profile even though execution later rejects them.

**Cause**: applying the session overlay only in the executor leaves an
incorrect capability contract in the provider request.

**Solution**: filter the forged-tool registry with the session overlay
while generating provider schemas, then enforce the same overlay again at
execution. Keep personal, correspondence, network, write, and outbound
metadata on every profile tool so profile selection never bypasses
approval.

### A Prompt Block Can Be Larger Than Its Own Share

**Problem**: on a small-window model the system prompt crowds out the
conversation, and the region doing it is the one meant to help recover
lost history.

**Cause**: writing a prompt block against a large window and never
measuring it against the share it lands in. The storage block is 433
tokens; the system prompt share of an 8K window is 278.

**Solution**: measure the assembled block against
`chat-context-allocation-tokens` for its category and fall back to a short
form when it does not fit. Keep the paths and tool names in the short
form and drop the reasoning — a block trimmed to advice is worse than
absent, since the run still pays for it and still cannot act on it.

### Advertising A Writable Path The Tools Refuse

**Problem**: the model repeatedly tries to write scratch files and reports
permission failures it cannot explain.

**Cause**: naming a directory in the system prompt without adding it to
`chat-files-allowed-directories`. The prompt and the enforcement layer
disagreed, and only the prompt was visible to the model.

**Solution**: when a prompt block grants access, the corresponding policy
list has to grant it too. Cover it with a test that reads the policy
rather than the prompt.

### Tool Arguments Arrive Positionally, Not As A Plist

**Problem**: a tool receives values in the wrong slots and filters on
nonsense, with no error raised.

**Cause**: writing the implementation as `(&rest args)` and reading a
plist. `chat-tool-caller--arguments-to-argv` converts a call's arguments
into an argv list ordered by the tool's declared `:parameters`.

**Solution**: give the function positional parameters in exactly the
declared order, convert to a plist inside it, and test the tool through
its real entry point so a reordering of `:parameters` fails a test rather
than silently mis-binding.

### Injecting A Growing Store Into Every Request

**Problem**: context available for work shrinks over weeks of use with no
change in configuration.

**Cause**: a store that accumulates — notes, memory, discovered facts —
being injected whole into the fixed region of every prompt. It grows
monotonically while the window does not.

**Solution**: put an index in the prompt and read bodies on demand. An
index costs about a line per entry and stays useful at a hundred of them.
Cap the index too, since it also appears in every request.

### Merging Two Keymaps Resolves A Collision Silently

**Problem**: after two modes become one, a documented key runs the wrong
command, and nothing reported a conflict.

**Cause**: `define-key` on the same key overwrites. Two maps that each
bound `C-c C-a` to a different command merge into one that binds it to
whichever was defined last. The other command becomes unreachable, and
the map cannot show what it lost.

**Solution**: assert the keymap and the help text agree in both
directions — every key the help names is bound, and every key that is
bound is documented. The conflict exists in the documentation before it
exists in the code, so the check catches it before the merge.

### A Reachability Pass Keyed On A Prefix Reports Live Code As Dead

**Problem**: a function still called from its own file is deleted as
unreachable.

**Cause**: walking the call graph from definitions matching one prefix.
A file usually also holds entry points that do not match — commands named
for what they do rather than for the module — and their callees look
unreachable.

**Solution**: treat everything in the file that is not a matched
definition as a root as well. Blank out the matched definitions and take
any remaining mention as a call. Never delete on a report alone when the
report can only prove absence of a reference it knows how to look for.

### A Test That Binds The Same Stale Variable Its Target Reads

**Problem**: a feature is broken in the running program while its test
passes. Removing a buffer-local variable left `chat-tool-caller.el`
reading it to find the project root, so tools lost the root for every
coding session — and the test still passed, because the test set that
same variable.

**Cause**: the test reached past the public way of establishing state and
bound the internal variable directly. A test written that way is
consistent with the code under test by construction: both refer to the
same name, and both are wrong together.

**Solution**: set up state the way the program does — here, the session
variable the surface binds — so a rename breaks the test. When a
capability is being checked rather than a buffer kind, test the negative
too: a session without the capability must not get the widened root.

### Docs Name Commands That No Longer Exist

**Problem**: a user runs an `M-x` command from the documentation and gets
`No match`.

**Cause**: renaming a command updates the callers, because they fail to
compile otherwise. Documentation does not fail to compile.

**Solution**: read the docs in a test and require every `M-x` name to be
a command. Allow an explicit list of names belonging to Emacs or to
packages the suite does not load; require everything shipped here to
exist. Count what was checked, so a regexp that stops matching fails
rather than passes.

### Every Assertion Passed And The Output Was Unreadable

**Problem**: twenty tests covered the transcript display and passed, and
the first look at real rendered output showed a raw JSON blob in the
middle of a step and tool arguments printed as `(("path" . "config.el"))`.

**Cause**: the assertions checked the properties that were thought of.
`chat-ui-transcript-never-shows-the-tool-call-as-prose` searched the whole
visible region for the function-call payload and passed, because the
answer did not contain it — while the interim step above it still did.
Nothing asserted on the argument text at all, because printing a Lisp
object is not a bug until someone reads it.

**Solution**: render a realistic turn and read it, before and after
believing the suite. A display's requirement is that a person can read it,
and that is not decomposable into the string searches one happens to
write. When reading finds something, add the assertion then — the reading
is what finds it.

### A Marker Whose Insertion Type Decides Which Region Owns Text

**Problem**: text arriving at the boundary between committed history and
the live tail was drawn inside the wrong one, so a committed step could be
overwritten by the next chunk.

**Cause**: a marker with insertion type t advances past text inserted at
its position; one with nil stays put and the text lands after it. The
boundary marker had the type that made arriving text belong to history.

**Solution**: set the boundary marker's insertion type from the invariant
you want, and write it down where the marker is defined. Here: anything
written past the committed history is by definition the tail, so
`chat-ui--live-start` has insertion type nil.

### A Batch Script Requires The UI And Gets An Unknown Provider

**Problem**: a one-off rendering script failed with `Unknown provider:
kimi`, while the whole suite passed against the same code.

**Cause**: the provider registry is populated by loading `chat.el`.
Requiring `chat-ui` pulls in the LLM layer but not the registration, so
any session whose model is a real provider fails on lookup.

**Solution**: `(require 'chat)` in scratch scripts. Cheap, and it makes
the script exercise the same load order a user gets.

### A Documented Key Bound To A Different Event Of The Same Name

**Problem**: the help said `S-RET` inserts a newline, `<S-return>` was
bound, and terminal users had no way to type a second line.

**Cause**: they are not the same key. `(kbd "S-RET")` is `[33554445]`,
a shift-modified `C-m` — what a terminal sends. `(kbd "<S-return>")` is
`[S-return]`, the GUI function key. The consistency test that would have
caught it extracted only `C-c ...` sequences from the help, so every
unprefixed key went unchecked in both directions.

**Solution**: bind both, and extract unprefixed keys from the help too.
Broadening that regexp immediately found `TAB` documented and bound to
nothing at all. When a consistency test has a blind spot, the bugs
collect inside it.

### Tab-Padded Output Rendered At The Wrong Tab Width

**Problem**: `ls` columns were ragged in the chat buffer while `ls -l`
looked fine.

**Cause**: BSD `ls -C` pads columns with tab characters and counts on
stops every eight columns. The buffer's `tab-width` was 4, a common
default. `ls -l` pads with spaces, so it was immune.

**Solution**: expand the tabs where the text is displayed, against the
width that produced them, rather than changing the buffer's `tab-width`
to suit one kind of output. Count columns with `string-width` so CJK
output lands correctly, and copy text in runs rather than character by
character — `char-to-string` drops the text properties that carry colour.

### Colour Applied As `font-lock-face` In A Buffer Without Font Lock

**Problem**: ANSI colour was converted correctly and none of it appeared.

**Cause**: `ansi-color-apply` marks colour with `font-lock-face`, which
the display honours only where Font Lock is enabled. A chat buffer is not
font-locked, so the property was present and inert.

**Solution**: promote `font-lock-face` to `face` after applying. And when
adding a base face over coloured text, append it rather than setting it,
or it replaces the colour it was meant to sit behind.

### A Path Rule That Owns The Character A Command Needs

**Problem**: typing `/` to see the command list listed the root directory.

**Cause**: the path predicate accepted any token starting with `/`, which
is the right reading of that character everywhere except the one position
where it opens a command.

**Solution**: decide by position, not just by the character. A token that
starts at the input marker and has no second slash is a command; anything
else is a path. Have both completion functions ask the same question so
they cannot both claim the same token.

### The Help Was Unreachable From The Place You Would Ask For It

**Problem**: `/help` fell through to the model as ordinary text and came
back as a tool error.

**Cause**: help had a key binding and no command name. Someone who cannot
tell what the surface does has not found the key binding yet — that is
what being stuck means.

**Solution**: make the obvious name work, and let it run while a response
is in flight, since being stuck is not less true while the model is
talking. Then test that every name the help promises reaches a handler.

### A One-Way Consistency Test Is A Blind Spot With A Passing Badge

**Problem**: four slash commands worked and appeared nowhere in the help,
with a slash-command consistency test passing the whole time.

**Cause**: it checked that every documented name reached a handler, and
not that every handler was documented. The keymap tests had both
directions; nobody noticed the slash tests had one, because the test that
existed passed.

**Solution**: write both directions when you write either, and check that
the pair is symmetric. Both directions of this one failed on their first
run — one caught undocumented commands, and the other caught `/help`
being dropped from the help while the help was being restructured.

### Advice That Is True Somewhere Else

**Problem**: the help ended with "press RET to send" and RET did nothing.

**Cause**: the line describes the chat buffer and was being read in
`*Chat Help*`, where `view-mode` owns RET and scrolls with it. Perfectly
true text, shown in the one place it is false.

**Solution**: text that names a key has to be written for the buffer it
appears in. Say which buffer, and give the help buffer its own footer
about its own keys.

### Four Names For The Aside And None For The Conversation

**Problem**: a user asked what `/ask` and `/question` differed in. Nothing
— they were separate table entries sharing a handler. With `/?` and the
`?text` prefix, four names reached the ephemeral one-shot ask, while the
recorded multi-step conversation that is the whole point of the surface
could only be reached by typing with no prefix at all.

**Cause**: aliases added as table entries rather than as aliases. Each one
was a one-line change that looked harmless, and nothing counted them.
Meanwhile the main path needed no name to work, so it never got one — and
without a name it could not be defaulted to, documented as a command, or
returned to.

**Solution**: one entry per command, everything else an alias through one
mechanism. Then name the thing that works by default, because "it is
already what plain input does" is a description of a behaviour that
deserves a name.

Reassigning the surplus names was the first attempt and was not enough:
both read equally well as either command, so whichever one they pointed
at, the reader still had to remember which. They were deleted instead. A
name that has to be memorized to be told apart from its neighbour earns
nothing, and deleting one is cheap where an unrecognized command is
ordinary text rather than an error.

### A Sticky Mode With No Way Back Except A Word You Have To Remember

**Problem**: after one `!ls`, every plain line went to the shell. An
explicit question worked and changed nothing, and the next line went to
the shell again. Only `/auto off` got out.

**Cause**: exactly one command could claim plain input and nothing could
release it. The design had thought carefully about which commands were
safe to make sticky and not at all about what the default was when none of
them were.

**Solution**: give the baseline a name, so releasing a claim is returning
to a command rather than clearing a variable. Then let commands declare
`reset` as well as `sticky`, and put the current holder in the input
prompt — the status line is at the top of a buffer that scrolls and the
cursor is at the bottom.

### An Alias List Built With `push` Reverses Its Own Priority

**Problem**: two Chinese names both meant `/send`, and completion offered
the second one.

**Cause**: registration used `setf` on `alist-get`, which prepends for a
key that is not present. Declaration order became reverse order, so the
last synonym declared became the primary name.

**Solution**: append for a new key and replace in place for an existing
one, and test that the first alias declared is the one offered. The
shipped catalog looked fine either way; only a two-synonym command showed
it.

### A Marker Found By Searching For Its Own Translated Text

**Problem**: none yet — caught while translating.

**Cause**: the "asking the model" indicator was removed by searching the
buffer for the literal `🤖 Asking AI...`. Translate that string and the
search stops finding it, leaving the note on screen underneath the answer
it was supposed to be replaced by.

**Solution**: mark it with a text property and find it by property. Any
literal used both to write and to find text is a latent version of this
bug, and localization is what triggers it.

### Two Halves Of One Pair, Each With Its Own Fallback

**Problem**: an old session refused to send at all. The provider answered
`tool_call_id is not found`, so nothing could be asked of a conversation
that had once used tools.

**Cause**: a tool call id has to be written twice into a request — once in
the assistant's `tool_calls` and once as the `tool_call_id` of the result
— and two different functions supplied it. Both had a fallback for calls
that arrived without an id, and the fallbacks disagreed: the call side
used the tool name, the result side used the position. A turn parsed out
of the reply text has no provider id, so both fallbacks fired, and the
request advertised `files_read` while referring to `call-1`. Five places
in the tree invented ids, in two incompatible schemes.

**Solution**: one function answers the question, and both sides call it.
A fallback that is reached from a single place cannot disagree with
itself. Two further notes: the name is not available as a fallback,
because a turn that reads a file in chunks calls one tool repeatedly and
all the chunks would answer to one id; and the fallback is qualified by
the message, because a bare position would make every turn claim `call-1`.
Assert that the two sides *agree*, never what the id says — the test that
existed pinned the literal `call-1` on the path that worked, which is
exactly how the disagreement stayed hidden.

### Ids Minted Before Duplicates Are Dropped Defeat The Dedup

**Problem**: none shipped — caught while fixing the above.

**Cause**: the parser drops repeated calls with `delete-dups`, which
compares whole plists. Minting an id during extraction makes every call
unique, so a call the model emitted twice would run twice.

**Solution**: assign ids after the list settles. Anything that gives an
element its own identity has to happen downstream of anything that
compares elements for equality.

### A Round Trip Verified In Only One Direction

**Problem**: every message in a reopened session was dated January 1970.

**Cause**: the loader wrapped `parse-time-string` in `decode-time`.
`parse-time-string` already returns a decoded time, and `decode-time`
reads its argument as a *time value*, so the leading seconds and minutes
were taken for the halves of an epoch offset. Writing was correct, which
is why the tests passed: they built a session and checked what came back
within one process, and nothing asserted a date. The wrong date was then
written back over the right one, so the damage was permanent and grew
with every reopen.

**Solution**: `encode-time` the parsed list, and test the reopen rather
than the object — save, load, and compare against the value that went in.
Test the second reopen too: a loader that corrupts and re-saves needs one
cycle to lose the data and another to look stable.

### A Character Class Named After The Examples That Prompted It

**Problem**: `/ｈｅｌｐ` was not a command. The slash was understood and
the name was not, so the line went to the model as text.

**Cause**: the fold from fullwidth to ASCII was a hand-listed table of
punctuation, because punctuation was what the first report was about. But
an input method is not in fullwidth mode for the punctuation only — it
produces `／ｈｅｌｐ`, and the name is affected exactly as much as the
slash. The table could not have been right: it was a list of instances
where the real rule was a Unicode block.

**Solution**: map U+FF01–U+FF5E arithmetically, which subsumes the table
and covers letters and digits. When a fold, escape or normalization is
implemented as a list, check whether the list is standing in for a range —
and test a member of the range that is not in the list.

### Folding The Syntax Is Not Folding The Argument

**Problem**: `/auto ｃｍｄ` did nothing useful after the fold above was
widened. The command was found; its argument was not.

**Cause**: the parser deliberately does not fold arguments, because the
same position holds a shell body in `/cmd` and a prompt in `/send`, where a
fullwidth character may be exactly what was meant. That rule is right, and
it leaves a gap: some arguments are not data. `/auto` takes a command name,
`/drop` a keyword, `/model` an id, `/help` a topic — all compared against
fixed names.

**Solution**: the parser folds syntax; a handler folds an argument it
interprets. Guard both directions — a widening fold needs tests that the
data positions were *not* folded, or the next widening will quietly rewrite
what someone is sending.

### Unreachable Is Not Inert

**Problem**: a module no command could invoke was nevertheless creating
directories and writing two files on every startup — and, because the test
runner sets `default-directory` to the repository root, on every test run.

**Cause**: a top-level `(when (or (file-directory-p chat-wiki-root)
(bound-and-true-p chat-root-directory)) (chat-wiki-initialize))` at the end
of the file. The second condition was dead — that variable is defined
nowhere — so what remained was "initialize if a `wiki` directory happens to
exist next to wherever Emacs started", with the root itself computed from
`default-directory` at load time. Reviewing the module as dead code missed
it, because the question asked was whether anything called *in*, not
whether it did anything *on its own*.

**Solution**: no side effects at load time; let each writer ensure its own
directory. When auditing a module for reachability, grep its top level for
forms that run — the entry points are not the only way in.

### A Regexp That Cannot Match What It Is For

**Problem**: every wiki page's title and date silently fell back to the
filename, and a page containing nothing but headings counted as written.

**Cause**: `^---\s-*\n\(.*?\)\n---\s-*\n\(.*\)` for a YAML frontmatter
block. In an Emacs regexp `.` does not match a newline, so this only ever
matched frontmatter that fitted on one line. Real frontmatter has one key
per line, so it never matched at all: the parse reported "no frontmatter"
and handed the YAML back as part of the body. Both symptoms were downstream
and neither pointed here.

**Solution**: scan the block over lines rather than with one pattern.
Any regexp meant to span a multi-line construct needs a test with two
lines in it — one line is exactly the case that passes by accident.

### Deleting The Characters You Cannot Handle

**Problem**: two Chinese wiki pages could not coexist. Creating the second
one signalled that the file already existed.

**Cause**: the slug function ran `(replace-regexp-in-string "[^[:ascii:]]"
"" title)` before collapsing the rest. Every CJK title reduced to the empty
string, so all of them mapped to the same filename. Searching had the
matching defect from the other direction: the query was split on
whitespace, and a Chinese sentence has none, so the whole question became
one token and was matched as a substring.

**Solution**: keep letters whatever script they are in — `[:alnum:]`
already matches Han, kana and hangul — and tokenize CJK one character at a
time. Watch the alternation when doing this: a class that matches letters
matches both scripts, so `[[:alnum:]]+` starting on Latin will swallow the
CJK that follows it. Test a mixed-script string, not just one of each.

### A Template That Fails Its Own Linter

**Problem**: a freshly created page was immediately reported as a stub with
broken links, on a wiki nobody had touched.

**Cause**: the templates emitted `Key takeaway 1` and `[[entity1]]` as
prompts to the author, and the lint flagged pages whose body matched
`TODO\|FIXME\|stub\|placeholder` and links whose targets did not exist. The
generator and the checker had each been written reasonably and never run
against each other.

**Solution**: emit empty sections and invent no links, and make the
emptiness check measure content — what is left after headings come off —
rather than search for words that legitimately appear in the subject
matter. When one part of a module generates what another part judges, test
the pair together.

### A Backslash Inside A Character Alternative

**Problem**: no wiki page ever had a backlink, no link was ever reported
broken, and no page was ever reported an orphan. The feature reported a
clean wiki because it found nothing at all.

**Cause**: the pattern for `[[Like This]]` was written
`"\\[\\[\\([^\\]]+\\)\\]\\]"`. A backslash is not an escape inside a
character alternative in an Emacs regexp, so `[^\]]` is not "not a
bracket" — it is "not a backslash", closed by the next bracket, followed
by a literal bracket. It matched no link that anyone would write. The
correct spelling puts the bracket first: `[^]]`.

**Solution**: fix the class, and note the failure mode rather than the
typo. Every symptom was an empty result, and an empty result from a
checker is indistinguishable from a clean bill of health. When a function
returns a list of problems, test that it finds a planted one — a test that
only asserts "no issues" passes just as well when the search is broken.

### match-string After A string-match That Failed

**Problem**: a page with no frontmatter got a title that was a fragment of
its own prose — `及为什么要`, five characters lifted out of the middle of a
sentence — instead of falling back to its filename.

**Cause**: the fallback was
`(or fm-title (progn (string-match "^# \\(.+\\)$" body) (match-string 1 body)) filename)`.
A failed `string-match` does not clear the match data, so `match-string`
returned a slice of `body` at offsets belonging to whatever string matched
last — here a line of YAML from the frontmatter parser.

**Solution**: `(and (string-match ...) (match-string ...))`. In Elisp,
match data is global and outlives the call that set it; never read it
without checking that the search succeeded. The symptom is distinctive:
a result of the right length taken from the wrong place, changing depending
on what ran before.

### The Rule Enforced At The Caller Instead Of The Door

**Problem**: pages created by the model had titles; pages created by any
other caller of `chat-wiki-create-page` had none, and read back as their
filenames.

**Cause**: `create-page` wrote caller-supplied content verbatim, adding
frontmatter only to pages it generated from a template. The "every page
has frontmatter" rule was implemented in the `wiki_write` tool — one
caller — so it held for the model and for nothing else.

**Solution**: put the invariant at the single point every page passes
through, and delete the caller's copy. When a rule is written at a call
site, ask what the other call sites do; if the answer is "violate it", the
rule is in the wrong place.

### Counting Characters Across Scripts

**Problem**: lint reported ordinary, fully written Chinese pages as having
"headings but no content".

**Cause**: the threshold was 40 characters of prose. A CJK character
carries roughly what a short word does, so 40 characters is a sentence in
English and a paragraph in Chinese — a Chinese page had to say two or three
times as much as an English one to pass.

**Solution**: count in units that mean the same thing in both — words for
alphabetic scripts, characters for CJK, which is what the tokenizer
already produced for search. A character count is not a length measure
when more than one script is in play.

### One Capability, Two Paths, And Only One Maintained

**Problem**: a module had `chat-wiki-query` with its own result buffer
alongside `/wiki search`, plus four `-interactive` wrappers whose only
caller was `M-x`. The two search paths formatted differently, and only one
of them got the fix when matching changed.

**Cause**: commands were added next to the functions they wrapped instead
of replacing them, so each capability accumulated an entry point per era
of the module.

**Solution**: delete the duplicate rather than keeping it for
compatibility nobody asked for. A wrapper whose only caller is `M-x`, and
whose behaviour a command already covers, is a second implementation to
keep in step. Check callers before assuming a public-looking function has
any.

### A Cond With No Final Clause, On An Event Stream

**Problem**: a reasoning model thought for a minute with the chat buffer
perfectly still, then painted its whole reply at once. No error anywhere,
and the transport log showed bytes arriving continuously the entire time.

**Cause**: the UI event handler was a `cond` with six branches and no `t`
clause, while the agent emitted seventeen event types. `stream-reasoning`
fell off the end and was discarded silently, and reasoning is where a
reasoning model spends its time.

**Solution**: a handler over someone else's event stream needs a
catch-all, and a test that reads both sides and fails when the sender
gains a type the receiver neither handles nor names. A dropped event has
no symptom of its own -- not an error, not a wrong value, just an absence
that looks exactly like a hang.

### A Field Named Two Ways On Sibling Events

**Problem**: reading `:content` from a reasoning event yielded nothing, on
every event, silently.

**Cause**: `stream-chunk` carries its accumulation as `:content` and its
delta as `:text`. `stream-reasoning`, emitted twelve lines away, carries
its accumulation as `:reasoning` and its delta as `:text`. Reaching for the
name the sibling uses returns nil rather than failing.

**Solution**: check the emit site rather than the neighbouring one. A plist
read for a key that is not there is indistinguishable from a key holding
an empty value, so nothing about the mistake is loud.

### A Defcustom Under A Defvar Of The Same Name

**Problem**: a flag had a `defvar` near the top of a file and a
`defcustom` near the bottom. Changing the `defcustom` default had no
effect, and `customize` edited a setting the code did not read.

**Cause**: `custom-declare-variable` leaves an already-bound variable
alone, so the `defvar` won. Both defaults were the same value, which is why
it went unnoticed for as long as it did.

**Solution**: one declaration, and make it the customizable one, placed
where the earliest reference can see it. Note that removing the `defvar`
moves the declaration below its first use, which the byte-compiler will
report as a free variable -- move the `defcustom` up rather than leaving
the pair.

### A Progress Message That Never Changes

**Problem**: twenty seconds between starting the request and the first
token, with `Streaming, waiting for first chunk` on screen throughout, and
users concluding the program had hung.

**Cause**: the message was accurate and static. A reader cannot tell a
working request from a dead one by looking at text that does not move.

**Solution**: put a number in it that changes. The surface already
refreshed once a second, so counting the seconds cost nothing and turned
the same message into evidence the request is alive.

### A Typed Record Model With No Writer

**Problem**: the transcript carried turn, step, category, work and
reasoning, with fold styles and faces keyed to them, and the display still
had to infer everything from message roles.

**Cause**: the stamping API was called only from tests. Production built
its messages plain, so the model existed and nothing populated it.

**Solution**: grep for callers before trusting that a model is in use.
An API used only by its own tests is worse than a missing one -- a missing
one is visibly missing, while this made the codebase look finished.

### A Batch Window Reports Its End As The End Of The Buffer

**Problem**: a test that arranged a window at the top of a long buffer and
asserted that live output did not scroll it failed: the window had
followed to the bottom.

**Cause**: under `-batch` there is no real display, so `window-end`
returns `point-max` whatever the buffer holds. Every window looks like it
is at the bottom, and no arrangement of one can tell the two cases apart.

**Solution**: extract the decision into a function taking the positions as
arguments and test the rule. Worth doing regardless -- the rule was the
whole of a user-facing promise and it was three lines buried in a loop.

### An Editable Prompt That Nothing Ever Redraws

**Problem**: the input prompt disappeared and never came back. Reopening
the session was the only way to get it, so a session could be left with
no prompt for as long as it stayed open.

**Cause**: two omissions that only matter together. The prompt was plain
unprotected text in the region the reader types in, so an ordinary edit
could take it; and nothing on the send path drew it, so once taken it was
taken for good. Either alone is survivable. Together they turn a
keystroke into a permanent broken state, and the trigger is impossible to
find afterwards because any edit will do.

**Solution**: both halves. The prompt is read-only, front-sticky and
rear-nonsticky, as every shell in Emacs concluded; and it is checked and
redrawn on every send, which is free when it is already right. Do not
look for the trigger when the real defect is that nothing repairs it.

### Recovery That Measures Instead Of Marking

**Problem**: finding a drawn prompt by counting back from the input marker
works on an intact prompt and fails on a half-eaten one -- the only case
recovery is for.

**Solution**: mark it with its own text property and find it by that. A
recovery path tested only against undamaged input is untested.

### `save-excursion` Restores Point On The Wrong Side Of A Rewrite

**Problem**: every time a command claimed or released plain input, the
cursor ended up in front of the prompt instead of after it, and what was
typed next went in front of it too.

**Cause**: `save-excursion` restores point through a marker. A marker at
the start of a region that is deleted and then rewritten does not know
which side of the new text it belongs on, and comes back before it. The
prompt is exactly that region, and point sits exactly at its start.

**Solution**: for point inside an area being rewritten, record the offset
into the area and restore it by arithmetic. `save-excursion` is for point
somewhere the edit does not reach.

### No Paint Between The Keystroke And The Work

**Problem**: sending felt like it waited for the request to be
established: the question appeared at the same moment the answer started
arriving, not when it was typed.

**Cause**: nothing painted a frame between the two. The question was in
the buffer and the input was cleared, but a command's buffer changes do
not reach the screen until the command returns, and the command went on
to prepare and start the request. The live waiting line was worse: it was
drawn by a refresh timer a second out, so the first second had no
indicator at all.

**Solution**: draw the waiting state at the point the request is created,
not on the next tick, and `redisplay` once before the work. The complaint
was never about the milliseconds; it was about the frame that was never
drawn.

Measured afterwards in the session that complained, 28ms stand between
RET and that paint. What follows it is another 245ms to 291ms, every
send, and the reader feels that too -- their question is on screen but
the editor is dead until the request is away. So the paint fixes what the
reader sees, not what the command loop is doing, and the work after it
still has to be either cheap or off the loop.

### `redisplay` Is The Version That Might Not

**Problem**: after adding the paint above, sending still hitched. Not
every time, and not for long, but the frame plainly did not arrive with
the keystroke.

**Cause**: `(redisplay)` does nothing at all when input is pending. It
returns nil to say so, and nobody was reading the return value. A send is
exactly the moment something is likely to be queued -- a held key, an
autorepeat, a second RET behind the first -- so of all the paints in the
program, the one placed to rescue the send was the one most liable to be
skipped. `(redisplay t)` is the forced version.

**Solution**: `(redisplay t)` on any paint whose whole purpose is to
happen before slow work. Reserve the preemptible form for paints that are
merely nice to have, where losing one to pending input is the right
outcome. Asserted in the source rather than at runtime, because batch
mode never paints and reports no window worth painting into, so a test
that called it could not tell the two apart.

### A Wall-Clock Number Blames Whoever Was Running When The GC Landed

**Problem**: the send path timed at 3ms on one iteration and 400ms on the
next, with nothing different about the two. Instrumenting the callees
blamed a different function each time -- project instructions on one run,
the system prompt on another.

**Cause**: garbage collection, landing wherever it landed and billing
whichever function was running. `gcs-done` and `gc-elapsed` around the
path showed one collection every second or third iteration.

**Solution**: charge each phase for the collection that happened while it
ran. The timing line carries `[gc N, Mms]` on any phase that provoked
one, which is what separates a phase that did expensive work from a phase
that merely allocated past the threshold on everyone else's behalf. A
phase measured at 924ms once and 29ms every time after is the second
kind, and no amount of staring at its code will show that.

Measure `gcs-done`, `gc-elapsed` and `memory-use-counts`
around a path before believing any per-function number, since a sampling
profiler and wall-clock advice will both blame the innocent. Where the
allocation is repeated work, remove the work: every send re-read every
applicable `AGENTS.md` off disk and re-ran the resident-span partition
over 20KB to 30KB to reach the answer it had last time. Caching that
halved the allocation per send and took the collections out of the
sample. Raising `gc-cons-threshold` around the send was considered and
rejected -- a deferred pause is still a pause, in a less predictable
place.

**But do not mistake this for a hitch the user can feel.** It was
presented as the cause of a reported RET hitch and it was not. The
collections were real, the caching was worth doing, and neither had
anything to do with the complaint: the actual cause was a preemptible
`redisplay`, and the actual pre-paint cost in the session that complained
was 28ms. See below for why the measurement said otherwise.

### A Reproduction Cannot Measure What The Reader's Emacs Is Doing

**Problem**: a reported hitch between RET and the typed line appearing
survived three rounds of diagnosis. Each round measured a reproduction of
the send path, each produced a confident cause, and each was wrong: batch
mode made garbage collection the largest term; a purpose-built GUI frame
was used to test whether the prompt marks paid for a font fallback on
macOS, and `char-displayable-p` turned out to be 0.018ms cold and free
warm; the transport, the body encoding and the log were measured and
cleared in turn.

**Cause**: the costs that decide whether a keystroke feels instant live in
the display and in whatever hooks the reader's configuration has
installed. Batch mode has no display and runs no `post-command-hook`. An
`emacs -Q` has a display and no configuration. Neither is the machine
where the complaint happened, and the program logged nothing between the
keystroke and the prepared request, so the one window under discussion
was the only part of the path with no record of itself.

**Solution**: make the path measure itself in the session where the
complaint happens. One log line per send: the phases in the order they
run, the mark before the paint separated out, and the facts that explain
an outlier -- buffer size, message count, whether undo is recording and
how long its list is, and how many `post-command-hook` and
`after-change-functions` entries are installed. The first real line
answered in one send what three rounds of reproduction had not.

Split the phases finely enough to name a culprit, and put the clock where
every layer can reach it. That first line put 98% of the send inside one
unbroken phase, which is an instrument failure, not a finding. Dividing
it at the points where work changes hands moved the unexplained cost from
one phase into another, because a clock that only marks at the door can
say the room is slow but not which piece of furniture: the marks had to
go into the transport and the request builder themselves, which is why
the clock lives in `chat-log` rather than in the UI that starts it.

### Counting The Preview Instead Of The Payload

**Problem**: the context budget reported 5,295 tokens for a request that
carried about 63,000. Auto-compaction was on and sat still, because by
its own arithmetic there was nothing to compact.

**Cause**: `chat-context-message-tokens` counted the *snippet* of each
message's tool calls and tool results -- the same 120-character preview a
durable summary shows -- while the request carries both in full. A 100KB
tool result is some 25,000 tokens on the wire and was counted as the 30
of its preview. On a 41-message coding session that under-counted the
context by 8.4x.

The same line was also the largest allocator on the keystroke path. To
produce a number it did not use, it concatenated every tool result into
one string, ran a whitespace regexp over the whole thing, trimmed it, and
kept 120 characters: 5.7MB allocated and 22.6ms spent per send, for an
answer that `length` gives for nothing.

**Solution**: count the fields the request will carry, by `length`, and
mirror the transport's own encoding rule for anything that is not already
a string. 22.6ms and 5.7MB became 0.2ms and 0.09MB, and the count went
from 8.4x under to matching. An estimator that samples what it is about
to send is not measuring what it is about to send.

**The general shape**: building a large thing to keep a small part of it.
Where the small part is all that is wanted, bound the input first --
`chat-context--message-snippet` now takes a head of a few times the
column cap before collapsing whitespace, because collapsing 200KB to keep
120 characters copies the 200KB twice. Where the small part is a
*measurement*, do not build anything at all.

**Not tested, which is why it survived**: 1088 tests passed with the
count 8.4x wrong. Every test that touched the budget asserted behaviour
around a threshold using messages it had built itself, and none asserted
that the count tracks what goes out.

### A Log Line On The Keystroke Path Is Work

**Problem**: 250ms of every send sat in the handover to the transport,
which does nothing but build a payload and fork `curl`.

**Cause**: two habits, both invisible in review. Every request printed
its whole formatted payload through `%S` -- a second formatting pass, a
quarter of a megabyte of `prin1` output, and an append to a log already
past a hundred megabytes, for a line nobody reads. And `executable-find`
was asked where `curl` lives on every request, which walks `exec-path`
and stats each entry: 11ms to 15ms here, growing with the path, to answer
a question whose answer does not change while Emacs runs.

**Solution**: log the shape, not the content -- counts, sizes and roles.
The content is in the session file already, and a reader chasing a bug
wants to know there were 41 messages and 250KB, not to scroll past them.
Look up an executable once and remember it. Together these took
`chat-llm--build-request` from 7.4ms to 0.7ms and removed a 250KB write
per send.

Two other habits in the same shape: four consecutive `chat-log` calls
where one would do, since each opens the file, appends and closes it; and
preparing the context in the UI when the run prepares it again before
every step, which compacted the same history twice per send -- and a
compaction rewrites the entire session file.

**Related hazard**: the prompt asks whether more than one model is
configured every time it is drawn, which asks every provider for its key.
That sweep is 0.4ms with no `auth-source` files present. With
`~/.authinfo.gpg` in place it becomes a GPG decryption per draw, and the
prompt is drawn on every send.

### Setting `face` To `default` Is Not The Same As Not Setting It

**Problem**: provider marks with no brand colour of their own came out
flat instead of taking the colour of the text around them.

**Cause**: the segment builder took a face argument that could be nil and
wrote `(or face 'default)` to avoid a nil property. `default` is a real
face, not an absence: it pins the foreground instead of letting the mark
inherit whatever it is drawn in.

**Solution**: build the property list so the key is absent when there is
no face, rather than present with a neutral-sounding value.

```elisp
(apply #'propertize text (when face (list 'face face)))
```

### A Glyph That The Frame Cannot Draw Is Worse Than No Glyph

**Problem**: a decorative mark risks appearing as a hollow box on a
terminal or in a font without it.

**Cause**: emoji and icon-font glyphs assume a colour font or a patched
font, and there is no reliable way to detect a font that has been
installed but lacks the code point.

**Solution**: keep marks to single-column BMP characters, colour them
with a face rather than the font, and check `char-displayable-p` before
drawing -- dropping the mark entirely when the answer is no. A box
carries nothing, takes a column anyway, and reads as a broken program.

### Scanning A Copy Of What Is Left Instead Of Scanning From An Offset

**Problem**: drawing a long reply took 592ms and allocated 986MB -- ten
times the collection threshold -- to put 320KB on screen once.

**Cause**: the loop over fenced code blocks searched `(substring content
pos)` and then took the same copy again to read the match groups. Two
copies of everything remaining, per block, so the cost was the reply's
length times its number of blocks. It looks linear because there is one
loop and one pass; the quadratic is inside `substring`.

**Solution**: `string-match` takes a start offset, and the match data it
leaves is in the original string's coordinates.

```elisp
(while (< pos len)
  (if (string-match regexp content pos)      ; not (substring content pos)
      (let ((block (match-string 1 content)) ; groups read from content
            (start (match-beginning 0))
            (end (match-end 0)))
        ...
        (setq pos end))
    ...))
```

Flat at 0.5MB per 100k afterwards, against 7 -> 20 -> 77 -> 308 before,
measured at four sizes an octave apart. Two sizes cannot tell linear from
quadratic; the ratio between them can.

The offset is also more correct than the copy. `^` matches at the start of
the string it is given, so scanning a copy let it match wherever the copy
happened to begin -- mid-line, in the middle of a paragraph. With an
offset it matches only where a line actually starts.

### Handing The Whole Of It Over Every Time Something Arrives

**Problem**: a 321KB reply arriving in 340 pieces allocated 53.6MB, 171
times the text, before anything was drawn with it.

**Cause**: `(setq all (concat all piece))` per piece. Emacs strings are
flat and immutable, so this copies everything received so far, every time
-- and no Lisp fixes that by being a Lisp. Clojure's structure sharing is
for vectors and maps; its strings are flat too.

**Solution**: hold the pieces in a list, fold them into one string only
when a consumer is given it, and give consumers it less often as it grows.

```elisp
(push piece pending)
(when (>= (* 8 pending-length) (length published))   ; back off as it grows
  (publish))
```

A short reply publishes on every piece and is unaffected; a long one
publishes 36 times instead of 340. Two things this needs to be safe: the
end of the run must flush whatever never reached the threshold, or a reply
loses its tail; and every consumer must accept a larger step, which is
where the quadratic above was found -- backing off made the drawing worse
before it made it better.

**What it does not fix**: the first send after a restart. Real sessions
hold small messages, so neither cost was ever on the keystroke path. They
filled the threshold *during* a reply, and the collection then landed on
whoever allocated next. Fixing an allocator and fixing a stall are
different claims, and the measurement has to say which one it supports.

### Printing An Event That Carries The Whole World

**Problem**: a 119MB log, 106.6MB of which -- 90% -- was 77 copies of the
same conversation, 1.4MB each.

**Cause**: a `cond` clause added to stop agent events being dropped
silently, doing the reasonable thing and printing what it dropped:

```elisp
(chat-log "[UI] Unhandled agent event: %s %S" type event)
```

`chat-agent--emit` puts `:run` on every event, and the run state holds the
session, which holds every message and every tool result. So `%S` on one
event printed the entire conversation. Seven event types reached that
clause, several times per turn.

The disk was the smaller half. That 1.4MB string is built by `format` in
the event callback, while a reply is streaming -- garbage on the same
order as everything else measured that night, on the same path.

**Solution**: name what an event carries instead of printing it. A dropped
event needs its type and its keys to be acted on; the payload is in the
session file already.

```elisp
(chat-log "[UI] Unhandled agent event: %s (step %s, carries %s)"
          type (plist-get event :step)
          (chat-ui--event-payload-keys event))
```

**General rule**: `%S` on anything that reaches a struct holding a session,
a run, a buffer or a process is unbounded by construction, and a log line
on a hot path is work. Measure a log's composition before assuming its
size came from volume of lines.

**Measuring it**: the dumps contain newlines, so counting matching *lines*
reported 3KB each and 0% of the log. The units have to be the record, not
the line -- bytes from the marker to the next timestamp.

### A Directory Whose Glob Decides What Its Files Are

**Problem**: adding a per-session event stream at
`~/.chat/sessions/<id>.wire.jsonl` would have handed every stream to
`chat-session-load` as though it were a session, on every listing.

**Cause**: `chat-session-list` decides what a session is by globbing:

```elisp
(dolist (file (directory-files chat-session-directory t "\\.jsonl$"))
  (let ((id (file-name-base file)))            ; "abc.wire" is now an id
    ...(chat-session-load id)))
```

Anything ending in `.jsonl` in that directory is a session by definition,
so a sibling file is not a new file -- it is a new session that fails to
load. Quietly, because the load is wrapped in `condition-case`. The same
trap caught the index: `index.jsonl` in there would be read as a session by
the very rebuild that walks the sessions to regenerate it.

**Solution**: a subdirectory for the streams, and the index outside the
session directory. Not a filter on the glob -- a filter is a rule someone
has to remember when adding the next file.

**General rule**: when a directory's contents are identified by pattern
rather than by a manifest, that pattern is a namespace, and putting an
unrelated file in it is a collision. Check what globs a directory before
adding a file to it.

### A Form Added To The End Of A Function Is Its Return Value

**Problem**: a compaction test began failing with
`(wrong-type-argument listp 392)`. The callback that should have received a
summary entry received the number 392.

**Cause**: recording compaction as an event, appended after the work:

```elisp
(defun chat-context--persist-compaction (session plan summary kind)
  (let* (...)
    (chat-session-add-summary ...)          ; used to be the value
    (when (fboundp 'chat-session-wire-record)
      (chat-session-wire-record ...))))     ; now the value
```

`chat-session-wire-record` returned the byte count from the `puthash` that
tracks file size, so the function returned 390-odd bytes where its caller
expected an alist. Nothing about the added code was wrong in itself.

**Solution**: bind what the function returns before adding anything after
it, and return it explicitly. Separately, a recording function should
return `t` rather than an incidental value, so that leaking it is harmless.

**General rule**: in Lisp every function ends in a return value, so
appending a statement to one is an interface change. Instrumentation is
where this bites, because instrumentation is added at the end by nature.

### Logging Costs Its Arguments Even When It Is Off

**Problem**: `chat-log` checked `chat-log-enabled` before writing, so
turning logging off appeared to make it free. It did not: the arguments
were evaluated at the call site, before the check was reached. One call
formatted a 250KB request payload on every send in order to hand it to a
function that would discard it.

**Cause**: it was a function. `(chat-log "%S" (expensive))` evaluates
`(expensive)` to build the call.

**Solution**: make it a macro, so the arguments sit inside the condition:

```elisp
(defmacro chat-log (format-string &rest args)
  `(when chat-log-enabled
     (chat-log--write ,format-string (list ,@args))))
```

Two things to check before doing this to an existing logger: no `.elc`
files that were compiled against the function, and no site that takes it as
a value -- `funcall`, `apply`, `mapcar`, `add-hook`. A macro in any of
those positions fails at runtime, not at compile time.

**General rule**: a guard inside a function guards the body, not the call.
When the arguments are the expensive part, the guard has to be outside.

## Display and Rendering

### Rebuilding Whitespace Instead Of Carrying It Through

**Problem**: rendering `- [ ] todo` produced `-[ ] todo`. One space, in a
renderer whose entire premise is that the buffer text is unchanged.

**Cause**: the line was reassembled from its parts, and the space between
the bullet and the checkbox was not one of the parts:

```elisp
;; indent + bullet + " " + rest, when the source was
;; indent + bullet + " " + checkbox + rest
(concat indent bullet (if checkbox (render checkbox) " ") rest)
```

**Solution**: carry the span through rather than reconstituting it —
`(substring line (match-end 2) (or (match-beginning 3) (match-end 0)))` —
so whatever was between them is what appears between them.

**General rule**: a renderer that must not change text should never write
a literal separator. What is not read from the source cannot match it. The
useful part here is that the invariant found the bug: a test asserting
only that a checkbox displays as `☐` passes on the broken version, and the
one asserting the text survives does not.

### Excluding From A Pattern What You Meant To Reject

**Problem**: MDP forbids tab indentation on a structure line, and a
tab-indented field reported nothing at all — it was silently data that
never arrived.

**Cause**: the pattern for a field was `\`\\( *\\)- \\(.*\\)\\'`. Tabs were
kept out of it, so a tab-indented line did not match, and a line that
matches nothing is a comment by specification. The rule that was supposed
to reject it never saw it.

**Solution**: match `[ \t]*`, then fail on the tab. Recognise first, refuse
second.

**General rule**: a validator only validates what reaches it. When a format
has a rule against a construction, the pattern has to admit that
construction so the rule can fire — otherwise "illegal" and "not present"
become the same code path, and the stricter format is the more silent one.

### Appending Only The New Text Draws A Block Before It Is One

**Problem**: a table streamed in unaligned and stayed unaligned, and a
list item never got its hanging indent, even though the renderer handled
both correctly when the same text was redrawn.

**Cause**: the streaming fast path kept everything already on screen and
appended only the delta. That is the cheapest possible update and it is
wrong for anything whose appearance depends on text that has not arrived:
a table's column widths need every row, a list item's `wrap-prefix` needs
its whole first line. By the time the second row arrived, the first had
been drawn as prose, and nothing revisits it.

**Solution**: keep the prefix consisting of *finished blocks* and redraw
the unfinished tail each time, generalising the existing "resume at a
closed fence" rule from fences to blocks. The cost is bounded by the tail
rather than the reply, and capped again for a tail that is itself long
(`chat-markdown-streaming-tail-max-chars`), which degrades to a plain face
until the block finishes.

**General rule**: incremental rendering is only safe up to the last point
whose appearance is settled. Cutting past it trades a correct display for
an append, and the display never recovers, because the append path has no
reason to look back.

### Measuring Markdown Source Instead Of What Reaches The Screen

**Problem**: a table looked aligned in plain source but its borders drifted
after rendering. Rows containing `` `main` `` or a link were the most
obvious failures, and a bold proportional-font header made the drift vary
by theme.

**Cause**: column widths were measured before inline rendering. Hidden
backticks, brackets and link destinations counted toward the width even
though they contributed no screen columns. The resulting character-column
arithmetic was then displayed through faces with different pixel metrics.

**Solution**: render each cell first, derive its screen text from
`invisible` and `display` properties, and measure that with `string-width`.
Give the whole table one fixed-pitch face before adding header, code and
border faces, and put that structural face first in the face list. Appending
it behind an existing channel face records the intent without giving it
control of the font metric. Keep truncation visibility-aware too, so it does
not discard hidden closing markers from the copyable Markdown source.

On graphical Emacs, fixed-pitch inheritance is still not a pixel guarantee
for mixed scripts: a CJK glyph can come from a fallback font whose width is
not exactly two Latin cells. Put each column border at an absolute display
column with `(space :align-to ...)`; padding spaces then preserve readable
source but no longer decide where the visible border lands.

**General rule**: display layout must measure the display representation,
not the storage representation. Once text properties can hide or replace
characters, source length is no longer evidence about occupied space.

### Splitting A Table Before Recognising Its Inline Syntax

**Problem**: a table that otherwise aligned correctly gained an extra column
when a cell contained `\|` or inline code such as `` `left|right` ``.

**Cause**: splitting on every pipe treats Markdown data as table structure.
Alignment cannot repair the wrong number of cells after that decision.

**Solution**: scan the row once, tracking backslash escapes and matching
backtick-run lengths. Only an unescaped pipe outside a code run is a boundary;
keep the original escape and backticks in the cell for the inline renderer.

**General rule**: structure tokenisation must understand the minimal lexical
contexts that can quote its delimiter. Do not ask layout code to recover a
structure the tokenizer already changed.

### Searching Every Inline Rule Through The Remaining Line

**Problem**: ordinary replies rendered quickly, but one long line containing
many links slowed superlinearly; 2000 links took over a second.

**Cause**: after every match, every inline regexp searched the entire remaining
line to discover which construct started next. Repeating those suffix scans made
a dense line approximately quadratic.

**Solution**: locate the next possible opening token once, dispatch from its
first bytes to the small set of constructs it can begin, and accept only a match
at that position. A 2000-link stress case then takes tens of milliseconds.

**General rule**: a single forward scanner is not linear if each step performs
another unbounded search over its remaining input.

### Appending A Resource Placeholder Duplicates The Document

**Problem**: an image's source syntax stayed in the buffer and a second
placeholder string was appended, so copying and session rendering no longer
had one authoritative representation.

**Cause**: the placeholder was treated as new content instead of a view of the
existing source span.

**Solution**: put the compact label in a `display` property over the complete
source span and attach a resource descriptor plus link keymap to that span.
The core renderer exposes metadata but performs no file, network or image work.

**General rule**: when source must remain copyable, a visual resource is a text
property over that source, not another string beside it.

### Duplicate Detection Can Make A Flat Protocol Quadratic

**Problem**: parsing a large flat MDP object slowed disproportionately as each
new field was added.

**Cause**: every insertion searched the growing alist with `assoc`. The outer
field pass was linear and the inner duplicate check was linear again.

**Solution**: preserve the alist for ordered output, but maintain a per-object
hash set for membership. Use the same principle when annotating lines: build a
line-number set once instead of scanning all structural line numbers for every
line.

**General rule**: ordered storage and fast membership are different jobs. Keep
the representation required by callers, and add an index for validation paths.

### Emacs Gives A Subprocess A Pty, So Git Starts A Pager And Waits Forever

**Problem**: `git log` and `git tag -l` run their whole timeout and then
report a timeout, having done their work immediately. The captured output
is two lines from `less`: `WARNING: terminal is not fully functional` and
`Press RETURN to continue`.

**Cause**: `process-connection-type` defaults to `t`, so `make-process`
allocates a pty unless told otherwise. Git checks whether stdout is a
terminal to decide about paging, a pty answers yes, and the pager it
starts waits for a keystroke that nothing on the other end of a pipe can
send. This is not specific to git or to background tasks — it affects any
pager-using program on any tool path, and it also puts ANSI colour codes
into text a model is about to read.

**Solution**: both halves, because neither covers the other. Use a pipe,
which removes the terminal that programs were checking for; and set the
variables, which cover the programs that page without asking a terminal
first, such as a forced `core.pager`.

```elisp
(let ((process-environment (chat-command-gate-environment)))
  (make-process ... :connection-type 'pipe))
```

**General rule**: a subprocess started on behalf of a tool call has
nobody who can answer a prompt. Anything that can block waiting for a
person has to be told not to, and the failure mode is a timeout reported
against a command that already finished — which reads as the command
being slow rather than as the harness being wrong.

### A Refusal That Does Not Say Why Is Answered By Giving Up

**Problem**: an agent asked to summarise a commit range spent six minutes
reading `.git` internals — `packed-refs`, `logs/HEAD`, loose objects —
which cannot produce commit subjects at all, since reflog holds only SHAs
and commit objects are zlib-compressed.

**Cause**: the tool refused `cd … && git rev-parse … && git log -1 … |
head -10` with `Error: Command not allowed:` and a copy of the command.
That command had four independent causes of refusal: `git` was not on the
allowlist, `&&` and `|` were rejected metacharacters, and quoting was a
candidate too. One sentence covered all four equally well, which means it
distinguished none of them. Unable to tell which rule had closed, the
agent did not try `git log` on its own — it abandoned git entirely.

**Solution**: make a refusal carry data rather than a sentence — a code,
the token that failed, and a form that works — and let the caller phrase
it. The token is what stops the reader comparing a whole command against a
list; the hint is what makes retrying possible.

```elisp
(cl-defstruct chat-command-gate-refusal code token hint)
```

**General rule**: an error message is an instruction to the reader about
what to do next, and a reader who cannot tell which of several rules
stopped them has exactly one move available: stop. Every refusal needs to
name the specific thing and a way forward, or it will be read as "this
whole approach is closed".

### A Strict Gate Beside An Open Window Is Not A Boundary

**Problem**: `shell_execute` enforced a 19-command allowlist and rejected
all shell metacharacters, while `work_task_start` handed the model's
string to `sh -c` unexamined. The same `git` command that was refused on
the first path ran on the second, with `&&` and `||` in it.

**Cause**: two places were deciding what may run, so they decided
differently. The gap widened further because subagent sessions are created
with `autoApprove: true`, and session-level auto-approve short-circuits
the per-tool auto-approve list, so on that path there was neither an
allowlist nor a prompt.

**Solution**: one decision function, and a policy passed in as an
argument. What differs legitimately between callers is the program list
and whether separators are meaningful — a tool that runs one program
through `make-process` cannot honour a pipeline, a background task runner
exists to run shell lines — but the decision itself belongs in one place.

**General rule**: the cost of a restriction is paid by whoever obeys it,
and the benefit only exists if there is no other route. When a second
route exists, the restriction stops being a boundary and becomes a tax on
the honest path — so either close the other route or drop the
restriction, but do not keep both.

### A Running Tool Reported As A Stalled Stream

**Problem**: a subagent worked for two and a half minutes and the
interface said `Stream has stalled without a new chunk`. Nothing was
wrong; the message was read as a failure.

**Cause**: the stall check was given a request id and a threshold, and it
concluded from "no chunk for fifteen seconds" that the stream had
stalled. The stream had in fact finished normally, and what was in
progress was something the stream had asked for — but tool activity was
kept in the UI's own list and never reached the request's record, so the
check could not see it. The phase stayed on `streaming` for the whole tool
call as well, so even the wording named the wrong component.

**Solution**: record tool start and finish on the request trace, count
them rather than flagging them (one step can call several tools, and a
flag cleared by the first result reports the rest as silence), and treat
silence with a known cause as not a stall. Then explain the wait instead:
`Running <tool> (42s)`, with a number that moves.

Also make the hint timer repeat rather than fire once. A single shot
landing during a long tool call is now spent on nothing, and a real stall
afterwards would go unreported — trading a false alarm for a silence is
not an improvement.

**General rule**: "no output" is not a diagnosis. Before reporting a
component as stuck, check whether something else is legitimately busy —
and if it is, say what it is and how long it has been going, because the
reader's real question is whether anything is still happening.

### Approved, Then Refused Anyway

**Problem**: the model proposed `make test` as a background task, the user
read it and approved it, and the tool refused: `the program make is not on
the allowed list`. The approval had no effect on the outcome.

**Cause**: approval ran before the tool function and the command list ran
inside it, with no way for either to know about the other. So the list was
consulted a second time, after the only party who could actually judge the
command had already judged it. A list cannot add safety over a person who
read the command; all it can do is void their answer.

**Solution**: make the answer say *how* the call was permitted rather than
just that it was — `human`, `grant`, `rule` or `dangerous` — and let the
tool see it. A person's yes skips the list; a grant does not, because a
grant only means "stop asking me about this", not "the rules no longer
apply".

**General rule**: when two checks guard one action, decide which one is
authoritative and let it be. Re-checking after a human decision is not
defence in depth, it is a veto over the only judgement in the system that
had full context.

### One Yes That Turned Off Every Question

**Problem**: approving a single shell command with "allow for session"
stopped every later tool in that session from asking, including file
writes and patches. A session found on disk had `autoApprove: true` with
nobody remembering having enabled it.

**Cause**: the option was implemented by setting the session's
auto-approve flag, and that flag short-circuited the per-tool list
entirely. There was nowhere to record "this command, this session", so the
nearest available switch was used — and it was a much larger switch than
the option's own label described.

**Solution**: give session-scoped grants their own store, so the choice
covers exactly what was approved and dies with the session. And keep the
mode out of reach of every interactive choice: the one mode that runs
anything has to be typed on purpose.

**General rule**: an option must not do more than its label says. When the
data structure cannot express the narrow thing offered, the answer is to
add it, not to spend the nearest wider permission and hope the difference
never comes up.

### Runtime Grants Written Into The User's Own Settings

**Problem**: "always allow this" put entries into `M-x customize` that the
user had never written, and lost them all on restart anyway.

**Cause**: the grant was pushed onto the same `defcustom` the user
configures by hand. Three problems in one: their customisation buffer
showed our entries, a `custom-file` save could write them back as if they
had asked for them, and clearing what the program granted meant clearing
their configuration with it. Nothing was persisted, so a promise the user
read as permanent expired silently.

**Solution**: separate stores by owner — a constant for what the project
stands behind, a `defcustom` we only ever read, and a file we own and can
clear as a group. Record when each runtime grant was added and which
session added it, because a list grown over months is otherwise unreadable
and the only safe move left is to delete all of it.

**General rule**: never write to a variable a user is expected to set. If
the program needs to remember something, it needs its own place to
remember it — sharing storage with configuration makes both unmaintainable
and makes intent impossible to reconstruct.

### An Incremental Refresh That Still Walked The Whole Repository

**Problem**: changing one known file in a 10,000-file fixture reported one
changed entry, but the refresh still took roughly as long as a full scan.

**Cause**: “incremental” described reuse after discovery. The implementation
still traversed every directory and hashed every candidate to discover that one
file had changed, then rebuilt a temporary relation index on every refresh.

**Solution**: keep stem and importer indexes with the last complete repo-map
revision. Unknown external changes use the bounded full scanner; an
editor-observed write calls `chat-repo-map-update-paths-async` with exact paths
and atomically replaces only affected entries and edges. Benchmark the two paths
separately so warm-query work cannot leak into the incremental timer.

**General rule**: an incremental result count does not prove incremental work.
Measure the discovery path, update path and dependent recomputation separately,
and provide an API that accepts knowledge the caller already owns.

### A Missing Baseline Is Not A Failed Trial Or A Passing Gate

**Problem**: Eval infrastructure existed, so stage records described the M9
baseline as complete even though no immutable live result set could be found.

**Cause**: runner completion, fixture completion and evidence completion were
collapsed into one status. That made a final comparison appear runnable without
the provider/model/capability identity or five repetitions per task.

**Solution**: validate exact sample count and identity in one immutable final
gate. Missing M9, M17, token usage or large-repository evidence is `blocked`;
observed task or threshold failure is `failed`. `M-x
chat-coding-acceptance-run-final` records the distinction in the existing Eval
store.

**General rule**: absence is neither zero nor success. A strict acceptance
system must preserve the difference between bad evidence and no evidence,
because only the second can be fixed by rerunning the measurement.

### A Managed HOME Can Hide A Language Toolchain

**Problem**: a sandboxed `cargo test` was approved but failed because rustup
reported that no default toolchain was configured. The Agent then consumed the
task budget probing toolchain directories.

**Cause**: deny-default execution correctly replaced `HOME` with a managed
temporary directory, but rustup stores its active toolchain under the
developer's `RUSTUP_HOME`. System compiler roots and SSL files were available;
the language-manager state was not.

**Solution**: detect actual Rust tool invocations, add only the existing
`RUSTUP_HOME` as a read-only sandbox root and pass that variable explicitly.
Keep the managed home, project-only write roots and default network denial. Add
a real `sh -c "cargo test ..."` isolation test plus a negative test proving an
ordinary command cannot see the Rust root.

**General rule**: replacing `HOME` is necessary isolation, but executable
discovery and language-manager state are separate capabilities. Grant the
smallest command-scoped read root instead of restoring the developer home.

### Build Outputs Are Not Source Scope

**Problem**: a successful coding Eval was marked failed because `cargo test`
created `target/**` and `Cargo.lock`, even though the only source edit was the
declared file.

**Cause**: the evaluator used one changed-file set for source edits, build
outputs and scope enforcement. A successful verification therefore looked like
an out-of-scope source mutation.

**Solution**: require each task to declare safe, non-overlapping
`generatedPaths`. Record generated files separately, apply `allowedPaths` only
to source changes and continue to fail closed for every undeclared path.

**General rule**: generated output is evidence, not permission. Keep it visible
and bounded, but never let it widen the source edit contract.

### Evidence Is Not Actionable Until The Agent Can Cite It

**Problem**: a multi-file coding task created and advanced its durable TODO
plan, but repeatedly failed when completing the first item and eventually
exhausted its step budget.

**Cause**: three individually plausible contracts did not compose. The provider
schema represented evidence as an encoded JSON string, successful tool results
hid the post-tool event ID from the model, and the persisted event used the tool
call ID where the plan resolver expected the owning Agent task ID. Evidence
existed in storage but was neither constructible nor discoverable by its caller.

**Solution**: expose evidence as a native string array, return the exact event ID
with every successful tracked tool result, and persist a separate
`agent_task_id` for scope resolution. Keep the tool-call identity for tracing.
Never return a usable Evidence ID for a failed tool. Test provider schema,
model-visible feedback, persisted scope and resolver behavior as one contract.

**General rule**: durable evidence needs an end-to-end citation path. Creating a
record is insufficient; the producer must expose its stable identity, the
consumer must accept that identity without re-encoding, and the resolver must
verify the same session and task scope.

Last updated: 2026-08-29
