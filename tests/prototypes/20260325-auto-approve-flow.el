;;; 20260325-auto-approve-flow.el --- Test auto-approval flow -*- lexical-binding: t -*-

;;; Commentary:
;; Integration test for auto-approval functionality.

;;; Code:

(add-to-list 'load-path (expand-file-name "../.." (file-name-directory load-file-name)))
(require 'chat-tool-forge)
(require 'chat-session)
(require 'chat-approval)

;; Mock tool for testing
(defun make-test-tool (id)
  "Create a test tool with ID."
  (make-chat-forged-tool
   :id id
   :name (symbol-name id)
   :description "Test tool"
   :language 'elisp
   :compiled-function (lambda () "test result")
   :parameters '((:name "input" :type "string" :required t))
   :is-active t))

;; Register test tools
(chat-tool-forge-register (make-test-tool 'files_read))
(chat-tool-forge-register (make-test-tool 'shell_execute))

(message "=== Auto-Approval Flow Tests ===")

;; Test 1: Default behavior - approval required for shell_execute
(message "\nTest 1: Default behavior (auto-approve disabled)")
(let ((chat-approval-enabled t)
      (chat-approval-auto-approve-global nil)
      (tool (chat-tool-forge-get 'shell_execute))
      (call '(:name "shell_execute" :arguments (("command" . "ls")))))
  (message "  Tool: shell_execute")
  (message "  Global auto-approve: %s" chat-approval-auto-approve-global)
  (message "  Auto-approve tools: %s" chat-approval-auto-approve-tools)
  (message "  Expected: Need approval (would prompt user)"))

;; Test 2: Global auto-approve enabled, tool in list
(message "\nTest 2: Global auto-approve with tool in list")
(let ((chat-approval-enabled t)
      (chat-approval-auto-approve-global t)
      (chat-approval-auto-approve-tools '(files_read))
      (tool (chat-tool-forge-get 'files_read))
      (call '(:name "files_read" :arguments (("path" . "/tmp/test")))))
  (message "  Tool: files_read")
  (message "  Global auto-approve: %s" chat-approval-auto-approve-global)
  (message "  Auto-approve tools: %s" chat-approval-auto-approve-tools)
  (message "  Result: %s" (if (chat-approval--auto-approve-p 'files_read nil)
                            "AUTO-APPROVED"
                          "NEEDS APPROVAL")))

;; Test 3: Global auto-approve enabled, but tool NOT in list
(message "\nTest 3: Global auto-approve with tool NOT in list")
(let ((chat-approval-enabled t)
      (chat-approval-auto-approve-global t)
      (chat-approval-auto-approve-tools '(files_read))
      (tool (chat-tool-forge-get 'shell_execute))
      (call '(:name "shell_execute" :arguments (("command" . "ls")))))
  (message "  Tool: shell_execute")
  (message "  Global auto-approve: %s" chat-approval-auto-approve-global)
  (message "  Auto-approve tools: %s" chat-approval-auto-approve-tools)
  (message "  Result: %s" (if (chat-approval--auto-approve-p 'shell_execute nil)
                            "AUTO-APPROVED"
                          "NEEDS APPROVAL")))

;; Test 4: Session-level override
(message "\nTest 4: Session-level auto-approve")
(let* ((chat-approval-enabled t)
       (chat-approval-auto-approve-global nil)
       (chat-approval-auto-approve-tools '(files_read))
       (session (chat-session-create "test-session"))
       (tool (chat-tool-forge-get 'shell_execute)))
  ;; Enable auto-approve for this session
  (chat-session-set-auto-approve session t)
  (message "  Tool: shell_execute")
  (message "  Global auto-approve: %s" chat-approval-auto-approve-global)
  (message "  Session auto-approve: %s" (chat-session-auto-approve session))
  (message "  Effective auto-approve: %s" (chat-approval--auto-approve-p 'shell_execute session))
  (message "  Result: %s" (if (chat-approval--auto-approve-p 'shell_execute session)
                            "AUTO-APPROVED (session override)"
                          "NEEDS APPROVAL")))

(message "\n=== Tests Complete ===")

(provide '20260325-auto-approve-flow)
;;; 20260325-auto-approve-flow.el ends here
