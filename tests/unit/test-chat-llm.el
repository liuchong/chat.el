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
;; Registered, enabled, configured
;; ------------------------------------------------------------------

(defmacro test-chat-llm--with-own-registry (&rest body)
  "Evaluate BODY over a provider registry of its own.

The real one is global and every registration in this file adds to it
permanently, so a test about which providers exist has to bring its own."
  (declare (indent 0))
  `(let ((chat-llm-providers nil)
         (chat-llm-enabled-providers nil))
     ,@body))

(ert-deftest chat-llm-configured-is-narrower-than-registered ()
  "chat.el registers every vendor it can speak to; a key says which are real.

Without this distinction the provider list offered to someone is a
catalogue of everything the package was built against."
  (test-chat-llm--with-own-registry
    (chat-llm-register-provider 'has-key :name "Has" :api-key "k")
    (chat-llm-register-provider 'no-key :name "None")
    (should (equal '(has-key no-key)
                   (sort (chat-llm-enabled-providers) #'string<)))
    (should (equal '(has-key) (chat-llm-configured-providers)))
    (should (chat-llm-provider-configured-p 'has-key))
    (should-not (chat-llm-provider-configured-p 'no-key))
    (should-not (chat-llm-provider-configured-p 'never-registered))))

(ert-deftest chat-llm-configured-is-sensed-not-remembered ()
  "A key set halfway through a session counts from the next look."
  (test-chat-llm--with-own-registry
    (let ((key nil))
      (chat-llm-register-provider 'later :name "Later"
                                  :api-key-fn (lambda () key))
      (should-not (chat-llm-configured-providers))
      (setq key "arrived")
      (should (equal '(later) (chat-llm-configured-providers)))
      (setq key nil)
      (should-not (chat-llm-configured-providers)))))

(ert-deftest chat-llm-configured-still-honours-the-enabled-list ()
  "Disabling a provider outranks having a key for it."
  (test-chat-llm--with-own-registry
    (chat-llm-register-provider 'wanted :name "Wanted" :api-key "k")
    (chat-llm-register-provider 'unwanted :name "Unwanted" :api-key "k")
    (let ((chat-llm-enabled-providers '(wanted)))
      (should (equal '(wanted) (chat-llm-configured-providers))))))

(ert-deftest chat-llm-a-key-lookup-that-fails-answers-no ()
  "This runs while drawing, so the error belongs to the request instead."
  (test-chat-llm--with-own-registry
    (chat-llm-register-provider 'broken :name "Broken"
                                :api-key-fn (lambda () (error "No keyring")))
    (should-not (chat-llm-provider-configured-p 'broken))
    (should-not (chat-llm-configured-providers))))

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

(ert-deftest chat-llm-extracts-finish-reason ()
  "Test finish_reason extraction from OpenAI style responses."
  (should (string= (chat-llm--extract-finish-reason
                    '((choices . [((message . ((content . "x")))
                                  (finish_reason . "length"))])))
                   "length"))
  (should-not (chat-llm--extract-finish-reason '((choices . []))))
  (should-not (chat-llm--extract-finish-reason nil)))

(ert-deftest chat-llm-extracts-anthropic-stop-reason ()
  "Test stop_reason extraction from Anthropic style responses."
  (should (string= (chat-llm--extract-finish-reason
                    '((stop_reason . "max_tokens")))
                   "length"))
  (should (string= (chat-llm--extract-finish-reason
                    '((stop_reason . "end_turn")))
                   "end_turn")))

(ert-deftest chat-llm-kimi-code-anthropic-uses-anthropic-protocol ()
  "Test the Kimi Code anthropic provider uses the Messages API shape."
  (should (string= (chat-llm--request-url 'kimi-code-anthropic)
                   "https://api.kimi.com/coding/v1/messages"))
  (let ((chat-llm-kimi-code-api-key "kimi-key"))
    (should (equal (cdr (assoc "x-api-key"
                               (chat-llm--make-headers 'kimi-code-anthropic)))
                   "kimi-key"))
    (should (cdr (assoc "anthropic-version"
                        (chat-llm--make-headers 'kimi-code-anthropic)))))
  (let* ((messages (list (make-chat-message :role :system :content "Rule")
                         (make-chat-message :role :user :content "Hello")))
         (request (chat-llm-claude--build-request
                   'kimi-code-anthropic messages nil)))
    (should (equal (plist-get request :model) "kimi-for-coding"))
    (should (equal (plist-get request :system) "Rule"))))

(ert-deftest chat-llm-kimi-code-pins-temperature-to-one ()
  "Test the Kimi Code provider sends temperature 1 whatever the caller asks.

The endpoint accepts only 1 and answers 400 `invalid temperature' for
anything else, on k3, k3-256k and kimi-for-coding alike, while
`chat-ui' always passes 0.7."
  (let* ((messages (list (make-chat-message :role :user :content "Hello")))
         (default (chat-llm-kimi-code--build-request messages nil))
         (overridden (chat-llm-kimi-code--build-request
                      messages '(:temperature 0.7))))
    (should (equal (alist-get 'temperature default) 1))
    (should (equal (alist-get 'temperature overridden) 1))))

(ert-deftest chat-llm-ark-registers-both-protocols ()
  "Test Ark registers OpenAI and Anthropic compatible providers."
  (should (string= (chat-llm--request-url 'ark-code)
                   "https://ark.cn-beijing.volces.com/api/plan/v3/chat/completions"))
  (should (string= (chat-llm--request-url 'ark-code-anthropic)
                   "https://ark.cn-beijing.volces.com/api/plan/v1/messages"))
  (let ((chat-llm-ark-api-key "ark-key"))
    (should (equal (cdr (assoc "Authorization"
                               (chat-llm--make-headers 'ark-code)))
                   "Bearer ark-key"))
    (should (equal (cdr (assoc "x-api-key"
                               (chat-llm--make-headers 'ark-code-anthropic)))
                   "ark-key")))
  (let* ((messages (list (make-chat-message :role :user :content "Hello")))
         (openai-req (chat-llm--build-request 'ark-code messages nil))
         (anthropic-req (chat-llm-claude--build-request
                         'ark-code-anthropic messages nil)))
    (should (equal (plist-get openai-req :model) "ark-code-latest"))
    (should (equal (plist-get anthropic-req :model) "ark-code-latest"))))

(ert-deftest chat-llm-format-messages-keeps-tool-role ()
  "Test convertToLlm emits tool_call_id for :tool messages."
  (let* ((messages (list
                    (make-chat-message :role :user :content "hi")
                    (make-chat-message
                     :role :assistant
                     :content ""
                     :tool-calls '((:id "call-1" :name "demo-tool"
                                   :arguments (("input" . "x")))))
                    (make-chat-message
                     :role :tool
                     :content "echo:x"
                     :metadata '(:tool-call-id "call-1"))))
         (formatted (chat-llm--format-messages messages)))
    (should (= (length formatted) 3))
    (let ((assistant (aref formatted 1))
          (tool (aref formatted 2)))
      (should (equal (cdr (assoc 'role assistant)) "assistant"))
      (should (assoc 'tool_calls assistant))
      (should (equal (cdr (assoc 'role tool)) "tool"))
      (should (equal (cdr (assoc 'tool_call_id tool)) "call-1")))))

(ert-deftest chat-llm-format-messages-expands-persisted-tool-results ()
  "Test stored assistant tool-results become tool role payloads."
  (let* ((messages (list
                    (make-chat-message
                     :role :assistant
                     :content "using tools"
                     :tool-calls '((:id "call-9" :name "demo-tool"
                                   :arguments (("input" . "x"))))
                     :tool-results '("echo:x"))))
         (formatted (chat-llm--format-messages messages)))
    (should (= (length formatted) 2))
    (should (equal (cdr (assoc 'role (aref formatted 1))) "tool"))
    (should (equal (cdr (assoc 'tool_call_id (aref formatted 1))) "call-9"))
    (should (equal (cdr (assoc 'content (aref formatted 1))) "echo:x"))))

(defun test-chat-llm--unpaired-tool-ids (messages)
  "Return the tool_call_ids in MESSAGES that no assistant turn offered.

This is the check the provider performs on a request, so it is the check
worth making here: walk the payload in order, collect the ids each
assistant advertises, and report any `tool_call_id' that arrives without
one.  Asserting on the ids themselves would only have pinned down the
fallback that was already wrong."
  (let ((offered nil)
        (unpaired nil))
    (dotimes (index (length messages))
      (let* ((entry (aref messages index))
             (role (cdr (assoc 'role entry))))
        (cond
         ((equal role "assistant")
          (dolist (call (append (cdr (assoc 'tool_calls entry)) nil))
            (push (cdr (assoc 'id call)) offered)))
         ((equal role "tool")
          (let ((id (cdr (assoc 'tool_call_id entry))))
            (unless (member id offered)
              (push id unpaired)))))))
    (nreverse unpaired)))

(defun test-chat-llm--offered-tool-ids (messages)
  "Return every id the assistant turns in MESSAGES advertise."
  (let (ids)
    (dotimes (index (length messages))
      (let ((entry (aref messages index)))
        (when (equal (cdr (assoc 'role entry)) "assistant")
          (dolist (call (append (cdr (assoc 'tool_calls entry)) nil))
            (push (cdr (assoc 'id call)) ids)))))
    (nreverse ids)))

(ert-deftest chat-llm-a-turn-without-call-ids-still-pairs ()
  "A transcript written before calls carried ids has to remain sendable.

This is the shape that produced `tool_call_id is not found': the calls
were parsed out of the reply text, so they reached disk with no ids, and
the results were stored on the same assistant message.  The call side then
fell back to the tool name and the result side to its position, leaving
the request advertising `files_read' while referring to `call-1'."
  (let* ((messages
          (list (make-chat-message :id "u1" :role :user :content "review this")
                (make-chat-message
                 :id "a1"
                 :role :assistant
                 :content "here is the review"
                 :tool-calls '((:name "files_read"
                                :arguments (("path" . "design.md")))
                               (:name "shell_execute"
                                :arguments (("command" . "wc -l design.md"))))
                 :tool-results '("# Design" "1437 design.md"))))
         (formatted (chat-llm--format-messages messages)))
    (should (= (length formatted) 4))
    (should-not (test-chat-llm--unpaired-tool-ids formatted))))

(ert-deftest chat-llm-calling-one-tool-twice-gives-two-ids ()
  "Reading a long file in chunks calls one tool repeatedly.

The fallback used to be the tool name, so every chunk answered to the same
id and the results were indistinguishable."
  (let* ((messages
          (list (make-chat-message
                 :id "a1"
                 :role :assistant
                 :content ""
                 :tool-calls '((:name "files_read_lines"
                                :arguments (("start_line" . 1)))
                               (:name "files_read_lines"
                                :arguments (("start_line" . 301)))
                               (:name "files_read_lines"
                                :arguments (("start_line" . 601))))
                 :tool-results '("part one" "part two" "part three"))))
         (formatted (chat-llm--format-messages messages))
         (offered (test-chat-llm--offered-tool-ids formatted)))
    (should (= (length offered) 3))
    (should (= (length (delete-dups (copy-sequence offered))) 3))
    (should-not (test-chat-llm--unpaired-tool-ids formatted))))

(ert-deftest chat-llm-two-idless-turns-do-not-claim-the-same-ids ()
  "Ids are unique across the history, not just within one turn.

A positional fallback alone would number both turns from one, and the
second turn's results would pair with the first turn's calls."
  (let* ((messages
          (list (make-chat-message
                 :id "a1" :role :assistant :content "first"
                 :tool-calls '((:name "files_read" :arguments nil))
                 :tool-results '("one"))
                (make-chat-message :id "u2" :role :user :content "again")
                (make-chat-message
                 :id "a2" :role :assistant :content "second"
                 :tool-calls '((:name "files_read" :arguments nil))
                 :tool-results '("two"))))
         (formatted (chat-llm--format-messages messages))
         (offered (test-chat-llm--offered-tool-ids formatted)))
    (should (= (length offered) 2))
    (should-not (equal (car offered) (cadr offered)))
    (should-not (test-chat-llm--unpaired-tool-ids formatted))))

(ert-deftest chat-llm-a-provider-id-is-never-replaced ()
  "The fallback is for transcripts that lack ids, not a rewrite."
  (let* ((messages
          (list (make-chat-message
                 :id "a1" :role :assistant :content ""
                 :tool-calls '((:id "call_abc123" :name "demo" :arguments nil))
                 :tool-results '("done"))))
         (formatted (chat-llm--format-messages messages)))
    (should (equal (test-chat-llm--offered-tool-ids formatted)
                   '("call_abc123")))
    (should (equal (cdr (assoc 'tool_call_id (aref formatted 1)))
                   "call_abc123"))))

(ert-deftest chat-llm-a-minted-id-is-not-the-tool-name ()
  "Two calls to one tool have to be told apart."
  (let ((first (chat-llm-new-tool-call-id "files_read"))
        (second (chat-llm-new-tool-call-id "files_read")))
    (should-not (equal first second))
    (should-not (equal first "files_read"))))

(ert-deftest chat-llm-extracts-openai-tool-calls ()
  "Test native OpenAI tool_calls decode into plists."
  (let ((calls (chat-llm--extract-tool-calls
                '((choices . [((message . ((content . :json-null)
                                           (tool_calls . [((id . "call-1")
                                                           (function . ((name . "demo-tool")
                                                                        (arguments . "{\"input\":\"hi\"}"))))])))
                               (finish_reason . "tool_calls"))]))))
        (reason (chat-llm--extract-finish-reason
                 '((choices . [((finish_reason . "tool_calls"))])))))
    (should (= (length calls) 1))
    (should (string= (plist-get (car calls) :id) "call-1"))
    (should (string= (plist-get (car calls) :name) "demo-tool"))
    (should (equal (plist-get (car calls) :arguments) '(("input" . "hi"))))
    (should (string= reason "tool_calls"))))

(ert-deftest chat-llm-parses-null-content-as-empty-string ()
  "Test tool-only responses with null content do not error."
  (should (string= (chat-llm--default-parse-response
                    '((choices . [((message . ((content . :json-null)
                                               (tool_calls . []))))])))
                   "")))

(ert-deftest chat-llm-openai-compatible-request-includes-tools ()
  "Test OpenAI compatible requests advertise provider tools."
  (chat-llm-register-provider 'tools-test
                              :model "test-model"
                              :request-fn (lambda (messages options)
                                            (chat-llm-build-openai-compatible-request
                                             'tools-test messages options)))
  (let* ((tools [((type . "function")
                  (function . ((name . "demo-tool")
                               (description . "Echo")
                               (parameters . ((type . "object"))))))])
         (request (chat-llm--build-request
                   'tools-test
                   (list (make-chat-message :role :user :content "Hi"))
                   (list :tools tools))))
    (should (equal (plist-get request :tool_choice) "auto"))
    (should (equal (plist-get request :tools) tools))))

(provide 'test-chat-llm)
;;; test-chat-llm.el ends here
