;;; chat-code.el --- AI code editing mode for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, ai, code, programming

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides AI-powered code editing capabilities for chat.el.
;; It implements a specialized chat mode for programming tasks with:
;;
;; - Project-aware context management
;; - Code-specific tools and prompts
;; - Preview-based editing workflow
;; - Single-window design (respects user's window layout)
;;
;; Design principles:
;; - No forced window splits - all operations in single buffer
;; - User controls window layout via standard Emacs commands
;; - Preview in separate buffer, manually switched
;; - All editing actions are atomic and reversible

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'subr-x)
(require 'chat-session)
(require 'chat-llm)
(require 'chat-files)
(require 'chat-context)
(require 'chat-context-code)
(require 'chat-edit)
(require 'chat-code-preview)
(require 'chat-code-intel)
(require 'chat-stream)
(require 'chat-code-lsp)
(require 'chat-tool-caller)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-code nil
  "AI code editing for chat.el."
  :group 'chat
  :prefix "chat-code-")

(defcustom chat-code-enabled t
  "Enable code mode features."
  :type 'boolean
  :group 'chat-code)

(defcustom chat-code-default-strategy 'balanced
  "Default context strategy for code mode.
\='minimal      - Current file only (~2k tokens)
\='focused      - Current file + related files (~4k tokens)
\='balanced     - + Symbols + Imports (~8k tokens)
\='comprehensive - Full project structure (~16k tokens)"
  :type '(choice (const minimal)
                 (const focused)
                 (const balanced)
                 (const comprehensive))
  :group 'chat-code)

(defcustom chat-code-max-tokens 16000
  "Maximum tokens for code mode context."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-history-max-tokens 8000
  "Maximum tokens reserved for conversation history in code mode requests."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-max-output-tokens 4096
  "Maximum completion tokens requested for code mode responses."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-request-timeout 180
  "Timeout in seconds for non-streaming code mode requests."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-request-safety-margin 2048
  "Safety margin kept free in the model context window."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-tool-result-summary-max-chars 240
  "Maximum characters kept in summarized tool results."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-auto-apply-threshold 10
  "Automatically apply changes smaller than this many lines.
Set to 0 to never auto-apply."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-system-prompt
  "You are an expert programmer. Help the user write, understand, and modify code.

When making changes:
- Follow existing code style and conventions
- Add error handling where appropriate
- Include tests for new functionality
- Document public APIs with clear docstrings
- Prefer small, focused changes over large rewrites
- Use the available tools only through the JSON tool calling protocol
- When generating code, consider the project's existing patterns
- Treat the active project root as the default working directory
- Prefer file tools for inspection before shell commands
- Use shell commands only for lightweight readonly inspection when file tools are not enough
- Stay inside the active project unless the user explicitly asks to leave it
- Do not repeat the same blocked tool pattern after access denied, approval denied, or command not allowed
- Stop using tools once you have enough evidence to answer
- Keep tool usage efficient, directed, and production quality rather than exploratory for its own sake"
  "System prompt for code mode."
  :type 'string
  :group 'chat-code)

(defconst chat-code--hard-rules
  '("Obey project instruction files in the active project, especially AGENTS.md."
    "Treat current code and observable runtime behavior as the source of truth."
    "If comments, docs, or naming disagree with the implementation, trust the implementation."
    "Comments may clarify intent, but never use comments alone to justify a conclusion."
    "Before changing code, inspect the target file and the most relevant neighboring code paths."
    "Do not invent unsupported behavior, hidden files, or tool results."
    "Stay inside the active project root unless the user explicitly asks to go elsewhere."
    "If a tool request was blocked or denied, do not retry the same pattern without new evidence."
    "Once enough evidence exists to answer, stop exploring and answer directly.")
  "Non-negotiable rules always sent in code mode.")

(defconst chat-code--coding-best-practices
  '("Prefer concrete code paths, data flow, and call sites over comments or file names."
    "Use the smallest sufficient set of files and tools."
    "Prefer structured file tools before readonly shell inspection."
    "When reading a project, start from the focused file, project instructions, and nearby entry points."
    "For debugging, distinguish observed facts from hypotheses."
    "For fixes, prefer root-cause changes over cosmetic patches."
    "When practical, add or update tests that lock in the behavior being changed.")
  "Reusable programming best practices for code mode.")

(defcustom chat-code-filetype-map
  '(("\\.py$" . python)
    ("\\.js$" . javascript)
    ("\\.ts$" . typescript)
    ("\\.jsx$" . jsx)
    ("\\.tsx$" . tsx)
    ("\\.el$" . emacs-lisp)
    ("\\.go$" . go)
    ("\\.rs$" . rust)
    ("\\.rb$" . ruby)
    ("\\.java$" . java)
    ("\\.c$" . c)
    ("\\.cpp$" . cpp)
    ("\\.h$" . c)
    ("\\.hpp$" . cpp)
    ("\\.sh$" . shell)
    ("\\.md$" . markdown))
  "File extensions to language mapping."
  :type '(repeat (cons string symbol))
  :group 'chat-code)

;; ------------------------------------------------------------------
;; Data Structures
;; ------------------------------------------------------------------

(cl-defstruct chat-code-session
  "A code editing session.
Inherits from chat-session with additional code-specific fields."
  base-session          ; The underlying chat-session
  project-root          ; Project root directory
  focus-file            ; Currently focused file (if any)
  focus-range           ; Focus range (start . end) in focus-file
  context-strategy      ; Context strategy symbol
  context-files         ; List of files in current context
  language              ; Primary language symbol
  edit-history)         ; List of applied edits

;; ------------------------------------------------------------------
;; Session Management
;; ------------------------------------------------------------------

(defvar-local chat-code--current-session nil
  "Current code mode session in this buffer.")
(defvar-local chat-code--messages-end nil
  "Marker for the end of the conversation area.")
(defvar-local chat-code--input-marker nil
  "Marker for the start of the editable input area.")
(defvar-local chat-code--active-request-handle nil
  "Currently active non streaming request handle.")
(defvar-local chat-code--active-stream-process nil
  "Currently active stream process.")
(defvar-local chat-code--pending-edit nil
  "Currently pending edit waiting for user confirmation.")
(defvar-local chat-code--active-request-model nil
  "Model used by the current or most recent code-mode request.")
(defvar-local chat-code--active-request-messages nil
  "Messages used by the current or most recent code-mode request.")

(defvar chat-code--preview-buffer-name "*chat-preview*"
  "Name of the preview buffer.")

(defcustom chat-code-tool-loop-max-steps 100
  "Maximum number of follow-up tool resolution requests in code mode."
  :type 'integer
  :group 'chat-code)

(defvar-local chat-code--status-state 'idle
  "Current status state for the code mode buffer.")
(defvar-local chat-code--status-detail "Ready"
  "Current status detail for the code mode buffer.")

(defun chat-code--model-label (&optional model)
  "Return a readable label for MODEL."
  (let* ((model-id (or model
                       chat-code--active-request-model
                       (and (chat-code--base-session)
                            (chat-session-model-id (chat-code--base-session)))))
         (provider-name (and model-id
                             (chat-llm-provider-option model-id :name))))
    (or provider-name
        (and model-id (symbol-name model-id))
        "No model")))

(defun chat-code--response-active-p ()
  "Return non nil when a response is already in progress."
  (or chat-code--active-request-handle
      (and (processp chat-code--active-stream-process)
           (process-live-p chat-code--active-stream-process))))

(defun chat-code--stream-started-p (handle)
  "Return non nil when HANDLE means stream startup succeeded."
  (not (null handle)))

(defun chat-code--set-stream-process-sentinel (process sentinel)
  "Install SENTINEL on PROCESS."
  (set-process-sentinel process sentinel))

(defun chat-code--base-session ()
  "Return the base chat session for the current code session."
  (and chat-code--current-session
       (chat-code-session-base-session chat-code--current-session)))

(defun chat-code--status-label (state)
  "Return display label for STATUS."
  (pcase state
    ('idle "Idle")
    ('running "Running")
    ('success "Success")
    ('failed "Failed")
    ('cancelled "Cancelled")
    ('stopped "Stopped")
    (_ "Unknown")))

(defun chat-code--status-face (state)
  "Return face plist for STATUS."
  (pcase state
    ((or 'idle 'cancelled) 'shadow)
    ('running 'font-lock-keyword-face)
    ('success 'success)
    ('failed 'error)
    ('stopped 'warning)
    (_ 'shadow)))

(defun chat-code--header-line ()
  "Return the dynamic header line for the current code buffer."
  (let ((label (chat-code--status-label chat-code--status-state))
        (detail (or chat-code--status-detail "Ready"))
        (model (chat-code--model-label)))
    (concat
     (propertize " Code Mode " 'face 'mode-line-emphasis)
     (propertize (format "Status: %s" label)
                 'face (chat-code--status-face chat-code--status-state))
     (propertize (format " | Model: %s | %s" model detail) 'face 'shadow))))

(defun chat-code--mode-line-status ()
  "Return a concise mode line status string."
  (let ((label (chat-code--status-label chat-code--status-state))
        (detail (or chat-code--status-detail "Ready"))
        (model (chat-code--model-label)))
    (format " [%s|%s|%s]" model label detail)))

(defun chat-code--mode-line-format ()
  "Return the explicit mode line format for code mode."
  (list
   "%e"
   'mode-line-front-space
   'mode-line-buffer-identification
   " "
   'mode-name
   '(:eval (chat-code--mode-line-status))
   "  "
   'mode-line-position))

(defun chat-code--set-status (state &optional detail)
  "Update code mode STATE and optional DETAIL."
  (setq chat-code--status-state state)
  (setq chat-code--status-detail (or detail ""))
  (setq-local header-line-format '(:eval (chat-code--header-line)))
  (setq-local mode-line-format (chat-code--mode-line-format))
  (force-mode-line-update t))

(defun chat-code--operation-guardrails ()
  "Return runtime operational guardrails for the current code session."
  (let ((project-root (and chat-code--current-session
                           (chat-code-session-project-root chat-code--current-session)))
        (focus-file (and chat-code--current-session
                         (chat-code-session-focus-file chat-code--current-session))))
    (mapconcat
     #'identity
     (delq nil
           (list
            "Operational guardrails:"
            (when project-root
              (format "- Active project root: %s" (abbreviate-file-name project-root)))
            (when focus-file
              (format "- Current focus file: %s" (abbreviate-file-name focus-file)))
            "- Default to the active project root as the working directory."
            "- Prefer files_list, files_read, files_read_lines, and files_grep for repository inspection."
            "- Use shell_execute only for lightweight readonly inspection when file tools are not enough."
            "- Use files_find for recursive text discovery across directories, and use files_grep for a known single file."
            "- Avoid broad recursive scans unless the current question truly requires them."
            "- Prefer focused paths over climbing parent directories."
            "- If a tool returns access denied, approval denied, command not allowed, or repeated failure, do not retry the same pattern."
            "- If the answer is already supportable from gathered evidence, stop using tools and answer directly."
            "- If the user asked to create or change files, use write tools directly instead of printing file contents in chat."
            "- If the user asked only for analysis, review, or explanation, stay readonly."))
     "\n")))

(defun chat-code--format-rule-section (title rules)
  "Format TITLE and RULES as a prompt section."
  (concat title "\n"
          (mapconcat (lambda (rule)
                       (format "- %s" rule))
                     rules
                     "\n")))

(defun chat-code--compose-system-prompt ()
  "Compose the full code mode system prompt."
  (mapconcat
   #'identity
   (list
    chat-code-system-prompt
    (chat-code--format-rule-section
     "Non-negotiable rules:"
     chat-code--hard-rules)
    (chat-code--format-rule-section
     "Programming best practices:"
     chat-code--coding-best-practices)
    (chat-code--operation-guardrails))
   "\n\n"))

(defun chat-code--request-output-budget (model)
  "Return the requested output token budget for MODEL."
  (let ((provider-limit (chat-llm-provider-option model :max-output-tokens)))
    (if (and (integerp provider-limit) (> provider-limit 0))
        (min chat-code-max-output-tokens provider-limit)
      chat-code-max-output-tokens)))

(defun chat-code--request-message-budget (model messages)
  "Return the total token budget for MODEL and MESSAGES."
  (let* ((provider-window (chat-llm-provider-option model :context-window))
         (system-tokens (chat-context-total-tokens
                         (seq-take-while (lambda (msg)
                                           (eq (chat-message-role msg) :system))
                                         messages)))
         (desired (+ system-tokens chat-code-history-max-tokens))
         (safe-limit (when (and (integerp provider-window) (> provider-window 0))
                       (max (+ system-tokens 512)
                            (- provider-window
                               (chat-code--request-output-budget model)
                               chat-code-request-safety-margin)))))
    (if safe-limit
        (min desired safe-limit)
      desired)))

(defun chat-code--prepare-request-messages (model messages)
  "Prepare MESSAGES for MODEL without losing earlier context abruptly."
  (chat-context-prepare-messages
   messages
   (chat-code--request-message-budget model messages)))

(defun chat-code--compact-text (text &optional max-chars)
  "Normalize TEXT and keep at most MAX-CHARS characters."
  (let* ((limit (or max-chars chat-code-tool-result-summary-max-chars))
         (normalized (replace-regexp-in-string
                      "[ \t\n\r]+"
                      " "
                      (string-trim (or text "")))))
    (if (> (length normalized) limit)
        (concat (substring normalized 0 limit) "...")
      normalized)))

(defun chat-code--read-tool-result-data (result)
  "Best effort parse RESULT into Lisp data."
  (when (and (stringp result)
             (not (string-empty-p result)))
    (condition-case nil
        (car (read-from-string result))
      (error nil))))

(defun chat-code--plist-like-p (data)
  "Return non nil when DATA looks like a plist."
  (and (listp data)
       (keywordp (car data))))

(defun chat-code--tool-result-data-summary (data)
  "Build a concise summary for parsed tool result DATA."
  (cond
   ((and (chat-code--plist-like-p data)
         (plist-member data :content))
    (let ((path (plist-get data :path))
          (content (plist-get data :content)))
      (chat-code--compact-text
       (format "%s%s"
               (if path
                   (format "%s: " (file-name-nondirectory path))
                 "")
               (or content "")))))
   ((and (chat-code--plist-like-p data)
         (plist-member data :lines))
    (let ((path (plist-get data :path))
          (lines (plist-get data :lines)))
      (chat-code--compact-text
       (format "%s: %s"
               (if path
                   (file-name-nondirectory path)
                 "lines")
               (mapconcat #'identity (seq-take lines 8) " ")))))
   ((and (chat-code--plist-like-p data)
         (plist-member data :path))
    (chat-code--compact-text
     (format "%s %s"
             (file-name-nondirectory (or (plist-get data :path) "file"))
             (or (plist-get data :status)
                 (plist-get data :result)
                 "ok"))))
   ((and (chat-code--plist-like-p data)
         (plist-member data :matches)
         (listp (plist-get data :matches)))
    (let* ((matches (plist-get data :matches))
           (names (mapcar #'file-name-nondirectory (seq-take matches 8))))
      (chat-code--compact-text
       (format "%d matches: %s"
               (or (plist-get data :match-count) (length matches))
               (mapconcat #'identity names ", ")))))
   ((and (listp data)
         data
         (chat-code--plist-like-p (car data))
         (plist-member (car data) :path))
    (let ((names nil)
          (remaining data)
          (used 0)
          name)
      (while remaining
        (setq name
              (file-name-nondirectory
               (or (plist-get (car remaining) :path)
                   (plist-get (car remaining) :name)
                   "")))
        (when (and (not (string-empty-p name))
                   (< used chat-code-tool-result-summary-max-chars))
          (push name names)
          (setq used (+ used (length name) 2)))
        (setq remaining (cdr remaining)))
      (chat-code--compact-text
       (format "%d entries: %s"
               (length data)
               (mapconcat #'identity (nreverse names) ", ")))))
   (t nil)))

(defun chat-code--tool-result-summary (result)
  "Return a compact summary for RESULT."
  (or (chat-code--tool-result-data-summary
       (chat-code--read-tool-result-data result))
      (chat-code--compact-text
       (or (car (split-string (string-trim (or result "")) "\n" t))
           "ok"))))

(defun chat-code--tool-arguments-summary (arguments)
  "Return a compact summary for tool ARGUMENTS."
  (chat-code--compact-text (format "%S" arguments) 120))

(defun chat-code--append-to-messages (fn)
  "Run FN at the end of the conversation area."
  (save-excursion
    (goto-char chat-code--messages-end)
    (funcall fn)
    (set-marker chat-code--messages-end (point))))

(defun chat-code--replace-response-slot (content-start fn)
  "Replace the pending assistant slot starting at CONTENT-START with FN output."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char content-start)
      (delete-region content-start chat-code--messages-end)
      (set-marker chat-code--messages-end (point))
      (funcall fn)
      (set-marker chat-code--messages-end (point)))))

(defun chat-code--render-progress (content-start detail)
  "Render a human readable progress DETAIL at CONTENT-START."
  (chat-code--replace-response-slot
   content-start
   (lambda ()
     (insert (format "%s...\n\n" detail)))))

(defun chat-code--read-file-if-exists (file)
  "Return FILE contents, or nil when FILE does not exist."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun chat-code--normalize-edit-file (path)
  "Resolve edit target PATH against the current project."
  (when (and path (not (string-empty-p path)))
    (expand-file-name path
                      (chat-code-session-project-root chat-code--current-session))))

(defun chat-code--json-get (data key)
  "Get KEY from decoded JSON DATA."
  (or (alist-get key data)
      (alist-get (if (symbolp key) (symbol-name key) key) data nil nil #'equal)))

(defun chat-code--match-fenced-block (content &optional language)
  "Return fenced block data from CONTENT.
When LANGUAGE is non-nil, only match that fenced language.
Returns either the block body string or a list of (LANG BODY)."
  (let ((pattern (if language
                     (format "```%s\n\\(\\(?:.\\|\n\\)*?\\)\n```"
                             (regexp-quote language))
                   "```\\([^\n]*\\)\n\\(\\(?:.\\|\n\\)*?\\)\n```")))
    (when (string-match pattern content)
      (if language
          (match-string 1 content)
        (list (match-string 1 content)
              (match-string 2 content))))))

(defun chat-code--create-explicit-edit (data)
  "Build a `chat-edit' object from explicit DATA."
  (let* ((target-file (or (chat-code--normalize-edit-file
                           (chat-code--json-get data 'file))
                          (chat-code-session-focus-file chat-code--current-session)))
         (description (or (chat-code--json-get data 'description)
                          "AI suggested change"))
         (edit-type (intern (or (chat-code--json-get data 'type) "rewrite")))
         (new-content (or (chat-code--json-get data 'new_content)
                          (chat-code--json-get data 'content))))
    (when (and target-file (stringp new-content))
      (pcase edit-type
        ('generate
         (chat-edit-create-generate target-file new-content description))
        (_
         (let ((original-content (or (chat-code--read-file-if-exists target-file) "")))
           (if (file-exists-p target-file)
               (chat-edit-create-rewrite target-file original-content new-content description)
             (chat-edit-create-generate target-file new-content description))))))))

(defun chat-code--format-tool-results (tool-results)
  "Format TOOL-RESULTS for display."
  (when tool-results
    (mapconcat #'identity tool-results "\n")))

(defun chat-code--tool-display-summary (tool-calls tool-results)
  "Build a concise user-facing summary for TOOL-CALLS and TOOL-RESULTS."
  (let (parts)
    (while (and tool-calls tool-results)
      (let* ((call (car tool-calls))
             (name (plist-get call :name))
             (summary (chat-code--tool-result-summary (car tool-results))))
        (push (format "%s: %s" name summary) parts))
      (setq tool-calls (cdr tool-calls))
      (setq tool-results (cdr tool-results)))
    (when parts
      (mapconcat #'identity (nreverse parts) " | "))))

(defun chat-code--tool-result-lines (tool-calls tool-results)
  "Format TOOL-CALLS and TOOL-RESULTS into readable lines."
  (let (lines)
    (while (and tool-calls tool-results)
      (let* ((call (car tool-calls))
             (name (plist-get call :name))
             (arguments (plist-get call :arguments))
             (result (chat-code--tool-result-summary (car tool-results))))
        (push (format "- %s %s => %s"
                      name
                      (chat-code--tool-arguments-summary arguments)
                      result)
              lines))
      (setq tool-calls (cdr tool-calls))
      (setq tool-results (cdr tool-results)))
    (nreverse lines)))

(defun chat-code--tool-followup-message (tool-calls tool-results)
  "Build a follow-up system message from TOOL-CALLS and TOOL-RESULTS."
  (concat
   "Tool results from the previous step:\n"
   (mapconcat #'identity
              (chat-code--tool-result-lines tool-calls tool-results)
              "\n")
   "\nUse these results to continue helping with the coding task.\n"
   "Do not retry the same path or command pattern after access denied, approval denied, or command not allowed.\n"
   "If you already have enough evidence, stop calling tools and answer directly.\n"
   "If another tool is needed, call one tool as JSON.\n"
   "Otherwise answer normally."))

(defun chat-code--merge-processed-results (base extra)
  "Merge processed tool data from BASE and EXTRA."
  (list :content (plist-get extra :content)
        :tool-loop-limit-reached (or (plist-get base :tool-loop-limit-reached)
                                     (plist-get extra :tool-loop-limit-reached))
        :tool-calls (append (plist-get base :tool-calls)
                            (plist-get extra :tool-calls))
        :tool-results (append (plist-get base :tool-results)
                              (plist-get extra :tool-results))))

(defun chat-code--display-processed-response (processed content-start)
  "Render PROCESSED response starting at CONTENT-START."
  (let* ((content (string-trim-right
                   (chat-tool-caller-extract-content
                    (or (plist-get processed :content) ""))))
         (tool-calls (plist-get processed :tool-calls))
         (tool-results (plist-get processed :tool-results))
         (tool-summary (chat-code--tool-display-summary tool-calls tool-results))
         (tool-loop-limit-reached (plist-get processed :tool-loop-limit-reached))
         (edit (chat-code--parse-code-edit content)))
    (if edit
        (chat-code--replace-response-slot
         content-start
         (lambda ()
           (chat-code--propose-edit edit)))
      (chat-code--replace-response-slot
       content-start
       (lambda ()
         (unless (string-empty-p content)
           (chat-code--insert-formatted-response content))
         (when tool-loop-limit-reached
           (unless (string-empty-p content)
             (insert "\n"))
           (insert "Tool loop stopped after reaching the safety limit."))
         (when tool-summary
           (unless (and (string-empty-p content)
                        (not tool-loop-limit-reached))
             (insert "\n"))
           (insert (format "Tools used: %s" tool-summary)))
         (insert "\n\n"))))))

(defun chat-code--persist-processed-response (processed &optional raw-request raw-response)
  "Persist PROCESSED response into the current session."
  (let* ((content (string-trim-right
                   (chat-tool-caller-extract-content
                    (or (plist-get processed :content) ""))))
         (tool-calls (plist-get processed :tool-calls))
         (tool-results (plist-get processed :tool-results))
         (tool-summary (chat-code--tool-display-summary tool-calls tool-results))
         (tool-loop-limit-reached (plist-get processed :tool-loop-limit-reached))
         (history-content (cond
                           ((and (string-blank-p content) tool-summary tool-loop-limit-reached)
                            (format "Tool loop stopped after reaching the safety limit.\nTools used: %s"
                                    tool-summary))
                           ((and (string-blank-p content) tool-summary)
                            tool-summary)
                           (tool-loop-limit-reached
                            (concat content
                                    "\nTool loop stopped after reaching the safety limit."))
                           (t
                            content))))
    (chat-session-add-message
     (chat-code--base-session)
     (make-chat-message
      :id (format "msg-%s" (random 10000))
      :role :assistant
      :content history-content
      :timestamp (current-time)
      :tool-calls tool-calls
      :tool-results tool-results
      :raw-request raw-request
      :raw-response raw-response))))

(defun chat-code--resolve-tool-loop-async (model messages processed raw-request raw-response
                                                 callback error-callback &optional depth)
  "Resolve tool calls asynchronously for code mode."
  (let ((step (or depth 0))
        (ui-buffer (current-buffer)))
    (if (or (null (plist-get processed :tool-calls))
            (>= step chat-code-tool-loop-max-steps))
        (funcall callback
                 (list :processed (if (and (plist-get processed :tool-calls)
                                           (>= step chat-code-tool-loop-max-steps))
                                      (plist-put (copy-tree processed)
                                                 :tool-loop-limit-reached
                                                 t)
                                    processed)
                       :raw-request raw-request
                       :raw-response raw-response))
      (let* ((followup-message
              (make-chat-message
               :id (format "code-tool-step-%s-%s" (random 10000) step)
               :role :system
               :content (chat-code--tool-followup-message
                         (plist-get processed :tool-calls)
                         (plist-get processed :tool-results))
               :timestamp (current-time)))
             (next-messages (chat-code--prepare-request-messages
                             model
                             (append messages (list followup-message)))))
        (chat-code--set-status
         'running
         (format "Resolving tools (%d/%d)" (1+ step) chat-code-tool-loop-max-steps))
        (setq chat-code--active-request-handle
              (chat-llm-request-async
               model
               next-messages
               (lambda (next-result)
                 (when (buffer-live-p ui-buffer)
                   (with-current-buffer ui-buffer
                     (let ((next-processed
                           (chat-tool-caller-process-response-data
                            (plist-get next-result :content)
                            (chat-code--base-session))))
                       (chat-code--resolve-tool-loop-async
                        model
                        next-messages
                        next-processed
                        (plist-get next-result :raw-request)
                        (plist-get next-result :raw-response)
                        (lambda (resolved)
                          (funcall callback
                                   (list :processed
                                         (chat-code--merge-processed-results
                                          processed
                                          (plist-get resolved :processed))
                                         :raw-request (plist-get resolved :raw-request)
                                         :raw-response (plist-get resolved :raw-response))))
                        (lambda (err)
                          (when (buffer-live-p ui-buffer)
                            (with-current-buffer ui-buffer
                              (funcall error-callback err))))
                        (1+ step))))))
               (lambda (err)
                 (when (buffer-live-p ui-buffer)
                   (with-current-buffer ui-buffer
                     (funcall error-callback err))))
               (list :temperature 0.7
                     :max-tokens (chat-code--request-output-budget model)
                     :timeout chat-code-request-timeout)))))))

(defun chat-code--finalize-response (content content-start &optional raw-request raw-response)
  "Finalize assistant CONTENT starting at CONTENT-START."
  (let ((processed (chat-tool-caller-process-response-data
                    content
                    (chat-code--base-session)))
        (model chat-code--active-request-model)
        (messages chat-code--active-request-messages)
        (ui-buffer (current-buffer)))
    (chat-code--resolve-tool-loop-async
     model
     messages
     processed
     raw-request
     raw-response
     (lambda (resolved)
       (when (buffer-live-p ui-buffer)
         (with-current-buffer ui-buffer
           (setq chat-code--active-request-handle nil)
           (chat-code--set-status
            (if (plist-get (plist-get resolved :processed) :tool-loop-limit-reached)
                'stopped
              'success)
            (if (plist-get (plist-get resolved :processed) :tool-loop-limit-reached)
                (format "Stopped after tool loop limit (%d)" chat-code-tool-loop-max-steps)
              "Completed"))
           (chat-code--persist-processed-response
            (plist-get resolved :processed)
            (plist-get resolved :raw-request)
            (plist-get resolved :raw-response))
           (chat-code--display-processed-response
            (plist-get resolved :processed)
            content-start))))
     (lambda (err)
       (when (buffer-live-p ui-buffer)
         (with-current-buffer ui-buffer
           (chat-code--handle-llm-error err content-start)))))))

(defun chat-code--detect-language (file-path)
  "Detect programming language for FILE-PATH."
  (let ((ext (file-name-extension file-path)))
    (pcase ext
      ("py" 'python)
      ("js" 'javascript)
      ("ts" 'typescript)
      ("el" 'emacs-lisp)
      ("go" 'go)
      ("rs" 'rust)
      ("rb" 'ruby)
      ("java" 'java)
      (_ nil))))

(defun chat-code--detect-project-root (&optional file)
  "Detect project root for FILE or current buffer."
  (let ((file (or file (buffer-file-name))))
    (or (and file (project-root (project-current nil file)))
        (and file (locate-dominating-file file ".git"))
        (and file (file-name-directory file))
        default-directory)))

(defun chat-code-session-create (name &optional project-root focus-file)
  "Create a new code mode session.

NAME is the session name.
PROJECT-ROOT is the project root directory.
FOCUS-FILE is an optional file to focus on."
  (let* ((project-root (or project-root (chat-code--detect-project-root)))
         (base-session (chat-session-create name chat-default-model))
         (language (and focus-file (chat-code--detect-language focus-file)))
         (code-session (make-chat-code-session
                        :base-session base-session
                        :project-root project-root
                        :focus-file focus-file
                        :context-strategy chat-code-default-strategy
                        :context-files (if focus-file (list focus-file) nil)
                        :language language
                        :edit-history nil)))
    code-session))

;; ------------------------------------------------------------------
;; Entry Points
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-code-start (&optional project-root)
  "Start a code mode session for the current project.
Optional PROJECT-ROOT overrides the detected project root."
  (interactive)
  (unless chat-code-enabled
    (error "Code mode is not enabled. Set chat-code-enabled to t"))
  (let* ((project-root (or project-root (chat-code--detect-project-root)))
         (session-name (format "Code: %s"
                               (file-name-nondirectory
                                (directory-file-name project-root))))
         (code-session (chat-code-session-create session-name project-root)))
    (chat-code--open-session code-session)))

;;;###autoload
(defun chat-code-for-file (file-path)
  "Start code mode focused on FILE-PATH."
  (interactive
   (list (read-file-name "Focus file: " nil nil t (buffer-file-name))))
  (unless chat-code-enabled
    (error "Code mode is not enabled. Set chat-code-enabled to t"))
  (let* ((project-root (chat-code--detect-project-root file-path))
         (session-name (format "Code: %s"
                               (file-name-nondirectory file-path)))
         (code-session (chat-code-session-create session-name
                                                  project-root
                                                  file-path)))
    (chat-code--open-session code-session)))

;;;###autoload
(defun chat-code-for-selection ()
  "Start code mode with current selection as context."
  (interactive)
  (unless chat-code-enabled
    (error "Code mode is not enabled. Set chat-code-enabled to t"))
  (let* ((file-path (buffer-file-name))
         (_ (unless file-path
              (error "Buffer is not visiting a file")))
         (project-root (chat-code--detect-project-root file-path))
         (session-name (format "Code: %s"
                               (file-name-nondirectory file-path)))
         (code-session (chat-code-session-create session-name
                                                  project-root
                                                  file-path)))
    ;; Store selection range if active
    (when (region-active-p)
      (setf (chat-code-session-focus-range code-session)
            (cons (line-number-at-pos (region-beginning))
                  (line-number-at-pos (region-end)))))
    (chat-code--open-session code-session)))

;;;###autoload
(defun chat-code-from-chat ()
  "Switch current chat session to code mode."
  (interactive)
  (unless chat-code-enabled
    (error "Code mode is not enabled. Set chat-code-enabled to t"))
  (unless (boundp 'chat--current-session)
    (error "Not in a chat buffer"))
  (let* ((base-session chat--current-session)
         (code-session (chat-code-session-create
                        (chat-session-name base-session)
                        (chat-code--detect-project-root)
                        nil)))
    ;; Reuse existing session but switch to code mode
    (setf (chat-code-session-base-session code-session) base-session)
    (chat-code--open-session code-session)))

;; ------------------------------------------------------------------
;; Buffer Management
;; ------------------------------------------------------------------

(defun chat-code--buffer-name (session)
  "Generate buffer name for SESSION."
  (format "*chat:code:%s*" (chat-session-name
                            (chat-code-session-base-session session))))

(defun chat-code--open-session (code-session)
  "Open CODE-SESSION in a code mode buffer."
  (let* ((buffer-name (chat-code--buffer-name code-session))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (chat-code-mode)
      (setq-local chat-code--current-session code-session)
      (chat-code--setup-buffer code-session))
    (pop-to-buffer buffer)))

(defun chat-code--setup-buffer (code-session)
  "Setup code mode buffer for CODE-SESSION."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq-local chat-code--active-request-handle nil)
    (setq-local chat-code--active-stream-process nil)
    (setq-local chat-code--pending-edit nil)
    ;; Header line with context info
    (chat-code--insert-header code-session)
    ;; Initial context summary
    (chat-code--insert-context-summary code-session)
    (setq chat-code--messages-end (point-marker))
    (chat-code--set-status 'idle "Ready")
    ;; Input area
    (chat-code--setup-input-area)
    (goto-char (point-max))))

(defun chat-code--insert-header (code-session)
  "Insert header for CODE-SESSION."
  (insert (propertize
           (format "════════════════════════════════════════════════════════════════════\n")
           'face '(:weight bold)))
  (let* ((base (chat-code-session-base-session code-session))
         (name (chat-session-name base))
         (strategy (chat-code-session-context-strategy code-session))
         (project (chat-code-session-project-root code-session))
         (focus (chat-code-session-focus-file code-session)))
    (insert (propertize
             (format "Session: %s | Strategy: %s\n" name strategy)
             'face 'shadow))
    (insert (propertize
             (format "Project: %s\n" (abbreviate-file-name project))
             'face 'shadow))
    (when focus
      (insert (propertize
               (format "Focus: %s\n" (file-name-nondirectory focus))
               'face 'shadow))))
  (insert (propertize
           "════════════════════════════════════════════════════════════════════\n"
           'face '(:weight bold)))
  (insert "\n"))

(defun chat-code--insert-context-summary (code-session)
  "Insert context summary for CODE-SESSION."
  (let ((files (chat-code-session-context-files code-session))
        (focus (chat-code-session-focus-file code-session)))
    (when (or files focus)
      (insert (propertize "[Context] " 'face '(:weight bold)))
      (if files
          (insert (format "%d file(s): %s\n"
                          (length files)
                          (mapconcat #'file-name-nondirectory files ", ")))
        (insert "No files in context\n"))
      (insert "\n"))))

(defun chat-code--setup-input-area ()
  "Setup the input area at bottom of buffer."
  (goto-char (point-max))
  (insert (propertize "────────────────────────────────────────────────────────────────────\n"
                      'face 'shadow))
  (insert "> ")
  (setq chat-code--input-marker (point-marker)))

;; ------------------------------------------------------------------
;; Mode Definition
;; ------------------------------------------------------------------

(defvar chat-code-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Send message
    (define-key map (kbd "RET") 'chat-code-send-message)
    ;; Accept/Reject changes
    (define-key map (kbd "C-c C-a") 'chat-code-accept-last-edit)
    (define-key map (kbd "C-c C-k") 'chat-code-reject-last-edit)
    (define-key map (kbd "C-c C-v") 'chat-code-view-preview)
    ;; Navigation
    (define-key map (kbd "C-c C-f") 'chat-code-focus-file)
    (define-key map (kbd "C-c C-r") 'chat-code-refresh-context)
    ;; Cancel
    (define-key map (kbd "C-g") 'chat-code-cancel)
    map)
  "Keymap for code mode buffers.")

(define-derived-mode chat-code-mode fundamental-mode "Chat-Code"
  "Major mode for AI-assisted code editing.

Key bindings:
  RET        - Send message
  C-c C-a    - Accept last edit
  C-c C-k    - Reject last edit
  C-c C-v    - View preview
  C-c C-f    - Focus on file
  C-c C-r    - Refresh context
  C-g        - Cancel current operation

In this mode, all operations use a single buffer design.
Preview is shown in a separate buffer that you can switch to manually
using C-x b or C-c C-v."
  :group 'chat-code
  (setq buffer-read-only nil)
  (setq truncate-lines nil))

;; ------------------------------------------------------------------
;; Core Commands
;; ------------------------------------------------------------------

(defun chat-code-send-message ()
  "Send message from input area."
  (interactive)
  (when chat-code--current-session
    (if (chat-code--response-active-p)
        (message "A response is already in progress. Cancel it before sending another message.")
      (let* ((input-start (marker-position chat-code--input-marker))
             (input-end (point-max))
             (content (string-trim (buffer-substring-no-properties
                                    input-start input-end))))
        (if (string-empty-p content)
            (message "Cannot send empty message")
          (delete-region input-start input-end)
          (goto-char input-start)
          (let ((user-msg (make-chat-message
                           :id (format "msg-%s" (random 10000))
                           :role :user
                           :content content
                           :timestamp (current-time))))
            (chat-session-add-message (chat-code--base-session) user-msg)
            (chat-code--display-user-message content)
            (chat-code--process-message)))))))

(defun chat-code--process-message ()
  "Process the latest user message."
  (when chat-code--current-session
    (chat-code--send-to-llm)))

(defcustom chat-code-use-streaming t
  "Whether to use streaming responses for code mode."
  :type 'boolean
  :group 'chat-code)

(defun chat-code--send-to-llm ()
  "Send the current code-mode conversation to the LLM."
  (chat-code--set-status 'running "Building context")
  (let* ((context (chat-context-code-build chat-code--current-session))
         (context-str (chat-context-code-to-string context))
         (lsp-context (when (chat-code-lsp-available-p)
                        (chat-code-lsp-get-context)))
         (lsp-str (when lsp-context
                    (chat-code-lsp-format-context lsp-context)))
         (system-prompt (chat-code--compose-system-prompt))
         (base-system-prompt (concat system-prompt "\n\n"
                                     context-str
                                     (when lsp-str
                                       (concat "\n\n" lsp-str))))
         (full-system-prompt (chat-tool-caller-build-system-prompt
                              base-system-prompt))
         (base-session (chat-code--base-session))
         (model (chat-session-model-id base-session))
         (messages (cons
                    (make-chat-message
                     :id "system-code"
                     :role :system
                     :content full-system-prompt
                     :timestamp (current-time))
                    (chat-session-messages base-session)))
         (prepared-messages (chat-code--prepare-request-messages model messages))
         (content-start (chat-code--show-assistant-indicator)))
    (setq chat-code--active-request-model model)
    (setq chat-code--active-request-messages prepared-messages)
    ;; Choose streaming or non-streaming
    (chat-code--set-status 'running "Waiting for model")
    (chat-code--render-progress content-start
                                (format "Running with %s"
                                        (chat-code--model-label model)))
    (if chat-code-use-streaming
        (chat-code--send-streaming model prepared-messages content-start)
      (chat-code--send-non-streaming model prepared-messages content-start))
    ;; Update context
    (setf (chat-code-session-context-files chat-code--current-session)
          (mapcar #'chat-code-file-context-path
                  (chat-code-context-files context)))))

(defun chat-code--send-streaming (model messages content-start)
  "Send streaming request to MODEL with MESSAGES.
CONTENT-START marks the assistant response body."
  (let ((buffer (current-buffer))
        (full-content ""))
    (chat-code--set-status 'running "Starting stream")
    (chat-code--render-progress content-start "Starting response")
    (let ((stream-process
           (condition-case err
               (chat-stream-request
                model
                messages
                (lambda (chunk)
                  (when (and chunk (> (length chunk) 0) (buffer-live-p buffer))
                    (with-current-buffer buffer
                      (chat-code--set-status 'running "Streaming response")
                      (setq full-content (concat full-content chunk))
                      (chat-code--replace-response-slot
                       content-start
                       (lambda ()
                         (let ((visible
                                (string-trim-right
                                 (chat-tool-caller-extract-content full-content))))
                           (if (string-empty-p visible)
                               (insert "Calling tools...\n\n")
                             (insert visible)
                             (insert "\n\n")))))
                      (redisplay t))))
                (list :temperature 0.7
                      :stream t
                      :max-tokens (chat-code--request-output-budget model)))
             (error
              (chat-code--handle-llm-error (error-message-string err) content-start)
              nil))))
      (setq chat-code--active-stream-process stream-process)
      (if (chat-code--stream-started-p stream-process)
          (chat-code--set-stream-process-sentinel
           stream-process
           (lambda (proc event)
             (when (and (buffer-live-p buffer)
                        (string-match-p "finished\\|closed\\|exited" event))
               (with-current-buffer buffer
                 (setq chat-code--active-stream-process nil)
                 (chat-code--finalize-response full-content content-start))
               (when (buffer-live-p (process-buffer proc))
                 (kill-buffer (process-buffer proc))))))
        (chat-code--handle-llm-error "Failed to start stream" content-start)))))

(defun chat-code--send-non-streaming (model messages content-start)
  "Send non-streaming request to MODEL with MESSAGES.
CONTENT-START marks the assistant response body."
  (setq chat-code--active-request-handle
        (chat-llm-request-async
         model
         messages
         (lambda (response)
           (chat-code--handle-llm-response response content-start))
         (lambda (error-msg)
           (chat-code--handle-llm-error error-msg content-start))
         (list :temperature 0.7
               :max-tokens (chat-code--request-output-budget model)
               :timeout chat-code-request-timeout))))

(defun chat-code--display-user-message (content)
  "Display user message CONTENT in buffer."
  (chat-code--append-to-messages
   (lambda ()
     (insert (propertize "You:\n" 'face 'font-lock-keyword-face))
     (insert content)
     (insert "\n\n"))))

(defun chat-code--show-assistant-indicator ()
  "Show assistant is thinking indicator and return content marker."
  (let (content-start)
    (chat-code--append-to-messages
     (lambda ()
       (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
       (setq content-start (copy-marker (point)))
       (insert "Preparing request...\n\n")))
    content-start))

(defun chat-code--handle-llm-response (response content-start)
  "Handle LLM RESPONSE starting at CONTENT-START."
  (setq chat-code--active-request-handle nil)
  (chat-code--set-status 'running "Processing response")
  (chat-code--finalize-response
   (plist-get response :content)
   content-start
   (plist-get response :raw-request)
   (plist-get response :raw-response)))

(defun chat-code--handle-llm-error (error-msg &optional content-start)
  "Handle LLM error ERROR-MSG.
If CONTENT-START is non nil, replace the pending assistant slot."
  (setq chat-code--active-request-handle nil)
  (setq chat-code--active-stream-process nil)
  (chat-code--set-status 'failed error-msg)
  (message "LLM Error: %s" error-msg)
  (let ((render-error
         (lambda ()
           (insert (propertize "Error: " 'face 'error))
           (insert (format "%s\n\n" error-msg)))))
    (if content-start
        (chat-code--replace-response-slot content-start render-error)
      (chat-code--append-to-messages render-error))))

(defun chat-code--display-assistant-response (content)
  "Display assistant CONTENT."
  (chat-code--append-to-messages
   (lambda ()
     (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
     (chat-code--insert-formatted-response content)
     (insert "\n\n"))))

(defun chat-code--insert-formatted-response (content)
  "Insert CONTENT with formatting for code blocks."
  (let ((pos 0)
        (len (length content)))
    (while (< pos len)
      (if (string-match "^\\(```\\([^\n]*\\)\\n\\(.*?\\)\\n```\\)" 
                        (substring content pos) 0)
          ;; Found code block
          (progn
            ;; Insert text before code block
            (insert (substring content pos (+ pos (match-beginning 0))))
            ;; Insert formatted code block
            (let* ((lang (match-string 2 (substring content pos)))
                   (code (match-string 3 (substring content pos)))
                   (face (if (string= lang "")
                             'default
                           '(:background "#f5f5f5" :extend t))))
              (insert (propertize (format "```%s\n%s\n```" lang code)
                                  'face face)))
            (setq pos (+ pos (match-end 0))))
        ;; No more code blocks
        (insert (substring content pos))
        (setq pos len)))))

(defun chat-code--parse-code-edit (content)
  "Parse CODE-EDIT block from CONTENT.
Returns a chat-edit struct or nil."
  ;; Look for code edit markers
  (cond
   ;; Check for explicit CODE-EDIT block
   ((chat-code--match-fenced-block content "code-edit")
    (chat-code--parse-explicit-edit content))
   ;; Check for implied edit (single code block with context)
   ((and (chat-code-session-focus-file chat-code--current-session)
         (chat-code--match-fenced-block content))
    (chat-code--create-edit-from-code-block content))
   (t nil)))

(defun chat-code--parse-explicit-edit (content)
  "Parse explicit CODE-EDIT block."
  (let ((payload-text (chat-code--match-fenced-block content "code-edit")))
    (when payload-text
    (condition-case err
        (let* ((json-object-type 'alist)
               (json-array-type 'list)
               (json-key-type 'symbol)
               (payload (json-read-from-string payload-text)))
          (chat-code--create-explicit-edit payload))
      (error
       (message "Failed to parse code-edit block: %s" (error-message-string err))
       nil)))))

(defun chat-code--create-edit-from-code-block (content)
  "Create edit from code block in CONTENT."
  (let ((block (chat-code--match-fenced-block content)))
    (when block
      (let* ((file (chat-code-session-focus-file chat-code--current-session))
             (new-code (cadr block))
           (original-code (when file
                            (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string)))))
        (when (and file original-code)
          (chat-edit-create-rewrite file original-code new-code
                                    "AI suggested change"))))))

(defun chat-code--propose-edit (edit)
  "Propose EDIT to user."
  (setq chat-code--pending-edit edit)
  (chat-code-preview-for-edit edit)
  (insert "I've generated a code change.\n\n")
  (insert (propertize "File: " 'face '(:weight bold)))
  (insert (format "%s\n" (chat-edit-file edit)))
  (insert (propertize "Description: " 'face '(:weight bold)))
  (insert (format "%s\n\n" (chat-edit-description edit)))
  (insert (propertize "[Apply: C-c C-a]  [Preview: C-c C-v]  [Reject: C-c C-k]\n"
                      'face '(:weight bold :foreground "blue")))
  (insert "\n")
  ;; Auto-apply if small enough
  (let ((new-lines (length (split-string (chat-edit-new-content edit) "\n")))
        (orig-lines (length (split-string (chat-edit-original-content edit) "\n"))))
    (when (and (> chat-code-auto-apply-threshold 0)
               (<= (abs (- new-lines orig-lines)) chat-code-auto-apply-threshold))
      (message "Auto-applying small change (%d lines)"
               (abs (- new-lines orig-lines)))
      (chat-code-accept-last-edit))))

(defun chat-code-accept-last-edit ()
  "Accept the last proposed edit."
  (interactive)
  (if chat-code--pending-edit
      (progn
        (message "Applying edit to %s..." 
                 (file-name-nondirectory (chat-edit-file chat-code--pending-edit)))
        (let ((result (chat-edit-apply chat-code--pending-edit)))
          (if result
              (progn
                (message "Edit applied successfully")
                (chat-edit-add-to-history chat-code--pending-edit)
                ;; Update display
                (chat-code--append-to-messages
                 (lambda ()
                   (insert (propertize "✓ Edit applied\n\n" 'face '(:foreground "green")))))
                (setq chat-code--pending-edit nil))
            (message "Failed to apply edit"))))
    (message "No pending edit to accept")))

(defun chat-code-reject-last-edit ()
  "Reject the last proposed edit."
  (interactive)
  (if chat-code--pending-edit
      (progn
        (message "Edit rejected")
        (setq chat-code--pending-edit nil)
        ;; Update display
        (chat-code--append-to-messages
         (lambda ()
           (insert (propertize "✗ Edit rejected\n\n" 'face '(:foreground "red"))))))
    (message "No pending edit to reject")))

(defun chat-code-view-preview ()
  "Switch to preview buffer."
  (interactive)
  (when chat-code--pending-edit
    (chat-code-preview-for-edit chat-code--pending-edit))
  (let ((preview-buffer (get-buffer chat-code--preview-buffer-name)))
    (if preview-buffer
        (pop-to-buffer preview-buffer)
      (message "No preview available"))))

(defun chat-code-focus-file (file-path)
  "Change focus to FILE-PATH."
  (interactive
   (list (read-file-name "Focus file: "
                         (chat-code-session-project-root
                          chat-code--current-session)
                         nil t)))
  (when chat-code--current-session
    (setf (chat-code-session-focus-file chat-code--current-session) file-path)
    (push file-path (chat-code-session-context-files chat-code--current-session))
    (message "Focus set to: %s" (file-name-nondirectory file-path))))

(defun chat-code-refresh-context ()
  "Refresh context for current session."
  (interactive)
  (when chat-code--current-session
    (let ((focus-file (chat-code-session-focus-file chat-code--current-session)))
      (when focus-file
        (setf (chat-code-session-context-files chat-code--current-session)
              (delete-dups
               (cons focus-file
                     (chat-code-session-context-files chat-code--current-session)))))
      (message "Context will be rebuilt on the next request"))))

(defun chat-code-cancel ()
  "Cancel current operation."
  (interactive)
  (when chat-code--active-request-handle
    (chat-llm-cancel-request chat-code--active-request-handle)
    (setq chat-code--active-request-handle nil))
  (when (and chat-code--active-stream-process
             (process-live-p chat-code--active-stream-process))
    (delete-process chat-code--active-stream-process)
    (setq chat-code--active-stream-process nil))
  (chat-code--set-status 'cancelled "Cancelled by user")
  (message "Response cancelled"))

;; ------------------------------------------------------------------
;; Inline Editing Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-edit-explain ()
  "Explain the code at point or in selection."
  (interactive)
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Explain this code:\n\n%s\n\nWhat does it do? How does it work?"
         "Code Explanation")
      (message "No code to explain"))))

;;;###autoload
(defun chat-edit-refactor (instruction)
  "Refactor code according to INSTRUCTION."
  (interactive "sRefactor instruction: ")
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         (format "Refactor this code: %s\n\n%s\n\nProvide the refactored code."
                 instruction "%s")
         "Code Refactoring")
      (message "No code to refactor"))))

;;;###autoload
(defun chat-edit-fix ()
  "Fix issues in the code at point."
  (interactive)
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Fix any issues in this code:\n\n%s\n\nProvide the fixed code."
         "Code Fix")
      (message "No code to fix"))))

;;;###autoload
(defun chat-edit-docs ()
  "Generate documentation for the code at point."
  (interactive)
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Add documentation to this code:\n\n%s\n\nProvide the documented code with docstrings/comments."
         "Add Documentation")
      (message "No code to document"))))

;;;###autoload
(defun chat-edit-tests ()
  "Generate tests for the code at point."
  (interactive)
  (let ((code (or (chat-code--get-selection)
                  (chat-code--get-function-at-point)))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Generate unit tests for this code:\n\n%s\n\nProvide comprehensive tests."
         "Generate Tests")
      (message "No code to test"))))

;;;###autoload
(defun chat-edit-complete ()
  "Complete the current code at point."
  (interactive)
  (let ((code (chat-code--get-context-around-point))
        (file (buffer-file-name)))
    (if code
        (chat-code--inline-request
         file
         code
         "Complete this code:\n\n%s\n\nContinue the implementation."
         "Code Completion")
      (message "No context for completion"))))

(defun chat-code--get-selection ()
  "Get selected text as string."
  (when (region-active-p)
    (buffer-substring-no-properties (region-beginning) (region-end))))

(defun chat-code--get-function-at-point ()
  "Get function at point as string."
  (save-excursion
    (when (beginning-of-defun)
      (let ((start (point)))
        (end-of-defun)
        (buffer-substring-no-properties start (point))))))

(defun chat-code--get-context-around-point ()
  "Get context around point (100 chars before and after)."
  (let ((start (max (point-min) (- (point) 100)))
        (end (min (point-max) (+ (point) 100))))
    (buffer-substring-no-properties start end)))

(defun chat-code--inline-request (file code prompt-template title)
  "Send inline request for CODE in FILE.
PROMPT-TEMPLATE is a format string with %s for code.
TITLE is the operation title."
  ;; Create or reuse code mode session
  (let* ((session (or (and (boundp 'chat-code--current-session)
                           chat-code--current-session)
                      (chat-code-session-create
                       title
                       (chat-code--detect-project-root file)
                       file)))
         (full-prompt (format prompt-template code)))
    
    ;; Open code mode buffer
    (chat-code--open-session session)
    
    ;; Set the prompt and send
    (with-current-buffer (chat-code--buffer-name session)
      (delete-region (marker-position chat-code--input-marker) (point-max))
      (goto-char (marker-position chat-code--input-marker))
      (insert full-prompt)
      (chat-code-send-message))))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat-code)
;;; chat-code.el ends here
