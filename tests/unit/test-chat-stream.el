;;; test-chat-stream.el --- Tests for streaming response -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for streaming response functionality.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-stream)

(ert-deftest chat-stream-parse-sse-line-extracts-data ()
  "Test parsing SSE format line."
  (let ((result (chat-stream--parse-sse-line "data: {\"content\": \"hello\"}")))
    (should (stringp result))
    (should (string= result "{\"content\": \"hello\"}"))))

(ert-deftest chat-stream-parse-sse-line-ignores-other ()
  "Test that non-data lines are ignored."
  (should-not (chat-stream--parse-sse-line "event: message"))
  (should-not (chat-stream--parse-sse-line "id: 123"))
  (should-not (chat-stream--parse-sse-line ""))
  (should-not (chat-stream--parse-sse-line ": comment")))

(ert-deftest chat-stream-extract-content-from-kimi-chunk ()
  "Test extracting content from Kimi stream chunk."
  ;; Build JSON string properly
  (let* ((json-data '((choices . [((delta . ((content . " world"))))])))
         (chunk (json-encode json-data)))
    (should (string= (chat-stream--extract-content chunk 'kimi) " world"))))

(ert-deftest chat-stream-extract-content-returns-nil-on-done ()
  "Test that [DONE] signal returns nil."
  (should-not (chat-stream--extract-content "[DONE]" 'kimi))
  (should-not (chat-stream--extract-content "data: [DONE]" 'kimi)))

(ert-deftest chat-stream-buffer-inserts-text ()
  "Test that stream buffer inserts text correctly."
  (with-temp-buffer
    (let ((chat-stream--buffer (current-buffer))
          (chat-stream--insert-marker (point-marker)))
      (chat-stream--insert-text "Hello")
      (chat-stream--insert-text " world")
      (should (string= (buffer-string) "Hello world")))))

(provide 'test-chat-stream)
;;; test-stream.el ends here
