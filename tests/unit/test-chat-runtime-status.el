;;; test-chat-runtime-status.el --- Runtime status tests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-runtime-status)
(require 'chat-ui)

(ert-deftest chat-runtime-status-projects-the-unified-coding-phases ()
  "Lifecycle and tool events project onto the six public coding phases."
  (should (eq 'planning
              (chat-runtime-status-phase-for-event 'plan-item-started)))
  (should (eq 'understanding
              (chat-runtime-status-phase-for-event 'context-bundle-built)))
  (should (eq 'editing
              (chat-runtime-status-phase-for-event
               'tool-event '(:event (:tool "file_write")))))
  (should (eq 'verifying
              (chat-runtime-status-phase-for-event
               'verification-step-started)))
  (should (eq 'repairing
              (chat-runtime-status-phase-for-event 'repair-started)))
  (should (eq 'reviewing
              (chat-runtime-status-phase-for-event 'review-finding)))
  (should (eq 'idle
              (chat-runtime-status-phase-for-event 'turn-ended))))

(ert-deftest chat-runtime-status-errors-are-closed-and-actionable ()
  "Every public failure kind includes a bounded summary and a next action."
  (dolist (case '((semantic unavailable)
                  (permission blocked)
                  (file stale)
                  (verification failed)
                  (runtime timeout)
                  (runtime cancelled)))
    (let ((diagnostic
           (chat-runtime-status-diagnostic
            (car case) (cadr case) "bounded reason")))
      (should (memq (chat-runtime-status-kind diagnostic)
                    chat-runtime-status-error-kinds))
      (should (stringp (chat-runtime-status-summary diagnostic)))
      (should-not (string-empty-p (chat-runtime-status-action diagnostic)))))
  (should
   (eq 'unavailable
       (chat-runtime-status-kind
        (chat-runtime-status-diagnostic-for-message
         "Semantic backend is unavailable"))))
  (should
   (eq 'stale
       (chat-runtime-status-kind
        (chat-runtime-status-diagnostic-for-message
         "stale-file: demo.el changed since read")))))

(ert-deftest chat-ui-runtime-status-survives-one-thousand-view-updates ()
  "Repeated phase changes preserve the input point and visible anchor."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Phase stability" 'kimi))
          (buffer (generate-new-buffer " *chat-phase-stability*")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (setq-local chat--current-session session)
           (chat-ui-setup-buffer session)
           (let ((inhibit-read-only t))
             (goto-char chat-ui--messages-end)
             (dotimes (index 80)
               (insert (format "stable-line-%03d\n" index)))
             (set-marker chat-ui--messages-end (point)))
           (goto-char (point-max))
           (insert "persistent input")
           (backward-char 5)
           (let ((input-offset (- (point) (marker-position chat-ui--input-overlay)))
                 (timer-count (length timer-list)))
             (goto-char (point-min))
             (search-forward "stable-line-030")
             (set-window-start (selected-window) (line-beginning-position) t)
             (goto-char (+ (marker-position chat-ui--input-overlay) input-offset))
             (dotimes (index 1000)
               (chat-ui--set-runtime-status
                (chat-runtime-status-create
                 :phase (if (zerop (% index 2)) 'editing 'verifying))))
             (should (= input-offset
                        (- (point) (marker-position chat-ui--input-overlay))))
             (should (equal "persistent input"
                            (buffer-substring-no-properties
                             (marker-position chat-ui--input-overlay)
                             (point-max))))
             (save-excursion
               (goto-char (window-start))
               (should (looking-at-p "stable-line-030")))
             (should (= timer-count (length timer-list)))))
       (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'test-chat-runtime-status)
;;; test-chat-runtime-status.el ends here
