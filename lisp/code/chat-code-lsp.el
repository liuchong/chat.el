;;; chat-code-lsp.el --- Public Emacs semantic adapter -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This adapter deliberately talks only to public Emacs APIs.  An already
;; active semantic service can surface through xref, imenu and flymake, but
;; this module never starts a service and never inspects client internals.

;;; Code:

(require 'cl-lib)
(require 'imenu)
(require 'xref)
(require 'flymake)
(require 'subr-x)
(require 'chat-code-intelligence)

(declare-function treesit-node-at "treesit" (position &optional parser-or-lang named))
(declare-function treesit-node-type "treesit" (node))
(declare-function treesit-node-start "treesit" (node))
(declare-function treesit-node-end "treesit" (node))
(declare-function treesit-parser-list "treesit" (&optional buffer))

(defun chat-code-lsp--request-buffer (request)
  "Return an existing semantic buffer for REQUEST."
  (let ((buffer (plist-get request :buffer))
        (path (plist-get request :path)))
    (cond
     ((buffer-live-p buffer) buffer)
     ((and path (find-buffer-visiting path)))
     (t nil))))

(defun chat-code-lsp--xref-backend (buffer)
  "Return the public xref backend active in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (ignore-errors (xref-find-backend)))))

(defun chat-code-lsp--imenu-available-p (buffer)
  "Return non-nil when BUFFER can produce an imenu index."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (or imenu-create-index-function
             (derived-mode-p 'prog-mode)))))

(defun chat-code-lsp-available-p (&optional buffer)
  "Return non-nil when BUFFER has public semantic information.

BUFFER defaults to the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (or (chat-code-lsp--xref-backend buffer)
             (chat-code-lsp--imenu-available-p buffer)
             (with-current-buffer buffer
               (and (bound-and-true-p flymake-mode)
                    (fboundp 'flymake-diagnostics)))
             (and (fboundp 'treesit-parser-list)
                  (treesit-parser-list buffer))))))

(defun chat-code-lsp--available-p (request operation)
  "Return non-nil when public APIs can answer OPERATION for REQUEST."
  (let ((buffer (chat-code-lsp--request-buffer request)))
    (pcase operation
      ((or 'definition 'references)
       (chat-code-lsp--xref-backend buffer))
      ('symbols (chat-code-lsp--imenu-available-p buffer))
      ('diagnostics
       (and (buffer-live-p buffer)
            (with-current-buffer buffer (bound-and-true-p flymake-mode))))
      (_ nil))))

(defun chat-code-lsp--position (request buffer)
  "Return REQUEST position constrained to BUFFER."
  (with-current-buffer buffer
    (max (point-min) (min (point-max) (or (plist-get request :position) (point))))))

(defun chat-code-lsp--identifier (request buffer)
  "Return the identifier requested by REQUEST in BUFFER."
  (or (plist-get request :symbol)
      (with-current-buffer buffer
        (save-excursion
          (goto-char (chat-code-lsp--position request buffer))
          (thing-at-point 'symbol t)))))

(defun chat-code-lsp--xref-item (item name kind)
  "Convert xref ITEM for NAME and KIND to a facade item."
  (condition-case nil
      (let* ((location (xref-item-location item))
             (marker (xref-location-marker location))
             (buffer (and (markerp marker) (marker-buffer marker)))
             (path (or (and buffer (buffer-file-name buffer))
                       (xref-location-group location))))
        (when (and path marker buffer)
          (with-current-buffer buffer
            (save-excursion
              (goto-char marker)
              (list :path path
                    :line (line-number-at-pos)
                    :column (current-column)
                    :name name
                    :kind kind
                    :confidence 0.96
                    :source 'xref
                    :detail (xref-item-summary item))))))
    (error nil)))

(defun chat-code-lsp--query-xref (request operation buffer)
  "Query public xref for REQUEST OPERATION in BUFFER."
  (let* ((backend (chat-code-lsp--xref-backend buffer))
         (identifier (chat-code-lsp--identifier request buffer)))
    (if (or (null backend) (string-empty-p (or identifier "")))
        (list :status 'unavailable :reason "No active xref backend or identifier")
      (condition-case err
          (let* ((raw (pcase operation
                        ('definition (xref-backend-definitions backend identifier))
                        ('references (xref-backend-references backend identifier))))
                 (items (delq nil
                              (mapcar
                               (lambda (item)
                                 (chat-code-lsp--xref-item item identifier operation))
                               raw))))
            (list :status (if items 'ok 'empty)
                  :revision (format "buffer-%d" (buffer-chars-modified-tick buffer))
                  :items items))
        (error (list :status 'error :reason (error-message-string err)))))))

(defun chat-code-lsp--flatten-imenu (index path &optional prefix)
  "Flatten imenu INDEX from PATH, adding optional PREFIX."
  (let (items)
    (dolist (entry index)
      (when (and (consp entry) (stringp (car entry)))
        (let ((name (if prefix (concat prefix "." (car entry)) (car entry)))
              (location (cdr entry)))
          (cond
           ((and (listp location) (not (markerp location)))
            (setq items
                  (nconc items (chat-code-lsp--flatten-imenu location path name))))
           ((or (markerp location) (integer-or-marker-p location))
            (let ((position (if (markerp location) (marker-position location) location)))
              (save-excursion
                (goto-char position)
                (push (list :path path
                            :line (line-number-at-pos)
                            :column (current-column)
                            :name name
                            :kind 'symbol
                            :confidence 0.88
                            :source 'imenu)
                      items))))))))
    items))

(defun chat-code-lsp--query-symbols (buffer)
  "Return public imenu symbols from BUFFER."
  (with-current-buffer buffer
    (condition-case err
        (let* ((creator (or imenu-create-index-function
                            #'imenu-default-create-index-function))
               (index (funcall creator))
               (items (chat-code-lsp--flatten-imenu index (buffer-file-name buffer))))
          (list :status (if items 'ok 'empty)
                :revision (format "buffer-%d" (buffer-chars-modified-tick))
                :items items))
      (error (list :status 'error :reason (error-message-string err))))))

(defun chat-code-lsp--diagnostic-item (diagnostic buffer)
  "Convert Flymake DIAGNOSTIC in BUFFER to a facade item."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (flymake-diagnostic-beg diagnostic))
      (list :path (buffer-file-name buffer)
            :line (line-number-at-pos)
            :column (current-column)
            :name (flymake-diagnostic-text diagnostic)
            :kind (flymake-diagnostic-type diagnostic)
            :confidence 1.0
            :source 'flymake
            :detail (flymake-diagnostic-text diagnostic)))))

(defun chat-code-lsp--query-diagnostics (buffer)
  "Return public Flymake diagnostics for BUFFER."
  (with-current-buffer buffer
    (condition-case err
        (let ((items (mapcar
                      (lambda (diagnostic)
                        (chat-code-lsp--diagnostic-item diagnostic buffer))
                      (flymake-diagnostics))))
          (list :status (if items 'ok 'empty)
                :revision (format "buffer-%d" (buffer-chars-modified-tick))
                :items items))
      (error (list :status 'error :reason (error-message-string err))))))

(defun chat-code-lsp--query (request operation callback)
  "Answer REQUEST OPERATION asynchronously through public Emacs APIs."
  (let ((buffer (chat-code-lsp--request-buffer request)))
    (run-at-time
     0 nil
     (lambda ()
       (funcall
        callback
        (if (not (buffer-live-p buffer))
            (list :status 'unavailable :reason "No existing file buffer")
          (pcase operation
            ((or 'definition 'references)
             (chat-code-lsp--query-xref request operation buffer))
            ('symbols (chat-code-lsp--query-symbols buffer))
            ('diagnostics (chat-code-lsp--query-diagnostics buffer))
            (_ (list :status 'unavailable
                     :reason "Operation is not exposed by public Emacs APIs")))))))))

(defun chat-code-lsp-backend ()
  "Return the public Emacs semantic backend descriptor."
  (make-chat-code-intelligence-backend
   :name 'xref
   :priority 10
   :operations '(definition references symbols diagnostics)
   :available #'chat-code-lsp--available-p
   :query #'chat-code-lsp--query))

;; Compatibility helpers for callers that only need current-buffer context.
(defun chat-code-lsp-get-symbol-at-point ()
  "Return public syntax information for the symbol at point."
  (let ((name (thing-at-point 'symbol t))
        node)
    (when (and (fboundp 'treesit-parser-list)
               (treesit-parser-list)
               (fboundp 'treesit-node-at))
      (setq node (ignore-errors (treesit-node-at (point) nil t))))
    (when name
      (list :name name
            :kind (and node (treesit-node-type node))
            :range (and node
                        (cons (treesit-node-start node)
                              (treesit-node-end node)))
            :container-name nil))))

(defun chat-code-lsp-get-diagnostics (_file-path)
  "Return public Flymake diagnostics for the current file buffer."
  (when (bound-and-true-p flymake-mode)
    (plist-get (chat-code-lsp--query-diagnostics (current-buffer)) :items)))

(defun chat-code-lsp-get-context ()
  "Return public semantic context for the current buffer."
  (let ((symbol (chat-code-lsp-get-symbol-at-point))
        (diagnostics (and (buffer-file-name)
                          (chat-code-lsp-get-diagnostics (buffer-file-name)))))
    (when (or symbol diagnostics)
      (list :symbol symbol :diagnostics diagnostics))))

(defun chat-code-lsp-format-context (context)
  "Format public semantic CONTEXT for an LLM prompt."
  (with-temp-buffer
    (when-let* ((symbol (plist-get context :symbol)))
      (insert (format ";; Current Symbol: %s\n" (plist-get symbol :name))))
    (when-let* ((diagnostics (plist-get context :diagnostics)))
      (insert ";; Diagnostics:\n")
      (dolist (diagnostic (seq-take diagnostics 5))
        (insert (format ";;   Line %d: %s\n"
                        (plist-get diagnostic :line)
                        (plist-get diagnostic :name)))))
    (buffer-string)))

;;;###autoload
(defun chat-code-lsp-show-info ()
  "Show public semantic information at point."
  (interactive)
  (if-let* ((info (chat-code-lsp-get-context)))
      (message "Code information:\n%s" (chat-code-lsp-format-context info))
    (message "No public semantic information available")))

(provide 'chat-code-lsp)
;;; chat-code-lsp.el ends here
