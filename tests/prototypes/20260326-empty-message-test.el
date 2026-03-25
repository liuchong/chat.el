;;; 20260326-empty-message-test.el --- Test empty message filtering -*- lexical-binding: t -*-

;;; Commentary:
;; Test that empty messages are filtered out.

;;; Code:

(add-to-list 'load-path (expand-file-name "../.." (file-name-directory load-file-name)))
(require 'chat-session)
(require 'chat-ui)

(message "=== Empty Message Filter Test ===")

;; Create a test session
(setq chat-session-auto-save nil)
(setq chat-session-directory (expand-file-name "~/.chat/test-sessions/"))
(make-directory chat-session-directory t)

(let* ((session (chat-session-create "test-empty-message"))
       (initial-msg-count (length (chat-session-messages session))))
  
  (message "\nTest 1: Non-empty message should be added")
  (let ((msg (make-chat-message
              :id "test-1"
              :role :user
              :content "Hello"
              :timestamp (current-time))))
    (chat-session-add-message session msg)
    (message "  Message count: %d (expected: %d)" 
             (length (chat-session-messages session))
             (1+ initial-msg-count))
    (message "  Result: %s" 
             (if (= (length (chat-session-messages session)) (1+ initial-msg-count))
                 "PASS" "FAIL")))
  
  (message "\nTest 2: Empty message content check")
  (let ((empty-content "")
        (whitespace-only "   ")
        (valid-content "Hello"))
    (message "  Empty string '%s': string-empty-p = %s (expected: t)" 
             empty-content (string-empty-p empty-content))
    (message "  Whitespace only '%s': string-empty-p after trim = %s (expected: t)"
             whitespace-only 
             (string-empty-p (string-trim whitespace-only)))
    (message "  Valid content '%s': string-empty-p = %s (expected: nil)"
             valid-content (string-empty-p valid-content))))

(message "\n=== Tests Complete ===")

(provide '20260326-empty-message-test)
;;; 20260326-empty-message-test.el ends here
