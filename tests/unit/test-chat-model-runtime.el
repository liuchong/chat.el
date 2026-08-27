;;; test-chat-model-runtime.el --- Unified model runtime tests -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'chat-model-runtime)
(require 'chat-llm-claude)

(defmacro test-chat-model-runtime--isolated (&rest body)
  "Evaluate BODY with private provider and capability state."
  (declare (indent 0))
  `(let ((chat-llm-providers nil)
         (chat-llm-enabled-providers nil)
         (chat-model-capabilities--registry nil)
         (chat-model-discovery--cache (make-hash-table :test 'eq))
         (chat-model-discovery--loaded t)
         (chat-model-discovery-cache-file nil))
     ,@body))

(defun test-chat-model-runtime--register (&optional capabilities)
  "Register the fixture provider with CAPABILITIES."
  (chat-llm-register-provider
   'model-runtime-fixture
   :model "fixture-model"
   :capabilities
   (or capabilities
       '(:stream t :tools t :tool-choice (auto) :reasoning t
         :input-modalities (text) :structured-output (json-object)))))

(ert-deftest chat-model-runtime-normalizes-async-result-events ()
  "One async result becomes ordered deltas, usage and one completion."
  (test-chat-model-runtime--isolated
    (test-chat-model-runtime--register)
    (let (events)
      (cl-letf (((symbol-function 'chat-llm-request-async)
                 (lambda (_provider _messages success _error _options)
                   (funcall
                    success
                    '(:content "answer" :reasoning "thought"
                      :tool-calls ((:id "call-1" :name "read"
                                    :arguments ((path . "README"))))
                      :finish-reason "tool_calls"
                      :usage (:input-tokens 3 :output-tokens 4
                              :total-tokens 7)))
                   'fixture-handle)))
        (should
         (eq (chat-model-request-events
              'model-runtime-fixture nil
              (lambda (event) (push event events)))
             'fixture-handle)))
      (setq events (nreverse events))
      (should (equal (mapcar #'chat-model-event-type events)
                     '(started reasoning-delta text-delta tool-call-delta
                       usage completed)))
      (should (equal (mapcar #'chat-model-event-sequence events)
                     '(1 2 3 4 5 6)))
      (should (= (length (delete-dups
                          (mapcar #'chat-model-event-request-id events)))
                 1))
      (should (equal
               (plist-get
                (plist-get (chat-model-event-payload (car (last events)))
                           :result)
                :content)
               "answer")))))

(ert-deftest chat-model-runtime-emits-one-terminal-error ()
  "Late duplicate callbacks cannot close one request twice."
  (test-chat-model-runtime--isolated
    (test-chat-model-runtime--register)
    (let (events)
      (cl-letf (((symbol-function 'chat-llm-request-async)
                 (lambda (_provider _messages success error _options)
                   (funcall error "first")
                   (funcall error "second")
                   (funcall success '(:content "late"))
                   'fixture-handle)))
        (chat-model-request-events
         'model-runtime-fixture nil
         (lambda (event) (push event events))))
      (should (equal (mapcar #'chat-model-event-type (nreverse events))
                     '(started error))))))

(ert-deftest chat-model-runtime-preflight-stops-incompatible-dispatch ()
  "Capability rejection happens before the low-level transport is called."
  (test-chat-model-runtime--isolated
    (test-chat-model-runtime--register '(:tools nil))
    (let ((dispatched nil)
          events)
      (cl-letf (((symbol-function 'chat-llm-request-async)
                 (lambda (&rest _args) (setq dispatched t))))
        (chat-model-request-events
         'model-runtime-fixture nil
         (lambda (event) (push event events))
         '(:tools [((type . "function"))])))
      (should-not dispatched)
      (should (equal (mapcar #'chat-model-event-type events) '(error))))))

(ert-deftest chat-model-runtime-normalizes-openai-stream-fixture ()
  "OpenAI-shaped SSE preserves reasoning, text, tools and usage."
  (test-chat-model-runtime--isolated
    (test-chat-model-runtime--register)
    (let (types text reasoning usage error)
      (chat-model-runtime--stream-payload
       'model-runtime-fixture
       "{\"choices\":[{\"delta\":{\"reasoning_content\":\"why\",\"content\":\"yes\",\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\"}}]}}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":2,\"total_tokens\":2}}"
       (lambda (type _payload) (push type types))
       (lambda (piece) (setq text piece))
       (lambda (piece) (setq reasoning piece))
       (lambda (value) (setq usage value))
       (lambda (message) (setq error message)))
      (should (equal (nreverse types)
                     '(reasoning-delta text-delta tool-call-delta usage)))
      (should (equal text "yes"))
      (should (equal reasoning "why"))
      (should (= (plist-get usage :input-tokens) 0))
      (should-not error))))

(ert-deftest chat-model-runtime-normalizes-anthropic-stream-fixtures ()
  "Anthropic-shaped SSE maps onto the same event vocabulary."
  (test-chat-model-runtime--isolated
    (chat-llm-register-provider
     'anthropic-fixture :model "fixture-model"
     :stream-fn
     (lambda (data)
       (let ((delta (alist-get 'delta data)))
         (when (equal (alist-get 'type delta) "text_delta")
           (alist-get 'text delta)))))
    (let (types text reasoning usage error)
      (dolist
          (payload
           '("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"why\"}}"
             "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"yes\"}}"
             "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c1\",\"name\":\"read\",\"input\":{}}}"
             "{\"type\":\"message_delta\",\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}"))
        (chat-model-runtime--stream-payload
         'anthropic-fixture payload
         (lambda (type _value) (push type types))
         (lambda (piece) (setq text piece))
         (lambda (piece) (setq reasoning piece))
         (lambda (value) (setq usage value))
         (lambda (message) (setq error message))))
      (should (equal (nreverse types)
                     '(reasoning-delta text-delta tool-call-delta usage)))
      (should (equal text "yes"))
      (should (equal reasoning "why"))
      (should (= (plist-get usage :total-tokens) 7))
      (should-not error))))

(ert-deftest chat-model-runtime-decode-preserves-reasoning-and-usage ()
  "Non-streaming decoding keeps model reasoning and token counters."
  (let* ((config '(:response-parser chat-llm-parse-openai-compatible-response))
         (result
          (chat-llm--decode-response
           config "{}"
           "{\"choices\":[{\"message\":{\"content\":\"yes\",\"reasoning_content\":\"why\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}"
           200)))
    (should (equal (plist-get result :reasoning) "why"))
    (should (= (plist-get (plist-get result :usage) :total-tokens) 5))))

(provide 'test-chat-model-runtime)
;;; test-chat-model-runtime.el ends here
