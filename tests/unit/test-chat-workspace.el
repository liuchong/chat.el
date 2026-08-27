;;; test-chat-workspace.el --- Worktree ownership tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-workspace)

(defun chat-workspace-test--git (root &rest args)
  "Run Git ARGS at ROOT and return trimmed output."
  (with-temp-buffer
    (let ((status (apply #'process-file "git" nil t nil "-C" root args)))
      (unless (zerop status)
        (error "Git test setup failed: %s" (buffer-string)))
      (string-trim (buffer-string)))))

(defun chat-workspace-test--repository (root)
  "Initialize a committed repository at ROOT."
  (chat-workspace-test--git root "init" "-q")
  (chat-workspace-test--git root "config" "user.name" "Chat Test")
  (chat-workspace-test--git root "config" "user.email" "chat@example.invalid")
  (with-temp-file (expand-file-name "tracked.txt" root) (insert "base"))
  (chat-workspace-test--git root "add" ".")
  (chat-workspace-test--git root "commit" "-qm" "base"))

(ert-deftest chat-workspace-worktree-protects-source-dirt-and-cleans-explicitly ()
  "Owned worktree lifecycle never rewrites dirty source checkout content."
  (chat-test-with-temp-dir
   (chat-workspace-test--repository temp-dir)
   (with-temp-file (expand-file-name "tracked.txt" temp-dir)
     (insert "source dirty"))
   (let* ((chat-workspace-directory
           (expand-file-name "workspaces/" chat-state-dir))
          (chat-worktree-directory
           (expand-file-name "worktrees/" chat-state-dir))
          (chat-workspace--registry (make-hash-table :test 'equal))
          (session (chat-session-create "Workspace" 'test-model))
          (workspace (chat-workspace-enable-worktree session temp-dir))
          (worktree-file (expand-file-name
                          "tracked.txt" (chat-workspace-path workspace))))
     (should (eq (chat-workspace-status workspace) 'active))
     (should (equal (with-temp-buffer
                      (insert-file-contents worktree-file)
                      (buffer-string))
                    "base"))
     (should (equal (with-temp-buffer
                      (insert-file-contents
                       (expand-file-name "tracked.txt" temp-dir))
                      (buffer-string))
                    "source dirty"))
     (with-temp-file worktree-file (insert "worktree dirty"))
     (should-error (chat-workspace-release session)
                   :type 'chat-workspace-dirty)
     (should (eq (chat-workspace-status workspace) 'needs-attention))
     (chat-workspace-release session t)
     (should (eq (chat-workspace-status workspace) 'released))
     (should-not (file-exists-p (chat-workspace-path workspace)))
     (should (equal (with-temp-buffer
                      (insert-file-contents
                       (expand-file-name "tracked.txt" temp-dir))
                      (buffer-string))
                    "source dirty")))))

(ert-deftest chat-workspace-restart-reconciles-missing-owned-path ()
  "A missing worktree becomes attention state instead of being recreated."
  (chat-test-with-temp-dir
   (chat-workspace-test--repository temp-dir)
   (let* ((chat-workspace-directory
           (expand-file-name "workspaces/" chat-state-dir))
          (chat-worktree-directory
           (expand-file-name "worktrees/" chat-state-dir))
          (chat-workspace--registry (make-hash-table :test 'equal))
          (session (chat-session-create "Workspace restart" 'test-model))
          (workspace (chat-workspace-enable-worktree session temp-dir))
          (path (chat-workspace-path workspace)))
     (chat-workspace-test--git temp-dir "worktree" "remove" "--force" path)
     (chat-workspace-save)
     (clrhash chat-workspace--registry)
     (should (= (chat-workspace-load) 1))
     (let ((loaded (chat-workspace-get session)))
       (should loaded)
       (chat-workspace-reconcile loaded session)
       (should (eq (chat-workspace-status loaded) 'needs-attention))
       (should-not (file-directory-p path))))))

(provide 'test-chat-workspace)
;;; test-chat-workspace.el ends here
