;;; chat-tool-caller.el --- AI tool calling with JSON format -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: tools, llm

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module defines the JSON tool calling contract used by chat.el.
;; It builds the system prompt, parses model responses, and executes tools.

;;; Code:

(require 'cl-lib)
(require 'chat-agent-budget)
(require 'chat-approval)
(require 'chat-files)
(require 'chat-i18n)
(require 'chat-llm)
(require 'chat-mdp)
(require 'chat-session)
(require 'chat-tool-forge)
(require 'json)
(require 'pp)
(require 'seq)
(require 'subr-x)

(chat-files-register-built-in-tools)

(defcustom chat-tool-caller-enabled t
  "Enable AI tool calling."
  :type 'boolean
  :group 'chat)

(defcustom chat-tool-caller-result-max-chars 8000
  "Maximum characters of one tool result fed back to the model.
Results longer than this are truncated with an omission marker so the
model knows content is missing."
  :type 'integer
  :group 'chat)

(defvar chat-tool-caller-current-session nil
  "Session whose tool overlay is used for provider tool exposure.")

(defvar chat-tool-caller-current-state-session nil
  "Canonical session that owns durable state for the current tool call.")

(defvar chat-tool-caller-current-execution-context nil
  "Correlation plist for the tool call currently being executed.")

(defvar chat-execution-current-context nil)

(defun chat-tool-caller--condition-error-type (err)
  "Return the stable public error type represented by ERR, or nil."
  (pcase (car-safe err)
    ('chat-files-file-not-read 'file-not-read)
    ('chat-files-stale-file 'stale-file)
    ('chat-files-version-mismatch 'version-mismatch)
    (_ nil)))

;; Bound buffer-locally by the chat surface, which loads after this.
(defvar chat--current-session)

(defun chat-tool-caller-truncate-result (result &optional max-chars)
  "Keep RESULT within MAX-CHARS, appending an omission marker when cut."
  (let* ((text (or result ""))
         (limit (or max-chars chat-tool-caller-result-max-chars)))
    (if (> (length text) limit)
        (format "%s\n... [truncated, %d chars omitted]"
                (substring text 0 limit)
                (- (length text) limit))
      text)))

(defun chat-tool-caller--tool-advertised-p (session tool-id)
  "Return non-nil when SESSION advertises TOOL-ID to the model."
  (let* ((config (and session (chat-session-tool-config session)))
         (advertised (plist-get config :advertised-tools)))
    (or (not (plist-member config :advertised-tools))
        (memq tool-id advertised))))

(defun chat-tool-caller--tool-available-in-session-p (tool session)
  "Return non-nil when TOOL is both authorized and advertised in SESSION."
  (let ((tool-id (chat-forged-tool-id tool)))
    (and (chat-session-tool-enabled-p session tool-id)
         (chat-tool-caller--tool-advertised-p session tool-id)
         (cond
          ((eq tool-id 'shell_execute)
           (bound-and-true-p chat-tool-shell-enabled))
          (t
           (chat-forged-tool-is-active tool))))))

(defun chat-tool-caller--tool-available-p (tool)
  "Return non-nil when TOOL should be exposed to the model."
  (chat-tool-caller--tool-available-in-session-p
   tool chat-tool-caller-current-session))

(defun chat-tool-caller--available-tools ()
  "Return tools that can currently be called."
  (seq-filter #'chat-tool-caller--tool-available-p
              (chat-tool-forge-list)))

(defun chat-tool-caller--tool-argument-spec (tool)
  "Return a JSON example string for TOOL arguments."
  (let ((params (chat-forged-tool-parameters tool)))
    (if (and (listp params) params)
        (concat "{"
                (mapconcat
                 (lambda (param)
                   (format "\"%s\": \"value\""
                           (plist-get param :name)))
                 params
                 ", ")
                "}")
      "{}")))

(defun chat-tool-caller--empty-json-object ()
  "Return an object that encodes as JSON `{}`."
  (make-hash-table :test 'equal))

(defun chat-tool-caller--format-tool-line (tool)
  "Format TOOL as one line for the system prompt."
  (format "- %s: %s arguments %s"
          (chat-forged-tool-id tool)
          (or (chat-forged-tool-description tool) "No description")
          (chat-tool-caller--tool-argument-spec tool)))

(defun chat-tool-caller--permission-metadata (tool)
  "Return permission metadata for TOOL."
  (append
   (when-let ((sensitivity (chat-forged-tool-sensitivity tool)))
     (list :sensitivity sensitivity))
   (when-let ((effects (chat-forged-tool-effects tool)))
     (list :effects effects))
   (when-let ((owner (chat-forged-tool-owner tool)))
     (list :owner owner))))

(defun chat-tool-caller--json-schema (tool)
  "Return an OpenAI-style JSON schema alist for TOOL parameters."
  (let ((params (chat-forged-tool-parameters tool))
        properties
        required)
    (cond
     ((and (listp params) params)
      (dolist (param params)
        (let ((name (plist-get param :name))
              (type (or (plist-get param :type) "string"))
              (desc (plist-get param :description))
              (enum (plist-get param :enum))
              (items (plist-get param :items))
              (min-items (plist-get param :min-items)))
          (push (cons name
                      (append `((type . ,type))
                              (when (and (stringp desc)
                                         (not (string-empty-p desc)))
                                `((description . ,desc)))
                              (when enum
                                `((enum . ,(vconcat enum))))
                              (when items
                                `((items . ,items)))
                              (when min-items
                                `((minItems . ,min-items)))))
                properties)
          (when (plist-get param :required)
            (push name required))))
      `((type . "object")
        (properties . ,(nreverse properties))
        (required . ,(vconcat (nreverse required)))
        (additionalProperties . :json-false)))
     (t
      `((type . "object")
        (properties . ,(chat-tool-caller--empty-json-object))
        (required . [])
        (additionalProperties . :json-false))))))

(defun chat-tool-caller-provider-tools ()
  "Return provider tool definitions for currently available tools.
The vector is empty when tool calling is disabled."
  (when chat-tool-caller-enabled
    (let (defs)
      (dolist (tool (chat-tool-caller--available-tools))
        (push `((type . "function")
                (function . ((name . ,(symbol-name (chat-forged-tool-id tool)))
                             (description . ,(or (chat-forged-tool-description tool)
                                                 ""))
                             (parameters . ,(chat-tool-caller--json-schema tool)))))
              defs))
      (when defs
        (vconcat (nreverse defs))))))

(defun chat-tool-caller--tool-usage-guidance ()
  "Return human readable usage guidance for built in tools."
  (mapconcat
   #'identity
   '("Tool usage guidance:"
     "- `open_file` opens a safe project file in Emacs and can jump to a specific line or column."
     "- `files_list` lists directory entries. Use it first to understand what exists."
     "- `files_find` searches recursively across a directory for files whose contents match a pattern."
     "- `files_grep` searches one known file path. Do not use it on directories."
     "- `files_read` reads a file body. Prefer `files_read_lines` when you already know the line range."
     "- `files_read_lines` reads a specific line range and is better for large files."
     "- `files_write` writes a full file body and is best for new files or deliberate whole-file rewrites."
     "- `files_replace` is for exact or regex search/replace when you can identify the current text precisely."
     "- `files_replace` should usually include `expected_count` or `line_hint` when the target may be ambiguous."
     "- `apply_patch` is for targeted multi-hunk edits to existing files using codex patch text."
     "- `files_patch` is a legacy structured search/replace tool. Prefer `apply_patch` for complex existing-file edits."
     "- `shell_execute` is only for lightweight readonly inspection when file tools are not enough."
     "- After code edits, prefer `programming_verification_plan` followed by `programming_verification_run`; use `programming_compile_task` only for an exact check the resolved profile does not contain."
     "- Verification IDs are typed: pass the profile ID from `programming_verification_plan` to `programming_verification_run`, then pass the distinct verification ID returned by that run to `programming_verification_read_result`."
     "- Build and test tools use an isolated temporary HOME and TMPDIR. Do not move caches into the project or clean generated caches unless they are tracked or the user asked for cleanup."
     "- If a write tool needs approval, wait for approval instead of printing the intended file body in chat.")
   "\n"))

(defun chat-tool-caller--plan-usage-guidance (tools)
  "Return plan guidance when TOOLS expose the programming plan surface."
  (let ((ids (mapcar #'chat-forged-tool-id tools)))
    (cond
     ((memq 'programming_plan_create ids)
      (mapconcat
       #'identity
       '("Programming plan boundaries:"
         "- Answer-only and read-only work needs no plan. For substantial coding or more than one bounded mutation, call the directly available `programming_plan_create` before the first gated action; ordinary coding creates the durable TODO list and starts its first dependency-ready item atomically."
         "- For exactly one bounded mutation through `files_write`, `files_replace`, or `files_patch`, call `programming_plan_skip` with reason `single-bounded-action` and that exact `tool_name` instead of creating a TODO plan. On the next step, call that newly visible write tool immediately; do not activate unrelated capabilities. The audited skip is available only once per task and permits one matching mutation plus targeted verification. If that edit fails or another mutation becomes necessary, create a durable TODO plan; never issue another skip or use a skip to hide multi-step work."
         "- TODO items are control points, not narration. Use the fewest items that preserve real dependencies, approvals, and distinct acceptance outcomes; combine related edits and their verification when one observable result closes both."
         "- Successful tools return an exact Evidence ID. Pass that ID in `evidence` when completing a plan item or recording Goal evidence; never invent one."
         "- The first item is already active after ordinary creation. Complete only the active item; then start the next pending item. Never batch dependent transitions: use each returned revision."
         "- Do not enter Plan Mode merely to create or use that TODO list."
         "- Call `programming_plan_mode_enter` only when the user explicitly asks for read-only planning before implementation.")
       "\n"))
     ((memq 'programming_plan_transition ids)
      (mapconcat
       #'identity
       '("Active programming plan:"
         "- A durable plan already exists. Do not call `programming_plan_create` again; use `programming_plan_read` if its current item or revision is uncertain."
         "- Successful tools return an exact Evidence ID. Pass those IDs in `evidence`; never invent evidence."
         "- After the active item's acceptance check passes, call `programming_plan_transition` to complete that item. Then start the next dependency-ready item using the returned revision."
         "- Never batch dependent transitions or continue inspecting after the final acceptance evidence is sufficient; close the plan and answer.")
       "\n")))))

(defun chat-tool-caller--storage-note-variant (session terse)
  "Build the storage block for SESSION at one verbosity, TERSE or not.

Three places, described together because the distinction between them is
the useful part: the transcript is what already happened, scratch space
is where this run may put things down, and shared knowledge is what
should outlive the session.  Told separately, a run tends to keep
everything in whichever one it noticed first."
  (let ((parts (delq nil
                     (list (and (fboundp 'chat-session-log-self-description)
                                (chat-session-log-self-description
                                 session terse))
                           (and (fboundp 'chat-scratch-prompt-note)
                                (chat-scratch-prompt-note session terse))
                           (and (fboundp 'chat-knowledge-prompt-note)
                                (chat-knowledge-prompt-note terse))))))
    (and parts (string-join parts (if terse "\n" "\n\n")))))

(defun chat-tool-caller--durable-storage-note (session)
  "Return what SESSION should know about the storage it can reach.

The full block runs to a few hundred tokens, which is nothing against a
large window and more than the whole system prompt share of a small one.
So it is measured against the share it actually lands in and shortened
when it does not fit, rather than tuned per window: the paths and tool
names survive either way, and only the reasoning is dropped.  Explaining
at length why a run should consult its transcript is worthless if doing
so crowds out the conversation it was meant to recover."
  (let ((full (chat-tool-caller--storage-note-variant session nil)))
    (if (or (null full)
            (not (fboundp 'chat-context-allocation-tokens))
            (not (fboundp 'chat-context-count-tokens)))
        full
      (let* ((model (and session (chat-session-model-id session)))
             (window (and (fboundp 'chat-context-window-for-model)
                          (chat-context-window-for-model model)))
             (share (and window
                         (chat-context-allocation-tokens
                          'system-prompt window))))
        (if (and share (> (chat-context-count-tokens full) share))
            (chat-tool-caller--storage-note-variant session t)
          full)))))

(defun chat-tool-caller--reply-language-note ()
  "Return the instruction naming the language to answer in, or nil.

Stated rather than inferred.  A model asked in one language about text
written in another has to guess which one the answer is for, and the
guess is not stable across models or across turns of the same
conversation.  The exception is quoted material: translating an error
message or a line of code on the way out makes it unsearchable."
  (when-let ((language (and (fboundp 'chat-reply-language-name)
                            (chat-reply-language-name))))
    (format
     (chat-i18n-prompt
      'reply-language
      (concat "Answer in %s. Keep identifiers, file paths, commands, error"
              " text and quoted code exactly as they appear -- translating"
              " those makes them impossible to search for. If the user"
              " writes in another language, follow the user."))
     language)))

(defun chat-tool-caller--output-format-note ()
  "Return the instruction naming the answer format.

Markdown, stated rather than assumed.  Every model writes it by habit,
and the habit is what the renderer was built around, so leaving it unsaid
means the display depends on something nobody asked for.

The subset is narrower than Markdown, and each restriction is there
because of how a buffer displays rather than because of taste.  The
reasons are stated: a prompt rule without a reason reads as optional, and
a model that does not know why a rule exists drops it as soon as the
content makes it inconvenient.

Not a precondition of rendering.  The renderer has to have defined
behaviour for anything the model writes, in or out of this subset -- see
specs/005."
  (chat-i18n-prompt
   'output-format
   (concat
    "Write answers in Markdown. They are rendered in the editor, so keep"
    " to the subset it displays well:\n"
    "- Headings use the ATX form (`## Title`), start at level two, and go"
    " no deeper than four. Never underline a heading: that form cannot be"
    " recognised until the line after it, by which point it is drawn.\n"
    "- Do not hard-wrap paragraphs. Text is wrapped to the window, so a"
    " paragraph wrapped by hand is ragged at every other width.\n"
    "- Every fenced code block names its language. The language is what"
    " selects syntax highlighting; without it the code has none.\n"
    "- Use fences only for literal code or source that should stay"
    " unrendered. Never wrap an ordinary answer or a Markdown rendering"
    " demonstration in a `markdown` fence: its contents are deliberately"
    " shown as source rather than rendered as a document.\n"
    "- Lists nest at most two levels.\n"
    "- Tables only for data that is genuinely tabular, at most four"
    " columns, with short cells. A wide table does not fit a window.\n"
    "- Inline code for identifiers, paths and commands.\n"
    "- Bold sparingly, and never in place of a heading.\n"
    "- No HTML, no LaTeX math, no images, no footnotes: none of these"
    " are rendered.")))

(defun chat-tool-caller-build-system-prompt
    (base-prompt &optional step-limit session)
  "Extend BASE-PROMPT with long term memory and tool calling instructions.

STEP-LIMIT, when given, is the step ceiling of the run this prompt opens.
It is stated here rather than counted down per step: a run should know
from the start that it has to converge, and the wording stays identical
across steps so it costs nothing to repeat.

SESSION, when given, adds what the run can know about itself: where its
own transcript is, where it may write scratch files, and what shared
knowledge already exists.  A run that does not know its record is on disk
will ask again for something it was already told."
  (let ((chat-tool-caller-current-session
         (or session chat-tool-caller-current-session))
        (base (if-let ((memory (and (fboundp 'chat-memory-snippet)
                                    (chat-memory-snippet session))))
                  (concat base-prompt "\n\n" memory)
                base-prompt)))
    (when-let ((storage (chat-tool-caller--durable-storage-note session)))
      (setq base (concat base "\n\n" storage)))
    (when-let ((language (chat-tool-caller--reply-language-note)))
      (setq base (concat base "\n\n" language)))
    ;; Beside the language note and on the same footing: both say how to
    ;; answer rather than what to answer, and both apply whether or not
    ;; there are tools.
    (setq base (concat base "\n\n" (chat-tool-caller--output-format-note)))
    (if (not chat-tool-caller-enabled)
        base
      (let ((tools (chat-tool-caller--available-tools)))
        (if (null tools)
            base
          (concat
           base
         "\n\n"
         ;; Only stated when tools exist: without them a run is a single
         ;; step and there is no budget to plan against.
         (if step-limit
             (concat (chat-agent-budget-system-note step-limit) "\n\n")
           "")
         ;; The policy is stated here and the numbers are not: usage changes
         ;; every step, and a figure baked into the prompt would be wrong by
         ;; the time it is read.
         (chat-context-budget-policy-note)
         "\n\n"
         "You can call tools when they are necessary.\n"
         "Prefer the provider tool-calling API. Multiple tools may be issued in one response.\n"
         "If the provider has no tool API, respond with JSON objects of the form below.\n"
         "After a tool runs, the system will send the tool result back to you as a tool message.\n"
         "You may then either answer normally or call more tools.\n"
         "Some tools may require user approval before execution.\n"
         "Read files before editing them.\n"
         "Use `open_file` when the user wants you to open a relevant file in Emacs.\n"
         "Use `files_write` for new files or whole-file rewrites.\n"
         "Use `files_replace` for exact text replacements with strong match constraints.\n"
         "Use `apply_patch` for precise existing-file edits across one or more hunks.\n"
         "Use files_find for recursive directory text search and use files_grep for one known file.\n"
         "After editing, inspect the result or diff before declaring success.\n"
         (chat-tool-caller--tool-usage-guidance)
         (if-let ((plan-guidance
                   (chat-tool-caller--plan-usage-guidance tools)))
             (concat "\n" plan-guidance)
           "")
         "\n"
         "Use this exact shape:\n"
         "{\"function_call\": {\"name\": \"TOOL_NAME\", \"arguments\": {\"param\": \"value\"}}}\n"
         "For `apply_patch`, pass a single string argument named `patch` using this envelope:\n"
         "*** Begin Patch\n"
         "*** Update File: path/to/file\n"
         "@@\n"
         "-old line\n"
         "+new line\n"
         "*** End Patch\n"
         "Rules:\n"
         "- Use only tool names from the list below.\n"
         "- You may issue multiple tool calls in one response.\n"
         "- Use the exact argument names shown for that tool.\n"
         "- Do not rename keys.\n"
         "- Do not print raw file contents in chat when a write tool should be used.\n"
         "- If editing an existing file, prefer `apply_patch` or `files_replace` over `files_write`.\n"
         "- If no tool is needed, answer normally.\n"
         "Available tools:\n"
         (mapconcat #'chat-tool-caller--format-tool-line tools "\n")))))))

(defun chat-tool-caller--fix-broken-json (string)
  "Apply small compatibility fixes to STRING."
  (let ((result (string-trim string)))
    (setq result (replace-regexp-in-string "\\`json[ \t\n\r]*" "" result))
    (when (string-prefix-p "```json" result)
      (setq result (string-trim-left (string-remove-prefix "```json" result))))
    (setq result (replace-regexp-in-string "[ \t\n\r]*```\\'" "" result))
    (setq result (replace-regexp-in-string "\"_call\"" "\"function_call\"" result))
    (setq result (replace-regexp-in-string "\"_execute\"" "\"shell_execute\"" result))
    result))

(defun chat-tool-caller--decode-json (string)
  "Decode tool call JSON from STRING."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'string))
    (json-read-from-string (chat-tool-caller--fix-broken-json string))))

(defun chat-tool-caller--extract-fenced-json (content)
  "Extract JSON code blocks from CONTENT."
  (let ((blocks nil)
        (pos 0))
    (while (string-match "```json" content pos)
      (let* ((start (match-end 0))
             (end (string-match "```" content start)))
        (if end
            (progn
              (push (substring content start end) blocks)
              (setq pos (+ end 3)))
          ;; Unclosed fence: skip past the opener so the loop terminates.
          (setq pos start))))
    (nreverse blocks)))

(defun chat-tool-caller--extract-inline-json-fragments (content)
  "Extract balanced inline JSON object fragments from CONTENT."
  (let ((len (length content))
        (pos 0)
        (fragments nil))
    (while (< pos len)
      (let ((start (string-match "{" content pos)))
        (if (null start)
            (setq pos len)
          (let ((depth 0)
                (idx start)
                (in-string nil)
                (escaped nil)
                end)
            (while (and (< idx len) (null end))
              (let ((ch (aref content idx)))
                (cond
                 (escaped
                  (setq escaped nil))
                 ((eq ch ?\\)
                  (when in-string
                    (setq escaped t)))
                 ((eq ch ?\")
                  (setq in-string (not in-string)))
                 ((not in-string)
                  (cond
                   ((eq ch ?{)
                    (setq depth (1+ depth)))
                   ((eq ch ?})
                    (setq depth (1- depth))
                    (when (= depth 0)
                      (setq end (1+ idx))))))))
              (setq idx (1+ idx)))
            (if end
                (progn
                  (push (substring content start end) fragments)
                  (setq pos end))
              (setq pos (1+ start)))))))
    (nreverse fragments)))

(defun chat-tool-caller--tool-json-fragments (content)
  "Return parseable tool call JSON fragments found in CONTENT."
  (let (fragments)
    (dolist (candidate (append (chat-tool-caller--extract-fenced-json content)
                               (chat-tool-caller--extract-inline-json-fragments content)))
      (condition-case nil
          (when (chat-tool-caller--call-from-data
                 (chat-tool-caller--decode-json candidate))
            (push candidate fragments))
        (error nil)))
    (nreverse (delete-dups fragments))))

(defun chat-tool-caller--extract-json-candidates (content)
  "Extract candidate JSON fragments from CONTENT."
  (let ((candidates nil)
        (trimmed (string-trim content)))
    (when (and (string-prefix-p "{" trimmed)
               (string-suffix-p "}" trimmed))
      (push trimmed candidates))
    (dolist (block (chat-tool-caller--extract-fenced-json content))
      (push block candidates))
    (dolist (fragment (chat-tool-caller--extract-inline-json-fragments content))
      (push fragment candidates))
    (nreverse (delete-dups candidates))))

(defun chat-tool-caller--call-from-data (data)
  "Extract one tool call plist from decoded JSON DATA.

Deliberately id-free: `chat-tool-caller-parse' drops duplicate calls by
comparing the plists, so an id minted here would make every call unique
and defeat that.  Ids are assigned once the list is settled."
  (let* ((function-call (cdr (assoc "function_call" data)))
         (name (and (listp function-call)
                    (cdr (assoc "name" function-call))))
         (arguments (and (listp function-call)
                         (cdr (assoc "arguments" function-call)))))
    (when (and (stringp name) (listp arguments))
      (list :name name
            :arguments arguments))))

(defun chat-tool-caller--attempted-tool-call-p (content)
  "Return non-nil when CONTENT looks like a failed tool call attempt.
The heuristic keys on explicit function_call markers so ordinary JSON
examples in prose do not count as attempts."
  (string-match-p "function_call\\|\"_call\"" content))

(defconst chat-tool-caller-parse-error-followup-text
  (concat
   "Your previous response looked like a tool call, but the tool call JSON "
   "could not be parsed.\n"
   "Respond with exactly one valid JSON object of the form "
   "{\"function_call\": {\"name\": \"<tool>\", \"arguments\": {...}}}, "
   "or answer normally without any JSON.")
  "Follow-up text sent when a tool call attempt fails to parse.")

(defun chat-tool-caller--with-call-ids (calls)
  "Return CALLS with an id on each, minting the ones that are missing.

A call parsed out of the reply text carries no provider id, and the id is
not decoration: it is what pairs the call with its result in the next
request.  Turns went to disk without one, and the request builder then
invented an id for the call and a different one for its result, so the
provider refused the history with `tool_call_id is not found'."
  (mapcar (lambda (call)
            (if (plist-get call :id)
                call
              (append (list :id (chat-llm-new-tool-call-id
                                 (plist-get call :name)))
                      call)))
          calls))

;; ------------------------------------------------------------------
;; Accepting MDP as well as JSON
;; ------------------------------------------------------------------

;; Both, during the changeover, and not out of compatibility habit: models
;; differ in how closely they follow a prompt, so switching one way only
;; would take tool calling away from whichever of them did not comply.
;;
;; Which format arrived is counted, because that count is the evidence for
;; deciding whether the JSON branch can ever be removed.  Removing it on a
;; feeling would be betting usability on one.

(defvar chat-tool-caller-format-counts nil
  "How many tool calls arrived in each format, as an alist.")

(defun chat-tool-caller--count-format (format)
  "Record that a tool call arrived as FORMAT."
  (let ((entry (assq format chat-tool-caller-format-counts)))
    (if entry
        (setcdr entry (1+ (cdr entry)))
      (push (cons format 1) chat-tool-caller-format-counts))))

(defun chat-tool-caller--mdp-to-json (value)
  "Return MDP VALUE in the shape the tool layer reads.

MDP keeps `false', `null', `[]' and `{}' apart, and the tool layer
inherited json.el's conventions for them, so the two representations have
to be translated rather than assumed to match."
  (cond
   ((eq value :false) :json-false)
   ((eq value :null) nil)
   ((eq value :empty-object) nil)
   ((and (consp value) (consp (car value)) (stringp (caar value)))
    (mapcar (lambda (field)
              (cons (car field) (chat-tool-caller--mdp-to-json (cdr field))))
            value))
   ((consp value) (mapcar #'chat-tool-caller--mdp-to-json value))
   (t value)))

(defconst chat-tool-caller--mdp-call-keys '("function_call" "tool_call")
  "Field or section names holding a single call.")

(defun chat-tool-caller--calls-from-mdp (content)
  "Return the tool calls MDP CONTENT declares.

Nothing here repairs anything.  What makes MDP worth accepting is that
prose around the payload is a comment by specification, so the tolerance
`chat-tool-caller--fix-broken-json' had to be guessed at is already in the
grammar.  Copying those repairs onto a new format would bring the old
format's illness along with them."
  (let ((value (chat-mdp-parse content)))
    (unless (or (chat-mdp-error-p value) (not (consp value)))
      (let ((calls nil))
        (dolist (key chat-tool-caller--mdp-call-keys)
          (when-let ((call (chat-tool-caller--mdp-call
                            (cdr (assoc key value)))))
            (push call calls)))
        (dolist (entry (cdr (assoc "tool_calls" value)))
          (when-let ((call (chat-tool-caller--mdp-call entry)))
            (push call calls)))
        (nreverse calls)))))

(defun chat-tool-caller--mdp-call (value)
  "Return the tool call VALUE describes, or nil."
  (when (and (consp value) (consp (car value)))
    (let ((name (cdr (assoc "name" value)))
          (arguments (cdr (assoc "arguments" value))))
      (when (and (stringp name) (not (string-empty-p name)))
        (list :name name
              :arguments (let ((converted (chat-tool-caller--mdp-to-json
                                           arguments)))
                           (if (listp converted) converted nil)))))))

(defun chat-tool-caller-parse (content)
  "Parse tool calls from CONTENT.

MDP first, then JSON, and only when MDP found nothing: a payload that
declares a call in MDP has said so unambiguously, while a reply that
merely mentions JSON in prose has not."
  (let ((calls (chat-tool-caller--calls-from-mdp content)))
    (if calls
        (chat-tool-caller--count-format 'mdp)
      (dolist (candidate (chat-tool-caller--extract-json-candidates content))
        (condition-case nil
            (let ((call (chat-tool-caller--call-from-data
                         (chat-tool-caller--decode-json candidate))))
              (when call
                (push call calls)))
          (error nil)))
      (setq calls (nreverse calls))
      (when calls
        (chat-tool-caller--count-format 'json)))
    ;; Ids after `delete-dups', which compares whole plists: minted any
    ;; earlier and no two calls would ever look alike.
    (chat-tool-caller--with-call-ids (delete-dups calls))))

(defconst chat-tool-caller--missing-argument
  (make-symbol "chat-tool-caller-missing-argument")
  "Sentinel used to distinguish a missing argument from JSON false.")

(defun chat-tool-caller--argument-entry (arguments key)
  "Return the entry for KEY in ARGUMENTS."
  (or (assoc key arguments)
      (assoc (intern key) arguments)))

(defun chat-tool-caller--argument-raw-value (arguments key)
  "Read raw KEY from ARGUMENTS or return a missing-value sentinel."
  (let ((entry (chat-tool-caller--argument-entry arguments key)))
    (if entry
        (cdr entry)
      chat-tool-caller--missing-argument)))

(defun chat-tool-caller--argument-value (arguments key)
  "Read normalized KEY from ARGUMENTS."
  (let ((value (chat-tool-caller--argument-raw-value arguments key)))
    (cond
     ((eq value chat-tool-caller--missing-argument) nil)
     ((eq value :json-false) nil)
     (t value))))

(defun chat-tool-caller--required-argument-p (param)
  "Return non-nil when PARAM is required."
  (plist-get param :required))

(defun chat-tool-caller--missing-required-arguments (params arguments)
  "Return missing required parameter names from PARAMS and ARGUMENTS."
  (let (missing)
    (dolist (param params)
      (let ((name (plist-get param :name)))
        (when (and (chat-tool-caller--required-argument-p param)
                   (eq (chat-tool-caller--argument-raw-value arguments name)
                       chat-tool-caller--missing-argument))
          (push name missing))))
    (nreverse missing)))

(defun chat-tool-caller--argument-type-valid-p (value type)
  "Return non-nil when raw VALUE conforms to JSON schema TYPE."
  (pcase type
    ("string" (stringp value))
    ("integer" (integerp value))
    ("number" (numberp value))
    ("boolean" (memq value '(t :json-false)))
    ("array" (or (vectorp value)
                 (proper-list-p value)))
    ("object" (or (hash-table-p value)
                  (null value)
                  (and (listp value)
                       (cl-every #'consp value))))
    (_ t)))

(defun chat-tool-caller--parameter-type-valid-p (value param)
  "Return non-nil when VALUE has PARAM's primary or accepted legacy type."
  (let ((types (cons (or (plist-get param :type) "string")
                     (plist-get param :accepted-types))))
    (seq-some (lambda (type)
                (chat-tool-caller--argument-type-valid-p value type))
              types)))

(defun chat-tool-caller--schema-get (schema key)
  "Return KEY from JSON SCHEMA with symbol or string keys."
  (or (cdr (assoc key schema))
      (and (symbolp key) (cdr (assoc (symbol-name key) schema)))
      (and (stringp key) (cdr (assoc (intern key) schema)))))

(defun chat-tool-caller--object-entries (value)
  "Return JSON object VALUE as an alist."
  (cond
   ((hash-table-p value)
    (let (entries)
      (maphash (lambda (key item) (push (cons key item) entries)) value)
      entries))
   ((listp value) value)
   (t nil)))

(defun chat-tool-caller--validate-schema-value (value schema path)
  "Validate VALUE against nested JSON SCHEMA at PATH."
  (let* ((type (chat-tool-caller--schema-get schema 'type))
         (enum (chat-tool-caller--schema-get schema 'enum)))
    (unless (chat-tool-caller--argument-type-valid-p value type)
      (error "Argument '%s' must be %s" path type))
    (when (and enum (not (member value (append enum nil))))
      (error "Argument '%s' must be one of: %s"
             path
             (mapconcat (lambda (item) (format "%s" item))
                        (append enum nil) ", ")))
    (pcase type
      ("array"
       (let* ((values (if (vectorp value) (append value nil) value))
              (minimum (chat-tool-caller--schema-get schema 'minItems))
              (items (chat-tool-caller--schema-get schema 'items)))
         (when (and minimum (< (length values) minimum))
           (error "Argument '%s' needs at least %d item%s"
                  path minimum (if (= minimum 1) "" "s")))
         (when items
           (cl-loop for item in values
                    for index from 0
                    do (chat-tool-caller--validate-schema-value
                        item items (format "%s[%d]" path index))))))
      ("object"
       (let* ((entries (chat-tool-caller--object-entries value))
              (properties (chat-tool-caller--schema-get schema 'properties))
              (required (append
                         (or (chat-tool-caller--schema-get schema 'required)
                             nil)
                         nil))
              (additional
               (chat-tool-caller--schema-get schema 'additionalProperties))
              (names (mapcar (lambda (entry)
                               (let ((key (car entry)))
                                 (if (symbolp key) (symbol-name key) key)))
                             entries)))
         (dolist (name required)
           (unless (member name names)
             (error "Missing required argument: %s.%s" path name)))
         (dolist (entry entries)
           (let* ((key (car entry))
                  (name (if (symbolp key) (symbol-name key) key))
                  (property (or (cdr (assoc name properties))
                                (cdr (assoc (intern name) properties)))))
             (cond
              (property
               (chat-tool-caller--validate-schema-value
                (cdr entry) property (format "%s.%s" path name)))
              ((eq additional :json-false)
               (error "Unknown argument: %s.%s" path name))))))))
    value))

(defun chat-tool-caller--argument-name (entry)
  "Return ENTRY key as a string."
  (let ((key (car entry)))
    (if (symbolp key) (symbol-name key) key)))

(defun chat-tool-caller--validate-arguments (tool arguments)
  "Validate ARGUMENTS against TOOL parameter declarations.
Signal a user-facing error for missing, unknown, mistyped, or invalid
enumerated values."
  (unless (or (null arguments)
              (and (listp arguments) (cl-every #'consp arguments)))
    (error "Tool arguments must be a JSON object"))
  (let* ((params (or (chat-forged-tool-parameters tool) nil))
         (names (mapcar (lambda (param) (plist-get param :name)) params))
         (missing (chat-tool-caller--missing-required-arguments params arguments))
         (unknown
          (delq nil
                (mapcar
                 (lambda (entry)
                   (let ((name (chat-tool-caller--argument-name entry)))
                     (unless (member name names) name)))
                 arguments))))
    (when missing
      (error "Missing required arguments: %s"
             (mapconcat #'identity missing ", ")))
    (when unknown
      (error "Unknown arguments: %s"
             (mapconcat #'identity unknown ", ")))
    (dolist (param params)
      (let* ((name (plist-get param :name))
             (value (chat-tool-caller--argument-raw-value arguments name))
             (type (or (plist-get param :type) "string"))
             (enum (plist-get param :enum))
             (items (plist-get param :items))
             (min-items (plist-get param :min-items)))
        (unless (eq value chat-tool-caller--missing-argument)
          (unless (chat-tool-caller--parameter-type-valid-p value param)
            (error "Argument '%s' must be %s" name type))
          (when (and enum (not (member value enum)))
            (error "Argument '%s' must be one of: %s"
                   name
                   (mapconcat (lambda (item) (format "%s" item))
                              enum ", "))))
          (when (and (chat-tool-caller--argument-type-valid-p value type)
                     (or items min-items))
            (chat-tool-caller--validate-schema-value
             value
             (append `((type . ,type))
                     (when items `((items . ,items)))
                     (when min-items `((minItems . ,min-items))))
             name)))))
  arguments)

(defun chat-tool-caller--arguments-to-argv (tool arguments)
  "Convert TOOL ARGUMENTS alist to an argv list."
  (chat-tool-caller--validate-arguments tool arguments)
  (let ((params (chat-forged-tool-parameters tool)))
    (cond
     ((and (listp params) params)
      (mapcar (lambda (param)
                (chat-tool-caller--argument-value
                 arguments
                 (plist-get param :name)))
              params))
     ((chat-tool-caller--argument-value arguments "input")
      (list (chat-tool-caller--argument-value arguments "input")))
     ((null arguments)
      nil)
     (t
      (mapcar #'cdr arguments)))))

(defun chat-tool-caller--stringify-result (result)
  "Convert RESULT into a stable string."
  (cond
   ((stringp result) result)
   ((null result) "nil")
   (t
    (string-trim-right (pp-to-string result)))))

(defun chat-tool-caller--compact-text (text &optional max-chars)
  "Normalize TEXT and keep at most MAX-CHARS characters."
  (let* ((limit (or max-chars 120))
         (normalized (replace-regexp-in-string
                      "[ \t\n\r]+"
                      " "
                      (string-trim (or text "")))))
    (if (> (length normalized) limit)
        (concat (substring normalized 0 limit) "...")
      normalized)))

(defun chat-tool-caller--notify (observer event)
  "Send EVENT to OBSERVER."
  (when observer
    (funcall observer event)))

(defun chat-tool-caller--tool-arguments-summary (arguments)
  "Return a compact summary for ARGUMENTS."
  (chat-tool-caller--compact-text (format "%S" arguments)))

(defun chat-tool-caller--tool-result-summary (result)
  "Return a compact summary for RESULT."
  (chat-tool-caller--compact-text (chat-tool-caller--stringify-result result)))

(defun chat-tool-caller--event-command-context (arguments)
  "Return event plist additions for shell command ARGUMENTS."
  (when-let ((command (cdr (assoc "command" arguments))))
    (list :command command)))

(defun chat-tool-caller--file-tool-p (tool-id)
  "Return non-nil when TOOL-ID is a file tool."
  (memq tool-id '(files_read files_read_lines files_grep files_find files_list
                  files_write files_replace files_patch apply_patch)))

(defun chat-tool-caller--access-denied-hint (tool-id error-message)
  "Return ERROR-MESSAGE with a hint about code capability when useful."
  (if (and (chat-tool-caller--file-tool-p tool-id)
           (string-match-p "path outside allowed directories" error-message)
           (null (chat-tool-caller--code-project-root)))
      (concat error-message
              ". Start a session from the project root with `chat-code-start', or give this one code capability with `chat-code-from-chat', before searching the repository")
    error-message))

(defun chat-tool-caller--code-project-root (&optional session)
  "Return the project root of SESSION, when it has one.

Code capability is a property of a session, so the root is read from the
explicit SESSION first, then the current tool execution or buffer session.
This order matters for callbacks running while another chat buffer is
current."
  (let ((session (or session
                     chat-tool-caller-current-session
                     (and (boundp 'chat--current-session)
                          chat--current-session))))
    (when (and session
               (fboundp 'chat-code-session-p)
               (chat-code-session-p session)
               (fboundp 'chat-code-session-project-root))
      (chat-code-session-project-root session))))

(defun chat-tool-caller--allowed-directories ()
  "Return effective file roots for the current tool execution."
  (let ((project-root (chat-tool-caller--code-project-root)))
    (delete-dups
     (append (when project-root
               (list project-root))
             chat-files-allowed-directories))))

(defun chat-tool-caller--execution-directory (&optional session)
  "Return the working directory for the current tool execution.

A directory SESSION was pointed at wins over the detected project
project root, so tools follow an explicit change of directory.  The
ambient value is the last resort, because tools can run from a process
sentinel where the current buffer is not the chat buffer.

SESSION is passed in rather than read from
`chat-tool-caller-current-session', which is bound by the same `let' that
calls this function and so is not yet visible here."
  (or (chat-session-working-directory
       (or session chat-tool-caller-current-session))
      (chat-tool-caller--code-project-root session)
      default-directory))

(defun chat-tool-caller-call-tool (call)
  "Return the registered tool targeted by CALL."
  (let ((tool-id (intern (plist-get call :name))))
    (or (chat-tool-forge-get tool-id)
        (when (and (eq tool-id 'shell_execute)
                   (require 'chat-tool-shell nil t))
          (chat-tool-forge-get tool-id)))))

(defun chat-tool-caller-call-approval-required-p (call)
  "Return non-nil when CALL requires serialized approval."
  (when-let ((tool (chat-tool-caller-call-tool call)))
    (chat-approval-tool-required-p tool call)))

(defun chat-tool-caller-call-resource-accesses (call)
  "Return resource access plists for scheduling CALL.
An access contains :resource, :mode, and optional :exclusive."
  (let* ((tool (chat-tool-caller-call-tool call))
         (resource-fn (and tool (chat-forged-tool-resource-function tool)))
         (effects (and tool (chat-forged-tool-effects tool)))
         (tool-id (and tool (chat-forged-tool-id tool)))
         (approval (and tool
                        (chat-approval-tool-required-p tool call)))
         accesses)
    (when resource-fn
      (setq accesses (funcall resource-fn call)))
    (when (seq-some (lambda (effect)
                      (memq effect '(write destructive)))
                    effects)
      (push '(:resource "global-write" :mode write :exclusive t) accesses))
    (when approval
      (push '(:resource "approval" :mode write :exclusive t) accesses))
    (unless accesses
      (push (list :resource (format "tool:%s" tool-id)
                  :mode 'read)
            accesses))
    (nreverse accesses)))

(defun chat-tool-caller-cancel-handle (handle)
  "Cancel asynchronous tool HANDLE when possible."
  (cond
   ((functionp handle)
    (ignore-errors (funcall handle)))
   ((processp handle)
    (when (process-live-p handle)
      (delete-process handle)))
   ((and (consp handle) (functionp (plist-get handle :cancel)))
    (ignore-errors (funcall (plist-get handle :cancel))))))

(defmacro chat-tool-caller--with-execution-context (session &rest body)
  "Run BODY with the file boundary and working directory SESSION implies.

Re-established rather than inherited, because a guard verdict arrives in an
HTTP callback: the dynamic bindings the enclosing `let' set up are long
gone by then.  Inheriting them worked only as long as authorization was
synchronous, and the failure it produces when it stops being synchronous is
the quiet kind -- the tool runs against the global
`chat-files-allowed-directories' instead of the session's, so the path
boundary the floor relies on is wider than anyone asked for."
  (declare (indent 1))
  `(let* ((chat-tool-caller-current-session ,session)
          (chat-execution-current-context
           chat-tool-caller-current-execution-context)
          (chat-files-current-read-set
           (plist-get chat-tool-caller-current-execution-context :read-set))
          (chat-files-current-observation-context
           chat-tool-caller-current-execution-context)
          (chat-files-enforce-read-set
           (hash-table-p chat-files-current-read-set))
          (chat-files-allowed-directories
           (chat-tool-caller--allowed-directories))
          (default-directory
           (file-name-as-directory
            (chat-files--resolved-path
             (chat-tool-caller--execution-directory ,session)))))
     ,@body))

(defun chat-tool-caller--denial-text (name reason)
  "Return what the assistant is told when CALL of NAME was denied for REASON.

Three parts, and each is there because leaving it out changed what the
assistant did next.  It says the decision was an automatic policy one
rather than the user objecting, because those mean opposite things: a
person refusing means stop and wait, a policy refusing means this route is
closed.  It gives the reason, because \"Approval denied\" with nothing
after it is what sent a run round the same loop for eight minutes.  And it
names the two ways forward, without the word STOP -- a policy denial is
usually worth working around, and telling the assistant to halt on one
throws away a task that had another route."
  (format "%s %s %s"
          (format (concat "Denied: the automatic approval policy did not"
                          " permit this call to '%s' (this is not the user"
                          " declining).")
                  name)
          (if reason (format "Reason: %s." reason) "")
          (concat "You may try a different approach that stays within the"
                  " policy, or explain this limitation and finish without"
                  " it. Do not repeat this same call unchanged.")))

(defun chat-tool-caller--run-async-tool
    (tool name arguments consent observer success error-callback)
  "Run TOOL's asynchronous function for CALL, already authorized as CONSENT.

The caller has re-established the execution context; this spawns the work
inside it, since an async tool validates its command and starts its
process before returning."
  (let ((argv (chat-tool-caller--arguments-to-argv tool arguments)))
    (cl-incf (chat-forged-tool-usage-count tool))
    ;; The binding has to cover the call that starts the work, not the
    ;; callbacks: an async tool validates its command and spawns the
    ;; process before returning, and a dynamic binding would be long gone
    ;; by the time output arrives.
    (let ((chat-approval-consent consent))
      (funcall
       (chat-forged-tool-async-function tool)
       argv
       (lambda (result)
         (let ((text (chat-tool-caller--stringify-result result)))
           (chat-tool-caller--notify
            observer
            (list :type 'tool-result
                  :tool name
                  :result-summary
                  (chat-tool-caller--tool-result-summary text)))
           (funcall success text)))
       (lambda (message)
         (let ((text (format "Error executing tool '%s': %s" name message)))
           (chat-tool-caller--notify
            observer
            (list :type 'tool-error
                  :tool name
                  :result-summary (chat-tool-caller--compact-text text)))
           (funcall error-callback text)))))))

(defun chat-tool-caller-execute-async
    (call session observer success error-callback
          &optional execution-context state-session)
  "Execute CALL and invoke SUCCESS or ERROR-CALLBACK.

The one place live tool execution is authorized, and it happens before the
split between tools that have an asynchronous runner and tools that do
not.  It used to happen after: a tool without an async function was handed
to the synchronous path, which authorized it separately, so which of two
authorization sites applied depended on whether the tool happened to be
asynchronous.  That is the same shape as the bug where a grant took effect
or did not for the same reason.

A denial arrives through SUCCESS, not ERROR-CALLBACK.  It is a policy
outcome the assistant should read and route around, and reporting it as a
tool fault gets it the wrong wording and the wrong handling from the agent
loop.  Return one stable cancellation handle whose active target follows
the call from authorization into asynchronous execution."
  (let* ((chat-tool-caller-current-execution-context execution-context)
         (chat-tool-caller-current-state-session (or state-session session))
         (tool (chat-tool-caller-call-tool call))
         (name (plist-get call :name))
         (arguments (plist-get call :arguments))
         (tool-id (intern name))
         (actual-session (or session
                             (when (boundp 'chat--current-session)
                               chat--current-session)))
         (cancelled nil)
         (active-handle nil)
         (stable-handle
          (list
           :cancel
           (lambda ()
             (setq cancelled t)
             (chat-tool-caller-cancel-handle active-handle)))))
    (condition-case err
        (progn
          (chat-tool-caller--with-execution-context actual-session
            (chat-tool-caller--notify
             observer
             (append (list :type 'tool-call
                           :tool name
                           :arguments arguments)
                     (when tool
                       (chat-tool-caller--permission-metadata tool))))
            (cond
             ((null tool)
              (funcall success (format "Error: Tool '%s' not found" name)))
             ((not (chat-session-tool-enabled-p actual-session tool-id))
              (let ((text
                     (format "Error: Tool '%s' is disabled for this session"
                             name)))
                (chat-tool-caller--notify
                 observer
                 (list :type 'tool-error :tool name :result-summary text))
                (funcall success text)))
             ((not (chat-tool-caller--tool-available-in-session-p
                    tool actual-session))
              (let ((text
                     (format "Error: Tool '%s' is unavailable for this turn"
                             name)))
                (chat-tool-caller--notify
                 observer
                 (list :type 'tool-error :tool name :result-summary text))
                (funcall success text)))
             (t
              (let ((authorization-handle
                     (chat-approval-authorize-async
                      tool call actual-session observer
                      (lambda (consent reason)
                        ;; Re-established here: with a guard this callback runs
                        ;; from an HTTP response, by which time the bindings
                        ;; above are gone.  A cancelled call ignores a late
                        ;; verdict entirely; no tool may begin after its run
                        ;; has already ended.
                        (unless cancelled
                          (let ((chat-tool-caller-current-execution-context
                                 execution-context)
                                (chat-tool-caller-current-state-session
                                 (or state-session actual-session)))
                            (chat-tool-caller--with-execution-context
                                actual-session
                              (cond
                               ((not consent)
                                (let ((text
                                       (chat-tool-caller--denial-text
                                        name reason)))
                                  (chat-tool-caller--notify
                                   observer
                                   (list :type 'tool-error
                                         :tool name
                                         :result-summary
                                         (chat-tool-caller--compact-text
                                          text)))
                                  (funcall success text)))
                               ((chat-forged-tool-async-function tool)
                                (setq
                                 active-handle
                                 (chat-tool-caller--run-async-tool
                                  tool name arguments consent
                                  observer success error-callback)))
                               (t
                                (funcall
                                 success
                                 (chat-tool-caller--execute-authorized
                                  tool call actual-session observer
                                  consent)))))))))))
                ;; Fast-path approval may invoke the callback synchronously.
                ;; Preserve the actual tool handle installed by that callback;
                ;; otherwise track the still-pending authorization request.
                (unless active-handle
                  (setq active-handle authorization-handle))))))
          stable-handle)
      (error
       (let ((text (format "Error executing tool '%s': %s"
                           name (error-message-string err)))
             (error-type (chat-tool-caller--condition-error-type err)))
         (chat-tool-caller--notify
          observer
          (append (list :type 'tool-error
                        :tool name
                        :result-summary (chat-tool-caller--compact-text text))
                  (when error-type (list :error-type error-type))))
         (funcall error-callback text))))))

(defun chat-tool-caller--execute-authorized
    (tool call _session observer consent)
  "Run CALL of TOOL, which has already been authorized as CONSENT.

Split out so that authorization happens exactly once per call.  Both entry
points authorize and then land here; when the asynchronous one delegates a
tool that has no asynchronous runner, it does not go back through a second
authorization, which would ask a second time under `manual'.

The caller has re-established the execution context."
  (let ((name (plist-get call :name))
        (arguments (plist-get call :arguments))
        (tool-id (chat-forged-tool-id tool)))
    (condition-case err
        (let ((result
               (chat-tool-caller--stringify-result
                (let ((chat-approval-consent consent))
                  (chat-tool-forge-execute
                   tool-id
                   (chat-tool-caller--arguments-to-argv tool arguments))))))
          (chat-tool-caller--notify
           observer
           (list :type 'tool-result
                 :tool name
                 :result-summary
                 (chat-tool-caller--tool-result-summary result)))
          result)
      (error
       (let ((error-type (chat-tool-caller--condition-error-type err))
             (result
              (format "Error executing tool '%s': %s"
                      name
                      (chat-tool-caller--access-denied-hint
                       tool-id (error-message-string err)))))
         (chat-tool-caller--notify
          observer
          (append (list :type 'tool-error
                        :tool name
                        :result-summary (chat-tool-caller--compact-text result))
                  (when error-type (list :error-type error-type))))
         result)))))

(defun chat-tool-caller-execute (call &optional session observer)
  "Execute one parsed tool CALL synchronously and return its result text.
Optional SESSION is the current chat session for approval context.
If SESSION is nil, uses `chat--current-session' if bound.

Not on the live path -- `chat-tool-caller-execute-async' is the only
execution entry the agent loop and workflows use -- but still public, and
called directly by tests and prototypes.  It authorizes for itself rather
than trusting its caller, and under `guarded' with a guard available it
refuses: there is nowhere in a synchronous function to wait for a verdict,
and falling back to the rules the guard was configured to replace would be
a silent downgrade of the mode."
  (let* ((chat-tool-caller-current-state-session session)
         (name (plist-get call :name))
         (arguments (plist-get call :arguments))
         (tool-id (intern name))
         (tool (chat-tool-caller-call-tool call))
         (actual-session (or session
                             (when (boundp 'chat--current-session)
                               chat--current-session))))
    (condition-case err
        (chat-tool-caller--with-execution-context actual-session
          (chat-tool-caller--notify
           observer
           (append
            (list :type 'tool-call
                  :tool name
                  :arguments arguments)
            (when tool
              (chat-tool-caller--permission-metadata tool))))
          (cond
           ((null tool)
            (format "Error: Tool '%s' not found" name))
           ((not (chat-session-tool-enabled-p actual-session tool-id))
            (let ((result
                   (format "Error: Tool '%s' is disabled for this session"
                           name)))
              (chat-tool-caller--notify
               observer
               (list :type 'tool-error
                     :tool name
                     :result-summary result))
              result))
           ((not (chat-tool-caller--tool-available-in-session-p
                  tool actual-session))
            (let ((result (format "Error: Tool '%s' is unavailable for this turn" name)))
              (chat-tool-caller--notify
               observer
               (list :type 'tool-error
                     :tool name
                     :result-summary result))
              result))
           (t
            (let ((consent (chat-approval-authorize
                            tool call actual-session observer)))
              (if consent
                  (chat-tool-caller--execute-authorized
                   tool call actual-session observer consent)
                (let ((result (chat-tool-caller--denial-text name nil)))
                  (chat-tool-caller--notify
                   observer
                   (list :type 'tool-error
                         :tool name
                         :result-summary
                         (chat-tool-caller--compact-text result)))
                  result))))))
      (error
       (let ((result
              (format "Error executing tool '%s': %s"
                      name
                      (chat-tool-caller--access-denied-hint
                       tool-id
                       (error-message-string err)))))
         (chat-tool-caller--notify
          observer
          (list :type 'tool-error
                :tool name
                :result-summary (chat-tool-caller--compact-text result)))
         result)))))

(defun chat-tool-caller-extract-content (content)
  "Extract user-facing text from CONTENT."
  (let* ((trimmed (string-trim content))
         (fragments (chat-tool-caller--tool-json-fragments content)))
    (cond
     ((null fragments)
      content)
     ((and (string-prefix-p "{" trimmed)
           (string-suffix-p "}" trimmed))
      "")
     (t
      (let ((result content)
            (pos 0))
        (while (string-match "```json" result pos)
          (let ((start (match-beginning 0))
                (after-start (match-end 0))
                end)
            (setq end (string-match "```" result after-start))
            (if end
                (setq result (concat (substring result 0 start)
                                     (substring result (+ end 3))))
              (setq pos (length result)))))
        (dolist (fragment fragments)
          (setq result (replace-regexp-in-string
                        (regexp-quote fragment)
                        ""
                        result
                        t
                        t)))
        (string-trim-right result))))))

(defun chat-tool-caller-process-response-data (content &optional _session observer)
  "Process CONTENT and return a result plist.

Parses and reports; it does not execute.  It used to carry a loop over the
parsed calls that ran each one, and that loop could not run: the agent loop
calls this only from the branch where there are no calls to run
\(`chat-agent-loop.el', the `(t ...)' arm), so the loop body always had
nothing to iterate.  What it did have was a route to execution that
authorized nothing, with no caller to notice it drifting -- which is the
next hole rather than dead code.

The calls returned here are persisted alongside their results, so they
have to carry the ids the next request will pair them by."
  (let* ((calls (chat-tool-caller-parse content))
         (parse-error (and (null calls)
                           (chat-tool-caller--attempted-tool-call-p content))))
    (when (and observer
               (not (string-empty-p (string-trim (chat-tool-caller-extract-content content)))))
      (funcall observer
               (list :type 'thinking
                     :summary (chat-tool-caller--compact-text
                               (chat-tool-caller-extract-content content)))))
    (list :content (string-trim-right (chat-tool-caller-extract-content content))
          :tool-calls calls
          :tool-results nil
          :tool-events nil
          :parse-error parse-error)))

(defun chat-tool-caller-process-response (content callback)
  "Process CONTENT then call CALLBACK."
  (let* ((result (chat-tool-caller-process-response-data content))
         (tool-results (plist-get result :tool-results)))
    (funcall callback
             (plist-get result :content)
             (when tool-results
               (mapconcat #'identity tool-results "\n")))))

(provide 'chat-tool-caller)
;;; chat-tool-caller.el ends here
