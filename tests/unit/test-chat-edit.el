;;; test-chat-edit.el --- Tests for chat-edit -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-edit)

(ert-deftest chat-edit-apply-writes-inside-allowed-directories ()
  "Test applying an edit writes the file inside allowed directories."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (target (expand-file-name "demo.txt" temp-dir))
          (edit (chat-edit-create-generate target "fresh content" "create demo")))
     (should (chat-edit-apply edit))
     (should (string= (with-temp-buffer
                        (insert-file-contents target)
                        (buffer-string))
                      "fresh content")))))

(ert-deftest chat-edit-apply-rejects-paths-outside-allowed-directories ()
  "Test applying an edit outside allowed directories fails cleanly."
  (chat-test-with-temp-dir
   (let* ((allowed (expand-file-name "allowed" temp-dir))
          (chat-files-allowed-directories (list allowed))
          (target (expand-file-name "outside.txt" temp-dir))
          (edit (chat-edit-create-generate target "nope" "escape attempt")))
     (make-directory allowed t)
     (should-not (chat-edit-apply edit))
    (should-not (file-exists-p target)))))

(ert-deftest chat-edit-refresh-refuses-modified-visiting-buffer ()
  "Test refreshing a file buffer rejects unsaved user edits."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (target (expand-file-name "keep.txt" temp-dir)))
     (with-temp-file target
       (insert "original"))
     (let ((buffer (find-file-noselect target)))
       (unwind-protect
           (progn
             (with-current-buffer buffer
               (insert "user edits"))
             (should-error (chat-edit--refresh-file-buffer target)
                           :type 'chat-files-stale-file)
             (with-current-buffer buffer
               (should (buffer-modified-p))
               (should (string-match-p "user edits" (buffer-string))))))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (set-buffer-modified-p nil))
         (kill-buffer buffer))))))

(ert-deftest chat-edit-apply-refuses-modified-visiting-buffer ()
  "Applying an edit never overwrites an unsaved visiting buffer."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (target (expand-file-name "keep.txt" temp-dir))
          (edit (chat-edit-create-rewrite
                 target "disk" "agent" "rewrite"))
          buffer)
     (with-temp-file target
       (insert "disk"))
     (unwind-protect
         (progn
           (setq buffer (find-file-noselect target))
           (with-current-buffer buffer
             (goto-char (point-max))
             (insert " unsaved"))
           (should-not (chat-edit-apply edit))
           (should-not (chat-edit-backup-file edit))
           (should (string= (with-temp-buffer
                              (insert-file-contents target)
                              (buffer-string))
                            "disk")))
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (set-buffer-modified-p nil))
         (kill-buffer buffer))))))

(ert-deftest chat-edit-refresh-reverts-clean-visiting-buffer ()
  "Test refreshing a clean visiting buffer picks up new file content."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (target (expand-file-name "clean.txt" temp-dir)))
     (with-temp-file target
       (insert "v1"))
     (let ((buffer (find-file-noselect target)))
       (unwind-protect
           (progn
             (with-temp-file target
               (insert "v2"))
             (chat-edit--refresh-file-buffer target)
             (with-current-buffer buffer
               (should-not (buffer-modified-p))
               (should (string-match-p "v2" (buffer-string))))))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))))))

(provide 'test-chat-edit)
;;; test-chat-edit.el ends here
