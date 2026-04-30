;;; test-chat-request-surface.el --- Tests for shared request UI helpers -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-request-surface)

(ert-deftest chat-request-surface-tool-targets-summarizes-file-events ()
  "Test shared tool target extraction deduplicates and keeps the latest single-file target."
  (chat-test-with-temp-dir
   (let* ((file-a (expand-file-name "docs/a.md" temp-dir))
          (file-b (expand-file-name "docs/b.md" temp-dir))
          (summary
           (chat-request-surface-tool-targets
            `((:type tool-call
               :tool "files_read"
               :arguments (("path" . ,file-a)))
              (:type tool-call
               :tool "files_read"
               :arguments (("path" . ,file-b)))
              (:type tool-call
               :tool "files_read"
               :arguments (("path" . ,file-a)))))))
     (should (equal (plist-get summary :paths)
                    (list (file-truename file-a)
                          (file-truename file-b))))
     (should (equal (plist-get summary :latest-single-target)
                    (file-truename file-a))))))

(ert-deftest chat-request-surface-buffer-observer-runs-in-source-buffer ()
  "Test shared observers switch back to the owning buffer before dispatch."
  (let (captured)
    (with-temp-buffer
      (rename-buffer " *chat-request-surface-test*" t)
      (let ((observer
             (chat-request-surface-buffer-observer
              (current-buffer)
              (lambda (id _trace event)
                (setq captured
                      (list id (current-buffer) (plist-get event :type)))))))
        (funcall observer "req-1" nil '(:type stream-chunk))
        (should (equal (car captured) "req-1"))
        (should (eq (cadr captured) (current-buffer)))
        (should (eq (caddr captured) 'stream-chunk))))))

(ert-deftest chat-request-surface-update-panel-if-visible-refreshes-visible-panels ()
  "Test panel refresh helper only updates when the panel is visible."
  (let ((chat-request-panel-auto-show t)
        updated)
    (with-temp-buffer
      (cl-letf (((symbol-function 'chat-request-panel--buffer-name)
                 (lambda (_buffer) "*chat-request:test*"))
                ((symbol-function 'chat-request-panel-update)
                 (lambda (buffer request-id tool-events)
                   (setq updated (list buffer request-id tool-events)))))
        (chat-request-surface-update-panel-if-visible
         (current-buffer)
         "req-2"
         '((:type tool-call :tool "files_read")))
        (should (equal (nth 1 updated) "req-2"))))))

(ert-deftest chat-request-surface-approval-hint-skips-duplicate-signatures ()
  "Test approval hint helper only returns text for new approval signatures."
  (let* ((tool-events '((:type approval-pending
                         :tool "files_write"
                         :actions ("C-c C-a once"))))
         (hint (chat-request-surface-approval-hint tool-events nil)))
    (should (string-match-p "Approval pending" (plist-get hint :text)))
    (should-not
     (chat-request-surface-approval-hint
      tool-events
      (plist-get hint :signature)))))

(provide 'test-chat-request-surface)
;;; test-chat-request-surface.el ends here
