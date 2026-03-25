;;; 20260326-tool-loop-dedup.el --- Test tool loop message deduplication -*- lexical-binding: t -*-

;;; Commentary:
;; Test that tool loop doesn't add duplicate messages.

;;; Code:

(add-to-list 'load-path (expand-file-name "../.." (file-name-directory load-file-name)))
(require 'chat-session)
(require 'chat-ui)

(message "=== Tool Loop Message Deduplication Test ===")

;; Test 1: Message exists check
(message "\nTest 1: chat-ui--message-exists-p")
(let* ((msg1 (make-chat-message :id "test-1" :role :user :content "Hello" :timestamp (current-time)))
       (msg2 (make-chat-message :id "test-2" :role :assistant :content "Hi" :timestamp (current-time)))
       (messages (list msg1 msg2)))
  (message "  msg1 exists in list: %s (expected: t)" 
           (chat-ui--message-exists-p msg1 messages))
  (message "  msg2 exists in list: %s (expected: t)"
           (chat-ui--message-exists-p msg2 messages))
  (let ((msg3 (make-chat-message :id "test-3" :role :system :content "System" :timestamp (current-time))))
    (message "  msg3 exists in list: %s (expected: nil)"
             (chat-ui--message-exists-p msg3 messages))))

;; Test 2: Simulated tool loop message accumulation
(message "\nTest 2: Simulated tool loop with duplicate prevention")
(let* ((user-msg (make-chat-message :id "user-1" :role :user :content "Test" :timestamp (current-time)))
       (messages (list user-msg))
       (step 0))
  ;; Simulate first tool round
  (let* ((followup-1 (make-chat-message 
                      :id (format "tool-step-%s-%s" (random 10000) step)
                      :role :system
                      :content "Tool results: pwd => /home"
                      :timestamp (current-time)))
         (next-messages-1 (if (chat-ui--message-exists-p followup-1 messages)
                              messages
                            (append messages (list followup-1)))))
    (message "  After round 1: %d messages (expected: 2)" (length next-messages-1))
    
    ;; Simulate second tool round with same message (should be prevented)
    (setq step 1)
    (let* ((followup-2 (make-chat-message 
                        :id (format "tool-step-%s-%s" (random 10000) step)
                        :role :system
                        :content "Tool results: ls => file1 file2"
                        :timestamp (current-time)))
           (next-messages-2 (if (chat-ui--message-exists-p followup-2 next-messages-1)
                                next-messages-1
                              (append next-messages-1 (list followup-2)))))
      (message "  After round 2: %d messages (expected: 3)" (length next-messages-2))
      
      ;; Try to add followup-1 again (should be prevented)
      (let ((next-messages-3 (if (chat-ui--message-exists-p followup-1 next-messages-2)
                                 next-messages-2
                               (append next-messages-2 (list followup-1)))))
        (message "  After trying to re-add msg1: %d messages (expected: 3, dedup prevented)" 
                 (length next-messages-3))
        (if (= (length next-messages-3) 3)
            (message "  Result: PASS - Deduplication working")
          (message "  Result: FAIL - Duplicate was added"))))))

(message "\n=== Tests Complete ===")

(provide '20260326-tool-loop-dedup)
;;; 20260326-tool-loop-dedup.el ends here
