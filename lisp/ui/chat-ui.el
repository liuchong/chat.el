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
(require 'chat-input-history)
(require 'chat-input-hint)
(require 'chat-mark)
(require 'chat-shell-builtins)
;; Owned by `chat.el', which loads after this file.
(defvar chat-commands-help)
(defvar chat-auto-save-sessions)
(declare-function chat-help-text "chat" ())
(declare-function chat-new-session "chat" (&optional name model))
(declare-function chat-list-sessions "chat" ())
(declare-function chat--open-chat-session "chat" (session))
(declare-function chat-wiki-dispatch "chat-wiki" (arg))
(declare-function ansi-color-apply "ansi-color" (string))
(require 'chat-session)
(require 'chat-model-selection)
(require 'chat-content)
(require 'chat-message-stage)
(require 'chat-checkpoint)
(require 'chat-workspace)
(require 'chat-event)
(require 'chat-work-plan)
(require 'chat-goal)
(require 'chat-plan-mode)
(require 'chat-repl)
(require 'chat-work-shelf)
(require 'chat-transcript)
(require 'chat-markdown)
(require 'chat-llm)
(require 'chat-stream)
(require 'chat-model-runtime)
(require 'chat-tool-forge-ai)
(require 'chat-tool-caller)
(require 'chat-context)
(require 'chat-context-budget)
(require 'chat-log)
(require 'chat-request-diagnostics)
(require 'chat-runtime-status)
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

(defcustom chat-ui-use-streaming t
  "Use streaming responses for real-time display.

Declared twice before, as a `defvar' here and a `defcustom' near the end
of the file.  `custom-declare-variable' leaves an already-bound variable
alone, so the `defcustom' form's value never took effect and `customize'
edited a setting the code did not read.  One declaration now, and it is
the customizable one.

On by default.  Off meant the whole reply arrived in a single callback
when the request finished, which is the behaviour that made a slow answer
indistinguishable from a hung one."
  :type 'boolean
  :group 'chat)

(defvar-local chat-ui--active-stream-process nil
  "Currently active stream process for cancellation.")

(defvar-local chat-ui--input-overlay nil
  "Overlay for the input area in chat buffer.")

(defvar-local chat-ui--messages-end nil
  "Marker for end of messages area.")

(defvar-local chat-ui--work-shelf-start nil
  "Marker before the input-adjacent work shelf.")

(defvar-local chat-ui--work-shelf-end nil
  "Marker after the input-adjacent work shelf.")

(defvar-local chat-ui--work-shelf-open nil
  "Non-nil when the outer input work shelf is open.")

(defvar-local chat-ui--work-shelf-expanded-sections nil
  "Hash table of expanded section IDs in the input work shelf.")

(defvar-local chat-ui--work-shelf-section-ids nil
  "Provider IDs currently rendered in the input work shelf.")

(defvar-local chat-ui--active-request-handle nil
  "Currently active non streaming request handle.")

(defvar chat-ui--input-was-typed nil
  "Non-nil while a handler runs on text entered without a command name.

Mode words are read only from an explicit `/send'.  Plain input reaches
the same handler, so reading them from both would mean that typing
\"queue the build for tomorrow\" sent \"the build for tomorrow\" and
queued it.  Asking for `/send queue ...' is a choice; typing is not.

Declared here rather than beside its use: bound with `let', so it has to
be known as a dynamic variable before the first binding is compiled, or
the binding is lexical and does nothing at all.")

(defvar chat-ui--send-content-parts nil
  "Typed attachment parts carried by the input currently being dispatched.")

(defvar chat-ui--send-content-parts-consumed nil
  "Non-nil when the current dispatch recorded or queued its attachments.")

(defvar chat-ui--submitted-model-target nil
  "Model target captured by the input currently crossing a send boundary.")

(defconst chat-ui-send-modes '(insert queue interrupt)
  "How input is handled when a run is already in progress.

insert     add it to the run in progress, for the next step to see
queue      hold it until the run finishes, then send it as a new run
interrupt  stop the run, keep what it produced, and send this instead")

(defcustom chat-send-default-mode 'insert
  "What pressing return during a run does when no mode is named.

`insert' because that is what it has always done; changing the default
would change the behaviour of every existing user without their asking."
  :type '(choice (const insert) (const queue) (const interrupt))
  :group 'chat)

(defvar-local chat-ui--send-mode nil
  "Mode chosen for this buffer, or nil to use `chat-send-default-mode'.
See `chat-ui-send-modes'.")

(defvar-local chat-ui--queued-sends nil
  "Messages waiting for the current run to finish, in arrival order.")

(defvar-local chat-ui--pending-content-parts nil
  "Attachment parts staged beside the current input text.")

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

(defvar-local chat-ui--runtime-status nil
  "Current pure runtime status projection for this chat buffer.")

(defvar-local chat-ui--last-approval-hint nil
  "Last approval hint signature shown in this buffer.")

(defvar-local chat-ui--last-tracked-tool-paths nil
  "Most recent file targets seen in this chat buffer.")

(defvar-local chat-ui--live-response-content ""
  "Accumulated visible content for the current live response.")

(defvar-local chat-ui--live-reasoning-content ""
  "Accumulated reasoning for the current live response.

A reasoning model can spend a minute here before its first word of answer.
Dropping this is what made the screen sit still for that minute and then
paint the whole reply at once: the agent emitted `stream-reasoning' and
nothing listened.")

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

Holds `:tool-summary', `:permission-failure' and `:limit-reached', which
belong to the turn as a whole rather than to any one part of it.")

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
         (staged (chat-ui--stage-length session)))
    (concat (chat-i18n 'status-model "Model: %s" model)
            (when-let ((phase (and chat-ui--runtime-status
                                   (chat-runtime-status-phase
                                    chat-ui--runtime-status))))
              (format " | %s"
                      (chat-runtime-status-phase-label phase)))
            (when auto (format " | %s" (chat-i18n 'status-auto "auto: /%s" auto)))
            (when (> staged 0)
              (format " | %s" (chat-i18n 'status-staged "staged: %d" staged)))
            (when (and (boundp 'chat-ui--last-outcome)
                       chat-ui--last-outcome
                       (null (and chat-ui--runtime-status
                                  (chat-runtime-status-phase
                                   chat-ui--runtime-status))))
              (format " | %s" chat-ui--last-outcome))
            (when-let ((approval (chat-ui--status-approval session)))
              (format " | %s" approval))
            (when label (format " | %s" label)))))

(defun chat-ui--status-approval (session)
  "Return the approval mode segment for SESSION, or nil when it is the default.

`manual' is not announced, on the same grounds as the baseline command:
naming the ordinary case every time teaches the reader to skip the field.
The other two are announced always, and `dangerous' in a face of its own
-- a user who has forgotten that every command now runs unasked is the
worst way for this to fail."
  (pcase (chat-approval-effective-mode session)
    ('manual nil)
    ('guarded (chat-i18n 'status-approval-guarded "approval: guarded"))
    ('dangerous
     (propertize (chat-i18n 'status-approval-dangerous "approval: DANGEROUS")
                 'face 'warning))
    (_ nil)))

(defun chat-ui--render-status-line ()
  "Rewrite the status line in place from the current session."
  (let* ((input-offset
          (and (markerp chat-ui--input-overlay)
               (marker-position chat-ui--input-overlay)
               (>= (point) (marker-position chat-ui--input-overlay))
               (- (point) (marker-position chat-ui--input-overlay))))
         (point-anchor (and (null input-offset) (copy-marker (point) t)))
         (window-anchors
          (mapcar (lambda (window)
                    (cons window (copy-marker (window-start window) nil)))
                  (get-buffer-window-list (current-buffer) nil t))))
    (unwind-protect
        (save-excursion
          (let ((inhibit-read-only t))
            (goto-char (point-min))
            (forward-line 1)
            (delete-region (line-beginning-position) (line-end-position))
            (let ((start (point)))
              (insert (chat-ui--status-line
                       (and (boundp 'chat--current-session)
                            chat--current-session)))
              ;; Appended, so a segment that carries its own face keeps it.
              (add-face-text-property start (point) 'shadow t))))
      (cond
       ((and input-offset (marker-position chat-ui--input-overlay))
        (goto-char (+ (marker-position chat-ui--input-overlay) input-offset)))
       ((and point-anchor (marker-position point-anchor))
        (goto-char point-anchor)))
      (when point-anchor (set-marker point-anchor nil))
      (dolist (entry window-anchors)
        (when (and (window-live-p (car entry))
                   (marker-position (cdr entry)))
          (set-window-start (car entry) (cdr entry) t))
        (set-marker (cdr entry) nil)))))

(defun chat-ui--set-runtime-status (status)
  "Set STATUS and redraw only when its visible projection changed."
  (unless (equal (and status
                      (list (chat-runtime-status-phase status)
                            (chat-runtime-status-kind status)
                            (chat-runtime-status-summary status)
                            (chat-runtime-status-action status)))
                 (and chat-ui--runtime-status
                      (list (chat-runtime-status-phase chat-ui--runtime-status)
                            (chat-runtime-status-kind chat-ui--runtime-status)
                            (chat-runtime-status-summary chat-ui--runtime-status)
                            (chat-runtime-status-action chat-ui--runtime-status))))
    (setq chat-ui--runtime-status status)
    (chat-ui--render-status-line)))

(defun chat-ui--project-runtime-event (type &optional payload)
  "Project runtime TYPE and PAYLOAD into this chat buffer."
  (let ((phase (chat-runtime-status-phase-for-event type payload)))
    (cond
     ((eq phase 'idle) (chat-ui--set-runtime-status nil))
     ((memq phase chat-runtime-status-phases)
      (chat-ui--set-runtime-status
       (chat-runtime-status-create :phase phase :source type))))))

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

(defvar-local chat-ui--last-outcome nil
  "Text of the last finished run's terminal state, shown in the status line.

Cleared when the next request begins.  A run that ended reads as ended;
without this the only place that outcome lived was the transcript, and a
reader looking at the header could not tell a finished run from one still
in flight.")

(defun chat-ui--request-elapsed-seconds (&optional snapshot)
  "Return seconds since the current request began, or nil."
  (when-let* ((snap (or snapshot
                        (and chat-ui--current-request-id
                             (chat-request-diagnostics-snapshot
                              chat-ui--current-request-id))))
              (started (plist-get snap :started-at)))
    (float-time (time-subtract (current-time) started))))

(defun chat-ui--request-live-detail (&optional snapshot)
  "Return a compact live request label from SNAPSHOT.

The elapsed time rides along: a phase that never advances is the freeze
signal, and the seconds next to it are what tell the reader so without
opening the request panel."
  (let ((detail (chat-request-diagnostics-live-detail
                 (or snapshot
                     (and chat-ui--current-request-id
                          (chat-request-diagnostics-snapshot
                           chat-ui--current-request-id)))
                 chat-ui--request-tool-events))
        (elapsed (chat-ui--request-elapsed-seconds snapshot)))
    (if (and detail elapsed (>= elapsed 1))
        (format "%s · %s" detail (chat-transcript--format-duration elapsed))
      detail)))

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

(defun chat-ui--terminal-run-marker (session status reason)
  "Build the display-only message marking a run's terminal state.

The marker is a stamped `system-detail' message: it persists in the
session, renders as a transcript row, and is never sent to the model
\(the display-only categories are excluded from model messages)."
  (let* ((elapsed (chat-ui--request-elapsed-seconds))
         (turns (chat-transcript-turns (chat-session-messages session)))
         (steps (length (plist-get (car (last turns)) :steps)))
         (total (chat-transcript--format-duration elapsed))
         (text
          (pcase status
            ('completed
             (chat-i18n 'run-completed
                        "✓ Completed · %s · %d steps" (or total "?") steps))
            ('stopped
             (chat-i18n 'run-stopped
                        "◆ Stopped: %s · %s · %d steps"
                        (or reason "?") (or total "?") steps))
            ('cancelled
             (chat-i18n 'run-cancelled "■ Cancelled · %s" (or total "?")))
            (_
             (chat-i18n 'run-failed
                        "✗ Failed: %s · %s" (or reason "?") (or total "?"))))))
    (chat-transcript-stamp
     (make-chat-message
      :id (chat-session-new-message-id)
      :role :system
      :content text
      :timestamp (current-time)
      :metadata (list :terminal-state status
                      :duration-seconds elapsed
                      :step-count steps))
     :category 'turn-outcome)))

(defun chat-ui--record-terminal-marker (marker)
  "Persist MARKER and project it into the status line.

The transcript's final row used to leave the reader inferring the outcome
from an absence: no spinner, no error, no progress.  An absence is a bad
signal -- it looks identical to a stall -- so the outcome is recorded as
a row of its own and projected into the status line.

The record is the drawing: redraw renders exactly one copy of the marker
from the session.  Paths that never redraw draw the row directly with
`chat-ui--draw-terminal-marker-row'."
  (chat-session-add-message (chat-ui--require-current-session) marker)
  (setq chat-ui--last-outcome (chat-message-content marker))
  (chat-ui--render-status-line)
  marker)

(defun chat-ui--draw-terminal-marker-row (marker)
  "Draw MARKER's row at the end of the conversation area.

Only for terminal paths that never redraw the conversation: the row goes
with the region on the next redraw and the record draws it from then on."
  (when (and (markerp chat-ui--messages-end)
             (marker-position chat-ui--messages-end))
    (let ((inhibit-read-only t)
          (status (plist-get (chat-message-metadata marker)
                             :terminal-state)))
      (save-excursion
        (goto-char chat-ui--messages-end)
        (insert (propertize
                 (concat chat-ui-detail-indent
                         (chat-message-content marker) "\n")
                 'face (pcase status
                         ('completed 'success)
                         ('error 'error)
                         (_ 'chat-transcript-system))))
        (set-marker chat-ui--messages-end (point))))))

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
  (setq chat-ui--live-reasoning-content "")
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
        (chat-ui--clear-request-hint-timer)
        (chat-request-surface-update-panel-if-visible
         buffer
         chat-ui--current-request-id
         chat-ui--request-tool-events)
        (message "%s Use C-c C-p or M-x chat-show-current-request-status for details."
                 message-text)))))

(defun chat-ui--start-request-hint-timer (buffer)
  "Start the stalled request hint timer for BUFFER.

Repeats, and stops itself once it has something to say or once the
request ends.  It used to fire once: with the stall check now declining
to call a running tool a stall, a single shot landing during a long tool
call would be spent on nothing and a real stall afterwards would go
unreported -- trading a false alarm for a silence, which is not an
improvement."
  (chat-ui--clear-request-hint-timer)
  (setq chat-ui--request-hint-shown nil)
  (setq chat-ui--request-hint-timer
        (run-at-time
         chat-request-diagnostics-stall-threshold
         chat-request-diagnostics-stall-threshold
         #'chat-ui--maybe-show-request-hint
         buffer)))

(defun chat-ui--begin-request (session provider model transport)
  "Create a diagnostics trace for SESSION, PROVIDER, MODEL, and TRANSPORT."
  (let ((request-id
         (chat-request-diagnostics-create
          'chat
          provider
          model
          (list :session-id (chat-session-id session)
                :session-name (chat-session-name session)))))
    (setq chat-ui--current-request-id request-id)
    ;; A new request replaces the last outcome: while it runs, the status
    ;; line belongs to the phase in flight, not to what finished before.
    (setq chat-ui--last-outcome nil)
    (chat-request-diagnostics-record
     request-id
     'request-created
     :transport transport
     :summary (format "Preparing %s request" transport))
    (setq chat-ui--request-tool-events nil)
    (setq chat-ui--live-response-content "")
    (setq chat-ui--live-reasoning-content "")
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
    (:name "send"     :handler chat-ui--command-send   :default sticky :while-busy t)
    (:name "quick"    :handler chat-ui--command-quick  :default reset)
    (:name "cmd"      :handler chat-ui--command-shell  :default sticky)
    (:name "stage"    :handler chat-ui--command-stage  :default sticky :while-busy t)
    (:name "cd"       :handler chat-ui--command-cd)
    (:name "pwd"      :handler chat-ui--command-pwd)
    (:name "root"     :handler chat-ui--command-root)
    (:name "new"      :handler chat-ui--command-new)
    (:name "list"     :handler chat-ui--command-list)
    (:name "save"     :handler chat-ui--command-save)
    (:name "clear"    :handler chat-ui--command-clear)
    (:name "goal"     :handler chat-ui--command-goal)
    (:name "plan"     :handler chat-ui--command-plan)
    (:name "repl"     :handler chat-ui--command-repl :while-busy t)
    (:name "wiki"     :handler chat-wiki-dispatch)
    (:name "approve"  :handler chat-ui--command-approve)
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
all for the conversation.  They are gone rather than reassigned: both
names read equally well as `/send' and as `/quick', so whichever one they
pointed at, a reader would have had to remember which.  A name that has to
be memorized to be distinguished from its neighbour is not carrying its
weight.")

;; Punctuation, not translation: registered as aliases so the table stays
;; one entry per command, and registered under a language so they are
;; accepted whatever `chat-language' says.
(chat-i18n-register-aliases
 'en
 '(("?" . "quick")
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

(defconst chat-ui--command-usage-schema-version 1
  "Current session-local command usage schema.")

(defun chat-ui--command-usage-records (&optional session)
  "Return current-schema command usage records for SESSION."
  (let ((stored (chat-session-metadata-get
                 (or session chat--current-session)
                 :chat-ui-command-usage)))
    (when (and (listp stored)
               (= (or (alist-get 'schemaVersion stored) 0)
                  chat-ui--command-usage-schema-version))
      (append (alist-get 'counts stored) nil))))

(defun chat-ui--command-usage-count (name &optional session)
  "Return successful dispatch count for canonical command NAME in SESSION."
  (let ((record
         (seq-find
          (lambda (entry) (equal (alist-get 'name entry) name))
          (chat-ui--command-usage-records session))))
    (or (and record (alist-get 'count record)) 0)))

(defun chat-ui--record-command-usage (name)
  "Record one successful dispatch of canonical command NAME."
  (when (and chat--current-session (chat-ui--command-entry name))
    (let* ((records (chat-ui--command-usage-records))
           (record (seq-find
                    (lambda (entry) (equal (alist-get 'name entry) name))
                    records)))
      (if record
          (setcdr (assq 'count record)
                  (1+ (or (alist-get 'count record) 0)))
        (setq records
              (append records
                      (list `((name . ,name) (count . 1))))))
      (chat-ui--session-metadata-set
       :chat-ui-command-usage
       `((schemaVersion . ,chat-ui--command-usage-schema-version)
         (counts . ,(vconcat records)))))))

(defun chat-ui--command-hint-model ()
  "Return a passive slash-command hint model at point, or nil."
  (when-let ((bounds (chat-ui--command-token-bounds)))
    (when (= (point) (cdr bounds))
      (let ((prefix (buffer-substring-no-properties
                     (1+ (car bounds)) (cdr bounds))))
        (make-chat-input-hint-model
         :source 'slash-command
         :prefix prefix
         :anchor-start (car bounds)
         :anchor-end (cdr bounds)
         :candidates
         (mapcar
          (lambda (entry)
            (let* ((canonical (plist-get entry :name))
                   (display (chat-ui--display-command-name canonical)))
              (make-chat-input-hint-candidate
               :key canonical
               :completion display
               :display (concat "/" display)
               :annotation (chat-ui--command-annotation canonical)
               :frequency (chat-ui--command-usage-count canonical))))
          chat-ui--command-table))))))

(defun chat-ui--model-argument-bounds ()
  "Return bounds of a `/model' target being typed at point, or nil."
  (when (and (chat-ui--point-in-input-p)
             (= (point) (point-max)))
    (let* ((input-start (marker-position chat-ui--input-overlay))
           (text (buffer-substring-no-properties input-start (point))))
      (when (string-match
             "\\`[/／]model[[:space:]]+\\([^[:space:]]*\\)\\'" text)
        (cons (+ input-start (match-beginning 1))
              (+ input-start (match-end 1)))))))

(defun chat-ui--model-argument-completion-at-point ()
  "Complete a `/model' target without opening a selection session."
  (when-let ((bounds (chat-ui--model-argument-bounds)))
    (list (car bounds)
          (cdr bounds)
          (mapcar #'car (chat-ui--model-target-candidates))
          :exclusive 'no
          :company-kind (lambda (_candidate) 'value))))

(defun chat-ui--model-argument-hint-model ()
  "Return passive configured-model hints after `/model', or nil."
  (when-let ((bounds (chat-ui--model-argument-bounds)))
    (let ((prefix (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (make-chat-input-hint-model
       :source 'model-target
       :prefix prefix
       :anchor-start (car bounds)
       :anchor-end (cdr bounds)
       :candidates
       (mapcar
        (lambda (entry)
          (make-chat-input-hint-candidate
           :key (car entry)
           :completion (car entry)
           :display (car entry)
           :annotation ""
           :frequency 0))
        (chat-ui--model-target-candidates))))))

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

(defun chat-ui--common-prefix (strings)
  "Return the exact longest common prefix of non-empty STRINGS."
  (let ((prefix (copy-sequence (car strings))))
    (dolist (string (cdr strings))
      (let ((limit (min (length prefix) (length string)))
            (index 0))
        (while (and (< index limit)
                    (= (aref prefix index) (aref string index)))
          (setq index (1+ index)))
        (setq prefix (substring prefix 0 index))))
    prefix))

(defun chat-ui-complete-input ()
  "Expand the current input token without opening a selection session."
  (interactive)
  (chat-input-hint-clear)
  (when-let* ((capf (run-hook-with-args-until-success
                     'completion-at-point-functions))
              (start (nth 0 capf))
              (end (nth 1 capf))
              (table (nth 2 capf)))
    (let* ((predicate (plist-get (nthcdr 3 capf) :predicate))
           (input (buffer-substring-no-properties start end))
           (candidates (all-completions input table predicate))
           (target (cond
                    ((null candidates) nil)
                    ((null (cdr candidates)) (car candidates))
                    (t (chat-ui--common-prefix candidates)))))
      (when (and target (> (length target) (length input)))
        (delete-region start end)
        (goto-char start)
        (insert target)))))

(defun chat-ui-insert-newline ()
  "Insert a newline in the input area without sending the message."
  (interactive)
  (unless (chat-ui--point-in-input-p)
    (goto-char (point-max)))
  (insert "\n"))

(defun chat-ui--human-bytes (bytes)
  "Return BYTES as a compact size for the attachment row."
  (cond
   ((< bytes 1024) (format "%d B" bytes))
   ((< bytes (* 1024 1024)) (format "%.1f KB" (/ bytes 1024.0)))
   (t (format "%.1f MB" (/ bytes 1048576.0)))))

(defun chat-ui--attachment-label (part)
  "Return a compact label for attachment PART."
  (format "%s  %s  %s"
          (symbol-name (chat-content-part-type part))
          (chat-content-part-name part)
          (chat-ui--human-bytes (chat-content-part-size part))))

(defun chat-ui--pending-attachments-prompt ()
  "Return prompt rows for attachments staged with the current input."
  (if (null chat-ui--pending-content-parts)
      ""
    (concat
     (chat-ui--prompt-segment
      (format "  Attachments (%d)\n" (length chat-ui--pending-content-parts))
      'face 'font-lock-keyword-face)
     (mapconcat
      (lambda (part)
        (chat-ui--prompt-segment
         (format "    %s\n" (chat-ui--attachment-label part))
         'face 'shadow
         'help-echo "M-x chat-ui-preview-attachment to preview"))
      chat-ui--pending-content-parts
      ""))))

(defun chat-ui--refresh-attachment-prompt ()
  "Refresh the input prompt after its staged attachments change."
  (when (and (derived-mode-p 'chat-mode)
             (markerp chat-ui--input-overlay))
    (chat-ui--render-input-prompt)))

(defun chat-ui-attach-file (file)
  "Stage FILE as a durable attachment for the next recorded message."
  (interactive "fAttach file: ")
  (unless chat--current-session
    (user-error "No active chat session"))
  (let ((part (chat-content-attach-file file)))
    (unless (seq-some
             (lambda (existing)
               (and (eq (chat-content-part-type existing)
                        (chat-content-part-type part))
                    (equal (chat-content-part-attachment-id existing)
                           (chat-content-part-attachment-id part))))
             chat-ui--pending-content-parts)
      (setq chat-ui--pending-content-parts
            (append chat-ui--pending-content-parts (list part))))
    (chat-ui--refresh-attachment-prompt)
    (message "Attached %s" (chat-content-part-name part))))

(defun chat-ui--clipboard-image-data ()
  "Return clipboard image data and suffix, or nil when unavailable."
  (catch 'image
    (dolist (entry '(("image/png" . ".png")
                     ("image/jpeg" . ".jpg")))
      (let ((data (and (fboundp 'gui-get-selection)
                       (ignore-errors
                         (gui-get-selection
                          'CLIPBOARD (intern (car entry)))))))
        (when (and (stringp data) (> (length data) 0))
          (throw 'image (cons data (cdr entry))))))))

(defun chat-ui--clipboard-image-file ()
  "Copy the clipboard image to a temporary file and return its path."
  (if-let* ((entry (chat-ui--clipboard-image-data)))
      (let ((file (make-temp-file "chat-clipboard-" nil (cdr entry))))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert (car entry))
          (write-region (point-min) (point-max) file nil 'silent))
        file)
    (when-let* ((program (executable-find "pngpaste")))
      (let ((file (make-temp-file "chat-clipboard-" nil ".png")))
        (if (= 0 (call-process program nil nil nil file))
            file
          (delete-file file)
          nil)))))

(defun chat-ui-paste-image ()
  "Stage the image currently on the system clipboard."
  (interactive)
  (unless chat--current-session
    (user-error "No active chat session"))
  (let ((file (chat-ui--clipboard-image-file)))
    (unless file
      (user-error "The clipboard does not contain a readable image"))
    (unwind-protect
        (let ((part (chat-content-attach-file file 'image)))
          (setf (chat-content-part-name part)
                (format "clipboard-%s.png" (format-time-string "%Y%m%d-%H%M%S")))
          (setq chat-ui--pending-content-parts
                (append chat-ui--pending-content-parts (list part)))
          (chat-ui--refresh-attachment-prompt)
          (message "Attached clipboard image"))
      (when (file-exists-p file)
        (delete-file file)))))

(defun chat-ui--all-attachment-parts ()
  "Return staged and recorded attachments available for preview."
  (let ((parts (copy-sequence chat-ui--pending-content-parts)))
    (when chat--current-session
      (dolist (message (reverse (chat-session-messages chat--current-session)))
        (dolist (part (chat-message-parts message))
          (when (memq (chat-content-part-type part) '(image file))
            (push part parts)))))
    (delete-dups parts)))

(defun chat-ui--choose-attachment (parts prompt)
  "Choose one of PARTS using PROMPT and return it."
  (let ((index 0)
        choices)
    (dolist (part parts)
      (setq index (1+ index))
      (push (cons (format "%d  %s" index (chat-ui--attachment-label part))
                  part)
            choices))
    (setq choices (nreverse choices))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

(defun chat-ui-preview-attachment ()
  "Preview a staged or recorded attachment."
  (interactive)
  (let* ((parts (chat-ui--all-attachment-parts))
         (part (and parts (chat-ui--choose-attachment parts "Preview: "))))
    (unless part
      (user-error "No attachments are available"))
    (let ((file (chat-content-part-file part)))
      (if (eq (chat-content-part-type part) 'image)
          (let ((image (create-image file nil nil))
                (buffer (get-buffer-create "*chat-attachment-preview*")))
            (unless image
              (user-error "Emacs cannot decode %s"
                          (chat-content-part-mime-type part)))
            (with-current-buffer buffer
              (let ((inhibit-read-only t))
                (erase-buffer)
                (insert-image image (chat-content-part-name part))
                (insert "\n"))
              (special-mode))
            (pop-to-buffer buffer))
        (find-file-other-window file)))))

(defun chat-ui-remove-attachment (&optional all)
  "Remove one staged attachment, or every staged attachment with ALL."
  (interactive "P")
  (unless chat-ui--pending-content-parts
    (user-error "No staged attachments"))
  (if all
      (setq chat-ui--pending-content-parts nil)
    (let ((part (chat-ui--choose-attachment
                 chat-ui--pending-content-parts "Remove: ")))
      (setq chat-ui--pending-content-parts
            (delq part chat-ui--pending-content-parts))))
  (chat-ui--refresh-attachment-prompt)
  (message "%s" (if all "Removed all attachments" "Removed attachment")))

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
  (setq chat-ui--live-reasoning-content "")
  (setq chat-ui--live-trailers nil)
  (setq chat-ui--last-render nil)
  (setq chat-ui--opened-fold-groups nil)
  (setq chat-ui--work-shelf-start nil)
  (setq chat-ui--work-shelf-end nil)
  (setq chat-ui--work-shelf-open nil)
  (setq chat-ui--work-shelf-expanded-sections (make-hash-table :test 'eq))
  (setq chat-ui--work-shelf-section-ids nil)
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

(defun chat-ui--insert-mdp-detail (label text face)
  "Insert MDP TEXT as a Markdown document below detail LABEL in FACE."
  (let ((body (string-trim-right (or text "")))
        (title (concat chat-ui-detail-indent
                       (or label (chat-i18n 'detail-label "Detail")))))
    (insert (propertize (concat title "\n") 'face face))
    (unless (string-empty-p body)
      ;; Keep the document at column zero.  Tables use absolute display
      ;; columns, so adding detail indentation would undo their alignment.
      (insert (chat-markdown-render body face))
      (insert "\n"))))

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

(defface chat-ui-role-user
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user role label."
  :group 'chat)

(defface chat-ui-role-assistant
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for assistant role labels."
  :group 'chat)

(defface chat-ui-role-system
  '((t :inherit font-lock-comment-face :weight bold))
  "Face for system role labels."
  :group 'chat)

(defconst chat-ui--role-faces
  '((user . chat-ui-role-user)
    (assistant . chat-ui-role-assistant)
    (assistant-quick . chat-ui-role-assistant)
    (system . chat-ui-role-system))
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
  (let ((face (alist-get role chat-ui--role-faces)))
    (insert (propertize (concat (chat-ui--role-label role) ":\n")
                        'face face
                        ;; Keep a semantic property beside the appearance.
                        ;; If another display pass clears `face', the live
                        ;; renderer can restore it without guessing from
                        ;; translated label text.
                        'chat-ui-role role
                        'rear-nonsticky '(face chat-ui-role)))))

(defun chat-ui--repair-role-faces (start end)
  "Restore role faces carrying semantic labels between START and END."
  (let ((position start))
    (while (< position end)
      (let* ((role (get-text-property position 'chat-ui-role))
             (next (or (next-single-property-change
                        position 'chat-ui-role nil end)
                       end)))
        (when role
          (put-text-property position next 'face
                             (alist-get role chat-ui--role-faces)))
        (setq position next)))))

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
       (let ((content-format (plist-get part :content-format)))
         (if (and (eq (plist-get part :work) 'tool-result)
                  (or (eq content-format 'mdp)
                      (equal content-format "mdp")))
             (chat-ui--insert-mdp-detail
              (chat-transcript-part-label part)
              text
              (chat-transcript-part-face part))
           (chat-ui--insert-detail (chat-transcript-part-label part)
                                   text
                                   (chat-transcript-part-face part))))))))

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
  (when-let ((failure (plist-get chat-ui--live-trailers
                                 :permission-failure)))
    (insert
     (propertize
      (concat chat-ui-detail-indent
              (chat-i18n
               'permission-blocked
               "Permission blocked %s: %s"
               (or (plist-get failure :tool) "tool")
               (or (plist-get failure :result-summary) "permission denied"))
              "\n")
      'face 'error)))
  (when (plist-get chat-ui--live-trailers :limit-reached)
    (insert (propertize
             (concat chat-ui-detail-indent
                     (chat-i18n 'tool-loop-stopped
                                "Tool loop stopped after reaching the safety limit.")
                     "\n")
             'face 'chat-transcript-system))))

(defun chat-ui--permission-error-p (event)
  "Return non-nil when tool error EVENT says an operation lacked permission."
  (and (eq (plist-get event :type) 'tool-error)
       (or (memq (plist-get event :error-type)
                 '(permission permission-block access-denied))
           (string-match-p
            (concat "\\(?:access denied\\|permission\\|not writable"
                    "\\|outside .*\\(?:boundary\\|root\\|workspace\\)"
                    "\\|write .*\\(?:blocked\\|denied\\)"
                    "\\|read .*\\(?:blocked\\|denied\\)\\)")
            (downcase (or (plist-get event :result-summary) ""))))))

(defun chat-ui--latest-permission-failure (tool-events)
  "Return the latest permission failure from TOOL-EVENTS, or nil."
  (seq-find #'chat-ui--permission-error-p (reverse tool-events)))

(defcustom chat-ui-live-reasoning-lines 6
  "How many trailing lines of live reasoning to show while it arrives.

The whole of it goes on the record and can be unfolded there.  Only the
tail is shown live, because a reasoning model emits tens of kilobytes and
pasting all of it into the buffer on every chunk is both unreadable and
quadratic."
  :type 'integer
  :group 'chat)

(defun chat-ui--insert-live-reasoning ()
  "Draw the reasoning for the in-flight turn, if any.

Expanded while it is the newest thing happening, and reduced to a single
summary line once answer text starts arriving -- which is folding rule 2
of specs/004 applied to the tail, where there is only ever one reasoning
segment in flight."
  (let ((reasoning (string-trim (or chat-ui--live-reasoning-content "")))
        (answering (not (string-empty-p
                         (string-trim (or chat-ui--live-response-content ""))))))
    (unless (string-empty-p reasoning)
      (let ((label (chat-i18n 'part-thinking "Thinking")))
        (if answering
            (insert (propertize
                     (format "%s%s (%d chars)\n"
                             chat-ui-detail-indent label (length reasoning))
                     'face 'chat-transcript-fold-row))
          (let* ((lines (split-string reasoning "\n"))
                 (shown (if (> (length lines) chat-ui-live-reasoning-lines)
                            (last lines chat-ui-live-reasoning-lines)
                          lines)))
            (insert (propertize (format "%s%s\n" chat-ui-detail-indent label)
                                'face 'chat-transcript-fold-row))
            (dolist (line shown)
              (insert (propertize (concat chat-ui-detail-indent line "\n")
                                  'face 'chat-transcript-thinking)))
            (insert "\n")))))))

(defmacro chat-ui--rewriting-region (start end &rest body)
  "Run BODY, which deletes the region from START to END and rewrites it.

Point is kept where it was, except when it was inside that region: there
is nowhere to put it back, because where it was no longer exists.  The
marker `save-excursion' keeps collapses to the start of the deletion and
re-insertion leaves it there, so the cursor lands at the top of whatever
was redrawn -- which is what put it at the first line of the conversation,
from the bottom of a long reply, every time a step was recorded.  Point
that was inside follows to the end of the rewrite instead, which is where
the reader was looking."
  (declare (indent 2))
  (let ((inside (make-symbol "inside")))
    `(let ((,inside (and (>= (point) ,start) (<= (point) ,end))))
       (save-excursion ,@body)
       (when ,inside
         (goto-char chat-ui--messages-end)))))

(defun chat-ui--insert-pending-model-switch ()
  "Insert the current pending model switch as a transient bottom row."
  (when-let* ((pending (and chat--current-session
                            (chat-model-selection-pending
                             chat--current-session)))
              (provider (alist-get 'provider pending))
              (model (alist-get 'model pending)))
    (insert
     (propertize
      (format "  Pending model switch: %s/%s\n" provider model)
      'face 'shadow
      'chat-ui-transient-model-switch (alist-get 'id pending)))))

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
           (reasoning (or chat-ui--live-reasoning-content ""))
           (last chat-ui--last-render)
           (previous (and last (plist-get last :content)))
           (body (and last (plist-get last :body-start)))
           ;; Reasoning is drawn above the body, so appending is only safe
           ;; while it has not changed.
           (append-p (and previous body
                          (not (string-empty-p content))
                          (equal reasoning (plist-get last :reasoning))
                          (= (plist-get last :live-start)
                             (marker-position chat-ui--live-start))
                          (string-prefix-p previous content)))
           (cut (and append-p (chat-ui--fence-safe-prefix-length previous))))
      (chat-ui--rewriting-region chat-ui--live-start chat-ui--messages-end
        (if append-p
            (progn
              (goto-char (+ body cut))
              (delete-region (point) chat-ui--messages-end)
              ;; The unfinished tail rather than the delta.  Appending only
              ;; what was new was cheaper, but it meant the block had
              ;; already been drawn as prose by the time the rest of it
              ;; arrived, so a table never got its columns and a list item
              ;; never got its bullet.  The tail is bounded by where the
              ;; last finished block ended, and degrades when even that is
              ;; long.
              (insert (chat-markdown-render-tail (substring content cut)))
              (insert "\n\n"))
          (goto-char chat-ui--live-start)
          (delete-region chat-ui--live-start chat-ui--messages-end)
          (setq body nil)
          (chat-ui--insert-live-reasoning)
          (unless (string-empty-p content)
            (chat-ui--insert-role-label 'assistant)
            (setq body (point))
            (chat-ui--insert-formatted-response content)
            (insert "\n\n")))
        (chat-ui--insert-live-trailers)
        (chat-ui--insert-pending-model-switch)
        (set-marker chat-ui--messages-end (point)))
      (setq chat-ui--last-render
            (and body
                 (list :content content
                       :reasoning reasoning
                       :body-start body
                       :live-start (marker-position chat-ui--live-start))))
      (chat-ui--repair-presentation-invariants))))

(defun chat-ui--redraw-conversation ()
  "Redraw the whole conversation from the session record.

The record is the only source: nothing the display has drawn before is
consulted, so a message appended, a fold toggled and a session reopened
all produce the same screen."
  (when (and chat--current-session
             chat-ui--conversation-start
             chat-ui--messages-end)
    (let ((inhibit-read-only t))
      (chat-ui--rewriting-region chat-ui--conversation-start
          chat-ui--messages-end
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

(defconst chat-ui--input-prompt-properties
  '(chat-ui-prompt t read-only t front-sticky (read-only) rear-nonsticky t)
  "Properties every drawn prompt carries.

Read-only because the prompt sits inside the region the reader types in,
where an unprotected one is a single backspace from being gone -- which
is what every shell in Emacs concluded too.  Front-sticky so nothing can
be typed into it from the left, rear-nonsticky so what is typed after it
inherits neither the protection nor the face.

Tagged with `chat-ui-prompt' so it can be found again by what it is.
Measuring back from the input marker instead would fail in the one case
that matters: a prompt that has already been partly eaten.")

(defface chat-ui-prompt-model
  '((t :inherit shadow))
  "Face for the model name in the input prompt.

Quiet, because it is context rather than a warning; the coloured glyph
beside it is what the eye lands on."
  :group 'chat-ui)

(defcustom chat-ui-prompt-model-width 24
  "Width the model name in the prompt is truncated to.

A provider's model names run long enough to push the cursor across the
window -- `grok-4-fast-non-reasoning' is twenty-five columns on its own.
Measured in columns rather than characters, so a name with CJK in it is
not counted at half its width."
  :type 'integer
  :group 'chat-ui)

(defvar chat-ui-prompt-model-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'chat-ui-switch-model)
    map)
  "Keymap on the model segment of the prompt.

Carries the mouse binding only.  Everything else falls through to the
buffer, because point can be moved onto the prompt and a keymap there
that swallowed ordinary keys would be a trap.")

(defvar chat-ui-work-shelf-prompt-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'chat-ui-toggle-work-shelf)
    map)
  "Mouse-only keymap on the input work-shelf disclosure glyph.")

(defvar chat-ui-work-shelf-section-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'chat-ui-toggle-work-shelf-section)
    map)
  "Mouse-only keymap on an input work-shelf section glyph.")

(defun chat-ui--prompt-segment (text &rest properties)
  "Return TEXT as a prompt segment carrying PROPERTIES.

Every segment carries the prompt's own properties as well, so the whole
prompt is one protected, findable run however many pieces it is built
from."
  (apply #'propertize text
         (append properties chat-ui--input-prompt-properties)))

(defun chat-ui--prompt-mark (glyph face &optional image)
  "Return GLYPH and a space as a prompt segment in FACE, or \"\" if unusable.

An undisplayable glyph is dropped rather than drawn: a hollow box carries
nothing, takes a column anyway, and reads as a broken program.

FACE may be nil, and then none is set rather than `default' being set:
the two are not the same, and the second would stop a provider without a
known brand colour from inheriting the text around it.

IMAGE, when given, is shown over GLYPH rather than instead of it: the
glyph stays the text in the buffer and only its pixels change.  That is
what keeps this safe to put in the prompt.  The prompt's width is
measured, its start and end are computed, and the input area begins after
it; an image inserted as its own character would change all three, while
an image displayed over one changes none of them.  It also means a
terminal frame, a build without librsvg, and a yank of the prompt line
each get the glyph, without a second code path written to give it to
them.

The image covers the glyph and the trailing space is a segment of its
own, because one `display' property spanning a run draws one image for
the whole run -- put on both, it would replace the space as well and set
the badge directly against the model name."
  (if (chat-mark-displayable-p glyph)
      (concat
       (apply #'chat-ui--prompt-segment
              glyph
              (append (when face (list 'face face))
                      (when image (list 'display image))))
       (apply #'chat-ui--prompt-segment
              " "
              (when face (list 'face face))))
    ""))

(defun chat-ui--prompt-model-segment ()
  "Return the segment naming the model prepared for the next input.

The model named is the one the request will actually carry, not the
provider symbol and not its display name: a prompt that names something
other than what is about to be used stops preventing mistakes and starts
causing them.

Clickable only when there is more than one provider to choose from.  A
`mouse-face' over a menu of one promises a choice that does not exist."
  (let* ((target (and chat--current-session
                      (chat-model-selection-prepared chat--current-session)))
         (provider (and target (chat-model-target-provider target)))
         (vendor (and provider (chat-llm-provider-vendor provider)))
         (mark-provider (or vendor provider))
         (config (and provider (chat-llm-get-provider-config provider)))
         (display-name (plist-get config :name))
         (model (or (and target (chat-model-target-model target))
                    (and provider (symbol-name provider))
                    ""))
         (dirty (and chat--current-session
                     (chat-model-selection-dirty-p chat--current-session)))
         (mark (chat-mark-for-provider mark-provider display-name))
         (switchable (> (chat-ui--model-choice-count) 1))
         (shown (truncate-string-to-width
                 (concat model (if dirty " (*)" ""))
                 chat-ui-prompt-model-width nil nil "\u2026"))
         (help (if switchable
                   (if dirty
                       (format "%s -- prepared; mouse-1 to change" model)
                     (chat-i18n 'prompt-model-switch
                                "%s -- mouse-1 to switch model" model))
                 model)))
    (concat
     (chat-ui--prompt-mark
      (car mark) (cdr mark)
      (chat-mark-provider-image mark-provider (car mark) (cdr mark)))
     (apply #'chat-ui--prompt-segment
            shown
            'face 'chat-ui-prompt-model
            'help-echo help
            (when switchable
              (list 'keymap chat-ui-prompt-model-map
                    'mouse-face 'highlight))))))

(defun chat-ui--work-shelf-prompt-segment ()
  "Return the stable outer disclosure control for the input work shelf."
  (concat
   (chat-ui--prompt-segment
    (if chat-ui--work-shelf-open "▴" "▸")
    'face 'shadow
    'keymap chat-ui-work-shelf-prompt-map
    'mouse-face 'highlight
    'help-echo (if chat-ui--work-shelf-open
                   "mouse-1 to close the work shelf"
                 "mouse-1 to open the work shelf")
    'rear-nonsticky '(keymap mouse-face help-echo))
   (chat-ui--prompt-segment " ")))

(defun chat-ui--input-prompt ()
  "Return the text that opens the input area.

Says what pressing RET will do.  The status line says it too, but it is
at the top of a buffer that scrolls and the cursor is down here: a shell
that looks like a chat box is how a question ends up being run as a
command, and a window that looks like one provider is how a question ends
up at another.

A claimed line names the command; an unclaimed one names the provider and
model, because that is what it will reach.  Neither shows the other: the
model is not what a shell line is about, and the baseline command has
never been announced by name."
  (let* ((claimed (chat-ui-default-command-claimed-p))
         (command (chat-ui-default-command))
         (repl (and (equal command "repl")
                    chat--current-session
                    (chat-repl-for-chat-session chat--current-session))))
    (concat
     (chat-ui--work-shelf-prompt-segment)
     (chat-ui--pending-attachments-prompt)
     (if (not claimed)
         (concat (chat-ui--prompt-model-segment)
                 (chat-ui--prompt-send-mode-segment)
                 (chat-ui--prompt-segment "> "))
       (let ((mark (chat-mark-for-mode command)))
         (concat
          (chat-ui--prompt-mark (car mark) (cdr mark))
          (chat-ui--prompt-segment
           (if repl
               (format "repl:%s#%d> "
                       (chat-repl-session-adapter-id repl)
                       (chat-repl-session-generation repl))
             (format "%s%s> "
                     (chat-ui--display-command-name command)
                     (chat-ui--prompt-send-mode-text)))
           'face 'chat-ui-claimed-prompt)))))))

(defun chat-ui--prompt-send-mode-text ()
  "Return how the chosen send mode reads in the prompt, or \"\".

Shown only when it is not the default, and only when something is
waiting.  A mode that is in force silently is a mode that cannot explain
why the same keystroke inserted this time and queued last time; a mode
shown always is clutter on a line most people never change."
  (let ((mode (chat-ui-send-mode))
        (waiting (length chat-ui--queued-sends)))
    (cond
     ((> waiting 0) (format " %s:%d" (chat-ui--send-mode-name mode) waiting))
     ((eq mode chat-send-default-mode) "")
     (t (format " %s" (chat-ui--send-mode-name mode))))))

(defun chat-ui--prompt-send-mode-segment ()
  "Return the send mode as a prompt segment, or \"\" when there is none."
  (let ((text (chat-ui--prompt-send-mode-text)))
    (if (string-empty-p text)
        ""
      (chat-ui--prompt-segment text 'face 'chat-ui-prompt-model))))

(defun chat-ui--input-prompt-bounds ()
  "Return the extent of the drawn prompt as a cons, or nil when none is drawn."
  (let ((end (and (markerp chat-ui--input-overlay)
                  (marker-position chat-ui--input-overlay))))
    (when (and end
               (> end (point-min))
               (get-text-property (1- end) 'chat-ui-prompt))
      (cons (or (previous-single-property-change end 'chat-ui-prompt)
                (point-min))
            end))))

(defun chat-ui--render-input-prompt ()
  "Draw the input prompt, keeping the input marker just after it.

Returns without touching the buffer when the prompt already on screen is
the one wanted, which is what makes this cheap enough to call on every
send.  Calling it there is the point: the prompt is ordinary buffer text
and nothing else on the send path draws it, so a prompt that got eaten
used to stay eaten for the life of the buffer.  Now it costs one RET.

Draws at the marker when no prompt is found rather than declining to, so
the case where the whole prompt is gone recovers as well as the case
where some of it is."
  (when (and (markerp chat-ui--input-overlay)
             (marker-position chat-ui--input-overlay))
    (let* ((wanted (chat-ui--input-prompt))
           (bounds (chat-ui--input-prompt-bounds))
           (drawn (and bounds (buffer-substring (car bounds) (cdr bounds)))))
      (unless (equal-including-properties drawn wanted)
        (let* ((inhibit-read-only t)
               (start (or (car bounds)
                          (marker-position chat-ui--input-overlay)))
               ;; How far into the input point sat, or nil when it sat
               ;; above the input and is none of this function's business.
               ;;
               ;; `save-excursion' cannot answer this.  It restores point
               ;; through a marker, and a marker at the start of a region
               ;; that is deleted and rewritten comes back on the far side
               ;; of the new text -- so the cursor landed in front of the
               ;; prompt every time a command claimed or released plain
               ;; input, and what was typed next went in front of it too.
               (offset (and (chat-ui--point-in-input-p)
                            (- (point)
                               (marker-position chat-ui--input-overlay)))))
          (save-excursion
            (when bounds
              (delete-region (car bounds) (cdr bounds)))
            (goto-char start)
            (insert wanted)
            (set-marker chat-ui--input-overlay (point)))
          (when offset
            (goto-char (+ (marker-position chat-ui--input-overlay)
                          offset))))))))

(defun chat-ui--repair-presentation-invariants ()
  "Restore durable display properties after a live or full redraw.

The input prompt and role colours are presentation state, not session
data.  A completion UI, a third-party display pass or an interrupted
rewrite may remove that state without removing the underlying input and
messages.  Repair it from semantic markers after every response redraw so
the buffer never stays half-usable until it is reopened."
  (let ((inhibit-read-only t))
    (chat-ui--render-input-prompt)
    (when (and (markerp chat-ui--conversation-start)
               (markerp chat-ui--messages-end))
      (chat-ui--repair-role-faces
       (marker-position chat-ui--conversation-start)
       (marker-position chat-ui--messages-end)))))

(defun chat-ui--repair-visible-presentation ()
  "Repair the prompt and visible role labels after an interactive command.

Scrolling can expose text whose presentation properties were cleared by
another display pass.  Limit role repair to visible windows so typing in a
long transcript never scans the whole conversation."
  (when (derived-mode-p 'chat-mode)
    (let ((inhibit-read-only t))
      (with-silent-modifications
        (chat-ui--render-input-prompt)
        (when (and (markerp chat-ui--conversation-start)
                   (markerp chat-ui--messages-end))
          (dolist (window (get-buffer-window-list (current-buffer) nil t))
            (when (window-live-p window)
              (chat-ui--repair-role-faces
               (max (marker-position chat-ui--conversation-start)
                    (window-start window))
               (min (marker-position chat-ui--messages-end)
                    (or (window-end window t) (point-max)))))))))))

(defun chat-ui--setup-input-area ()
  "Setup the input area at bottom of buffer."
  (goto-char (point-max))
  (setq chat-ui--work-shelf-start (copy-marker (point) nil))
  (setq chat-ui--work-shelf-end (copy-marker (point) t))
  (chat-ui--render-work-shelf)
  ;; `chat-ui--render-work-shelf' restores its normal live-tail semantics;
  ;; initialization still has to insert the divider and prompt at this point.
  (set-marker-insertion-type chat-ui--work-shelf-start nil)
  (set-marker-insertion-type chat-ui--work-shelf-end nil)
  (insert (propertize "───\n" 'face 'shadow))
  (insert (chat-ui--input-prompt))
  (setq chat-ui--input-overlay (point-marker))
  ;; Only future live output shares the shelf boundary.  Both ends must
  ;; advance together while the shelf is collapsed or its region reverses.
  (set-marker-insertion-type chat-ui--work-shelf-start t)
  (set-marker-insertion-type chat-ui--work-shelf-end t))

(defun chat-ui--work-shelf-section-expanded-p (section-id)
  "Return non-nil when SECTION-ID is expanded in this buffer."
  (and (hash-table-p chat-ui--work-shelf-expanded-sections)
       (gethash section-id chat-ui--work-shelf-expanded-sections)))

(defun chat-ui--insert-work-shelf-section (section)
  "Insert one work-shelf SECTION at point."
  (let* ((section-id (chat-work-shelf-section-id section))
         (expanded (chat-ui--work-shelf-section-expanded-p section-id))
         (section-start (point))
         (glyph-start section-start))
    (insert (if expanded "▾" "▸"))
    (add-text-properties
     glyph-start (point)
     `(face shadow
       keymap ,chat-ui-work-shelf-section-map
       mouse-face highlight
       help-echo ,(if expanded
                      "mouse-1 to collapse this section"
                    "mouse-1 to expand this section")
       chat-work-shelf-section ,section-id
       rear-nonsticky
       (keymap mouse-face help-echo chat-work-shelf-section)))
    (insert " " (chat-work-shelf-section-summary section) "\n")
    (when expanded
      (dolist (line (chat-work-shelf-section-detail-lines section))
        (insert "  " line "\n")))
    (add-text-properties
     section-start (point)
     `(chat-work-shelf-section-owner ,section-id))
    (add-text-properties
     (1- (point)) (point)
     '(rear-nonsticky (chat-work-shelf-section-owner)))))

(defun chat-ui--work-shelf-section-region (section-id)
  "Return the rendered region owned by SECTION-ID, or nil."
  (let ((start
         (text-property-any
          chat-ui--work-shelf-start chat-ui--work-shelf-end
          'chat-work-shelf-section-owner section-id)))
    (when start
      (cons start
            (or (next-single-property-change
                 start 'chat-work-shelf-section-owner nil
                 chat-ui--work-shelf-end)
                chat-ui--work-shelf-end)))))

(defun chat-ui--call-preserving-work-shelf-anchors (function)
  "Call FUNCTION while preserving point and visible window starts."
  (let ((point-anchor (copy-marker (point) t))
        (window-anchors
         (mapcar (lambda (window)
                   (cons window (copy-marker (window-start window) nil)))
                 (get-buffer-window-list (current-buffer) nil t))))
    (unwind-protect
        (funcall function)
      (when (marker-position point-anchor)
        (goto-char point-anchor))
      (set-marker point-anchor nil)
      (dolist (entry window-anchors)
        (when (and (window-live-p (car entry))
                   (marker-position (cdr entry)))
          (set-window-start (car entry) (cdr entry) t))
        (set-marker (cdr entry) nil)))))

(defun chat-ui--render-work-shelf ()
  "Render the bounded work shelf without moving point or visible windows."
  (when (and (markerp chat-ui--work-shelf-start)
             (markerp chat-ui--work-shelf-end)
             (marker-position chat-ui--work-shelf-start)
             (marker-position chat-ui--work-shelf-end))
    (let* ((sections
            (and chat-ui--work-shelf-open
                 chat--current-session
                 (chat-work-shelf-project chat--current-session))))
      (chat-ui--call-preserving-work-shelf-anchors
       (lambda ()
         (let ((inhibit-read-only t)
               (inhibit-modification-hooks t))
           ;; During shelf insertion the start must stay before its own text;
           ;; between renders it advances across live transcript insertion.
           (set-marker-insertion-type chat-ui--work-shelf-start nil)
           (set-marker-insertion-type chat-ui--work-shelf-end t)
           (unwind-protect
               (progn
                 (goto-char chat-ui--work-shelf-start)
                 (delete-region chat-ui--work-shelf-start
                                chat-ui--work-shelf-end)
                 (dolist (section sections)
                   (chat-ui--insert-work-shelf-section section))
                 (set-marker chat-ui--work-shelf-end (point))
                 (setq chat-ui--work-shelf-section-ids
                       (mapcar #'chat-work-shelf-section-id sections)))
             (set-marker-insertion-type chat-ui--work-shelf-start t)
             (set-marker-insertion-type chat-ui--work-shelf-end t))))))))

(defun chat-ui--refresh-work-shelf-sections (event)
  "Incrementally refresh only work-shelf sections invalidated by EVENT."
  (when (and chat-ui--work-shelf-open chat--current-session)
    (let* ((sections (chat-work-shelf-project chat--current-session))
           (section-ids (mapcar #'chat-work-shelf-section-id sections))
           (affected (chat-work-shelf-provider-ids-for-event event)))
      (if (not (equal section-ids chat-ui--work-shelf-section-ids))
          (chat-ui--render-work-shelf)
        (chat-ui--call-preserving-work-shelf-anchors
         (lambda ()
           (let ((inhibit-read-only t)
                 (inhibit-modification-hooks t)
                 (shelf-end (copy-marker chat-ui--work-shelf-end t)))
             (unwind-protect
                 (dolist (section sections)
                   (when (memq (chat-work-shelf-section-id section) affected)
                     (when-let ((region
                                 (chat-ui--work-shelf-section-region
                                  (chat-work-shelf-section-id section))))
                       (goto-char (car region))
                       (delete-region (car region) (cdr region))
                       (chat-ui--insert-work-shelf-section section))))
               (set-marker chat-ui--work-shelf-end shelf-end)
               (set-marker shelf-end nil)))))))))

(defun chat-ui-toggle-work-shelf (&optional _event)
  "Open or close the input work shelf without moving the input point."
  (interactive (list last-nonmenu-event))
  (setq chat-ui--work-shelf-open (not chat-ui--work-shelf-open))
  (chat-ui--render-work-shelf)
  (chat-ui--render-input-prompt))

(defun chat-ui--work-shelf-section-at-event (event)
  "Return the work-shelf section ID under mouse EVENT, if any."
  (when (and event (mouse-event-p event))
    (let ((position (posn-point (event-start event))))
      (when (integer-or-marker-p position)
        (get-text-property position 'chat-work-shelf-section)))))

(defun chat-ui-toggle-work-shelf-section (&optional event section-id)
  "Toggle SECTION-ID, or the section under mouse EVENT, without moving point."
  (interactive (list last-nonmenu-event nil))
  (let ((id (or section-id (chat-ui--work-shelf-section-at-event event))))
    (when id
      (unless (hash-table-p chat-ui--work-shelf-expanded-sections)
        (setq chat-ui--work-shelf-expanded-sections
              (make-hash-table :test 'eq)))
      (puthash id
               (not (gethash id chat-ui--work-shelf-expanded-sections))
               chat-ui--work-shelf-expanded-sections)
      (chat-ui--render-work-shelf))))

(defun chat-ui--observe-work-shelf-event (event)
  "Refresh work shelves whose session is affected by EVENT."
  (when (chat-work-shelf-event-relevant-p event)
    (dolist (buffer (buffer-list))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (and chat--current-session
                     (markerp chat-ui--work-shelf-start)
                     (equal (chat-session-id chat--current-session)
                            (chat-event-session-id event)))
            (chat-ui--refresh-work-shelf-sections event)))))))

(defun chat-ui--observe-runtime-event (event)
  "Project lifecycle EVENT into chat buffers for the same session."
  (let ((phase
         (unless (chat-work-shelf-event-relevant-p event)
           (chat-runtime-status-phase-for-event
            (chat-event-type event) (chat-event-payload event)))))
    (when phase
      (dolist (buffer (buffer-list))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and chat--current-session
                       (equal (chat-session-id chat--current-session)
                              (chat-event-session-id event)))
              (chat-ui--project-runtime-event
               (chat-event-type event) (chat-event-payload event)))))))))

;; ------------------------------------------------------------------
;; Message Sending
;; ------------------------------------------------------------------

;; ------------------------------------------------------------------
;; Where a send spends its time
;; ------------------------------------------------------------------
;;
;; Nothing on the send path logged anything before the request was
;; prepared, so a report of "RET hitches" had no evidence in it and had to
;; be chased by reproducing the path elsewhere.  That does not work: the
;; costs that matter here live in the display and in whatever hooks the
;; reader's configuration has installed, and neither exists in batch mode
;; or in an `emacs -Q'.  So the path measures itself, in the session where
;; the complaint happens, and says so in one line.
;;
;; The clock itself lives in `chat-log' rather than here, because the marks
;; that named the two costs worth fixing came from below this layer: a
;; phase measured only at the door tells you the room is slow, not which
;; piece of furniture.

(defalias 'chat-ui--clock-start #'chat-log-timing-start)
(defalias 'chat-ui--clock #'chat-log-timing-mark)

(defun chat-ui--clock-report (what)
  "Log the marks collected for this send, described as WHAT."
  (chat-log-timing-report
   what
   (format "buffer %dk, %d messages, undo %s, %d post-command hooks, %d change hooks"
           (/ (buffer-size) 1024)
           (if chat--current-session
               (length (chat-session-messages chat--current-session))
             0)
           (cond ((eq buffer-undo-list t) "off")
                 ((listp buffer-undo-list) (format "%d" (length buffer-undo-list)))
                 (t "?"))
           (length (default-value 'post-command-hook))
           (length (if (listp after-change-functions) after-change-functions nil)))))

(defun chat-ui-send-message ()
  "Act on the input area, either as a command or as a message."
  (interactive)
  (chat-input-hint-clear)
  (when chat--current-session
    (chat-ui--clock-start (chat-session-id chat--current-session))
    ;; Before reading the input rather than after clearing it, so a prompt
    ;; that went missing is back on screen at the moment the reader looks
    ;; for it.  Reading the input afterwards is safe: repairing the prompt
    ;; moves the marker with the typed text, not through it.
    (chat-ui--render-input-prompt)
    (chat-ui--clock "prompt")
    (let* ((input-start (marker-position chat-ui--input-overlay))
           (input-end (point-max))
           (content (string-trim (buffer-substring-no-properties input-start input-end)))
           (command (chat-command-parse content))
           (control (chat-ui--control-command command))
           (chat-ui--send-content-parts
            (copy-sequence chat-ui--pending-content-parts))
           (chat-ui--send-content-parts-consumed nil))
      ;; Anything actually sent becomes recallable, commands included --
      ;; that is what a shell does, and a mistyped command is exactly what
      ;; one wants back.  Sending also ends any walk in progress, so the
      ;; next `M-p' starts from the top.
      (unless (eq (plist-get command :kind) 'empty)
        (chat-input-history-add content)
        (chat-input-history-reset-position))
      (chat-ui--clock "history")
      (cond
       ((and (eq (plist-get command :kind) 'empty)
             chat-ui--send-content-parts)
        (chat-ui--clear-input input-start input-end)
        (chat-ui--send-in-mode "" (chat-ui-send-mode)
                               chat-ui--send-content-parts))
       ((eq (plist-get command :kind) 'empty)
        (message "%s" (chat-i18n 'empty-message "Cannot send empty message")))
       (control
        (chat-ui--clear-input input-start input-end)
        (funcall control (plist-get command :arg))
        ;; While-busy commands bypass `chat-ui--dispatch-command', so the
        ;; default-command effect has to be applied here as well: an
        ;; explicit `/send' hands plain input back to the model, and a
        ;; `/stage' claims it, even while a run holds the surface.
        (chat-ui--record-command-usage
         (chat-ui--command-canonical-name (plist-get command :name)))
        (chat-ui--note-command-default command))
       ;; Through the send path rather than straight to steering: an
       ;; explicit `/send queue ...' during a run has to be read as a
       ;; command, and this branch used to swallow it as prose.
       ((chat-agent-active-p chat-ui--active-agent-run)
        (chat-ui--clear-input input-start input-end)
        (if (eq (plist-get command :kind) 'slash)
            (chat-ui--dispatch-command command)
          (let ((chat-ui--input-was-typed t))
            (chat-ui--send-in-mode (chat-ui--command-message-text command)
                                   (chat-ui-send-mode)
                                   chat-ui--send-content-parts))))
       ((chat-ui--response-active-p)
        (message "%s" (chat-i18n 'request-in-progress
                          "A response is already in progress. Cancel it before sending another message.")))
       (t
        (chat-ui--clear-input input-start input-end)
        (chat-ui--dispatch-command command)))
      (when chat-ui--send-content-parts-consumed
        (setq chat-ui--pending-content-parts nil)
        (chat-ui--refresh-attachment-prompt)))))

(defun chat-ui--clear-input (input-start input-end)
  "Remove the text between INPUT-START and INPUT-END from the input area."
  (delete-region input-start input-end)
  (goto-char input-start))

;; ------------------------------------------------------------------
;; Input history
;; ------------------------------------------------------------------

(defun chat-ui--input-text ()
  "Return what is currently typed in the input area."
  (if chat-ui--input-overlay
      (buffer-substring-no-properties
       (marker-position chat-ui--input-overlay) (point-max))
    ""))

(defun chat-ui--set-input-text (text)
  "Replace the input area with TEXT and leave point at its end."
  (when chat-ui--input-overlay
    (let ((start (marker-position chat-ui--input-overlay)))
      (delete-region start (point-max))
      (goto-char start)
      (insert (or text "")))))

(defun chat-ui-previous-input ()
  "Recall the previous input, keeping any unsent draft."
  (interactive)
  (chat-input-history-walk 1 #'chat-ui--input-text #'chat-ui--set-input-text))

(defun chat-ui-next-input ()
  "Recall the next input, restoring the draft past the newest entry."
  (interactive)
  (chat-input-history-walk -1 #'chat-ui--input-text #'chat-ui--set-input-text))

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
  (let* ((request (downcase (chat-command-fold-name arg)))
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

(defun chat-ui--goal-report (goal)
  "Return a compact user-facing report for GOAL."
  (if (null goal)
      "Goal: none. Create one with /goal OBJECTIVE :: STOPPING CONDITION"
    (let* ((projection (chat-goal-ui-projection chat--current-session))
           (remaining (plist-get projection :remaining)))
      (string-join
       (delq nil
             (list
              (format "Goal [%s] revision %d: %s"
                      (chat-goal-status goal) (chat-goal-revision goal)
                      (plist-get projection :objective))
              (and (plist-get projection :stopping-condition)
                   (format "Stopping condition: %s"
                           (plist-get projection :stopping-condition)))
              (and (plist-get projection :checkpoint)
                   (format "Current checkpoint: %s"
                           (plist-get projection :checkpoint)))
              (and (plist-get projection :needs-attention)
                   (format "Needs attention: %s"
                           (plist-get projection :needs-attention)))
              (and remaining
                   (format "Remaining: %s"
                           (mapconcat #'identity remaining "; ")))
              (and (plist-get projection :blocker-reason)
                   (format "Blocked: %s; resume when: %s"
                           (plist-get projection :blocker-reason)
                           (plist-get projection :unblock-condition)))))
       "\n"))))

(defun chat-ui--command-goal (arg)
  "Inspect or control the selected Goal according to ARG."
  (let* ((session chat--current-session)
         (request (string-trim (or arg "")))
         (current (and session (chat-goal-current session))))
    (condition-case err
        (cond
         ((null session)
          (user-error "No active chat session"))
         ((string-empty-p request)
          (chat-ui--insert-system-message (chat-ui--goal-report current)))
         ((member (downcase request) '("pause" "resume" "cancel" "clear"))
          (unless current
            (user-error "No selected Goal"))
          (pcase (downcase request)
            ("pause"
             (setq current
                   (chat-goal-pause session (chat-goal-id current)
                                    (chat-goal-revision current))))
            ("resume"
             (setq current
                   (chat-goal-resume session (chat-goal-id current)
                                     (chat-goal-revision current))))
            ("cancel"
             (setq current
                   (chat-goal-cancel session (chat-goal-id current)
                                     (chat-goal-revision current))))
            ("clear"
             (chat-goal-clear session)
             (setq current nil)))
          (chat-ui--insert-system-message (chat-ui--goal-report current)))
         ((string-match
           "\\`\\(.+?\\)[[:space:]]+::[[:space:]]+\\(.+\\)\\'" request)
          (let ((objective (string-trim (match-string 1 request)))
                (stopping (string-trim (match-string 2 request))))
            (setq current
                  (chat-goal-create
                   session objective
                   `(((id . "outcome") (title . ,stopping)))
                   stopping
                   :sources '("slash-command")
                   :project-root (chat-session-working-directory session)))
            (chat-ui--insert-system-message (chat-ui--goal-report current))))
         (t
          (chat-ui--insert-system-message
           "Usage: /goal OBJECTIVE :: STOPPING CONDITION | pause | resume | cancel | clear")))
      ((chat-goal-invalid chat-goal-transition-invalid chat-goal-scope-mismatch
        chat-goal-stale-revision chat-goal-evidence-invalid user-error)
       (chat-ui--insert-system-message (error-message-string err))))))

(defun chat-ui--plan-mode-report (state)
  "Return a compact user-facing report for planning STATE."
  (if (null state)
      "Plan Mode: off. Use /plan on to start read-only research."
    (format "Plan Mode [%s] revision %d: %s%s"
            (chat-plan-mode-state-status state)
            (chat-plan-mode-state-revision state)
            (if (chat-plan-mode-state-enabled state) "read-only" "off")
            (if (chat-plan-mode-state-plan-id state)
                (format "; plan %s" (chat-plan-mode-state-plan-id state))
              ""))))

(defun chat-ui--command-plan (arg)
  "Inspect or control independent Plan Mode according to ARG."
  (let* ((session chat--current-session)
         (request (string-trim (or arg "")))
         (parts (split-string request "[[:space:]]+" t))
         (action (downcase (or (car parts) "")))
         (state (and session (chat-plan-mode-current session))))
    (condition-case err
        (cond
         ((null session)
          (user-error "No active chat session"))
         ((string-empty-p request)
          (chat-ui--insert-system-message (chat-ui--plan-mode-report state)))
         ((member action '("on" "start" "enter"))
          (setq state (chat-plan-mode-enter session))
          (chat-ui--insert-system-message (chat-ui--plan-mode-report state)))
         ((equal action "approve")
          (unless state (user-error "Plan Mode is inactive"))
          (setq state
                (chat-plan-mode-approve
                 session (chat-plan-mode-state-revision state)))
          (chat-ui--insert-system-message (chat-ui--plan-mode-report state)))
         ((equal action "reject")
          (unless state (user-error "Plan Mode is inactive"))
          (let ((feedback
                 (string-trim
                  (substring request (min (length request)
                                          (length (car parts)))))))
            (setq state
                  (chat-plan-mode-reject
                   session (chat-plan-mode-state-revision state) feedback))
            (chat-ui--insert-system-message (chat-ui--plan-mode-report state))))
         ((member action '("off" "cancel" "exit"))
          (unless state (user-error "Plan Mode is inactive"))
          (setq state
                (chat-plan-mode-cancel
                 session (chat-plan-mode-state-revision state)))
          (chat-ui--insert-system-message (chat-ui--plan-mode-report state)))
         (t
          (chat-ui--insert-system-message
           "Usage: /plan on | approve | reject FEEDBACK | cancel")))
      ((chat-plan-mode-invalid chat-plan-mode-stale-revision user-error)
       (chat-ui--insert-system-message (error-message-string err))))))

(defun chat-ui-enter-plan-mode ()
  "Enter read-only Plan Mode through the same path as `/plan on'."
  (interactive)
  (chat-ui--command-plan "on"))

(defun chat-ui--command-approve (arg)
  "Report or change the approval mode according to ARG.

Named `approve' rather than `auto' because `/auto' already says which
command plain input runs through.  Two settings under one word would be
two settings nobody can talk about."
  (let* ((session (and (boundp 'chat--current-session) chat--current-session))
         (request (downcase (string-trim (or arg "")))))
    (cond
     ((string-empty-p request)
      (chat-ui--insert-system-message
       (concat (chat-approval-mode-report session)
               ". "
               (chat-i18n 'approval-usage
                          "/approve manual | guarded | dangerous"))))
     ;; `chat-approval-normalize-mode' rather than a list of names, so
     ;; `/approve auto' keeps working for anyone whose fingers learned it
     ;; and for notes written before the rename.
     ((chat-approval-normalize-mode request)
      (let ((mode (chat-approval-normalize-mode request)))
        (condition-case err
            (progn
              (chat-approval-set-mode mode session)
              (chat-ui--render-default-command)
              (chat-ui--insert-system-message
               (if (eq mode 'dangerous)
                   (chat-i18n 'approval-dangerous-on
                              "Approval: DANGEROUS -- every tool call runs unasked, and the command gate is off.")
                 (chat-approval-mode-report session))))
          (user-error
           (chat-ui--insert-system-message (error-message-string err))))))
     (t
      (chat-ui--insert-system-message
       (chat-i18n 'approval-unknown-mode
                  "Unknown approval mode `%s'. One of: manual, guarded, dangerous."
                  request))))))

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
       (chat-ui--record-command-usage "cmd")
       (chat-ui--note-command-default command))
      ('shell-repeat
       (chat-ui--repeat-shell-command)
       (chat-ui--record-command-usage "cmd")
       (chat-ui--note-command-default command))
      ('query
       (chat-ui--command-quick arg)
       (chat-ui--record-command-usage "quick")
       (chat-ui--note-command-default command))
      ('slash
       (let ((handler (chat-ui--command-handler (plist-get command :name))))
         (if handler
             (progn
               (funcall handler arg)
               (chat-ui--record-command-usage
                (chat-ui--command-canonical-name
                 (plist-get command :name)))
               (chat-ui--note-command-default command))
           ;; An unknown name is not an error: the model may still make
           ;; sense of it, and refusing would break slash-prefixed prose.
           (chat-ui--send-user-message (plist-get command :text)))))
      ('literal (chat-ui--send-user-message arg))
      ('note (chat-ui--dispatch-plain-input (plist-get command :text)))
      (_ (chat-ui--send-user-message (plist-get command :text))))))

(defun chat-ui--dispatch-plain-input (text)
  "Run TEXT through the command that currently holds plain input."
  (let ((handler (chat-ui--command-handler (chat-ui-default-command)))
        ;; Marked so that the handler knows the user did not name it, and
        ;; therefore does not read the first word as an argument to it.
        (chat-ui--input-was-typed t))
    (if handler
        (funcall handler text)
      (chat-ui--send-user-message text))))

(defun chat-ui--prompt-event (type message &optional queue-length mode)
  "Return lifecycle TYPE for MESSAGE with QUEUE-LENGTH and MODE facts."
  (chat-event-create
   :type type
   :session-id (and chat--current-session
                    (chat-session-id chat--current-session))
   :source 'ui
   :payload
   (delq nil
         (list
          (when (chat-message-p message)
            (cons 'message_id (chat-message-id message)))
          (cons 'chars
                (length (if (chat-message-p message)
                            (or (chat-message-content message) "")
                          (or message ""))))
          (when queue-length (cons 'queue_length queue-length))
          (when mode (cons 'mode (format "%s" mode)))))
   :subject message))

(defun chat-ui--send-user-message (content &optional content-parts metadata model-target)
  "Record CONTENT and CONTENT-PARTS as a user message, then respond.
METADATA records provenance supplied by the input surface.  MODEL-TARGET
is the immutable target captured when the input was submitted."
  (let* ((model-target (or model-target chat-ui--submitted-model-target
                           (chat-model-selection-prepared
                            chat--current-session)))
         (metadata (copy-tree metadata))
         (metadata (plist-put metadata :model-provider
                              (chat-model-target-provider model-target)))
         (metadata (plist-put metadata :model-name
                              (chat-model-target-model model-target)))
         (attachments (or content-parts chat-ui--send-content-parts))
         (parts (chat-content-parts-with-text attachments content)))
    (if (and (string-empty-p content) (null parts))
        (message "%s" (chat-i18n 'empty-message "Cannot send empty message"))
      (if (and (null attachments)
               (chat-tool-forge-ai--tool-request-p content))
          (chat-ui--handle-tool-creation content)
        (let* ((user-msg (chat-ui--stamp-user-message
                          (make-chat-message
                           :id (chat-session-new-message-id)
                           :role :user
                           :content content
                           :content-parts parts
                           :metadata metadata
                           :timestamp (current-time))))
               (event (chat-ui--prompt-event
                       'user-prompt-submitted user-msg))
               (outcome (chat-event-publish event))
               (user-msg (chat-event-subject event)))
          (if (not (and (chat-event-allowed-p outcome)
                        (chat-message-p user-msg)))
              (message
               (chat-i18n 'message-blocked "Message blocked: %s")
               (or (plist-get outcome :reason)
                   "runtime policy returned an invalid message"))
            (let (checkpoint-error)
              (condition-case err
                  (chat-ui--checkpoint-user-message user-msg)
                (error
                 (setq checkpoint-error err)
                 (chat-event-emit
                  'turn-failed
                  :session-id (chat-session-id chat--current-session)
                  :turn-id (chat-transcript-turn user-msg)
                  :source 'checkpoint
                  :payload
                  (list (cons 'reason (error-message-string err))))
                 (message "Message not sent: checkpoint failed: %s"
                          (error-message-string err))))
              (unless checkpoint-error
                (chat-ui--activate-model-target model-target)
                (chat-session-add-message chat--current-session user-msg)
                ;; A staged batch remains recoverable until its canonical
                ;; user message has passed the checkpoint and been recorded.
                (when (plist-get metadata :staged-message-ids)
                  (chat-ui--set-stage nil))
                (setq chat-ui--send-content-parts-consumed
                      (and attachments t))
                (chat-ui--clock "record")
                ;; Drawn from the record rather than inserted directly, so
                ;; the live boundary lands after this message, not before it.
                (chat-ui--redraw-conversation)
                (chat-ui--clock "redraw")
                (chat-ui--get-response)))))))))

(defun chat-ui--checkpoint-user-message (message)
  "Create the pre-Turn checkpoint for user MESSAGE and link its ID."
  (let ((checkpoint
         (chat-checkpoint-create
          chat--current-session
          :turn-id (chat-transcript-turn message)
          :reason 'user-turn)))
    (setf (chat-message-metadata message)
          (plist-put (chat-message-metadata message)
                     :checkpoint-id
                     (chat-checkpoint-id checkpoint)))
    checkpoint))

(defun chat-ui--stamp-user-message (message)
  "Number MESSAGE with the turn it opens.

The question and every step it goes on to produce share this number, which
is what lets the display group them instead of guessing from position."
  (chat-transcript-stamp
   message
   :turn (1+ (seq-count (lambda (m) (eq (chat-message-role m) :user))
                        (chat-session-messages chat--current-session)))
   :category 'user))

(defun chat-ui--steer-active-agent (content &optional model-target)
  "Queue CONTENT and MODEL-TARGET for the response already running."
  (let* ((model-target (or model-target chat-ui--submitted-model-target))
         (user-msg (make-chat-message
                    :id (chat-session-new-message-id)
                    :role :user
                    :content content
                    :metadata
                    (and model-target
                         (list :model-provider
                               (chat-model-target-provider model-target)
                               :model-name
                               (chat-model-target-model model-target)))
                    :timestamp (current-time)))
         (event (chat-ui--prompt-event
                 'user-prompt-submitted user-msg nil 'steering))
         (outcome (chat-event-publish event))
         (user-msg (chat-event-subject event)))
    (if (not (and (chat-event-allowed-p outcome)
                  (chat-message-p user-msg)))
        (message
         (chat-i18n 'message-blocked "Message blocked: %s")
         (or (plist-get outcome :reason)
             "runtime policy returned an invalid message"))
      (chat-session-add-message chat--current-session user-msg)
      (chat-ui--redraw-conversation)
      (when (and model-target
                 (not
                  (chat-model-selection-target-equal-p
                   model-target
                   (make-chat-model-target
                    :provider (chat-agent-run-state-provider
                               chat-ui--active-agent-run)
                    :model (chat-agent-run-state-model
                            chat-ui--active-agent-run)))))
        (let* ((existing (chat-model-selection-pending
                          chat--current-session))
               (existing-target (chat-model-selection-pending-target
                                 chat--current-session))
               (pending
                (if (chat-model-selection-target-equal-p
                     existing-target model-target)
                    existing
                  (chat-model-selection-request
                   chat--current-session model-target 'message))))
          (chat-agent-schedule-model-switch
           chat-ui--active-agent-run
           (chat-model-target-provider model-target)
           (chat-model-target-model model-target)
           (alist-get 'id pending)
           (chat-ui--pending-model-switch-source pending)
           (chat-ui--model-switch-request-options
            chat-ui--active-agent-run model-target))
          (chat-ui--render-input-prompt)
          (chat-ui--render-live-region)))
      (chat-agent-steer chat-ui--active-agent-run user-msg)
      (message "%s" (chat-i18n 'message-queued
                            "Message queued for the active response.")))))

;;; Staging: several editable drafts, one turn
;;
;; Writing a request in one go is not how a request arrives.  It arrives
;; as `also check X', `and the file is at Y' -- each of which, sent on its
;; own, spends a whole turn on a fragment and gets an answer to the
;; fragment.  Staging keeps those drafts inert until an explicit send.
;;
;; They are joined into a single user message rather than sent as several,
;; because consecutive messages in the same role are not something every
;; provider accepts, and a batching feature that works on some models is
;; worse than one that reads slightly less faithfully on all of them.

(defun chat-ui--stage-items (&optional session)
  "Return structured staged items in SESSION, in display order."
  (when-let ((session (or session chat--current-session)))
    (let ((stored (chat-session-metadata-get session :chat-ui-staged-messages)))
      (chat-message-stage-items-from-json stored))))

(defun chat-ui--stage-entries (&optional session)
  "Return the staged text projection in SESSION, in display order."
  (chat-message-stage-texts (chat-ui--stage-items session)))

(defun chat-ui--stage-length (&optional session)
  "Return how many inert drafts are staged in SESSION."
  (length (chat-ui--stage-entries session)))

(defun chat-ui--set-stage (entries)
  "Make ENTRIES the staged drafts of the current session."
  (chat-ui--session-metadata-set
   :chat-ui-staged-messages
   (chat-message-stage-items-to-json
    (chat-message-stage-items-from-json entries)))
  (chat-ui--render-status-line))

(defun chat-ui--stage-next-original-order (items)
  "Return and reserve the next original order after ITEMS."
  (let* ((stored (chat-ui--session-metadata-get
                  :chat-ui-staged-message-next-order))
         (next (max (if (integerp stored) stored 1)
                    (chat-message-stage-next-original-order items))))
    (chat-ui--session-metadata-set
     :chat-ui-staged-message-next-order (1+ next))
    next))

(defun chat-ui--stage-new-item (text &optional content-parts)
  "Return a new staged item holding TEXT and CONTENT-PARTS."
  (let ((items (chat-ui--stage-items)))
    (chat-message-stage-create
     text (chat-ui--stage-next-original-order items) content-parts 'chat-ui)))

(defun chat-ui--stage-position (text)
  "Read a positive one-based stage position from TEXT."
  (let ((position (and (string-match-p "\\`[0-9]+\\'" text)
                       (string-to-number text))))
    (unless (and position (> position 0))
      (user-error "Stage position must be a positive number: %s" text))
    position))

(defun chat-ui--stage-add (text &optional content-parts)
  "Append TEXT and CONTENT-PARTS as one structured staged item."
  (let* ((items (chat-ui--stage-items))
         (item (chat-ui--stage-new-item text content-parts))
         (updated (append items (list item))))
    (chat-ui--set-stage updated)
    (setq chat-ui--send-content-parts-consumed (and content-parts t))
    (chat-event-publish
     (chat-ui--prompt-event
      'user-prompt-staged text (length updated) 'session))
    (chat-ui--insert-system-message
     (chat-i18n 'stage-added
                "Staged %d: %s  (/send to send, /stage to review)"
                (length updated) text))))

(defun chat-ui--stage-edit (position text)
  "Replace the staged text at POSITION with TEXT."
  (chat-ui--set-stage
   (chat-message-stage-edit (chat-ui--stage-items) position text))
  (chat-ui--insert-system-message
   (chat-i18n 'stage-edited "Edited staged item %d: %s" position text)))

(defun chat-ui--stage-move (from-position to-position)
  "Move staged item FROM-POSITION to TO-POSITION."
  (chat-ui--set-stage
   (chat-message-stage-move
    (chat-ui--stage-items) from-position to-position))
  (chat-ui--insert-system-message
   (chat-i18n 'stage-moved "Moved staged item %d to %d."
              from-position to-position)))

(defun chat-ui--stage-recall (position)
  "Remove staged item at POSITION and restore it to the input area."
  (let* ((removed (chat-message-stage-remove
                   (chat-ui--stage-items) position))
         (item (car removed)))
    (chat-ui--set-stage (cdr removed))
    (setq chat-ui--pending-content-parts
          (append (chat-message-stage-item-content-parts item)
                  chat-ui--pending-content-parts))
    (chat-ui--set-input-text (chat-message-stage-item-text item))
    (chat-ui--refresh-attachment-prompt)
    (chat-ui--insert-system-message
     (chat-i18n 'stage-recalled "Recalled staged item %d to the input."
                position))))

(defun chat-ui--stage-drop (request)
  "Drop the staged position named by REQUEST, the last, or all."
  (let ((items (chat-ui--stage-items))
        (request (downcase (chat-command-fold-name request))))
    (cond
     ((null items)
      (chat-ui--insert-system-message
       (chat-i18n 'stage-empty
                  "Nothing staged. /stage <draft> keeps input until explicit send.")))
     ((member request '("all" "*"))
      (chat-ui--set-stage nil)
      (chat-ui--insert-system-message
       (chat-i18n 'stage-dropped-all "Dropped all %d staged drafts."
                  (length items))))
     (t
      (let* ((position (if (string-empty-p request)
                           (length items)
                         (chat-ui--stage-position request)))
             (removed (chat-message-stage-remove items position)))
        (chat-ui--set-stage (cdr removed))
        (chat-ui--insert-system-message
         (chat-i18n 'stage-dropped "Dropped: %s"
                    (chat-message-stage-item-text (car removed)))))))))

(defun chat-ui--command-stage (arg)
  "Stage ARG, or edit, move, recall, or list staged items."
  (let* ((note (string-trim (or arg "")))
         (has-operation
          (string-match
           "\\`\\([^[:space:]]+\\)\\(?:[[:space:]]+\\(.*\\)\\)?\\'"
           note))
         (operation
          (and has-operation
               (downcase (chat-command-fold-name (match-string 1 note)))))
         (operand (or (and has-operation (match-string 2 note)) "")))
    (cond
     ((string-empty-p note)
      (chat-ui--report-stage))
     ((and (string= operation "add") (not (string-empty-p operand)))
      (chat-ui--stage-add operand chat-ui--send-content-parts))
     ((and (string= operation "edit")
           (string-match "\\`\\([0-9]+\\)[[:space:]]+\\(.+\\)\\'" operand))
      (chat-ui--stage-edit
       (chat-ui--stage-position (match-string 1 operand))
       (match-string 2 operand)))
     ((and (string= operation "move")
           (string-match "\\`\\([0-9]+\\)[[:space:]]+\\([0-9]+\\)\\'" operand))
      (chat-ui--stage-move
       (chat-ui--stage-position (match-string 1 operand))
       (chat-ui--stage-position (match-string 2 operand))))
     ((and (string= operation "recall")
           (string-match "\\`\\([0-9]+\\)\\'" operand))
      (chat-ui--stage-recall
       (chat-ui--stage-position (match-string 1 operand))))
     ((and (string= operation "drop")
           (or (string-empty-p operand)
               (string-match-p "\\`[^[:space:]]+\\'" operand)))
      (chat-ui--stage-drop operand))
     ((and (string= operation "clear") (string-empty-p operand))
      (chat-ui--stage-drop "all"))
     ((member operation '("add" "edit" "move" "recall" "drop" "clear"))
      (user-error
       "Usage: /stage add TEXT | edit N TEXT | move N M | recall N | drop [N|all] | clear"))
     (t
      (chat-ui--stage-add note chat-ui--send-content-parts)))))

(defun chat-ui--report-stage ()
  "Say what is staged, and how to send or discard it."
  (let ((items (chat-ui--stage-items)))
    (chat-ui--insert-system-message
     (if (null items)
         (chat-i18n 'stage-empty
                    "Nothing staged. /stage <draft> keeps input until explicit send.")
       (concat (chat-i18n 'stage-heading "Staged (%d), /send to send:"
                          (length items))
               "\n"
               (string-join
                (seq-map-indexed
                 (lambda (item index)
                   (let ((created (chat-message-stage-item-created-at item)))
                     (format "  %d. [id %s, original %d%s] %s"
                             (1+ index)
                             (substring
                              (chat-message-stage-item-id item)
                              0 (min 18 (length
                                         (chat-message-stage-item-id item))))
                             (chat-message-stage-item-original-order item)
                             (if (> created 0)
                                 (format ", %s"
                                         (format-time-string
                                          "%H:%M:%S"
                                          (seconds-to-time (/ created 1000.0))))
                               "")
                             (chat-message-stage-item-text item))))
                 items)
                "\n"))))))

(defun chat-ui--send-stage (arg)
  "Send the staged drafts as one turn, appending ARG when given."
  (let* ((extra (string-trim (or arg "")))
         (items (append (chat-ui--stage-items)
                        (and (not (string-empty-p extra))
                             (list (chat-ui--stage-new-item
                                    extra chat-ui--send-content-parts))))))
    (if (null items)
      (message "%s"
               (chat-i18n 'send-usage
                          "Usage: /send <message>, or /send alone to send staged drafts."))
      ;; A staged batch is a new user turn.  If another run owns the
      ;; executor, it waits in the runtime queue instead of being steered
      ;; into that run or starting concurrently.
      (chat-ui--send-in-mode
       (chat-message-stage-joined-text items)
       'queue
       (chat-message-stage-content-parts items)
       (chat-message-stage-batch-metadata items)))))

(defun chat-ui--command-cancel (_arg)
  "Cancel the response that is in flight."
  (chat-ui-cancel-response)
  (message "%s" (chat-i18n 'request-cancelled "Request cancelled.")))

(defun chat-ui--command-model (arg)
  "Request the model target named by ARG at the next request boundary."
  (let ((target (or (chat-ui--resolve-model-target arg)
                    (chat-ui--read-model-target))))
    (when target
      (chat-ui--request-model-switch target 'command)
      (message "Model switch pending: %s/%s"
               (chat-model-target-provider target)
               (chat-model-target-model target)))))

(defun chat-ui--command-shell (arg)
  "Run ARG as a shell command."
  (if (string-empty-p arg)
      (message "%s" (chat-i18n 'shell-usage "Usage: !<command>"))
    (chat-ui--handle-shell-command arg)))

(defun chat-ui--repl-status-text (session)
  "Return a compact status report for REPL SESSION."
  (if (not session)
      "No REPL is selected. Use /repl start shell or /repl start clojure."
    (format "REPL %s #%d [%s]\n%s"
            (chat-repl-session-adapter-id session)
            (chat-repl-session-generation session)
            (chat-repl-session-status session)
            (chat-repl-session-directory session))))

(defun chat-ui--repl-result-observer (buffer chat-session-id)
  "Return a bounded result observer for BUFFER and CHAT-SESSION-ID."
  (lambda (status value transaction)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and chat--current-session
                   (equal (chat-session-id chat--current-session)
                          chat-session-id))
          (let* ((repl (chat-repl-for-chat-session chat--current-session))
                 (adapter (and repl (chat-repl-session-adapter-id repl)))
                 (generation (and repl (chat-repl-session-generation repl)))
                 (text (string-trim-right (or value ""))))
            (chat-ui--insert-system-message
             (format "REPL %s #%s [%s] %s%s"
                     (or adapter "closed") (or generation "-") status
                     (chat-repl-transaction-id transaction)
                     (if (string-empty-p text)
                         ""
                       (format "\n%s" (chat-ui--repl-fenced-text text)))))
            (chat-ui--render-input-prompt)))))))

(defun chat-ui--repl-fenced-text (text)
  "Return TEXT in a Markdown fence that cannot be closed by its contents."
  (let ((longest 0)
        (current 0))
    (dotimes (index (length text))
      (if (eq (aref text index) ?`)
          (setq current (1+ current)
                longest (max longest current))
        (setq current 0)))
    (let ((fence (make-string (max 3 (1+ longest)) ?`)))
      (format "%stext\n%s\n%s" fence text fence))))

(defun chat-ui--repl-eval (code)
  "Queue CODE in the current session's selected REPL."
  (let ((repl (and chat--current-session
                   (chat-repl-for-chat-session chat--current-session))))
    (unless repl
      (user-error "No REPL is selected; use /repl start shell or /repl start clojure"))
    (when (string-empty-p (string-trim code))
      (user-error "REPL input is empty"))
    (chat-repl-eval
     repl code
     (chat-ui--repl-result-observer (current-buffer)
                                    (chat-session-id chat--current-session)))
    (message "REPL input queued: %s" (chat-repl-session-adapter-id repl))))

(defun chat-ui--repl-split-request (arg)
  "Return (ACTION . REST) parsed from REPL command ARG."
  (let ((trimmed (string-trim (or arg ""))))
    (if (string-empty-p trimmed)
        (cons "" "")
      (if (string-match "\\`\\([^[:space:]]+\\)\\(?:[[:space:]]+\\(.*\\)\\)?\\'"
                        trimmed)
          (cons (downcase (match-string 1 trimmed))
                (or (match-string 2 trimmed) ""))
        (cons trimmed "")))))

(defun chat-ui--command-repl (arg)
  "Manage or evaluate the current session's persistent REPL using ARG."
  (if chat-ui--input-was-typed
      (chat-ui--repl-eval arg)
    (pcase-let* ((`(,action . ,rest) (chat-ui--repl-split-request arg))
                 (session (and chat--current-session
                               (chat-repl-for-chat-session
                                chat--current-session))))
      (pcase action
        ("start"
         (when session
           (user-error "A REPL is already selected; close it before starting another"))
         (let* ((name (if (string-empty-p rest) "shell" (string-trim rest)))
                (adapter (intern-soft name))
                (directory (or (chat-session-working-directory
                                chat--current-session)
                               default-directory)))
           (unless (and adapter (memq adapter (chat-repl-adapter-ids)))
             (user-error "Unavailable REPL adapter: %s" name))
           (setq session (chat-repl-start chat--current-session adapter directory))
           (chat-ui--set-default-command "repl")
           (chat-ui--render-default-command)
           (chat-ui--insert-system-message (chat-ui--repl-status-text session))))
        ("eval" (chat-ui--repl-eval rest))
        ("interrupt"
         (unless session (user-error "No REPL is selected"))
         (chat-repl-interrupt session "interrupted by developer")
         (chat-ui--insert-system-message (chat-ui--repl-status-text session))
         (chat-ui--render-input-prompt))
        ("reset"
         (unless session (user-error "No REPL is selected"))
         (chat-repl-reset session)
         (chat-ui--insert-system-message (chat-ui--repl-status-text session))
         (chat-ui--render-input-prompt))
        ("close"
         (unless session (user-error "No REPL is selected"))
         (chat-repl-close session)
         (when (equal (chat-ui-default-command) "repl")
           (chat-ui--set-default-command nil)
           (chat-ui--render-default-command))
         (chat-ui--insert-system-message "REPL closed."))
        ((or "status" "")
         (chat-ui--insert-system-message (chat-ui--repl-status-text session)))
        ("adapters"
         (chat-ui--insert-system-message
          (format "REPL adapters: %s"
                  (mapconcat #'symbol-name (chat-repl-adapter-ids) ", "))))
        ("list"
         (chat-ui--insert-system-message
          (if session (chat-ui--repl-status-text session)
            "No REPL is selected.")))
        (_
         (user-error
          "Usage: /repl start ADAPTER | eval CODE | interrupt | reset | status | adapters | close"))))))

;; ------------------------------------------------------------------
;; Sending while something is already running
;; ------------------------------------------------------------------

;; Pressing return during a run had one meaning, and it was never chosen:
;; the input was injected into the run in progress.  That is right when the
;; user is adding to what they asked, wrong when they want the current job
;; finished first, and worst when they have changed their mind -- the model
;; carries on with a task that has been withdrawn.  So three meanings, and
;; the user picks.  Spec 010.

(defun chat-ui-send-mode ()
  "Return the mode in force for this buffer."
  (or chat-ui--send-mode chat-send-default-mode))

(defun chat-ui--send-mode-name (mode)
  "Return MODE as it is written in a command."
  (symbol-name mode))

(defun chat-ui--split-send-mode (arg)
  "Return (MODE . REST) for ARG, or nil when it names no mode.

Only the first word, and only when it is exactly a mode name."
  (let* ((trimmed (string-trim arg))
         (space (string-match-p "[ \t\n]" trimmed))
         (head (if space (substring trimmed 0 space) trimmed))
         (rest (if space (string-trim (substring trimmed space)) "")))
    (when-let ((mode (car (member (intern-soft (downcase head))
                                  chat-ui-send-modes))))
      (cons mode rest))))

(defun chat-ui--command-send (arg)
  "Send ARG to the model, including staged drafts when they exist.

This is the name of what plain input has always done: recorded in the
session, answered by a run that may reason and use tools over several
steps.  It needed a name so that auto has somewhere to return to, and so
that the main way of using the surface is not the only thing on it with
no name.

ARG may begin with a mode name, which applies to this message, or consist
of one, which changes the mode for later ones."
  (let ((split (and (not chat-ui--input-was-typed)
                    (chat-ui--split-send-mode arg))))
    (cond
     ;; Staging owns the entire next explicit send.  Its batch is a new
     ;; turn and automatically waits behind an active run, so mode words
     ;; here are ordinary closing text rather than a second control plane.
     ((chat-ui--stage-items)
      (chat-ui--send-stage arg))
     ((and split (string-empty-p (cdr split)))
      (chat-ui--set-send-mode (car split)))
     (split
      (chat-ui--send-in-mode (cdr split) (car split)))
     ((string-empty-p arg)
      (message "%s" (chat-i18n 'send-usage
                               "Usage: /send <message>, or /send alone to send staged drafts.")))
     (t (chat-ui--send-in-mode arg (chat-ui-send-mode))))))

(defun chat-ui--set-send-mode (mode)
  "Make MODE what pressing return during a run does in this buffer."
  (setq chat-ui--send-mode mode)
  (force-mode-line-update)
  (message (chat-i18n 'send-mode-set "Sending during a run now: %s")
           (chat-ui--send-mode-name mode)))

(defun chat-ui--send-in-mode (content mode &optional content-parts metadata)
  "Send CONTENT, handling a run already in progress according to MODE.

With nothing running the three modes are the same thing, because there is
nothing to insert into, wait for, or interrupt."
  (let ((parts (or content-parts chat-ui--send-content-parts))
        (chat-ui--submitted-model-target
         (and chat--current-session
              (chat-model-selection-prepared chat--current-session))))
    (cond
     ((not (chat-agent-active-p chat-ui--active-agent-run))
      (chat-ui--send-user-message content parts metadata))
     ((eq mode 'queue) (chat-ui--queue-send content parts metadata))
     ((eq mode 'interrupt) (chat-ui--interrupt-with content parts))
     (parts (chat-ui--queue-send content parts metadata))
     (t (chat-ui--steer-active-agent content)))))

(defun chat-ui--draft (content parts &optional metadata model-target)
  "Return a queued draft for CONTENT, PARTS, METADATA and MODEL-TARGET."
  (list :text content :parts parts :metadata metadata :model-target model-target))

(defun chat-ui--draft-text (draft)
  "Return DRAFT text."
  (or (plist-get draft :text) ""))

(defun chat-ui--draft-parts (draft)
  "Return DRAFT typed parts."
  (plist-get draft :parts))

(defun chat-ui--draft-metadata (draft)
  "Return DRAFT message metadata."
  (plist-get draft :metadata))

(defun chat-ui--draft-model-target (draft)
  "Return the immutable model target captured by DRAFT."
  (plist-get draft :model-target))

(defun chat-ui--queue-send (content &optional content-parts metadata model-target)
  "Hold CONTENT, CONTENT-PARTS, METADATA and MODEL-TARGET until later."
  (let ((draft (chat-ui--draft
                content content-parts metadata
                (or model-target chat-ui--submitted-model-target))))
    (setq chat-ui--queued-sends (append chat-ui--queued-sends (list draft)))
    (setq chat-ui--send-content-parts-consumed (and content-parts t))
    (chat-event-publish
     (chat-ui--prompt-event
      'user-prompt-queued draft (length chat-ui--queued-sends) 'run))
    (message (chat-i18n 'send-queued-count
                        "Queued until this response finishes (%d waiting).")
             (length chat-ui--queued-sends))))

(defun chat-ui--drain-queued-sends ()
  "Send the first message waiting for a run that has just finished.

One at a time, each as a run of its own.  Combining them would be
`insert', and someone who chose `queue' chose not to combine them.  The
rest stay queued and follow as each run ends.

Sent whatever the finished run's status was, cancelled and failed
included: waiting meant waiting for an outcome, and a failure is one.
Swallowing the input would be worse than carrying a failure forward."
  (when-let ((next (pop chat-ui--queued-sends)))
    ;; Through a timer so that the send does not run inside the event
    ;; handler of the run it was waiting for, which is still finishing.
    (let ((buffer (current-buffer)))
      (run-at-time
       0 nil
       (lambda ()
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (let ((chat-ui--submitted-model-target
                    (chat-ui--draft-model-target next)))
               (chat-ui--send-user-message
                (chat-ui--draft-text next)
                (chat-ui--draft-parts next)
                (chat-ui--draft-metadata next))))))))))

(defconst chat-ui--interrupted-marker "[interrupted after %s characters]"
  "How a reply cut short introduces itself to later turns.")

(defun chat-ui--interrupt-with (content &optional content-parts model-target)
  "Stop the current run, keep what it produced, and send CONTENT instead.

Keeping it is the part that did not exist.  A cancelled run's in-flight
text was dropped -- the stream sentinel skips the result handler once
cancelled, and the UI's `cancelled' branch only cleans up -- so \"the
partial result is used as context\" had nothing to refer to.  Steps that
had already completed were always kept; this is about the one in flight."
  (let ((partial (string-trim (or chat-ui--live-response-content ""))))
    (unless (string-empty-p partial)
      (chat-session-add-message
       chat--current-session
       (make-chat-message
        :id (chat-session-new-message-id)
        :role :assistant
        :content (concat (format chat-ui--interrupted-marker
                                 (length partial))
                         "\n" partial)
        :timestamp (current-time))))
    (chat-ui-cancel-response)
    (chat-ui--redraw-conversation)
    (let ((chat-ui--submitted-model-target
           (or model-target chat-ui--submitted-model-target)))
      (if content-parts
          (chat-ui--send-user-message content content-parts)
        (chat-ui--send-user-message content)))))

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

(defun chat-ui--command-root (arg)
  "Show this session's root directory, or change it to ARG.

The root is the stable anchor of the conversation: project instructions,
goals and project scope follow it, and /cd never moves it.  Changing the
root deliberately does not change the working directory -- the two answer
different questions, and coupling them is how a shell wander silently
re-rooted the project."
  (let ((session (chat-ui--require-current-session)))
    (if (string-empty-p arg)
        (chat-ui--insert-system-message
         (format "🗂 Root directory: %s\n📁 Current directory: %s"
                 (or (chat-session-root-directory session) "(none)")
                 default-directory))
      (let ((expanded (expand-file-name
                       (chat-command-fold-path (string-trim arg)))))
        (if (not (file-directory-p expanded))
            (chat-ui--insert-system-message
             (chat-i18n 'directory-missing "❌ Directory not found: %s" arg))
          (chat-session-set-root-directory session expanded)
          (chat-ui--insert-system-message
           (format "🗂 Root directory changed to: %s"
                   (file-name-as-directory expanded))))))))

(defun chat-ui--command-new (_arg)
  "Start a new session."
  (call-interactively #'chat-new-session))

(defun chat-ui--command-list (_arg)
  "Show the saved sessions."
  (call-interactively #'chat-list-sessions))

(defun chat-ui--require-current-session ()
  "Return the current session or signal a user-facing error."
  (or chat--current-session
      (user-error "%s" (chat-i18n 'no-session "No session here."))))

(defun chat-ui--require-recovery-idle ()
  "Refuse structural recovery while the current response is active."
  (when (chat-ui--response-active-p)
    (user-error "Cancel or finish the current response before recovery")))

(defun chat-ui--checkpoint-time (checkpoint)
  "Return CHECKPOINT creation time for display."
  (if-let* ((timestamp (chat-checkpoint-created-at checkpoint)))
      (format-time-string "%Y-%m-%d %H:%M:%S"
                          (seconds-to-time (/ timestamp 1000.0)))
    "unknown time"))

(defun chat-ui--checkpoint-label (checkpoint)
  "Return one concise selection label for CHECKPOINT."
  (format "%s  %s  %s  %d owned"
          (chat-checkpoint-id checkpoint)
          (chat-ui--checkpoint-time checkpoint)
          (chat-checkpoint-reason checkpoint)
          (seq-count
           (lambda (entry)
             (eq (chat-checkpoint-file-status entry) 'owned))
           (chat-checkpoint-files checkpoint))))

(defun chat-ui--read-checkpoint ()
  "Read one checkpoint belonging to the current session."
  (let* ((session (chat-ui--require-current-session))
         (checkpoints (chat-checkpoint-list (chat-session-id session))))
    (unless checkpoints
      (user-error "This session has no checkpoints"))
    (let* ((choices
            (mapcar (lambda (checkpoint)
                      (cons (chat-ui--checkpoint-label checkpoint) checkpoint))
                    checkpoints))
           (choice (completing-read "Checkpoint: " choices nil t)))
      (cdr (assoc choice choices)))))

;;;###autoload
(defun chat-ui-checkpoint-list ()
  "Show checkpoints owned by the current session."
  (interactive)
  (let* ((session (chat-ui--require-current-session))
         (checkpoints (chat-checkpoint-list (chat-session-id session))))
    (with-help-window "*chat checkpoints*"
      (princ (format "Checkpoints for %s\n\n" (chat-session-name session)))
      (if checkpoints
          (dolist (checkpoint checkpoints)
            (princ (chat-ui--checkpoint-label checkpoint))
            (when-let* ((limitations (chat-checkpoint-limitations checkpoint)))
              (princ (format "  %d limitation%s"
                             (length limitations)
                             (if (= (length limitations) 1) "" "s"))))
            (princ "\n"))
        (princ "No checkpoints.\n")))))

;;;###autoload
(defun chat-ui-checkpoint-create ()
  "Create an explicit checkpoint for the current session."
  (interactive)
  (chat-ui--require-recovery-idle)
  (let ((checkpoint
         (chat-checkpoint-create
          (chat-ui--require-current-session) :reason 'manual)))
    (chat-ui--insert-system-message
     (format "Checkpoint created: %s" (chat-checkpoint-id checkpoint)))
    checkpoint))

;;;###autoload
(defun chat-ui-checkpoint-rollback-code (checkpoint &optional force)
  "Restore runtime-owned files from CHECKPOINT.
With a prefix argument FORCE, overwrite externally drifted owned paths."
  (interactive (list (chat-ui--read-checkpoint) current-prefix-arg))
  (chat-ui--require-recovery-idle)
  (let ((result (chat-checkpoint-rollback-code checkpoint force)))
    (chat-ui--insert-system-message
     (format "Checkpoint %s restored %d owned file%s%s."
             (plist-get result :checkpoint-id)
             (plist-get result :restored-files)
             (if (= (plist-get result :restored-files) 1) "" "s")
             (if (plist-get result :forced) " with force" "")))
    result))

;;;###autoload
(defun chat-ui-checkpoint-rollback-conversation (checkpoint)
  "Create and open a conversation branch at CHECKPOINT."
  (interactive (list (chat-ui--read-checkpoint)))
  (chat-ui--require-recovery-idle)
  (let ((branch
         (chat-checkpoint-rollback-conversation
          checkpoint (chat-ui--require-current-session))))
    (chat--open-chat-session branch)
    branch))

;;;###autoload
(defun chat-ui-checkpoint-rollback-both (checkpoint &optional force)
  "Restore CHECKPOINT files and then open a conversation branch.
With a prefix argument FORCE, overwrite externally drifted owned paths."
  (interactive (list (chat-ui--read-checkpoint) current-prefix-arg))
  (chat-ui--require-recovery-idle)
  (let* ((result
          (chat-checkpoint-rollback-both
           checkpoint (chat-ui--require-current-session) force))
         (branch (plist-get result :branch)))
    (chat--open-chat-session branch)
    result))

;;;###autoload
(defun chat-ui-workspace-status ()
  "Show and reconcile the current session workspace."
  (interactive)
  (let* ((session (chat-ui--require-current-session))
         (workspace (chat-workspace-get session)))
    (with-help-window "*chat workspace*"
      (princ (format "Workspace for %s\n\n" (chat-session-name session)))
      (if (null workspace)
          (progn
            (princ "Kind: checkout\n")
            (princ (format "Path: %s\n" default-directory)))
        (setq workspace (chat-workspace-reconcile workspace session))
        (princ (format "Kind: %s\n" (chat-workspace-kind workspace)))
        (princ (format "Status: %s\n" (chat-workspace-status workspace)))
        (princ (format "Path: %s\n" (chat-workspace-path workspace)))
        (princ (format "Source: %s\n"
                       (chat-workspace-source-root workspace)))
        (princ (format "Base: %s\n"
                       (chat-workspace-base-revision workspace)))
        (princ (format "Dirty: %s\n"
                       (if (chat-workspace-dirty workspace) "yes" "no")))))))

;;;###autoload
(defun chat-ui-workspace-enable (&optional revision)
  "Give the current session an owned worktree at optional REVISION."
  (interactive
   (list (and current-prefix-arg
              (read-string "Base revision: " "HEAD"))))
  (chat-ui--require-recovery-idle)
  (let* ((session (chat-ui--require-current-session))
         (workspace
          (chat-workspace-enable-worktree
           session default-directory :revision revision)))
    (setq-local default-directory (chat-workspace-path workspace))
    (chat-ui--insert-system-message
     (format "Owned worktree enabled: %s" default-directory))
    workspace))

;;;###autoload
(defun chat-ui-workspace-release (&optional force)
  "Release the current session's owned worktree.
With a prefix argument FORCE, discard changes in that owned worktree."
  (interactive "P")
  (chat-ui--require-recovery-idle)
  (let* ((session (chat-ui--require-current-session))
         (workspace (chat-workspace-release session force)))
    (setq-local default-directory
                (chat-workspace-source-root workspace))
    (chat-ui--insert-system-message
     (format "Owned worktree released%s; source checkout restored: %s"
             (if force " with force" "") default-directory))
    workspace))

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
  (let ((topic (chat-command-fold-name arg)))
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
  "Return the coding system prompt for SESSION, or nil.

Code capability is a property of the session, so this is the whole of
what a coding session adds to the system instruction.  Project and code
context remain typed fragments until request projection."
  (when (and session
             (fboundp 'chat-code-session-p)
             (chat-code-session-p session))
    (and (fboundp 'chat-code--compose-system-prompt)
         (chat-code--compose-system-prompt))))

(defun chat-ui--code-context (session)
  "Return SESSION's current code context as typed fragments."
  (when (and session
             (fboundp 'chat-code-session-p)
             (chat-code-session-p session)
             (fboundp 'chat-context-code-build)
             (fboundp 'chat-context-code-to-string))
    (when-let* ((context-object
                 (ignore-errors (chat-context-code-build session)))
                (payload (chat-context-code-to-string context-object))
                ((not (string-empty-p payload))))
      (let* ((root (or (chat-session-working-directory session)
                       default-directory))
             (diagnostics
              (and chat-ui--current-request-id
                   (fboundp 'chat-code-context-diagnostics)
                   (chat-code-context-diagnostics context-object))))
        (when chat-ui--current-request-id
          (chat-request-diagnostics-record
           chat-ui--current-request-id
           'code-context-built
           :diagnostics diagnostics
           :summary "Prepared versioned coding context"))
        (list
         (chat-context-fragment-create
          :id (format "code-context:%s"
                      (secure-hash 'sha256 (format "%s\0%s" root payload)))
          :kind 'code :authority 'runtime :source-kind 'code-context
          :source-id (format "code-context:%s" root)
          :source-path root :scope 'project :scope-id root :priority 40
          :residency 'compactable :budget-policy 'trim :payload payload
          :status 'active
          :metadata `((diagnosticCount . ,(length diagnostics)))))))))

(defun chat-ui--standing-context (session)
  "Return attributable standing context fragments for SESSION."
  (append (chat-ui--project-context session)
          (chat-ui--code-context session)))

(defun chat-ui--current-model-supports-tools-p ()
  "Return nil only when the current model explicitly lacks tool support."
  (if (null chat--current-session)
      t
    (let* ((provider (chat-session-model-id chat--current-session))
           (config (chat-llm-get-provider-config provider))
           (model (or (chat-session-model-name chat--current-session)
                      (plist-get config :model))))
      (not (null
            (chat-model-capabilities-tools
             (chat-model-capabilities-resolve provider model)))))))

(defun chat-ui--prepare-messages-with-tools (messages)
  "Prepare message list with tool calling system prompt."
  (if (or (not chat-tool-caller-enabled)
          (not (chat-ui--current-model-supports-tools-p)))
      (progn
        (chat-log "[TOOLS] Tools unavailable, using original messages")
        messages)
    (let* ((code-prompt (chat-ui--code-capability-prompt chat--current-session))
           (base-prompt (or code-prompt
                            (chat-i18n-prompt 'assistant-persona
                                              "You are a helpful AI assistant.")))
           (target-note (chat-ui--followup-target-note))
           (prompt (cond
                    (target-note
                     (format "%s\n\n%s" base-prompt target-note))
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
             :timestamp (current-time)
             :metadata (list :tool-system-prompt-base prompt))
            messages))))

(defun chat-ui--session-directories-fragment (session root cwd)
  "Return the fragment naming SESSION's ROOT and CWD to the model.

The two directories answer different questions, and a model that cannot
see them conflates them: a /cd for one shell command quietly re-anchors
the project.  The fragment also carries the standing rule that AGENTS.md
in both directories is required reading -- injection covers the files the
walk finds, and the rule covers the ones it cannot."
  (chat-context-fragment-validate
   (chat-context-fragment-create
    :id (format "session-directories:%s" (chat-session-id session))
    :kind 'instruction :authority 'runtime
    :source-kind 'session-directories
    :source-id (format "session:%s" (chat-session-id session))
    :scope 'session :scope-id (chat-session-id session)
    :priority 1 :residency 'protected :budget-policy 'preserve
    :payload
    (format
     (concat "Session directories:\n"
             "- Root directory (stable anchor): %s\n"
             "- Current working directory (shell commands and relative paths; "
             "moves with /cd): %s\n"
             "The root directory is this conversation's project home: project "
             "instructions, goals and file scope anchor there, and it never "
             "follows cd. The current directory is only where commands run "
             "right now.\n"
             "Before making changes you MUST read and obey AGENTS.md in the "
             "root directory and in the current directory. Their contents are "
             "injected when the discovery walk finds them; if one exists but "
             "is not in context, read it with the file tool before editing "
             "anything under that directory.")
     root cwd)
    :status 'active
    :metadata `((root . ,root) (cwd . ,cwd)))))

(defun chat-ui--project-context (session)
  "Return scoped project context fragments for SESSION.

Instructions are discovered from both of the session's directories: the
stable root and the current working directory.  Each graph already walks
upward to the filesystem root, so a cwd inside the root adds nothing new;
the merge matters when shell work has taken the cwd outside it."
  (when (fboundp 'chat-project-instruction-graph)
    (let* ((cwd (or (chat-session-working-directory session)
                    default-directory))
           (root (or (chat-session-root-directory session) cwd))
           (starts (delete-dups
                    (mapcar #'file-truename (list root cwd))))
           (seen (make-hash-table :test 'equal))
           (fragments nil)
           (source-count 0)
           (diagnostics nil))
      (dolist (start starts)
        (let ((graph (ignore-errors (chat-project-instruction-graph start))))
          (when graph
            (setq source-count
                  (+ source-count
                     (length (plist-get graph :source-files)))
                  diagnostics
                  (append diagnostics (plist-get graph :diagnostics)))
            (dolist (fragment (plist-get graph :fragments))
              (unless (gethash (chat-context-fragment-id fragment) seen)
                (puthash (chat-context-fragment-id fragment) t seen)
                (push fragment fragments))))))
      (when (and fragments (fboundp 'chat-event-publish))
        (chat-event-publish
         (chat-event-create
          :type 'instruction-graph-observed
          :session-id (chat-session-id session) :source 'project-context
          :payload
          `((sourceCount . ,source-count)
            (fragmentCount . ,(length fragments))
            (diagnosticCount . ,(length diagnostics))
            (diagnosticTypes
             . ,(vconcat
                 (delete-dups
                  (mapcar (lambda (item) (plist-get item :type))
                          diagnostics))))))))
      (cons (chat-ui--session-directories-fragment session root cwd)
            (nreverse fragments)))))

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
          ('approval-guard-pending
           (format "- Guard Judging %s: %s"
                   (plist-get event :index)
                   (plist-get event :tool)))
          ('approval
           ;; The source and the reason are the whole value of this line.
           ;; "Approval 3: granted" leaves the reader unable to tell a
           ;; builtin pattern from something they allowed last month, and a
           ;; refusal with no reason is the failure spec 011 set out to fix.
           ;;
           ;; A guard's allow names the rule it matched, and that is shown
           ;; for the same reason the reason for a refusal is: an approver
           ;; whose permissions cannot be reviewed afterwards is worse than
           ;; no approver.
           (concat
            (format "- Approval %s: %s"
                    (plist-get event :index)
                    (plist-get event :decision))
            (when-let ((source (plist-get event :source)))
              (format " (%s)" source))
            (when-let ((rule (plist-get event :matched-rule)))
              (format " [%s]" rule))
            (when-let ((reason (plist-get event :reason)))
              (format " -- %s" reason))))
          ('approval-shadow
           ;; Marked as deciding nothing, because a line that reads like an
           ;; approval but changed no outcome is worse than no line.
           (concat
            (format "- Guard Shadow %s: %s (decided nothing)"
                    (plist-get event :index)
                    (plist-get event :verdict))
            (when-let ((reason (plist-get event :reason)))
              (format " -- %s" reason))))
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

(defun chat-ui-window-follows-p (window-point window-end input-start
                                              buffer-min buffer-max)
  "Return non-nil when a window at WINDOW-POINT should follow new output.

WINDOW-END is where the window's view stops, INPUT-START where the input
area begins or nil, and BUFFER-MIN and BUFFER-MAX the buffer's bounds.

A named rule rather than a condition buried in a loop, because it is the
whole of the promise that a reader who has scrolled up is left alone: only
a window already at the end follows, and never one whose point sits in the
input area, where following would move the cursor out from under someone
who is typing."
  (and (numberp window-end)
       (or (null input-start) (< window-point input-start))
       (>= window-end buffer-max)))

(defun chat-ui--capture-live-window-state (ui-buffer)
  "Capture how windows showing UI-BUFFER should react to the next redraw.

This must run before output is inserted.  Inferring the state afterwards
made a manually scrolled window look close enough to the new end and
yanked it back down.

A window start inside the live tail cannot be kept as a marker: the
redraw deletes the tail, the marker collapses to the tail's start, and
its advance-on-insert type then drags it past the whole re-inserted
reply, so the restore landed the prompt at the window top with every
output line above it.  That start is anchored by its distance from the
buffer end instead -- the tail grows, and the same bottom lines stay on
screen."
  (when (buffer-live-p ui-buffer)
    (with-current-buffer ui-buffer
      (let ((input-start (and (markerp chat-ui--input-overlay)
                              (marker-position chat-ui--input-overlay)))
            (live-start (and (markerp chat-ui--live-start)
                             (marker-position chat-ui--live-start))))
        (mapcar
         (lambda (window)
           (let ((window-point (window-point window))
                 (window-start (window-start window)))
             (list :window window
                   :follow
                   (chat-ui-window-follows-p
                    window-point (window-end window t) input-start
                    (point-min) (point-max))
                   :input-point
                   (and input-start (>= window-point input-start))
                   :point (copy-marker window-point t)
                   :start (copy-marker window-start t)
                   :at-bottom (>= (window-end window t) (point-max))
                   :start-tail-lines
                   (and live-start
                        (>= window-start live-start)
                        (count-lines window-start (point-max))))))
         (seq-filter #'window-live-p
                     (get-buffer-window-list ui-buffer nil t)))))))

(defun chat-ui--release-live-window-state (states)
  "Release the markers retained by captured window STATES."
  (dolist (state states)
    (set-marker (plist-get state :point) nil)
    (set-marker (plist-get state :start) nil)))

(defun chat-ui--follow-live-output (ui-buffer &optional captured-state)
  "Scroll windows showing UI-BUFFER to the live response edge.

CAPTURED-STATE, when non-nil, was taken before the redraw.  Only windows
that were exactly at the bottom then follow.  Other windows restore their
old top line.  Point may remain in the input while that line is off-screen;
manual reading position owns the window until the reader returns to it."
  (when (buffer-live-p ui-buffer)
    (with-current-buffer ui-buffer
      (let ((edge (and (markerp chat-ui--messages-end)
                       (marker-position chat-ui--messages-end)))
            (input-start (and (markerp chat-ui--input-overlay)
                              (marker-position chat-ui--input-overlay))))
        (when edge
          (if captured-state
              (unwind-protect
                  (dolist (state captured-state)
                    (let ((window (plist-get state :window)))
                      (when (window-live-p window)
                        (if (plist-get state :follow)
                            (set-window-point window edge)
                          (let ((tail-lines
                                 (plist-get state :start-tail-lines)))
                            (cond
                             ((plist-get state :at-bottom)
                              ;; A window showing the buffer end rides the
                              ;; bottom like a terminal: the tail grows,
                              ;; the prompt stays at the bottom edge, the
                              ;; newest output above it, and the cursor is
                              ;; not moved out of the input to do it.
                              (set-window-start
                               window
                               (save-excursion
                                 (goto-char (point-max))
                                 (line-beginning-position)
                                 (forward-line
                                  (- (1- (window-body-height window))))
                                 (max (point-min) (line-beginning-position)))
                               t))
                             (tail-lines
                              ;; A reading position inside the tail: keep
                              ;; the same distance from the buffer end.
                              ;; The buffer never ends with a newline (the
                              ;; prompt trails), so count-lines includes
                              ;; the partial last line and the walk back
                              ;; is one line shorter than the count.
                              (set-window-start
                               window
                               (save-excursion
                                 (goto-char (point-max))
                                 (line-beginning-position)
                                 (forward-line (- (1- tail-lines)))
                                 (line-beginning-position))
                               t))
                             (t
                              (set-window-start
                               window
                               (marker-position (plist-get state :start))
                               t))))
                          (set-window-point
                           window (marker-position
                                   (plist-get state :point)))))))
                (chat-ui--release-live-window-state captured-state))
            ;; Compatibility path for callers that only want to follow an
            ;; already drawn edge.  Event rendering always supplies the
            ;; pre-redraw snapshot above.
            (dolist (window (get-buffer-window-list ui-buffer nil t))
              (when (and (window-live-p window)
                         (chat-ui-window-follows-p
                          (window-point window) (window-end window t)
                          input-start (point-min) (point-max)))
                (set-window-point window edge)))))))))

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
  "Return the length of the CONTENT prefix the fast path may keep.

The streaming fast path may only keep text it will not have to reformat.
Cutting at the previous length leaves a half-arrived code block rendered
as prose, and the fence that closes it later never re-runs the
formatting, so the block stays broken for the rest of the conversation.

Now every block rather than only fenced ones: a table gains columns as
its rows arrive, and a list gains its hanging indent, so cutting inside
either of those froze them half-drawn for the same reason."
  (chat-markdown-stable-prefix-length content))

(defun chat-ui--insert-formatted-response (content)
  "Insert CONTENT as Markdown rendered for display.

One renderer, called from here, from the redraw, from the quick answer
and from errors -- so those paths cannot produce different styling for
the same text, which they did as long as each carried its own
formatting."
  (insert (chat-markdown-render content)))

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
      (let ((window-state (chat-ui--capture-live-window-state ui-buffer)))
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
                    :permission-failure
                    (chat-ui--latest-permission-failure tool-events)
                    :limit-reached tool-loop-limit-reached))
        (chat-ui--render-live-region)
        (chat-ui--follow-live-output ui-buffer window-state)))))

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

(defun chat-ui--goal-followup-function (session)
  "Return one bounded automatic-continuation callback for SESSION's Goal."
  (let ((continuations 0))
    (lambda (_processed)
      (let ((goal (chat-goal-current session)))
        (cond
         ((or (null goal)
              (not (eq (chat-goal-status goal) 'active))
              (not (chat-goal-project-in-scope-p session goal))
              (chat-plan-mode-active-p session))
          nil)
         ((>= continuations chat-goal-max-continuations-per-run)
          (chat-goal-mark-needs-attention
           session "Automatic continuation budget exhausted; send a message to continue.")
          nil)
         (t
          (setq continuations (1+ continuations))
          (format
           (concat
            "The selected Goal remains active at revision %d. Continue making concrete progress toward its stopping condition. "
            "Do not merely restate status. Record verified progress with the Goal tools; if a real external dependency prevents progress, block the Goal with an actionable resume condition; if all required evidence is known, request deterministic completion.")
           (chat-goal-revision goal))))))))

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

(defun chat-ui--event-payload-keys (event)
  "Name what EVENT carries beyond what every event carries.

Named rather than printed.  `chat-agent--emit' puts `:run' on every
event, and the run holds the whole session, so `%S' on one dropped event
wrote the entire conversation to the log -- several times per turn, since
seven event types reach the clause that reports them."
  (let ((keys (cl-loop for (key _value) on event by #'cddr
                       unless (memq key '(:type :step :run))
                       collect (substring (symbol-name key) 1))))
    (if keys (mapconcat #'identity keys " ") "nothing")))

(defun chat-ui--agent-stop-summary (reason)
  "Return a precise user-facing summary for agent stop REASON."
  (pcase reason
    ('max-steps
     (format "Stopped after step limit (%s)"
             (chat-agent-budget-label (chat-ui--step-limit))))
    ('active-plan-unclosed
     "Stopped because the durable work plan remains open")
    ('work-plan-blocked
     "Stopped because the durable work plan is blocked")
    (_ (format "Stopped (%s)" (or reason "unknown reason")))))

(defun chat-ui--make-agent-event-handler (session msg-id ui-buffer content-start request-id)
  "Return an agent event handler rendering into UI-BUFFER.
SESSION, MSG-ID, CONTENT-START, and REQUEST-ID identify the pending
assistant response being filled in."
  (let ((tool-events nil))
    (lambda (event)
      (let ((type (plist-get event :type)))
        (when (buffer-live-p ui-buffer)
          (with-current-buffer ui-buffer
            (chat-ui--project-runtime-event type event)))
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
               (chat-ui--request-live-detail)))))
         ((eq type 'stream-reasoning)
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              ;; `:reasoning' is the accumulation; `:text' is only the
              ;; latest delta.  The chunk event names its two the other way
              ;; round, as `:content' and `:text'.
              (setq chat-ui--live-reasoning-content
                    (or (plist-get event :reasoning) ""))
              (chat-ui--render-response-state
               ui-buffer
               content-start
               chat-ui--live-response-content
               tool-events
               (chat-ui--request-live-detail)))))
         ((eq type 'model-tool-call-delta)
          ;; Transport telemetry is persisted by the wire observer.  The
          ;; transcript renders completed tool activity and final text, so
          ;; partial call arguments and token counters need no visible row.
          nil)
         ((eq type 'model-request-started)
          (when request-id
            (chat-request-diagnostics-record
             request-id 'model-request-started
             :provider (plist-get event :provider)
             :model (plist-get event :model)
             :request-id (plist-get event :request-id)
             :summary
             (format "Requested %s/%s"
                     (plist-get event :provider)
                     (plist-get event :model)))))
         ((eq type 'model-usage)
          nil)
         ((eq type 'model-switched)
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (let ((target
                     (chat-model-selection-target
                      (plist-get event :provider)
                      (plist-get event :model))))
                (chat-ui--activate-model-target
                 target (plist-get event :operation-id))
                (chat-ui--redraw-conversation)))))
         ((eq type 'model-retry)
          ;; Runtime projection keeps the visible phase active while the
          ;; bounded wire record explains why this model request restarted.
          nil)
         ((eq type 'tool-event)
          (setq tool-events (append tool-events
                                    (list (plist-get event :event))))
          ;; Tool activity belongs on the request's own record, not only in
          ;; this buffer's list.  The stall check is given a request id and
          ;; nothing else, so a tool that started and has not finished was
          ;; invisible to it -- which is how a working subagent came to be
          ;; reported as a stalled stream.
          (when request-id
            (chat-request-diagnostics-record-tool-event
             request-id (plist-get event :event)))
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
              (let ((window-state
                     (chat-ui--capture-live-window-state ui-buffer)))
                (setq chat-ui--live-response-content "")
                (setq chat-ui--live-reasoning-content "")
                (setq chat-ui--live-trailers
                      (list :detail (chat-ui--request-live-detail)
                            :permission-failure
                            (chat-ui--latest-permission-failure tool-events)))
                (chat-ui--redraw-conversation)
                (chat-ui--follow-live-output ui-buffer window-state)))))
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
               (chat-ui--request-live-detail)))))
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
         ((eq type 'work-plan-finalization)
          (when request-id
            (chat-request-diagnostics-record
             request-id
             'work-plan-finalization
             :summary
             (format "%s durable work plan %s at revision %s"
                     (if (eq (plist-get event :action) 'retry)
                         "Settling" "Stopped with")
                     (or (plist-get event :plan-id) "unknown")
                     (or (plist-get event :revision) "unknown"))))
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (chat-ui--refresh-live-surfaces))))
         ((eq type 'agent-end)
          (setq chat-ui--active-agent-run nil)
          (setq chat-ui--active-request-handle nil)
          (setq chat-ui--active-stream-process nil)
          (pcase (plist-get event :status)
            ((or 'completed 'stopped)
             (let* ((stopped (eq (plist-get event :status) 'stopped))
                    (reason (plist-get event :reason))
                    (summary (if stopped
                                 (chat-ui--agent-stop-summary reason)
                               "Request completed")))
               (when (buffer-live-p ui-buffer)
                 (with-current-buffer ui-buffer
                   (chat-ui--record-terminal-marker
                    (chat-ui--terminal-run-marker
                     session (if stopped 'stopped 'completed)
                     (and stopped summary)))
                   (chat-ui--cleanup-request-state
                    (if stopped 'stopped 'completed) summary)))
               (message "%s" summary)
               (chat-ui--finalize-response
                session
                msg-id
                ui-buffer
                content-start
                (list :content (plist-get event :content)
                      :tool-events (plist-get event :tool-events)
                      :stop-reason reason
                      :tool-loop-limit-reached (eq reason 'max-steps)))
               ;; The marker is on the record; redraw once so it renders
               ;; from there, alongside the trailers the final draw left
               ;; in the live tail.
               (when (buffer-live-p ui-buffer)
                 (with-current-buffer ui-buffer
                   (let ((window-state
                          (chat-ui--capture-live-window-state ui-buffer)))
                     (chat-ui--redraw-conversation)
                     (chat-ui--follow-live-output ui-buffer
                                                  window-state))))))
            ('cancelled
             (when (buffer-live-p ui-buffer)
               (with-current-buffer ui-buffer
                 (chat-ui--record-terminal-marker
                  (chat-ui--terminal-run-marker session 'cancelled nil))
                 (chat-ui--cleanup-request-state
                  'cancelled "Cancelled by user")
                 (chat-ui--draw-terminal-marker-row
                  (car (last (chat-session-messages session))))))
             (message "Response cancelled"))
            ('error
             (let ((marker
                    (and (buffer-live-p ui-buffer)
                         (with-current-buffer ui-buffer
                           (chat-ui--terminal-run-marker
                            session 'error
                            (or (plist-get event :reason)
                                "Unknown error"))))))
               (chat-ui--render-error
                ui-buffer
                (or (plist-get event :reason) "Unknown error"))
               (when (and marker (buffer-live-p ui-buffer))
                 (with-current-buffer ui-buffer
                   (chat-ui--record-terminal-marker marker)
                   (chat-ui--draw-terminal-marker-row marker))))
             (message "Error: %s" (plist-get event :reason))))
          (when (and (eq (plist-get event :status) 'stopped)
                     (chat-goal-current session)
                     (eq (chat-goal-status (chat-goal-current session))
                         'active))
            (chat-goal-mark-needs-attention
             session
             (pcase (plist-get event :reason)
               ('active-plan-unclosed
                "The Agent stopped with an open durable work plan.")
               ('work-plan-blocked
                "The Agent stopped because its durable work plan is blocked.")
               (_ "Agent step budget exhausted; send a message to continue."))))
          ;; After the status branches, and outside them, because waiting
          ;; meant waiting for an outcome and every one of these is one.
          (when (buffer-live-p ui-buffer)
            (with-current-buffer ui-buffer
              (chat-ui--drain-queued-sends))))
         ;; Nothing falls off the end.  The agent emits more kinds of event
         ;; than this handler names, and a `cond' with no final clause drops
         ;; the rest without a word -- which is how a minute of reasoning
         ;; went missing and looked like a hung screen rather than a bug.
         (t
          (chat-log "[UI] Unhandled agent event: %s (step %s, carries %s)"
                    type
                    (plist-get event :step)
                    (chat-ui--event-payload-keys event))))))))

(defun chat-ui--start-agent-run (transport)
  "Start an agent run for the current session through TRANSPORT."
  (message "%s" (chat-i18n 'response-starting "Getting response from AI..."))
  (let* ((session chat--current-session)
         (provider (chat-session-model-id session))
         (model (or (chat-session-model-name session)
                    (plist-get (chat-llm-get-provider-config provider) :model)))
         ;; The session records more than a request should carry: command
         ;; replies and captured shell output are there for the reader.
         (messages (chat-transcript-model-messages
                    (chat-session-messages session)))
         (msg-id (chat-session-new-message-id))
         (ui-buffer (current-buffer))
         (request-id
          (chat-ui--begin-request session provider model transport))
         ;; No header is drawn up front: the tail draws its own once
         ;; there is something under it, and until then the narrative
         ;; line is what says the request is in flight.  A header planted
         ;; here would be a second one.
         (assistant-start chat-ui--live-start))
    (setq chat-ui--live-response-content "")
    (setq chat-ui--live-reasoning-content "")
    (setq chat-ui--live-trailers nil)
    (setq chat-ui--last-render nil)
    ;; Drawn and painted here, before the transport is prepared, because
    ;; nothing had put a frame on screen between RET and the request going
    ;; out: the question was in the buffer but unpainted, and the live line
    ;; waited on a refresh timer a second away.  What the reader saw was
    ;; their question and the waiting state arriving together once the
    ;; request was already on the wire, which reads as the send having
    ;; waited for it.
    ;;
    ;; The paint goes here, ahead of the preparation, rather than being
    ;; relied on to happen afterwards: measured in a real session, 28ms
    ;; stand between RET and this point and a few hundred more follow it.
    ;; Whatever those turn out to cost, the reader sees their question
    ;; first.
    ;;
    ;; Forced, because the plain `redisplay' does nothing at all when any
    ;; input is pending and returns nil to say so.  A send is exactly the
    ;; moment something is likely to be queued -- a held key, an autorepeat,
    ;; a second RET -- so the one paint standing between the keystroke and
    ;; the request was the one most liable to be skipped, and skipping it
    ;; puts the reader back to seeing nothing until the command returns.
    (chat-ui--render-live-region)
    (chat-ui--clock "live")
    (redisplay t)
    ;; The one mark worth having: everything before it is what stands
    ;; between the keystroke and the reader seeing their own question, and
    ;; the paint's own cost is invisible anywhere but a real frame.
    (chat-ui--clock "PAINT")
    ;; Each preparation phase is recorded as it is passed, so a send that
    ;; never returns leaves the phase it died in as the trace's last word
    ;; -- "Preparing stream request" alone could mean anything between the
    ;; keystroke and the wire.
    (chat-request-diagnostics-record
     request-id 'context-preparing
     :summary "Preparing context and the tool prompt")
    (let* ((messages-with-tools
            (prog1 (chat-ui--prepare-messages-with-tools messages)
              (chat-ui--clock "tools"))))
      (chat-request-diagnostics-record
       request-id 'context-prepared
       :summary "Context and tool prompt ready; starting the agent run")
      ;; Handed over unprepared, because the run prepares the context
      ;; before every step including the first.  Doing it here as well
      ;; compacted the same history twice per send, and a compaction
      ;; rewrites the whole session file.
      (chat-log "[UI] Starting %s agent run with %d messages"
                transport (length messages-with-tools))
      (setq chat-ui--active-agent-run
            (chat-agent-start
             (list :provider provider
                   :model model
                   :messages messages-with-tools
                   :session session
                   :track-task t
                   :task-title (chat-session-name session)
                   :profile (plist-get (chat-session-tool-config session)
                                       :profile)
                   :project-root (chat-ui--path-completion-root)
                   :context-target-path
                   (or (chat-session-working-directory session)
                       default-directory)
                   :context-fragments (chat-ui--standing-context session)
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
                          :max-tokens (chat-ui--request-output-budget provider)
                          :timeout chat-ui-request-timeout)
                    (when request-id
                      (list :request-id request-id)))
                   :followup-request-options
                   (list :timeout chat-ui-tool-followup-timeout)
                   :followup-fn (chat-ui--goal-followup-function session)
                   :on-event
                   (chat-ui--make-agent-event-handler
                    session msg-id ui-buffer assistant-start request-id))))
      ;; A queued message owns the model captured when it was submitted.
      ;; If an explicit switch was requested later, its first legal boundary
      ;; is this new run's continuation, not the queued message's first request.
      (chat-ui--schedule-session-model-switch chat-ui--active-agent-run)
      (chat-ui--clock "start")
      (chat-ui--clock-report (format "%s send" transport)))))

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
       tool-events nil tool-summary limit-reached))
    ;; No second pass over the whole conversation to add styling.  The one
    ;; that used to be here ran only here, so the next redraw -- a fold, a
    ;; reopen, an appended message -- dropped the headings and the bold it
    ;; had added, and the streaming path and the redraw path had produced
    ;; different styling for the same text all along.  Both go through the
    ;; renderer now, from the same recorded Markdown.
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
      (let ((diagnostic
             (chat-runtime-status-diagnostic-for-message error-message)))
        (save-excursion
          (goto-char chat-ui--messages-end)
          ;; Through the renderer too: an error message often quotes a path
          ;; or a command, and a provider's message is frequently Markdown.
          (chat-ui--insert-formatted-response
           (format "[Error: %s]\n\nNext: %s"
                   error-message
                   (chat-runtime-status-action diagnostic)))
          (insert "\n\n")
          (set-marker chat-ui--messages-end (point)))))))

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
(defun chat-set-model (model &optional model-name)
  "Prepare provider MODEL and MODEL-NAME for the next submitted input.

Every session stores its own provider, so `chat-default-model' only
decides what new sessions start with; a session restored from disk keeps
whatever it was created with, even after the default changes or its
provider stops working. This command persists a separate prepared target;
the active target changes only when a submitted input crosses its boundary.

MODEL-NAME pins which of that provider's models to ask for.  Given
together rather than in two steps on purpose: between changing the
provider and changing the name the session would be pointing at a new
vendor with the old vendor's model id, which is nobody's valid pairing.

Left out, any name the session had pinned is dropped, because a model id
belongs to the vendor that serves it -- carrying `k3' over to DeepSeek
would produce a request only the vendor can refuse.  The session then
resolves the new provider's current default into one concrete prepared target.

The active request target is deliberately unchanged.  The prompt marks
the prepared target dirty until a real message or `/model' transition
reaches a request boundary."
  (interactive
   (list (intern
          (completing-read
           "Model: "
           (mapcar #'symbol-name (chat-ui--offered-providers))
           ;; Offers what is configured but accepts what is registered: a
           ;; key set moments from now is a reason to switch, and the
           ;; check below still catches a name that is nobody's provider.
           nil nil nil nil
           (when-let ((provider (chat-ui--session-provider)))
             (symbol-name provider))))))
  (unless chat--current-session
    (user-error "No chat session in this buffer"))
  (let ((target (chat-model-selection-target model model-name))
        (superseded (chat-model-selection-pending chat--current-session)))
    ;; A manual prompt choice is newer intent than an un-applied command.
    (chat-model-selection-prepare chat--current-session target)
    (when (and superseded
               (chat-agent-active-p chat-ui--active-agent-run))
      (chat-agent-cancel-model-switch
       chat-ui--active-agent-run (alist-get 'id superseded)))
    (chat-ui--render-live-region))
  (chat-ui--render-input-prompt)
  (message "Model prepared for the next send: %s"
           (chat-model-target-model
            (chat-model-selection-prepared chat--current-session))))

(defun chat-ui--model-target-candidates ()
  "Return configured model targets as (DISPLAY . TARGET) pairs."
  (apply
   #'append
   (mapcar
    (lambda (vendor)
      (when-let* ((provider (chat-llm-vendor-primary-provider vendor)))
        (mapcar
         (lambda (model)
           (cons (format "%s/%s" provider model)
                 (chat-model-selection-target provider model)))
         (chat-llm-provider-models provider))))
    (chat-ui--offered-vendors))))

(defun chat-ui--resolve-model-target (text)
  "Resolve TEXT to exactly one configured model target."
  (let* ((text (string-trim (chat-command-fold-name (or text ""))))
         (candidates (chat-ui--model-target-candidates))
         (direct (cdr (assoc-string text candidates t))))
    (cond
     (direct direct)
     ((string-empty-p text) nil)
     ((string-match "\\`\\([^/[:space:]]+\\)[/[:space:]]+\\(.+\\)\\'" text)
      (chat-model-selection-target
       (intern (downcase (match-string 1 text)))
       (match-string 2 text)))
     ((chat-llm-get-provider-config (intern (downcase text)))
      (chat-model-selection-target (intern (downcase text))))
     (t
      (let ((matches
             (seq-filter
              (lambda (entry)
                (equal (downcase text)
                       (downcase (chat-model-target-model (cdr entry)))))
              candidates)))
        (cond
         ((null matches) (user-error "Unknown model target: %s" text))
         ((cdr matches) (user-error "Ambiguous model target: %s" text))
         (t (cdar matches))))))))

(defun chat-ui--read-model-target (&optional event)
  "Read one configured model target, using popup EVENT when possible."
  (let ((groups (chat-ui--model-choices)))
    (cond
     ((null groups) (user-error "No providers are configured"))
     ((and event (display-popup-menus-p) (listp event))
      (when-let ((chosen (x-popup-menu
                          event
                          (cons (chat-i18n 'switch-model-title "Model") groups))))
        (chat-model-selection-target (car chosen) (cdr chosen))))
     (t
      (let* ((candidates (chat-ui--model-target-candidates))
             (name (completing-read "Model: " (mapcar #'car candidates) nil t)))
        (cdr (assoc name candidates)))))))

(defun chat-ui--pending-model-switch-source (pending)
  "Return PENDING's source as a symbol."
  (let ((source (alist-get 'source pending)))
    (if (symbolp source) source (and source (intern source)))))

(defun chat-ui--model-switch-request-options (run target)
  "Return complete request options for RUN after switching to TARGET."
  (let ((options (copy-tree (chat-agent-run-state-request-options run))))
    (setq options
          (plist-put options :max-tokens
                     (chat-ui--request-output-budget
                      (chat-model-target-provider target))))
    (plist-put options :model (chat-model-target-model target))))

(defun chat-ui--append-applied-model-switch (pending target)
  "Record applied PENDING for TARGET as display-only transcript history."
  (when (eq (chat-ui--pending-model-switch-source pending) 'command)
    (chat-session-add-message
     chat--current-session
     (chat-transcript-stamp
      (make-chat-message
       :id (or (alist-get 'id pending) (chat-session-new-message-id))
       :role :system
       :content (format "Model switched to %s/%s"
                        (chat-model-target-provider target)
                        (chat-model-target-model target))
       :metadata (list :model-switch-id (alist-get 'id pending)
                       :provider (chat-model-target-provider target)
                       :model (chat-model-target-model target))
       :timestamp (current-time))
      :category 'command-reply))))

(defun chat-ui--activate-model-target (target &optional operation-id)
  "Activate TARGET for the current session and return consumed operation."
  (let ((pending (chat-model-selection-activate
                  chat--current-session target operation-id)))
    (when pending
      (chat-ui--append-applied-model-switch pending target))
    (chat-ui--render-status-line)
    (chat-ui--render-input-prompt)
    pending))

(defun chat-ui--request-model-switch (target source)
  "Request TARGET for the next boundary, attributed to SOURCE."
  (let* ((pending (chat-model-selection-request
                   chat--current-session target source))
         (operation-id (alist-get 'id pending)))
    (when (chat-agent-active-p chat-ui--active-agent-run)
      (chat-agent-schedule-model-switch
       chat-ui--active-agent-run
       (chat-model-target-provider target)
       (chat-model-target-model target)
       operation-id source
       (chat-ui--model-switch-request-options
        chat-ui--active-agent-run target)))
    (chat-ui--render-input-prompt)
    (chat-ui--render-live-region)
    pending))

(defun chat-ui--schedule-session-model-switch (run)
  "Schedule the current session switch on RUN's next continuation boundary."
  (when-let* ((pending (and chat--current-session
                            (chat-model-selection-pending
                             chat--current-session)))
              (target (chat-model-selection-pending-target
                       chat--current-session)))
    (when (and (chat-agent-active-p run)
               (not
                (chat-model-selection-target-equal-p
                 target
                 (make-chat-model-target
                  :provider (chat-agent-run-state-provider run)
                  :model (chat-agent-run-state-model run)))))
      (chat-agent-schedule-model-switch
       run
       (chat-model-target-provider target)
       (chat-model-target-model target)
       (alist-get 'id pending)
       (chat-ui--pending-model-switch-source pending)
       (chat-ui--model-switch-request-options run target)))))

(defun chat-ui--offered-providers ()
  "Return the providers worth offering a reader, in display order.

Only the ones with a key, because chat.el registers every vendor it knows
how to speak to whether or not this machine has an account with it --
sixteen of them, of which a typical configuration reaches two.  Offering
the register was offering a catalogue and calling it a choice.

Sensed rather than declared: there is no list to maintain, and a key
added or removed shows up the next time the prompt is drawn.

The active and prepared providers are both included without a key, since
the prompt must show where it is, where it is going, and let the user leave."
  (let ((configured (chat-llm-configured-providers))
        (active (and chat--current-session
                     (chat-session-model-id chat--current-session)))
        (prepared (chat-ui--session-provider)))
    (delete-dups (append (delq nil (list active prepared)) configured))))

(defun chat-ui--vendor-label (vendor provider)
  "Return the display name for VENDOR, reached through PROVIDER."
  (let ((name (plist-get (chat-llm-get-provider-config provider) :name)))
    ;; A vendor serving two protocols names them apart -- \"Kimi Code\"
    ;; and \"Kimi Code (Anthropic)\".  The group is the vendor, so the
    ;; protocol's parenthetical does not belong in its heading.
    (if (and name (string-match "\\`\\(.*?\\)[ ]*(\\(?:.*\\))\\'" name))
        (match-string 1 name)
      (or name (symbol-name vendor)))))

(defun chat-ui--model-choices ()
  "Return what to offer, grouped by vendor.

A list of (VENDOR-LABEL . ITEMS), where each item is
\(MODEL-LABEL PROVIDER . MODEL-NAME).  Two levels because vendor and
model are two questions: a flat list of every provider read as one
vendor per protocol variant and no models at all.

Only the vendor's primary provider contributes models, so a vendor
reachable over two protocols appears once."
  (delq nil
        (mapcar
         (lambda (vendor)
           (when-let* ((provider (chat-llm-vendor-primary-provider vendor))
                       (models (chat-llm-provider-models provider)))
             (cons (chat-ui--vendor-label vendor provider)
                   (mapcar
                    (lambda (model)
                      ;; The reader's first question on opening the menu
                      ;; is where they already are.
                      (let ((prepared (and chat--current-session
                                           (chat-model-selection-prepared
                                            chat--current-session))))
                        (cons (if (and prepared
                                       (eq provider
                                           (chat-model-target-provider prepared))
                                       (equal model
                                              (chat-model-target-model prepared)))
                                (concat "* " model)
                              (concat "  " model))
                              (cons provider model))))
                    models))))
         (chat-ui--offered-vendors))))

(defun chat-ui--session-provider ()
  "Return the provider prepared at the current session prompt."
  (and chat--current-session
       (chat-model-target-provider
        (chat-model-selection-prepared chat--current-session))))

(defun chat-ui--offered-vendors ()
  "Return the vendors worth offering, the session's own included."
  (let* ((vendors (chat-llm-configured-vendors))
         (current (when-let ((provider (chat-ui--session-provider)))
                    (chat-llm-provider-vendor provider))))
    (if (and current (not (memq current vendors)))
        (cons current vendors)
      vendors)))

(defun chat-ui--model-choice-count ()
  "Return how many model choices there are across all vendors."
  (apply #'+ (mapcar (lambda (group) (length (cdr group)))
                     (chat-ui--model-choices))))

(defun chat-ui-switch-model (&optional event)
  "Prepare the model used by the next submitted input, from a menu.

Bound to a click on the model named in the prompt, which is where the
reader is already looking when they want to change it -- the model was
visible in one place and changeable in another.

Grouped by vendor, one item per model.  Falls back to the minibuffer
where a popup menu cannot be drawn, because Emacs in a terminal is not an
edge case.  Selection is preparation only; it never mutates an in-flight
request."
  (interactive (list last-nonmenu-event))
  (let ((groups (chat-ui--model-choices)))
    (cond
     ((null groups)
      (user-error "No providers are configured"))
     ((= (chat-ui--model-choice-count) 1)
      (message "%s" (chat-i18n 'only-one-provider
                               "Only one model is configured")))
     (t
      (when-let ((target (chat-ui--read-model-target event)))
        (chat-set-model (chat-model-target-provider target)
                        (chat-model-target-model target)))))))

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

The builtins that change this session are handled here rather than in the
shell, because a subprocess cannot move its parent's working directory or
set its parent's environment: run there, they would succeed and change
nothing that outlives them.  Everything else goes to a real shell."
  (let* ((trimmed (string-trim command))
         (builtin (chat-shell-builtins-parse trimmed)))
    (if builtin
        (chat-ui--handle-shell-builtin builtin)
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
own `cd' applies to that subprocess only.  A bare `cd' means home and `-'
means the directory before this one, as they do in a shell."
  (let ((parsed (chat-shell-builtins-parse command)))
    (when (eq (plist-get parsed :builtin) 'cd)
      (chat-shell-builtins-resolve-directory (plist-get parsed :arg)))))

(defun chat-ui--change-directory (directory &optional quiet)
  "Point this session at DIRECTORY, reporting it unless QUIET.

Records it on the session so it outlives the buffer, and sets the buffer
default so typed shell commands and the tools the agent runs share one
working directory.  Returns non-nil when the directory changed.

DIRECTORY may be a cons of `error' and a reason, which is how `cd -'
reports that there is nowhere to go back to yet."
  (if (eq (car-safe directory) 'error)
      (progn (chat-ui--insert-system-message (cdr directory)) nil)
    (let* ((requested (chat-command-fold-path (string-trim directory)))
           (expanded (expand-file-name requested)))
      (if (not (file-directory-p expanded))
          (progn
            (chat-ui--insert-system-message
             (chat-i18n 'directory-missing "❌ Directory not found: %s" requested))
            nil)
        ;; Recorded before the move, so `cd -' has somewhere to return to.
        (chat-shell-builtins-record-departure default-directory)
        (setq default-directory (file-name-as-directory expanded))
        (when chat--current-session
          (chat-session-set-working-directory chat--current-session
                                              default-directory))
        (unless quiet
          (chat-ui--insert-system-message
           (chat-i18n 'directory-changed "📁 Changed directory to: %s"
                      default-directory)))
        t))))

(defun chat-ui--handle-shell-builtin (parsed)
  "Act on PARSED, a builtin described by `chat-shell-builtins-parse'."
  (pcase (plist-get parsed :builtin)
    ('cd
     (chat-ui--change-directory
      (chat-shell-builtins-resolve-directory (plist-get parsed :arg))))
    ('pushd
     (let ((here default-directory)
           (target (plist-get parsed :arg)))
       (when (chat-ui--change-directory
              (chat-shell-builtins-resolve-directory target) t)
         (chat-shell-builtins-push-directory here)
         (chat-ui--insert-system-message
          (chat-shell-builtins-directory-stack-report default-directory)))))
    ('popd
     (let ((target (chat-shell-builtins-pop-directory)))
       (if (not target)
           (chat-ui--insert-system-message
            (chat-i18n 'shell-empty-directory-stack "popd: directory stack empty"))
         (when (chat-ui--change-directory target t)
           (chat-ui--insert-system-message
            (chat-shell-builtins-directory-stack-report default-directory))))))
    ('dirs
     (chat-ui--insert-system-message
      (chat-shell-builtins-directory-stack-report default-directory)))
    ('export
     (let ((assignment (chat-shell-builtins-parse-assignment
                        (plist-get parsed :arg))))
       (if (not assignment)
           (chat-ui--insert-system-message
            (chat-i18n 'shell-bad-assignment "export: not a valid name"))
         (chat-shell-builtins-set-variable (car assignment) (cdr assignment))
         (chat-ui--insert-system-message
          (format "%s=%s" (car assignment) (cdr assignment))))))
    ('unset
     (chat-shell-builtins-unset-variable (plist-get parsed :arg))
     (chat-ui--insert-system-message
      (chat-i18n 'shell-unset "unset %s" (plist-get parsed :arg))))))

(defun chat-ui--repeat-shell-command ()
  "Run the shell command this buffer ran most recently."
  (if chat-ui--last-shell-command
      (chat-ui--handle-shell-command chat-ui--last-shell-command)
    (chat-ui--insert-system-message
     (chat-i18n 'shell-nothing-to-repeat "⚠️ No shell command to repeat yet"))))

(defun chat-ui--execute-shell-safe (command)
  "Run COMMAND for the chat buffer and return its output.

Runs with whatever this buffer has exported, so a variable set on one line
is there on the next.  Every command is its own subshell, so without this
an `export' would reach only the process that performed it: the variable
would appear to be set and then not be, which is worse than declining to
set it."
  (let ((process-environment (chat-shell-builtins-process-environment)))
    (chat-ui--execute-shell-safe-1 command)))

(defun chat-ui--execute-shell-safe-1 (command)
  "Run COMMAND and return its output."
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
        (chat-model-request-result
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
    ;; A quick answer is Markdown for the same reason a long one is.  It
    ;; used to be inserted raw, so the same reply looked different
    ;; depending on which command had asked for it.
    (chat-ui--insert-formatted-response content)
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
      (setq chat-ui--pending-content-parts
            (seq-remove
             (lambda (part) (eq (chat-content-part-type part) 'text))
             (chat-message-parts user-msg)))
      (chat-ui--rebuild-buffer (chat-message-text user-msg)))))

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


;;;###autoload
(defun chat-ui-cancel-response ()
  "Cancel the current agent run or in flight request."
  (interactive)
  (cond
   ((chat-agent-active-p chat-ui--active-agent-run)
    (chat-agent-cancel chat-ui--active-agent-run)
    (message "Response cancelled"))
   ((or chat-ui--active-request-handle
        (and chat-ui--active-stream-process
             (process-live-p chat-ui--active-stream-process)))
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
      (setq chat-ui--active-stream-process nil))
    (chat-ui--cleanup-request-state 'cancelled "Cancelled by user")
   (message "Response cancelled"))
   (t
    (message "No response is currently running"))))

(chat-event-add-observer #'chat-ui--observe-work-shelf-event)
(chat-event-add-observer #'chat-ui--observe-runtime-event)

(provide 'chat-ui)
;;; chat-ui.el ends here
