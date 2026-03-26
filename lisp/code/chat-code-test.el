;;; chat-code-test.el --- Test integration for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This module integrates testing with code mode.
;; Supports running tests, auto-fix, and coverage analysis.

;;; Code:

(require 'cl-lib)

;; ------------------------------------------------------------------
;; Test Framework Detection
;; ------------------------------------------------------------------

(defun chat-code-test--detect-framework (file-path)
  "Detect test framework for FILE-PATH."
  (let ((ext (file-name-extension file-path)))
    (pcase ext
      ("py" (chat-code-test--detect-python-framework file-path))
      ("js" 'jest)
      ("ts" 'jest)
      ("el" 'ert)
      ("go" 'go-test)
      ("rs" 'cargo-test)
      (_ nil))))

(defun chat-code-test--detect-python-framework (file-path)
  "Detect Python test framework."
  (let ((dir (file-name-directory file-path)))
    (cond
     ((file-exists-p (expand-file-name "pytest.ini" dir)) 'pytest)
     ((file-exists-p (expand-file-name "setup.py" dir)) 'pytest)
     ((file-exists-p (expand-file-name "pyproject.toml" dir)) 'pytest)
     (t 'unittest))))

;; ------------------------------------------------------------------
;; Running Tests
;; ------------------------------------------------------------------

(defun chat-code-test-run (file-path &optional test-name)
  "Run tests for FILE-PATH.
If TEST-NAME is provided, run only that test."
  (interactive
   (list (or (buffer-file-name)
             (read-file-name "Test file: "))
         (when current-prefix-arg
           (read-string "Test name: "))))
  (let ((framework (chat-code-test--detect-framework file-path)))
    (pcase framework
      ('pytest (chat-code-test--run-pytest file-path test-name))
      ('ert (chat-code-test--run-ert file-path test-name))
      ('jest (chat-code-test--run-jest file-path test-name))
      ('go-test (chat-code-test--run-go-test file-path test-name))
      (_ (message "Unknown test framework for %s" file-path)))))

(defun chat-code-test--run-pytest (file-path &optional test-name)
  "Run pytest on FILE-PATH."
  (let* ((default-directory (chat-code--detect-project-root file-path))
         (cmd (if test-name
                  (format "python -m pytest %s::%s -v" file-path test-name)
                (format "python -m pytest %s -v" file-path)))
         (buffer (get-buffer-create "*chat-test-output*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "Running: %s\n\n" cmd)))
    (make-process
     :name "chat-pytest"
     :buffer buffer
     :command (list "bash" "-c" cmd)
     :sentinel (lambda (proc event)
                 (when (string-match-p "finished" event)
                   (with-current-buffer (process-buffer proc)
                     (goto-char (point-max))
                     (insert "\n\nTest run complete.\n")
                     (chat-code-test--parse-pytest-output (current-buffer)))
                   (pop-to-buffer (process-buffer proc)))))))

(defun chat-code-test--run-ert (file-path &optional test-name)
  "Run ERT tests in FILE-PATH."
  (let ((buffer (get-buffer-create "*chat-test-output*")))
    (with-current-buffer buffer
      (erase-buffer)
      (load-file file-path)
      (let ((tests (if test-name
                      (list (intern test-name))
                     (ert-select-tests "" t))))
        (ert-run-tests-batch tests)))))

(defun chat-code-test--run-jest (file-path &optional test-name)
  "Run Jest on FILE-PATH."
  (let* ((default-directory (chat-code--detect-project-root file-path))
         (cmd (if test-name
                  (format "npx jest %s -t '%s'" file-path test-name)
                (format "npx jest %s" file-path)))
         (buffer (get-buffer-create "*chat-test-output*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "Running: %s\n\n" cmd)))
    (make-process
     :name "chat-jest"
     :buffer buffer
     :command (list "bash" "-c" cmd)
     :sentinel (lambda (proc event)
                 (when (string-match-p "finished" event)
                   (pop-to-buffer (process-buffer proc)))))))

(defun chat-code-test--run-go-test (file-path &optional test-name)
  "Run Go tests in FILE-PATH."
  (let* ((default-directory (file-name-directory file-path))
         (cmd (if test-name
                  (format "go test -run %s -v" test-name)
                "go test -v"))
         (buffer (get-buffer-create "*chat-test-output*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "Running: %s\n\n" cmd)))
    (make-process
     :name "chat-go-test"
     :buffer buffer
     :command (list "bash" "-c" cmd)
     :sentinel (lambda (proc event)
                 (when (string-match-p "finished" event)
                   (pop-to-buffer (process-buffer proc)))))))

;; ------------------------------------------------------------------
;; Test Result Parsing
;; ------------------------------------------------------------------

(defun chat-code-test--parse-pytest-output (buffer)
  "Parse pytest output in BUFFER.
Returns list of failures."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let (failures)
      (while (re-search-forward "FAILED\\s-+\\([^:]+\\)::\\([^\\s]+\\)" nil t)
        (push (list :file (match-string 1)
                   :test (match-string 2)
                   :error nil)
              failures))
      (when failures
        (chat-code-test--show-failures failures))
      failures)))

(defun chat-code-test--show-failures (failures)
  "Show test FAILURES in a buffer."
  (let ((buffer (get-buffer-create "*chat-test-failures*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert "════════════════════════════════════════════════════════════════════\n")
      (insert "Test Failures\n")
      (insert "════════════════════════════════════════════════════════════════════\n\n")
      (dolist (failure failures)
        (insert (format "File: %s\n" (plist-get failure :file)))
        (insert (format "Test: %s\n" (plist-get failure :test)))
        (insert "\n")
        (insert (propertize "[f] Fix with AI  [i] Ignore\n"
                            'face '(:weight bold)))
        (local-set-key (kbd "f")
                      (lambda ()
                        (interactive)
                        (chat-code-test--auto-fix failure)))
        (local-set-key (kbd "i")
                      (lambda ()
                        (interactive)
                        (forward-line 3))))
      (pop-to-buffer buffer))))

;; ------------------------------------------------------------------
;; Auto-fix
;; ------------------------------------------------------------------

(defun chat-code-test--auto-fix (failure)
  "Auto-fix test FAILURE using AI."
  (let* ((file (plist-get failure :file))
         (test-name (plist-get failure :test))
         (error-info (plist-get failure :error))
         (source-code (with-temp-buffer
                        (insert-file-contents file)
                        (buffer-string)))
         (test-code (chat-code-test--extract-test file test-name)))
    ;; Create prompt for AI
    (let ((prompt (format "Fix this failing test:\n\nTest: %s\nFile: %s\nError: %s\n\nTest code:\n```\n%s\n```\n\nSource code:\n```\n%s\n```\n\nProvide the fixed test code."
                         test-name file error-info test-code source-code)))
      ;; Send to code mode
      (chat-code--inline-request file test-code prompt "Auto-fix test"))))

(defun chat-code-test--extract-test (file test-name)
  "Extract test TEST-NAME from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (re-search-forward (format "def\\s+%s\\s*(" test-name) nil t)
      (beginning-of-line)
      (let ((start (point)))
        (forward-line 1)
        (while (and (not (eobp))
                    (or (looking-at "^[ \t]+")
                        (looking-at "^$")))
          (forward-line 1))
        (buffer-substring-no-properties start (point))))))

;; ------------------------------------------------------------------
;; Test Generation
;; ------------------------------------------------------------------

(defun chat-code-test-generate (function-name)
  "Generate tests for FUNCTION-NAME using AI."
  (interactive
   (list (read-string "Function to test: " (thing-at-point 'symbol))))
  (let* ((file (buffer-file-name))
         (function-code (chat-code-test--get-function-code function-name))
         (framework (chat-code-test--detect-framework file))
         (prompt (format "Generate comprehensive unit tests for this function using %s:\n\n```\n%s\n```\n\nInclude edge cases and error handling."
                        framework function-code)))
    (chat-code--inline-request file function-code prompt "Generate Tests")))

(defun chat-code-test--get-function-code (function-name)
  "Get code for FUNCTION-NAME."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward (format "\\b%s\\b" function-name) nil t)
      ;; Try to find function definition
      (beginning-of-defun)
      (let ((start (point)))
        (end-of-defun)
        (buffer-substring-no-properties start (point))))))

;; ------------------------------------------------------------------
;; Coverage
;; ------------------------------------------------------------------

(defun chat-code-test-coverage (file-path)
  "Run tests with coverage for FILE-PATH."
  (interactive (list (or (buffer-file-name) (read-file-name "File: "))))
  (let ((framework (chat-code-test--detect-framework file-path)))
    (pcase framework
      ('pytest
       (chat-code-test--run-pytest-coverage file-path))
      (_ (message "Coverage not yet supported for %s" framework)))))

(defun chat-code-test--run-pytest-coverage (file-path)
  "Run pytest with coverage."
  (let* ((default-directory (chat-code--detect-project-root file-path))
         (cmd (format "python -m pytest %s --cov=%s --cov-report=term-missing"
                     file-path
                     (file-name-sans-extension file-path)))
         (buffer (get-buffer-create "*chat-test-coverage*")))
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "Running: %s\n\n" cmd)))
    (make-process
     :name "chat-pytest-coverage"
     :buffer buffer
     :command (list "bash" "-c" cmd)
     :sentinel (lambda (proc event)
                 (when (string-match-p "finished" event)
                   (pop-to-buffer (process-buffer proc)))))))

;; ------------------------------------------------------------------
;; Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-code-run-tests ()
  "Run tests for current buffer."
  (interactive)
  (chat-code-test-run (buffer-file-name)))

;;;###autoload
(defun chat-code-run-test-at-point ()
  "Run test at point."
  (interactive)
  (let ((test-name (chat-code-test--get-test-at-point)))
    (if test-name
        (chat-code-test-run (buffer-file-name) test-name)
      (message "No test found at point"))))

(defun chat-code-test--get-test-at-point ()
  "Get test name at point."
  (save-excursion
    (when (beginning-of-defun)
      (when (looking-at "def\\s-+\\(test_\\w+\\)")
        (match-string 1)))))

;;;###autoload
(defun chat-code-test-coverage-current ()
  "Show test coverage for current file."
  (interactive)
  (chat-code-test-coverage (buffer-file-name)))

(provide 'chat-code-test)
;;; chat-code-test.el ends here
