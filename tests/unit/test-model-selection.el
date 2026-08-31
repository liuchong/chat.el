;;; test-model-selection.el --- Delayed model switching tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-ui)
(require 'chat-model-selection)

(defun chat-test-model-target (provider)
  "Return PROVIDER's configured concrete target for tests."
  (chat-model-selection-target provider))

(ert-deftest chat-model-selection-preparation-is-not-activation ()
  "Prompt selection survives reopening without changing active requests."
  (chat-test-with-temp-dir
   (let* ((chat-session-auto-save t)
          (session (chat-session-create "model-state" 'kimi))
          (target (chat-test-model-target 'deepseek)))
     (chat-model-selection-prepare session target)
     (should (eq 'kimi (chat-session-model-id session)))
     (should (chat-model-selection-dirty-p session))
     (let* ((reloaded (chat-session-load (chat-session-id session)))
            (prepared (chat-model-selection-prepared reloaded)))
       (should (eq 'deepseek (chat-model-target-provider prepared)))
       (should (chat-model-selection-dirty-p reloaded))))))

(ert-deftest chat-model-selection-pending-operation-is-consumed-once ()
  "A matching request boundary consumes one pending switch exactly once."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "model-state" 'kimi))
          (target (chat-test-model-target 'deepseek))
          (pending (chat-model-selection-request session target 'command)))
     (should (alist-get 'id pending))
     (should (chat-model-selection-pending session))
     (should (equal pending (chat-model-selection-activate session target)))
     (should-not (chat-model-selection-pending session))
     (should-not (chat-model-selection-dirty-p session))
     (should-not (chat-model-selection-activate session target)))))

(ert-deftest chat-model-selection-late-event-cannot-consume-newer-request ()
  "A late event cannot consume a newer request for the same target."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "model-state" 'kimi))
          (target (chat-test-model-target 'deepseek))
          (older (chat-model-selection-request session target 'command))
          (newer (chat-model-selection-request session target 'command)))
     (should-not
      (chat-model-selection-activate session target (alist-get 'id older)))
     (should (equal newer (chat-model-selection-pending session)))
     (should (equal newer
                    (chat-model-selection-activate
                     session target (alist-get 'id newer))))
     (should-not (chat-model-selection-pending session)))))

(ert-deftest chat-model-selection-pending-switch-survives-session-reopen ()
  "Prepared and pending switch identity survive a persisted session reopen."
  (chat-test-with-temp-dir
   (let* ((chat-session-auto-save t)
          (session (chat-session-create "pending-model-state" 'kimi))
          (target (chat-test-model-target 'deepseek))
          (pending (chat-model-selection-request session target 'command))
          (reloaded (chat-session-load (chat-session-id session)))
          (reloaded-pending (chat-model-selection-pending reloaded)))
     (should (equal (alist-get 'id pending)
                    (alist-get 'id reloaded-pending)))
     (should (chat-model-selection-target-equal-p
              target (chat-model-selection-prepared reloaded)))
     (should (chat-model-selection-target-equal-p
              target (chat-model-selection-pending-target reloaded))))))

(ert-deftest chat-ui-ambiguous-model-name-does-not-change-selection ()
  "A bare model shared by providers is refused without changing state."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "ambiguous-model" 'kimi))
          (before (copy-tree (chat-session-metadata session)))
          (shared-a (make-chat-model-target :provider 'kimi :model "shared"))
          (shared-b (make-chat-model-target
                     :provider 'deepseek :model "shared")))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (cl-letf (((symbol-function 'chat-ui--model-target-candidates)
                  (lambda ()
                    (list (cons "kimi/shared" shared-a)
                          (cons "deepseek/shared" shared-b)))))
         (should-error (chat-ui--resolve-model-target "shared")
                       :type 'user-error)))
     (should (equal before (chat-session-metadata session)))
     (should-not (chat-model-selection-pending session)))))

(ert-deftest chat-agent-model-switch-applies-at-next-turn-boundary ()
  "Scheduling does not mutate a run until the boundary function executes."
  (let* ((old (chat-test-model-target 'kimi))
         (new (chat-test-model-target 'deepseek))
         events
         (run (chat-agent--run-create
               :provider (chat-model-target-provider old)
               :model (chat-model-target-model old)
               :request-options (list :model (chat-model-target-model old))
               :on-event (lambda (event) (push event events)))))
    (chat-agent-schedule-model-switch
     run (chat-model-target-provider new) (chat-model-target-model new)
     "switch-1" 'command '(:max-tokens 4242))
    (should (eq (chat-model-target-provider old)
                (chat-agent-run-state-provider run)))
    (chat-agent--apply-pending-model-switch run)
    (should (eq (chat-model-target-provider new)
                (chat-agent-run-state-provider run)))
    (should (equal (chat-model-target-model new)
                   (plist-get (chat-agent-run-state-request-options run)
                              :model)))
    (should (= 4242
               (plist-get (chat-agent-run-state-request-options run)
                          :max-tokens)))
    (should (eq 'model-switched (plist-get (car events) :type)))
    (should-not (chat-agent--apply-pending-model-switch run))))

(ert-deftest chat-ui-prompt-selection-cancels-the-superseded-run-switch ()
  "A newer prompt choice clears the matching session and Agent operation."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "model-state" 'kimi))
          (old-target (chat-test-model-target 'deepseek))
          (new-target (chat-test-model-target 'kimi-code))
          (pending (chat-model-selection-request session old-target 'command))
          (run (chat-agent--run-create
                :provider 'kimi
                :model (chat-model-target-model
                        (chat-model-selection-active session)))))
     (chat-agent-schedule-model-switch
      run (chat-model-target-provider old-target)
      (chat-model-target-model old-target) (alist-get 'id pending) 'command
      (list :model (chat-model-target-model old-target)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (setq-local chat-ui--active-agent-run run)
       (chat-ui-setup-buffer session)
       (chat-test-silently
        (chat-set-model (chat-model-target-provider new-target)
                        (chat-model-target-model new-target))))
     (should-not (chat-model-selection-pending session))
     (should-not (chat-agent-run-state-pending-model-switch run))
     (should (chat-model-selection-target-equal-p
              new-target (chat-model-selection-prepared session))))))

(ert-deftest chat-ui-queued-run-keeps-its-target-then-schedules-later-command ()
  "A command newer than a queued message waits for that run's continuation."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "model-state" 'kimi))
          (queued-target (chat-model-selection-active session))
          (command-target (chat-test-model-target 'deepseek))
          (pending (chat-model-selection-request
                    session command-target 'command))
          (run (chat-agent--run-create
                :provider (chat-model-target-provider queued-target)
                :model (chat-model-target-model queued-target)
                :request-options
                (list :model (chat-model-target-model queued-target)))))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui--schedule-session-model-switch run))
     (should (chat-model-selection-target-equal-p
              queued-target
              (make-chat-model-target
               :provider (chat-agent-run-state-provider run)
               :model (chat-agent-run-state-model run))))
     (should (equal (alist-get 'id pending)
                    (plist-get
                     (chat-agent-run-state-pending-model-switch run)
                     :operation-id)))
     (chat-agent--apply-pending-model-switch run)
     (should (chat-model-selection-target-equal-p
              command-target
              (make-chat-model-target
               :provider (chat-agent-run-state-provider run)
               :model (chat-agent-run-state-model run)))))))

(ert-deftest chat-ui-model-prompt-marks-prepared-target-dirty ()
  "Prompt selection shows its not-yet-active state without relabeling session."
  (chat-test-with-temp-dir
   (let ((session (chat-session-create "dirty-model" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-set-model 'deepseek)
       (should (eq 'kimi (chat-session-model-id session)))
       (should (string-match-p
                "(\\*)" (substring-no-properties
                           (chat-ui--prompt-model-segment))))))))

(ert-deftest chat-ui-send-modes-capture-the-prepared-target-at-submission ()
  "Idle, insert and interrupt dispatch all capture one prepared target."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "model-state" 'kimi))
          (target (chat-test-model-target 'deepseek))
          (run (chat-agent--run-create
                :provider 'kimi
                :model (chat-model-target-model
                        (chat-model-selection-active session))))
          captured)
     (chat-model-selection-prepare session target)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (cl-letf (((symbol-function 'chat-ui--send-user-message)
                  (lambda (&rest _)
                    (push (cons 'idle chat-ui--submitted-model-target)
                          captured)))
                 ((symbol-function 'chat-ui--steer-active-agent)
                  (lambda (&rest _)
                    (push (cons 'insert chat-ui--submitted-model-target)
                          captured)))
                 ((symbol-function 'chat-ui--interrupt-with)
                  (lambda (&rest _)
                    (push (cons 'interrupt chat-ui--submitted-model-target)
                          captured))))
         (setq-local chat-ui--active-agent-run nil)
         (chat-ui--send-in-mode "idle" 'queue)
         (setq-local chat-ui--active-agent-run run)
         (chat-ui--send-in-mode "insert" 'insert)
         (chat-ui--send-in-mode "interrupt" 'interrupt)))
     (should (= 3 (length captured)))
     (dolist (entry captured)
       (should (chat-model-selection-target-equal-p target (cdr entry)))))))

(ert-deftest chat-ui-model-command-becomes-one-display-only-record ()
  "Applying a command replaces transient state with durable UI-only history."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "model-state" 'kimi))
          (target (chat-test-model-target 'deepseek)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (let* ((pending (chat-ui--request-model-switch target 'command))
              (operation-id (alist-get 'id pending)))
         (chat-ui--render-live-region)
         (goto-char (point-min))
         (should (text-property-search-forward
                  'chat-ui-transient-model-switch operation-id t))
         (chat-ui--activate-model-target target operation-id)
         (chat-ui--redraw-conversation)
         (goto-char (point-min))
         (should-not (text-property-search-forward
                      'chat-ui-transient-model-switch operation-id t))
         (let ((records
                (seq-filter
                 (lambda (message)
                   (eq 'command-reply (chat-transcript-category message)))
                 (chat-session-messages session))))
           (should (= 1 (length records)))
           (should (equal operation-id
                          (plist-get (chat-message-metadata (car records))
                                     :model-switch-id)))))))))

(ert-deftest chat-ui-model-command-pends-without-interrupting-active-run ()
  "The command schedules the next continuation and leaves this request alone."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "pending-model" 'kimi))
          (old (chat-test-model-target 'kimi))
          (run (chat-agent--run-create
                :provider (chat-model-target-provider old)
                :model (chat-model-target-model old))))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (setq-local chat-ui--active-agent-run run)
       (chat-ui-setup-buffer session)
       (chat-ui--command-model "deepseek")
       (should (eq 'kimi (chat-agent-run-state-provider run)))
       (should (chat-agent-run-state-pending-model-switch run))
       (should (chat-model-selection-pending session))
       (should (string-match-p
                "Pending model switch: deepseek/"
                (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest chat-ui-queued-send-captures-model-at-submission ()
  "A later prompt choice cannot retarget a message already queued."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "queued-model" 'kimi))
          (run (chat-agent--run-create :provider 'kimi :model "old")))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (setq-local chat-ui--active-agent-run run)
       (setq-local chat-ui--queued-sends nil)
       (chat-model-selection-prepare session (chat-test-model-target 'deepseek))
       (chat-ui--send-in-mode "first" 'queue)
       (chat-model-selection-prepare session (chat-test-model-target 'kimi))
       (let ((captured (chat-ui--draft-model-target
                        (car chat-ui--queued-sends))))
         (should (eq 'deepseek (chat-model-target-provider captured))))))))

(ert-deftest chat-ui-model-argument-hints-and-completion-share-targets ()
  "Hints are passive while TAB completion exposes the same target names."
  (chat-test-with-temp-dir
   (let ((session (chat-session-create "model-hint" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-max))
       (insert "/model deep")
       (cl-letf (((symbol-function 'chat-ui--model-target-candidates)
                  (lambda ()
                    (list (cons "deepseek/deepseek-v4-flash"
                                (chat-test-model-target 'deepseek))))))
         (let* ((hint (chat-ui--model-argument-hint-model))
                (capf (chat-ui--model-argument-completion-at-point))
                (names (mapcar #'chat-input-hint-candidate-completion
                               (chat-input-hint-visible-candidates hint))))
           (should hint)
           (should capf)
           (should (equal '("deepseek/deepseek-v4-flash") names))))))))

(provide 'test-model-selection)
;;; test-model-selection.el ends here
