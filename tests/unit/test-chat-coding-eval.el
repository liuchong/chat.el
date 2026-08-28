;;; test-chat-coding-eval.el --- Coding evaluation tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-coding-eval)

(defconst chat-coding-eval-test-manifest
  (expand-file-name "coding-eval/manifest.json" chat-test-fixtures-dir))

(defmacro chat-coding-eval-test-with-runtime (&rest body)
  "Run BODY with isolated evaluation records and workspaces."
  `(chat-test-with-temp-dir
    (let ((chat-eval-directory (expand-file-name "evals/" temp-dir))
          (chat-eval-auto-save t)
          (chat-coding-eval-workspace-directory
           (expand-file-name "workspaces/" temp-dir))
          (chat-coding-eval-clean-workspaces t))
      ,@body)))

(defun chat-coding-eval-test--wait (predicate &optional seconds)
  "Wait up to SECONDS for PREDICATE in batch tests."
  (let ((deadline (+ (float-time) (or seconds 3))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (funcall predicate)))

(defun chat-coding-eval-test--task (fixture judges &optional allowed timeout)
  "Return a minimal task using FIXTURE and JUDGES."
  (chat-coding-eval-task-create-record
   :schema-version chat-coding-eval-schema-version
   :id "test-task" :revision 1 :category "single-file-fix"
   :language "python" :description "test"
   :fixture-id "test-fixture" :fixture-directory fixture
   :prompt "Apply the requested test change."
   :allowed-paths (or allowed '("sample.py"))
   :timeout-seconds (or timeout 2)
   :judges judges))

(ert-deftest chat-coding-eval-suite-has-fixed-balanced-coverage ()
  "The baseline contains thirty tasks with balanced category coverage."
  (let* ((tasks (chat-coding-eval-load-suite
                 chat-coding-eval-test-manifest))
         (coverage (chat-coding-eval-suite-coverage tasks)))
    (should (= 30 (alist-get 'taskCount coverage)))
    (should (equal '(5 5 5 5 5 5)
                   (mapcar #'cdr (alist-get 'categories coverage))))
    (should (equal '(6 6 6 6 6)
                   (mapcar #'cdr (alist-get 'languages coverage))))
    (dolist (task tasks)
      (let ((left (chat-coding-eval-fixture-digest
                   (chat-coding-eval-task-fixture-directory task)))
            (right (chat-coding-eval-fixture-digest
                    (chat-coding-eval-task-fixture-directory task))))
        (should (= 64 (length left)))
        (should (equal left right))))))

(ert-deftest chat-coding-eval-rejects-unsafe-allowed-and-judge-paths ()
  "Fixture policy rejects traversal before an executor can run."
  (let* ((fixture (expand-file-name "coding-eval/python"
                                    chat-test-fixtures-dir))
         (task (chat-coding-eval-test--task
                fixture '(((type . "no-change") (name . "safe")))
                '("../outside"))))
    (should-error (chat-coding-eval--validate-task task))
    (setf (chat-coding-eval-task-allowed-paths task) '("sample.py")
          (chat-coding-eval-task-judges task)
          '(((type . "file-regexp") (name . "unsafe")
             (path . "../outside") (regexp . "x"))))
    (should-error (chat-coding-eval--validate-task task))))

(ert-deftest chat-coding-eval-read-only-run-is-traced-and-cleaned ()
  "A synchronous fake executor still enters the async result contract."
  (chat-coding-eval-test-with-runtime
   (let* ((task (seq-find
                 (lambda (item)
                   (equal "python-locate"
                          (chat-coding-eval-task-id item)))
                 (chat-coding-eval-load-suite
                  chat-coding-eval-test-manifest)))
          result state)
     (setq state
           (chat-coding-eval-run
            task
            (lambda (_task _workspace done)
              (funcall done 'completed "find_user returns None" '((model . "fake"))))
            :on-complete (lambda (value _state) (setq result value))))
     (should result)
     (should (eq 'passed (chat-eval-result-status result)))
     (should-not (file-exists-p
                  (chat-coding-eval-run-state-workspace state)))
     (should (file-exists-p
              (chat-eval--result-file (chat-eval-result-id result)))))))

(ert-deftest chat-coding-eval-executor-metadata-is-redacted-on-disk ()
  "Provider metadata uses the evaluation privacy boundary."
  (chat-coding-eval-test-with-runtime
   (let* ((task (car (chat-coding-eval-load-suite
                      chat-coding-eval-test-manifest)))
          result)
     (setf (chat-coding-eval-task-judges task)
           '(((type . "no-change") (name . "unchanged"))))
     (chat-coding-eval-run
      task
      (lambda (_task _workspace done)
        (funcall done 'completed "done"
                 '((providerDetail . "token=abcdefghijklmnop"))))
      :on-complete (lambda (value _state) (setq result value)))
     (let ((json (with-temp-buffer
                   (insert-file-contents
                    (chat-eval--result-file (chat-eval-result-id result)))
                   (buffer-string))))
       (should (string-match-p "redacted" json))
       (should-not (string-match-p "abcdefghijklmnop" json))))))

(ert-deftest chat-coding-eval-command-judge-accepts-an-allowed-fix ()
  "An allowed edit is tested by argv without invoking a shell."
  (chat-coding-eval-test-with-runtime
   (let* ((task (seq-find
                 (lambda (item)
                   (equal "python-single-fix"
                          (chat-coding-eval-task-id item)))
                 (chat-coding-eval-load-suite
                  chat-coding-eval-test-manifest)))
          result)
     (chat-coding-eval-run
      task
      (lambda (_task workspace done)
        (let ((file (expand-file-name "sample.py" workspace)))
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (re-search-forward
             "def divide(left, right):\n    return left // right")
            (replace-match
             "def divide(left, right):\n    if right == 0:\n        raise ValueError(\"zero divisor\")\n    return left / right"
             t t)
            (write-region (point-min) (point-max) file nil 'silent)))
        (funcall done 'completed "fixed" nil))
      :on-complete (lambda (value _state) (setq result value)))
     (should (chat-coding-eval-test--wait (lambda () result) 5))
     (should (eq 'passed (chat-eval-result-status result)))
     (should (equal '("sample.py")
                    (alist-get 'changedFiles
                               (chat-eval-result-metadata result)))))))

(ert-deftest chat-coding-eval-fails-closed-on-out-of-scope-change ()
  "Unexpected changed paths fail before untrusted judge commands run."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (task (chat-coding-eval-test--task
                 fixture '(((type . "no-change") (name . "unchanged")))))
          result)
     (chat-coding-eval-run
      task
      (lambda (_task workspace done)
        (write-region "outside" nil
                      (expand-file-name "unexpected.txt" workspace)
                      nil 'silent)
        (funcall done 'completed "done" nil))
      :on-complete (lambda (value _state) (setq result value)))
     (should result)
     (should (eq 'failed (chat-eval-result-status result)))
     (should (equal '("unexpected.txt")
                    (alist-get 'outOfScopeFiles
                               (chat-eval-result-metadata result)))))))

(ert-deftest chat-coding-eval-records-crash-cancel-and-timeout ()
  "Every executor terminal path produces evidence and removes its workspace."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (judges '(((type . "no-change") (name . "unchanged"))))
          (task (chat-coding-eval-test--task fixture judges))
          crash-result cancel-result timeout-result cancel-called)
     (chat-coding-eval-run
      task (lambda (&rest _args) (error "executor crashed"))
      :on-complete (lambda (value _state) (setq crash-result value)))
     (should (eq 'error (chat-eval-result-status crash-result)))
     (let ((state
            (chat-coding-eval-run
             task
             (lambda (_task _workspace _done)
               (lambda () (setq cancel-called t)))
             :on-complete (lambda (value _state) (setq cancel-result value)))))
       (should (chat-coding-eval-cancel state)))
     (should cancel-called)
     (should (eq 'cancelled (chat-eval-result-status cancel-result)))
     (setf (chat-coding-eval-task-timeout-seconds task) 0.03)
     (chat-coding-eval-run
      task (lambda (_task _workspace _done) nil)
      :on-complete (lambda (value _state) (setq timeout-result value)))
     (should (chat-coding-eval-test--wait (lambda () timeout-result)))
     (should (eq 'timed-out (chat-eval-result-status timeout-result)))
     (should-not
      (directory-files chat-coding-eval-workspace-directory nil "test-task-")))))

(ert-deftest chat-coding-eval-command-timeout-kills-the-process ()
  "A stalled judge is terminated and cannot survive workspace cleanup."
  (chat-coding-eval-test-with-runtime
   (let* ((fixture (expand-file-name "coding-eval/python"
                                     chat-test-fixtures-dir))
          (task
           (chat-coding-eval-test--task
            fixture
            '(((type . "command") (name . "stall")
               (command . ["python3" "-c" "import time; time.sleep(1)"])
               (expectedExit . 0) (timeoutSeconds . 0.03)))))
          result state process)
     ;; JSON commands decode as lists; normalize this direct fixture too.
     (setcdr (assq 'command (car (chat-coding-eval-task-judges task)))
             '("python3" "-c" "import time; time.sleep(1)"))
     (setq state
           (chat-coding-eval-run
            task
            (lambda (_task _workspace done)
              (funcall done 'completed "done" nil))
            :on-complete (lambda (value _state) (setq result value))))
     (setq process (chat-coding-eval-run-state-process state))
     (should (chat-coding-eval-test--wait (lambda () result)))
     (should (eq 'timed-out (chat-eval-result-status result)))
     (should-not (process-live-p process))
     (should-not (file-exists-p
                  (chat-coding-eval-run-state-workspace state))))))

(provide 'test-chat-coding-eval)
;;; test-chat-coding-eval.el ends here
