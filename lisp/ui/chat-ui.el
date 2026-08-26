;;; chat-ui.el --- UI components for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, ui

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides UI components and interaction for chat sessions.

;;; Code:

(require 'chat-i18n)
(require 'chat-command)
;; Owned by `chat.el', which loads after this file.
(defvar chat-commands-help)
(defvar chat-auto-save-sessions)
(declare-function chat-help-text "chat" ())
(declare-function chat-new-session "chat" (&optional name model))
(declare-function chat-list-sessions "chat" ())
(declare-function ansi-color-apply "ansi-color" (string))
(require 'chat-session)
(require 'chat-transcript)
(require 'chat-llm)
(require 'chat-stream)
(require 'chat-tool-forge-ai)
(require 'chat-tool-caller)
(require 'chat-context)
(require 'chat-context-budget)
(require 'chat-log)
(require 'chat-request-diagnostics)
(require 'chat-request-panel)
(require 'chat-request-surface)
(require 'chat-status)
(require 'chat-agent)
(require 'chat-agent-transcript)

;; Code capability lives in a module that loads after this one, because
;; it is an optional property of a session rather than a second surface.
;; Declared rather than required so the dependency stays one-way.
(declare-function chat-code-session-p "chat-code" (session))
(declare-function chat-code--compose-system-prompt "chat-code" ())
(declare-function chat-code-session-project-root "chat-code" (session))
(declare-function chat-code-session-focus-file "chat-code" (session))
(declare-function chat-code-session-context-strategy "chat-code" (session))
(declare-function chat-code-session-context-files "chat-code" (session))
(declare-function chat-code--parse-code-edit "chat-code" (content))
(declare-function chat-code--propose-edit "chat-code" (edit))
(declare-function chat-code-session-set-focus-file "chat-code" (session value))
(declare-function chat-code-session-set-context-files "chat-code" (session value))
(declare-function chat-code-lsp-available-p "chat-code-lsp" ())
(declare-function chat-code-lsp-get-context "chat-code-lsp" ())
(declare-function chat-code-lsp-format-context "chat-code-lsp" (context))
(declare-function chat-context-code-build "chat-context-code" (session))
(declare-function chat-context-code-to-string "chat-context-code" (context))

;; ------------------------------------------------------------------
;; Chat Buffer Management
;; ------------------------------------------------------------------

(defvar chat--current-session nil
  "Current chat session bound by chat buffers.")

(defvar chat-ui-use-streaming nil
  "Whether chat UI should use streaming responses.")

(defvar-local chat-ui--active-stream-process nil
  "Currently active stream process for cancellation.")

(defvar-local chat-ui--input-overlay nil
  "Overlay for the input area in chat buffer.")

(defvar-local chat-ui--messages-end nil
  "Marker for end of messages area.")

(defvar-local chat-ui--active-request-handle nil
  "Currently active non streaming request handle.")

(defvar-local chat-ui--active-agent-run nil
  "Currently active agent run state, or nil.")

(defvar-local chat-ui--current-request-id nil
  "Diagnostics request id for the current chat buffer.")

(defvar-local chat-ui--request-hint-timer nil
  "Timer used to show stalled request hints.")

(defvar-local chat-ui--request-hint-shown nil
  "Whether a stalled request hint has already been shown.")

(defvar-local chat-ui--request-refresh-timer nil
  "Timer used to refresh live request surfaces.")

(defvar-local chat-ui--request-diagnostics-observer nil
  "Observer callback registered for live diagnostics updates.")

(defvar-local chat-ui--request-tool-events nil
  "Current structured tool events for the request panel.")

(defvar-local chat-ui--last-approval-hint nil
  "Last approval hint signature shown in this buffer.")

(defvar-local chat-ui--last-tracked-tool-paths nil
  "Most recent file targets seen in this chat buffer.")

(defvar-local chat-ui--live-response-content ""
  "Accumulated visible content for the current live response.")

(defvar-local chat-ui--last-render nil
  "Last rendered slot state used by the streaming fast path.")

(defvar-local chat-ui--conversation-start nil
  "Marker where the conversation begins, just after the header.")

(defvar-local chat-ui--live-start nil
  "Marker where the in-flight part of the current turn begins.

Everything before it has been recorded on the session and is redrawn only
when the record changes.  Everything after it is the tail that has not
been recorded yet, which is what a stream chunk rewrites.

Insertion type nil, so text arriving at the boundary lands after it:
anything written past the committed history is by definition the tail.")

(defvar-local chat-ui--opened-fold-groups nil
  "Fold group keys the reader opened by hand.

Keyed by the first part of a run, so a group stays open while later parts
of the same channel arrive.")

(defvar-local chat-ui--live-trailers nil
  "Plist of trailing notes for the in-flight turn.

Holds `:tool-summary' and `:limit-reached', which belong to the turn as a
whole rather than to any one part of it.")

(defun chat-ui--pending-approval-event ()
  "Return the current pending approval event when present."
  (chat-status-persistent-event chat-ui--request-tool-events))

(defun chat-ui--status-line (session)
  "Return top status line text for SESSION."
  (let* ((model (and session (chat-session-model-id session)))
         (label (chat-status-persistent-label chat-ui--request-tool-events))
         ;; The default command changes what plain input does, so it
         ;; belongs where the reader already looks for what this session
         ;; is.  An invisible mode that eats prose is the failure here.
         ;; The baseline is not announced: naming it every time would
         ;; train the reader to stop reading the field that matters.
         (auto (and (chat-ui-default-command-claimed-p session)
                    (chat-ui--display-command-name
                     (chat-ui-default-command session))))
         (queued (chat-ui--queue-length session)))
    (concat (chat-i18n 'status-model "Model: %s" model)
            (when auto (format " | %s" (chat-i18n 'status-auto "auto: /%s" auto)))
            (when (> queued 0)
              (format " | %s" (chat-i18n 'status-queued "queued: %d" queued)))
            (when label (format " | %s" label)))))

(defun chat-ui--render-status-line ()
  "Rewrite the status line in place from the current session."
  (save-excursion
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (forward-line 1)
      (delete-region (line-beginning-position) (line-end-position))
      (insert (propertize
               (chat-ui--status-line
                (and (boundp 'chat--current-session)
                     chat--current-session))
               'face 'shadow)))))

(defun chat-ui--response-active-p ()
  "Return non nil when a response is already in progress."
  (or (chat-agent-active-p chat-ui--active-agent-run)
      chat-ui--active-request-handle
      (and chat-ui--active-stream-process
           (process-live-p chat-ui--active-stream-process))))

(defun chat-ui--clear-request-hint-timer ()
  "Cancel and clear the stalled request hint timer."
  (when (timerp chat-ui--request-hint-timer)
    (cancel-timer chat-ui--request-hint-timer))
  (setq chat-ui--request-hint-timer nil))

(defun chat-ui--clear-request-refresh-timer ()
  "Cancel and clear the live request refresh timer."
  (when (timerp chat-ui--request-refresh-timer)
    (cancel-timer chat-ui--request-refresh-timer))
  (setq chat-ui--request-refresh-timer nil))

(defun chat-ui--unsubscribe-request-diagnostics ()
  "Remove the current request diagnostics observer."
  (when (and chat-ui--current-request-id
             chat-ui--request-diagnostics-observer)
    (chat-request-diagnostics-unsubscribe
     chat-ui--current-request-id
     chat-ui--request-diagnostics-observer))
  (setq chat-ui--request-diagnostics-observer nil))

(defun chat-ui--session-metadata-get (key)
  "Return current session metadata entry for KEY."
  (chat-session-metadata-get chat--current-session key))

(defun chat-ui--session-metadata-set (key value)
  "Store VALUE under KEY in the current session metadata."
  (when chat--current-session
    (chat-session-metadata-set chat--current-session key value)
    (when chat-session-auto-save
      (chat-session-save chat--current-session))))

(defun chat-ui--promote-code-focus (session paths latest-single-target)
  "Record PATHS and LATEST-SINGLE-TARGET as SESSION's code context.

A code session's focus follows what the run actually touched, so the next
request carries the file the conversation moved to rather than the one it
started on.  A session without code capability has no focus to move."
  (when (and session
             (fboundp 'chat-code-session-p)
             (chat-code-session-p session))
    (when paths
      (chat-code-session-set-context-files
       session
       (delete-dups
        (append (mapcar #'chat-files--resolved-path paths)
                (chat-code-session-context-files session)))))
    (when latest-single-target
      (chat-code-session-set-focus-file
       session (chat-files--resolved-path latest-single-target)))))

(defun chat-ui--track-tool-targets (tool-events)
  "Update recent file target state from TOOL-EVENTS."
  (when-let ((target-data (chat-request-surface-tool-targets tool-events)))
    (let ((all-paths (delete-dups (plist-get target-data :paths)))
          (latest-single-target (plist-get target-data :latest-single-target)))
      (setq chat-ui--last-tracked-tool-paths all-paths)
      (chat-ui--session-metadata-set :chat-ui-recent-target-paths all-paths)
      (when latest-single-target
        (chat-ui--session-metadata-set
         :chat-ui-preferred-target-path
         (chat-files--resolved-path latest-single-target)))
      (chat-ui--promote-code-focus
       chat--current-session all-paths latest-single-target))))

(defun chat-ui--request-live-detail (&optional snapshot)
  "Return a compact live request label from SNAPSHOT."
  (chat-request-diagnostics-live-detail
   (or snapshot
       (and chat-ui--current-request-id
            (chat-request-diagnostics-snapshot
             chat-ui--current-request-id)))
   chat-ui--request-tool-events))

(defun chat-ui--live-narrative-line (&optional detail)
  "Return a transient live narrative line for DETAIL."
  (chat-request-surface-live-narrative-line
   (or detail
       (chat-ui--request-live-detail))))

(defun chat-ui--refresh-live-response (&optional snapshot)
  "Refresh the in-flight tail of the transcript from SNAPSHOT."
  (when (and chat-ui--live-start
             (marker-buffer chat-ui--live-start))
    (chat-ui--render-response-state
     (current-buffer)
     chat-ui--live-start
     chat-ui--live-response-content
     chat-ui--request-tool-events
     (chat-ui--request-live-detail snapshot))))

(defun chat-ui--refresh-live-surfaces (&optional snapshot)
  "Refresh transcript and panel surfaces from SNAPSHOT."
  (when chat-ui--current-request-id
    (chat-ui--refresh-live-response snapshot)
    (chat-request-surface-update-panel-if-visible
     (current-buffer)
     chat-ui--current-request-id
     chat-ui--request-tool-events)))

(defun chat-ui--handle-request-diagnostics-update (id _trace _event)
  "Handle diagnostics update for request ID."
  (when (equal id chat-ui--current-request-id)
    (chat-ui--refresh-live-surfaces
     (chat-request-diagnostics-snapshot id))))

(defun chat-ui--start-request-refresh-timer (buffer)
  "Start the live request refresh timer for BUFFER."
  (chat-ui--clear-request-refresh-timer)
  (setq chat-ui--request-refresh-timer
        (chat-request-surface-start-refresh-timer
         buffer
         (lambda () chat-ui--current-request-id)
         #'chat-ui--refresh-live-surfaces
         #'chat-ui--clear-request-refresh-timer)))

(defun chat-ui--cleanup-request-state (&optional phase summary)
  "Clear current request state and optionally record PHASE and SUMMARY."
  (let ((source-buffer (current-buffer)))
    (chat-request-surface-update-panel-if-visible
     source-buffer
     chat-ui--current-request-id
     chat-ui--request-tool-events))
  (when chat-ui--current-request-id
    (when phase
      (chat-request-diagnostics-record
       chat-ui--current-request-id
       phase
       :handle chat-ui--active-request-handle
       :process chat-ui--active-stream-process
       :summary summary))
    (chat-ui--unsubscribe-request-diagnostics)
    (chat-ui--clear-request-refresh-timer)
    (chat-ui--clear-request-hint-timer)
    (setq chat-ui--request-hint-shown nil))
  (setq chat-ui--request-tool-events nil)
  (setq chat-ui--last-approval-hint nil)
  (setq chat-ui--last-tracked-tool-paths nil)
  (setq chat-ui--live-response-content "")
  (setq chat-ui--live-trailers nil)
  (setq chat-ui--last-render nil)
  (setq chat-ui--current-request-id nil))

(defun chat-ui--maybe-announce-approval-shortcuts (tool-events)
  "Show one native approval hint for TOOL-EVENTS when needed."
  (when-let ((hint (chat-request-surface-approval-hint
                    tool-events
                    chat-ui--last-approval-hint)))
    (setq chat-ui--last-approval-hint (plist-get hint :signature))
    (let ((text (plist-get hint :text)))
      (message "%s" text)
      text)))

(defun chat-ui--maybe-show-request-hint (buffer)
  "Show one stalled request hint in BUFFER if needed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((message-text
                  (and chat-ui--current-request-id
                       (not chat-ui--request-hint-shown)
                       (chat-request-diagnostics-stall-message
                        chat-ui--current-request-id))))
        (setq chat-ui--request-hint-shown t)
        (chat-request-surface-update-panel-if-visible
         buffer
         chat-ui--current-request-id
         chat-ui--request-tool-events)
        (message "%s Use C-c C-p or M-x chat-show-current-request-status for details."
                 message-text)))))

(defun chat-ui--start-request-hint-timer (buffer)
  "Start the stalled request hint timer for BUFFER."
  (chat-ui--clear-request-hint-timer)
  (setq chat-ui--request-hint-shown nil)
  (setq chat-ui--request-hint-timer
        (run-at-time
         chat-request-diagnostics-stall-threshold
         nil
         #'chat-ui--maybe-show-request-hint
         buffer)))

(defun chat-ui--begin-request (session model transport)
  "Create a diagnostics request trace for SESSION, MODEL, and TRANSPORT."
  (let ((request-id
         (chat-request-diagnostics-create
          'chat
          model
          model
          (list :session-id (chat-session-id session)
                :session-name (chat-session-name session)))))
    (setq chat-ui--current-request-id request-id)
    (chat-request-diagnostics-record
     request-id
     'request-created
     :transport transport
     :summary (format "Preparing %s request" transport))
    (setq chat-ui--request-tool-events nil)
    (setq chat-ui--live-response-content "")
    (setq chat-ui--request-diagnostics-observer
          (chat-request-surface-buffer-observer
           (current-buffer)
           #'chat-ui--handle-request-diagnostics-update))
    (chat-request-diagnostics-subscribe
     request-id
     chat-ui--request-diagnostics-observer)
    (when chat-request-panel-auto-show
      (chat-request-panel-open (current-buffer) request-id nil))
    (chat-ui--start-request-hint-timer (current-buffer))
    (chat-ui--start-request-refresh-timer (current-buffer))
    request-id))

(defun chat-show-current-request-status ()
  "Show diagnostics for the current chat request."
  (interactive)
  (if chat-ui--current-request-id
      (chat-request-diagnostics-show chat-ui--current-request-id)
    (user-error "No active request diagnostics")))

(defun chat-ui-toggle-request-panel ()
  "Toggle the request panel for the current chat buffer."
  (interactive)
  (chat-request-panel-toggle
   (current-buffer)
   chat-ui--current-request-id
   chat-ui--request-tool-events))

(defcustom chat-ui-auto-path-completion t
  "Whether typing a path-like token in the input offers completion."
  :type 'boolean
  :group 'chat-ui)

(defvar chat-ui--auto-path-completion-active nil
  "Non-nil while auto path completion is running, to avoid recursion.")

(defun chat-ui--point-in-input-p (&optional position)
  "Return non-nil when POSITION is inside the editable input area."
  (let ((pos (or position (point))))
    (and (markerp chat-ui--input-overlay)
         (>= pos (marker-position chat-ui--input-overlay)))))

(defun chat-ui--input-token-bounds ()
  "Return bounds of the current token in the input area, or nil."
  (when (chat-ui--point-in-input-p)
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t\n\"'`()[]{}<>")
        (let ((start (point)))
          (when (<= (marker-position chat-ui--input-overlay) start)
            (cons start end)))))))

(defconst chat-ui-baseline-command "send"
  "The command plain input runs through when nothing has claimed it.

Typing a line and pressing RET has always meant `talk to the model, and
write it down'.  Naming that behaviour makes it a command like any other,
which is what lets auto return to it: a default you can only leave by
remembering a magic word is a trap, and that is exactly what the previous
design was.")

(defconst chat-ui--command-table
  '((:name "cancel"   :handler chat-ui--command-cancel :while-busy t)
    (:name "help"     :handler chat-ui--command-help   :while-busy t)
    (:name "model"    :handler chat-ui--command-model  :while-busy t)
    (:name "send"     :handler chat-ui--command-send   :default sticky)
    (:name "quick"    :handler chat-ui--command-quick  :default reset)
    (:name "cmd"      :handler chat-ui--command-shell  :default sticky)
    (:name "queue"    :handler chat-ui--command-queue  :default sticky)
    (:name "flush"    :handler chat-ui--command-flush  :default reset)
    (:name "drop"     :handler chat-ui--command-drop)
    (:name "cd"       :handler chat-ui--command-cd)
    (:name "pwd"      :handler chat-ui--command-pwd)
    (:name "new"      :handler chat-ui--command-new)
    (:name "list"     :handler chat-ui--command-list)
    (:name "save"     :handler chat-ui--command-save)
    (:name "clear"    :handler chat-ui--command-clear)
    (:name "auto"     :handler chat-ui--command-auto))
  "What each slash command is, declared rather than listed per property.

`:handler' takes the argument text, which may be empty.  A name absent
from this table, and not an alias of one, is left as ordinary message
text.

`:while-busy' means the command still runs while a response is in flight.

`:default' says what using the command does to the session's default
command, which is what plain input runs through:

  sticky  Becomes the default.  For work that comes in runs -- you rarely
          run one shell command, or queue one note.
  reset   Returns the default to `chat-ui-baseline-command'.
  nil     Leaves the default alone.  A command you reach for once says
          nothing about what the next line means.

`/quick' asks without recording, so it resets rather than sticking.  As a
sticky default it would quietly stop the conversation being written down,
and a footgun that only surfaces later is the worst kind.  Resetting
still gets a reader out of shell mode, which is the thing that actually
went wrong when only `/cmd' could hold plain input.

One entry per command, and every other spelling is an alias.  `/ask' and
`/question' were once entries of their own sharing a handler, which is
how they came to have three names between them for the aside and none at
all for the conversation.")

;; `/ask' reads as `ask the model', so it is the recorded conversation
;; rather than the aside beside it -- which is what a reader means by it
;; and, for a long time, was not what it did.  These are declared as
;; aliases so the table stays one entry per command; being registered as
;; a language means they are accepted whatever `chat-language' says.
(chat-i18n-register-aliases
 'en
 '(("ask" . "send")
   ("question" . "send")
   ("?" . "quick")
   ("!" . "cmd")))

(defun chat-ui--command-entry (name)
  "Return the table entry for slash command NAME, or nil.

NAME may be a localized alias, which resolves to the canonical entry so
that every property of a command is declared once."
  (let ((canonical (or (and (fboundp 'chat-i18n-resolve-alias)
                            (chat-i18n-resolve-alias name))
                       name)))
    (seq-find (lambda (entry) (equal (plist-get entry :name) canonical))
              chat-ui--command-table)))

(defun chat-ui--command-canonical-name (name)
  "Return the canonical name for slash command NAME, or nil."
  (plist-get (chat-ui--command-entry name) :name))

(defun chat-ui--command-handler (name)
  "Return the handler for slash command NAME, or nil."
  (plist-get (chat-ui--command-entry name) :handler))

(defun chat-ui--command-default-effect (name)
  "Return what using command NAME does to the default: `sticky', `reset' or nil."
  (plist-get (chat-ui--command-entry name) :default))

(defun chat-ui--command-repeatable-p (name)
  "Return non-nil when slash command NAME may become the default."
  (eq (chat-ui--command-default-effect name) 'sticky))

(defun chat-ui--repeatable-command-names ()
  "Return the names of every command that may become the default."
  (delete-dups
   (delq nil
         (mapcar (lambda (entry)
                   (and (eq (plist-get entry :default) 'sticky)
                        (plist-get entry :name)))
                 chat-ui--command-table))))

(defun chat-ui--command-token-bounds ()
  "Return the bounds of a slash command being typed, or nil.

A `/' opening the input area is a command; the same character anywhere
else is part of a path.  `/Users/liu' has a second slash and is a path
again, so the ambiguity resolves as soon as there is enough to resolve
it."
  (when-let* ((bounds (chat-ui--input-token-bounds))
              (input-start (marker-position chat-ui--input-overlay)))
    (and (= (car bounds) input-start)
         (let ((token (buffer-substring-no-properties (car bounds) (cdr bounds))))
           (and (string-prefix-p "/" token)
                (not (string-match-p "/" (substring token 1)))
                bounds)))))

(defun chat-ui--command-completion-at-point ()
  "Complete a slash command at the start of the input area.

Without this, `/' reaches the path completion below and answers a request
for the command list with the contents of the root directory."
  (when-let ((bounds (chat-ui--command-token-bounds)))
    (list (1+ (car bounds))
          (cdr bounds)
          (chat-ui--command-completion-table)
          :exclusive 'no
          :annotation-function #'chat-ui--command-annotation
          :company-kind (lambda (_candidate) 'keyword))))

(defun chat-ui--command-completion-table ()
  "Return the slash command names offered for completion.

Every language's aliases are accepted, but only the current language's
are offered: a list that showed all of them would be mostly noise to
whoever is reading it."
  (delete-dups
   (mapcar (lambda (entry)
             (let ((name (plist-get entry :name)))
               (or (and (fboundp 'chat-i18n-localized-name)
                        (chat-i18n-localized-name name))
                   name)))
           chat-ui--command-table)))

(defun chat-ui--command-annotation (name)
  "Return a short annotation for slash command NAME."
  (pcase (chat-ui--command-default-effect name)
    ('sticky (concat "  " (chat-i18n 'command-annotation-sticky
                                     "can hold plain input")))
    (_ (if (plist-get (chat-ui--command-entry name) :while-busy)
           (concat "  " (chat-i18n 'command-annotation-while-busy
                                   "works while busy"))
         ""))))

(defun chat-ui--path-token-p (token)
  "Return non-nil when TOKEN looks like a file path fragment."
  (and (stringp token)
       (not (string-empty-p token))
       ;; A slash command is not a path; see
       ;; `chat-ui--command-token-bounds'.
       (not (chat-ui--command-token-bounds))
       (or (string-prefix-p "/" token)
           (string-prefix-p "~/" token)
           (string-prefix-p "./" token)
           (string-prefix-p "../" token)
           (string-match-p "/" token))))

(defun chat-ui--path-completion-root ()
  "Return the base directory for relative input path completion.

A code session completes against the project it was rooted in, which is
not always the directory the buffer sits in."
  (file-name-as-directory
   (or (and chat--current-session
            (fboundp 'chat-code-session-p)
            (chat-code-session-p chat--current-session)
            (chat-code-session-project-root chat--current-session))
       default-directory)))

(defun chat-ui--path-completion-candidates (token base-directory)
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

(defun chat-ui--path-completion-at-point ()
  "Return a completion data form for path-like input tokens."
  (when-let* ((bounds (chat-ui--input-token-bounds))
              (token (buffer-substring-no-properties (car bounds) (cdr bounds)))
              ((chat-ui--path-token-p token)))
    (let ((base-directory (chat-ui--path-completion-root)))
      (list
       (car bounds)
       (cdr bounds)
       (lambda (string predicate action)
         (if (eq action 'metadata)
             '(metadata (category . file))
           (complete-with-action
            action
            (chat-ui--path-completion-candidates string base-directory)
            string
            predicate)))
       :exclusive 'no
       :company-kind (lambda (_candidate) 'file)))))

(defun chat-ui--maybe-complete-path-after-insert ()
  "Auto-trigger completion for path-like or command-like input."
  (when (and chat-ui-auto-path-completion
             (not chat-ui--auto-path-completion-active)
             (chat-ui--point-in-input-p)
             (not (minibufferp))
             (let ((char last-command-event))
               (or (memq char '(?/ ?. ?~))
                   (and (characterp char)
                        (or (and (>= char ?0) (<= char ?9))
                            (and (>= char ?A) (<= char ?Z))
                            (and (>= char ?a) (<= char ?z))
                            (memq char '(?_ ?-)))))))
    (when (or (chat-ui--command-completion-at-point)
              (chat-ui--path-completion-at-point))
      (let ((chat-ui--auto-path-completion-active t))
        (completion-at-point)))))

(defun chat-ui-insert-newline ()
  "Insert a newline in the input area without sending the message."
  (interactive)
  (unless (chat-ui--point-in-input-p)
    (goto-char (point-max)))
  (insert "\n"))

(defun chat-ui-beginning-of-input ()
  "Move to the start of what you typed, not to the start of the line.

The prompt is buffer text, so plain `move-beginning-of-line' lands before
the `> ' -- a position where typing inserts outside the input area and
`C-k' takes the prompt with it.  On a continuation line inside the input,
the line start is what is wanted."
  (interactive)
  (let ((input-start (and chat-ui--input-overlay
                          (marker-position chat-ui--input-overlay))))
    (if (and input-start
             (>= (point) input-start)
             (<= (line-beginning-position) input-start))
        (goto-char input-start)
      (move-beginning-of-line 1))))

(defun chat-ui--capability-lines (session)
  "Return the header lines describing what SESSION carries, or nil.

A plain conversation has nothing to say here and gets nothing.  What a
code session shows -- the project it is rooted in, the file in focus, the
files in context -- is exactly what changes its requests, so the header
doubles as the answer to why a reply mentioned a file nobody named."
  (when (and session
             (fboundp 'chat-code-session-p)
             (chat-code-session-p session))
    (let ((project (chat-code-session-project-root session))
          (focus (chat-code-session-focus-file session))
          (strategy (chat-code-session-context-strategy session))
          (files (chat-code-session-context-files session)))
      (concat
       (format "Code: %s"
               (if project (abbreviate-file-name project) "no project root"))
       (when strategy (format " | context %s" strategy))
       "\n"
       (when focus
         (format "Focus: %s\n" (abbreviate-file-name focus)))
       (when files
         (format "Context: %d file(s): %s\n"
                 (length files)
                 (mapconcat #'file-name-nondirectory files ", ")))))))

(defun chat-ui-setup-buffer (session)
  "Setup chat buffer for SESSION."
  (chat-ui--clear-request-hint-timer)
  (chat-ui--clear-request-refresh-timer)
  (chat-ui--unsubscribe-request-diagnostics)
  (setq chat-ui--current-request-id nil)
  (setq chat-ui--request-hint-shown nil)
  (setq chat-ui--request-tool-events nil)
  (setq chat-ui--last-approval-hint nil)
  (setq chat-ui--last-tracked-tool-paths nil)
  (setq chat-ui--live-response-content "")
  (setq chat-ui--live-trailers nil)
  (setq chat-ui--last-render nil)
  (setq chat-ui--opened-fold-groups nil)
  (chat-request-panel-close (current-buffer))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "═══ %s ═══\n" (chat-session-name session))
                       'face 'header-line))
    (insert (propertize (format "%s\n" (chat-ui--status-line session))
                       'face 'shadow))
    (when-let ((capability (chat-ui--capability-lines session)))
      (insert (propertize capability 'face 'shadow)))
    (insert "\n")
    (setq chat-ui--conversation-start (copy-marker (point) nil))
    (chat-ui--render-messages (chat-session-messages session))
    (setq chat-ui--live-start (copy-marker (point) nil))
    (setq chat-ui--messages-end (point-marker))
    (chat-ui--setup-input-area)))

(defun chat-ui--insert-message (msg)
  "Insert message MSG into the buffer as transcript parts.

Goes through the transcript so a message drawn as it arrives looks the
same as the same message drawn from the record after a reload."
  (chat-ui--render-parts (chat-transcript-message-parts msg)))

;; ------------------------------------------------------------------
;; Transcript rendering
;; ------------------------------------------------------------------
;;
;; A run is not one answer.  It reasons, calls a tool, reads the result,
;; reasons again, and only then replies.  This display used to draw the
;; whole run into one mutable region, so step N's text was deleted to
;; make room for step N+1 and the reader was left with a question at the
;; top, an answer at the bottom, and nothing in between.
;;
;; Every step is already recorded: the agent loop emits
;; `message-appended' for each one and it is persisted immediately.  So
;; the display does not need to keep anything -- it draws the record.
;; `chat-transcript-plan' says what to draw and what to fold; this code
;; only puts it on screen.
;;
;; Two regions, because they change at different rates.  Committed
;; history is redrawn when the record changes: a message appended, a
;; message sent, a fold toggled.  The live tail is redrawn on every
;; stream chunk, and it is short, so a long conversation does not get
;; slower to stream into.

(defcustom chat-ui-detail-indent "  "
  "Prefix marking a transcript part as detail rather than as the answer."
  :type 'string
  :group 'chat-ui)

(defcustom chat-ui-detail-inline-max 64
  "Longest detail text still shown on the same line as its label."
  :type 'integer
  :group 'chat-ui)

(defun chat-ui--toggle-fold-at-mouse (event)
  "Toggle the fold group EVENT was delivered on."
  (interactive "e")
  (mouse-set-point event)
  (chat-ui-toggle-fold))

(defvar chat-ui-fold-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'chat-ui-toggle-fold)
    (define-key map (kbd "TAB") #'chat-ui-toggle-fold)
    (define-key map [mouse-1] #'chat-ui--toggle-fold-at-mouse)
    map)
  "Keymap active on a fold row.

Carried as a text property, so `RET' toggles a fold where a fold is and
still sends the message everywhere else.")

(defun chat-ui--insert-fold-row (instruction)
  "Insert the summary row standing in for what INSTRUCTION hides."
  (let ((group (plist-get instruction :group)))
    (insert (propertize (concat chat-ui-detail-indent
                                (chat-transcript-fold-row-text instruction)
                                "\n")
                        'face 'chat-transcript-fold-row
                        'chat-ui-fold-group group
                        'keymap chat-ui-fold-row-map
                        'mouse-face 'highlight
                        'help-echo (if (plist-get instruction :open)
                                       (chat-i18n 'fold-echo-close
                                                  "RET or mouse-1 to fold")
                                     (chat-i18n 'fold-echo-open
                                                "RET or mouse-1 to expand"))))))

(defun chat-ui--insert-detail (label text face)
  "Insert TEXT as a detail block titled LABEL, drawn in FACE."
  (let* ((body (string-trim-right (or text "")))
         (title (concat chat-ui-detail-indent
                        (or label (chat-i18n 'detail-label "Detail")))))
    (if (string-empty-p body)
        (insert (propertize (concat title "\n") 'face face))
      (if (and (not (string-match-p "\n" body))
               (<= (length body) chat-ui-detail-inline-max))
          (insert (propertize (format "%s: %s\n" title body) 'face face))
        (insert (propertize (concat title "\n") 'face face))
        (dolist (line (split-string body "\n"))
          (insert (propertize (concat chat-ui-detail-indent
                                      chat-ui-detail-indent line "\n")
                              'face face)))))))

(defun chat-ui--open-block ()
  "Ensure a blank line separates what follows from the detail above it.

Detail lines end in a single newline so a run of them reads as one block.
A question or an answer starting immediately after would be pulled into
that block."
  (unless (or (bolp) (bobp))
    (insert "\n"))
  (unless (or (bobp)
              (and (> (point) (1+ (point-min)))
                   (eq (char-before (1- (point))) ?\n)))
    (insert "\n")))

(defconst chat-ui--pending-query-property 'chat-ui-pending-query
  "Property marking the note that says a one-off question is in flight.

Marked rather than found by searching for its own text: the text is
translated, and a search for the English would quietly stop finding it in
any other language, leaving the note on screen under the answer.")

(defconst chat-ui--role-faces
  '((user . font-lock-keyword-face)
    (assistant . font-lock-function-name-face)
    (assistant-quick . font-lock-function-name-face)
    (system . font-lock-comment-face))
  "The face each role label is drawn in.")

(defun chat-ui--role-label (role)
  "Return the text naming ROLE in the reader's language."
  (pcase role
    ('user (chat-i18n 'role-you "You"))
    ('assistant (chat-i18n 'role-assistant "Assistant"))
    ('assistant-quick (chat-i18n 'role-assistant-quick "Assistant (quick)"))
    ('system (chat-i18n 'role-system "System"))))

(defun chat-ui--insert-role-label (role)
  "Insert the label for ROLE and the newline that follows it."
  (insert (propertize (concat (chat-ui--role-label role) ":\n")
                      'face (alist-get role chat-ui--role-faces))))

(defun chat-ui--insert-part (part)
  "Insert transcript PART at point.

A question and an answer read as themselves.  Everything else is the
run's account of its own work, so it is indented, labeled and drawn in
the face its channel calls for -- present, but not competing with the
answer for the reader's attention."
  (let ((text (or (plist-get part :text) "")))
    (pcase (plist-get part :category)
      ('user
       (chat-ui--open-block)
       (chat-ui--insert-role-label 'user)
       (insert text)
       (insert "\n\n"))
      ('ai-final
       (chat-ui--open-block)
       (chat-ui--insert-role-label 'assistant)
       (chat-ui--insert-formatted-response text)
       (insert "\n\n"))
      (_
       (chat-ui--insert-detail (chat-transcript-part-label part)
                               text
                               (chat-transcript-part-face part))))))

(defun chat-ui--prose-part-p (part)
  "Return non-nil when PART is prose rather than a labeled event.

A tool call is worth a row even when its arguments are empty; prose with
nothing left in it is not."
  (memq (plist-get part :work) '(nil message)))

(defun chat-ui--display-parts (parts)
  "Return PARTS with their text prepared for display.

A model that calls a tool puts the call in the content field as well, so
the step's prose arrives with a JSON blob embedded in it.  Rendered as
written it reads as the model having answered in JSON.  Stripping it can
empty the prose out entirely, and an empty part must not reach the plan:
it would be counted in a fold row standing for nothing."
  (delq nil
        (mapcar
         (lambda (part)
           (let ((text (if (chat-ui--prose-part-p part)
                           (string-trim
                            (chat-tool-caller-extract-content
                             (or (plist-get part :text) "")))
                         (plist-get part :text))))
             (unless (and (chat-ui--prose-part-p part)
                          (string-empty-p (or text "")))
               (plist-put (copy-sequence part) :text text))))
         parts)))

(defun chat-ui--render-parts (parts)
  "Insert PARTS at point, folding by channel."
  (dolist (instruction (chat-transcript-plan (chat-ui--display-parts parts)
                                             chat-ui--opened-fold-groups))
    (pcase (plist-get instruction :type)
      ('fold-row (chat-ui--insert-fold-row instruction))
      ('part (chat-ui--insert-part (plist-get instruction :part))))))

(defun chat-ui--render-messages (messages)
  "Insert MESSAGES at point as a folded transcript."
  (chat-ui--render-parts (chat-transcript-parts messages)))

(defun chat-ui--insert-live-trailers ()
  "Insert the notes that belong to the turn rather than to any one part."
  (when-let ((line (chat-ui--live-narrative-line
                    (plist-get chat-ui--live-trailers :detail))))
    (insert (propertize (concat chat-ui-detail-indent line "\n")
                        'face 'chat-transcript-fold-row)))
  (when-let ((summary (plist-get chat-ui--live-trailers :tool-summary)))
    (insert (propertize (concat chat-ui-detail-indent
                                (chat-i18n 'tools-used "Tools used: %s" summary)
                                "\n")
                        'face 'chat-transcript-system)))
  (when (plist-get chat-ui--live-trailers :limit-reached)
    (insert (propertize
             (concat chat-ui-detail-indent
                     (chat-i18n 'tool-loop-stopped
                                "Tool loop stopped after reaching the safety limit.")
                     "\n")
             'face 'chat-transcript-system))))

(defun chat-ui--render-live-region ()
  "Redraw the in-flight tail of the current turn.

Called for every stream chunk, so it touches only the tail; the committed
history above `chat-ui--live-start' is left alone.

Within the tail it appends rather than rewrites when it can, because a
reply arrives in many small chunks and reinserting all of it each time
makes a long answer quadratic to display.  The append has to resume at a
closed fence: cutting mid-block leaves a half-arrived code block drawn as
prose, and the fence that would have closed it is never reconsidered."
  (when (and chat-ui--live-start chat-ui--messages-end)
    (let* ((inhibit-read-only t)
           (content (string-trim-right (or chat-ui--live-response-content "")))
           (last chat-ui--last-render)
           (previous (and last (plist-get last :content)))
           (body (and last (plist-get last :body-start)))
           (append-p (and previous body
                          (not (string-empty-p content))
                          (= (plist-get last :live-start)
                             (marker-position chat-ui--live-start))
                          (string-prefix-p previous content)))
           (cut (and append-p (chat-ui--fence-safe-prefix-length previous))))
      (save-excursion
        (if append-p
            (progn
              (goto-char (+ body cut))
              (delete-region (point) chat-ui--messages-end)
              (chat-ui--insert-formatted-response (substring content cut))
              (insert "\n\n"))
          (goto-char chat-ui--live-start)
          (delete-region chat-ui--live-start chat-ui--messages-end)
          (setq body nil)
          (unless (string-empty-p content)
            (chat-ui--insert-role-label 'assistant)
            (setq body (point))
            (chat-ui--insert-formatted-response content)
            (insert "\n\n")))
        (chat-ui--insert-live-trailers)
        (set-marker chat-ui--messages-end (point)))
      (setq chat-ui--last-render
            (and body
                 (list :content content
                       :body-start body
                       :live-start (marker-position chat-ui--live-start)))))))

(defun chat-ui--redraw-conversation ()
  "Redraw the whole conversation from the session record.

The record is the only source: nothing the display has drawn before is
consulted, so a message appended, a fold toggled and a session reopened
all produce the same screen."
  (when (and chat--current-session
             chat-ui--conversation-start
             chat-ui--messages-end)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char chat-ui--conversation-start)
        (delete-region chat-ui--conversation-start chat-ui--messages-end)
        (chat-ui--render-messages (chat-session-messages chat--current-session))
        (setq chat-ui--live-start (copy-marker (point) nil))
        (set-marker chat-ui--messages-end (point))))
    (setq chat-ui--last-render nil)
    (chat-ui--render-live-region)))

(defun chat-ui-toggle-fold ()
  "Expand or fold the group at point."
  (interactive)
  (let ((group (or (get-text-property (point) 'chat-ui-fold-group)
                   (and (> (point) (point-min))
                        (get-text-property (1- (point)) 'chat-ui-fold-group)))))
    (unless group
      (user-error "No folded section here"))
    (setq chat-ui--opened-fold-groups
          (if (member group chat-ui--opened-fold-groups)
              (delete group chat-ui--opened-fold-groups)
            (cons group chat-ui--opened-fold-groups)))
    (let ((line (line-number-at-pos)))
      (chat-ui--redraw-conversation)
      (goto-char (point-min))
      (forward-line (1- line)))))

(defun chat-ui-toggle-all-folds ()
  "Expand every folded group, or fold them all when all are open."
  (interactive)
  (let ((groups
         (delq nil
               (mapcar (lambda (instruction)
                         (and (eq (plist-get instruction :type) 'fold-row)
                              (plist-get instruction :group)))
                       ;; Same filtering the renderer applies, or the
                       ;; keys here would not be the keys on screen.
                       (chat-transcript-plan
                        (chat-ui--display-parts
                         (chat-transcript-parts
                          (chat-session-messages chat--current-session)))
                        nil)))))
    (setq chat-ui--opened-fold-groups
          (if (cl-every (lambda (group)
                          (member group chat-ui--opened-fold-groups))
                        groups)
              nil
            groups))
    (chat-ui--redraw-conversation)
    (message "%s" (if chat-ui--opened-fold-groups
                      (chat-i18n 'detail-shown "Showing all detail")
                    (chat-i18n 'detail-folded "Detail folded")))))

(defface chat-ui-claimed-prompt
  '((t :inherit warning))
  "Face for the input prompt while a command other than the baseline holds it."
  :group 'chat-ui)

(defun chat-ui--input-prompt ()
  "Return the text that opens the input area.

Names the command plain input will run through when that is not the
baseline.  The status line says so too, but it is at the top of a buffer
that scrolls and the cursor is down here: a shell that looks like a chat
box is how a question ends up being run as a command."
  (if (chat-ui-default-command-claimed-p)
      (propertize (format "%s> " (chat-ui--display-command-name
                                 (chat-ui-default-command)))
                  'face 'chat-ui-claimed-prompt)
    "> "))

(defun chat-ui--render-input-prompt ()
  "Rewrite the input prompt in place, keeping the input marker after it."
  (when (and (markerp chat-ui--input-overlay)
             (marker-position chat-ui--input-overlay))
    (save-excursion
      (let* ((inhibit-read-only t)
             (end (marker-position chat-ui--input-overlay))
             (start (progn (goto-char end) (line-beginning-position))))
        (delete-region start end)
        (goto-char start)
        (insert (chat-ui--input-prompt))
        (set-marker chat-ui--input-overlay (point))))))

(defun chat-ui--setup-input-area ()
  "Setup the input area at bottom of buffer."
  (goto-char (point-max))
  (insert (propertize "───\n" 'face 'shadow))
  (insert (chat-ui--input-prompt))
  (setq chat-ui--input-overlay (point-marker)))

;; ------------------------------------------------------------------
;; Message Sending
;; ------------------------------------------------------------------

(defun chat-ui-send-message ()
  "Act on the input area, either as a command or as a message."
  (interactive)
  (when chat--current-session
    (let* ((input-start (marker-position chat-ui--input-overlay))
           (input-end (point-max))
           (content (string-trim (buffer-substring-no-properties input-start input-end)))
           (command (chat-command-parse content))
           (control (chat-ui--control-command command)))
      (cond
       ((eq (plist-get command :kind) 'empty)
        (message "%s" (chat-i18n 'empty-message "Cannot send empty message")))
       (control
        (chat-ui--clear-input input-start input-end)
        (funcall control (plist-get command :arg)))
       ((chat-agent-active-p chat-ui--active-agent-run)
        (chat-ui--clear-input input-start input-end)
        (chat-ui--steer-active-agent (chat-ui--command-message-text command)))
       ((chat-ui--response-active-p)
        (message "%s" (chat-i18n 'request-in-progress
                          "A response is already in progress. Cancel it before sending another message.")))
       (t
        (chat-ui--clear-input input-start input-end)
        (chat-ui--dispatch-command command))))))

(defun chat-ui--clear-input (input-start input-end)
  "Remove the text between INPUT-START and INPUT-END from the input area."
  (delete-region input-start input-end)
  (goto-char input-start))

(defun chat-ui--control-command (command)
  "Return the handler for COMMAND when it may run during a response."
  (and (eq (plist-get command :kind) 'slash)
       (plist-get (chat-ui--command-entry (plist-get command :name)) :while-busy)
       (chat-ui--command-handler (plist-get command :name))))

(defun chat-ui--command-message-text (command)
  "Return the text COMMAND should contribute as an ordinary message."
  (if (memq (plist-get command :kind) '(literal note))
      (plist-get command :arg)
    (plist-get command :text)))

;; ------------------------------------------------------------------
;; The default command
;; ------------------------------------------------------------------
;;
;; Shell work comes in runs.  Having to prefix every line of a run with
;; `!' is the kind of friction that makes people stop using the surface
;; and open a terminal instead.  So a repeatable command can become the
;; session's default: plain input goes to it until `/auto off'.
;;
;; It is a mode, and an invisible mode that eats your prose is worse than
;; typing the prefix.  Three things keep it visible: the header says what
;; is on, a message says so when it turns on, and the literal escape is
;; always available for one line that must not be interpreted.

(defun chat-ui-default-command (&optional session)
  "Return the command plain input runs through in SESSION.

Always a name: `chat-ui-baseline-command' when nothing has claimed plain
input.  SESSION defaults to the current one.  It is taken as an argument
because the status line is drawn for a session that may not be the
buffer's yet, and a header that disagrees with the behaviour is worse
than no header.

Kept on the session so it survives a reopen: a mode you cannot see is
bad, and a mode that silently expires is worse."
  (or (when-let ((session (or session chat--current-session)))
        (chat-session-metadata-get session :chat-ui-default-command))
      chat-ui-baseline-command))

(defun chat-ui-default-command-claimed-p (&optional session)
  "Return non-nil when something other than the baseline holds plain input."
  (not (equal (chat-ui-default-command session) chat-ui-baseline-command)))

(defun chat-ui--set-default-command (name)
  "Make NAME the command plain input runs through.

The baseline is stored as nil so there is one representation of `nothing
has claimed plain input' rather than two that have to be kept in step."
  (chat-ui--session-metadata-set
   :chat-ui-default-command
   (and name (not (equal name chat-ui-baseline-command)) name)))

(defun chat-ui--render-default-command ()
  "Redraw both places that say what plain input will do."
  (chat-ui--render-status-line)
  (chat-ui--render-input-prompt))

(defun chat-ui--command-name-of (command)
  "Return the canonical command name COMMAND invokes, or nil.

`!ls' and `/cmd ls' are the same command reached two ways, so the bare
prefix affects the default exactly as the slash name does."
  (pcase (plist-get command :kind)
    ('slash (chat-ui--command-canonical-name (plist-get command :name)))
    ((or 'shell 'shell-repeat) "cmd")
    ('query "quick")
    (_ nil)))

(defun chat-ui--note-command-default (command)
  "Apply COMMAND's effect on which command holds plain input.

A sticky command claims plain input; one that resets hands it back to the
baseline.  Both are announced, because the whole failure mode here is a
mode the reader cannot see."
  (when-let* ((_ chat--current-session)
              (name (chat-ui--command-name-of command))
              (effect (chat-ui--command-default-effect name)))
    (let ((wanted (if (eq effect 'reset) chat-ui-baseline-command name)))
      (unless (equal (chat-ui-default-command) wanted)
        (chat-ui--set-default-command wanted)
        (chat-ui--render-default-command)
        (message "%s"
                 (if (equal wanted chat-ui-baseline-command)
                     (chat-i18n 'auto-released
                                "Plain input goes to the model again.")
                   (chat-i18n 'auto-claimed
                              "Plain input now runs through /%s. /auto off to stop."
                              (chat-ui--display-command-name wanted))))))))

(defun chat-ui--display-command-name (name)
  "Return NAME as the reader's language calls it."
  (or (and (fboundp 'chat-i18n-localized-name)
           (chat-i18n-localized-name name))
      name))

(defun chat-ui--command-auto (arg)
  "Report, set or clear the default command according to ARG."
  (let* ((request (downcase (string-trim (or arg ""))))
         (canonical (chat-ui--command-canonical-name request)))
    (cond
     ((string-empty-p request)
      (chat-ui--insert-system-message
       (if (chat-ui-default-command-claimed-p)
           (chat-i18n 'auto-state-on
                      "Auto: plain input runs through /%s. /auto off to stop."
                      (chat-ui--display-command-name (chat-ui-default-command)))
         (chat-i18n 'auto-state-off
                    "Auto: off -- plain input goes to the model. Repeatable: %s"
                    (chat-ui--repeatable-command-list)))))
     ((or (member request '("off" "none" "stop"))
          (equal canonical chat-ui-baseline-command))
      (chat-ui--set-default-command nil)
      (chat-ui--render-default-command)
      (chat-ui--insert-system-message
       (chat-i18n 'auto-turned-off
                  "Auto: off -- plain input goes to the model.")))
     ((and canonical (chat-ui--command-repeatable-p canonical))
      (chat-ui--set-default-command canonical)
      (chat-ui--render-default-command)
      (chat-ui--insert-system-message
       (chat-i18n 'auto-state-on
                  "Auto: plain input runs through /%s. /auto off to stop."
                  (chat-ui--display-command-name canonical))))
     (t
      (chat-ui--insert-system-message
       (chat-i18n 'auto-not-repeatable
                  "/%s cannot be a default command. Repeatable: %s"
                  request
                  (chat-ui--repeatable-command-list)))))))

(defun chat-ui--repeatable-command-list ()
  "Return the repeatable command names as slash-prefixed display text."
  (mapconcat (lambda (name)
               (concat "/" (chat-ui--display-command-name name)))
             (chat-ui--repeatable-command-names) " "))

(defun chat-ui--dispatch-command (command)
  "Run COMMAND, which was parsed from the input area."
  (let ((arg (plist-get command :arg)))
    (pcase (plist-get command :kind)
      ('shell
       (chat-ui--command-shell arg)
       (chat-ui--note-command-default command))
      ('shell-repeat
       (chat-ui--repeat-shell-command)
       (chat-ui--note-command-default command))
      ('query
       (chat-ui--command-quick arg)
       (chat-ui--note-command-default command))
      ('slash
       (let ((handler (chat-ui--command-handler (plist-get command :name))))
         (if handler
             (progn
               (funcall handler arg)
               (chat-ui--note-command-default command))
           ;; An unknown name is not an error: the model may still make
           ;; sense of it, and refusing would break slash-prefixed prose.
           (chat-ui--send-user-message (plist-get command :text)))))
      ('literal (chat-ui--send-user-message arg))
      ('note (chat-ui--dispatch-plain-input (plist-get command :text)))
      (_ (chat-ui--send-user-message (plist-get command :text))))))

(defun chat-ui--dispatch-plain-input (text)
  "Run TEXT through the command that currently holds plain input."
  (let ((handler (chat-ui--command-handler (chat-ui-default-command))))
    (if handler
        (funcall handler text)
      (chat-ui--send-user-message text))))

(defun chat-ui--send-user-message (content)
  "Record CONTENT as a user message and ask the model to respond."
  (if (string-empty-p content)
      (message "%s" (chat-i18n 'empty-message "Cannot send empty message"))
    (if (chat-tool-forge-ai--tool-request-p content)
        (chat-ui--handle-tool-creation content)
      (let ((user-msg (make-chat-message
                       :id (chat-session-new-message-id)
                       :role :user
                       :content content
                       :timestamp (current-time))))
        (chat-session-add-message chat--current-session user-msg)
        ;; Drawn from the record rather than inserted directly, so the
        ;; live boundary lands after this message instead of before it.
        (chat-ui--redraw-conversation)
        (chat-ui--get-response)))))

(defun chat-ui--steer-active-agent (content)
  "Queue CONTENT for the response that is already running."
  (let ((user-msg (make-chat-message
                   :id (chat-session-new-message-id)
                   :role :user
                   :content content
                   :timestamp (current-time))))
    (chat-session-add-message chat--current-session user-msg)
    (chat-ui--redraw-conversation)
    (chat-agent-steer chat-ui--active-agent-run user-msg)
    (message "%s" (chat-i18n 'message-queued
                          "Message queued for the active response."))))

;;; The queue: several notes, one turn
;;
;; Writing a request in one go is not how a request arrives.  It arrives
;; as `also check X', `and the file is at Y' -- each of which, sent on its
;; own, spends a whole turn on a fragment and gets an answer to the
;; fragment.  The queue lets those land as notes and go out together.
;;
;; They are joined into a single user message rather than sent as several,
;; because consecutive messages in the same role are not something every
;; provider accepts, and a batching feature that works on some models is
;; worse than one that reads slightly less faithfully on all of them.

(defun chat-ui--queue-entries (&optional session)
  "Return the notes queued in SESSION, oldest first."
  (when-let ((session (or session chat--current-session)))
    (let ((stored (chat-session-metadata-get session :chat-ui-queued-messages)))
      ;; A round trip through JSON brings a list of strings back as a
      ;; vector, and a queue that empties itself on reopen would be a
      ;; quiet way to lose what someone typed.
      (append (if (vectorp stored) (append stored nil) stored) nil))))

(defun chat-ui--queue-length (&optional session)
  "Return how many notes are queued in SESSION."
  (length (chat-ui--queue-entries session)))

(defun chat-ui--set-queue (entries)
  "Make ENTRIES the queued notes of the current session."
  (chat-ui--session-metadata-set :chat-ui-queued-messages entries)
  (chat-ui--render-status-line))

(defun chat-ui--queue-joined-text (entries)
  "Return ENTRIES as the text of one message.

Numbered when there are several, so the model can see it was given
distinct requests rather than one rambling one; left alone when there is
only one, because numbering a list of one is noise."
  (if (cdr entries)
      (string-join
       (seq-map-indexed (lambda (entry index)
                          (format "%d. %s" (1+ index) entry))
                        entries)
       "\n\n")
    (car entries)))

(defun chat-ui--command-queue (arg)
  "Queue ARG to go out later, or list what is queued when ARG is empty."
  (let ((note (string-trim (or arg ""))))
    (if (string-empty-p note)
        (chat-ui--report-queue)
      (let ((entries (append (chat-ui--queue-entries) (list note))))
        (chat-ui--set-queue entries)
        (chat-ui--insert-system-message
         (chat-i18n 'queue-added
                    "Queued %d: %s  (/flush to send, /queue to review)"
                    (length entries) note))))))

(defun chat-ui--report-queue ()
  "Say what is queued, and how to send or discard it."
  (let ((entries (chat-ui--queue-entries)))
    (chat-ui--insert-system-message
     (if (null entries)
         (chat-i18n 'queue-empty
                    "Nothing queued. /queue <note> collects notes to send together.")
       (concat (chat-i18n 'queue-heading "Queued (%d), /flush to send:"
                          (length entries))
               "\n"
               (string-join
                (seq-map-indexed (lambda (entry index)
                                   (format "  %d. %s" (1+ index) entry))
                                 entries)
                "\n"))))))

(defun chat-ui--command-flush (arg)
  "Send the queue as one turn, with ARG appended when it is given."
  (let* ((extra (string-trim (or arg "")))
         (entries (append (chat-ui--queue-entries)
                          (and (not (string-empty-p extra)) (list extra)))))
    (if (null entries)
        (chat-ui--insert-system-message
         (chat-i18n 'queue-empty
                    "Nothing queued. /queue <note> collects notes to send together."))
      ;; Cleared before sending: a failed request that left the notes
      ;; queued would send them twice on the next flush.
      (chat-ui--set-queue nil)
      (chat-ui--send-user-message (chat-ui--queue-joined-text entries)))))

(defun chat-ui--command-drop (arg)
  "Drop the last queued note, or all of them when ARG says `all'."
  (let ((entries (chat-ui--queue-entries))
        (request (downcase (string-trim (or arg "")))))
    (cond
     ((null entries)
      (chat-ui--insert-system-message
       (chat-i18n 'queue-empty
                  "Nothing queued. /queue <note> collects notes to send together.")))
     ((member request '("all" "*"))
      (chat-ui--set-queue nil)
      (chat-ui--insert-system-message
       (chat-i18n 'queue-dropped-all "Dropped all %d queued notes."
                  (length entries))))
     (t
      (chat-ui--set-queue (butlast entries))
      (chat-ui--insert-system-message
       (chat-i18n 'queue-dropped "Dropped: %s" (car (last entries))))))))

(defun chat-ui--command-cancel (_arg)
  "Cancel the response that is in flight."
  (chat-ui-cancel-response)
  (message "%s" (chat-i18n 'request-cancelled "Request cancelled.")))

(defun chat-ui--command-model (arg)
  "Point this session at the provider named ARG, prompting when empty."
  (if (string-empty-p arg)
      (call-interactively #'chat-set-model)
    (chat-set-model (intern arg))))

(defun chat-ui--command-shell (arg)
  "Run ARG as a shell command."
  (if (string-empty-p arg)
      (message "%s" (chat-i18n 'shell-usage "Usage: !<command>"))
    (chat-ui--handle-shell-command arg)))

(defun chat-ui--command-send (arg)
  "Send ARG to the model as a recorded turn, or flush the queue when empty.

This is the name of what plain input has always done: recorded in the
session, answered by a run that may reason and use tools over several
steps.  It needed a name so that auto has somewhere to return to, and so
that the main way of using the surface is not the only thing on it with
no name."
  (if (string-empty-p arg)
      (if (chat-ui--queue-entries)
          (chat-ui--command-flush "")
        (message "%s" (chat-i18n 'send-usage
                                 "Usage: /send <message>, or /send alone to send the queue.")))
    (chat-ui--send-user-message arg)))

(defun chat-ui--command-quick (arg)
  "Ask the model ARG once, without recording it in the session."
  (chat-ui--handle-direct-query arg))

(defun chat-ui--command-cd (arg)
  "Point this session at directory ARG, prompting when empty."
  (chat-ui--change-directory
   (if (string-empty-p arg)
       (read-directory-name "Working directory: " default-directory nil t)
     arg)))

(defun chat-ui--command-pwd (_arg)
  "Report the working directory of this session."
  (chat-ui--insert-system-message (format "📁 %s" default-directory)))

(defun chat-ui--command-new (_arg)
  "Start a new session."
  (call-interactively #'chat-new-session))

(defun chat-ui--command-list (_arg)
  "Show the saved sessions."
  (call-interactively #'chat-list-sessions))

(defun chat-ui--command-save (_arg)
  "Write this session to disk now."
  (if (null chat--current-session)
      (message "%s" (chat-i18n 'no-session "No session here."))
    (chat-session-save chat--current-session)
    (chat-ui--insert-system-message
     (chat-i18n 'session-saved "Saved: %s"
                (chat-session-name chat--current-session)))))

(defun chat-ui--command-clear (_arg)
  "Drop the conversation from this session, keeping the session itself.

Asks first: the messages are the session, and there is no undo for
throwing them away."
  (cond
   ((null chat--current-session)
    (message "%s" (chat-i18n 'no-session "No session here.")))
   ((not (yes-or-no-p (chat-i18n 'clear-confirm
                                 "Discard this conversation? ")))
    (message "%s" (chat-i18n 'clear-cancelled "Kept the conversation.")))
   (t
    (chat-session-clear-messages chat--current-session)
    (when chat-auto-save-sessions
      (chat-session-save chat--current-session))
    (chat-ui-setup-buffer chat--current-session)
    (chat-ui--insert-system-message
     (chat-i18n 'conversation-cleared "Conversation cleared.")))))

(defun chat-ui--command-help (arg)
  "Show help, filtered to lines matching ARG when it is given.

`/help' is the first thing someone types when they cannot see what to do
next, so it has to work from the input area rather than only from a key
binding nobody has found yet."
  (let ((topic (string-trim (or arg ""))))
    (if (string-empty-p topic)
        (chat-ui--show-help)
      (chat-ui--show-help-matching topic))))

(defun chat-ui--help-text ()
  "Return the help text to show, localized when a catalog has it."
  (if (fboundp 'chat-help-text)
      (chat-help-text)
    chat-commands-help))

(defun chat-ui--show-help ()
  "Display the full help text."
  (if (fboundp 'chat-show-help)
      (chat-show-help)
    (chat-ui--insert-system-message (chat-ui--help-text))))

(defun chat-ui--show-help-matching (topic)
  "Show the help lines that mention TOPIC, or say that none do."
  (let ((matches
         (seq-filter (lambda (line)
                       (string-match-p (regexp-quote (downcase topic))
                                       (downcase line)))
                     (split-string (chat-ui--help-text) "\n"))))
    (chat-ui--insert-system-message
     (if matches
         (concat (chat-i18n 'help-topic-heading "Help for %s:" topic)
                 "\n"
                 (string-join matches "\n"))
       (chat-i18n 'help-topic-missing
                  "Nothing in the help mentions %s. /help for all of it."
                  topic)))))

(defun chat-ui--followup-target-note ()
  "Return a system note about the most recent file target."
  (when-let ((target (chat-ui--session-metadata-get :chat-ui-preferred-target-path)))
    (format
     "Recent file target for follow-up requests: %s\nUse it only when the user refers implicitly to the same file or asks to continue the last file task."
     target)))

(defun chat-ui--code-capability-prompt (session)
  "Return the coding prompt and context for SESSION, or nil.

Code capability is a property of the session, so this is the whole of
what a coding session adds to a request: its rules, the project context
it was pointed at, and whatever the language server can say about the
file in focus.  Nothing else about the request differs, which is why
there is no second request path to hold it."
  (when (and session
             (fboundp 'chat-code-session-p)
             (chat-code-session-p session))
    (let* ((prompt (and (fboundp 'chat-code--compose-system-prompt)
                        (chat-code--compose-system-prompt)))
           (context (and (fboundp 'chat-context-code-build)
                         (ignore-errors
                           (chat-context-code-to-string
                            (chat-context-code-build session)))))
           (lsp (and (fboundp 'chat-code-lsp-available-p)
                     (chat-code-lsp-available-p)
                     (when-let ((ctx (chat-code-lsp-get-context)))
                       (chat-code-lsp-format-context ctx)))))
      (string-join (delq nil (list prompt
                                   (and context
                                        (not (string-empty-p context))
                                        context)
                                   lsp))
                   "\n\n"))))

(defun chat-ui--prepare-messages-with-tools (messages)
  "Prepare message list with tool calling system prompt."
  (if (not chat-tool-caller-enabled)
      (progn
        (chat-log "[TOOLS] Tool calling disabled, using original messages")
        messages)
    (let* ((code-prompt (chat-ui--code-capability-prompt chat--current-session))
           (base-prompt (or code-prompt
                            (chat-i18n-prompt 'assistant-persona
                                              "You are a helpful AI assistant.")))
           (target-note (chat-ui--followup-target-note))
           (instructions (and (fboundp 'chat-project-instructions)
                              (chat-project-instructions default-directory)))
           (prompt (cond
                    ((and target-note instructions)
                     (format "%s\n\n%s\n\n;; Project instructions:\n%s"
                             base-prompt target-note instructions))
                    (target-note
                     (format "%s\n\n%s" base-prompt target-note))
                    (instructions
                     (format "%s\n\n;; Project instructions:\n%s"
                             base-prompt instructions))
                    (t
                     base-prompt)))
           (system-prompt (chat-tool-caller-build-system-prompt
                           prompt (chat-ui--step-limit)
                           chat--current-session)))
      (chat-log "[TOOLS] System prompt: %s" system-prompt)
      (chat-log "[TOOLS] Adding system message to %d user messages" (length messages))
      (cons (make-chat-message
             :id "system-tools"
             :role :system
             :content system-prompt
             :timestamp (current-time))
            messages))))

(defun chat-ui--format-tool-results (tool-results)
  "Format TOOL-RESULTS for display."
  (when tool-results
    (mapconcat #'identity tool-results "\n")))

(defun chat-ui--format-tool-events (tool-events)
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

(defun chat-ui--follow-live-output (ui-buffer)
  "Scroll windows showing UI-BUFFER to the live response edge.
Only windows already near the bottom follow, and only when their
point is outside the input area, so typing is never interrupted and
manual scrolling is never overridden."
  (when (buffer-live-p ui-buffer)
    (with-current-buffer ui-buffer
      (let ((edge (and (markerp chat-ui--messages-end)
                       (marker-position chat-ui--messages-end)))
            (input-start (and (markerp chat-ui--input-overlay)
                              (marker-position chat-ui--input-overlay))))
        (when edge
          (dolist (window (get-buffer-window-list ui-buffer nil t))
            (when (and (window-live-p window)
                       (or (null input-start)
                           (< (window-point window) input-start))
                       (>= (window-end window t)
                           (max (point-min) (- (point-max) 80))))
              (set-window-point window edge))))))))

(defface chat-ui-shell-prompt-face
  '((t :inherit font-lock-comment-face :weight bold))
  "Face for the `$' marking an echoed shell command."
  :group 'chat-ui)

(defface chat-ui-shell-command-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the shell command itself.

The command is what you would search the transcript for, so it is the
part that should stand out from its own output."
  :group 'chat-ui)

(defface chat-ui-shell-output-face
  '((t :inherit fixed-pitch))
  "Face for shell output.

Fixed pitch because column alignment is meaningless without it: a
proportional font makes `ls' ragged however carefully the tabs were
expanded."
  :group 'chat-ui)

(defface chat-code-block-face
  '((t :inherit font-lock-constant-face :extend t))
  "Face for fenced code blocks in chat buffers.

Named for the surface that introduced it, and kept under that name so
existing customization keeps applying now that every chat buffer
formats code blocks this way."
  :group 'chat-ui)

(defcustom chat-ui-tool-summary-max-chars 240
  "Longest tool argument or result summary shown inline."
  :type 'integer
  :group 'chat-ui)

(defun chat-ui--compact-text (text &optional max-chars)
  "Normalize TEXT to one line and keep at most MAX-CHARS characters."
  (let* ((limit (or max-chars chat-ui-tool-summary-max-chars))
         (normalized (replace-regexp-in-string
                      "[ \t\n\r]+" " " (string-trim (or text "")))))
    (if (> (length normalized) limit)
        (concat (substring normalized 0 limit) "...")
      normalized)))

(defun chat-ui--tool-arguments-summary (arguments)
  "Return a compact one-line summary for tool ARGUMENTS."
  (chat-ui--compact-text (format "%S" arguments) 120))

(defun chat-ui--read-tool-result-data (result)
  "Best effort parse RESULT into Lisp data."
  (when (and (stringp result) (not (string-empty-p result)))
    (condition-case nil
        (car (read-from-string result))
      (error nil))))

(defun chat-ui--plist-like-p (data)
  "Return non-nil when DATA looks like a plist."
  (and (listp data) (keywordp (car data))))

(defun chat-ui--tool-result-data-summary (data)
  "Build a concise summary for parsed tool result DATA.

Tool results are structured, so a summary can say which file and what
happened instead of showing the first line of a serialized plist."
  (cond
   ((and (chat-ui--plist-like-p data) (plist-member data :content))
    (let ((path (plist-get data :path))
          (content (plist-get data :content)))
      (chat-ui--compact-text
       (format "%s%s"
               (if path (format "%s: " (file-name-nondirectory path)) "")
               (or content "")))))
   ((and (chat-ui--plist-like-p data) (plist-member data :lines))
    (let ((path (plist-get data :path))
          (lines (plist-get data :lines)))
      (chat-ui--compact-text
       (format "%s: %s"
               (if path (file-name-nondirectory path) "lines")
               (mapconcat #'identity (seq-take lines 8) " ")))))
   ((and (chat-ui--plist-like-p data) (plist-member data :path))
    (chat-ui--compact-text
     (format "%s %s"
             (file-name-nondirectory (or (plist-get data :path) "file"))
             (or (plist-get data :status) (plist-get data :result) "ok"))))
   ((and (chat-ui--plist-like-p data)
         (plist-member data :matches)
         (listp (plist-get data :matches)))
    (let* ((matches (plist-get data :matches))
           (names (mapcar #'file-name-nondirectory (seq-take matches 8))))
      (chat-ui--compact-text
       (format "%d matches: %s"
               (or (plist-get data :match-count) (length matches))
               (mapconcat #'identity names ", ")))))
   ((and (listp data)
         data
         (chat-ui--plist-like-p (car data))
         (plist-member (car data) :path))
    (let ((names nil)
          (used 0))
      (dolist (entry data)
        (let ((name (file-name-nondirectory
                     (or (plist-get entry :path)
                         (plist-get entry :name)
                         ""))))
          (when (and (not (string-empty-p name))
                     (< used chat-ui-tool-summary-max-chars))
            (push name names)
            (setq used (+ used (length name) 2)))))
      (chat-ui--compact-text
       (format "%d entries: %s"
               (length data)
               (mapconcat #'identity (nreverse names) ", ")))))
   (t nil)))

(defun chat-ui--tool-result-summary (result)
  "Return a compact summary for RESULT."
  (or (chat-ui--tool-result-data-summary
       (chat-ui--read-tool-result-data result))
      (chat-ui--compact-text
       (or (car (split-string (string-trim (or result "")) "\n" t)) "ok"))))

(defun chat-ui--tool-display-summary (tool-calls tool-results)
  "Build a concise user-facing summary for TOOL-CALLS and TOOL-RESULTS."
  (let (parts)
    (while (and tool-calls tool-results)
      (let* ((call (car tool-calls))
             (name (plist-get call :name))
             (summary (chat-ui--tool-result-summary (car tool-results))))
        (push (format "%s: %s" name summary) parts))
      (setq tool-calls (cdr tool-calls))
      (setq tool-results (cdr tool-results)))
    (when parts
      (mapconcat #'identity (nreverse parts) " | "))))

(defun chat-ui--append-to-messages (fn)
  "Run FN at the end of the conversation area."
  (save-excursion
    (goto-char chat-ui--messages-end)
    (funcall fn)
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui--replace-response-slot (content-start fn)
  "Replace the pending assistant slot at CONTENT-START with FN output."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char content-start)
      (delete-region content-start chat-ui--messages-end)
      (set-marker chat-ui--messages-end (point))
      (funcall fn)
      (set-marker chat-ui--messages-end (point)))))

(defun chat-ui--fence-safe-prefix-length (content)
  "Return the length of the CONTENT prefix after the last closed fence.

The streaming fast path may only keep text it will not have to reformat.
Cutting at the previous length leaves a half-arrived code block rendered
as prose, and the fence that closes it later never re-runs the
formatting, so the block stays broken for the rest of the conversation."
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

(defun chat-ui--insert-formatted-response (content)
  "Insert CONTENT, giving fenced code blocks their own face."
  (let ((pos 0)
        (len (length content)))
    (while (< pos len)
      (if (string-match "^\\(```\\([^\n]*\\)\n\\(\\(?:.\\|\n\\)*?\\)\n```\\)"
                        (substring content pos))
          (let* ((tail (substring content pos))
                 (lang (match-string 2 tail))
                 (code (match-string 3 tail))
                 (face (if (string-empty-p lang) 'default 'chat-code-block-face)))
            (insert (substring content pos (+ pos (match-beginning 0))))
            (insert (propertize (format "```%s\n%s\n```" lang code)
                                'face face))
            (setq pos (+ pos (match-end 0))))
        (insert (substring content pos))
        (setq pos len)))))

(defun chat-ui--render-response-state (ui-buffer content-start content tool-events
                                                 &optional live-detail
                                                 tool-summary
                                                 tool-loop-limit-reached)
  "Render the in-flight tail of the current turn in UI-BUFFER.

CONTENT is what has arrived and not yet been recorded; TOOL-EVENTS,
LIVE-DETAIL, TOOL-SUMMARY and TOOL-LOOP-LIMIT-REACHED describe the state
around it.  CONTENT-START is accepted for callers written against the
mutable slot this replaced; the tail is positioned from
`chat-ui--live-start', which the record moves as each step lands.

Only the tail is touched.  Committed steps are drawn from the session and
are not this function's business, which is what keeps an intermediate
step on screen once it has been recorded."
  (ignore content-start)
  (when (buffer-live-p ui-buffer)
    (with-current-buffer ui-buffer
      (setq chat-ui--request-tool-events tool-events)
      (chat-ui--track-tool-targets tool-events)
      (chat-ui--maybe-announce-approval-shortcuts tool-events)
      (when (or (and chat-request-panel-auto-show
                     chat-ui--current-request-id)
                (get-buffer-window
                 (chat-request-panel--buffer-name ui-buffer) t))
        (chat-request-panel-update
         ui-buffer
         chat-ui--current-request-id
         tool-events))
      (chat-ui--render-status-line)
      (setq chat-ui--live-response-content (or content ""))
      (setq chat-ui--live-trailers
            (list :detail live-detail
                  :tool-summary tool-summary
                  :limit-reached tool-loop-limit-reached))
      (chat-ui--render-live-region))))

(defun chat-ui--tool-result-lines (tool-calls tool-results)
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
                      (chat-ui--tool-arguments-summary arguments)
                      result)
              lines))
      (setq tool-calls (cdr tool-calls))
      (setq tool-results (cdr tool-results)))
    (nreverse lines)))

(defun chat-ui--tool-followup-message (tool-calls tool-results)
  "Build a follow-up system message from TOOL-CALLS and TOOL-RESULTS."
  (concat
   "Tool results from the previous step:\n"
   (mapconcat #'identity
              (chat-ui--tool-result-lines tool-calls tool-results)
              "\n")
   "\nUse these results to continue helping.\n"
   "If a tool result says approval denied, do not retry the same risky tool immediately.\n"
   "If another tool is needed, call one tool as JSON.\n"
   "Otherwise answer normally."))

(defcustom chat-ui-tool-loop-max-steps nil
  "Step ceiling for a chat run, or nil to follow the global budget.

Set this only to hold this display to a tighter limit than
`chat-agent-max-steps'; `unlimited' lifts the ceiling entirely."
  :type '(choice (const :tag "Follow chat-agent-max-steps" nil)
                 (integer :tag "Steps")
                 (const :tag "Unlimited" unlimited))
  :group 'chat)

(defun chat-ui--step-limit ()
  "Return the step ceiling in force for this display."
  (chat-agent-budget-effective-limit chat-ui-tool-loop-max-steps))

(defcustom chat-ui-max-output-tokens 4096
  "Output tokens to ask for, capped by what the provider allows."
  :type 'integer
  :group 'chat-ui)

(defcustom chat-ui-request-timeout 180
  "Seconds to wait for a reply before giving up."
  :type 'integer
  :group 'chat-ui)

(defcustom chat-ui-tool-followup-timeout 300
  "Seconds to wait for a reply that follows a tool call.

Longer than `chat-ui-request-timeout' because a follow-up arrives after
the model has already read a tool result, which is the slow part."
  :type 'integer
  :group 'chat-ui)

(defun chat-ui--request-output-budget (model)
  "Return the output token budget to request from MODEL.

Asking for more than the provider allows is refused outright by some and
silently clamped by others, so the ceiling comes from the provider when
it declares one."
  (let ((provider-limit (condition-case nil
                            (chat-llm-provider-option model :max-output-tokens)
                          (error nil))))
    (if (and (integerp provider-limit) (> provider-limit 0))
        (min chat-ui-max-output-tokens provider-limit)
      chat-ui-max-output-tokens)))

(defun chat-ui--make-agent-event-handler (session msg-id ui-buffer content-start request-id)
  "Return an agent event handler rendering into UI-BUFFER.
SESSION, MSG-ID, CONTENT-START, and REQUEST-ID identify the pending
assistant response being filled in."
  (let ((tool-events nil))
    (lambda (event)
      (let ((type (plist-get event :type)))
        (cond
         ((eq type 'stream-chunk)
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (setq chat-ui--live-response-content
                    (string-trim-right
                     (chat-tool-caller-extract-content
                      (or (plist-get event :content) ""))))
              (chat-ui--render-response-state
               ui-buffer
               content-start
               chat-ui--live-response-content
               tool-events
               (chat-ui--request-live-detail))
              (chat-ui--follow-live-output ui-buffer))))
         ((eq type 'tool-event)
          (setq tool-events (append tool-events
                                    (list (plist-get event :event))))
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (setq chat-ui--request-tool-events tool-events)
              (chat-ui--render-response-state
               ui-buffer
               content-start
               chat-ui--live-response-content
               tool-events
               (chat-ui--request-live-detail)))))
         ((eq type 'message-appended)
          (chat-agent-transcript-persist-message
           session
           (plist-get event :message))
          ;; The step is on the record now, so it becomes committed
          ;; history and the live tail starts over.  This is what keeps
          ;; an intermediate step on screen: the tail no longer owns it,
          ;; so the next chunk cannot overwrite it.
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (setq chat-ui--live-response-content "")
              (setq chat-ui--live-trailers
                    (list :detail (chat-ui--request-live-detail)))
              (chat-ui--redraw-conversation))))
         ((eq type 'response)
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (setq chat-ui--live-response-content
                    (or (plist-get (plist-get event :processed) :content) ""))
              (chat-ui--render-response-state
               ui-buffer
               content-start
               chat-ui--live-response-content
               tool-events
               (chat-ui--request-live-detail))
              (chat-ui--follow-live-output ui-buffer))))
         ((eq type 'followup)
          (when request-id
            (chat-request-diagnostics-record
             request-id
             'tool-loop-step
             :summary (format "Resolving tool step %d"
                              (plist-get event :step))))
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (chat-ui--refresh-live-surfaces))))
         ((eq type 'agent-end)
          (setq chat-ui--active-agent-run nil)
          (setq chat-ui--active-request-handle nil)
          (setq chat-ui--active-stream-process nil)
          (pcase (plist-get event :status)
            ((or 'completed 'stopped)
             (when (buffer-live-p ui-buffer)
               (with-current-buffer ui-buffer
                 (chat-ui--cleanup-request-state
                  'completed
                  (if (eq (plist-get event :status) 'stopped)
                      (format "Stopped after step limit (%s)"
                              (chat-agent-budget-label
                               (chat-ui--step-limit)))
                    "Request completed"))))
             (message "%s" (if (eq (plist-get event :status) 'stopped)
                               "Stopped after tool loop limit"
                             "Response completed"))
             (chat-ui--finalize-response
              session
              msg-id
              ui-buffer
              content-start
              (list :content (plist-get event :content)
                    :tool-events (plist-get event :tool-events))))
            ('cancelled
             (when (buffer-live-p ui-buffer)
               (with-current-buffer ui-buffer
                 (chat-ui--cleanup-request-state
                  'cancelled "Cancelled by user")))
             (message "Response cancelled"))
            ('error
             (chat-ui--render-error
              ui-buffer
              (or (plist-get event :reason) "Unknown error"))
             (message "Error: %s" (plist-get event :reason))))))))))

(defun chat-ui--start-agent-run (transport)
  "Start an agent run for the current session through TRANSPORT."
  (message "%s" (chat-i18n 'response-starting "Getting response from AI..."))
  (let* ((session chat--current-session)
         (model (chat-session-model-id session))
         ;; The session records more than a request should carry: command
         ;; replies and captured shell output are there for the reader.
         (messages (chat-transcript-model-messages
                    (chat-session-messages session)))
         (msg-id (chat-session-new-message-id))
         (ui-buffer (current-buffer))
         (request-id (chat-ui--begin-request session model transport))
         ;; No header is drawn up front: the tail draws its own once
         ;; there is something under it, and until then the narrative
         ;; line is what says the request is in flight.  A header planted
         ;; here would be a second one.
         (assistant-start chat-ui--live-start))
    (setq chat-ui--live-response-content "")
    (setq chat-ui--live-trailers nil)
    (setq chat-ui--last-render nil)
    (let* ((messages-with-tools (chat-ui--prepare-messages-with-tools messages))
           (messages-final
            (chat-context-prepare-messages
             messages-with-tools
             ;; Without a limit derived from the model this compacted
             ;; against a flat figure, throwing away history a large
             ;; window had ample room for.
             (chat-context-budget-compaction-limit
              (chat-session-model-id session))
             session)))
      (chat-log "[UI] Starting %s agent run with %d messages"
                transport (length messages-final))
      (setq chat-ui--active-agent-run
            (chat-agent-start
             (list :model model
                   :messages messages-final
                   :session session
                   :transport transport
                   :max-steps chat-ui-tool-loop-max-steps
                   :transform-context-fn
                   (lambda (_run step-messages)
                     (chat-context-prepare-messages
                      step-messages
                      (chat-context-budget-compaction-limit
                       (chat-session-model-id session))
                      session))
                   :request-options
                   (append
                    (list :temperature 0.7
                          :max-tokens (chat-ui--request-output-budget model)
                          :timeout chat-ui-request-timeout)
                    (when request-id
                      (list :request-id request-id)))
                   :followup-request-options
                   (list :timeout chat-ui-tool-followup-timeout)
                   :on-event
                   (chat-ui--make-agent-event-handler
                    session msg-id ui-buffer assistant-start request-id)))))))

(defface chat-ui-code-block-face
  '((t :inherit font-lock-constant-face :extend t))
  "Face for fenced code block lines in chat buffers."
  :group 'chat)

(defun chat-ui--fontify-markdown-lite (start end)
  "Apply lightweight markdown fontification between START and END.
Fenced code blocks use `chat-ui-code-block-face', fence markers use
`font-lock-comment-face', ATX headers become bold, and **bold**
spans use the bold face."
  (save-excursion
    (let ((in-fence nil))
      (goto-char start)
      (while (< (point) end)
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position)
                     (line-end-position))))
          (cond
           ((string-match-p "^\\s-*```" line)
            (add-text-properties (line-beginning-position)
                                 (min (1+ (line-end-position)) end)
                                 '(face font-lock-comment-face))
            (setq in-fence (not in-fence)))
           (in-fence
            (add-text-properties (line-beginning-position)
                                 (min (1+ (line-end-position)) end)
                                 '(face chat-ui-code-block-face)))
           ((string-match-p "^\\s-*#+\\s-" line)
            (add-text-properties (line-beginning-position)
                                 (line-end-position)
                                 '(face (:weight bold))))))
        (forward-line 1))
      (goto-char start)
      (while (re-search-forward "\\*\\*\\([^*\n]+\\)\\*\\*" end t)
        (add-text-properties (match-beginning 1)
                             (match-end 1)
                             '(face bold))))))

(defun chat-ui--proposed-edit (session content)
  "Return the edit CONTENT proposes for SESSION, or nil.

Only a session with code capability can be offered an edit to apply;
without it the same fenced block is just text in a reply."
  (when (and session
             (fboundp 'chat-code-session-p)
             (chat-code-session-p session)
             (fboundp 'chat-code--parse-code-edit))
    (chat-code--parse-code-edit content)))

(defun chat-ui--answer-on-record-p (session content)
  "Return non-nil when CONTENT is already the recorded answer of SESSION.

The agent loop records every step as it happens, the answer included, so
by the time a run ends the reply is usually on screen already.  Rendering
it as the live tail as well would show it twice.  It is not always
recorded -- a run cut short, or one that ended without an answer -- so
this is a question rather than an assumption."
  (when (and session (not (string-empty-p (string-trim (or content "")))))
    (let ((wanted (string-trim content)))
      (cl-some
       (lambda (message)
         (and (eq (chat-transcript-category message) 'ai-final)
              (equal (string-trim (or (chat-message-content message) ""))
                     wanted)))
       (chat-session-messages session)))))

(defun chat-ui--finalize-response (session msg-id ui-buffer content-start processed
                                           &optional raw-request raw-response)
  "Settle the finished turn for SESSION from PROCESSED.

MSG-ID, RAW-REQUEST, and RAW-RESPONSE are accepted for compatibility;
agent messages are persisted incrementally from `message-appended'.

The answer is already on the record and already on screen, so this does
not draw it again.  What it adds is what belongs to the turn as a whole
-- which tools ran, whether the step limit cut the run short -- and the
edit a coding reply may be proposing."
  (let* ((content (string-trim-right
                   ;; Stripped here as well as while streaming.  A reply
                   ;; that arrives in one piece takes this path only, and
                   ;; a tool call rendered raw reads as the model having
                   ;; answered with JSON.
                   (chat-tool-caller-extract-content
                    (or (plist-get processed :content) ""))))
         (tool-events (plist-get processed :tool-events))
         (tool-calls (plist-get processed :tool-calls))
         (tool-results (plist-get processed :tool-results))
         (tool-summary (chat-ui--tool-display-summary tool-calls tool-results))
         (limit-reached (plist-get processed :tool-loop-limit-reached))
         (recorded (chat-ui--answer-on-record-p session content)))
    (ignore msg-id raw-request raw-response)
    (if-let ((edit (chat-ui--proposed-edit session content)))
        (when (buffer-live-p ui-buffer)
          (with-current-buffer ui-buffer
            (chat-ui--replace-response-slot
             chat-ui--live-start
             (lambda () (chat-code--propose-edit edit)))))
      (chat-ui--render-response-state
       ui-buffer content-start
       ;; Drawing it again would show it twice: once as the recorded
       ;; answer above the tail, once as the tail itself.
       (if (or recorded (and (string-blank-p content) tool-summary))
           ""
         content)
       tool-events nil tool-summary limit-reached)
      (when (buffer-live-p ui-buffer)
        (with-current-buffer ui-buffer
          (chat-ui--fontify-markdown-lite chat-ui--conversation-start
                                          chat-ui--messages-end))))
    (chat-log "[UI] Response rendered")))

(defun chat-ui--render-error (ui-buffer error-message)
  "Render ERROR-MESSAGE in UI-BUFFER."
  (setq chat-ui--active-request-handle nil)
  (setq chat-ui--active-stream-process nil)
  (when (buffer-live-p ui-buffer)
    (with-current-buffer ui-buffer
      (chat-ui--cleanup-request-state 'error error-message)))
  (when (buffer-live-p ui-buffer)
    (with-current-buffer ui-buffer
      (save-excursion
        (goto-char chat-ui--messages-end)
        (insert (format "[Error: %s]" error-message))
        (insert "\n\n")
        (set-marker chat-ui--messages-end (point))))))

(defun chat-ui--get-response ()
  "Get AI response for current session.
Uses streaming if `chat-ui-use-streaming' is non-nil."
  (if chat-ui-use-streaming
      (chat-ui--get-response-streaming)
    (chat-ui--get-response-sync)))

(defun chat-ui--get-response-sync ()
  "Get AI response through the non streaming agent transport."
  (chat-ui--start-agent-run 'sync))

(defun chat-ui--get-response-streaming ()
  "Get AI response through the streaming agent transport."
  (chat-ui--start-agent-run 'stream))

;; ------------------------------------------------------------------
;; Interactive Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-set-model (model)
  "Point the current chat session at provider MODEL.

Every session stores its own provider, so `chat-default-model' only
decides what new sessions start with; a session restored from disk keeps
whatever it was created with, even after the default changes or its
provider stops working. This retargets the session in front of you and
persists the change.

Refuses while a response is in flight, because the reply would come back
from a different provider than the one that was asked."
  (interactive
   (list (intern
          (completing-read
           "Model: "
           (mapcar #'symbol-name (chat-llm-enabled-providers))
           nil t nil nil
           (and chat--current-session
                (symbol-name (chat-session-model-id chat--current-session)))))))
  (unless chat--current-session
    (user-error "No chat session in this buffer"))
  (unless (chat-llm-get-provider-config model)
    (user-error "Unknown provider: %s" model))
  (when (chat-ui--response-active-p)
    (user-error "Response in progress; cancel it before switching model"))
  (setf (chat-session-model-id chat--current-session) model)
  (when chat-session-auto-save
    (chat-session-save chat--current-session))
  (chat-ui--render-status-line)
  (message "Model switched to %s" model))

(defun chat-ui--handle-tool-creation (content)
  "Handle tool creation request from CONTENT."
  ;; Show thinking message
  (save-excursion
    (goto-char chat-ui--messages-end)
    (chat-ui--insert-role-label 'system)
    (insert (chat-i18n 'tool-forge-creating "🔨 Creating tool from your request..."))
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point)))
  ;; Generate tool asynchronously
  (run-with-timer
   0.1 nil
   (lambda ()
     (let ((tool (chat-tool-forge-ai-create-and-register
                  (chat-tool-forge-ai--extract-description content))))
       (if tool
           (progn
             ;; Success message
             (save-excursion
               (goto-char chat-ui--messages-end)
               (chat-ui--insert-role-label 'system)
               (insert (chat-i18n 'tool-forge-created
                                  "✅ Tool '%s' (%s) created and registered!"
                                  (chat-forged-tool-name tool)
                                  (chat-forged-tool-id tool)))
               (insert "\n\n")
               (set-marker chat-ui--messages-end (point)))
             ;; Add to session messages
             (chat-session-add-message
              chat--current-session
              (make-chat-message
               :id (chat-session-new-message-id)
               :role :system
               :content (format "Created tool: %s" (chat-forged-tool-name tool))
               :timestamp (current-time))))
         ;; Failure message
         (save-excursion
           (goto-char chat-ui--messages-end)
           (chat-ui--insert-role-label 'system)
           (insert (chat-i18n 'tool-forge-failed
                              "❌ Failed to create tool. Please try again with a clearer description."))
           (insert "\n\n")
           (set-marker chat-ui--messages-end (point))))))))

;; ------------------------------------------------------------------
;; Hybrid Mode - Shell & Direct Query
;; ------------------------------------------------------------------

(defcustom chat-ui-shell-unrestricted t
  "Whether a shell command typed by the user bypasses the AI tool limits.

A command the model proposes always stays on the restricted path, which
accepts only `chat-tool-shell-allowed-commands' and rejects shell
metacharacters.  A command a person typed is a different trust level, so
by default it runs through the system shell, where pipes, redirection and
variables work.  Set this to nil to hold typed commands to the same
restrictions as the model."
  :type 'boolean
  :group 'chat)

(defvar-local chat-ui--last-shell-command nil
  "The most recent shell command run from this buffer.")

(defun chat-ui--handle-shell-command (command)
  "Run COMMAND and report the result in the chat buffer.

A lone `cd' is handled here instead of in the shell, because a subprocess
cannot change the directory this session works in."
  (let* ((trimmed (string-trim command))
         (directory (chat-ui--directory-command-target trimmed)))
    (if directory
        (chat-ui--change-directory directory)
      (setq chat-ui--last-shell-command trimmed)
      (chat-ui--insert-shell-echo trimmed)
      (let ((output (chat-ui--execute-shell-safe trimmed)))
        (chat-ui--insert-shell-output
         (if (and output (not (string-empty-p (string-trim output))))
             output
           (chat-i18n 'no-output "(no output)")))))))

(defconst chat-ui--shell-tab-width 8
  "Tab stop width shell tools assume when they align columns.

`ls -C' pads with tabs rather than spaces, and it counts on stops every
eight columns.  A buffer set to any other `tab-width' -- four is a common
default -- renders that output ragged.  Rather than fight the buffer's
setting, the tabs are expanded here against the width that produced
them.")

(defun chat-ui--expand-tabs (text)
  "Return TEXT with tabs expanded against shell tab stops.

Column counting uses `string-width', so a line of CJK output lands where
the shell meant it to.  Text is copied in runs rather than character by
character, because the colour applied just before this is a text property
and rebuilding the string from characters would throw it away."
  (if (not (string-match-p "\t" text))
      text
    (let ((parts nil)
          (line-start 0)
          (length (length text)))
      (while (<= line-start length)
        (let* ((newline (string-search "\n" text line-start))
               (line-end (or newline length))
               (position line-start)
               ;; Counted on the output, not the input: a tab is one
               ;; character in but several columns out, so a second tab on
               ;; the same line has to be measured against what came out.
               (column 0))
          (while (< position line-end)
            (let ((tab (string-search "\t" text position)))
              (if (or (not tab) (>= tab line-end))
                  (progn
                    (push (substring text position line-end) parts)
                    (setq position line-end))
                (let ((run (substring text position tab)))
                  (push run parts)
                  (setq column (+ column (string-width run))))
                (let ((stop (* chat-ui--shell-tab-width
                               (1+ (/ column chat-ui--shell-tab-width)))))
                  (push (make-string (- stop column) ?\s) parts)
                  (setq column stop))
                (setq position (1+ tab)))))
          (when newline (push "\n" parts))
          (setq line-start (if newline (1+ newline) (1+ length)))))
      (apply #'concat (nreverse parts)))))

(defun chat-ui--as-display-faces (text)
  "Return TEXT with any `font-lock-face' promoted to `face'.

`ansi-color-apply' marks colour with `font-lock-face', which the display
honours only where Font Lock is on.  A chat buffer is not a
font-locked buffer, so the colour would simply not appear."
  (let ((position 0)
        (length (length text)))
    (while (< position length)
      (let ((next (or (next-single-property-change position 'font-lock-face text)
                      length))
            (value (get-text-property position 'font-lock-face text)))
        (when value
          (put-text-property position next 'face value text))
        (setq position next))))
  text)

(defun chat-ui--decorate-shell-text (text)
  "Return TEXT ready to display: colours applied, tabs expanded.

Shell tools emit SGR escapes when they think they are talking to a
terminal.  Left alone they show up as literal `ESC[0m' noise, so they are
turned into faces -- which is also the colour the output is supposed to
have."
  (chat-ui--expand-tabs
   (if (require 'ansi-color nil t)
       (chat-ui--as-display-faces (copy-sequence (ansi-color-apply text)))
     text)))

(defun chat-ui--insert-shell-echo (command)
  "Echo COMMAND in the transcript as the shell line it is."
  (chat-ui--insert-system-message
   (concat (propertize "$ " 'face 'chat-ui-shell-prompt-face)
           (propertize command 'face 'chat-ui-shell-command-face))))

(defun chat-ui--insert-shell-output (output)
  "Insert shell OUTPUT, aligned and coloured."
  (let ((text (copy-sequence (chat-ui--decorate-shell-text output))))
    ;; Appended, so it sits under any colour the output asked for rather
    ;; than replacing it.
    (add-face-text-property 0 (length text) 'chat-ui-shell-output-face t text)
    (chat-ui--insert-system-message text)))

(defun chat-ui--directory-command-target (command)
  "Return the directory a lone `cd' COMMAND asks for, or nil.

A compound command returns nil so that it reaches the shell, where its
own `cd' applies to that subprocess only.  A bare `cd' means home, as it
does in a shell."
  (when (string-match "\\`cd\\(?:[ \t]+\\(.*\\)\\)?\\'" command)
    (let ((target (string-trim (or (match-string 1 command) ""))))
      (unless (string-match-p "[;&|<>`$]" target)
        (if (string-empty-p target) "~" target)))))

(defun chat-ui--change-directory (directory)
  "Point this session at DIRECTORY.

Records it on the session so it outlives the buffer, and sets the buffer
default so typed shell commands and the tools the agent runs share one
working directory."
  (let* ((requested (chat-command-fold-path (string-trim directory)))
         (expanded (expand-file-name requested)))
    (if (not (file-directory-p expanded))
        (chat-ui--insert-system-message
         (chat-i18n 'directory-missing "❌ Directory not found: %s" requested))
      (setq default-directory (file-name-as-directory expanded))
      (when chat--current-session
        (chat-session-set-working-directory chat--current-session
                                            default-directory))
      (chat-ui--insert-system-message
       (chat-i18n 'directory-changed "📁 Changed directory to: %s" default-directory)))))

(defun chat-ui--repeat-shell-command ()
  "Run the shell command this buffer ran most recently."
  (if chat-ui--last-shell-command
      (chat-ui--handle-shell-command chat-ui--last-shell-command)
    (chat-ui--insert-system-message
     (chat-i18n 'shell-nothing-to-repeat "⚠️ No shell command to repeat yet"))))

(defun chat-ui--execute-shell-safe (command)
  "Run COMMAND for the chat buffer and return its output."
  (condition-case err
      (cond
       ((and chat-ui-shell-unrestricted
             (require 'chat-tool-shell nil t)
             (fboundp 'chat-tool-shell-execute-unrestricted))
        (chat-tool-shell-execute-unrestricted command))
       ((and (featurep 'chat-tool-shell)
             (fboundp 'chat-tool-shell-execute)
             (boundp 'chat-tool-shell-enabled)
             chat-tool-shell-enabled)
        (chat-tool-shell-execute command))
       (t
        (with-output-to-string
          (with-current-buffer standard-output
            (call-process-shell-command command nil t)))))
    (error (format "Error: %s" (error-message-string err)))))

(defun chat-ui--handle-direct-query (question)
  "Ask AI QUESTION directly without saving to session history.
This is an ephemeral query - the result is displayed but not persisted."
  (let ((trimmed (string-trim question)))
    (if (string-empty-p trimmed)
        (message "Empty question. Usage: ?<your question>")
      (chat-ui--insert-user-message (format "?%s" trimmed))
      (chat-ui--insert-system-message
       (propertize (chat-i18n 'query-asking "🤖 Asking AI...")
                   chat-ui--pending-query-property t))
      ;; Get AI response asynchronously
      (let* ((session chat--current-session)
             (model (chat-session-model-id session))
             (buffer (current-buffer)))
        (chat-llm-request-async
         model
         (list (make-chat-message
                :id (chat-session-new-message-id "ephemeral")
                :role :user
                :content trimmed
                :timestamp (current-time)))
         (lambda (result)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (let ((content (plist-get result :content)))
                 (chat-ui--insert-ephemeral-response content)))))
         (lambda (err)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (chat-ui--insert-system-message (chat-i18n 'error-note "❌ Error: %s" err)))))
         '(:temperature 0.7))))))

(defun chat-ui--insert-system-message (content)
  "Insert a system message CONTENT into chat buffer."
  (save-excursion
    (goto-char chat-ui--messages-end)
    (chat-ui--insert-role-label 'system)
    (insert content)
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui--insert-user-message (content)
  "Insert a user message CONTENT into chat buffer (ephemeral)."
  (save-excursion
    (goto-char chat-ui--messages-end)
    (chat-ui--insert-role-label 'user)
    (insert (propertize content 'face 'italic))
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui--insert-ephemeral-response (content)
  "Insert an ephemeral AI response CONTENT into chat buffer."
  (save-excursion
    (goto-char chat-ui--messages-end)
    (chat-ui--delete-pending-query-note)
    (chat-ui--insert-role-label 'assistant-quick)
    (insert content)
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui--delete-pending-query-note ()
  "Remove the `asking' note, wherever in the transcript it ended up."
  (let ((position (point-min)))
    (while (and position (< position chat-ui--messages-end))
      (if (get-text-property position chat-ui--pending-query-property)
          (let ((end (or (next-single-property-change
                          position chat-ui--pending-query-property
                          nil (marker-position chat-ui--messages-end))
                         (marker-position chat-ui--messages-end))))
            (delete-region position (min end (marker-position chat-ui--messages-end)))
            (setq position nil))
        (setq position (next-single-property-change
                        position chat-ui--pending-query-property
                        nil (marker-position chat-ui--messages-end)))
        (when (and position (>= position (marker-position chat-ui--messages-end)))
          (setq position nil))))
    (goto-char (marker-position chat-ui--messages-end))))

(defun chat-ui-clear-input ()
  "Clear current input."
  (interactive)
  (when chat-ui--input-overlay
    (delete-region (marker-position chat-ui--input-overlay) (point-max))
    (goto-char (marker-position chat-ui--input-overlay))))

(defun chat-ui--restore-input (content)
  "Restore CONTENT into the current input area."
  (goto-char (marker-position chat-ui--input-overlay))
  (insert content))

(defun chat-ui--rebuild-buffer (&optional input-content)
  "Rebuild the current chat buffer and optionally restore INPUT-CONTENT."
  (let ((session chat--current-session))
    (chat-ui-setup-buffer session)
    (when input-content
      (chat-ui--restore-input input-content))))

(defun chat-ui-regenerate-last-response ()
  "Regenerate the trailing assistant response in the current session."
  (interactive)
  (unless chat--current-session
    (user-error "No active chat session"))
  (if (chat-ui--response-active-p)
      (message "A response is already in progress. Cancel it before regenerating.")
    (let ((assistant-msg
           (chat-session-find-last-message-by-role
            chat--current-session
            :assistant)))
      (unless assistant-msg
        (user-error "No assistant response available to regenerate"))
      (setq chat--current-session
            (chat-session-create-branch-before-message
             chat--current-session
             (chat-message-id assistant-msg)
             nil
             '((reason . "regenerate"))))
      (chat-ui--rebuild-buffer)
      (chat-ui--get-response))))

(defun chat-ui-edit-last-user-message ()
  "Restore the last user message to the input area for editing."
  (interactive)
  (unless chat--current-session
    (user-error "No active chat session"))
  (if (chat-ui--response-active-p)
      (message "A response is already in progress. Cancel it before editing the last message.")
    (let ((user-msg
           (chat-session-find-last-message-by-role
            chat--current-session
            :user)))
      (unless user-msg
        (user-error "No user message available to edit"))
      (setq chat--current-session
            (chat-session-create-branch-before-message
             chat--current-session
             (chat-message-id user-msg)
             nil
             '((reason . "edit-resend"))))
      (chat-ui--rebuild-buffer (chat-message-content user-msg)))))

(defun chat-ui-previous-message ()
  "Navigate to previous message."
  (interactive)
  ;; Implementation for history navigation
  (message "History navigation not yet implemented"))

;; ------------------------------------------------------------------
;; View Raw Messages
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-view-raw-message ()
  "View raw API request/response for message at point."
  (interactive)
  (if (and (boundp 'chat--current-session) chat--current-session)
      (let* ((session chat--current-session)
             (messages (chat-session-messages session))
             ;; Find the last assistant message with raw data
             (msg (cl-find-if (lambda (m)
                               (and (eq (chat-message-role m) :assistant)
                                    (or (chat-message-raw-request m)
                                        (chat-message-raw-response m))))
                             (reverse messages))))
        (if msg
            (chat-ui--display-raw-exchange msg)
          (message "No raw message data found in current session")))
    (message "No active chat session")))

(defun chat-ui--display-raw-exchange (msg)
  "Display raw request/response for MSG in a buffer."
  (let* ((msg-id (chat-message-id msg))
         (raw-request (chat-message-raw-request msg))
         (raw-response (chat-message-raw-response msg))
         (buf (get-buffer-create (format "*chat-raw:%s*" msg-id))))
    (with-current-buffer buf
      (erase-buffer)
      (insert "========================================\n")
      (insert (format "Message ID: %s\n" msg-id))
      (insert "========================================\n\n")
      
      (when raw-request
        (insert "--- REQUEST ---\n")
        (insert raw-request)
        (insert "\n\n"))
      
      (when raw-response
        (insert "--- RESPONSE ---\n")
        (insert raw-response)
        (insert "\n")))
    
    (with-current-buffer buf
      (json-pretty-print-buffer)
      (goto-char (point-min))
      (view-mode)
      (pop-to-buffer buf))))

;;;###autoload
(defun chat-view-last-raw-exchange ()
  "View raw API exchange for the last assistant message."
  (interactive)
  (call-interactively 'chat-view-raw-message))

;; ------------------------------------------------------------------
;; Streaming Response (Phase 2)
;; ------------------------------------------------------------------

(defcustom chat-ui-use-streaming nil
  "Use streaming responses for real-time display."
  :type 'boolean
  :group 'chat)

;;;###autoload
(defun chat-ui-cancel-response ()
  "Cancel the current agent run or in flight request."
  (interactive)
  (if (chat-agent-active-p chat-ui--active-agent-run)
      (progn
        (chat-agent-cancel chat-ui--active-agent-run)
        (message "Response cancelled"))
    (when chat-ui--active-request-handle
      (chat-llm-cancel-request chat-ui--active-request-handle)
      (setq chat-ui--active-request-handle nil))
    (when (and chat-ui--active-stream-process
               (process-live-p chat-ui--active-stream-process))
      (when chat-ui--current-request-id
        (chat-request-diagnostics-record
         chat-ui--current-request-id
         'cancelled
         :process chat-ui--active-stream-process
         :summary "Cancelled by user"))
      (delete-process chat-ui--active-stream-process)
      (setq chat-ui--active-stream-process nil)
      (message "Response cancelled")))
  (chat-ui--cleanup-request-state))

(provide 'chat-ui)
;;; chat-ui.el ends here
