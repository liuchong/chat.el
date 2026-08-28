;;; chat-code-test.el --- Compatibility commands for project verification -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Historical test commands now delegate to the project-level verifier.  The
;; verifier resolves manifest commands and executes argv lists, so this module
;; no longer guesses a framework from one extension or constructs shell text.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'chat-code-verify)

(defun chat-code-test--project-root (path)
  "Return the project root containing PATH."
  (let ((default-directory
         (file-name-as-directory
          (if (file-directory-p path) path (file-name-directory path)))))
    (file-name-as-directory
     (or (and (fboundp 'project-current)
              (when-let* ((project (project-current nil default-directory)))
                (expand-file-name (project-root project))))
         (locate-dominating-file
          default-directory
          (lambda (directory)
            (seq-some
             (lambda (marker)
               (file-exists-p (expand-file-name marker directory)))
             '(".git" "package.json" "pyproject.toml" "go.mod"
               "Cargo.toml" "tests/run-tests.sh" "tests/run-tests.el"))))
         default-directory))))

(defun chat-code-test-run (file-path &optional test-name)
  "Verify the project containing FILE-PATH.
TEST-NAME is retained for API compatibility; project profiles remain the
authority for targeted command syntax."
  (interactive
   (list (or (buffer-file-name) (read-file-name "Changed file: "))
         (when current-prefix-arg (read-string "Test name: "))))
  (when (and test-name (not (string-empty-p test-name)))
    (message "Project verification profile controls test targeting"))
  (let* ((root (chat-code-test--project-root file-path))
         (relative (file-relative-name (expand-file-name file-path) root))
         (profile (chat-code-verify-plan root (list relative)))
         (result (chat-code-verify-run-sync profile)))
    (message "%s" (chat-code-verify-summary result))
    result))

(defun chat-code-run-tests ()
  "Run project verification for the current file."
  (interactive)
  (unless (buffer-file-name) (user-error "Current buffer has no file"))
  (chat-code-test-run (buffer-file-name)))

(defun chat-code-run-test-at-point ()
  "Run project verification for the current file and test symbol."
  (interactive)
  (unless (buffer-file-name) (user-error "Current buffer has no file"))
  (chat-code-test-run
   (buffer-file-name)
   (or (thing-at-point 'symbol t) "")))

(defun chat-code-test-coverage (_file-path)
  "Explain how coverage should be configured in a verification profile."
  (user-error
   "Coverage requires an explicit project verification step; no command was guessed"))

(defun chat-code-test-coverage-current ()
  "Open the explicit coverage configuration guidance."
  (interactive)
  (chat-code-test-coverage (buffer-file-name)))

(defun chat-code-test-generate (_function-name)
  "Reject implicit test generation from this execution compatibility module."
  (interactive (list (or (thing-at-point 'symbol t) "")))
  (user-error "Use the coding Agent with an explicit test-writing objective"))

(provide 'chat-code-test)
;;; chat-code-test.el ends here
