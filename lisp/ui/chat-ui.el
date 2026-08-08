;;; chat-ui.el --- UI components for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, ui

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides UI components and interaction for chat sessions.

;;; Code:

(require 'chat-session)
(require 'chat-llm)
(require 'chat-stream)
(require 'chat-tool-forge-ai)
(require 'chat-tool-caller)
(require 'chat-context)
(require 'chat-log)
(require 'chat-request-diagnostics)
(require 'chat-request-panel)
(require 'chat-request-surface)
(require 'chat-status)
(require 'chat-agent)

;; ------------------------------------------------------------------
;; Chat Buffer Management
;; ------------------------------------------------------------------

(defvar chat--current-session nil
  "Current chat session bound by chat buffers.")

(defvar chat-ui-use-streaming nil
  "Whether chat UI should use streaming responses.")

(defvar chat-ui--active-stream-process nil
  "Currently active stream process for cancellation.")

(defvar chat-ui--input-overlay nil
  "Overlay for the input area in chat buffer.")

(defvar chat-ui--messages-end nil
  "Marker for end of messages area.")

(defvar chat-ui--active-request-handle nil
  "Currently active non streaming request handle.")

(defvar chat-ui--active-agent-run nil
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

(defvar-local chat-ui--live-response-start nil
  "Marker at the current assistant response body.")

(defvar-local chat-ui--live-response-content ""
  "Accumulated visible content for the current live response.")

(defvar-local chat-ui--last-render nil
  "Last rendered slot state used by the streaming fast path.")

(defun chat-ui--pending-approval-event ()
  "Return the current pending approval event when present."
  (chat-status-persistent-event chat-ui--request-tool-events))

(defun chat-ui--status-line (session)
  "Return top status line text for SESSION."
  (let ((model (and session (chat-session-model-id session))))
    (if-let ((label (chat-status-persistent-label chat-ui--request-tool-events)))
        (format "Model: %s | %s" model label)
      (format "Model: %s" model))))

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
  (and chat--current-session
       (plist-get (chat-session-metadata chat--current-session) key)))

(defun chat-ui--session-metadata-set (key value)
  "Store VALUE under KEY in the current session metadata."
  (when chat--current-session
    (setf (chat-session-metadata chat--current-session)
          (plist-put (chat-session-metadata chat--current-session) key value))
    (when chat-session-auto-save
      (chat-session-save chat--current-session))))

(defun chat-ui--track-tool-targets (tool-events)
  "Update recent file target state from TOOL-EVENTS."
  (when-let ((target-data (chat-request-surface-tool-targets tool-events)))
    (let ((all-paths (plist-get target-data :paths))
          (latest-single-target (plist-get target-data :latest-single-target)))
      (setq chat-ui--last-tracked-tool-paths all-paths)
      (chat-ui--session-metadata-set :chat-ui-recent-target-paths all-paths)
      (when latest-single-target
        (chat-ui--session-metadata-set
         :chat-ui-preferred-target-path
         (chat-files--resolved-path latest-single-target))))))

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
  "Refresh the transcript live response slot from SNAPSHOT."
  (when (and chat-ui--live-response-start
             (marker-buffer chat-ui--live-response-start))
    (chat-ui--render-response-state
     (current-buffer)
     chat-ui--live-response-start
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
  (setq chat-ui--live-response-start nil)
  (setq chat-ui--live-response-content "")
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
  (setq chat-ui--live-response-start nil)
  (setq chat-ui--live-response-content "")
  (chat-request-panel-close (current-buffer))
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize (format "═══ %s ═══\n" (chat-session-name session))
                       'face 'header-line))
    (insert (propertize (format "%s\n\n" (chat-ui--status-line session))
                       'face 'shadow))
    (dolist (msg (chat-session-messages session))
      (chat-ui--insert-message msg))
    (setq chat-ui--messages-end (point-marker))
    (chat-ui--setup-input-area)))

(defun chat-ui--insert-message (msg)
  "Insert message MSG into buffer."
  (let* ((role (chat-message-role msg))
         (content (chat-message-content msg))
         (role-face (pcase role
                      (:user 'font-lock-keyword-face)
                      (:assistant 'font-lock-function-name-face)
                      (:system 'font-lock-comment-face)
                      (_ 'default)))
         (role-name (pcase role
                      (:user "You")
                      (:assistant "Assistant")
                      (:system "System")
                      (_ (symbol-name role)))))
    (insert (propertize (format "%s:\n" role-name) 'face role-face))
    (insert content)
    (insert "\n\n")))

(defun chat-ui--setup-input-area ()
  "Setup the input area at bottom of buffer."
  (goto-char (point-max))
  (insert (propertize "───\n" 'face 'shadow))
  (insert "> ")
  (setq chat-ui--input-overlay (point-marker)))

;; ------------------------------------------------------------------
;; Message Sending
;; ------------------------------------------------------------------

(defun chat-ui-send-message ()
  "Send message from input area."
  (interactive)
  (when chat--current-session
    (if (chat-ui--response-active-p)
        (message "A response is already in progress. Cancel it before sending another message.")
      (let* ((input-start (marker-position chat-ui--input-overlay))
             (input-end (point-max))
             (content (string-trim (buffer-substring-no-properties input-start input-end))))
        ;; Check for empty message
        (if (string-empty-p content)
            (message "Cannot send empty message")
          ;; Clear input
          (delete-region input-start input-end)
          (goto-char input-start)
          ;; Check for special prefixes and commands
          (cond
           ;; Cancel current request
           ((string-equal "/cancel" content)
            (chat-ui-cancel-response)
            (message "Request cancelled."))
           ;; Shell command with ! prefix
           ((string-prefix-p "!" content)
            (chat-ui--handle-shell-command (substring content 1)))
           ;; Direct AI query with ? prefix
           ((string-prefix-p "?" content)
            (chat-ui--handle-direct-query (substring content 1)))
           ;; Tool creation request
           ((chat-tool-forge-ai--tool-request-p content)
            (chat-ui--handle-tool-creation content))
           ;; Normal message flow
           (t
            (let ((user-msg (make-chat-message
                            :id (chat-session-new-message-id)
                            :role :user
                            :content content
                            :timestamp (current-time))))
              (chat-session-add-message chat--current-session user-msg)
              ;; Insert in buffer
              (save-excursion
                (goto-char chat-ui--messages-end)
                (chat-ui--insert-message user-msg)
                (set-marker chat-ui--messages-end (point)))
              ;; Get AI response
              (chat-ui--get-response)))))))))

(defun chat-ui--followup-target-note ()
  "Return a system note about the most recent file target."
  (when-let ((target (chat-ui--session-metadata-get :chat-ui-preferred-target-path)))
    (format
     "Recent file target for follow-up requests: %s\nUse it only when the user refers implicitly to the same file or asks to continue the last file task."
     target)))

(defun chat-ui--prepare-messages-with-tools (messages)
  "Prepare message list with tool calling system prompt."
  (if (not chat-tool-caller-enabled)
      (progn
        (chat-log "[TOOLS] Tool calling disabled, using original messages")
        messages)
    (let* ((base-prompt "You are a helpful AI assistant.")
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
           (system-prompt (chat-tool-caller-build-system-prompt prompt)))
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

(defun chat-ui--render-response-state (ui-buffer content-start content tool-events
                                                 &optional live-detail)
  "Render CONTENT, TOOL-EVENTS, and optional LIVE-DETAIL at CONTENT-START."
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
      (save-excursion
        (let ((inhibit-read-only t))
          (goto-char (point-min))
          (forward-line 1)
          (delete-region (line-beginning-position) (line-end-position))
          (insert (propertize
                   (chat-ui--status-line
                    (and (boundp 'chat--current-session)
                         chat--current-session))
                   'face 'shadow))
          (let* ((last chat-ui--last-render)
                 (old-content (and last (plist-get last :content)))
                 (fast (and old-content
                            (eq (plist-get last :content-start) content-start)
                            (= (plist-get last :event-count)
                               (length tool-events))
                            (string-prefix-p old-content content))))
            (if fast
                ;; Streaming fast path: only the tail changed.
                (progn
                  (goto-char (+ (marker-position content-start)
                                (length old-content)))
                  (delete-region (point) chat-ui--messages-end)
                  (insert (substring content (length old-content))))
              (delete-region content-start chat-ui--messages-end)
              (goto-char content-start)
              (unless (string-empty-p content)
                (insert content)))
            (when-let ((line (chat-ui--live-narrative-line live-detail)))
              (unless (string-empty-p content)
                (insert "\n"))
              (insert line))
            (insert "\n\n")
            (set-marker chat-ui--messages-end (point))
            (setq chat-ui--last-render
                  (list :content content
                        :content-start content-start
                        :event-count (length tool-events)))))))))

(defun chat-ui--tool-result-lines (tool-calls tool-results)
  "Format TOOL-CALLS and TOOL-RESULTS into readable lines."
  (let (lines)
    (while (and tool-calls tool-results)
      (let* ((call (car tool-calls))
             (name (plist-get call :name))
             (arguments (plist-get call :arguments))
             (result (chat-tool-caller-truncate-result
                      (string-trim-right (or (car tool-results) "")))))
        (push (format "- %s %S => %s" name arguments result) lines))
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

(defcustom chat-ui-tool-loop-max-steps 100
  "Maximum number of tool loop follow-up requests."
  :type 'integer
  :group 'chat)

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
              (redisplay t))))
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
                      (format "Stopped after tool loop limit (%d)"
                              chat-ui-tool-loop-max-steps)
                    "Request completed"))))
             (chat-ui--finalize-response
              session
              msg-id
              ui-buffer
              content-start
              (list :content (plist-get event :content)
                    :tool-calls (plist-get event :tool-calls)
                    :tool-results (plist-get event :tool-results)
                    :tool-events (plist-get event :tool-events))
              (plist-get event :raw-request)
              (plist-get event :raw-response)))
            ('cancelled
             (when (buffer-live-p ui-buffer)
               (with-current-buffer ui-buffer
                 (chat-ui--cleanup-request-state
                  'cancelled "Cancelled by user"))))
            ('error
             (chat-ui--render-error
              ui-buffer
              (or (plist-get event :reason) "Unknown error"))))))))))

(defun chat-ui--start-agent-run (transport)
  "Start an agent run for the current session through TRANSPORT."
  (message "Getting response from AI...")
  (let* ((session chat--current-session)
         (model (chat-session-model-id session))
         (messages (chat-session-messages session))
         (msg-id (chat-session-new-message-id))
         (ui-buffer (current-buffer))
         assistant-start
         (request-id (chat-ui--begin-request session model transport)))
    (save-excursion
      (goto-char chat-ui--messages-end)
      (insert (propertize "Assistant:\n" 'face 'font-lock-function-name-face))
      (set-marker chat-ui--messages-end (point))
      (setq assistant-start (copy-marker (point))))
    (setq chat-ui--live-response-start assistant-start)
    (let* ((messages-with-tools (chat-ui--prepare-messages-with-tools messages))
           (messages-final (chat-context-prepare-messages messages-with-tools)))
      (chat-log "[UI] Starting %s agent run with %d messages"
                transport (length messages-final))
      (setq chat-ui--active-agent-run
            (chat-agent-start
             (list :model model
                   :messages messages-final
                   :session session
                   :transport transport
                   :max-steps chat-ui-tool-loop-max-steps
                   :request-options
                   (append
                    (list :temperature 0.7)
                    (when request-id
                      (list :request-id request-id)))
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

(defun chat-ui--finalize-response (session msg-id ui-buffer content-start processed
                                           &optional raw-request raw-response)
  "Render PROCESSED response and persist it for SESSION."
  (let* ((content (or (plist-get processed :content) ""))
         (tool-events (plist-get processed :tool-events))
         (tool-calls (plist-get processed :tool-calls))
         (tool-results (plist-get processed :tool-results))
         (tool-summary (chat-ui--format-tool-results tool-results))
         (history-content (if (and (string-blank-p content) tool-summary)
                              tool-summary
                            content)))
    (chat-ui--render-response-state ui-buffer content-start content tool-events)
    (when (buffer-live-p ui-buffer)
      (with-current-buffer ui-buffer
        (chat-ui--fontify-markdown-lite content-start chat-ui--messages-end)))
    (chat-session-add-message
     session
     (make-chat-message
      :id msg-id
      :role :assistant
      :content history-content
      :timestamp (current-time)
      :tool-calls tool-calls
      :tool-results tool-results
      :raw-request raw-request
      :raw-response raw-response))
    (chat-log "[UI] Response saved to session")))

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

(defun chat-ui--handle-tool-creation (content)
  "Handle tool creation request from CONTENT."
  ;; Show thinking message
  (save-excursion
    (goto-char chat-ui--messages-end)
    (insert (propertize "System:\n" 'face 'font-lock-comment-face))
    (insert "🔨 Creating tool from your request...\n\n")
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
               (insert (propertize "System:\n" 'face 'font-lock-comment-face))
               (insert (format "✅ Tool '%s' (%s) created and registered!\n\n"
                              (chat-forged-tool-name tool)
                              (chat-forged-tool-id tool)))
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
           (insert (propertize "System:\n" 'face 'font-lock-comment-face))
           (insert "❌ Failed to create tool. Please try again with a clearer description.\n\n")
           (set-marker chat-ui--messages-end (point))))))))

;; ------------------------------------------------------------------
;; Hybrid Mode - Shell & Direct Query
;; ------------------------------------------------------------------

(defun chat-ui--handle-shell-command (command)
  "Execute shell COMMAND and display result in chat buffer.
Handles special case: cd <dir> changes default-directory."
  (let* ((trimmed (string-trim command))
         ;; `string-match' (not -p) so `match-end' below sees this match.
         (is-cd (string-match "^cd\\s-+" trimmed)))
    (if (and is-cd (not (string-match-p ";\\|&&\\|||" trimmed)))
        ;; Handle cd specially
        (let ((dir (substring trimmed (match-end 0))))
          (setq dir (string-trim dir))
          ;; Expand ~ to home
          (when (string-prefix-p "~" dir)
            (setq dir (concat (getenv "HOME") (substring dir 1))))
          ;; Check if directory exists
          (if (file-directory-p dir)
              (progn
                (setq default-directory (file-name-as-directory (expand-file-name dir)))
                (chat-ui--insert-system-message (format "📁 Changed directory to: %s" default-directory)))
            (chat-ui--insert-system-message (format "❌ Directory not found: %s" dir))))
      ;; Normal shell command
      (progn
        (chat-ui--insert-system-message (format "$ %s" trimmed))
        (let ((output (chat-ui--execute-shell-safe trimmed)))
          (if output
              (chat-ui--insert-system-message output)
            (chat-ui--insert-system-message "⚠️ Shell execution disabled or failed")))))))

(defun chat-ui--execute-shell-safe (command)
  "Safely execute shell COMMAND and return output.
Uses chat-tool-shell if available, otherwise basic shell execution."
  (condition-case err
      (if (and (featurep 'chat-tool-shell)
               (fboundp 'chat-tool-shell-execute)
               (boundp 'chat-tool-shell-enabled)
               chat-tool-shell-enabled)
          ;; Use chat-tool-shell if available and enabled
          (chat-tool-shell-execute command)
        ;; Fallback to basic shell execution
        (with-output-to-string
          (with-current-buffer standard-output
            (call-process-shell-command command nil t))))
    (error (format "Error: %s" (error-message-string err)))))

(defun chat-ui--handle-direct-query (question)
  "Ask AI QUESTION directly without saving to session history.
This is an ephemeral query - the result is displayed but not persisted."
  (let ((trimmed (string-trim question)))
    (if (string-empty-p trimmed)
        (message "Empty question. Usage: ?<your question>")
      (chat-ui--insert-user-message (format "?%s" trimmed))
      (chat-ui--insert-system-message "🤖 Asking AI...")
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
               (chat-ui--insert-system-message (format "❌ Error: %s" err)))))
         '(:temperature 0.7))))))

(defun chat-ui--insert-system-message (content)
  "Insert a system message CONTENT into chat buffer."
  (save-excursion
    (goto-char chat-ui--messages-end)
    (insert (propertize "System:\n" 'face 'font-lock-comment-face))
    (insert content)
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui--insert-user-message (content)
  "Insert a user message CONTENT into chat buffer (ephemeral)."
  (save-excursion
    (goto-char chat-ui--messages-end)
    (insert (propertize "You:\n" 'face 'font-lock-keyword-face))
    (insert (propertize content 'face 'italic))
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

(defun chat-ui--insert-ephemeral-response (content)
  "Insert an ephemeral AI response CONTENT into chat buffer."
  (save-excursion
    (goto-char chat-ui--messages-end)
    ;; Remove the "Asking AI..." message
    (let ((search-start (max (point-min) (- chat-ui--messages-end 500))))
      (goto-char search-start)
      (when (search-forward "🤖 Asking AI..." chat-ui--messages-end t)
        (let ((beg (line-beginning-position)))
          (goto-char chat-ui--messages-end)
          (delete-region beg chat-ui--messages-end)
          (goto-char beg))))
    (insert (propertize "Assistant (quick):\n" 'face 'font-lock-function-name-face))
    (insert content)
    (insert "\n\n")
    (set-marker chat-ui--messages-end (point))))

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
      (chat-session-truncate-after-message
       chat--current-session
       (chat-message-id assistant-msg)
       t)
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
      (chat-session-truncate-after-message
       chat--current-session
       (chat-message-id user-msg)
       t)
      (chat-ui--rebuild-buffer (chat-message-content user-msg)))))

(defun chat-ui-previous-message ()
  "Navigate to previous message."
  (interactive)
  ;; Implementation for history navigation
  (message "History navigation not yet implemented"))

;; ------------------------------------------------------------------
;; View Raw Messages
;; ------------------------------------------------------------------

(defun chat-ui--get-message-at-point ()
  "Get the message struct at point."
  (when (boundp 'chat--current-session)
    (let* ((session chat--current-session)
           (messages (chat-session-messages session))
           found-msg)
      (save-excursion
        (goto-char (point-min))
        (while (and (not found-msg) (< (point) (point-max)))
          (when (get-text-property (point) 'chat-message-id)
            (let ((msg-id (get-text-property (point) 'chat-message-id)))
              (setq found-msg (cl-find-if (lambda (m) (equal (chat-message-id m) msg-id))
                                          messages))))
          (forward-line 1)))
      found-msg)))

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

(defun chat-ui--stream-started-p (handle)
  "Return non-nil when HANDLE means stream startup succeeded."
  (not (null handle)))

(defun chat-ui--stream-process-p (process)
  "Return non-nil when PROCESS is a valid stream process."
  (processp process))

(defun chat-ui--set-stream-process-sentinel (process sentinel)
  "Install SENTINEL on PROCESS."
  (set-process-sentinel process sentinel))

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
