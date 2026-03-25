;;; test-chat-tool-forge-ai.el --- Tests for AI tool generation -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for AI-assisted tool generation.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-tool-forge-ai)

(ert-deftest chat-tool-forge-ai-extracts-tool-request-from-message ()
  "Test detecting tool creation intent in user message."
  (let ((msg "Create a tool that counts words in text"))
    (should (chat-tool-forge-ai--tool-request-p msg))))

(ert-deftest chat-tool-forge-ai-ignores-normal-messages ()
  "Test that normal chat does not trigger tool creation."
  (should-not (chat-tool-forge-ai--tool-request-p "Hello, how are you?"))
  (should-not (chat-tool-forge-ai--tool-request-p "What is the weather?")))

(ert-deftest chat-tool-forge-ai-extracts-description ()
  "Test extracting description from tool request."
  (let ((msg "Create a tool that counts words in text"))
    (should (string-match-p "counts words" (chat-tool-forge-ai--extract-description msg)))))

(ert-deftest chat-tool-forge-ai-generates-id ()
  "Test ID generation from description."
  (let ((id1 (chat-tool-forge-ai--generate-id "Count words in string"))
        (id2 (chat-tool-forge-ai--generate-id "create a thing")))
    (should (symbolp id1))
    (should (symbolp id2))
    (should (string-match-p "count" (symbol-name id1)))))

(ert-deftest chat-tool-forge-ai-prompt-includes-available-tools ()
  "Test that tool generation prompt includes existing tools."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir))
     ;; Register a sample tool
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'existing-tool
       :name "Existing Tool"
       :language 'elisp
       :source-code "(lambda () t)"))
     ;; Check prompt includes it
     (let ((prompt (chat-tool-forge-ai--build-prompt "Create new tool")))
       (should (string-match-p "existing-tool" prompt))))))

(ert-deftest chat-tool-forge-ai-parses-chat-llm-response-plist ()
  "Test parsing tool code from `chat-llm-request' result plist."
  (let* ((response '(:content "```elisp\n(lambda (input) input)\n```"))
         (spec (chat-tool-forge-ai--parse-response response "Echo input")))
    (should (eq (plist-get spec :language) 'elisp))
    (should (string= (plist-get spec :source-code) "(lambda (input) input)"))))

(provide 'test-chat-tool-forge-ai)
;;; test-chat-tool-forge-ai.el ends here
