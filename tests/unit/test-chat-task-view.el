;;; test-chat-task-view.el --- Tests for task projections -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-task-view)

(ert-deftest chat-task-view-flattens-parents-before-children ()
  "The native task projection preserves stable parent-child structure."
  (chat-test-with-temp-dir
   (let ((chat-task-directory temp-dir)
         (chat-task--registry (make-hash-table :test 'equal))
         (chat-task--loaded-p nil)
         (chat-task-auto-save nil))
     (chat-task-adopt :id "parent" :kind 'agent :title "Parent"
                      :status 'running)
     (chat-task-adopt :id "child" :parent-id "parent" :kind 'workflow
                      :title "Child" :status 'waiting-approval)
     (let ((items (chat-task-view--tree-items)))
       (should (equal (mapcar (lambda (item)
                               (chat-task-id (car item)))
                             items)
                      '("parent" "child")))
       (should (equal (mapcar #'cdr items) '(0 1)))))))

(ert-deftest chat-task-view-detail-shows-checkpoint-and-outcome ()
  "Task details expose durable recovery and outcome fields."
  (chat-test-with-temp-dir
   (let ((chat-task-directory temp-dir)
         (chat-task--registry (make-hash-table :test 'equal))
         (chat-task--loaded-p nil)
         (chat-task-auto-save nil))
     (chat-task-adopt
      :id "detail" :kind 'workflow :title "Inspect me"
      :status 'needs-attention
      :checkpoint '((stepIndex . 2) (error . "retry"))
      :error "temporary failure")
     (with-temp-buffer
       (chat-task-view-detail-mode)
       (setq chat-task-view-detail-task-id "detail")
       (chat-task-view-detail-refresh)
       (should (string-match-p "Inspect me" (buffer-string)))
       (should (string-match-p "stepIndex" (buffer-string)))
       (should (string-match-p "temporary failure" (buffer-string)))))))

(provide 'test-chat-task-view)
;;; test-chat-task-view.el ends here
