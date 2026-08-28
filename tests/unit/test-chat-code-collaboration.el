;;; test-chat-code-collaboration.el --- Coding collaboration tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-code-collaboration)

(defun chat-code-collaboration-test--git (root &rest args)
  "Run Git ARGS in ROOT for test setup."
  (with-temp-buffer
    (let ((exit (apply #'process-file "git" nil t nil "-C" root args)))
      (unless (zerop exit) (error "%s" (buffer-string)))
      (string-trim (buffer-string)))))

(defun chat-code-collaboration-test--repo (root)
  "Create a two-file committed repository at ROOT."
  (chat-code-collaboration-test--git root "init" "-q")
  (chat-code-collaboration-test--git root "config" "user.name" "Collab Test")
  (chat-code-collaboration-test--git root "config" "user.email"
                                    "collab@example.invalid")
  (with-temp-file (expand-file-name "a.txt" root) (insert "a0\n"))
  (with-temp-file (expand-file-name "b.txt" root) (insert "b0\n"))
  (chat-code-collaboration-test--git root "add" ".")
  (chat-code-collaboration-test--git root "commit" "-qm" "base"))

(defmacro chat-code-collaboration-test--isolated (&rest body)
  "Run BODY with isolated durable collaboration registries."
  (declare (indent 0) (debug t))
  `(let ((chat-task-directory (expand-file-name "tasks/" chat-state-dir))
         (chat-task--registry (make-hash-table :test 'equal))
         (chat-task--loaded-p t)
         (chat-task-auto-save nil)
         (chat-task--scheduling-p nil)
         (chat-workspace-directory (expand-file-name "workspaces/" chat-state-dir))
         (chat-worktree-directory (expand-file-name "worktrees/" chat-state-dir))
         (chat-workspace--registry (make-hash-table :test 'equal))
         (chat-code-collaboration--children (make-hash-table :test 'equal))
         (chat-event-observer-functions nil)
         (chat-event-blocker-functions nil))
     ,@body))

(defun chat-code-collaboration-test--prepared-child
    (parent root path replacement)
  "Return completed child owning PATH with REPLACEMENT content."
  (let* ((child (chat-code-collaboration-declare
                 parent (format "Edit %s" path) (list path)))
         (child-session (chat-session-create "Child" 'test-model))
         (workspace (chat-workspace-enable-worktree
                     child-session root
                     :revision (chat-code-child-base-revision child))))
    (with-temp-file (expand-file-name path (chat-workspace-path workspace))
      (insert replacement))
    (setf (chat-code-child-child-session child) child-session
          (chat-code-child-workspace child) workspace
          (chat-code-child-status child) 'completed
          (chat-code-child-changed-files child) (list path)
          (chat-code-child-summary child) "bounded child summary")
    child))

(ert-deftest chat-code-collaboration-path-locks-are-hierarchical ()
  "Parent and descendant write scopes conflict; siblings remain parallel."
  (should
   (chat-task-resources-conflict-p
    '((:key "path:/repo/src" :mode write))
    '((:key "path:/repo/src/lib/a.el" :mode write))))
  (should-not
   (chat-task-resources-conflict-p
    '((:key "path:/repo/src/a" :mode write))
    '((:key "path:/repo/src/b" :mode write)))))

(ert-deftest chat-code-collaboration-nonconflicting-children-merge-and-verify ()
  "Independent worktrees merge without overwrite and each reruns verification."
  (chat-test-with-temp-dir
   (chat-code-collaboration-test--repo temp-dir)
   (chat-code-collaboration-test--isolated
     (let ((parent (chat-session-create "Parent" 'test-model))
           calls children)
       (chat-session-set-working-directory parent temp-dir)
       (setq children
             (list
              (chat-code-collaboration-test--prepared-child
               parent temp-dir "a.txt" "a1\n")
              (chat-code-collaboration-test--prepared-child
               parent temp-dir "b.txt" "b1\n")))
       (let ((chat-code-collaboration-verification-function
              (lambda (_root changed _session-id)
                (push changed calls)
                (list :id (format "verify-%d" (length calls))
                      :status 'passed))))
         (dolist (child children)
           (should (eq (chat-code-merge-result-status
                        (chat-code-collaboration-merge child temp-dir))
                       'merged))))
       (should (= (length calls) 2))
       (should (equal (with-temp-buffer
                        (insert-file-contents (expand-file-name "a.txt" temp-dir))
                        (buffer-string))
                      "a1\n"))
       (should (equal (with-temp-buffer
                        (insert-file-contents (expand-file-name "b.txt" temp-dir))
                        (buffer-string))
                      "b1\n"))))))

(ert-deftest chat-code-collaboration-conflict-never-overwrites-parent ()
  "A parent edit on a child-owned file is detected before patch application."
  (chat-test-with-temp-dir
   (chat-code-collaboration-test--repo temp-dir)
   (chat-code-collaboration-test--isolated
     (let* ((parent (chat-session-create "Parent" 'test-model))
            child)
       (chat-session-set-working-directory parent temp-dir)
       (setq child
             (chat-code-collaboration-test--prepared-child
              parent temp-dir "a.txt" "child\n"))
       (with-temp-file (expand-file-name "a.txt" temp-dir)
         (insert "parent\n"))
       (let ((result (chat-code-collaboration-merge child temp-dir)))
         (should (eq (chat-code-merge-result-status result) 'conflicted))
         (should (equal (with-temp-buffer
                          (insert-file-contents
                           (expand-file-name "a.txt" temp-dir))
                          (buffer-string))
                        "parent\n")))
       (chat-workspace-release (chat-code-child-child-session child) t)))))

(ert-deftest chat-code-collaboration-stale-base-is-conflicted ()
  "A moved source HEAD blocks the merge without selecting either version."
  (chat-test-with-temp-dir
   (chat-code-collaboration-test--repo temp-dir)
   (chat-code-collaboration-test--isolated
     (let* ((parent (chat-session-create "Parent" 'test-model))
            child)
       (chat-session-set-working-directory parent temp-dir)
       (setq child
             (chat-code-collaboration-test--prepared-child
              parent temp-dir "a.txt" "child\n"))
       (with-temp-file (expand-file-name "b.txt" temp-dir) (insert "b1\n"))
       (chat-code-collaboration-test--git temp-dir "add" "b.txt")
       (chat-code-collaboration-test--git temp-dir "commit" "-qm" "advance")
       (let ((result (chat-code-collaboration-merge child temp-dir)))
         (should (eq (chat-code-merge-result-status result) 'conflicted))
         (should (equal (with-temp-buffer
                          (insert-file-contents
                           (expand-file-name "a.txt" temp-dir))
                          (buffer-string))
                        "a0\n")))
       (chat-workspace-release (chat-code-child-child-session child) t)))))

(ert-deftest chat-code-collaboration-post-completion-drift-is-conflicted ()
  "Worktree drift after completion evidence is detected before source writes."
  (chat-test-with-temp-dir
   (chat-code-collaboration-test--repo temp-dir)
   (chat-code-collaboration-test--isolated
     (let* ((parent (chat-session-create "Parent" 'test-model))
            child)
       (chat-session-set-working-directory parent temp-dir)
       (setq child
             (chat-code-collaboration-test--prepared-child
              parent temp-dir "a.txt" "child\n"))
       (with-temp-file
           (expand-file-name
            "b.txt" (chat-workspace-path (chat-code-child-workspace child)))
         (insert "late drift\n"))
       (let ((result (chat-code-collaboration-merge child temp-dir)))
         (should (eq (chat-code-merge-result-status result) 'conflicted))
         (should (string-match-p "after completion"
                                 (chat-code-merge-result-reason result)))
         (should (equal (with-temp-buffer
                          (insert-file-contents
                           (expand-file-name "a.txt" temp-dir))
                          (buffer-string))
                        "a0\n")))
       (chat-workspace-release (chat-code-child-child-session child) t)))))

(ert-deftest chat-code-collaboration-parent-result-excludes-transcript ()
  "Parent-visible child data is bounded and contains no transcript field."
  (let* ((child (chat-code-child-create
                 :id "child" :status 'completed
                 :summary (make-string 10000 ?x)
                 :changed-files '("a.el") :checkpoint-ids '("cp-1")))
         (data (chat-code-collaboration-child-data child)))
    (should (<= (length (alist-get 'summary data))
                chat-code-collaboration-summary-limit))
    (should-not (assq 'transcript data))
    (should (equal (alist-get 'changedFiles data) '("a.el")))
    (should (equal (alist-get 'checkpointIds data) '("cp-1")))))

(provide 'test-chat-code-collaboration)
;;; test-chat-code-collaboration.el ends here
