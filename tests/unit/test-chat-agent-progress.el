;;; test-chat-agent-progress.el --- Agent progress tests -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'chat-agent-progress)
(require 'chat-agent-loop)

(ert-deftest chat-agent-progress-warns-then-stops-after-error ()
  (let ((chat-agent-progress-warning-threshold 3)
        (chat-agent-progress-stop-threshold 5)
        (state (chat-agent-progress-state-create)))
    (should-not (chat-agent-progress-observe state 'error))
    (should-not (chat-agent-progress-observe state 'inspection "read:a"))
    (should-not (chat-agent-progress-observe state 'inspection "read:b"))
    (let ((event (chat-agent-progress-observe state 'inspection "read:c")))
      (should (eq (plist-get event :event) 'stagnation-detected))
      (should (= (plist-get event :inspection-count) 3))
      (should (string-match-p
               "3 inspection calls followed a tool error"
               (chat-agent-progress-state-reminder state))))
    (should-not (chat-agent-progress-observe state 'inspection "read:d"))
    (let ((event (chat-agent-progress-observe state 'inspection "read:e")))
      (should (eq (plist-get event :event) 'stagnation-stopped))
      (should (string-match-p
               "5 inspection calls"
               (chat-agent-progress-state-stop-reason state))))))

(ert-deftest chat-agent-progress-success-recovers-and-resets ()
  (let ((chat-agent-progress-warning-threshold 2)
        (state (chat-agent-progress-state-create)))
    (chat-agent-progress-observe state 'error)
    (chat-agent-progress-observe state 'inspection "read:a")
    (chat-agent-progress-observe state 'inspection "read:b")
    (let ((event (chat-agent-progress-observe state 'progress)))
      (should (eq (plist-get event :event) 'stagnation-recovered)))
    (should-not (chat-agent-progress-state-after-error-p state))
    (should-not (chat-agent-progress-state-reminder state))
    (should-not (chat-agent-progress-state-stop-reason state))
    (should (= (chat-agent-progress-state-inspection-after-error state) 0))))

(ert-deftest chat-agent-progress-repeated-inspection-without-error-only-warns ()
  (let ((chat-agent-progress-warning-threshold 3)
        (chat-agent-progress-stop-threshold 5)
        (state (chat-agent-progress-state-create))
        event)
    (dotimes (_ 8)
      (setq event (or (chat-agent-progress-observe
                       state 'inspection "read:same")
                      event)))
    (should (eq (plist-get event :event) 'stagnation-detected))
    (should (chat-agent-progress-state-reminder state))
    (should-not (chat-agent-progress-state-stop-reason state))))

(ert-deftest chat-agent-progress-distinct-inspections-remain-valid-research ()
  (let ((chat-agent-progress-warning-threshold 3)
        (state (chat-agent-progress-state-create)))
    (dotimes (index 8)
      (should-not
       (chat-agent-progress-observe
        state 'inspection (format "read:%d" index))))
    (should-not (chat-agent-progress-state-reminder state))))

(ert-deftest chat-agent-loop-classifies-control-write-as-neutral ()
  (cl-letf (((symbol-function 'chat-tool-caller-call-resource-accesses)
             (lambda (_call)
               '((:resource "global-write" :mode write :exclusive t)))))
    (should (eq (chat-agent--progress-tool-kind
                 '(:name "programming_plan_create") nil)
                'neutral))
    (should (eq (chat-agent--progress-tool-kind
                 '(:name "files_patch") nil)
                'progress))
    (should (eq (chat-agent--progress-tool-kind
                 '(:name "files_read") t)
                'error))))

(ert-deftest chat-agent-loop-emits-stagnation-and-recovery-events ()
  (let* ((chat-agent-progress-warning-threshold 2)
         events
         (run (chat-agent--run-create
               :progress-state (chat-agent-progress-state-create)
               :on-event (lambda (event)
                           (push (plist-get event :type) events)))))
    (cl-letf (((symbol-function 'chat-tool-caller-call-resource-accesses)
               (lambda (call)
                 (if (equal (plist-get call :name) "files_patch")
                     '((:resource "file:a" :mode write))
                   '((:resource "file:a" :mode read))))))
      (chat-agent--observe-progress
       run
       '((:name "files_patch") (:name "files_read") (:name "files_read"))
       '("Error: no match" "one" "two")
       '(t nil nil))
      (should (memq 'stagnation-detected events))
      (should (chat-agent-progress-state-reminder
               (chat-agent-run-state-progress-state run)))
      (chat-agent--observe-progress
       run '((:name "files_patch")) '("updated") '(nil))
      (should (memq 'stagnation-recovered events))
      (should-not (chat-agent-progress-state-reminder
                   (chat-agent-run-state-progress-state run))))))

(provide 'test-chat-agent-progress)
;;; test-chat-agent-progress.el ends here
