;;; test-chat-repl.el --- Real isolated REPL integration tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-repl)

(defmacro chat-repl-integration--isolated (&rest body)
  "Run BODY with isolated durable registries and measured execution."
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
      (chat-execution-initialize)
      (chat-repl-initialize)
      ,@body)))

(defun chat-repl-integration--wait-task (task &optional seconds)
  "Wait up to SECONDS for TASK and return its terminal status."
  (let ((deadline (+ (float-time) (or seconds 20))))
    (while (and (not (chat-task-terminal-p task))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (chat-task-status task)))

(ert-deftest chat-repl-shell-preserves-state-and-closes-process-tree ()
  "Two isolated shell inputs share state and close without a live handle."
  (chat-repl-integration--isolated
   (let ((session nil)
         process)
     (unwind-protect
         (progn
           (setq session (chat-repl-start "chat-shell" 'shell temp-dir)
                 process (chat-repl--active-process session))
           (should (process-live-p process))
           (should (eq (chat-repl-integration--wait-task
                        (chat-repl-eval session "x=41"))
                       'completed))
           (let ((task (chat-repl-eval session "echo $((x + 1))")))
             (should (eq (chat-repl-integration--wait-task task) 'completed))
             (should (string-match-p
                      "42"
                      (chat-task-result task))))
           (let ((first (chat-repl-eval session "printf first"))
                 (second (chat-repl-eval session "printf second")))
             (should (memq (chat-task-status second) '(queued running)))
             (should (eq (chat-repl-integration--wait-task first) 'completed))
             (should (eq (chat-repl-integration--wait-task second) 'completed))
             (should (equal (chat-task-result first) "first"))
             (should (equal (chat-task-result second) "second"))))
       (when session (chat-repl-close session)))
     (should-not (process-live-p process)))))

(ert-deftest chat-repl-shell-close-terminates-descendants ()
  "Closing a REPL kills a child that outlived its framed input."
  (chat-repl-integration--isolated
   (let ((session nil)
         child-pid)
     (unwind-protect
         (progn
           (setq session (chat-repl-start "chat-tree" 'shell temp-dir))
           (let ((task (chat-repl-eval session "sleep 30 & printf $!")))
             (should (eq (chat-repl-integration--wait-task task) 'completed))
             (setq child-pid (string-to-number (chat-task-result task)))
             (should (> child-pid 1))
             (should (process-attributes child-pid)))
           (chat-repl-close session)
           (setq session nil)
           (let ((deadline (+ (float-time) 2)))
             (while (and (process-attributes child-pid)
                         (< (float-time) deadline))
               (sleep-for 0.05)))
           (should-not (process-attributes child-pid)))
       (when session (chat-repl-close session))))))

(ert-deftest chat-repl-shell-interrupt-cancels-task-without-false-failure ()
  "An explicit interrupt has one canceled task and interrupted REPL outcome."
  (chat-repl-integration--isolated
   (let ((session nil))
     (unwind-protect
         (progn
           (setq session (chat-repl-start "chat-interrupt" 'shell temp-dir))
           (let* ((task (chat-repl-eval session "sleep 30"))
                  (transaction
                   (car (last (chat-repl-session-transactions session)))))
             (should (eq (chat-task-status task) 'running))
             (chat-repl-interrupt session "integration interrupt")
             (should (eq (chat-task-status task) 'canceled))
             (should (eq (chat-repl-transaction-status transaction)
                         'interrupted))
             (should (eq (chat-repl-session-status session) 'interrupted))))
       (when session (chat-repl-close session))))))

(ert-deftest chat-repl-shell-close-cancels-queue-before-resource-release ()
  "Closing cannot let a queued input begin between cancellation and teardown."
  (chat-repl-integration--isolated
   (let ((session nil)
         (sentinel-file (expand-file-name "must-not-exist" temp-dir)))
     (unwind-protect
         (progn
           (setq session (chat-repl-start "chat-close-queue" 'shell temp-dir))
           (let ((active (chat-repl-eval session "sleep 30"))
                 (queued
                  (chat-repl-eval
                   session
                   (format "printf leaked > %s"
                           (shell-quote-argument sentinel-file)))))
             (should (eq (chat-task-status active) 'running))
             (should (eq (chat-task-status queued) 'queued))
             (chat-repl-close session)
             (setq session nil)
             (should (eq (chat-task-status active) 'canceled))
             (should (eq (chat-task-status queued) 'canceled))
             (should-not (file-exists-p sentinel-file))))
       (when session (chat-repl-close session))))))

(ert-deftest chat-repl-official-clojure-cli-preserves-definitions ()
  "The official CLI adapter keeps one namespace across isolated inputs."
  (unless (executable-find "clojure")
    (ert-skip "official clojure CLI is unavailable"))
  (chat-repl-integration--isolated
   (let ((session nil)
         process)
     (unwind-protect
         (progn
           (setq session (chat-repl-start "chat-clojure" 'clojure temp-dir)
                 process (chat-repl--active-process session))
           (let ((task (chat-repl-eval session "(def answer 41)")))
             (let ((status (chat-repl-integration--wait-task task 40)))
               (ert-info ((format "REPL task error: %s" (chat-task-error task)))
                 (should (eq status 'completed)))))
           (let ((task (chat-repl-eval session "(inc answer)")))
             (should (eq (chat-repl-integration--wait-task task 40) 'completed))
             (should (string-match-p "42" (chat-task-result task)))))
       (when session (chat-repl-close session)))
     (should-not (process-live-p process)))))

(provide 'test-chat-repl-integration)
;;; test-chat-repl.el ends here
