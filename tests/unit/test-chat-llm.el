;;; test-chat-llm.el --- Tests for chat-llm.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat-llm.el LLM abstraction layer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-llm)
(require 'chat-request-diagnostics)

;; ------------------------------------------------------------------
;; Provider Registration
;; ------------------------------------------------------------------

(ert-deftest chat-llm-register-provider-adds-to-list ()
  "Test that providers can be registered."
  (chat-llm-register-provider 'test-provider
                              :name "Test"
                              :base-url "https://test.example.com"
                              :api-key-fn (lambda () "test-key"))
  (should (assoc 'test-provider chat-llm-providers))
  (let ((config (cdr (assoc 'test-provider chat-llm-providers))))
    (should (string= (plist-get config :name) "Test"))
    (should (string= (plist-get config :base-url) "https://test.example.com"))))

(ert-deftest chat-llm-get-provider-returns-config ()
  "Test retrieving provider configuration."
  (chat-llm-register-provider 'another-provider
                              :name "Another"
                              :base-url "https://another.example.com")
  (let ((config (chat-llm-get-provider 'another-provider)))
    (should config)
    (should (string= (plist-get config :name) "Another"))))

;; ------------------------------------------------------------------
;; API Key Handling
;; ------------------------------------------------------------------

(ert-deftest chat-llm-api-key-from-function ()
  "Test API key retrieval from function."
  (chat-llm-register-provider 'fn-key-provider
                              :api-key-fn (lambda () "secret-key-from-fn"))
  (should (string= (chat-llm--get-api-key 'fn-key-provider)
                   "secret-key-from-fn")))

(ert-deftest chat-llm-api-key-from-string ()
  "Test API key retrieval from string."
  (chat-llm-register-provider 'string-key-provider
                              :api-key "secret-key-string")
  (should (string= (chat-llm--get-api-key 'string-key-provider)
                   "secret-key-string")))

(ert-deftest chat-llm-api-key-prefers-function ()
  "Test that api-key-fn takes precedence over api-key."
  (chat-llm-register-provider 'mixed-provider
                              :api-key "string-key"
                              :api-key-fn (lambda () "function-key"))
  (should (string= (chat-llm--get-api-key 'mixed-provider)
                   "function-key")))

;; ------------------------------------------------------------------
;; Message Formatting
;; ------------------------------------------------------------------

(ert-deftest chat-llm-format-messages-returns-list ()
  "Test that messages are formatted for API."
  (let ((messages (list (make-chat-message :role :user :content "Hello")
                        (make-chat-message :role :assistant :content "Hi"))))
    (let ((formatted (chat-llm--format-messages messages)))
      (should (arrayp formatted))
      (should (= (length formatted) 2))
      (let ((first (aref formatted 0)))
        (should (listp first))
        (should (equal (cdr (assoc 'role first)) "user"))
        (should (equal (cdr (assoc 'content first)) "Hello"))))))

;; ------------------------------------------------------------------
;; Request Building
;; ------------------------------------------------------------------

(ert-deftest chat-llm-build-request-includes-required-fields ()
  "Test request payload includes all required fields."
  (chat-llm-register-provider 'build-test
                              :model "test-model")
  (let* ((messages (list (make-chat-message :role :user :content "Test")))
         (request (chat-llm--build-request 'build-test messages nil)))
    (should (plistp request))
    (should (equal (plist-get request :model) "test-model"))
    (should (plist-get request :messages))
    (should (= (length (plist-get request :messages)) 1))))

(ert-deftest chat-llm-build-request-uses-provider-request-hook ()
  "Test request builder hooks override the default payload shape."
  (chat-llm-register-provider 'hook-test
                              :model "ignored"
                              :request-fn (lambda (_messages _options)
                                            '((custom . t))))
  (should (equal (chat-llm--build-request 'hook-test nil nil)
                 '((custom . t)))))

(ert-deftest chat-llm-build-request-uses-provider-build-request-hook ()
  "Test `:build-request-fn' is also honored."
  (chat-llm-register-provider 'build-hook-test
                              :model "ignored"
                              :build-request-fn (lambda (_messages _options)
                                                  '((builder . t))))
  (should (equal (chat-llm--build-request 'build-hook-test nil nil)
                 '((builder . t)))))

(ert-deftest chat-llm-request-async-calls-success-callback ()
  "Test async requests pass parsed response to the success callback."
  (let (captured-result)
    (chat-llm-register-provider 'async-test
                                :base-url "https://async.example.com"
                                :api-key "token"
                                :response-fn (lambda (_json-data) "async ok"))
    (cl-letf (((symbol-function 'chat-llm--post-async)
               (lambda (_url _headers _body success _error &optional _timeout)
                 (funcall success "{\"choices\":[{\"message\":{\"content\":\"ignored\"}}]}" 200)
                 'fake-handle)))
      (let ((handle (chat-llm-request-async
                     'async-test
                     (list (make-chat-message :role :user :content "Hi"))
                     (lambda (result)
                       (setq captured-result result))
                     (lambda (_err)
                       (should nil)))))
        (should (eq handle 'fake-handle))
        (should (equal (plist-get captured-result :content) "async ok"))
        (should (stringp (plist-get captured-result :raw-request)))
        (should (stringp (plist-get captured-result :raw-response)))))))

(ert-deftest chat-llm-request-async-calls-error-callback ()
  "Test async requests surface transport errors."
  (let (captured-error)
    (chat-llm-register-provider 'async-error-test
                                :base-url "https://async.example.com"
                                :api-key "token")
    (cl-letf (((symbol-function 'chat-llm--post-async)
               (lambda (_url _headers _body _success error &optional _timeout)
                 (funcall error "network failed")
                 'fake-handle)))
      (chat-llm-request-async
       'async-error-test
       (list (make-chat-message :role :user :content "Hi"))
       (lambda (_result)
         (should nil))
       (lambda (err)
         (setq captured-error err)))
      (should (string= captured-error "network failed")))))

(ert-deftest chat-llm-request-async-uses-configured-curl-transport ()
  "Test async requests honor provider specific curl transport."
  (let (captured-dispatch)
    (chat-llm-register-provider 'async-curl-test
                                :base-url "https://async.example.com"
                                :api-key "token"
                                :async-transport 'curl)
    (cl-letf (((symbol-function 'chat-llm--post-async-curl)
               (lambda (_url _headers _body success _error &optional _timeout)
                 (setq captured-dispatch 'curl)
                 (funcall success "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}" 200)
                 'curl-handle))
              ((symbol-function 'chat-llm--default-parse-response)
               (lambda (_json-data)
                 "ok")))
      (should (eq (chat-llm-request-async
                   'async-curl-test
                   (list (make-chat-message :role :user :content "Hi"))
                   (lambda (_result))
                   (lambda (_err)
                     (should nil)))
                  'curl-handle))
      (should (eq captured-dispatch 'curl)))))

(ert-deftest chat-llm-post-async-installs-timeout-timer ()
  "Test async transport installs a timeout timer for request handles."
  (let (captured-timeout handle)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url _callback _cbargs _silent _inhibit)
                 (setq handle (generate-new-buffer " *chat-llm-timeout*"))
                 handle))
              ((symbol-function 'run-at-time)
               (lambda (secs _repeat function &rest args)
                 (setq captured-timeout secs)
                 (list :timer function args))))
      (setq handle
            (chat-llm--post-async "https://example.com"
                                  nil
                                  "{}"
                                  (lambda (_body _status))
                                  (lambda (_err))
                                  7))
      (should (bufferp handle))
      (should (= captured-timeout 7)))))

(ert-deftest chat-llm-stream-falls-back-to-async-request ()
  "Test streaming API at least emits one content callback and a terminator."
  (let (chunks)
    (chat-llm-register-provider 'stream-fallback-test
                                :base-url "https://async.example.com"
                                :api-key "token")
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (lambda (_provider _messages success _error &optional _options)
                 (funcall success
                          '(:content "stream-body"
                            :raw-request "{\"request\":true}"
                            :raw-response "{\"response\":true}"))
                 'stream-handle)))
      (should (eq (chat-llm-stream
                   'stream-fallback-test
                   (list (make-chat-message :role :user :content "Hi"))
                   (lambda (chunk)
                     (push chunk chunks)))
                  'stream-handle))
      (should (equal (nreverse chunks) '("stream-body" nil))))))

(ert-deftest chat-llm-cancel-request-cancels-timeout-timer ()
  "Test cancelling a request also cancels its timeout timer."
  (let ((handle (generate-new-buffer " *chat-llm-cancel*"))
        cancelled)
    (with-current-buffer handle
      (setq-local chat-llm--timeout-timer 'fake-timer))
    (cl-letf (((symbol-function 'cancel-timer)
               (lambda (timer)
                 (setq cancelled timer))))
      (should (chat-llm-cancel-request handle))
      (should (eq cancelled 'fake-timer)))))

(ert-deftest chat-llm-request-async-records-request-diagnostics ()
  "Test async requests update diagnostics when a request id is provided."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        snapshot)
    (puthash "req-test"
             (make-chat-request-trace
              :id "req-test"
              :mode 'chat
              :provider 'async-diag-test
              :model 'async-diag-test
              :phase 'created
              :started-at (current-time)
              :updated-at (current-time))
             chat-request-diagnostics--traces)
    (chat-llm-register-provider 'async-diag-test
                                :base-url "https://async.example.com"
                                :api-key "token"
                                :response-fn (lambda (_json-data) "async ok"))
    (cl-letf (((symbol-function 'chat-llm--post-async)
               (lambda (_url _headers _body success _error &optional _timeout)
                 (let ((handle (generate-new-buffer " *chat-llm-diag*")))
                   (funcall success "{\"choices\":[{\"message\":{\"content\":\"ignored\"}}]}" 200)
                   handle))))
      (chat-llm-request-async
       'async-diag-test
       (list (make-chat-message :role :user :content "Hi"))
       (lambda (_result))
       (lambda (_err) (should nil))
       (list :request-id "req-test"))
      (setq snapshot (chat-request-diagnostics-snapshot "req-test"))
      (should (equal (plist-get snapshot :phase) 'processing))
      (should (equal (plist-get snapshot :timeout) 60))
      (should (seq-some
               (lambda (event)
                 (string-match-p "Received HTTP 200"
                                 (or (plist-get event :summary) "")))
               (plist-get snapshot :events))))))

(provide 'test-chat-llm)
;;; test-chat-llm.el ends here
