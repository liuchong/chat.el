;;; test-chat-tool-caller.el --- Tests for chat-tool-caller -*- lexical-binding: t -*-

(require 'ert)
(require 'chat-tool-caller)

;; ------------------------------------------------------------------
;; Tool Call Parsing Tests
;; ------------------------------------------------------------------

(ert-deftest chat-tool-caller-parses-single-tool-call ()
  "Test parsing a single tool call from AI response."
  (let* ((response "I'll count the words for you.\n<function_calls>\n<invoke name=\"word-counter\">\n<parameter name=\"input\">hello world</parameter>\n</invoke>\n</function_calls>")
         (calls (chat-tool-caller-parse response)))
    (should (= (length calls) 1))
    (should (string= (plist-get (car calls) :name) "word-counter"))
    (should (equal (plist-get (car calls) :arguments) '(("input" . "hello world"))))))

(ert-deftest chat-tool-caller-parses-multiple-tool-calls ()
  "Test parsing multiple tool calls."
  (let* ((response "<function_calls>\n<invoke name=\"tool1\">\n<parameter name=\"input\">test1</parameter>\n</invoke>\n<invoke name=\"tool2\">\n<parameter name=\"input\">test2</parameter>\n</invoke>\n</function_calls>")
         (calls (chat-tool-caller-parse response)))
    (should (= (length calls) 2))
    (should (string= (plist-get (nth 0 calls) :name) "tool1"))
    (should (string= (plist-get (nth 1 calls) :name) "tool2"))))

(ert-deftest chat-tool-caller-returns-nil-for-no-tool-calls ()
  "Test that plain text returns nil."
  (let* ((response "This is just a plain response with no tools.")
         (calls (chat-tool-caller-parse response)))
    (should (null calls))))

(ert-deftest chat-tool-caller-extracts-content ()
  "Test extracting user-facing content."
  (let* ((response "Here is the result:\n<function_calls>\n<invoke name=\"test\">\n</invoke>\n</function_calls>")
         (content (chat-tool-caller-extract-content response)))
    (should (string= content "Here is the result:\n"))))

(ert-deftest chat-tool-caller-extracts-content-cleanly ()
  "Test that content extraction removes all tool call markup."
  (let* ((response "Before<function_calls>\n<invoke name=\"x\"></invoke>\n</function_calls>After")
         (content (chat-tool-caller-extract-content response)))
    (should (string= content "BeforeAfter"))))

;; ------------------------------------------------------------------
;; Integration Tests (require actual tools)
;; ------------------------------------------------------------------

(ert-deftest chat-tool-caller-processes-response-without-tools ()
  "Test processing a response without tool calls."
  (let ((result nil))
    (chat-tool-caller-process-response
     "Hello, how can I help?"
     (lambda (content tool-results)
       (setq result (list content tool-results))))
    (should (string= (nth 0 result) "Hello, how can I help?"))
    (should (null (nth 1 result)))))

(provide 'test-chat-tool-caller)
;;; test-chat-tool-caller.el ends here
