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
- Testing and Batch Mode
- Development Hygiene

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

### 403 Access Denied For Kimi Code

**Problem**: The API returns `Kimi For Coding is currently only available for Coding Agents`.

**Cause**: The provider requires a specific `User-Agent` and Emacs `url` does not honor that header reliably when it is passed through regular request headers.

**Solution**: Bind `url-user-agent` directly instead of trying to set a `User-Agent` header.

```elisp
;; Wrong
'(("User-Agent" . "claude-code/0.1.0"))

;; Right
(let ((url-user-agent "claude-code/0.1.0"))
  (url-retrieve-synchronously ...))
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

### Mode Specific Stream Adapters Can Drift From The Core API

**Problem**: a mode specific streaming path fails with wrong number of arguments or never finalizes the response.

**Cause**: the mode layer invents its own callback contract instead of following the actual `chat-stream-request` signature and sentinel flow.

**Solution**: keep mode integrations on the same four argument `chat-stream-request` contract and finalize the completed response from the process sentinel.

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

### Persistence Stubs Must Not Masquerade As Real Load Paths

**Problem**: higher level features like incremental indexing appear to exist but silently rebuild everything every time.

**Cause**: the save path writes index files while the corresponding load path still returns `nil` as a placeholder.

**Solution**: finish the load path at the same time as the save path or explicitly disable the feature until both directions are implemented and covered by tests.

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

**Solution**: feed tool results back through a follow up system message and persist a readable assistant side summary when needed.

### Mode Specific Tool Prompt Drift Reintroduces Wrong Protocols

**Problem**: a specialized mode like `code-mode` starts emitting XML style tool calls even though the shared chat flow already uses JSON `function_call`.

**Cause**: the mode builds its own system prompt and final response path instead of reusing the shared tool calling prompt and post processing contract.

**Solution**: mode specific request paths must build their system prompt through `chat-tool-caller-build-system-prompt` and finalize responses through `chat-tool-caller-process-response-data` plus the same follow up tool loop pattern.

### Shell Whitelists Fail If Execution Still Uses A Shell

**Problem**: a whitelist that validates only the first token can still be bypassed with pipes and command chaining.

**Cause**: `call-process-shell-command` hands the full string back to the shell for expansion.

**Solution**: reject shell metacharacters and execute argv directly with `process-file`.

```elisp
(and (not (string-match-p chat-tool-shell--unsafe-pattern command))
     (member (car argv) chat-tool-shell-allowed-commands))
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

Last updated: 2026-03-26
