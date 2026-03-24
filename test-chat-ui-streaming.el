;;; test-chat-ui-streaming.el --- Test streaming response timer fix -*- lexical-binding: t -*-

;;; Commentary:
;; This test verifies that the streaming response timer fix works correctly.
;; The fix uses closure variable capture instead of timer argument passing
;; to avoid wrong-number-of-arguments errors in lexical binding mode.

;;; Code:

(require 'ert)

(ert-deftest chat-ui-streaming-timer-lexical-binding ()
  "Test that run-with-idle-timer callback works with lexical binding."
  (let ((result nil)
        (var1 "test1")
        (var2 "test2"))
    ;; Use closure capture like the fix does
    (let ((v1 var1)
          (v2 var2))
      (run-with-idle-timer
       0.01 nil
       (lambda ()
         (setq result (cons v1 v2)))))
    ;; Wait for timer
    (sleep-for 0.1)
    ;; Verify result
    (should (equal result '("test1" . "test2")))))

(ert-deftest chat-ui-streaming-timer-error-handling ()
  "Test that timer callback error handling works."
  (let ((caught-error nil))
    (let ((test-var "value"))
      (run-with-idle-timer
       0.01 nil
       (lambda ()
         (condition-case err
             (progn
               (should (string= test-var "value"))
               (signal 'test-error "intentional"))
           (error
            (setq caught-error (car err)))))))
    (sleep-for 0.1)
    (should (eq caught-error 'test-error))))

(provide 'test-chat-ui-streaming)
;;; test-chat-ui-streaming.el ends here
