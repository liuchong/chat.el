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
(require 'chat-transcript)
(require 'chat-llm)
(require 'chat-files)
(require 'chat-reading)
(require 'chat-context)
(require 'chat-context-code)
(require 'chat-edit)
(require 'chat-code-preview)
(require 'chat-code-intel)
(require 'chat-status)
(require 'chat-stream)
(require 'chat-agent)
(require 'chat-agent-transcript)
(require 'chat-code-lsp)
(require 'chat-tool-caller)
(require 'chat-request-diagnostics)
(require 'chat-request-panel)
(require 'chat-request-surface)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defvar chat--current-session nil
  "Current chat session bound by chat buffers.")

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

(defcustom chat-code-tool-followup-timeout 300
  "Timeout in seconds for code-mode tool follow-up requests."
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

(defcustom chat-code-reading-near-point-radius 5
  "Number of surrounding lines to capture around point.
Used by reading workflow commands."
  :type 'integer
  :group 'chat-code)

(defcustom chat-code-auto-path-completion t
  "Whether to auto-trigger path completion in the code-mode input area."
  :type 'boolean
  :group 'chat-code)

(defcustom chat-code-commands-help
  "Code Mode Commands:
  RET                   - Send message
  C-c C-a               - Accept last edit
  C-c C-k               - Reject last edit
  C-c C-v               - View preview buffer
  C-c C-f               - Focus another file
  C-c C-r               - Refresh context
  C-c C-q               - Quote active region into input
  C-c C-SPC             - Ask about active region immediately
  C-c C-s               - Show current request diagnostics
  C-c C-p               - Toggle request panel
  C-c C-e               - Edit and resend last user message
  C-c C-g               - Regenerate last assistant response
  C-c C-h               - Open this help buffer
  S-RET                 - Insert newline without sending
  C-g                   - Cancel current operation

Reading Workflow:
  M-x chat-code-quote-region       - Quote active region into code mode
  M-x chat-code-quote-defun        - Quote defun at point into code mode
  M-x chat-code-quote-near-point   - Quote nearby context into code mode
  M-x chat-code-quote-current-file - Quote current file into code mode
  M-x chat-code-ask-region         - Ask about active region immediately
  M-x chat-code-ask-defun          - Ask about defun at point immediately
  M-x chat-code-ask-near-point     - Ask about nearby context immediately
  M-x chat-code-ask-current-file   - Ask about current file immediately

Workflow Notes:
  - Quote commands fill the input area so you can refine the question.
  - Ask commands send the quoted context immediately.
  - The request panel shows execution details without polluting the transcript.
  - Preview edits in *chat-preview* before accepting file changes.
  - File write approvals can also allow one directory subtree with C-c C-f.
  - Type a path-like token in the input area to trigger file completion.

Documentation Workflow:
  - For long documents, work section by section instead of asking for one giant response.
  - Use files_write for new doc files or intentional whole-document rewrites.
  - Use apply_patch or files_replace for targeted edits to existing documents.
  - Short follow-up requests reuse the latest single-file focus when possible.
  - Quote a region or one heading block when revising an existing document.
  - If quote-current-file refuses a large file, switch to region, defun, or near-point style capture."
  "Help text displayed for code mode commands."
  :type 'string
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
    "If the user gives a short follow-up without restating the path, prefer the current focus file or the most recently inspected file before broad scanning."
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

(defconst chat-code--editing-protocol-rules
  '("When the user asks for real file changes, use tools instead of printing large code blocks in chat."
    "Use files_write for new files or intentional whole-file rewrites."
    "Use files_replace only when the target text is known exactly and the match can be constrained."
    "Prefer apply_patch for existing-file edits that touch multiple hunks or need nearby context."
    "After reading or editing one specific file, keep that file as the default target for the next vague follow-up unless the user redirects you."
    "After every successful write tool, inspect the edited file or diff before claiming success."
    "If an edit tool fails because the match is ambiguous or stale, read the file again and choose a narrower edit strategy."
    "Do not repeat the same failed edit command without new evidence from the files."
    "When enough evidence exists, stop editing and summarize the actual changes made.")
  "Editing protocol rules for code mode.")

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

;; Code capability is a property of a session, not a kind of session.
;;
;; It used to be a struct wrapping a `chat-session', which had three
;; costs.  Every access had to unwrap, so the two surfaces operated on
;; different objects and neither could render the other's conversation.
;; The wrapper was not serialized, so a code session could not be
;; reopened -- the more capable surface was the one that could not resume,
;; which read as a design decision and was an artifact.  And two of its
;; fields, language and edit-history, were written at creation and never
;; read by anything.
;;
;; Session metadata already persists through the JSONL state entry and
;; already carries the working directory, so putting these there makes a
;; code session an ordinary session that happens to know its project.

(defun chat-code-session-p (session)
  "Return non-nil when SESSION has code capability enabled."
  (and session
       (chat-session-p session)
       (chat-session-metadata-get session 'code-enabled)
       t))

;; Metadata survives as JSON, which does not distinguish a symbol from a
;; string or a list from an array.  A symbol written before a save reads
;; back as a string afterwards, and code comparing it with `eq' then
;; silently stops matching -- the same trap the message metadata hit.  So
;; the accessor is where the type is guaranteed, and each property
;; declares the shape it promises.

(defun chat-code--as-symbol (value)
  "Return VALUE as a symbol, or nil."
  (cond ((null value) nil)
        ((symbolp value) value)
        ((stringp value) (intern value))
        (t nil)))

(defun chat-code--as-list (value)
  "Return VALUE as a list."
  (cond ((null value) nil)
        ((vectorp value) (append value nil))
        ((listp value) value)
        (t (list value))))

(defmacro chat-code--define-property (name key &optional normalizer)
  "Define accessor NAME reading session metadata KEY, with a setter.

NORMALIZER, when given, converts what storage returns into the type the
rest of the code expects."
  `(progn
     (defun ,name (session)
       ,(format "Return the %s recorded for SESSION." key)
       (let ((value (chat-session-metadata-get session ',key)))
         ,(if normalizer `(,normalizer value) 'value)))
     (gv-define-setter ,name (value session)
       (list 'chat-session-metadata-set session '',key value))))

(chat-code--define-property chat-code-session-project-root project-root)
(chat-code--define-property chat-code-session-focus-file focus-file)
(chat-code--define-property chat-code-session-focus-range focus-range)
(chat-code--define-property chat-code-session-context-strategy
                            context-strategy chat-code--as-symbol)
(chat-code--define-property chat-code-session-context-files
                            context-files chat-code--as-list)

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
(defvar-local chat-code--active-agent-run nil
  "Currently active agent run state, or nil.")
(defvar-local chat-code--active-request-model nil
  "Model used by the current or most recent code-mode request.")
(defvar-local chat-code--active-request-messages nil
  "Messages used by the current or most recent code-mode request.")
(defvar-local chat-code--current-request-id nil
  "Diagnostics request id for the current code-mode buffer.")
(defvar-local chat-code--request-hint-timer nil
  "Timer used to show stalled request hints in code mode.")
(defvar-local chat-code--request-hint-shown nil
  "Whether a stalled request hint has already been shown.")
(defvar-local chat-code--request-tool-events nil
  "Current structured tool events for the request panel.")

(defvar-local chat-code--last-approval-hint nil
  "Last approval hint signature shown in this buffer.")

(defvar-local chat-code--auto-path-completion-active nil
  "Guard flag to avoid recursive path completion in the input area.")

(defvar-local chat-code--request-refresh-timer nil
  "Timer used to refresh live request surfaces in code mode.")

(defvar-local chat-code--request-diagnostics-observer nil
  "Observer function subscribed to request diagnostics updates.")

(defvar-local chat-code--live-response-start nil
  "Marker for the pending live assistant response slot.")

(defvar-local chat-code--live-response-content ""
  "Latest visible assistant content for the live response slot.")

(defvar-local chat-code--last-tracked-tool-paths nil
  "Last canonical file paths tracked from tool activity.")

(defun chat-code--pending-approval-event ()
  "Return the current pending approval event when present."
  (chat-status-persistent-event chat-code--request-tool-events))

(defvar chat-code--preview-buffer-name "*chat-preview*"
  "Name of the preview buffer.")

(defface chat-code-block-face
  '((t :inherit font-lock-constant-face :extend t))
  "Face for fenced code blocks in code mode buffers."
  :group 'chat-code)

(defcustom chat-code-tool-loop-max-steps nil
  "Step ceiling for a code-mode run, or nil to follow the global budget.

Set this only to hold code mode to a tighter limit than
`chat-agent-max-steps'; `unlimited' lifts the ceiling entirely."
  :type '(choice (const :tag "Follow chat-agent-max-steps" nil)
                 (integer :tag "Steps")
                 (const :tag "Unlimited" unlimited))
  :group 'chat-code)

(defun chat-code--step-limit ()
  "Return the step ceiling in force for code mode."
  (chat-agent-budget-effective-limit chat-code-tool-loop-max-steps))

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
         (provider-name
          (and model-id
               (condition-case nil
                   (chat-llm-provider-option model-id :name)
                 (error nil)))))
    (or provider-name
        (and model-id (symbol-name model-id))
        "No model")))

(defun chat-code--response-active-p ()
  "Return non nil when a response is already in progress."
  (or (chat-agent-active-p chat-code--active-agent-run)
      chat-code--active-request-handle
      (and (processp chat-code--active-stream-process)
           (process-live-p chat-code--active-stream-process))))

(defun chat-code--clear-request-hint-timer ()
  "Cancel and clear the stalled request hint timer."
  (when (timerp chat-code--request-hint-timer)
    (cancel-timer chat-code--request-hint-timer))
  (setq chat-code--request-hint-timer nil))

(defun chat-code--clear-request-refresh-timer ()
  "Cancel and clear the live request refresh timer."
  (when (timerp chat-code--request-refresh-timer)
    (cancel-timer chat-code--request-refresh-timer))
  (setq chat-code--request-refresh-timer nil))

(defun chat-code--unsubscribe-request-diagnostics ()
  "Remove the current request diagnostics observer."
  (when (and chat-code--current-request-id
             chat-code--request-diagnostics-observer)
    (chat-request-diagnostics-unsubscribe
     chat-code--current-request-id
     chat-code--request-diagnostics-observer))
  (setq chat-code--request-diagnostics-observer nil))

(defun chat-code--window-near-live-edge-p (window)
  "Return non-nil when WINDOW is already near the live response edge."
  (and (window-live-p window)
       (eq (window-buffer window) (current-buffer))
       (or (chat-code--point-in-input-p (window-point window))
           (>= (window-end window t)
               (max (point-min) (- (point-max) 80))))))

(defun chat-code--active-live-windows ()
  "Return windows that should follow active streamed output."
  (seq-filter #'chat-code--window-near-live-edge-p
              (get-buffer-window-list (current-buffer) nil t)))

(defun chat-code--follow-live-output (windows)
  "Move WINDOWS to the latest response edge.
Windows whose point sits in the input area are left alone: Emacs
keeps the cursor visible on its own there, and yanking point out of
the input area mid-edit feels broken."
  (dolist (window windows)
    (when (and (window-live-p window)
               (not (chat-code--point-in-input-p (window-point window))))
      (chat-code--set-window-point
       window
       (marker-position chat-code--messages-end)))))

(defun chat-code--set-window-point (window position)
  "Set WINDOW point to POSITION."
  (set-window-point window position))

(defun chat-code--remember-focus-file (file-path &optional silent)
  "Store FILE-PATH as the current focus file.
When SILENT is non-nil, do not show minibuffer feedback."
  (when (and chat-code--current-session file-path)
    (let* ((resolved (chat-files--resolved-path file-path))
           (current-focus (chat-code-session-focus-file chat-code--current-session))
           (context-files (chat-code-session-context-files chat-code--current-session)))
      (setf (chat-code-session-focus-file chat-code--current-session) resolved)
      (setf (chat-code-session-context-files chat-code--current-session)
            (delete-dups (cons resolved context-files)))
      (unless (or silent (equal current-focus resolved))
        (message "Focus set to: %s" (file-name-nondirectory resolved))))))

(defun chat-code--track-tool-targets (tool-events)
  "Update session target state from TOOL-EVENTS."
  (when chat-code--current-session
    (when-let ((target-data (chat-request-surface-tool-targets tool-events)))
      (let ((all-paths (plist-get target-data :paths))
            (latest-single-target (plist-get target-data :latest-single-target)))
        (setq all-paths (delete-dups all-paths))
        (unless (equal all-paths chat-code--last-tracked-tool-paths)
          (setq chat-code--last-tracked-tool-paths all-paths)
          (setf (chat-code-session-context-files chat-code--current-session)
                (delete-dups
                 (append all-paths
                         (chat-code-session-context-files chat-code--current-session)))))
        (when latest-single-target
          (chat-code--remember-focus-file latest-single-target t))))))

(defun chat-code--request-live-detail (&optional snapshot)
  "Return a compact live request label from SNAPSHOT."
  (chat-request-diagnostics-live-detail
   (or snapshot
       (and chat-code--current-request-id
            (chat-request-diagnostics-snapshot
             chat-code--current-request-id)))
   chat-code--request-tool-events
   chat-code--status-detail))

(defun chat-code--live-placeholder (&optional snapshot)
  "Return a user-facing streaming placeholder from SNAPSHOT."
  (or (chat-code--request-live-detail snapshot)
      "Waiting for response..."))

(defun chat-code--live-narrative-line (&optional detail)
  "Return a transient live narrative line for DETAIL."
  (chat-request-surface-live-narrative-line
   (or detail
       (chat-code--request-live-detail))))

(defun chat-code--refresh-live-response (&optional snapshot)
  "Refresh the transcript live response slot from SNAPSHOT."
  (when (and chat-code--live-response-start
             (marker-buffer chat-code--live-response-start)
             (eq chat-code--status-state 'running))
    (chat-code--render-response-state
     chat-code--live-response-start
     chat-code--live-response-content
     chat-code--request-tool-events
     nil
     nil
     (chat-code--request-live-detail snapshot))))

(defun chat-code--refresh-live-surfaces (&optional snapshot)
  "Refresh panel and status text from SNAPSHOT."
  (when (and chat-code--current-request-id
             (eq chat-code--status-state 'running))
    (chat-code--set-status 'running (chat-code--request-live-detail snapshot))
    (chat-code--refresh-live-response snapshot)
    (chat-request-surface-update-panel-if-visible
     (current-buffer)
     chat-code--current-request-id
     chat-code--request-tool-events)))

(defun chat-code--handle-request-diagnostics-update (id _trace _event)
  "Handle diagnostics update for request ID."
  (when (equal id chat-code--current-request-id)
    (chat-code--refresh-live-surfaces
     (chat-request-diagnostics-snapshot id))))

(defun chat-code--start-request-refresh-timer (buffer)
  "Start the live request refresh timer for BUFFER."
  (chat-code--clear-request-refresh-timer)
  (setq chat-code--request-refresh-timer
        (chat-request-surface-start-refresh-timer
         buffer
         (lambda () chat-code--current-request-id)
         #'chat-code--refresh-live-surfaces
         #'chat-code--clear-request-refresh-timer)))

(defun chat-code--cleanup-request-state (&optional phase summary)
  "Clear current request diagnostics and optionally record PHASE and SUMMARY."
  (when chat-code--current-request-id
    (when phase
      (chat-request-diagnostics-record
       chat-code--current-request-id
       phase
       :handle chat-code--active-request-handle
       :process chat-code--active-stream-process
       :summary summary))
    (chat-code--unsubscribe-request-diagnostics)
    (chat-code--clear-request-refresh-timer)
    (chat-code--clear-request-hint-timer)
    (setq chat-code--request-hint-shown nil))
  (setq chat-code--request-tool-events nil)
  (setq chat-code--last-approval-hint nil)
  (setq chat-code--last-tracked-tool-paths nil)
  (setq chat-code--live-response-start nil)
  (setq chat-code--live-response-content "")
  (setq chat-code--current-request-id nil))

(defun chat-code--maybe-announce-approval-shortcuts (tool-events)
  "Show one native approval hint for TOOL-EVENTS when needed."
  (when-let ((hint (chat-request-surface-approval-hint
                    tool-events
                    chat-code--last-approval-hint)))
    (setq chat-code--last-approval-hint (plist-get hint :signature))
    (let ((text (plist-get hint :text)))
      (message "%s" text)
      text))) 

(defun chat-code--maybe-show-request-hint (buffer)
  "Show one stalled request hint in BUFFER if needed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((message-text
                  (and chat-code--current-request-id
                       (not chat-code--request-hint-shown)
                       (chat-request-diagnostics-stall-message
                        chat-code--current-request-id))))
        (setq chat-code--request-hint-shown t)
        (chat-request-surface-update-panel-if-visible
         buffer
         chat-code--current-request-id
         chat-code--request-tool-events)
        (message "%s Use C-c C-p or M-x chat-code-show-current-request-status for details."
                 message-text)))))

(defun chat-code--start-request-hint-timer (buffer)
  "Start the stalled request hint timer for BUFFER."
  (chat-code--clear-request-hint-timer)
  (setq chat-code--request-hint-shown nil)
  (setq chat-code--request-hint-timer
        (run-at-time
         chat-request-diagnostics-stall-threshold
         nil
         #'chat-code--maybe-show-request-hint
         buffer)))

(defun chat-code--begin-request (model transport)
  "Create diagnostics state for MODEL and TRANSPORT."
  (let* ((session chat-code--current-session)
         (source-buffer (current-buffer))
         (base-session session)
         (request-id
          (chat-request-diagnostics-create
           'code
           model
           model
           (list :session-id (and base-session (chat-session-id base-session))
                 :project-root (and session (chat-code-session-project-root session))
                 :focus-file (and session (chat-code-session-focus-file session))))))
    (setq chat-code--current-request-id request-id)
    (chat-request-diagnostics-record
     request-id
     'request-created
     :transport transport
     :summary (format "Preparing %s request" transport))
    (setq chat-code--request-tool-events nil)
    (setq chat-code--last-approval-hint nil)
    (setq chat-code--request-diagnostics-observer
          (chat-request-surface-buffer-observer
           source-buffer
           (lambda (id _trace _event)
             (chat-code--handle-request-diagnostics-update id nil nil))))
    (chat-request-diagnostics-subscribe
     request-id
     chat-code--request-diagnostics-observer)
    (when chat-request-panel-auto-show
      (chat-request-panel-open source-buffer request-id nil))
    (chat-code--start-request-hint-timer source-buffer)
    (chat-code--start-request-refresh-timer source-buffer)
    request-id))

(defun chat-code-show-current-request-status ()
  "Show diagnostics for the current code-mode request."
  (interactive)
  (if chat-code--current-request-id
      (chat-request-diagnostics-show chat-code--current-request-id)
    (user-error "No active request diagnostics")))

(defun chat-code-toggle-request-panel ()
  "Toggle the request panel for the current code-mode buffer."
  (interactive)
  (chat-request-panel-toggle
   (current-buffer)
   chat-code--current-request-id
   chat-code--request-tool-events))

(defun chat-code--base-session ()
  "Return the chat session backing this code buffer.

A code session is an ordinary session, so this is the session itself.
Kept as a name because the request and rendering paths read better
saying which session they mean, and because those paths are shared with
the chat surface."
  chat-code--current-session)

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
        (model (chat-code--model-label))
        (pending-label (chat-status-persistent-label chat-code--request-tool-events)))
    (concat
     (propertize " Code Mode " 'face 'mode-line-emphasis)
     (propertize (format "Status: %s" label)
                 'face (chat-code--status-face chat-code--status-state))
     (when pending-label
       (propertize
        (format " | %s" pending-label)
        'face 'warning))
     (propertize (format " | Model: %s | %s" model detail) 'face 'shadow))))

(defun chat-code--mode-line-status ()
  "Return a concise mode line status string."
  (let ((label (chat-code--status-label chat-code--status-state))
        (detail (or chat-code--status-detail "Ready"))
        (model (chat-code--model-label))
        (pending-label (chat-status-persistent-label chat-code--request-tool-events)))
    (format " [%s|%s%s|%s]"
            model
            label
            (if pending-label "|APPROVAL" "")
            detail)))

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
            "- Use files_write for new files and full rewrites."
            "- Use files_replace for strict search/replace edits when the target text is uniquely known."
            "- Use apply_patch for targeted existing-file edits with context."
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
    (chat-code--format-rule-section
     "Editing protocol:"
     chat-code--editing-protocol-rules)
    (chat-code--operation-guardrails))
   "\n\n"))

(defun chat-code--request-output-budget (model)
  "Return the requested output token budget for MODEL."
  (let ((provider-limit
         (condition-case nil
             (chat-llm-provider-option model :max-output-tokens)
           (error nil))))
    (if (and (integerp provider-limit) (> provider-limit 0))
        (min chat-code-max-output-tokens provider-limit)
      chat-code-max-output-tokens)))

(defun chat-code--request-message-budget (model messages)
  "Return the total token budget for MODEL and MESSAGES."
  (let* ((provider-window
          (condition-case nil
              (chat-llm-provider-option model :context-window)
            (error nil)))
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
   (chat-code--request-message-budget model messages)
   (chat-code--base-session)))

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

(defun chat-code--format-tool-events (tool-events)
  "Format TOOL-EVENTS into readable lines."
  (when tool-events
    (concat
     "Steps:\n"
     (mapconcat
      (lambda (event)
        (pcase (plist-get event :type)
          ('thinking
           (format "- Thinking: %s"
                   (plist-get event :summary)))
          ('tool-call
           (format "- Tool Call %s: %s %s"
                   (plist-get event :index)
                   (plist-get event :tool)
                   (chat-tool-caller--tool-arguments-summary
                    (plist-get event :arguments))))
          ('approval-pending
           (format "- Approval Pending %s: %s"
                   (plist-get event :index)
                   (plist-get event :tool)))
          ('approval
           (format "- Approval %s: %s"
                   (plist-get event :index)
                   (plist-get event :decision)))
          ('tool-result
           (format "- Tool Result %s: %s"
                   (plist-get event :index)
                   (plist-get event :result-summary)))
          ('tool-error
           (format "- Tool Error %s: %s"
                   (plist-get event :index)
                   (plist-get event :result-summary)))
          (_
           (format "- %s" event))))
      tool-events
      "\n"))))

(defvar-local chat-code--last-render nil
  "Last rendered slot state used by the streaming fast path.")

(defun chat-code--fence-safe-prefix-length (content)
  "Return the length of the CONTENT prefix after the last closed fence."
  (let ((pos 0)
        (last-close 0)
        (count 0))
    (while (string-match "```" content pos)
      (setq count (1+ count)
            pos (match-end 0))
      (when (zerop (mod count 2))
        (setq last-close pos)))
    (if (zerop (mod count 2))
        (length content)
      last-close)))

(defun chat-code--render-response-state (content-start content tool-events
                                                      &optional tool-loop-limit-reached
                                                      tool-summary
                                                      live-detail)
  "Render CONTENT, TOOL-EVENTS, TOOL-LOOP-LIMIT-REACHED, and TOOL-SUMMARY."
  (let ((follow-windows (chat-code--active-live-windows)))
    (setq chat-code--request-tool-events tool-events)
    (setq chat-code--live-response-start content-start)
    (setq chat-code--live-response-content content)
    (chat-code--track-tool-targets tool-events)
    (chat-code--maybe-announce-approval-shortcuts tool-events)
    (when (or (and chat-request-panel-auto-show
                   chat-code--current-request-id)
              (get-buffer-window
               (chat-request-panel--buffer-name (current-buffer)) t))
      (chat-request-panel-update
       (current-buffer)
       chat-code--current-request-id
       tool-events))
    (let ((trailers
           (lambda ()
             (when live-detail
               (unless (string-empty-p content)
                 (insert "\n"))
               (insert (chat-code--live-narrative-line live-detail)))
             (when tool-summary
               (unless (and (string-empty-p content)
                            (not live-detail)
                            (not tool-events))
                 (insert "\n"))
               (insert (format "Tools used: %s" tool-summary)))
             (when tool-loop-limit-reached
               (unless (and (string-empty-p content)
                            (not live-detail)
                            (not tool-events)
                            (not tool-summary))
                 (insert "\n"))
               (insert "Tool loop stopped after reaching the safety limit."))
             (insert "\n\n")))
          (last chat-code--last-render))
      (if (and last
               (eq (plist-get last :content-start) content-start)
               (= (plist-get last :event-count) (length tool-events))
               (string-prefix-p (plist-get last :content) content))
          ;; Streaming fast path: re-render only the tail after the
          ;; last closed fence, then the trailer lines.
          (let ((cut (chat-code--fence-safe-prefix-length
                      (plist-get last :content)))
                (inhibit-read-only t))
            (save-excursion
              (goto-char (+ (marker-position content-start) cut))
              (delete-region (point) chat-code--messages-end)
              (chat-code--insert-formatted-response (substring content cut))
              (funcall trailers)
              (set-marker chat-code--messages-end (point))))
        (chat-code--replace-response-slot
         content-start
         (lambda ()
           (unless (string-empty-p content)
             (chat-code--insert-formatted-response content))
           (funcall trailers))))
      (setq chat-code--last-render
            (list :content content
                  :content-start content-start
                  :event-count (length tool-events))))
    (chat-code--follow-live-output follow-windows)))

(defun chat-code--tool-result-lines (tool-calls tool-results)
  "Format TOOL-CALLS and TOOL-RESULTS into readable lines."
  (let (lines)
    (while (and tool-calls tool-results)
      (let* ((call (car tool-calls))
             (name (plist-get call :name))
             (arguments (plist-get call :arguments))
             (result (chat-tool-caller-truncate-result
                      (string-trim-right (or (car tool-results) "")))))
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

(defun chat-code--display-processed-response (processed content-start)
  "Render PROCESSED response starting at CONTENT-START."
  (let* ((content (string-trim-right
                   (chat-tool-caller-extract-content
                    (or (plist-get processed :content) ""))))
         (tool-events (plist-get processed :tool-events))
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
      (chat-code--render-response-state
       content-start
       (if (and (string-blank-p content) tool-summary)
           ""
         content)
       tool-events
       tool-loop-limit-reached
       tool-summary))))

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
      :id (chat-session-new-message-id)
      :role :assistant
      :content history-content
      :timestamp (current-time)
      :tool-calls tool-calls
      :tool-results tool-results
      :raw-request raw-request
      :raw-response raw-response))))

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
  "Create a new session with code capability enabled.

NAME is the session name.
PROJECT-ROOT is the project root directory.
FOCUS-FILE is an optional file to focus on.

Returns an ordinary `chat-session', so it saves, lists and reopens like
any other."
  (let ((session (chat-session-create
                  name
                  (if (boundp 'chat-default-model)
                      chat-default-model
                    'kimi))))
    (chat-code-enable session
                      (or project-root (chat-code--detect-project-root))
                      focus-file)
    session))

(defun chat-code-enable (session &optional project-root focus-file)
  "Turn on code capability for SESSION.

Separate from creation so an existing conversation can gain project
context without being restarted, which is what `chat-code-from-chat'
needs and what a reopened session needs when its capability is already
recorded."
  (chat-session-metadata-set session 'code-enabled t)
  (setf (chat-code-session-project-root session)
        (or project-root
            (chat-code-session-project-root session)
            (chat-code--detect-project-root)))
  (unless (chat-code-session-context-strategy session)
    (setf (chat-code-session-context-strategy session)
          chat-code-default-strategy))
  (when focus-file
    (setf (chat-code-session-focus-file session) focus-file)
    (setf (chat-code-session-context-files session) (list focus-file)))
  session)

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
  (unless (and (boundp 'chat--current-session) chat--current-session)
    (error "Not in a chat buffer"))
  ;; Enabling capability on the session in hand, rather than creating one
  ;; and swapping its contents, is what the command name always claimed.
  (chat-code--open-session (chat-code-enable chat--current-session)))

;; ------------------------------------------------------------------
;; Buffer Management
;; ------------------------------------------------------------------

(defun chat-code--buffer-name (session)
  "Generate buffer name for SESSION."
  (format "*chat:code:%s*" (chat-session-name session)))

(defun chat-code--open-session (code-session)
  "Open CODE-SESSION in a code mode buffer."
  (let* ((buffer-name (chat-code--buffer-name code-session))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (chat-code-mode)
      (setq-local chat-code--current-session code-session)
      ;; The same session-level setup the chat surface performs: working
      ;; directory, scratch space, and the canonical session binding.
      ;; Both variables point at one object until the surfaces merge.
      (when (fboundp 'chat-prepare-session-buffer)
        (chat-prepare-session-buffer code-session))
      (chat-code--setup-buffer code-session))
    (pop-to-buffer buffer)))

(defun chat-code--setup-buffer (code-session)
  "Setup code mode buffer for CODE-SESSION."
  (chat-code--clear-request-hint-timer)
  (setq-local chat-code--current-request-id nil)
  (setq-local chat-code--request-hint-shown nil)
  (setq-local chat-code--request-tool-events nil)
  (setq-local chat-code--last-approval-hint nil)
  (chat-request-panel-close (current-buffer))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq-local chat-code--active-request-handle nil)
    (setq-local chat-code--active-stream-process nil)
    (setq-local chat-code--pending-edit nil)
    (setq-local chat-code--last-tracked-tool-paths nil)
    (setq-local chat-code--live-response-start nil)
    (setq-local chat-code--live-response-content "")
    ;; Header line with context info
    (chat-code--insert-header code-session)
    ;; Initial context summary
    (chat-code--insert-context-summary code-session)
    (dolist (message (chat-session-messages code-session))
      (chat-code--insert-session-message message))
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
  (let* ((name (chat-session-name code-session))
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

(defun chat-code--point-in-input-p (&optional position)
  "Return non-nil when POSITION is inside the editable input area."
  (let ((pos (or position (point))))
    (and chat-code--input-marker
         (>= pos (marker-position chat-code--input-marker)))))

(defun chat-code--input-token-bounds ()
  "Return bounds of the current token in the input area, or nil."
  (when (chat-code--point-in-input-p)
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t\n\"'`()[]{}<>")
        (let ((start (point)))
          (when (<= (marker-position chat-code--input-marker) start)
            (cons start end)))))))

(defun chat-code--path-token-p (token)
  "Return non-nil when TOKEN looks like a file path fragment."
  (and (stringp token)
       (not (string-empty-p token))
       (or (string-prefix-p "/" token)
           (string-prefix-p "~/" token)
           (string-prefix-p "./" token)
           (string-prefix-p "../" token)
           (string-match-p "/" token))))

(defun chat-code--path-completion-root ()
  "Return the base directory for relative input path completion."
  (file-name-as-directory
   (or (and chat-code--current-session
            (chat-code-session-project-root chat-code--current-session))
       default-directory)))

(defun chat-code--path-completion-candidates (token base-directory)
  "Return completion candidates for TOKEN relative to BASE-DIRECTORY."
  (let* ((directory-prefix (or (file-name-directory token) ""))
         (file-prefix (file-name-nondirectory token))
         (completion-root (if (or (string-prefix-p "/" token)
                                  (string-prefix-p "~/" token))
                              (expand-file-name directory-prefix)
                            (expand-file-name directory-prefix base-directory)))
         (default-directory (file-name-as-directory completion-root)))
    (mapcar (lambda (candidate)
              (concat directory-prefix candidate))
            (file-name-all-completions file-prefix default-directory))))

(defun chat-code--path-completion-at-point ()
  "Return a completion data form for path-like input tokens."
  (when-let* ((bounds (chat-code--input-token-bounds))
              (token (buffer-substring-no-properties (car bounds) (cdr bounds)))
              ((chat-code--path-token-p token)))
    (let ((base-directory (chat-code--path-completion-root)))
      (list
       (car bounds)
       (cdr bounds)
       (lambda (string predicate action)
         (if (eq action 'metadata)
             '(metadata (category . file))
           (complete-with-action
            action
            (chat-code--path-completion-candidates string base-directory)
            string
            predicate)))
       :exclusive 'no
       :company-kind (lambda (_candidate) 'file)))))

(defun chat-code--maybe-complete-path-after-insert ()
  "Auto-trigger file completion for path-like tokens in the input area."
  (when (and chat-code-auto-path-completion
             (not chat-code--auto-path-completion-active)
             (chat-code--point-in-input-p)
             (not (minibufferp))
             (let ((char last-command-event))
               (or (eq char ?/)
                   (eq char ?.)
                   (eq char ?~)
                   (and (characterp char)
                        (or (and (>= char ?0) (<= char ?9))
                            (and (>= char ?A) (<= char ?Z))
                            (and (>= char ?a) (<= char ?z))
                            (memq char '(?_ ?-)))))))
    (when (chat-code--path-completion-at-point)
      (let ((chat-code--auto-path-completion-active t))
        (completion-at-point)))))

(defun chat-code-insert-newline ()
  "Insert a newline in the input area without sending the message."
  (interactive)
  (unless (chat-code--point-in-input-p)
    (goto-char (point-max)))
  (insert "\n"))

;; ------------------------------------------------------------------
;; Mode Definition
;; ------------------------------------------------------------------

(defvar chat-code-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Send message
    (define-key map (kbd "RET") 'chat-code-send-message)
    (define-key map (kbd "<S-return>") 'chat-code-insert-newline)
    ;; Accept/Reject changes
    (define-key map (kbd "C-c C-a") 'chat-code-accept-last-edit)
    (define-key map (kbd "C-c C-k") 'chat-code-reject-last-edit)
    (define-key map (kbd "C-c C-v") 'chat-code-view-preview)
    ;; Navigation
    (define-key map (kbd "C-c C-f") 'chat-code-focus-file)
    (define-key map (kbd "C-c C-r") 'chat-code-refresh-context)
    (define-key map (kbd "C-c C-q") 'chat-code-quote-region)
    (define-key map (kbd "C-c C-SPC") 'chat-code-ask-region)
    (define-key map (kbd "C-c C-s") 'chat-code-show-current-request-status)
    (define-key map (kbd "C-c C-p") 'chat-code-toggle-request-panel)
    (define-key map (kbd "C-c C-e") 'chat-code-edit-last-user-message)
    (define-key map (kbd "C-c C-g") 'chat-code-regenerate-last-response)
    (define-key map (kbd "C-c C-h") 'chat-code-show-help)
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
  C-c C-q    - Quote active region into input
  C-c C-SPC  - Ask about active region
  C-c C-s    - Show request status
  C-c C-p    - Toggle request panel
  C-c C-e    - Edit and resend last user message
  C-c C-g    - Regenerate last assistant response
  C-c C-h    - Open code mode help
  S-RET      - Insert newline without sending
  C-g        - Cancel current operation

In this mode, all operations use a single buffer design.
Preview is shown in a separate buffer that you can switch to manually
using C-x b or C-c C-v."
  :group 'chat-code
  (setq buffer-read-only nil)
  (setq truncate-lines nil)
  (setq-local completion-at-point-functions
              '(chat-code--path-completion-at-point))
  (add-hook 'post-self-insert-hook
            #'chat-code--maybe-complete-path-after-insert
            nil
            t))

;; ------------------------------------------------------------------
;; Core Commands
;; ------------------------------------------------------------------

(defun chat-code-send-message ()
  "Send message from input area."
  (interactive)
  (when chat-code--current-session
    (let* ((input-start (marker-position chat-code--input-marker))
           (input-end (point-max))
           (content (string-trim (buffer-substring-no-properties
                                  input-start input-end))))
      (cond
       ((string-empty-p content)
        (message "Cannot send empty message"))
       ((chat-agent-active-p chat-code--active-agent-run)
        (delete-region input-start input-end)
        (goto-char input-start)
        (let ((user-msg (make-chat-message
                         :id (chat-session-new-message-id)
                         :role :user
                         :content content
                         :timestamp (current-time))))
          (chat-session-add-message (chat-code--base-session) user-msg)
          (chat-code--display-user-message content)
          (chat-agent-steer chat-code--active-agent-run user-msg)
          (message "Message queued for the active response.")))
       ((chat-code--response-active-p)
        (message "A response is already in progress. Cancel it before sending another message."))
       (t
        (delete-region input-start input-end)
        (goto-char input-start)
        (let ((user-msg (make-chat-message
                         :id (chat-session-new-message-id)
                         :role :user
                         :content content
                         :timestamp (current-time))))
          (chat-session-add-message (chat-code--base-session) user-msg)
          (chat-code--display-user-message content)
          (chat-code--process-message)))))))

(defun chat-code-show-help ()
  "Display the code-mode help buffer."
  (interactive)
  (with-current-buffer (get-buffer-create "*Chat Code Help*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert chat-code-commands-help)
      (goto-char (point-min))
      (view-mode 1))
    (pop-to-buffer (current-buffer))))

(defun chat-code-quote-region ()
  "Quote the active region into the current code-mode input area."
  (interactive)
  (unless (region-active-p)
    (user-error "No active region to quote"))
  (chat-code--quote-capture (chat-code--capture-region)))

(defun chat-code-ask-region (question)
  "Ask QUESTION about the active region in code mode."
  (interactive "sQuestion: ")
  (unless (region-active-p)
    (user-error "No active region to ask about"))
  (chat-code--ask-capture (chat-code--capture-region) question))

(defun chat-code-quote-defun ()
  "Quote the defun at point into the current code-mode input area."
  (interactive)
  (chat-code--quote-capture (chat-code--capture-defun)))

(defun chat-code-ask-defun (question)
  "Ask QUESTION about the defun at point in code mode."
  (interactive "sQuestion: ")
  (chat-code--ask-capture (chat-code--capture-defun) question))

(defun chat-code-quote-near-point ()
  "Quote nearby context around point into the current code-mode input area."
  (interactive)
  (chat-code--quote-capture (chat-code--capture-near-point)))

(defun chat-code-ask-near-point (question)
  "Ask QUESTION about nearby context around point in code mode."
  (interactive "sQuestion: ")
  (chat-code--ask-capture (chat-code--capture-near-point) question))

(defun chat-code-quote-current-file ()
  "Quote the current file into the current code-mode input area."
  (interactive)
  (chat-code--quote-capture (chat-code--capture-current-file)))

(defun chat-code-ask-current-file (question)
  "Ask QUESTION about the current file in code mode."
  (interactive "sQuestion: ")
  (chat-code--ask-capture (chat-code--capture-current-file) question))

(defun chat-code--process-message ()
  "Process the latest user message."
  (when chat-code--current-session
    (chat-code--send-to-llm)))

(defcustom chat-code-use-streaming t
  "Whether to use streaming responses for code mode."
  :type 'boolean
  :group 'chat-code)

(defun chat-code--make-agent-event-handler (content-start ui-buffer)
  "Return an agent event handler rendering into UI-BUFFER at CONTENT-START."
  (let ((tool-events nil)
        (visible-content ""))
    (lambda (event)
      (let ((type (plist-get event :type)))
        (cond
         ((eq type 'turn-start)
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (chat-code--set-status
               'running
               (if (> (plist-get event :step) 1)
                   (format "Resolving tools (%d/%s)"
                           (1- (plist-get event :step))
                           (chat-agent-budget-label (chat-code--step-limit)))
                 "Waiting for model")))))
         ((eq type 'stream-chunk)
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (chat-code--set-status 'running "Streaming response")
              (setq visible-content
                    (string-trim-right
                     (chat-tool-caller-extract-content
                      (or (plist-get event :content) ""))))
              (chat-code--render-response-state
               content-start
               visible-content
               tool-events
               nil
               nil
               (chat-code--live-placeholder))
              (redisplay t))))
         ((eq type 'tool-event)
          (setq tool-events (append tool-events
                                    (list (plist-get event :event))))
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (setq chat-code--request-tool-events tool-events)
              (chat-code--render-response-state
               content-start
               visible-content
               tool-events
               nil
               nil
               (chat-code--request-live-detail)))))
         ((eq type 'message-appended)
          (chat-agent-transcript-persist-message
           (chat-code--base-session)
           (plist-get event :message)))
         ((eq type 'response)
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (setq visible-content
                    (or (plist-get (plist-get event :processed) :content) ""))
              (chat-code--render-response-state
               content-start
               visible-content
               tool-events
               nil
               nil
               (chat-code--request-live-detail)))))
         ((eq type 'followup)
          (when chat-code--current-request-id
            (chat-request-diagnostics-record
             chat-code--current-request-id
             'tool-loop-step
             :summary (format "Resolving tool step %d"
                              (plist-get event :step)))))
         ((eq type 'agent-end)
          (setq chat-code--active-agent-run nil)
          (setq chat-code--active-request-handle nil)
          (setq chat-code--active-stream-process nil)
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (let ((status (plist-get event :status)))
                (pcase status
                  ((or 'completed 'stopped)
                   (chat-code--cleanup-request-state
                    'completed "Request completed")
                   (chat-code--set-status
                    (if (eq status 'stopped) 'stopped 'success)
                    (if (eq status 'stopped)
                        (format "Stopped after step limit (%s)"
                                (chat-agent-budget-label
                                 (chat-code--step-limit)))
                      "Completed"))
                   (let ((processed
                          (list :content (plist-get event :content)
                                :tool-events (plist-get event :tool-events)
                                :tool-loop-limit-reached
                                (eq status 'stopped))))
                     (chat-code--display-processed-response
                      processed content-start)))
                  ('cancelled
                   (chat-code--cleanup-request-state
                    'cancelled "Cancelled by user")
                   (chat-code--set-status 'cancelled "Cancelled by user"))
                  ('error
                   (chat-code--handle-llm-error
                    (or (plist-get event :reason) "Unknown error")
                    content-start))))))))))))

(defun chat-code--start-agent-run (transport model prepared-messages content-start)
  "Start an agent run for TRANSPORT with MODEL and PREPARED-MESSAGES.
CONTENT-START marks the assistant response body."
  (setq chat-code--active-agent-run
        (chat-agent-start
         (list :model model
               :messages prepared-messages
               :session (chat-code--base-session)
               :transport transport
               :max-steps chat-code-tool-loop-max-steps
               :transform-context-fn
               (lambda (_run step-messages)
                 (if (cl-every #'chat-message-p step-messages)
                     (chat-context-prepare-messages
                      step-messages
                      (chat-code--request-message-budget model step-messages)
                      (chat-code--base-session))
                   step-messages))
               :followup-fn
               (lambda (processed)
                 (when (and (null (plist-get processed :tool-calls))
                            (plist-get processed :parse-error))
                   chat-tool-caller-parse-error-followup-text))
               :request-options
               (append
                (list :temperature 0.7
                      :max-tokens (chat-code--request-output-budget model)
                      :timeout chat-code-request-timeout)
                (when chat-code--current-request-id
                  (list :request-id chat-code--current-request-id)))
               :followup-request-options
               (list :timeout chat-code-tool-followup-timeout)
               :on-event
               (chat-code--make-agent-event-handler
                content-start (current-buffer))))))

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
         (base-session (chat-code--base-session))
         (full-system-prompt (chat-tool-caller-build-system-prompt
                              base-system-prompt
                              (chat-code--step-limit)
                              base-session))
         (model (chat-session-model-id base-session))
         (messages (cons
                    (make-chat-message
                     :id "system-code"
                     :role :system
                     :content full-system-prompt
                     :timestamp (current-time))
                    ;; The session records more than a request should carry:
                    ;; command replies and captured shell output are there
                    ;; for the reader.
                    (chat-transcript-model-messages
                     (chat-session-messages base-session))))
         (prepared-messages (chat-code--prepare-request-messages model messages))
         (content-start (chat-code--show-assistant-indicator)))
    (setq chat-code--active-request-model model)
    (setq chat-code--active-request-messages prepared-messages)
    (chat-code--begin-request
     model
     (if chat-code-use-streaming 'stream 'async))
    ;; Choose streaming or non-streaming
    (chat-code--set-status 'running "Waiting for model")
    (chat-code--render-progress content-start
                                (format "Running with %s"
                                        (chat-code--model-label model)))
    (chat-code--start-agent-run
     (if chat-code-use-streaming 'stream 'sync)
     model
     prepared-messages
     content-start)
    ;; Update context
    (setf (chat-code-session-context-files chat-code--current-session)
          (mapcar #'chat-code-file-context-path
                  (chat-code-context-files context)))))

(defun chat-code--display-user-message (content)
  "Display user message CONTENT in buffer."
  (chat-code--append-to-messages
   (lambda ()
     (insert (propertize "You:\n" 'face 'font-lock-keyword-face))
     (insert content)
     (insert "\n\n"))))

(defun chat-code--insert-session-message (message)
  "Insert MESSAGE into the current code-mode buffer."
  (pcase (chat-message-role message)
    (:user
     (insert (propertize "You:\n" 'face 'font-lock-keyword-face))
     (insert (chat-message-content message))
     (insert "\n\n"))
    (:assistant
     (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
     (chat-code--insert-formatted-response (chat-message-content message))
     (insert "\n\n"))
    (:system
     (insert (propertize "System:\n" 'face 'font-lock-comment-face))
     (insert (chat-message-content message))
     (insert "\n\n"))
    (_
     (insert (format "%s:\n" (chat-message-role message)))
     (insert (chat-message-content message))
     (insert "\n\n"))))

(defun chat-code--restore-input (content)
  "Restore CONTENT into the current code-mode input area."
  (goto-char (marker-position chat-code--input-marker))
  (insert content))

(defun chat-code--rebuild-buffer (&optional input-content)
  "Rebuild the current code-mode buffer and optionally restore INPUT-CONTENT."
  (chat-code--setup-buffer chat-code--current-session)
  (when input-content
    (chat-code--restore-input input-content)))

(defun chat-code--show-assistant-indicator ()
  "Show assistant is thinking indicator and return content marker."
  (let (content-start)
    (chat-code--append-to-messages
     (lambda ()
       (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
       (setq content-start (copy-marker (point)))
       (insert "Preparing request...\n\n")))
    content-start))

(defun chat-code--handle-llm-error (error-msg &optional content-start)
  "Handle LLM error ERROR-MSG.
If CONTENT-START is non nil, replace the pending assistant slot."
  (setq chat-code--active-request-handle nil)
  (setq chat-code--active-stream-process nil)
  (chat-code--cleanup-request-state 'error error-msg)
  (chat-code--set-status 'failed error-msg)
  (message "LLM Error: %s" error-msg)
  (let ((render-error
         (lambda ()
           (insert (propertize "Error: " 'face 'error))
           (insert (format "%s\n\n" error-msg)))))
    (if content-start
        (chat-code--replace-response-slot content-start render-error)
      (chat-code--append-to-messages render-error))))

(defun chat-code-regenerate-last-response ()
  "Regenerate the trailing assistant response in the current code session."
  (interactive)
  (unless chat-code--current-session
    (user-error "No active code session"))
  (if (chat-code--response-active-p)
      (message "A response is already in progress. Cancel it before regenerating.")
    (let* ((base-session (chat-code--base-session))
           (assistant-msg
            (chat-session-find-last-message-by-role base-session :assistant)))
      (unless assistant-msg
        (user-error "No assistant response available to regenerate"))
      (setq chat-code--current-session
            (chat-session-create-branch-before-message
             base-session
             (chat-message-id assistant-msg)
             nil
             '((reason . "regenerate"))))
      (chat-code--rebuild-buffer)
      (chat-code--send-to-llm))))

(defun chat-code-edit-last-user-message ()
  "Restore the last user message to the input area for editing."
  (interactive)
  (unless chat-code--current-session
    (user-error "No active code session"))
  (if (chat-code--response-active-p)
      (message "A response is already in progress. Cancel it before editing the last message.")
    (let* ((base-session (chat-code--base-session))
           (user-msg
            (chat-session-find-last-message-by-role base-session :user)))
      (unless user-msg
        (user-error "No user message available to edit"))
      (setq chat-code--current-session
            (chat-session-create-branch-before-message
             base-session
             (chat-message-id user-msg)
             nil
             '((reason . "edit-resend"))))
      (chat-code--rebuild-buffer (chat-message-content user-msg)))))

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
                           'chat-code-block-face)))
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
    (chat-code--remember-focus-file file-path)))

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
  (when (chat-agent-active-p chat-code--active-agent-run)
    (chat-agent-cancel chat-code--active-agent-run))
  (when chat-code--active-request-handle
    (chat-llm-cancel-request chat-code--active-request-handle)
    (setq chat-code--active-request-handle nil))
  (when (and chat-code--active-stream-process
             (process-live-p chat-code--active-stream-process))
    (when chat-code--current-request-id
      (chat-request-diagnostics-record
       chat-code--current-request-id
       'cancelled
       :process chat-code--active-stream-process
       :summary "Cancelled by user"))
    (delete-process chat-code--active-stream-process)
    (setq chat-code--active-stream-process nil))
  (chat-code--cleanup-request-state)
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

(defun chat-code--selection-line-range ()
  "Return the current region line range as a cons."
  (when (region-active-p)
    (cons (line-number-at-pos (region-beginning))
          (line-number-at-pos (region-end)))))

(defun chat-code--prepare-reading-session ()
  "Return a code session suitable for reading workflow commands."
  (or (and (boundp 'chat-code--current-session)
           chat-code--current-session)
      (chat-code-session-create
       (format "Code: %s"
               (file-name-nondirectory
                (or (buffer-file-name)
                    default-directory)))
       (or (ignore-errors (chat-code--detect-project-root))
           default-directory)
       (buffer-file-name))))

(defun chat-code--quote-capture (capture)
  "Insert CAPTURE into the current code-mode input area."
  (let ((prompt (chat-code--quoted-capture-prompt capture))
        (session (chat-code--prepare-reading-session)))
    (chat-code--open-session session)
    (with-current-buffer (chat-code--buffer-name session)
      (delete-region (marker-position chat-code--input-marker) (point-max))
      (goto-char (marker-position chat-code--input-marker))
      (insert prompt))))

(defun chat-code--ask-capture (capture question)
  "Send QUESTION about CAPTURE in code mode."
  (let ((prompt (chat-code--quoted-capture-prompt capture question))
        (session (chat-code--prepare-reading-session)))
    (chat-code--open-session session)
    (with-current-buffer (chat-code--buffer-name session)
      (delete-region (marker-position chat-code--input-marker) (point-max))
      (goto-char (marker-position chat-code--input-marker))
      (insert prompt)
      (chat-code-send-message))))

(defun chat-code--quoted-capture-prompt (capture &optional question)
  "Build a structured quoted prompt for CAPTURE and QUESTION."
  (chat-reading-format-question capture question))

(defun chat-code--get-function-at-point ()
  "Get function at point as string."
  (save-excursion
    (when (beginning-of-defun)
      (let ((start (point)))
        (end-of-defun)
        (buffer-substring-no-properties start (point))))))

(defun chat-code--capture-region ()
  "Capture the active region for reading workflow commands."
  (chat-reading-capture-region))

(defun chat-code--capture-defun ()
  "Capture the defun at point for reading workflow commands."
  (chat-reading-capture-defun))

(defun chat-code--capture-near-point ()
  "Capture nearby context around point for reading workflow commands."
  (chat-reading-capture-near-point chat-code-reading-near-point-radius))

(defun chat-code--capture-current-file ()
  "Capture the current file for reading workflow commands."
  (chat-reading-capture-current-file))

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
