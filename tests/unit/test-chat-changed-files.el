;;; test-chat-changed-files.el --- Session changed-file ledger tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-changed-files)
(require 'chat-checkpoint)
(require 'chat-files)

(defun chat-changed-files-test--session (root)
  "Return a saved session rooted at ROOT."
  (let ((session (chat-session-create "Changed files" 'test-model)))
    (chat-session-metadata-set session 'project-root
                               (file-name-as-directory root))
    (chat-session-metadata-set session 'working-directory
                               (file-name-as-directory root))
    (chat-session-save session)
    session))

(defun chat-changed-files-test--fact
    (root path operation turn &optional rename-from timestamp)
  "Return a changed-file fact rooted at ROOT."
  (list :path path
        :canonical-path (expand-file-name path root)
        :operation operation :turn-id turn
        :updated-at (or timestamp (* 1000 turn))
        :rename-from rename-from))

(ert-deftest chat-changed-files-derives-net-effects-and-deduplicates-writes ()
  "Repeated writes update one entry and an added-then-deleted path disappears."
  (chat-test-with-temp-dir
   (let* ((chat-changed-files--registry (make-hash-table :test 'equal))
          (session (chat-changed-files-test--session temp-dir)))
     (chat-changed-files-record-success
      session "checkpoint-1"
      (list (chat-changed-files-test--fact temp-dir "new.txt" 'added 1))
      '("new.txt"))
     (chat-changed-files-record-success
      session "checkpoint-2"
      (list (chat-changed-files-test--fact temp-dir "new.txt" 'modified 2))
      '("new.txt"))
     (let ((entry (car (chat-changed-file-ledger-entries
                        (chat-changed-files-current session)))))
       (should (eq (chat-changed-file-entry-operation entry) 'added))
       (should (= (chat-changed-file-entry-first-turn entry) 1))
       (should (= (chat-changed-file-entry-last-turn entry) 2))
       (should (equal (chat-changed-file-entry-latest-evidence-id entry)
                      "checkpoint-2")))
     (chat-changed-files-record-success
      session "checkpoint-3"
      (list (chat-changed-files-test--fact temp-dir "new.txt" 'deleted 3))
      '("new.txt"))
     (should-not (chat-changed-file-ledger-entries
                  (chat-changed-files-current session))))))

(ert-deftest chat-changed-files-preserves-execution-order-at-one-timestamp ()
  "Equal timestamps never reorder successful contributions by derived ID."
  (chat-test-with-temp-dir
   (let* ((chat-changed-files--registry (make-hash-table :test 'equal))
          (session (chat-changed-files-test--session temp-dir))
          (timestamp 1000))
     ;; These evidence names deliberately make the delete contribution's
     ;; stable hash sort before the add contribution's stable hash.
     (chat-changed-files-record-success
      session "add-0"
      (list (chat-changed-files-test--fact
             temp-dir "same.txt" 'added 1 nil timestamp))
      '("same.txt"))
     (chat-changed-files-record-success
      session "delete-0"
      (list (chat-changed-files-test--fact
             temp-dir "same.txt" 'deleted 2 nil timestamp))
      '("same.txt"))
     (should-not (chat-changed-file-ledger-entries
                  (chat-changed-files-current session))))))

(ert-deftest chat-changed-files-rename-retains-source-and-rollback-rederives ()
  "A rename replaces the visible source and rollback restores prior projection."
  (chat-test-with-temp-dir
   (let* ((chat-changed-files--registry (make-hash-table :test 'equal))
          (session (chat-changed-files-test--session temp-dir)))
     (chat-changed-files-record-success
      session "checkpoint-before"
      (list (chat-changed-files-test--fact temp-dir "old.txt" 'modified 1))
      '("old.txt"))
     (chat-changed-files-record-success
      session "checkpoint-rename"
      (list (chat-changed-files-test--fact
             temp-dir "new.txt" 'renamed 2 "old.txt"))
      '("old.txt" "new.txt"))
     (let* ((ledger (chat-changed-files-current session))
            (entry (car (chat-changed-file-ledger-entries ledger))))
       (should (= (length (chat-changed-file-ledger-entries ledger)) 1))
       (should (equal (chat-changed-file-entry-path entry) "new.txt"))
       (should (eq (chat-changed-file-entry-operation entry) 'renamed))
       (should (equal (chat-changed-file-entry-rename-history entry)
                      '("old.txt"))))
     (chat-changed-files-rollback-evidence session "checkpoint-rename")
     (let ((entry (car (chat-changed-file-ledger-entries
                        (chat-changed-files-current session)))))
       (should (equal (chat-changed-file-entry-path entry) "old.txt"))
       (should (eq (chat-changed-file-entry-operation entry) 'modified))))))

(ert-deftest chat-changed-files-added-then-renamed-remains-an-addition ()
  "Renaming a conversation-created file keeps its net added operation."
  (chat-test-with-temp-dir
   (let* ((chat-changed-files--registry (make-hash-table :test 'equal))
          (session (chat-changed-files-test--session temp-dir)))
     (chat-changed-files-record-success
      session "checkpoint-add"
      (list (chat-changed-files-test--fact temp-dir "draft.txt" 'added 1))
      '("draft.txt"))
     (chat-changed-files-record-success
      session "checkpoint-rename"
      (list (chat-changed-files-test--fact
             temp-dir "final.txt" 'renamed 2 "draft.txt"))
      '("draft.txt" "final.txt"))
     (let ((entry (car (chat-changed-file-ledger-entries
                        (chat-changed-files-current session)))))
       (should (equal "final.txt" (chat-changed-file-entry-path entry)))
       (should (eq 'added (chat-changed-file-entry-operation entry)))
       (should (equal '("draft.txt")
                      (chat-changed-file-entry-rename-history entry)))))))

(ert-deftest chat-changed-files-persists-strict-current-schema ()
  "The session round trip preserves the ledger and rejects unknown schemas."
  (chat-test-with-temp-dir
   (let* ((chat-changed-files--registry (make-hash-table :test 'equal))
          (session (chat-changed-files-test--session temp-dir)))
     (chat-changed-files-record-success
      session "checkpoint-1"
      (list (chat-changed-files-test--fact temp-dir "persist.txt" 'modified 1))
      '("persist.txt"))
     (clrhash chat-changed-files--registry)
     (let* ((reloaded (chat-session-load (chat-session-id session)))
            (entry (car (chat-changed-file-ledger-entries
                         (chat-changed-files-current reloaded)))))
       (should (equal (chat-changed-file-entry-path entry) "persist.txt")))
     (clrhash chat-changed-files--registry)
     (chat-session-metadata-set
      session 'changed-file-ledger
      '((schemaVersion . 2) (revision . 1)
        (contributions . []) (entries . [])))
     (should-error (chat-changed-files-current session)
                   :type 'chat-changed-files-error))))

(ert-deftest chat-checkpoint-success-is-the-changed-file-attribution-boundary ()
  "Only completed direct writes enter the ledger; unrelated dirt does not."
  (chat-test-with-temp-dir
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (chat-changed-files--registry (make-hash-table :test 'equal))
          (chat-files-allowed-directories (list temp-dir))
          (default-directory temp-dir)
          (session (chat-changed-files-test--session temp-dir))
          (written (expand-file-name "written.txt" temp-dir))
          (captured-only (expand-file-name "captured-only.txt" temp-dir))
          (unrelated (expand-file-name "unrelated.txt" temp-dir))
          (write-call `(:name "files_write"
                        :arguments (("path" . ,written))))
          (captured-call `(:name "files_write"
                           :arguments (("path" . ,captured-only)))))
     (chat-checkpoint-create session :turn-id 1)
     (chat-checkpoint-before-tool session 1 write-call)
     (with-temp-file written (insert "owned"))
     (with-temp-file unrelated (insert "user dirt"))
     (chat-checkpoint-complete-tool session 1 write-call)
     (chat-checkpoint-before-tool session 1 captured-call)
     (let ((entries (chat-changed-file-ledger-entries
                     (chat-changed-files-current session))))
       (should (= (length entries) 1))
       (should (equal (chat-changed-file-entry-path (car entries))
                      "written.txt"))
       (should (eq (chat-changed-file-entry-operation (car entries)) 'added))))))

(ert-deftest chat-checkpoint-rename-and-rollback-update-the-ledger ()
  "A completed move is one rename entry and code rollback removes its evidence."
  (chat-test-with-temp-dir
   (let* ((chat-checkpoint-directory
           (expand-file-name "checkpoints/" chat-state-dir))
          (chat-checkpoint--registry (make-hash-table :test 'equal))
          (chat-changed-files--registry (make-hash-table :test 'equal))
          (chat-files-allowed-directories (list temp-dir))
          (default-directory temp-dir)
          (session (chat-changed-files-test--session temp-dir))
          (source (expand-file-name "old.txt" temp-dir))
          (target (expand-file-name "new.txt" temp-dir))
          (patch (mapconcat
                  #'identity
                  '("*** Begin Patch"
                    "*** Update File: old.txt"
                    "*** Move to: new.txt"
                    "*** End Patch")
                  "\n"))
          (call `(:name "apply_patch" :arguments (("patch" . ,patch)))))
     (with-temp-file source (insert "content\n"))
     (let ((checkpoint (chat-checkpoint-create session :turn-id 1)))
       (chat-checkpoint-before-tool session 1 call)
       (rename-file source target)
       (chat-checkpoint-complete-tool session 1 call)
       (let ((entry (car (chat-changed-file-ledger-entries
                          (chat-changed-files-current session)))))
         (should (equal (chat-changed-file-entry-path entry) "new.txt"))
         (should (eq (chat-changed-file-entry-operation entry) 'renamed))
         (should (equal (chat-changed-file-entry-rename-history entry)
                        '("old.txt"))))
       (chat-checkpoint-rollback-code
        (chat-checkpoint-get (chat-checkpoint-id checkpoint)
                             (chat-session-id session)))
       (should (file-exists-p source))
       (should-not (file-exists-p target))
       (should-not (chat-changed-file-ledger-entries
                    (chat-changed-files-current session)))))))

(provide 'test-chat-changed-files)
;;; test-chat-changed-files.el ends here
