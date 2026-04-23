;;; test-chat-stream.el --- Tests for streaming response -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for streaming response functionality.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-stream)
(require 'chat-request-diagnostics)

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
  (let* ((json-data '(("choices" . ((("delta" . (("content" . " world"))))))))
         (chunk (json-encode json-data)))
    (should (string= (chat-stream--extract-content chunk 'kimi) " world"))))

(ert-deftest chat-stream-extract-content-uses-provider-stream-hook ()
  "Test stream extraction honors provider specific parser hooks."
  (chat-llm-register-provider 'stream-hook-test
                              :stream-fn (lambda (json-data)
                                           (cdr (assoc 'text json-data))))
  (should (string=
           (chat-stream--extract-content "{\"text\":\"hooked\"}" 'stream-hook-test)
           "hooked")))

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

(ert-deftest chat-stream-handle-output-joins-partial-lines ()
  "Test that partial SSE lines are buffered across chunks."
  (let ((buffer (generate-new-buffer " *chat-stream-test*"))
        (received nil))
    (unwind-protect
        (let ((proc (make-pipe-process :name "chat-stream-test"
                                       :buffer buffer
                                       :noquery t)))
          (with-current-buffer buffer
            (setq-local chat-stream--partial-line ""))
          (chat-stream--handle-output
           proc
           "data: {\"choices\":[{\"delta\":{\"content\":\"hel"
           'kimi
           (lambda (chunk)
             (push chunk received)))
          (should (null received))
          (chat-stream--handle-output
           proc
           "lo\"}}]}\n"
           'kimi
           (lambda (chunk)
             (push chunk received)))
          (should (equal received '("hello")))
          (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest chat-stream-redact-curl-args-for-log-hides-secrets ()
  "Test curl args logging hides bearer tokens and large bodies."
  (let ((redacted
         (chat-stream--redact-curl-args-for-log
          '("-s"
            "-H" "Authorization: Bearer secret-token"
            "-d" "{\"hello\":\"world\"}"
            "https://example.com"))))
    (should (equal redacted
                   '("-s"
                     "-H" "Authorization: Bearer <redacted>"
                     "-d" "<17 bytes>"
                     "https://example.com")))
    (should-not (cl-some (lambda (item)
                           (and (stringp item)
                                (string-match-p "secret-token" item)))
                         redacted))))

(ert-deftest chat-stream-handle-output-records-stream-diagnostics ()
  "Test stream output updates diagnostics chunk counters."
  (let ((buffer (generate-new-buffer " *chat-stream-diag*"))
        (chat-request-diagnostics--traces (make-hash-table :test 'equal))
        snapshot)
    (unwind-protect
        (let ((proc (make-pipe-process :name "chat-stream-diag"
                                       :buffer buffer
                                       :noquery t)))
          (puthash "req-stream"
                   (make-chat-request-trace
                    :id "req-stream"
                    :mode 'chat
                    :provider 'kimi
                    :model 'kimi
                    :phase 'streaming
                    :started-at (current-time)
                    :updated-at (current-time))
                   chat-request-diagnostics--traces)
          (process-put proc 'chat-request-id "req-stream")
          (with-current-buffer buffer
            (setq-local chat-stream--partial-line ""))
          (chat-stream--handle-output
           proc
           "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n"
           'kimi
           (lambda (_chunk)))
          (setq snapshot (chat-request-diagnostics-snapshot "req-stream"))
          (should (= (plist-get snapshot :stream-chunk-count) 1))
          (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(provide 'test-chat-stream)
;;; test-stream.el ends here
