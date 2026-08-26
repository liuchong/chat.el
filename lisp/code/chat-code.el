;;; chat-code.el --- AI code editing mode for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, ai, code, programming

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides AI-powered code editing capabilities for chat.el.
;; Code capability for a chat session: project-aware context, coding
;; prompts, and a preview-based editing workflow.  There is no code
;; buffer and no code major mode -- a coding session is an ordinary chat
;; buffer whose session carries a project root, a focus file and a
;; context strategy, so it draws, streams, reports status and takes keys
;; through the same implementation as every other session.
;;
;; It was a second surface once, with its own copy of the request and
;; rendering pipeline.  The copies drifted: this side learned to cut
;; streaming updates at a fence boundary and to summarize tool results
;; readably, the other learned to guard a dead buffer and to read the
;; project's own instructions.  Each fix landed on one side only.

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

;; The shared surface loads before this module, and requiring it back
;; would be circular: it reaches into code capability only through
;; `fboundp' checks, and this module reaches into the surface it is drawn
;; on.  Declared rather than required so the dependency stays one way.
(declare-function chat--open-chat-session "chat" (session))
(declare-function chat--buffer-name "chat" (session))
(declare-function chat-ui-send-message "chat-ui" ())
(defvar chat-ui--input-overlay)
(defvar chat-ui--messages-end)

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
  "Whether a session may be given code capability."
  :type 'boolean
  :group 'chat-code)

(defcustom chat-code-default-strategy 'balanced
  "Default context strategy for a session with code capability.
\='minimal      - Current file only (~2k tokens)
\='focused      - Current file + related files (~4k tokens)
\='balanced     - + Symbols + Imports (~8k tokens)
\='comprehensive - Full project structure (~16k tokens)"
  :type '(choice (const minimal)
                 (const focused)
                 (const balanced)
                 (const comprehensive))
  :group 'chat-code)

(defcustom chat-code-auto-apply-threshold 10
  "Automatically apply changes smaller than this many lines.
Set to 0 to never auto-apply."
  :type 'integer
  :group 'chat-code)

;; These settings governed the code surface's own copy of the request and
;; rendering pipeline.  There is one pipeline now, so they are aliases to
;; the settings that survived: a configuration that set them keeps
;; working rather than silently losing effect.

(define-obsolete-variable-alias 'chat-code-max-output-tokens
  'chat-ui-max-output-tokens "chat.el 2026-08")
(define-obsolete-variable-alias 'chat-code-request-timeout
  'chat-ui-request-timeout "chat.el 2026-08")
(define-obsolete-variable-alias 'chat-code-tool-followup-timeout
  'chat-ui-tool-followup-timeout "chat.el 2026-08")
(define-obsolete-variable-alias 'chat-code-tool-result-summary-max-chars
  'chat-ui-tool-summary-max-chars "chat.el 2026-08")
(define-obsolete-variable-alias 'chat-code-auto-path-completion
  'chat-ui-auto-path-completion "chat.el 2026-08")
(define-obsolete-variable-alias 'chat-code-use-streaming
  'chat-ui-use-streaming "chat.el 2026-08")

;; These three sized a context calculation that capped history at a flat
;; 8000 tokens regardless of the model.  The budget module derives the
;; limit from the model's own window instead, so there is nothing left
;; for them to point at.
(make-obsolete-variable 'chat-code-max-tokens
                        "context is sized from the model's window; see chat-context-budget"
                        "chat.el 2026-08")
(make-obsolete-variable 'chat-code-history-max-tokens
                        "context is sized from the model's window; see chat-context-budget"
                        "chat.el 2026-08")
(make-obsolete-variable 'chat-code-request-safety-margin
                        "context is sized from the model's window; see chat-context-budget"
                        "chat.el 2026-08")

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
  "System prompt for a session with code capability."
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
  "Non-negotiable rules always sent for a session with code capability.")

(defconst chat-code--coding-best-practices
  '("Prefer concrete code paths, data flow, and call sites over comments or file names."
    "Use the smallest sufficient set of files and tools."
    "Prefer structured file tools before readonly shell inspection."
    "When reading a project, start from the focused file, project instructions, and nearby entry points."
    "For debugging, distinguish observed facts from hypotheses."
    "For fixes, prefer root-cause changes over cosmetic patches."
    "When practical, add or update tests that lock in the behavior being changed.")
  "Reusable programming best practices sent with code capability.")

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
  "Editing protocol rules sent with code capability.")

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
  "Define accessor NAME reading session metadata KEY, with setters.

NORMALIZER, when given, converts what storage returns into the type the
rest of the code expects.

Two ways to write are defined on purpose.  The `setf' expander is for
this module; the named function is for callers loaded before it, where a
`setf' place would have to be expanded before its expander exists and
would silently compile to something else."
  (let ((setter (intern (format "%s-set"
                                (replace-regexp-in-string
                                 "\\`chat-code-session-" "chat-code-session-set-"
                                 (symbol-name name))))))
    (ignore setter)
    `(progn
       (defun ,name (session)
         ,(format "Return the %s recorded for SESSION." key)
         (let ((value (chat-session-metadata-get session ',key)))
           ,(if normalizer `(,normalizer value) 'value)))
       (defun ,(intern (replace-regexp-in-string
                        "\\`chat-code-session-" "chat-code-session-set-"
                        (symbol-name name)))
           (session value)
         ,(format "Record VALUE as the %s of SESSION." key)
         (chat-session-metadata-set session ',key value))
       (gv-define-setter ,name (value session)
         (list 'chat-session-metadata-set session '',key value)))))

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

;; Everything about drawing a conversation, tracking a request and
;; reporting status now lives on the one surface, so the buffer-local
;; state that mirrored it is gone.  What remains here is the state that
;; only exists because a session has code capability.

(defvar-local chat-code--pending-edit nil
  "Currently pending edit waiting for user confirmation.")

(defvar chat-code--preview-buffer-name "*chat-preview*"
  "Name of the preview buffer.")

(defcustom chat-code-tool-loop-max-steps nil
  "Step ceiling for a coding run, or nil to follow the global budget.

Set this only to hold coding sessions to a tighter limit than
`chat-agent-max-steps'; `unlimited' lifts the ceiling entirely."
  :type '(choice (const :tag "Follow chat-agent-max-steps" nil)
                 (integer :tag "Steps")
                 (const :tag "Unlimited" unlimited))
  :group 'chat-code)







(defun chat-code--session ()
  "Return the code session bound in this buffer, or nil.

Reads the one session binding every chat buffer has.  Code capability is
a property of that session, so there is nothing else to consult, and a
command that needs capability can tell the difference between \"no
session\" and \"no code capability\"."
  (and (boundp 'chat--current-session)
       chat--current-session
       (chat-code-session-p chat--current-session)
       chat--current-session))

(defun chat-code--remember-focus-file (file-path &optional silent)
  "Store FILE-PATH as the current focus file.
When SILENT is non-nil, do not show minibuffer feedback."
  (when-let ((session (and file-path (chat-code--session))))
    (let* ((resolved (chat-files--resolved-path file-path))
           (current-focus (chat-code-session-focus-file session))
           (context-files (chat-code-session-context-files session)))
      (setf (chat-code-session-focus-file session) resolved)
      (setf (chat-code-session-context-files session)
            (delete-dups (cons resolved context-files)))
      (unless (or silent (equal current-focus resolved))
        (message "Focus set to: %s" (file-name-nondirectory resolved))))))










 













(defun chat-code--operation-guardrails ()
  "Return runtime operational guardrails for the current code session."
  (let* ((session (chat-code--session))
         (project-root (and session (chat-code-session-project-root session)))
         (focus-file (and session (chat-code-session-focus-file session))))
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

(defun chat-code--persona-prompt ()
  "Return the coding persona, localized unless it has been customized.

A value the user set wins over any translation of it, on the same
principle as `chat-commands-help': the English in the defcustom is both
the default and the reference a translation is checked against."
  (if (equal chat-code-system-prompt
             (eval (car (get 'chat-code-system-prompt 'standard-value)) t))
      (chat-i18n-prompt 'code-persona chat-code-system-prompt)
    chat-code-system-prompt))

(defun chat-code--compose-system-prompt ()
  "Compose the full system prompt a code-capable session sends.

The rule sections stay in the language they were written in.  They are
dense with things a parser matches literally -- tool names, `AGENTS.md',
patch envelopes -- and a translation has to carry those through untouched
while changing everything around them.  That is a lot of surface for no
change in what the model does, so the persona is translated and the rules
are not."
  (mapconcat
   #'identity
   (list
    (chat-code--persona-prompt)
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













(defun chat-code--read-file-if-exists (file)
  "Return FILE contents, or nil when FILE does not exist."
  (when (and file (file-exists-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun chat-code--normalize-edit-file (path)
  "Resolve edit target PATH against the current project."
  (when (and path (not (string-empty-p path)))
    (expand-file-name
     path
     (or (when-let ((session (chat-code--session)))
           (chat-code-session-project-root session))
         default-directory))))

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
                          (when-let ((session (chat-code--session)))
                            (chat-code-session-focus-file session))))
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




(defvar-local chat-code--last-render nil
  "Last rendered slot state used by the streaming fast path.")








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
  "Start a new chat session with code capability, rooted at this project.

Capability is a property of a session rather than a surface to switch
into, so this is a constructor: it makes a session, turns the capability
on and points it at the detected project root.  It stays a separate
command from `chat-new-session' because rooting a conversation at a
project is a decision worth making when the conversation begins, and from
`chat-code-from-chat' because that one adds the capability to a
conversation already under way.

Optional PROJECT-ROOT overrides the detected project root."
  (interactive)
  (unless chat-code-enabled
    (error "Code capability is not enabled. Set chat-code-enabled to t"))
  (let* ((project-root (or project-root (chat-code--detect-project-root)))
         (session-name (format "Code: %s"
                               (file-name-nondirectory
                                (directory-file-name project-root))))
         (code-session (chat-code-session-create session-name project-root)))
    (chat-code--open-session code-session)))

;;;###autoload
(defun chat-code-for-file (file-path)
  "Start a session with code capability, focused on FILE-PATH."
  (interactive
   (list (read-file-name "Focus file: " nil nil t (buffer-file-name))))
  (unless chat-code-enabled
    (error "Code capability is not enabled. Set chat-code-enabled to t"))
  (let* ((project-root (chat-code--detect-project-root file-path))
         (session-name (format "Code: %s"
                               (file-name-nondirectory file-path)))
         (code-session (chat-code-session-create session-name
                                                  project-root
                                                  file-path)))
    (chat-code--open-session code-session)))

;;;###autoload
(defun chat-code-for-selection ()
  "Start a session with code capability, focused on the active region."
  (interactive)
  (unless chat-code-enabled
    (error "Code capability is not enabled. Set chat-code-enabled to t"))
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
  "Give the current session code capability.

The conversation is kept: capability is a property of a session, so there
is nothing to switch to and nothing to carry across."
  (interactive)
  (unless chat-code-enabled
    (error "Code capability is not enabled. Set chat-code-enabled to t"))
  (unless (and (boundp 'chat--current-session) chat--current-session)
    (error "Not in a chat buffer"))
  ;; Enabling capability on the session in hand, rather than creating one
  ;; and swapping its contents, is what the command name always claimed.
  (chat-code--open-session (chat-code-enable chat--current-session)))

;; ------------------------------------------------------------------
;; Buffer Management
;; ------------------------------------------------------------------

(defun chat-code--open-session (session)
  "Open SESSION on the single chat surface.

Kept as the entry point every code command already calls, but there is
no code buffer any more: a code session is a chat buffer whose session
happens to carry project context.  The separate buffer is what forced a
second copy of every rendering and request function."
  (chat--open-chat-session session))

;; ------------------------------------------------------------------
;; Core Commands
;; ------------------------------------------------------------------


























(defun chat-code--parse-code-edit (content)
  "Parse CODE-EDIT block from CONTENT.
Returns a chat-edit struct or nil."
  ;; Look for code edit markers
  (cond
   ;; Check for explicit CODE-EDIT block
   ((chat-code--match-fenced-block content "code-edit")
    (chat-code--parse-explicit-edit content))
   ;; Check for implied edit (single code block with context)
   ((and (when-let ((session (chat-code--session)))
           (chat-code-session-focus-file session))
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
      (let* ((file (when-let ((session (chat-code--session)))
                     (chat-code-session-focus-file session)))
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

(defun chat-code--note-in-conversation (text face)
  "Append TEXT in FACE below the conversation.

Goes through the shared surface's marker, so a note about an edit lands
in the same place as everything else the buffer shows."
  (when (and (boundp 'chat-ui--messages-end)
             (markerp chat-ui--messages-end))
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char chat-ui--messages-end)
        (insert (propertize text 'face face))
        (set-marker chat-ui--messages-end (point))))))

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
                (chat-code--note-in-conversation
                 "✓ Edit applied\n\n" '(:foreground "green"))
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
        (chat-code--note-in-conversation
         "✗ Edit rejected\n\n" '(:foreground "red")))
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
  "Change focus to FILE-PATH.

Bound in every chat buffer, so it says what is missing rather than
failing quietly in a session that has no project to focus within."
  (interactive
   (list (if-let ((session (chat-code--session)))
             (read-file-name "Focus file: "
                             (chat-code-session-project-root session) nil t)
           (user-error
            "This session has no code capability; M-x chat-code-from-chat adds it"))))
  (when (chat-code--session)
    (chat-code--remember-focus-file file-path)))

(defun chat-code-refresh-context ()
  "Refresh context for current session."
  (interactive)
  (if-let ((session (chat-code--session)))
      (let ((focus-file (chat-code-session-focus-file session)))
        (when focus-file
          (setf (chat-code-session-context-files session)
                (delete-dups
                 (cons focus-file
                       (chat-code-session-context-files session)))))
        (message "Context will be rebuilt on the next request"))
    (user-error
     "This session has no code capability; M-x chat-code-from-chat adds it")))


;; ------------------------------------------------------------------
;; Inline Editing Commands
;; ------------------------------------------------------------------

(defun chat-code--get-selection ()
  "Return the selected text, or nil."
  (when (region-active-p)
    (buffer-substring-no-properties (region-beginning) (region-end))))

(defun chat-code--get-function-at-point ()
  "Return the defun around point as a string, or nil."
  (save-excursion
    (when (beginning-of-defun)
      (let ((start (point)))
        (end-of-defun)
        (buffer-substring-no-properties start (point))))))

(defun chat-code--get-context-around-point ()
  "Return the text surrounding point, for completion requests."
  (let ((start (max (point-min) (- (point) 100)))
        (end (min (point-max) (+ (point) 100))))
    (buffer-substring-no-properties start end)))

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













(defun chat-code--inline-request (file code prompt-template title)
  "Send inline request for CODE in FILE.
PROMPT-TEMPLATE is a format string with %s for code.
TITLE is the operation title.

Reuses the session bound in the current buffer when there is one, so
invoking this from a chat buffer continues that conversation rather than
starting a parallel one about the same file."
  (let* ((session (or (and (boundp 'chat--current-session)
                           chat--current-session
                           (chat-code-session-p chat--current-session)
                           chat--current-session)
                      (chat-code-session-create
                       title
                       (chat-code--detect-project-root file)
                       file)))
         (full-prompt (format prompt-template code)))
    (chat-code--open-session session)
    (with-current-buffer (chat--buffer-name session)
      (delete-region (marker-position chat-ui--input-overlay) (point-max))
      (goto-char (marker-position chat-ui--input-overlay))
      (insert full-prompt)
      (chat-ui-send-message))))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat-code)
;;; chat-code.el ends here
