;;; test-chat-llm-kimi-integration.el --- Kimi integration tests -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-llm)

(defun test-chat-kimi--has-api-key ()
  "Check if Kimi API key is available."
  (condition-case nil
      (chat-llm--get-api-key 'kimi)
    (error nil)))

(ert-deftest chat-llm-kimi-simple-request ()
  "Test making a simple request to Kimi API."
  (skip-unless (test-chat-kimi--has-api-key))
  (let* ((messages (list (make-chat-message
                          :role :user
                          :content "Say hello in one word")))
         (response (chat-llm-request 'kimi messages '(:max-tokens 10))))
    (should (stringp response))
    (should (> (length response) 0))))

(ert-deftest chat-llm-kimi-streaming-request ()
  "Test streaming request to Kimi API."
  (skip-unless (test-chat-kimi--has-api-key))
  (let* ((messages (list (make-chat-message
                          :role :user
                          :content "Count 1 2 3")))
         (chunks '()))
    (chat-llm-stream 'kimi messages
                     (lambda (chunk)
                       (when chunk
                         (push chunk chunks))))
    (should (> (length chunks) 0))))

(provide 'test-chat-llm-kimi-integration)
;;; test-chat-llm-kimi-integration.el ends here
