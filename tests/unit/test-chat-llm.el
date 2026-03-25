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

(provide 'test-chat-llm)
;;; test-chat-llm.el ends here
