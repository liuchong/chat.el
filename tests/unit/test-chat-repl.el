;;; test-chat-repl.el --- Persistent REPL contract tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-repl)
(require 'chat-ui)

(defmacro chat-repl-test--isolated (&rest body)
  "Run BODY with isolated REPL, execution, task and event state."
  `(chat-test-with-temp-dir
    (let ((chat-repl-directory (expand-file-name "repl/" temp-dir))
          (chat-execution-directory (expand-file-name "execution/" temp-dir))
          (chat-task-directory (expand-file-name "tasks/" temp-dir))
          (chat-repl--sessions (make-hash-table :test 'equal))
          (chat-repl--selected (make-hash-table :test 'equal))
          (chat-repl--adapters (make-hash-table :test 'eq))
          (chat-execution--records (make-hash-table :test 'equal))
          (chat-execution--backends (make-hash-table :test 'eq))
          (chat-task--registry (make-hash-table :test 'equal))
          (chat-task--loaded-p t)
          (chat-task--scheduling-p nil)
          (chat-event-observer-functions nil)
          (chat-event-blocker-functions nil))
      (chat-repl-install-default-adapters)
      ,@body)))

(ert-deftest chat-repl-registers-shell-and-official-clojure-adapters ()
  "The initial registry has no second Clojure toolchain path."
  (chat-repl-test--isolated
   (should (chat-repl-adapter 'shell))
   (should (chat-repl-adapter 'clojure))
   (should (equal (chat-repl-adapter-command-function
                   (chat-repl-adapter 'clojure))
                  #'chat-repl--clojure-command))
   (should-not (gethash 'lein chat-repl--adapters))))

(ert-deftest chat-repl-initialize-preserves-configured-adapters ()
  "Initialization installs defaults without erasing extension registration."
  (chat-repl-test--isolated
   (let ((custom
          (chat-repl-adapter-create
           :id 'custom :label "Custom"
           :availability-function (lambda () t)
           :command-function (lambda (_token) '("custom"))
           :submit-function (lambda (_session _transaction code) code))))
     (chat-repl-register-adapter custom)
     (chat-repl-initialize)
     (should (eq (chat-repl-adapter 'custom) custom)))))

(ert-deftest chat-repl-parser-uses-framing-across-process-chunks ()
  "A prompt or arbitrary chunk boundary cannot complete a transaction."
  (chat-repl-test--isolated
   (let* ((transaction
           (chat-repl-transaction-create
            :id "tx" :task-id "task" :code "x" :output ""
            :status 'running :parser-state 'waiting-begin :parser-buffer ""))
          (session
           (chat-repl-session-create
            :id "repl" :chat-session-id "chat" :adapter-id 'shell
            :directory temp-dir :generation 1 :status 'busy :token "TOKEN"
            :active-transaction transaction :transactions (list transaction)))
          done fail)
     (setf (chat-repl-transaction-done-function transaction)
           (lambda (value) (setq done value))
           (chat-repl-transaction-fail-function transaction)
           (lambda (value) (setq fail value)))
     (chat-repl--parse-output session "startup> \x1eTOKEN:B:")
     (should-not done)
     (chat-repl--parse-output session "tx\x1f\nforty")
     (should-not done)
     (chat-repl--parse-output session "-two\n\x1eTOKEN:E:tx:0")
     (should-not done)
     (chat-repl--parse-output session "\x1f\n")
     (should (equal done "forty-two"))
     (should-not fail)
     (should (eq (chat-repl-transaction-status transaction) 'completed))
     (should (eq (chat-repl-session-status session) 'idle)))))

(ert-deftest chat-repl-output-is-bounded-while-streaming ()
  "Large output retains a marked tail instead of an unbounded accumulator."
  (chat-repl-test--isolated
   (let* ((chat-repl-output-limit 8)
          (transaction (chat-repl-transaction-create :id "tx" :output ""))
          (session (chat-repl-session-create
                    :id "repl" :chat-session-id "chat" :adapter-id 'shell
                    :generation 1 :status 'busy)))
     (chat-repl--append-output session transaction "012345")
     (chat-repl--append-output session transaction "6789AB")
     (should (equal (chat-repl-transaction-output transaction) "456789AB"))
     (should (chat-repl-transaction-output-truncated-p transaction)))))

(ert-deftest chat-repl-load-interrupts-active-state-without-starting-processes ()
  "Restart reconciliation is durable and has no replay side effect."
  (chat-repl-test--isolated
   (let* ((transaction
           (chat-repl-transaction-create
            :id "tx" :task-id "task" :code "danger" :output ""
            :status 'running :created-at 1 :started-at 2))
          (session
           (chat-repl-session-create
            :id "repl" :chat-session-id "chat" :adapter-id 'shell
            :directory temp-dir :generation 1 :status 'busy
            :execution-id "execution" :created-at 1 :updated-at 2
            :transactions (list transaction)))
          starts)
     (puthash "repl" session chat-repl--sessions)
     (puthash "chat" "repl" chat-repl--selected)
     (chat-repl-save)
     (clrhash chat-repl--sessions)
     (clrhash chat-repl--selected)
     (cl-letf (((symbol-function 'chat-repl--start-process)
                (lambda (&rest _) (cl-incf starts))))
       (chat-repl-load))
     (setq session (chat-repl-get "repl"))
     (should-not starts)
     (should (eq (chat-repl-session-status session) 'interrupted))
     (should (eq (chat-repl-transaction-status
                  (car (chat-repl-session-transactions session)))
                 'interrupted)))))

(ert-deftest chat-repl-work-shelf-projection-is-session-scoped ()
  "One session cannot observe another session's runtime details."
  (chat-repl-test--isolated
   (let ((session
          (chat-repl-session-create
           :id "repl" :chat-session-id "owner" :adapter-id 'shell
           :directory temp-dir :generation 2 :status 'idle
           :transactions nil)))
     (puthash "repl" session chat-repl--sessions)
     (puthash "owner" "repl" chat-repl--selected)
     (should (chat-repl-ui-projection "owner"))
     (should-not (chat-repl-ui-projection "other"))
     (setf (chat-repl-session-status session) 'closed)
     (should-not (chat-repl-ui-projection "owner")))))

(ert-deftest chat-repl-ui-start-claims-input-evaluates-and-close-releases-it ()
  "The chat command exposes one visible, reversible REPL input mode."
  (chat-repl-test--isolated
   (let ((chat-session-auto-save nil)
         (chat-session (chat-session-create "REPL UI" 'test))
         evaluated
         inserted)
     (with-temp-buffer
       (setq-local chat--current-session chat-session)
       (cl-letf (((symbol-function 'chat-repl-adapter-ids)
                  (lambda () '(clojure shell)))
                 ((symbol-function 'chat-repl-start)
                  (lambda (chat adapter directory)
                    (let ((session
                           (chat-repl-session-create
                            :id "repl-ui" :chat-session-id (chat-session-id chat)
                            :adapter-id adapter :directory directory
                            :generation 1 :status 'idle)))
                      (puthash "repl-ui" session chat-repl--sessions)
                      (puthash (chat-session-id chat) "repl-ui"
                               chat-repl--selected)
                      session)))
                 ((symbol-function 'chat-repl-eval)
                  (lambda (_session code &optional _observer)
                    (setq evaluated code)))
                 ((symbol-function 'chat-repl-close)
                  (lambda (session)
                    (setf (chat-repl-session-status session) 'closed)
                    (remhash (chat-repl-session-chat-session-id session)
                             chat-repl--selected)))
                 ((symbol-function 'chat-ui--insert-system-message)
                  (lambda (text) (push text inserted)))
                 ((symbol-function 'chat-ui--render-default-command) #'ignore)
                 ((symbol-function 'chat-ui--render-input-prompt) #'ignore))
         (chat-ui--command-repl "start shell")
         (should (equal (chat-ui-default-command) "repl"))
         (let ((chat-ui--input-was-typed t))
           (chat-ui--command-repl "echo 42"))
         (should (equal evaluated "echo 42"))
         (chat-ui--command-repl "close")
         (should (equal (chat-ui-default-command) chat-ui-baseline-command))
         (should (seq-some (lambda (text) (string-match-p "closed" text))
                           inserted)))))))

(ert-deftest chat-repl-bounds-durable-code-without-truncating-wire-input ()
  "Retention limits never change the program sent to an adapter."
  (chat-repl-test--isolated
   (let* ((chat-repl-code-limit 4)
          (sent nil)
          (session
           (chat-repl-session-create
            :id "repl-wire" :chat-session-id "owner" :adapter-id 'shell
            :directory default-directory :generation 1 :status 'idle))
          (process 'fake-process)
          (code "echo complete payload"))
     (chat-repl-register-adapter
      (chat-repl-adapter-create
       :id 'shell :label "Shell"
       :availability-function (lambda () t)
       :command-function (lambda (_token) '("fake"))
       :submit-function (lambda (_session _transaction value)
                          (setq sent value)
                          value)))
     (cl-letf (((symbol-function 'chat-repl--active-process)
                (lambda (_session) process))
               ((symbol-function 'process-send-string)
                (lambda (_process _wire) t)))
       (let ((transaction
              (chat-repl-transaction-create
               :id "tx" :task-id "task" :code "load"
               :code-truncated-p t :wire-code code :status 'queued)))
         (cl-letf (((symbol-function 'chat-repl-save) #'ignore)
                   ((symbol-function 'chat-repl--emit) #'ignore))
           (chat-repl--begin-transaction
            session transaction #'ignore #'ignore)
           (should (equal sent code))
           (should-not (chat-repl-transaction-wire-code transaction))))))))

(ert-deftest chat-repl-send-failure-atomically-fails-task-and-runtime ()
  "A broken process write cannot leave a durable busy transaction behind."
  (chat-repl-test--isolated
   (let* ((session
           (chat-repl-session-create
            :id "repl-send" :chat-session-id "owner" :adapter-id 'shell
            :directory default-directory :generation 1 :status 'idle))
          (transaction
           (chat-repl-transaction-create
            :id "tx" :task-id "task" :code "echo" :wire-code "echo"
            :status 'queued))
          failed)
     (cl-letf (((symbol-function 'chat-repl--active-process)
                (lambda (_session) 'fake-process))
               ((symbol-function 'process-send-string)
                (lambda (&rest _) (error "wire closed")))
               ((symbol-function 'chat-repl-save) #'ignore)
               ((symbol-function 'chat-repl--emit) #'ignore))
       (chat-repl--begin-transaction
        session transaction #'ignore (lambda (reason) (setq failed reason))))
     (should (string-match-p "wire closed" failed))
     (should (eq (chat-repl-transaction-status transaction) 'failed))
     (should (eq (chat-repl-session-status session) 'failed))
     (should-not (chat-repl-session-active-transaction session)))))

(ert-deftest chat-repl-queue-capacity-fails-before-dropping-live-records ()
  "Backpressure is explicit when every retained transaction is still active."
  (chat-repl-test--isolated
   (let* ((chat-repl-history-limit 1)
          (queued
           (chat-repl-transaction-create
            :id "queued" :task-id "task" :code "one" :status 'queued))
          (session
           (chat-repl-session-create
            :id "repl-full" :chat-session-id "owner" :adapter-id 'shell
            :directory default-directory :generation 1 :status 'idle
            :transactions (list queued))))
     (should-error (chat-repl-eval session "two")
                   :type 'chat-repl-state-error)
     (should (equal (chat-repl-session-transactions session) (list queued))))))

(ert-deftest chat-repl-rendering-uses-a-fence-longer-than-output-runs ()
  "REPL output containing Markdown fences remains one literal code block."
  (let ((rendered (chat-ui--repl-fenced-text "before ``` after")))
    (should (string-prefix-p "````text\n" rendered))
    (should (string-suffix-p "\n````" rendered))))

(provide 'test-chat-repl)
;;; test-chat-repl.el ends here
