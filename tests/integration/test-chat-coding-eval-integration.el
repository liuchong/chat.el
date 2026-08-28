;;; test-chat-coding-eval-integration.el --- Coding eval integration -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-coding-eval)

(ert-deftest chat-coding-eval-integration-all-fixtures-repeat-cleanly ()
  "Every baseline task can repeat setup, deterministic judging and cleanup."
  (chat-test-with-temp-dir
   (let* ((chat-eval-auto-save nil)
          (chat-coding-eval-workspace-directory
           (expand-file-name "coding-workspaces/" temp-dir))
          (manifest (expand-file-name "coding-eval/manifest.json"
                                      chat-test-fixtures-dir))
          (tasks
           (mapcar
            (lambda (task)
              (let ((copy (copy-chat-coding-eval-task task)))
                (setf (chat-coding-eval-task-judges copy)
                      '(((type . "no-change") (name . "fixture-unchanged"))))
                copy))
            (chat-coding-eval-load-suite manifest)))
          results completed suite)
     (setq suite
           (chat-coding-eval-run-suite
      tasks
      (lambda (_task _workspace done)
        (funcall done 'completed "fixture inspected" '((executor . "fixed"))))
      :repetitions 2
      :on-complete
      (lambda (values _state)
        (setq results values completed t))))
     (let ((deadline (+ (float-time) 60)))
       (while (and (not completed) (< (float-time) deadline))
         (accept-process-output nil 0.01)))
     (ert-info ((format "pending=%d results=%d current=%S"
                        (length (chat-coding-eval-suite-state-pending suite))
                        (length (chat-coding-eval-suite-state-results suite))
                        (and (chat-coding-eval-suite-state-current suite)
                             (chat-coding-eval-task-id
                              (chat-coding-eval-run-state-task
                               (chat-coding-eval-suite-state-current suite))))))
       (should completed))
     (should (= 60 (length results)))
     (should (= 30 (cl-count
                    1 results
                    :key (lambda (result)
                           (alist-get 'repetition
                                      (chat-eval-result-metadata result))))))
     (should (= 30 (cl-count
                    2 results
                    :key (lambda (result)
                           (alist-get 'repetition
                                      (chat-eval-result-metadata result))))))
     (should (seq-every-p
              (lambda (result)
                (and (eq 'passed (chat-eval-result-status result))
                     (= 40 (length
                            (alist-get 'fixtureRevision
                                       (chat-eval-result-metadata result))))))
              results))
     (let ((large-results
            (seq-filter
             (lambda (result)
               (equal "python-locate"
                      (alist-get 'taskId
                                 (chat-eval-result-metadata result))))
             results)))
       (should (= 2 (length large-results)))
       (should
        (seq-every-p
         (lambda (result)
           (let ((metadata (chat-eval-result-metadata result)))
             (and (= 10001 (alist-get 'fixtureFileCount metadata))
                  (= 10000 (alist-get 'fixtureIndexedFileCount metadata))
                  (= 64 (length
                         (alist-get 'fixtureGeneratorDigest metadata))))))
         large-results)))
     (should-not
      (directory-files chat-coding-eval-workspace-directory nil "-[[:alnum:]]+\\'")))))

(provide 'test-chat-coding-eval-integration)
;;; test-chat-coding-eval-integration.el ends here
