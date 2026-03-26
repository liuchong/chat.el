;;; chat-code-lsp.el --- LSP integration for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This module integrates with LSP clients (lsp-mode or eglot)
;; to provide enhanced code intelligence.

;;; Code:

(require 'cl-lib)

;; ------------------------------------------------------------------
;; Detection
;; ------------------------------------------------------------------

(defun chat-code-lsp--detect-client ()
  "Detect which LSP client is available.
Returns 'lsp-mode, 'eglot, or nil."
  (cond
   ((and (fboundp 'lsp-mode) lsp-mode) 'lsp-mode)
   ((and (fboundp 'eglot--managed-mode) eglot--managed-mode) 'eglot)
   ((featurep 'lsp-mode) 'lsp-mode)
   ((featurep 'eglot) 'eglot)
   (t nil)))

(defun chat-code-lsp-available-p ()
  "Check if LSP is available in current buffer."
  (not (null (chat-code-lsp--detect-client))))

;; ------------------------------------------------------------------
;; Symbol Information
;; ------------------------------------------------------------------

(defun chat-code-lsp-get-symbol-at-point ()
  "Get symbol information at point from LSP.
Returns plist with :name, :kind, :range, :container-name."
  (let ((client (chat-code-lsp--detect-client)))
    (pcase client
      ('lsp-mode (chat-code-lsp--symbol-lsp-mode))
      ('eglot (chat-code-lsp--symbol-eglot))
      (_ nil))))

(defun chat-code-lsp--symbol-lsp-mode ()
  "Get symbol info from lsp-mode."
  (when (fboundp 'lsp-get-symbol-at-point)
    (let* ((sym (lsp-get-symbol-at-point))
           (name (when sym (plist-get sym :name)))
           (kind (when sym (plist-get sym :kind))))
      (when name
        (list :name name
              :kind kind
              :range (plist-get sym :range)
              :container-name (plist-get sym :containerName))))))

(defun chat-code-lsp--symbol-eglot ()
  "Get symbol info from eglot."
  (when (fboundp 'eglot--current-server)
    (let ((server (eglot--current-server)))
      (when server
        ;; Eglot doesn't have a direct symbol-at-point function
        ;; We can use imenu or similar
        (let ((sym (thing-at-point 'symbol)))
          (when sym
            (list :name sym
                  :kind nil
                  :range nil
                  :container-name nil)))))))

;; ------------------------------------------------------------------
;; Diagnostics
;; ------------------------------------------------------------------

(defun chat-code-lsp-get-diagnostics (file-path)
  "Get LSP diagnostics for FILE-PATH.
Returns list of plists with :message, :severity, :line, :column."
  (let ((client (chat-code-lsp--detect-client)))
    (pcase client
      ('lsp-mode (chat-code-lsp--diagnostics-lsp-mode file-path))
      ('eglot (chat-code-lsp--diagnostics-eglot file-path))
      (_ nil))))

(defun chat-code-lsp--diagnostics-lsp-mode (file-path)
  "Get diagnostics from lsp-mode."
  (when (and (fboundp 'lsp-diagnostics)
             (fboundp 'lsp--workspace-diagnostics))
    (let ((diags (gethash file-path (lsp--workspace-diagnostics
                                     (lsp--read-workspace)))))
      (mapcar (lambda (diag)
                (list :message (plist-get diag :message)
                      :severity (plist-get diag :severity)
                      :line (plist-get (plist-get diag :range) :line)
                      :column (plist-get (plist-get diag :range) :character)))
              diags))))

(defun chat-code-lsp--diagnostics-eglot (file-path)
  "Get diagnostics from eglot."
  (when (fboundp 'eglot--diagnostics)
    (let ((diags (gethash file-path eglot--diagnostics)))
      (mapcar (lambda (diag)
                (list :message (flymake-diagnostic-text diag)
                      :severity (pcase (flymake-diagnostic-type diag)
                                  ('eglot-error 1)
                                  ('eglot-warning 2)
                                  (_ 3))
                      :line (1- (line-number-at-pos
                                 (flymake-diagnostic-beg diag)))
                      :column (save-excursion
                                (goto-char (flymake-diagnostic-beg diag))
                                (current-column))))
              diags))))

;; ------------------------------------------------------------------
;; Hover Information
;; ------------------------------------------------------------------

(defun chat-code-lsp-hover-info ()
  "Get hover information at point from LSP."
  (let ((client (chat-code-lsp--detect-client)))
    (pcase client
      ('lsp-mode (when (fboundp 'lsp-hover)
                   (lsp-hover)))
      ('eglot (when (fboundp 'eglot-help-at-point)
                (eglot-help-at-point)))
      (_ nil))))

;; ------------------------------------------------------------------
;; Context Integration
;; ------------------------------------------------------------------

(defun chat-code-lsp-get-context ()
  "Get LSP context for current buffer.
Returns plist with :symbol, :diagnostics, :hover."
  (let* ((symbol (chat-code-lsp-get-symbol-at-point))
         (file (buffer-file-name))
         (diagnostics (when file
                        (chat-code-lsp-get-diagnostics file)))
         (hover (chat-code-lsp-hover-info)))
    (when (or symbol diagnostics hover)
      (list :symbol symbol
            :diagnostics diagnostics
            :hover hover))))

(defun chat-code-lsp-format-context (context)
  "Format LSP CONTEXT for LLM prompt."
  (let ((result ""))
    ;; Add symbol info
    (when (plist-get context :symbol)
      (let ((sym (plist-get context :symbol)))
        (setq result (concat result ";; Current Symbol:\n"))
        (setq result (concat result (format ";;   Name: %s\n"
                                            (plist-get sym :name))))
        (when (plist-get sym :container-name)
          (setq result (concat result (format ";;   Container: %s\n"
                                              (plist-get sym :container-name)))))))
    ;; Add diagnostics
    (when (plist-get context :diagnostics)
      (let ((diags (plist-get context :diagnostics)))
        (when diags
          (setq result (concat result "\n;; Diagnostics:\n"))
          (dolist (diag (cl-subseq diags 0 (min 5 (length diags))))
            (setq result (concat result (format ";;   Line %d: %s\n"
                                                (plist-get diag :line)
                                                (plist-get diag :message))))))))
    result))

;; ------------------------------------------------------------------
;; Commands
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-code-lsp-show-info ()
  "Show LSP information at point."
  (interactive)
  (let ((info (chat-code-lsp-get-context)))
    (if info
        (message "LSP Info:\n%s" (chat-code-lsp-format-context info))
      (message "No LSP information available"))))

(provide 'chat-code-lsp)
;;; chat-code-lsp-lsp.el ends here
