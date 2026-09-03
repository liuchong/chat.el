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

(ert-deftest chat-stream-handle-output-exposes-complete-payloads ()
  "The normalized runtime can observe each complete raw SSE payload."
  (let ((buffer (generate-new-buffer " *chat-stream-payload-test*"))
        payloads)
    (unwind-protect
        (let ((proc (make-pipe-process :name "chat-stream-payload-test"
                                       :buffer buffer :noquery t)))
          (with-current-buffer buffer
            (setq-local chat-stream--partial-line ""))
          (chat-stream--handle-output
           proc "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n"
           'kimi #'ignore nil
           (lambda (payload) (push payload payloads)))
          (should (= (length payloads) 1))
          (should (string-match-p "\\\"content\\\":\\\"ok\\\""
                                  (car payloads)))
          (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

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

(ert-deftest chat-stream-handle-output-does-not-require-diagnostics-trace ()
  "An optional request id must not make diagnostics part of the data path."
  (let ((buffer (generate-new-buffer " *chat-stream-no-trace*"))
        (chat-request-diagnostics--traces (make-hash-table :test 'equal))
        payloads
        chunks)
    (unwind-protect
        (let ((proc (make-pipe-process :name "chat-stream-no-trace"
                                       :buffer buffer
                                       :noquery t)))
          (process-put proc 'chat-request-id "unregistered-request")
          (with-current-buffer buffer
            (setq-local chat-stream--partial-line ""))
          (chat-stream--handle-output
           proc
           (concat
            "data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n"
            "data: {\"choices\":[{\"delta\":{\"content\":\" second\"}}]}\n")
           'kimi
           (lambda (chunk) (push chunk chunks))
           nil
           (lambda (payload) (push payload payloads)))
          (should (equal (nreverse chunks) '("first" " second")))
          (should (= (length payloads) 2))
          (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest chat-stream-captures-http-error-payload ()
  "Test non-SSE JSON error bodies are captured for the sentinel."
  (let ((buffer (generate-new-buffer " *stream-err-test*"))
        (proc nil))
    (unwind-protect
        (progn
          (setq proc (start-process "stream-err-test" buffer "true"))
          (chat-stream--handle-output
           proc
           "{\"error\":{\"message\":\"bad key\",\"type\":\"invalid_authentication_error\"}}\n"
           'kimi
           #'ignore)
          (should (equal (process-get proc 'chat-stream-http-error)
                         "bad key")))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest chat-stream-accumulates-native-tool-calls ()
  "Test streamed tool_call deltas are merged into a native result."
  (let ((buffer (generate-new-buffer " *chat-stream-tools*"))
        (proc nil))
    (unwind-protect
        (progn
          (setq proc (start-process "chat-stream-tools" buffer "true"))
          (chat-stream-accumulate-payload
           proc
           "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"function\":{\"name\":\"demo-tool\",\"arguments\":\"{\\\"in\"}}]}}]}")
          (chat-stream-accumulate-payload
           proc
           "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"put\\\":\\\"hi\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}")
          (let ((result (chat-stream-native-result proc)))
            (should (string= (plist-get result :finish-reason) "tool_calls"))
            (should (= (length (plist-get result :tool-calls)) 1))
            (should (string= (plist-get (car (plist-get result :tool-calls)) :name)
                             "demo-tool"))
            (should (equal (plist-get (car (plist-get result :tool-calls)) :arguments)
                           '(("input" . "hi"))))))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest chat-stream-accumulates-anthropic-tool-and-stop-deltas ()
  "Test native tool input and nested stop reasons share the stream contract."
  (let ((buffer (generate-new-buffer " *chat-stream-anthropic-tools*"))
        proc)
    (unwind-protect
        (progn
          (setq proc (start-process "chat-stream-anthropic-tools" buffer "true"))
          (chat-stream-accumulate-payload
           proc
           "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool-1\",\"name\":\"demo-tool\",\"input\":{}}}")
          (chat-stream-accumulate-payload
           proc
           "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"input\\\":\\\"hi\\\"}\"}}")
          (chat-stream-accumulate-payload
           proc
           "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}")
          (let* ((result (chat-stream-native-result proc))
                 (call (car (plist-get result :tool-calls))))
            (should (equal (plist-get result :finish-reason) "length"))
            (should (equal (plist-get call :id) "tool-1"))
            (should (equal (plist-get call :name) "demo-tool"))
            (should (equal (plist-get call :arguments)
                           '(("input" . "hi"))))))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest chat-stream-accumulates-reasoning-and-terminal-errors ()
  "Test reasoning deltas and provider error events remain typed."
  (let ((buffer (generate-new-buffer " *chat-stream-reasoning*"))
        proc)
    (unwind-protect
        (progn
          (setq proc (start-process "chat-stream-reasoning" buffer "true"))
          (chat-stream-accumulate-payload
           proc
           "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"check inputs\"}}")
          (chat-stream-accumulate-payload
           proc
           "{\"type\":\"error\",\"error\":{\"message\":\"stream failed\"}}")
          (should
           (equal (plist-get (chat-stream-native-result proc) :reasoning)
                  "check inputs"))
          (should
           (equal (process-get proc 'chat-stream-http-error)
                  "stream failed")))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest chat-stream-reasoning-deltas-keep-their-order ()
  "Reasoning is collected per delta and read once, at the end.

Rebuilding the whole trace on every delta made a long one quadratic to
collect, so the deltas are pushed onto a list instead -- which puts them
in the wrong order unless the read reverses them."
  (let ((buffer (generate-new-buffer " *chat-stream-reasoning-order*"))
        proc)
    (unwind-protect
        (progn
          (setq proc (start-process "chat-stream-order" buffer "true"))
          (dolist (thought '("first" " then" " last"))
            (chat-stream-accumulate-payload
             proc
             (format "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"%s\"}}"
                     thought)))
          (should (equal (plist-get (chat-stream-native-result proc) :reasoning)
                         "first then last")))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest chat-stream-a-request-marks-its-own-phases ()
  "Timing the send only from the UI left a phase nothing could explain.

Two hundred milliseconds of every send sat inside one call into the
transport, where the pieces differ by kind: building a payload, encoding
it, appending to the log, and connecting -- and connecting is the one
cost that cannot be measured anywhere but the sender's own Emacs."
  (let ((log-file (make-temp-file "chat-stream-timing")))
    (unwind-protect
        (let ((chat-log-file log-file)
              (chat-log-enabled t)
              (chat-log-timings t)
              (stand-in (make-pipe-process :name "chat-stream-timing"
                                           :noquery t))
              posted)
          (unwind-protect
              (cl-letf
                  (((symbol-function 'chat-llm-get-provider)
                    (lambda (&rest _)
                      '(:model "test" :base-url "https://example.invalid")))
                   ((symbol-function 'chat-llm--make-headers)
                    (lambda (&rest _) '(("Authorization" . "Bearer x"))))
                   ((symbol-function 'chat-llm--build-request)
                    (lambda (&rest _) '(:messages [])))
                   ((symbol-function 'chat-stream-net-post)
                    (lambda (url headers body _on-data _on-terminal)
                      (setq posted (list :url url :headers headers
                                         :body body))
                      stand-in)))
                (chat-log-timing-start)
                (chat-stream-request 'deepseek nil #'ignore)
                (chat-log-timing-report "stream send")
                (let ((logged (with-temp-buffer
                                (insert-file-contents log-file)
                                (buffer-string))))
                  (dolist (phase '("headers" "build" "encode" "log"
                                   "spawn" "diagnostics"))
                    (should (string-match-p (concat phase " [0-9]+")
                                            logged))))
                ;; In-process transport: the request went straight to the
                ;; network layer -- no curl config file, no command line
                ;; carrying the token.
                (should (string-match-p "messages" (plist-get posted :body)))
                (should (equal (plist-get posted :url)
                               "https://example.invalid/chat/completions")))
            (when (process-live-p stand-in)
              (delete-process stand-in))))
      (delete-file log-file))))

(provide 'test-chat-stream)
;;; test-stream.el ends here
