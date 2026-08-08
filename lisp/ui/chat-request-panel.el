;;; chat-request-panel.el --- Request panel UI -*- lexical-binding: t -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-request-diagnostics)

(defgroup chat-request-panel nil
  "Structured request panel for chat.el."
  :group 'chat)

(defcustom chat-request-panel-auto-show t
  "Whether to automatically show the request panel for active requests."
  :type 'boolean
  :group 'chat-request-panel)

(defcustom chat-request-panel-window-width 44
  "Preferred side window width for the request panel."
  :type 'integer
  :group 'chat-request-panel)

(defcustom chat-request-panel-max-events 30
  "Maximum request events shown in the panel; older ones collapse."
  :type 'integer
  :group 'chat-request-panel)

(defvar-local chat-request-panel--source-buffer nil
  "Source buffer associated with the current request panel buffer.")

(defun chat-request-panel--buffer-name (source-buffer)
  "Return request panel buffer name for SOURCE-BUFFER."
  (format "*chat-panel:%s*" (buffer-name source-buffer)))

(defun chat-request-panel--buffer (source-buffer)
  "Return the request panel buffer for SOURCE-BUFFER."
  (get-buffer-create (chat-request-panel--buffer-name source-buffer)))

(defun chat-request-panel--event-lines (event)
  "Return display lines for EVENT."
  (pcase (plist-get event :type)
    ('thinking
     (list (format "- Thinking: %s" (or (plist-get event :summary) ""))))
    ('tool-call
     (list (format "- Tool Call %s: %s"
                   (or (plist-get event :index) "?")
                   (or (plist-get event :tool) ""))))
    ('approval-pending
     (append
      (list (format "- Approval Pending %s: %s"
                    (or (plist-get event :index) "?")
                    (or (plist-get event :tool) "")))
      (when-let ((command (plist-get event :command)))
        (list (format "  Command: %s" command)))
      (when-let ((directory (plist-get event :directory)))
        (list (format "  Directory: %s" directory)))
      (when-let ((options (plist-get event :options)))
        (list (format "  Choices: %s"
                      (mapconcat #'car options ", "))))
      (when-let ((actions (plist-get event :actions)))
        (list (format "  Actions: %s"
                      (mapconcat #'identity actions ", "))))))
    ('approval
     (append
      (list (format "- Approval %s: %s"
                    (or (plist-get event :index) "?")
                    (or (plist-get event :decision) "")))
      (when-let ((directory (plist-get event :directory)))
        (list (format "  Directory: %s" directory)))
      (when-let ((command (plist-get event :command)))
        (list (format "  Command: %s" command)))))
    ('whitelist-update
     (list (format "- Whitelist %s: %s %s"
                   (or (plist-get event :index) "?")
                   (or (plist-get event :scope) "")
                   (or (plist-get event :pattern) ""))))
    ('tool-result
     (list (format "- Tool Result %s: %s"
                   (or (plist-get event :index) "?")
                   (or (plist-get event :result-summary) ""))))
    ('tool-error
     (list (format "- Tool Error %s: %s"
                   (or (plist-get event :index) "?")
                   (or (plist-get event :result-summary) ""))))
    (_
     (list (format "- %s" event)))))

(defun chat-request-panel--insert-lines (title lines)
  "Insert TITLE and LINES into the current buffer."
  (insert (propertize title 'face 'bold) "\n")
  (if lines
      (dolist (line lines)
        (insert line "\n"))
    (insert "None\n"))
  (insert "\n"))

(defun chat-request-panel--seconds-since (time)
  "Return elapsed seconds since TIME."
  (when time
    (float-time (time-subtract (current-time) time))))

(defun chat-request-panel--format-seconds (seconds)
  "Return a short readable string for SECONDS."
  (if seconds
      (format "%.1fs" seconds)
    "n/a"))

(defun chat-request-panel--live-state (snapshot)
  "Return a user-facing live state label for SNAPSHOT."
  (let* ((phase (plist-get snapshot :phase))
         (process-live-p (plist-get snapshot :process-live-p))
         (stall (and snapshot
                     (chat-request-diagnostics-stall-message
                      (plist-get snapshot :id)))))
    (cond
     ((and stall (not (string-empty-p stall))) "stalled")
     ((and (eq phase 'streaming) process-live-p) "streaming")
     ((and (eq phase 'waiting) process-live-p) "waiting")
     ((eq phase 'tool-loop) "tool-loop")
     ((eq phase 'completed) "completed")
     ((eq phase 'failed) "failed")
     ((eq phase 'cancelled) "cancelled")
     (process-live-p "active")
     (t "idle"))))

(defun chat-request-panel--render (source-buffer request-id tool-events)
  "Render panel for SOURCE-BUFFER, REQUEST-ID, and TOOL-EVENTS."
  (let* ((snapshot (and request-id
                        (chat-request-diagnostics-snapshot request-id)))
         (stall-message (and request-id
                             (chat-request-diagnostics-stall-message request-id)))
         (elapsed (chat-request-panel--seconds-since
                   (plist-get snapshot :started-at)))
         (buffer (chat-request-panel--buffer source-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq-local chat-request-panel--source-buffer source-buffer)
        (insert (propertize "Request Panel" 'face 'mode-line-emphasis) "\n")
        (insert (format "Source: %s\n" (buffer-name source-buffer)))
        (if snapshot
            (progn
              (insert (format "Request: %s\n" (plist-get snapshot :id)))
              (insert (format "Mode: %s\n" (plist-get snapshot :mode)))
              (insert (format "Provider: %s\n" (plist-get snapshot :provider)))
              (insert (format "Model: %s\n" (plist-get snapshot :model)))
              (insert (format "Phase: %s\n" (plist-get snapshot :phase)))
              (insert (format "Transport: %s\n"
                              (or (plist-get snapshot :transport) "n/a")))
              (insert (format "Timeout: %s\n"
                              (or (plist-get snapshot :timeout) "n/a")))
              (insert (format "Live: %s\n"
                              (chat-request-panel--live-state snapshot)))
              (insert (format "Elapsed: %ss\n"
                              (if elapsed
                                  (truncate elapsed)
                                "n/a")))
              (insert (format "Handle: %s\n"
                              (if (plist-get snapshot :handle-live-p) "live" "dead")))
              (insert (format "Process: %s\n"
                              (if (plist-get snapshot :process-live-p) "live" "dead")))
              (insert (format "Chunks: %s\n"
                              (plist-get snapshot :stream-chunk-count)))
              (insert (format "Last chunk: %s\n"
                              (if-let ((last-chunk-at (plist-get snapshot :last-chunk-at)))
                                  (format-time-string "%H:%M:%S" last-chunk-at)
                                "n/a")))
              (insert (format "Chunk age: %s\n"
                              (chat-request-panel--format-seconds
                               (chat-request-panel--seconds-since
                                (plist-get snapshot :last-chunk-at)))))
              (when-let ((last-event (plist-get snapshot :last-event)))
                (insert (format "Last event: %s\n"
                                (or (plist-get last-event :summary)
                                    (plist-get last-event :type)
                                    "n/a"))))
              (when-let ((last-error (plist-get snapshot :last-error)))
                (insert (format "Error: %s\n" last-error))))
          (insert "No active request\n"))
        (insert "\n")
        (when stall-message
          (insert (propertize "Stall" 'face 'warning) "\n")
          (insert stall-message "\n\n"))
        (chat-request-panel--insert-lines
         "Tool Steps"
         (apply #'append
                (mapcar #'chat-request-panel--event-lines tool-events)))
        (let* ((all-events (plist-get snapshot :events))
               (total (length all-events))
               (hidden (max 0 (- total chat-request-panel-max-events)))
               (shown (if (> hidden 0)
                          (nthcdr hidden all-events)
                        all-events)))
          (chat-request-panel--insert-lines
           "Request Events"
           (append
            (when (> hidden 0)
              (list (format "… %d earlier events hidden" hidden)))
            (mapcar
             (lambda (event)
               (format "- %s %s"
                       (plist-get event :type)
                       (or (plist-get event :summary) "")))
             shown))))
        (goto-char (point-min))
        (view-mode 1)))))

(defun chat-request-panel-update (source-buffer request-id tool-events)
  "Update request panel for SOURCE-BUFFER using REQUEST-ID and TOOL-EVENTS."
  (when (buffer-live-p source-buffer)
    (chat-request-panel--render source-buffer request-id tool-events)))

(defun chat-request-panel-open (source-buffer request-id tool-events)
  "Open request panel for SOURCE-BUFFER with REQUEST-ID and TOOL-EVENTS."
  (let ((buffer (chat-request-panel--buffer source-buffer)))
    (chat-request-panel-update source-buffer request-id tool-events)
    (display-buffer-in-side-window
     buffer
     `((side . right)
       (slot . 0)
       (window-width . ,chat-request-panel-window-width)))))

(defun chat-request-panel-close (source-buffer)
  "Close request panel for SOURCE-BUFFER."
  (let ((buffer (get-buffer (chat-request-panel--buffer-name source-buffer))))
    (when buffer
      (when-let ((window (get-buffer-window buffer t)))
        (delete-window window))
      (kill-buffer buffer))))

(defun chat-request-panel-toggle (source-buffer request-id tool-events)
  "Toggle request panel for SOURCE-BUFFER using REQUEST-ID and TOOL-EVENTS."
  (let ((buffer (get-buffer (chat-request-panel--buffer-name source-buffer))))
    (if (and buffer (get-buffer-window buffer t))
        (chat-request-panel-close source-buffer)
      (chat-request-panel-open source-buffer request-id tool-events))))

(provide 'chat-request-panel)
