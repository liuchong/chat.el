;;; test-code-mode.el --- Test code mode implementation -*- lexical-binding: t -*-

;; This file tests the code mode implementation

;;; Code:

(require 'cl-lib)

;; Set load path
(load (expand-file-name "../test-paths.el" (file-name-directory load-file-name)) nil t)

;; Define required variables
(defvar chat-default-model 'kimi-code
  "Default LLM model.")

;; Load the modules
(require 'chat-session)
(require 'chat-context-code)
(require 'chat-edit)
(require 'chat-code-preview)
(require 'chat-code)

;; Test 1: Create a code session
(message "Test 1: Creating code session...")
(let ((session (chat-code-session-create "test-session"
                                         "/tmp"
                                         "/tmp/test.py")))
  (if session
      (progn
        (message "  ✓ Session created: %s" 
                 (chat-session-name (chat-code-session-base-session session)))
        (message "  ✓ Project root: %s" (chat-code-session-project-root session))
        (message "  ✓ Focus file: %s" (chat-code-session-focus-file session)))
    (message "  ✗ Failed to create session")))

;; Test 2: Context building
(message "\nTest 2: Testing context building...")
(let ((context (make-chat-code-context
                :strategy 'minimal
                :budget 2000
                :sources nil
                :files nil
                :symbols nil
                :total-tokens 0)))
  ;; Test token estimation
  (let ((tokens (chat-context-code--estimate-tokens "Hello world")))
    (message "  ✓ Token estimate for 'Hello world': %d" tokens))
  ;; Test budget calculation
  (let ((budget (chat-context-code--calculate-budget 'balanced)))
    (message "  ✓ Budget for balanced strategy: %d" budget)))

;; Test 3: Edit creation
(message "\nTest 3: Testing edit operations...")
(let ((edit (chat-edit-create-generate "/tmp/new-file.py"
                                       "def hello():\n    pass\n"
                                       "Create hello function")))
  (if edit
      (progn
        (message "  ✓ Edit created: %s" (chat-edit-id edit))
        (message "  ✓ Type: %s" (chat-edit-type edit))
        (message "  ✓ File: %s" (chat-edit-file edit)))
    (message "  ✗ Failed to create edit")))

;; Test 4: Preview buffer
(message "\nTest 4: Testing preview buffer...")
(let ((buffer (chat-code-preview-get-buffer)))
  (if buffer
      (progn
        (message "  ✓ Preview buffer created: %s" (buffer-name buffer))
        (message "  ✓ Buffer mode: %s" major-mode))
    (message "  ✗ Failed to create preview buffer")))

;; Test 5: Language detection
(message "\nTest 5: Testing language detection...")
(let ((tests '(("/tmp/test.py" . python)
               ("/tmp/test.js" . javascript)
               ("/tmp/test.el" . emacs-lisp)
               ("/tmp/test.go" . go)
               ("/tmp/test.rs" . rust))))
  (dolist (test tests)
    (let ((result (chat-context-code--detect-language (car test))))
      (if (eq result (cdr test))
          (message "  ✓ %s -> %s" (car test) result)
        (message "  ✗ %s -> %s (expected %s)" 
                 (car test) result (cdr test))))))

;; Summary
(message "\n====================================")
(message "Code Mode Implementation Tests")
(message "====================================")
(message "All modules loaded successfully!")
(message "Run 'M-x chat-code-start' to try code mode.")

(provide 'test-code-mode)
;;; test-code-mode.el ends here
