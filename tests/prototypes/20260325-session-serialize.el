;;; 20260325-session-serialize.el --- Test session serialization with auto-approve -*- lexical-binding: t -*-

;;; Commentary:
;; Test session auto-approve serialization/deserialization.

;;; Code:

(add-to-list 'load-path (expand-file-name "../.." (file-name-directory load-file-name)))
(require 'chat-session)

(message "=== Session Serialization Tests ===")

;; Test 1: Create session with auto-approve = t
(message "\nTest 1: Create session with auto-approve = t")
(let* ((session (chat-session-create "test-auto-approve"))
       (serialized (progn 
                     (chat-session-set-auto-approve session t)
                     (chat-session--serialize session)))
       (auto-approve-val (cdr (assoc 'autoApprove serialized))))
  (message "  Session name: %s" (chat-session-name session))
  (message "  auto-approve field: %s" (chat-session-auto-approve session))
  (message "  Serialized autoApprove: %s" auto-approve-val)
  (message "  Result: %s" (if (eq auto-approve-val t) "PASS" "FAIL")))

;; Test 2: Create session with auto-approve = nil
(message "\nTest 2: Create session with auto-approve = nil")
(let* ((session (chat-session-create "test-no-auto-approve"))
       (serialized (progn
                     (chat-session-set-auto-approve session nil)
                     (chat-session--serialize session)))
       (auto-approve-val (cdr (assoc 'autoApprove serialized))))
  (message "  Session name: %s" (chat-session-name session))
  (message "  auto-approve field: %s" (chat-session-auto-approve session))
  (message "  Serialized autoApprove: %s" auto-approve-val)
  (message "  Result: %s" (if (eq auto-approve-val :json-false) "PASS" "FAIL")))

;; Test 3: Deserialize and check
(message "\nTest 3: Deserialize and verify")
(let* ((original (chat-session-create "test-roundtrip"))
       (serialized (progn
                     (chat-session-set-auto-approve original t)
                     (chat-session--serialize original)))
       (restored (chat-session--deserialize serialized)))
  (message "  Original auto-approve: %s" (chat-session-auto-approve original))
  (message "  Restored auto-approve: %s" (chat-session-auto-approve restored))
  (message "  Result: %s" (if (eq (chat-session-auto-approve original)
                               (chat-session-auto-approve restored))
                          "PASS" "FAIL")))

(message "\n=== Tests Complete ===")

(provide '20260325-session-serialize)
;;; 20260325-session-serialize.el ends here
