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

(ert-deftest chat-agent-cancelled-result-returns-from-completion-cleanly ()
  "A transport cancellation finishes without falling through or throwing."
  (let ((run (chat-agent--run-create))
        finished)
    (cl-letf (((symbol-function 'chat-agent--finish)
               (lambda (seen status reason)
                 (setq finished (list seen status reason)))))
      (should-not
       (chat-agent--complete-result run nil '(:cancelled t) nil)))
    (should (equal finished (list run 'cancelled nil)))))

(ert-deftest chat-agent-runs-own-isolated-read-sets ()
  "Every foreground or child run starts with an independent read set."
  (let ((calls-a (list nil))
        (calls-b (list nil))
        run-a
        run-b)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport '((:content "done")) calls-a)))
      (setq run-a
            (chat-agent-start
             (list :model 'kimi
                   :messages (list (chat-agent-test--user-message))))))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport '((:content "done")) calls-b)))
      (setq run-b
            (chat-agent-start
             (list :model 'kimi
                   :messages (list (chat-agent-test--user-message))))))
    (let ((read-set-a (chat-agent-run-state-read-set run-a))
          (read-set-b (chat-agent-run-state-read-set run-b)))
      (should (hash-table-p read-set-a))
      (should (hash-table-p read-set-b))
      (should-not (eq read-set-a read-set-b))
      (should (stringp (chat-agent-run-state-run-id run-a)))
      (should-not (equal (chat-agent-run-state-run-id run-a)
                         (chat-agent-run-state-run-id run-b)))
      (puthash "/tmp/only-a" 'observed read-set-a)
      (should-not (gethash "/tmp/only-a" read-set-b)))))

(ert-deftest chat-agent-tracked-run-is-a-durable-foreground-task ()
  "A UI-style run records one terminal task and clears its live marker."
  (chat-test-with-temp-dir
   (let* ((chat-task-directory temp-dir)
          (chat-task--registry (make-hash-table :test 'equal))
          (chat-task--loaded-p nil)
          (chat-task-auto-save t)
          (session (make-chat-session :id "tracked-session"
                                      :name "Tracked run"
                                      :model-id 'kimi))
          run)
     (cl-letf (((symbol-function 'chat-llm-request-async)
                (chat-agent-test--stub-transport
                 '((:content "done")) (list nil))))
       (setq run
             (chat-agent-start
              (list :model 'kimi
                    :messages (list (chat-agent-test--user-message))
                    :session session
                    :track-task t))))
     (let ((task (chat-task-get (chat-agent-run-state-task-id run))))
       (should (eq (chat-task-kind task) 'agent))
       (should (eq (chat-task-status task) 'completed))
       (should (string= (chat-task-result task) "done"))
       (should-not (assoc 'activeTaskId (chat-session-metadata session)))))))

(ert-deftest chat-agent-runtime-task-cancels-the-live-run-once ()
  "Cancelling a foreground task cancels its attached agent run."
  (chat-test-with-temp-dir
   (let* ((chat-task-directory temp-dir)
          (chat-task--registry (make-hash-table :test 'equal))
          (chat-task--loaded-p nil)
          (session (make-chat-session :id "cancel-session"
                                      :name "Cancelable run"
                                      :model-id 'kimi))
          run)
     (cl-letf (((symbol-function 'chat-llm-request-async)
                (chat-agent-test--stub-transport nil (list nil))))
       (setq run
             (chat-agent-start
              (list :model 'kimi
                    :messages (list (chat-agent-test--user-message))
                    :session session
                    :track-task t))))
     (chat-task-cancel (chat-agent-run-state-task-id run) "stop")
     (should (chat-agent-run-state-done run))
     (should (eq (chat-agent-run-state-status run) 'cancelled))
     (should (eq (chat-task-status
                  (chat-task-get (chat-agent-run-state-task-id run)))
                 'canceled)))))

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
        ;; Introduced by a marker saying when it arrived: on the wire only
        ;; role and content travel, so an injected message that says
        ;; nothing about itself is indistinguishable from one the user sent
        ;; before the run began.
        (should (string-match-p "^\\[arrived while you were working · "
                                (chat-message-content (cadr sent))))
        (should (string-match-p "^补充指令$"
                                (chat-message-content (cadr sent))))))))

(ert-deftest chat-agent-steering-marks-which-input-is-which ()
  "Several messages injected at once say how many there were and in
what order.  Three adjacent user turns with nothing to tell them apart
left the model unable to say which was the correction."
  (let ((calls (list nil))
        (steered nil))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport '((:content "回答")) calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :steering-fn
             (lambda (_run)
               (unless steered
                 (setq steered t)
                 (list (make-chat-message :id "s1" :role :user
                                          :content "first"
                                          :timestamp (current-time))
                       (make-chat-message :id "s2" :role :user
                                          :content "second"
                                          :timestamp (current-time))))))))
    (let ((sent (caar calls)))
      (should (= 3 (length sent)))
      (should (string-match-p "^\\[input 1 of 2 · "
                              (chat-message-content (nth 1 sent))))
      (should (string-match-p "^\\[input 2 of 2 · "
                              (chat-message-content (nth 2 sent)))))))

(ert-deftest chat-agent-steering-leaves-the-session-copy-unmarked ()
  "The marker is on the wire, not on the message the user can see.
The same struct is in the session and on screen, where an explanation of
when it arrived is noise."
  (let ((calls (list nil))
        (steered nil)
        (original (make-chat-message :id "s1" :role :user
                                    :content "补充"
                                    :timestamp (current-time))))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport '((:content "回答")) calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :steering-fn (lambda (_run)
                            (unless steered
                              (setq steered t)
                              (list original))))))
    (should (string= "补充" (chat-message-content original)))))

(ert-deftest chat-agent-steering-gives-the-budget-back ()
  "A message arriving mid-run gets as many steps as the first one did.
Steering used to spend the budget rather than bring any: six of eight
steps spent on the question left the correction two."
  (let ((run (chat-agent--run-create :max-steps 8 :step-budget 8 :step 5)))
    (chat-agent-steer run (make-chat-message :id "s1" :role :user
                                             :content "改一下"))
    (should (= 13 (chat-agent-run-state-max-steps run)))))

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

(ert-deftest chat-agent-transform-context-runs-before-dispatch ()
  "Test per-step context transforms rewrite messages before transport."
  (let ((calls (list nil)))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "ok"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :transform-context-fn
             (lambda (_run messages)
               (append messages
                       (list (make-chat-message
                              :id "context-1"
                              :role :system
                              :content "transformed"
                              :timestamp (current-time)))))))
      (let ((sent (caar calls)))
        (should (= (length sent) 2))
        (should (string= (chat-message-content (car (last sent)))
                         "transformed"))))))

(ert-deftest chat-agent-prepare-next-turn-appends-before-continuation ()
  "Test prepare-next-turn can append context before continued tool turns."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (calls (list nil)))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list (list :content chat-agent-test--tool-call-json)
                      '(:content "done"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :prepare-next-turn-fn
             (lambda (_run processed)
               (when (plist-get processed :tool-calls)
                 (list (make-chat-message
                        :id "prepared-1"
                        :role :system
                        :content "prepared context"
                        :timestamp (current-time)))))))
      (let ((second (cadr (car calls))))
        (should (string= (chat-message-content (car (last second)))
                         "prepared context"))))))

(ert-deftest chat-agent-lifo-queue-mode-delivers-newest-steering-first ()
  "Test LIFO queue mode changes steering delivery order."
  (let ((calls (list nil))
        saved-success
        run)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (lambda (_model messages success _error _options)
                 (setcar calls (append (car calls) (list messages)))
                 (setq saved-success success)
                 'stub-handle)))
      (setq run
            (chat-agent-start
             (list :model 'kimi
                   :messages (list (chat-agent-test--user-message))
                   :queue-mode 'lifo)))
      (chat-agent-steer
       run
       (make-chat-message :id "steer-a" :role :user :content "first"))
      (chat-agent-steer
       run
       (make-chat-message :id "steer-b" :role :user :content "second"))
      (funcall saved-success '(:content "initial"))
      (let ((second-request (cadr (car calls))))
        ;; Matched rather than compared: each injected message now carries
        ;; a marker saying when it arrived and where it sat in the batch.
        (should (string-match-p "^second$"
                                (chat-message-content (nth 2 second-request))))
        (should (string-match-p "^first$"
                                (chat-message-content (nth 3 second-request))))
        (should (string-match-p "input 1 of 2"
                                (chat-message-content (nth 2 second-request))))
        (should (string-match-p "input 2 of 2"
                                (chat-message-content
                                 (nth 3 second-request))))))))

(ert-deftest chat-agent-cancel-runs-registered-cancel-functions ()
  "Test cancellation propagates through registered callbacks."
  (let ((saved-success nil)
        (cancelled nil)
        run)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (lambda (_model _messages success _error _options)
                 (setq saved-success success)
                 'stub-handle)))
      (setq run (chat-agent-start
                 (list :model 'kimi
                       :messages (list (chat-agent-test--user-message)))))
      (chat-agent-add-cancel-function
       run
       (lambda (_run) (setq cancelled t)))
      (should (chat-agent-cancel run))
      (should cancelled)
      (funcall saved-success '(:content "late"))
      (should (eq (chat-agent-run-state-status run) 'cancelled)))))

(ert-deftest chat-agent-cancelled-tool-batch-stops-before-next-tool ()
  "Test cancellation after one tool prevents later tools from running."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (first-count 0)
        (second-count 0)
        (calls (list nil))
        run)
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'first-tool
      :name "First Tool"
      :description "First"
      :language 'elisp
      :compiled-function (lambda (&rest _)
                           (setq first-count (1+ first-count))
                           "first")
      :is-active t
      :usage-count 0))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'second-tool
      :name "Second Tool"
      :description "Second"
      :language 'elisp
      :compiled-function (lambda (&rest _)
                           (setq second-count (1+ second-count))
                           "second")
      :is-active t
      :usage-count 0))
    (let ((chat-plugin-after-tool-call-functions
           (list (lambda (active-run _call _result)
                   (chat-agent-cancel active-run))))
          (responses
           (list (list :content ""
                       :tool-calls
                       (list (list :id "call-1"
                                   :name "first-tool"
                                   :arguments nil)
                             (list :id "call-2"
                                   :name "second-tool"
                                   :arguments nil))))))
      (cl-letf (((symbol-function 'chat-llm-request-async)
                 (chat-agent-test--stub-transport
                  responses
                  calls)))
        (setq run
              (chat-agent-start
               (list :model 'kimi
                     :messages (list (chat-agent-test--user-message)))))))
    (should (= first-count 1))
    (should (= second-count 0))
    (should (eq (chat-agent-run-state-status run) 'cancelled))))

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

(ert-deftest chat-agent-no-tool-steer-runs-before-default-stop ()
  "Test mid-run steering continues even when the current turn has no tools."
  (let ((calls (list nil))
        (queued nil)
        run)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "first")
                  (:content "after steer"))
                calls)))
      (setq
       run
       (chat-agent-start
        (list
         :model 'kimi
         :messages (list (chat-agent-test--user-message))
         :on-event
         (lambda (event)
           (when (and (not queued)
                      (eq (plist-get event :type) 'response))
             (setq queued t)
             (chat-agent-steer
              (plist-get event :run)
              (make-chat-message
               :id "steer-2"
               :role :user
               :content "new constraint"
               :timestamp (current-time))))))))
      (should (chat-agent-run-state-done run))
      (should (= (length (car calls)) 2))
      (should (string-match-p
               "^new constraint$"
               (chat-message-content (car (last (cadr (car calls))))))))))

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

(ert-deftest chat-agent-scheduler-overlaps-reads-and-preserves-result-order ()
  "Test independent async reads overlap while results keep provider order."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        callbacks
        (transport-calls (list nil))
        run)
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'async-read
      :name "Async Read"
      :language 'elisp
      :parameters '((:name "key" :type "string" :required t))
      :effects '(read)
      :resource-function
      (lambda (call)
        (list (list :resource
                    (cdr (assoc "key" (plist-get call :arguments)))
                    :mode 'read)))
      :async-function
      (lambda (argv success _error)
        (push (cons (car argv) success) callbacks)
        #'ignore)
      :is-active t
      :usage-count 0))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list
                 (list :content ""
                       :tool-calls
                       '((:id "read-1" :name "async-read"
                          :arguments (("key" . "one")))
                         (:id "read-2" :name "async-read"
                          :arguments (("key" . "two")))))
                 '(:content "done"))
                transport-calls)))
      (setq run
            (chat-agent-start
             (list :model 'kimi
                   :messages (list (chat-agent-test--user-message)))))
      (should (= (length callbacks) 2))
      (funcall (cdr (assoc "two" callbacks)) "second")
      (should-not (chat-agent-run-state-done run))
      (funcall (cdr (assoc "one" callbacks)) "first")
      (should (chat-agent-run-state-done run))
      (should (equal (chat-agent-run-state-tool-results run)
                     '("first" "second"))))))

(ert-deftest chat-agent-scheduler-serializes-write-effects ()
  "Test async writes never overlap even when their targets differ."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (chat-approval-enabled nil)
        callbacks
        (transport-calls (list nil)))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'async-write
      :name "Async Write"
      :language 'elisp
      :parameters '((:name "key" :type "string" :required t))
      :effects '(write)
      :async-function
      (lambda (argv success _error)
        (setq callbacks
              (append callbacks (list (cons (car argv) success))))
        #'ignore)
      :is-active t
      :usage-count 0))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list
                 (list :content ""
                       :tool-calls
                       '((:id "write-1" :name "async-write"
                          :arguments (("key" . "one")))
                         (:id "write-2" :name "async-write"
                          :arguments (("key" . "two")))))
                 '(:content "done"))
                transport-calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))))
      (should (equal (mapcar #'car callbacks) '("one")))
      (funcall (cdr (car callbacks)) "first")
      (should (equal (mapcar #'car callbacks) '("one" "two")))
      (funcall (cdr (cadr callbacks)) "second"))))

(ert-deftest chat-agent-pre-tool-policy-blocks-execution-and-returns-a-result ()
  "A runtime refusal is fed back to the model without invoking the tool."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (chat-event-blocking-types '(pre-tool))
        (chat-event-blocker-functions
         (list (lambda (event)
                 (when (eq (chat-event-type event) 'pre-tool)
                   '(:decision block :reason "test policy refused")))))
        (exec-counter (list 0))
        (calls (list nil))
        run)
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list (list :content chat-agent-test--tool-call-json)
                      '(:content "used another route"))
                calls)))
      (setq run
            (chat-agent-start
             (list :model 'kimi
                   :messages (list (chat-agent-test--user-message))))))
    (should (= 0 (car exec-counter)))
    (should (equal '("test policy refused")
                   (chat-agent-run-state-tool-results run)))
    (should (equal "used another route"
                   (chat-agent-run-state-content run)))))

(ert-deftest chat-agent-policy-modification-recomputes-resource-conflicts ()
  "A modified call is scheduled by its new resources, not stale ones."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (chat-event-blocking-types '(pre-tool))
        (chat-event-blocker-functions
         (list
          (lambda (event)
            (let ((call (chat-event-subject event)))
              (when (equal (plist-get call :id) "read-1")
                (list :decision 'modify
                      :subject
                      (plist-put (copy-tree call) :arguments
                                 '(("key" . "shared")))))))))
        callbacks
        (transport-calls (list nil)))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'async-read :name "Async Read" :language 'elisp
      :parameters '((:name "key" :type "string" :required t))
      :effects '(read)
      :resource-function
      (lambda (call)
        (list (list :resource
                    (cdr (assoc "key" (plist-get call :arguments)))
                    :mode 'write)))
      :async-function
      (lambda (argv success _error)
        (setq callbacks (append callbacks (list (cons (car argv) success))))
        #'ignore)
      :is-active t :usage-count 0))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list
                 (list :content ""
                       :tool-calls
                       '((:id "read-1" :name "async-read"
                          :arguments (("key" . "one")))
                         (:id "read-2" :name "async-read"
                          :arguments (("key" . "shared")))))
                 '(:content "done"))
                transport-calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message)))))
    (should (equal (mapcar #'car callbacks) '("shared")))
    (funcall (cdr (car callbacks)) "first")
    (should (equal (mapcar #'car callbacks) '("shared" "shared")))
    (funcall (cdr (cadr callbacks)) "second")))

(ert-deftest chat-agent-cancellation-propagates-to-async-tools ()
  "Test cancelling a run invokes every active async tool handle."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (cancel-count 0)
        (transport-calls (list nil))
        run)
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'cancellable-read
      :name "Cancellable Read"
      :language 'elisp
      :parameters '((:name "key" :type "string" :required t))
      :effects '(read)
      :resource-function
      (lambda (call)
        (list (list :resource
                    (cdr (assoc "key" (plist-get call :arguments)))
                    :mode 'read)))
      :async-function
      (lambda (_argv _success _error)
        (lambda () (cl-incf cancel-count)))
      :is-active t
      :usage-count 0))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list
                 (list :content ""
                       :tool-calls
                       '((:id "cancel-1" :name "cancellable-read"
                          :arguments (("key" . "one")))
                         (:id "cancel-2" :name "cancellable-read"
                          :arguments (("key" . "two"))))))
                transport-calls)))
      (setq run
            (chat-agent-start
             (list :model 'kimi
                   :messages (list (chat-agent-test--user-message)))))
      (should (chat-agent-cancel run))
      (should (= cancel-count 2))
      (should (eq (chat-agent-run-state-status run) 'cancelled)))))

;; ------------------------------------------------------------------
;; Step budget reaching the request
;; ------------------------------------------------------------------

(defun chat-agent-test--capturing-transport (responses calls options)
  "Like `chat-agent-test--stub-transport' but also record request options.
RESPONSES are served in order, CALLS collects messages in its car and
OPTIONS collects the options plist of every request in its car."
  (let ((remaining responses))
    (lambda (_model messages success _error request-options)
      (setcar calls (append (car calls) (list messages)))
      (setcar options (append (car options) (list request-options)))
      (let ((next (pop remaining)))
        (when (functionp next)
          (setq next (funcall next)))
        (when next
          (funcall success next)))
      'stub-handle)))

(defun chat-agent-test--budget-notes (messages)
  "Return the budget reminders present in MESSAGES."
  (cl-remove-if-not
   (lambda (message)
     (string-match-p "\\[step budget\\]" (or (chat-message-content message) "")))
   messages))

(ert-deftest chat-agent-says-nothing-about-a-budget-with-room-to-spare ()
  "No reminder is spent on a step that has plenty of budget left."
  (let ((calls (list nil))
        (chat-agent-budget-disclosure 'nearing))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "done" :raw-request "r" :raw-response "s"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :max-steps 300
             :on-event #'ignore))
      (should-not (chat-agent-test--budget-notes (car (car calls)))))))

(ert-deftest chat-agent-appends-the-wrap-up-instruction-on-the-final-step ()
  "The last allowed step is told to answer, and told it at the end.

Placing it last is deliberate: a short instruction buried mid-context is
the one the model skips."
  (let ((calls (list nil)))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "done" :raw-request "r" :raw-response "s"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :max-steps 1
             :on-event #'ignore))
      (let* ((request (car (car calls)))
             (notes (chat-agent-test--budget-notes request)))
        (should (equal (length notes) 1))
        (should (string-match-p "Final step (1 of 1)"
                                (chat-message-content (car notes))))
        (should (eq (car (last request)) (car notes)))))))

(ert-deftest chat-agent-withdraws-tools-on-the-final-step ()
  "Tools are not advertised on the step that has to produce an answer.

Asking a model to stop calling tools is far less reliable than giving it
nothing to call."
  (let ((calls (list nil))
        (options (list nil)))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--capturing-transport
                '((:content "done" :raw-request "r" :raw-response "s"))
                calls options))
              ((symbol-function 'chat-tool-caller-provider-tools)
               (lambda () '((:name "demo")))))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :max-steps 1
             :on-event #'ignore))
      (should-not (plist-get (car (car options)) :tools)))))

(ert-deftest chat-agent-advertises-tools-while-budget-remains ()
  "A step with budget left still gets its tools."
  (let ((calls (list nil))
        (options (list nil)))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--capturing-transport
                '((:content "done" :raw-request "r" :raw-response "s"))
                calls options))
              ((symbol-function 'chat-tool-caller-provider-tools)
               (lambda () '((:name "demo")))))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :max-steps 10
             :on-event #'ignore))
      (should (plist-get (car (car options)) :tools)))))

(ert-deftest chat-agent-reminder-does-not-persist-into-the-transcript ()
  "A reminder describes one step and must not accumulate in the run.

Storing it would repeat a stale count in every later request and leave
budget chatter in the saved history."
  (let ((calls (list nil))
        run)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "done" :raw-request "r" :raw-response "s"))
                calls)))
      (setq run (chat-agent-start
                 (list :model 'kimi
                       :messages (list (chat-agent-test--user-message))
                       :max-steps 1
                       :on-event #'ignore)))
      (should (chat-agent-test--budget-notes (car (car calls))))
      (should-not (chat-agent-test--budget-notes
                   (chat-agent-run-state-messages run))))))

(ert-deftest chat-agent-runs-with-an-unlimited-budget ()
  "An unlimited ceiling is a symbol, and the loop must not compare it as a number."
  (let ((calls (list nil))
        (events nil))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "done" :raw-request "r" :raw-response "s"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :max-steps 'unlimited
             :on-event (lambda (event) (setq events (append events (list event))))))
      (let ((end (car (last events))))
        (should (eq (plist-get end :status) 'completed))))))

;; ------------------------------------------------------------------
;; Stamping the record
;; ------------------------------------------------------------------
;;
;; The stamping API existed and only tests called it.  The loop built its
;; messages plain, so a multi-round run reached disk as a flat list and the
;; display had to infer turn, step and kind from roles -- which cannot tell
;; an intermediate step from a final answer.

(defun chat-agent-test--appended (events)
  "Return the messages EVENTS appended, in order."
  (delq nil (mapcar (lambda (event)
                      (and (eq (plist-get event :type) 'message-appended)
                           (plist-get event :message)))
                    events)))

(ert-deftest chat-agent-stamps-a-final-answer-as-final ()
  "A reply with no tool calls ends the run, so it is the answer."
  (let ((calls (list nil))
        (events nil))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "最终回答" :raw-request "r" :raw-response "s"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :on-event (lambda (event) (setq events (append events (list event))))))
      (let ((message (car (chat-agent-test--appended events))))
        (should message)
        (should (eq (chat-transcript-category message) 'ai-final))
        (should (= (chat-transcript-step message) 1))
        (should (chat-message-timestamp message))))))

(ert-deftest chat-agent-stamps-a-step-that-calls-tools-as-progress ()
  "A reply carrying tool calls is a step of the turn, not its answer."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (exec-counter (list 0))
        (calls (list nil))
        (events nil))
    (chat-agent-test--register-demo-tool exec-counter)
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                (list (list :content chat-agent-test--tool-call-json
                            :raw-request "r" :raw-response "s")
                      (list :content "最终回答"
                            :raw-request "r2" :raw-response "s2"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :on-event (lambda (event) (setq events (append events (list event))))))
      (let* ((messages (chat-agent-test--appended events))
             (first-step (car messages))
             (tool-message (seq-find (lambda (m)
                                       (eq (chat-message-role m) :tool))
                                     messages))
             (answer (car (last messages))))
        (should (eq (chat-transcript-category first-step) 'ai-progress))
        (should (eq (chat-transcript-work first-step) 'message))
        (should tool-message)
        (should (eq (chat-transcript-category tool-message) 'ai-progress))
        (should (eq (chat-transcript-work tool-message) 'tool-result))
        (should (eq (chat-transcript-category answer) 'ai-final))
        ;; Two requests, so two steps, and they are numbered apart.
        (should (= (chat-transcript-step first-step) 1))
        (should (= (chat-transcript-step answer) 2))))))

(ert-deftest chat-agent-keeps-one-turn-number-for-the-whole-run ()
  "Steering adds a user message mid-run; the turn must not advance.

The number is counted from the session's user messages, so recounting
after a steer would file the rest of this turn under the next one."
  (let* ((session (chat-session-create "stamp" 'kimi))
         (run (chat-agent--run-create :session session)))
    (chat-session-add-message
     session (make-chat-message :id "u1" :role :user :content "one"
                                :timestamp (current-time)))
    (should (= (chat-agent--turn-number run) 1))
    (chat-session-add-message
     session (make-chat-message :id "u2" :role :user :content "steered"
                                :timestamp (current-time)))
    (should (= (chat-agent--turn-number run) 1))))

(ert-deftest chat-agent-numbers-the-second-turn-second ()
  "A fresh run over a session with one exchange answers turn two."
  (let ((session (chat-session-create "stamp" 'kimi)))
    (dolist (id '("u1" "u2"))
      (chat-session-add-message
       session (make-chat-message :id id :role :user :content id
                                  :timestamp (current-time))))
    (should (= (chat-agent--turn-number
                (chat-agent--run-create :session session))
               2))))

(ert-deftest chat-agent-puts-reasoning-on-the-step-that-produced-it ()
  "Reasoning belongs to its step, so no request path can send it back."
  (let ((calls (list nil))
        (events nil))
    (cl-letf (((symbol-function 'chat-llm-request-async)
               (chat-agent-test--stub-transport
                '((:content "答案" :reasoning "先想一想"
                            :raw-request "r" :raw-response "s"))
                calls)))
      (chat-agent-start
       (list :model 'kimi
             :messages (list (chat-agent-test--user-message))
             :on-event (lambda (event) (setq events (append events (list event))))))
      (let ((message (car (chat-agent-test--appended events))))
        (should (equal (chat-transcript-reasoning message) "先想一想"))
        ;; On the metadata, not in the content the next request would carry.
        (should (equal (chat-message-content message) "答案"))))))

;;; Stream accumulation

(defun chat-agent-test--publish-all (pieces)
  "Feed PIECES through an accumulator, returning (DELTAS . ALL)."
  (let ((text (chat-agent--stream-text-create))
        (deltas nil))
    (dolist (piece pieces)
      (when (chat-agent--stream-add text piece)
        (push (car (chat-agent--stream-publish text)) deltas)))
    ;; The tail that never reached the threshold, which the end of a run
    ;; flushes and which the deltas would otherwise be missing.
    (let ((tail (car (chat-agent--stream-publish text))))
      (unless (string-empty-p tail)
        (push tail deltas)))
    (cons (nreverse deltas) (chat-agent-stream-text-published text))))

(ert-deftest chat-agent-a-held-back-piece-still-arrives ()
  "Holding pieces back is only allowed if none of them are lost.

The accumulator publishes less often as a reply grows, so the reply that
stops arriving before the next publication is the one that would silently
lose its tail."
  (let ((chat-agent-stream-publish-fraction 8)
        (text (chat-agent--stream-text-create)))
    ;; Long enough that the last pieces cannot reach the threshold.
    (dotimes (_ 400)
      (when (chat-agent--stream-add text "0123456789")
        (chat-agent--stream-publish text)))
    (should (equal (chat-agent--stream-all text)
                   (mapconcat #'identity (make-list 400 "0123456789") "")))))

(ert-deftest chat-agent-a-short-reply-publishes-every-piece ()
  "Backing off must not cost a normal-length reply its smooth arrival."
  (let* ((chat-agent-stream-publish-fraction 8)
         (pieces (make-list 4 "word "))
         (published (chat-agent-test--publish-all pieces)))
    (should (equal (car published) pieces))
    (should (equal (cdr published) "word word word word "))))

(ert-deftest chat-agent-a-long-reply-is-not-copied-once-per-piece ()
  "The reply that cost 165 times its own size to accumulate.

Measured on the longest reply in a real log -- 340 pieces, 321KB -- the
`(concat all piece)' accumulator allocated 52MB, half a collection
threshold spent on one reply.  Publishing has to fall well short of once
per piece for that to stop being true."
  (let* ((chat-agent-stream-publish-fraction 8)
         (pieces (make-list 340 (make-string 967 ?x)))
         (published (chat-agent-test--publish-all pieces)))
    (should (< (length (car published)) 60))
    ;; Fewer, larger steps, carrying exactly what arrived.
    (should (equal (mapconcat #'identity (car published) "")
                   (cdr published)))
    (should (= (length (cdr published)) (* 340 967)))))

(ert-deftest chat-agent-publishing-every-piece-remains-available ()
  "The back-off is a default, not a decision taken away from the reader."
  (let* ((chat-agent-stream-publish-fraction 0)
         (pieces (make-list 50 "0123456789"))
         (published (chat-agent-test--publish-all pieces)))
    (should (= (length (car published)) 50))))

(ert-deftest chat-agent-checkpoint-ownership-requires-tool-success ()
  "Denied results never claim file ownership; successful results do."
  (dolist (case '(("Denied: policy refused" . 0)
                  ("written" . 1)))
    (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
          (session (make-chat-session :id "checkpoint-agent"
                                      :name "Checkpoint agent"
                                      :model-id 'kimi))
          (calls (list nil))
          (before-count 0)
          (complete-count 0)
          (tool-result (car case)))
      (chat-agent-test--register-demo-tool (list 0))
      (cl-letf (((symbol-function 'chat-llm-request-async)
                 (chat-agent-test--stub-transport
                  (list (list :content chat-agent-test--tool-call-json)
                        '(:content "done"))
                  calls))
                ((symbol-function 'chat-checkpoint-before-tool)
                 (lambda (&rest _args) (cl-incf before-count)))
                ((symbol-function 'chat-checkpoint-complete-tool)
                 (lambda (&rest _args) (cl-incf complete-count)))
                ((symbol-function 'chat-tool-caller-execute-async)
                 (lambda (_call _session _observer success _error &optional _context)
                   (funcall success tool-result)
                   'done)))
        (chat-agent-start
         (list :model 'kimi
               :session session
               :messages (list (chat-agent-test--user-message)))))
      (should (= before-count 1))
      (should (= complete-count (cdr case))))))

(provide 'test-chat-agent)
;;; test-chat-agent.el ends here
