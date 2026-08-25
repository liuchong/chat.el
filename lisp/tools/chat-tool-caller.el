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

(defun chat-tool-caller-truncate-result (result &optional max-chars)
  "Keep RESULT within MAX-CHARS, appending an omission marker when cut."
  (let* ((text (or result ""))
         (limit (or max-chars chat-tool-caller-result-max-chars)))
    (if (> (length text) limit)
        (format "%s\n... [truncated, %d chars omitted]"
                (substring text 0 limit)
                (- (length text) limit))
      text)))

(defun chat-tool-caller--tool-available-p (tool)
  "Return non-nil when TOOL should be exposed to the model."
  (let ((tool-id (chat-forged-tool-id tool)))
    (and (chat-session-tool-enabled-p chat-tool-caller-current-session tool-id)
         (cond
          ((eq tool-id 'shell_execute)
           (bound-and-true-p chat-tool-shell-enabled))
          (t
           (chat-forged-tool-is-active tool))))))

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
              (desc (or (plist-get param :description) ""))
              (enum (plist-get param :enum)))
          (push (cons name
                      (append `((type . ,type) (description . ,desc))
                              (when enum
                                `((enum . ,(vconcat enum))))))
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
     "- If a write tool needs approval, wait for approval instead of printing the intended file body in chat.")
   "\n"))

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
  (let ((base (if-let ((memory (and (fboundp 'chat-memory-snippet)
                                    (chat-memory-snippet))))
                  (concat base-prompt "\n\n" memory)
                base-prompt)))
    (when-let ((storage (chat-tool-caller--durable-storage-note session)))
      (setq base (concat base "\n\n" storage)))
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
  "Extract one tool call plist from decoded JSON DATA."
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

(defun chat-tool-caller-parse (content)
  "Parse tool calls from CONTENT."
  (let ((calls nil))
    (dolist (candidate (chat-tool-caller--extract-json-candidates content))
      (condition-case nil
          (let ((call (chat-tool-caller--call-from-data
                       (chat-tool-caller--decode-json candidate))))
            (when call
              (push call calls)))
        (error nil)))
    (nreverse (delete-dups calls))))

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
                 (null value)
                 (and (listp value)
                      (not (consp (car-safe value))))))
    ("object" (or (hash-table-p value)
                  (null value)
                  (and (listp value)
                       (cl-every #'consp value))))
    (_ t)))

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
             (enum (plist-get param :enum)))
        (unless (eq value chat-tool-caller--missing-argument)
          (unless (chat-tool-caller--argument-type-valid-p value type)
            (error "Argument '%s' must be %s" name type))
          (when (and enum (not (member value enum)))
            (error "Argument '%s' must be one of: %s"
                   name
                   (mapconcat (lambda (item) (format "%s" item))
                              enum ", ")))))))
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
  "Return ERROR-MESSAGE with a code-mode hint when useful."
  (if (and (chat-tool-caller--file-tool-p tool-id)
           (string-match-p "path outside allowed directories" error-message)
           (null (chat-tool-caller--code-project-root)))
      (concat error-message
              ". Start code mode from the project root or switch this conversation to code mode before searching the repository")
    error-message))

(defun chat-tool-caller--shell-whitelist-approve-p (call)
  "Check if shell command in CALL is whitelisted for auto-approval."
  (let ((arguments (plist-get call :arguments))
        (require (require 'chat-tool-shell nil t)))
    (when require
      (let ((command (cdr (assoc "command" arguments))))
        (and command
             (fboundp 'chat-tool-shell-whitelist-match-p)
             (chat-tool-shell-whitelist-match-p command))))))

(defun chat-tool-caller--code-project-root ()
  "Return the current code mode project root, when available."
  (when (and (boundp 'chat-code--current-session)
             chat-code--current-session
             (fboundp 'chat-code-session-project-root))
    (chat-code-session-project-root chat-code--current-session)))

(defun chat-tool-caller--allowed-directories ()
  "Return effective file roots for the current tool execution."
  (let ((project-root (chat-tool-caller--code-project-root)))
    (delete-dups
     (append (when project-root
               (list project-root))
             chat-files-allowed-directories))))

(defun chat-tool-caller--execution-directory (&optional session)
  "Return the working directory for the current tool execution.

A directory SESSION was pointed at wins over the detected code mode
project root, so tools follow an explicit change of directory.  The
ambient value is the last resort, because tools can run from a process
sentinel where the current buffer is not the chat buffer.

SESSION is passed in rather than read from
`chat-tool-caller-current-session', which is bound by the same `let' that
calls this function and so is not yet visible here."
  (or (chat-session-working-directory
       (or session chat-tool-caller-current-session))
      (chat-tool-caller--code-project-root)
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

(defun chat-tool-caller-execute-async
    (call session observer success error-callback)
  "Execute CALL and invoke SUCCESS or ERROR-CALLBACK.
Tools without an asynchronous runner complete synchronously through the
normal execution path. Asynchronous runners receive ARGV, SUCCESS, and
ERROR-CALLBACK and return a cancellable handle."
  (let ((tool (chat-tool-caller-call-tool call)))
    (if (not (and tool (chat-forged-tool-async-function tool)))
        (funcall success (chat-tool-caller-execute call session observer))
      (let* ((name (plist-get call :name))
             (arguments (plist-get call :arguments))
             (tool-id (chat-forged-tool-id tool))
             (actual-session (or session
                                 (when (boundp 'chat--current-session)
                                   chat--current-session))))
        (condition-case err
            (let ((chat-tool-caller-current-session actual-session)
                  (chat-files-allowed-directories
                   (chat-tool-caller--allowed-directories))
                  (default-directory
                   (file-name-as-directory
                    (chat-files--resolved-path
                     (chat-tool-caller--execution-directory actual-session)))))
              (chat-tool-caller--notify
               observer
               (append (list :type 'tool-call
                             :tool name
                             :arguments arguments)
                       (chat-tool-caller--permission-metadata tool)))
              (unless (chat-session-tool-enabled-p actual-session tool-id)
                (error "Tool '%s' is disabled for this session" name))
              (let ((argv (chat-tool-caller--arguments-to-argv tool arguments)))
                (if (not (chat-approval-request-tool-call
                          tool call actual-session observer))
                    (let ((text (format "Approval denied for tool '%s'" name)))
                      (chat-tool-caller--notify
                       observer
                       (list :type 'tool-error
                             :tool name
                             :result-summary text))
                      (funcall error-callback text))
                  (cl-incf (chat-forged-tool-usage-count tool))
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
                     (let ((text (format "Error executing tool '%s': %s"
                                         name message)))
                       (chat-tool-caller--notify
                        observer
                        (list :type 'tool-error
                              :tool name
                              :result-summary
                              (chat-tool-caller--compact-text text)))
                       (funcall error-callback text)))))))
          (error
           (let ((text (format "Error executing tool '%s': %s"
                               name (error-message-string err))))
             (chat-tool-caller--notify
              observer
              (list :type 'tool-error
                    :tool name
                    :result-summary
                    (chat-tool-caller--compact-text text)))
             (funcall error-callback text))))))))

(defun chat-tool-caller-execute (call &optional session observer)
  "Execute one parsed tool CALL.
Optional SESSION is the current chat session for approval context.
If SESSION is nil, uses `chat--current-session' if bound."
  (let* ((name (plist-get call :name))
         (arguments (plist-get call :arguments))
         (tool-id (intern name))
         (tool (chat-tool-caller-call-tool call))
         (actual-session (or session
                             (when (boundp 'chat--current-session)
                               chat--current-session))))
    (condition-case err
        (let ((chat-tool-caller-current-session actual-session)
              (chat-files-allowed-directories (chat-tool-caller--allowed-directories))
              (default-directory (file-name-as-directory
                                  (chat-files--resolved-path
                                   (chat-tool-caller--execution-directory
                                    actual-session)))))
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
            (let ((result (format "Error: Tool '%s' is disabled for this session" name)))
              (chat-tool-caller--notify
               observer
               (list :type 'tool-error
                     :tool name
                     :result-summary result))
              result))
           (t
              ;; Check shell whitelist first for shell_execute
              (if (and (eq tool-id 'shell_execute)
                       (chat-tool-caller--shell-whitelist-approve-p call))
                  ;; Whitelisted shell command: execute without approval
                  (let ((result
                         (chat-tool-caller--stringify-result
                          (chat-tool-forge-execute
                           tool-id
                           (chat-tool-caller--arguments-to-argv tool arguments)))))
                    (chat-tool-caller--notify
                     observer
                     (append
                      (list :type 'approval
                            :tool name
                            :decision 'whitelisted-command
                            :approved t)
                      (chat-tool-caller--event-command-context arguments)))
                    (chat-tool-caller--notify
                     observer
                     (list :type 'tool-result
                           :tool name
                           :result-summary (chat-tool-caller--tool-result-summary result)))
                    result)
                ;; Normal approval flow
                (if (chat-approval-request-tool-call tool call actual-session observer)
                    (let ((result
                           (chat-tool-caller--stringify-result
                            (chat-tool-forge-execute
                             tool-id
                             (chat-tool-caller--arguments-to-argv tool arguments)))))
                      (chat-tool-caller--notify
                       observer
                       (list :type 'tool-result
                             :tool name
                             :result-summary (chat-tool-caller--tool-result-summary result)))
                      result)
                  (let ((result (format "Approval denied for tool '%s'" name)))
                    (chat-tool-caller--notify
                     observer
                     (list :type 'tool-error
                           :tool name
                           :result-summary result))
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

(defun chat-tool-caller-process-response-data (content &optional session observer)
  "Process CONTENT for SESSION and return a result plist."
  (let* ((calls (chat-tool-caller-parse content))
         (parse-error (and (null calls)
                           (chat-tool-caller--attempted-tool-call-p content)))
         tool-results
         tool-events)
    (when (and observer
               (not (string-empty-p (string-trim (chat-tool-caller-extract-content content)))))
      (funcall observer
               (list :type 'thinking
                     :summary (chat-tool-caller--compact-text
                               (chat-tool-caller-extract-content content)))))
    (cl-loop for call in calls
             for index from 1
             do (push (chat-tool-caller-execute
                       call
                       session
                       (lambda (event)
                         (let ((indexed (copy-tree event)))
                           (setq indexed (plist-put indexed :index index))
                           (push indexed tool-events))))
                      tool-results))
    (list :content (string-trim-right (chat-tool-caller-extract-content content))
          :tool-calls calls
          :tool-results (nreverse tool-results)
          :tool-events (nreverse tool-events)
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
