;;; test-chat-agent.el --- Tests for chat-agent -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-agent)

(defun chat-agent-test--stub-transport (responses calls)
  "Return a stub transport serving RESPONSES in order.
Each element is either a result plist passed to the success callback or
a function called with the success callback.  CALLS is a cons cell whose
car collects the messages of every request."
  (let ((remaining responses))
    (lambda (_model messages success _error _options)
      (setcar calls (append (car calls) (list messages)))
      (let ((next (pop remaining)))
        (when (functionp next)
          (setq next (funcall next)))
        (when next
          (funcall success next)))
      'stub-handle)))

(defun chat-agent-test--register-demo-tool (counter)
  "Register a demo tool counting executions into the car of COUNTER."
  (chat-tool-forge-register
   (make-chat-forged-tool
    :id 'demo-tool
    :name "Demo Tool"
    :description "Echo one argument"
    :language 'elisp
    :parameters '((:name "input" :type "string" :required t))
    :compiled-function (lambda (input)
                         (setcar counter (1+ (car counter)))
                         (format "echo:%s" input))
    :is-active t
    :usage-count 0)))

(defconst chat-agent-test--tool-call-json
  "{\"function_call\":{\"name\":\"demo-tool\",\"arguments\":{\"input\":\"hi\"}}}"
  "A valid demo tool call response.")

(defun chat-agent-test--user-message ()
  "Return one user message for agent tests."
  (make-chat-message
   :id "user-1"
   :role :user
   :content "测试请求"
   :timestamp (current-time)))

(ert-deftest chat-agent-completes-simple-answer ()
  "Test a plain answer finishes the run as completed in one step."
  (let ((calls (list nil))
        (events nil)
        run)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "最终回答" :raw-request "r" :raw-response "s"))
                calls)))
      (setq run (chat-agent-start
                 (list :model 'kimi
                       :messages (list (chat-agent-test--user-message))
                       :on-event (lambda (event) (setq events (append events (list event)))))))
      (let ((end (car (last events))))
        (should (eq (plist-get end :type) 'agent-end))
        (should (eq (plist-get end :status) 'completed))
        (should (string= (plist-get end :content) "最终回答"))
        (should (= (plist-get end :steps) 1)))
      (should (= (length (car calls)) 1))
      (should (chat-agent-run-state-done run)))))

(ert-deftest chat-agent-executes-tool-and-feeds-result-back ()
  "Test a tool call is executed and its result drives a follow-up turn."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (calls (list nil))
        (events nil))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list (list :content chat-agent-test--tool-call-json)
                      '(:content "工具结果已收到"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :on-event (lambda (event) (setq events (append events (list event))))))
      (let ((end (car (last events))))
        (should (eq (plist-get end :status) 'completed))
        (should (string= (plist-get end :content) "工具结果已收到"))
        (should (equal (plist-get end :tool-results) '("echo:hi"))))
      (should (= (car exec-counter) 1))
      (should (= (length (car calls)) 2))
      (let ((followup (car (last (cadr (car calls))))))
        (should (eq (chat-message-role followup) :tool))
        (should (string-match-p "echo:hi" (chat-message-content followup)))))))

(ert-deftest chat-agent-retries-after-parse-error ()
  "Test a malformed tool call attempt triggers a parse error follow-up."
  (let ((calls (list nil))
        (events nil))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "```json\n{\"function_call\":{\"name\":\"demo\"")
                  (:content "修复后的回答"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :on-event (lambda (event) (setq events (append events (list event))))))
      (should (= (length (car calls)) 2))
      (let ((followup (car (last (cadr (car calls))))))
        (should (string-match-p "could not be parsed"
                                (chat-message-content followup))))
      (should (eq (plist-get (car (last events)) :status) 'completed)))))

(ert-deftest chat-agent-stops-at-max-steps ()
  "Test the run stops with reason max-steps when the limit is reached."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (calls (list nil))
        (events nil))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (make-list 3 (lambda ()
                               (list :content chat-agent-test--tool-call-json)))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :max-steps 3
             :on-event (lambda (event) (setq events (append events (list event))))))
      (let ((end (car (last events))))
        (should (eq (plist-get end :status) 'stopped))
        (should (eq (plist-get end :reason) 'max-steps))
        (should (= (plist-get end :steps) 3)))
      (should (= (car exec-counter) 3)))))

(ert-deftest chat-agent-cancel-prevents-further-processing ()
  "Test cancelling a run emits agent-end once and ignores late responses."
  (let ((saved-success nil)
        (events nil)
        run)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (lambda (_model _messages success _error _options)
                 (setq saved-success success)
                 'stub-handle)))
      (setq run (chat-agent-start
                 (list :model 'kimi
                       :messages (list (chat-agent-test--user-message))
                       :on-event (lambda (event) (setq events (append events (list event)))))))
      (should (chat-agent-active-p run))
      (should (chat-agent-cancel run))
      (should-not (chat-agent-active-p run))
      (let ((end (car (last events))))
        (should (eq (plist-get end :type) 'agent-end))
        (should (eq (plist-get end :status) 'cancelled)))
      ;; A late transport callback must be ignored.
      (funcall saved-success '(:content "迟到回答"))
      (should (= (length (cl-remove-if-not
                          (lambda (event) (eq (plist-get event :type) 'agent-end))
                          events))
                 1)))))

(ert-deftest chat-agent-refuses-tool-calls-from-truncated-response ()
  "Test tool calls in a length truncated response are refused, not executed."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (calls (list nil))
        (events nil))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list (list :content chat-agent-test--tool-call-json
                            :finish-reason "length")
                      '(:content "重新发出的回答"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :on-event (lambda (event) (setq events (append events (list event))))))
      (should (= (car exec-counter) 0))
      (should (cl-some (lambda (event)
                         (eq (plist-get event :type) 'truncated))
                       events))
      (let ((end (car (last events))))
        (should (eq (plist-get end :status) 'completed))
        (should (equal (plist-get end :tool-results)
                       (list chat-agent-truncated-tool-result-text))))
      (let ((followup (car (last (cadr (car calls))))))
        (should (eq (chat-message-role followup) :tool))
        (should (string-match-p "truncated"
                                (chat-message-content followup)))))))

(ert-deftest chat-agent-injects-steering-messages ()
  "Test steering messages are appended before the request is sent."
  (let ((calls (list nil))
        (steered nil))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "回答"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :steering-fn (lambda (_run)
                            (unless steered
                              (setq steered t)
                              (list (make-chat-message
                                     :id "steer-1"
                                     :role :user
                                     :content "补充指令"
                                     :timestamp (current-time)))))))
      (let ((sent (caar calls)))
        (should (= (length sent) 2))
        (should (string= (chat-message-content (cadr sent)) "补充指令"))))))

(ert-deftest chat-agent-custom-should-stop-overrides-default ()
  "Test a custom should-stop predicate ends the loop early."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (calls (list nil))
        (events nil))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list (list :content chat-agent-test--tool-call-json))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :should-stop-fn (lambda (_run _processed) t)
             :on-event (lambda (event) (setq events (append events (list event))))))
      (should (= (car exec-counter) 1))
      (should (= (length (car calls)) 1))
      (should (eq (plist-get (car (last events)) :status) 'completed)))))

(ert-deftest chat-agent-default-followup-text-contract ()
  "Test the default follow-up text covers parse errors and tool results."
  (should (string-match-p
           "could not be parsed"
           (chat-agent--default-followup-text
            '(:tool-calls nil :parse-error t))))
  (let ((text (chat-agent--default-followup-text
               (list :tool-calls '((:name "files_read"
                                     :arguments (("path" . "/tmp/x"))))
                     :tool-results (list (make-string 50 ?x))
                     :parse-error nil))))
    (should (string-match-p "files_read" text))
    (should (string-match-p (make-string 50 ?x) text))))

(ert-deftest chat-agent-uses-followup-request-options-after-first-turn ()
  "Test follow-up turns merge the dedicated request options."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (seen-options nil))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (lambda (_model _messages success _error options)
                 (push options seen-options)
                 (funcall success (if (= (length seen-options) 1)
                                      (list :content chat-agent-test--tool-call-json)
                                    '(:content "done")))
                 'stub-handle)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :request-options '(:timeout 60 :temperature 0.7)
             :followup-request-options '(:timeout 300)))
      (should (= (plist-get (car seen-options) :timeout) 300))
      (should (= (plist-get (cadr seen-options) :timeout) 60))
      (should (equal (plist-get (car seen-options) :temperature) 0.7)))))

(ert-deftest chat-agent-executes-native-tool-calls ()
  "Test provider tool_calls are executed and returned as :tool messages."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (calls (list nil))
        (events nil))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list (list :content ""
                            :tool-calls (list (list :id "call-1"
                                                    :name "demo-tool"
                                                    :arguments '(("input" . "hi")))))
                      '(:content "native done"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :on-event (lambda (event) (setq events (append events (list event))))))
      (should (= (car exec-counter) 1))
      (should (= (length (car calls)) 2))
      (let* ((second (cadr (car calls)))
             (assistant (nth 1 second))
             (tool (nth 2 second)))
        (should (eq (chat-message-role assistant) :assistant))
        (should (equal (plist-get (car (chat-message-tool-calls assistant)) :name)
                       "demo-tool"))
        (should (eq (chat-message-role tool) :tool))
        (should (string= (plist-get (chat-message-metadata tool) :tool-call-id)
                         "call-1"))
        (should (string-match-p "echo:hi" (chat-message-content tool))))
      (should (eq (plist-get (car (last events)) :status) 'completed)))))

(ert-deftest chat-agent-steer-and-follow-up-queues ()
  "Test follow-up runs after the agent would otherwise stop."
  (let ((calls (list nil))
        (queued nil)
        run)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "first")
                  (:content "after follow-up"))
                calls)))
      (setq run (chat-agent-start
                 (list :model 'kimi
                       :messages (list (chat-agent-test--user-message))
                       :on-event
                       (lambda (event)
                         (when (and (not queued)
                                    (eq (plist-get event :type) 'response))
                           (setq queued t)
                           (chat-agent-follow-up
                            (plist-get event :run)
                            (make-chat-message
                             :id "follow-1"
                             :role :user
                             :content "continue"
                             :timestamp (current-time))))))))
      (should (chat-agent-run-state-done run))
      (should (= (length (car calls)) 2))
      (should (string= (chat-message-content (car (last (cadr (car calls)))))
                       "continue")))))

(ert-deftest chat-agent-plugin-can-block-tool-calls ()
  "Test before-tool-call hooks can block execution."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (chat-plugin-before-tool-call-functions
         (list (lambda (_run _call)
                 '(:block t :reason "blocked by plugin"))))
        (calls (list nil)))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list (list :content chat-agent-test--tool-call-json)
                      '(:content "blocked noted"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))))
      (should (= (car exec-counter) 0))
      (let ((tool (car (last (cadr (car calls))))))
        (should (eq (chat-message-role tool) :tool))
        (should (string-match-p "blocked by plugin"
                                (chat-message-content tool)))))))

(provide 'test-chat-agent)
;;; test-chat-agent.el ends here
