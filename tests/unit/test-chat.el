;;; test-chat.el --- Tests for main chat.el entry point -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat.el main entry point and configuration.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat)

;; ------------------------------------------------------------------
;; Feature Loading
;; ------------------------------------------------------------------

(ert-deftest chat-feature-is-loaded ()
  "Test that chat feature is properly loaded."
  (should (featurep 'chat)))

;; ------------------------------------------------------------------
;; Configuration Variables
;; ------------------------------------------------------------------

(ert-deftest chat-default-model-is-set ()
  "Test that chat-default-model has a default value."
  (should chat-default-model)
  (should (symbolp chat-default-model))
  (should (eq chat-default-model 'kimi)))

(ert-deftest chat-load-config-files-loads-supported-locations-in-order ()
  "Test config files load from all supported locations in override order."
  (chat-test-with-temp-dir
   (let* ((home-dir temp-dir)
          (root-dir (expand-file-name "repo" temp-dir))
          (chat-dir (expand-file-name ".chat" home-dir))
          (process-environment (cons (format "HOME=%s" home-dir)
                                     process-environment))
          loaded-files)
     (make-directory root-dir t)
     (make-directory chat-dir t)
     (with-temp-file (expand-file-name ".chat.el" home-dir)
       (insert "(setq chat-test-config-order '(global-root))\n"
               "(setq chat-test-config-value 'home)\n"))
     (with-temp-file (expand-file-name "config.el" chat-dir)
       (insert "(setq chat-test-config-order (append chat-test-config-order '(chat-dir)))\n"
               "(setq chat-test-config-value 'chat-dir)\n"))
     (with-temp-file (expand-file-name "chat-config.local.el" root-dir)
       (insert "(setq chat-test-config-order (append chat-test-config-order '(project-local)))\n"
               "(setq chat-test-config-value 'project)\n"))
     (setq chat-test-config-order nil)
     (setq chat-test-config-value nil)
     (unwind-protect
         (progn
           (setq loaded-files (chat-load-config-files root-dir))
           (should (equal (mapcar #'file-name-nondirectory loaded-files)
                          '(".chat.el" "config.el" "chat-config.local.el")))
           (should (equal chat-test-config-order
                          '(global-root chat-dir project-local)))
           (should (eq chat-test-config-value 'project)))
       (makunbound 'chat-test-config-order)
       (makunbound 'chat-test-config-value)))))

(ert-deftest chat-session-directory-configurable ()
  "Test that session directory can be configured."
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir))
     (should (string= chat-session-directory temp-dir))
     (chat-session--ensure-directory)
     (should (file-directory-p temp-dir)))))

;; ------------------------------------------------------------------
;; Main Commands
;; ------------------------------------------------------------------

(ert-deftest chat-command-is-bound ()
  "Test that M-x chat is bound."
  (should (fboundp 'chat))
  (should (commandp 'chat)))

(ert-deftest chat-new-session-command-is-bound ()
  "Test that chat-new-session is bound."
  (should (fboundp 'chat-new-session))
  (should (commandp 'chat-new-session)))

(ert-deftest chat-list-sessions-command-is-bound ()
  "Test that chat-list-sessions is bound."
  (should (fboundp 'chat-list-sessions))
  (should (commandp 'chat-list-sessions)))

(ert-deftest chat-reading-commands-are-bound ()
  (should (commandp 'chat-quote-region))
  (should (commandp 'chat-ask-region))
  (should (commandp 'chat-quote-defun))
  (should (commandp 'chat-ask-defun))
  (should (commandp 'chat-quote-near-point))
  (should (commandp 'chat-ask-near-point))
  (should (commandp 'chat-quote-current-file))
  (should (commandp 'chat-ask-current-file)))

(ert-deftest chat-ensure-reading-session-creates-new-session-when-none ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil))
     (with-temp-buffer
       (let ((session (chat--ensure-reading-session "/tmp/demo.el")))
         (should (string= (chat-session-name session) "Read: demo.el"))
         (should (eq (chat-session-model-id session) chat-default-model)))))))

(ert-deftest chat-ensure-reading-session-reuses-last-session ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Existing" 'kimi)))
     (setq chat--last-session-id (chat-session-id session))
     (with-temp-buffer
       (let ((resolved (chat--ensure-reading-session "/tmp/other.el")))
         (should (string= (chat-session-id resolved)
                          (chat-session-id session))))))))

(ert-deftest chat-quote-region-opens-chat-and-inserts-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message")
             (set-mark (line-beginning-position))
             (goto-char (line-end-position))
             (activate-mark)
             (chat-quote-region)
             (with-current-buffer "*chat:Read: demo.el*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Question about this code:" quoted))
                 (should (string-match-p "Kind: region" quoted))
                 (should (string-match-p "message" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-current-file-sends-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-current-file "What matters here?"))
             (should (string-match-p "Question about this code:" sent-content))
             (should (string-match-p "Kind: current-file" sent-content))
             (should (string-match-p "What matters here\\?" sent-content))
             (should (string-match-p "defun demo" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-defun-opens-chat-and-inserts-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n\n(defun beta ()\n  (message \"b\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (chat-quote-defun)
             (with-current-buffer "*chat:Read: demo.el*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Kind: defun" quoted))
                 (should (string-match-p "defun beta" quoted))
                 (should-not (string-match-p "defun alpha" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-defun-sends-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n\n(defun beta ()\n  (message \"b\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-defun "Why beta?"))
             (should (string-match-p "Kind: defun" sent-content))
             (should (string-match-p "Why beta\\?" sent-content))
             (should (string-match-p "defun beta" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-near-point-opens-chat-and-inserts-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\nline4\nline5\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (forward-line 2)
             (chat-quote-near-point)
             (with-current-buffer "*chat:Read: demo.el*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Kind: near-point" quoted))
                 (should (string-match-p "line3" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-near-point-sends-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "line1\nline2\nline3\nline4\nline5\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (forward-line 2)
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-near-point "What is nearby?"))
             (should (string-match-p "Kind: near-point" sent-content))
             (should (string-match-p "What is nearby\\?" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-current-file-opens-chat-and-inserts-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (chat-quote-current-file)
             (with-current-buffer "*chat:Read: demo.el*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Kind: current-file" quoted))
                 (should (string-match-p "defun demo" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-ask-region-sends-structured-reference ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message")
             (set-mark (line-beginning-position))
             (goto-char (line-end-position))
             (activate-mark)
             (cl-letf (((symbol-function 'chat-ui-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-ui--input-overlay)
                                 (point-max))))))
               (chat-ask-region "Why is this here?"))
             (should (string-match-p "Kind: region" sent-content))
             (should (string-match-p "Why is this here\\?" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-command-reuses-existing-session-buffer ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (existing (chat-session-create "Existing" 'kimi))
          (chat--last-session-id (chat-session-id existing))
          (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (chat--open-session existing)
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (chat-quote-current-file)
             (should (get-buffer "*chat:Existing*"))
             (with-current-buffer "*chat:Existing*"
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-ui--input-overlay)
                              (point-max))))
                 (should (string-match-p "Kind: current-file" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-quote-current-file-propagates-oversized-file-error ()
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir)
         (chat--last-session-id nil)
         (chat-reading-current-file-max-lines 1)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-quote-current-file) :type 'user-error)
         (kill-buffer (current-buffer)))))))

;; ------------------------------------------------------------------
;; Utility Functions
;; ------------------------------------------------------------------

(ert-deftest chat-version-returns-string ()
  "Test that chat-version returns version string."
  (let ((version (chat-version)))
    (should (stringp version))
    (should (> (length version) 0))))

(ert-deftest chat-registers-core-file-tools ()
  "Test that loading chat registers built in file tools."
  (should (chat-tool-forge-get 'files_read))
  (should (chat-tool-forge-get 'files_patch))
  (should (chat-tool-forge-get 'apply_patch))
  (should (chat-tool-forge-get 'files_write)))

(provide 'test-chat)
;;; test-chat.el ends here
