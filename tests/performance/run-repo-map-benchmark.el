;;; run-repo-map-benchmark.el --- Standalone repository benchmark -*- lexical-binding: t; -*-

;;; Code:

(let* ((root (file-name-directory (directory-file-name
                                   (file-name-directory load-file-name))))
       (project (file-name-directory (directory-file-name root))))
  (load (expand-file-name "chat.el" project) nil t))

(let ((result (chat-coding-acceptance-benchmark-sync)))
  (princ (json-encode result))
  (terpri)
  (unless (seq-every-p
           (lambda (gate)
             (eq (chat-coding-acceptance-gate-status gate) 'passed))
           (chat-coding-acceptance-performance-gates result))
    (kill-emacs 1)))

;;; run-repo-map-benchmark.el ends here
