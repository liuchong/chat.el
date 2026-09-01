;;; test-chat-checkpoint.el --- Owned recovery tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-checkpoint)
(require 'chat-files)

(defun chat-checkpoint-test--git (root &rest args)
  "Run Git ARGS in ROOT for checkpoint tests."
  (with-temp-buffer
    (let ((status (apply #'process-file "git" nil t nil "-C" root args)))
      (unless (zerop status)
        (error "Git test setup failed: %s" (buffer-string)))
      (string-trim (buffer-string)))))

(defun chat-checkpoint-test--repository (root)
  "Initialize a committed repository at ROOT."
  (chat-checkpoint-test--git root "init" "-q")
  (chat-checkpoint-test--git root "config" "user.name" "Chat Test")
  (chat-checkpoint-test--git root "config" "user.email" "chat@example.invalid")
  (with-temp-file (expand-file-name "owned.txt" root) (insert "before"))
  (with-temp-file (expand-file-name "user.txt" root) (insert "base"))
  (chat-checkpoint-test--git root "add" ".")
  (chat-checkpoint-test--git root "commit" "-qm" "base"))

(defun chat-checkpoint-test--session (root)
  "Return a saved code-capable session rooted at ROOT."
  (let ((session (chat-session-create "Checkpoint" 'test-model)))
    (chat-session-metadata-set session 'project-root
                               (file-name-as-directory root))
    (chat-session-metadata-set session 'working-directory
                               (file-name-as-directory root))
    (chat-session-save session)
    session))

(ert-deftest chat-checkpoint-create-normalizes-persisted-id-vectors ()
  "A decoded checkpoint ID array remains appendable on the next Turn."
  (chat-test-with-temp-dir
   (chat-checkpoint-test--repository temp-dir)
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (default-directory temp-dir)
          (session (chat-checkpoint-test--session temp-dir))
          (prior-ids ["checkpoint-old-1" "checkpoint-old-2"]))
     (chat-session-metadata-set session 'checkpoint-ids prior-ids)
     (let ((checkpoint (chat-checkpoint-create session :turn-id 3))
           (ids (chat-session-metadata-get session 'checkpoint-ids)))
       (should (listp ids))
       (should (equal ids
                      (list "checkpoint-old-1"
                            "checkpoint-old-2"
                            (chat-checkpoint-id checkpoint))))))))

(ert-deftest chat-checkpoint-owned-rollback-preserves-preexisting-dirty-work ()
  "Rollback restores one owned file and leaves unrelated user dirt intact."
  (chat-test-with-temp-dir
   (chat-checkpoint-test--repository temp-dir)
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (chat-files-allowed-directories (list temp-dir))
          (default-directory temp-dir)
          (session (chat-checkpoint-test--session temp-dir))
          (owned (expand-file-name "owned.txt" temp-dir))
          (user-file (expand-file-name "user.txt" temp-dir)))
     (with-temp-file user-file (insert "user dirty before turn"))
     (let ((checkpoint (chat-checkpoint-create session :turn-id 1)))
       (chat-checkpoint-capture-path checkpoint owned)
       (with-temp-file owned (insert "agent change"))
       (chat-checkpoint-complete-paths checkpoint (list owned))
       (let ((loaded (chat-checkpoint-get
                      (chat-checkpoint-id checkpoint)
                      (chat-session-id session))))
         (should loaded)
         (chat-checkpoint-rollback-code loaded)
         (should (equal (with-temp-buffer
                          (insert-file-contents owned)
                          (buffer-string))
                        "before"))
         (should (equal (with-temp-buffer
                          (insert-file-contents user-file)
                          (buffer-string))
                        "user dirty before turn")))))))

(ert-deftest chat-checkpoint-observes-each-direct-write-state-transition ()
  "A repeated no-op write is not semantic progress after an earlier mutation."
  (chat-test-with-temp-dir
   (chat-checkpoint-test--repository temp-dir)
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (chat-files-allowed-directories (list temp-dir))
          (default-directory temp-dir)
          (session (chat-checkpoint-test--session temp-dir))
          (path (expand-file-name "owned.txt" temp-dir))
          (call `(:name "files_write" :arguments (("path" . ,path)))))
     (chat-checkpoint-create session :turn-id 1)
     (chat-checkpoint-before-tool session 1 call)
     (with-temp-file path (insert "first"))
     (should (eq (chat-checkpoint-tool-change-status session 1 call) 'changed))
     (chat-checkpoint-complete-tool session 1 call)
     (chat-checkpoint-before-tool session 1 call)
     (with-temp-file path (insert "first"))
     (should (eq (chat-checkpoint-tool-change-status session 1 call)
                 'unchanged))
     (chat-checkpoint-complete-tool session 1 call)
     (chat-checkpoint-before-tool session 1 call)
     (with-temp-file path (insert "second"))
     (should (eq (chat-checkpoint-tool-change-status session 1 call)
                 'changed)))))

(ert-deftest chat-checkpoint-external-drift-refuses-before-overwrite ()
  "Current bytes differing from the runtime post-digest block rollback."
  (chat-test-with-temp-dir
   (chat-checkpoint-test--repository temp-dir)
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (session (chat-checkpoint-test--session temp-dir))
          (path (expand-file-name "owned.txt" temp-dir))
          (checkpoint (chat-checkpoint-create session :turn-id 1)))
     (chat-checkpoint-capture-path checkpoint path)
     (with-temp-file path (insert "agent change"))
     (chat-checkpoint-complete-paths checkpoint (list path))
     (with-temp-file path (insert "external change"))
     (should-error (chat-checkpoint-rollback-code checkpoint)
                   :type 'chat-checkpoint-external-drift)
     (should (equal (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string))
                    "external change"))
     (chat-checkpoint-rollback-code checkpoint t)
     (should (equal (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string))
                    "before")))))

(ert-deftest chat-checkpoint-restores-new-deleted-binary-and-executable-paths ()
  "Owned snapshots preserve absence, bytes, links and executable mode."
  (chat-test-with-temp-dir
   (chat-checkpoint-test--repository temp-dir)
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (session (chat-checkpoint-test--session temp-dir))
          (new-file (expand-file-name "new.bin" temp-dir))
          (deleted (expand-file-name "owned.txt" temp-dir))
          (executable (expand-file-name "run.sh" temp-dir))
          (link (expand-file-name "owned-link" temp-dir))
          (checkpoint (chat-checkpoint-create session :turn-id 1)))
     (with-temp-file executable (insert "#!/bin/sh\nexit 0\n"))
     (set-file-modes executable #o755)
     (make-symbolic-link "owned.txt" link)
     (chat-checkpoint-capture-paths checkpoint
                                    (list new-file deleted executable link))
     (with-temp-buffer
       (set-buffer-multibyte nil)
       (insert (unibyte-string 0 1 2 255))
       (write-region (point-min) (point-max) new-file nil 'silent))
     (delete-file deleted)
     (with-temp-file executable (insert "changed\n"))
     (set-file-modes executable #o644)
     (delete-file link)
     (make-symbolic-link "user.txt" link)
     (chat-checkpoint-complete-paths checkpoint
                                     (list new-file deleted executable link))
     (chat-checkpoint-rollback-code checkpoint)
     (should-not (file-exists-p new-file))
     (should (equal (with-temp-buffer
                      (insert-file-contents deleted)
                      (buffer-string))
                    "before"))
     (should (= (logand (file-modes executable) #o777) #o755))
     (should (equal (with-temp-buffer
                      (insert-file-contents executable)
                      (buffer-string))
                    "#!/bin/sh\nexit 0\n"))
     (should (equal (file-symlink-p link) "owned.txt")))))

(ert-deftest chat-checkpoint-refuses-a-forged-path-outside-the-workspace ()
  "A reloaded or corrupted entry cannot escape its checkpoint root."
  (chat-test-with-temp-dir
   (chat-checkpoint-test--repository temp-dir)
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (session (chat-checkpoint-test--session temp-dir))
          (owned (expand-file-name "owned.txt" temp-dir))
          (outside (expand-file-name "outside.txt"
                                     (file-name-directory temp-dir)))
          (checkpoint (chat-checkpoint-create session :turn-id 1)))
     (unwind-protect
         (progn
           (with-temp-file outside (insert "outside"))
           (chat-checkpoint-capture-path checkpoint owned)
           (with-temp-file owned (insert "agent change"))
           (chat-checkpoint-complete-paths checkpoint (list owned))
           (setf (chat-checkpoint-file-path
                  (car (chat-checkpoint-files checkpoint)))
                 "../outside.txt")
           (should-error (chat-checkpoint-rollback-code checkpoint t)
                         :type 'chat-checkpoint-workspace-mismatch)
           (should (equal (with-temp-buffer
                            (insert-file-contents outside)
                            (buffer-string))
                          "outside")))
       (when (file-exists-p outside)
         (delete-file outside))))))

(ert-deftest chat-checkpoint-conversation-rollback-branches-without-truncation ()
  "Conversation recovery creates a sibling from the saved head."
  (chat-test-with-temp-dir
   (chat-checkpoint-test--repository temp-dir)
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (session (chat-checkpoint-test--session temp-dir))
          (first (make-chat-message :id "before-turn" :role :assistant
                                    :content "before")))
     (chat-session-add-message session first)
     (let ((checkpoint (chat-checkpoint-create session :turn-id 2)))
       (chat-session-add-message
        session (make-chat-message :id "user-turn" :role :user :content "do"))
       (chat-session-add-message
        session (make-chat-message :id "answer" :role :assistant :content "done"))
       (let ((branch (chat-checkpoint-rollback-conversation checkpoint session)))
         (should (= (length (chat-session-messages session)) 3))
         (should (= (length (chat-session-messages branch)) 1))
         (should (equal (chat-message-id
                         (car (chat-session-messages branch)))
                        "before-turn"))
         (should (equal (chat-session-parent-session-id branch)
                        (chat-session-id session))))))))

(ert-deftest chat-checkpoint-failed-new-turn-does-not-mutate-previous-turn ()
  "A lifecycle failure without its own checkpoint leaves the prior one alone."
  (chat-test-with-temp-dir
   (chat-checkpoint-test--repository temp-dir)
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (session (chat-checkpoint-test--session temp-dir))
          (checkpoint (chat-checkpoint-create session :turn-id 1))
          (event (chat-event-create
                  :type 'turn-failed
                  :session-id (chat-session-id session)
                  :turn-id 2)))
     (chat-checkpoint-observe-event event)
     (should-not (chat-checkpoint-boundaries checkpoint))
     (should-not (chat-checkpoint-for-turn session 2)))))

(provide 'test-chat-checkpoint)
;;; test-chat-checkpoint.el ends here
