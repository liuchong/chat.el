;;; chat-plugin-emacs.el --- Emacs-native agent tools -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Plugin that exposes live Emacs capabilities as agent tools: buffers,
;; imenu, xref, and project.el.  These are the host features a CLI
;; agent cannot copy.  All tools are read-only.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'subr-x)
(require 'seq)
(require 'chat-plugin)
(require 'chat-tool-forge)

(defun chat-plugin-emacs--line (value)
  "Coerce VALUE to a 1-based line number or nil."
  (cond
   ((integerp value) value)
   ((numberp value) (truncate value))
   ((and (stringp value) (string-match-p "\\`[0-9]+\\'" value))
    (string-to-number value))
   (t nil)))

(defcustom chat-plugin-emacs-sensitive-buffer-patterns
  '("authinfo" "\\.gpg\\'" "\\.netrc\\'" "\\.env\\'" "password" "secret" "token")
  "Buffer name or file name patterns that Emacs tools never expose."
  :type '(repeat regexp)
  :group 'chat-plugin)

(defcustom chat-plugin-emacs-allow-all-buffers nil
  "When non-nil, allow read-only Emacs tools to inspect any non-sensitive buffer."
  :type 'boolean
  :group 'chat-plugin)

(defun chat-plugin-emacs--project-root ()
  "Return the current project root, or nil."
  (when-let ((project (ignore-errors (project-current))))
    (file-truename (project-root project))))

(defun chat-plugin-emacs--sensitive-buffer-p (buffer)
  "Return non-nil when BUFFER matches a hard deny pattern."
  (with-current-buffer buffer
    (let ((values (delq nil (list (buffer-name) buffer-file-name))))
      (seq-some
       (lambda (pattern)
         (seq-some (lambda (value)
                     (string-match-p pattern value))
                   values))
       chat-plugin-emacs-sensitive-buffer-patterns))))

(defun chat-plugin-emacs--buffer-in-project-p (buffer)
  "Return non-nil when BUFFER visits a file under the current project."
  (let ((root (chat-plugin-emacs--project-root)))
    (and root
         (buffer-live-p buffer)
         (with-current-buffer buffer
           (and buffer-file-name
                (string-prefix-p root
                                 (file-truename buffer-file-name)))))))

(defun chat-plugin-emacs--buffer-visible-p (buffer)
  "Return non-nil when BUFFER may be listed or read by Emacs tools."
  (and (buffer-live-p buffer)
       (not (string-prefix-p " " (buffer-name buffer)))
       (not (chat-plugin-emacs--sensitive-buffer-p buffer))
       (or chat-plugin-emacs-allow-all-buffers
           (eq buffer (current-buffer))
           (chat-plugin-emacs--buffer-in-project-p buffer))))

(defun chat-plugin-emacs--buffer-listable-p (buffer)
  "Return non-nil when BUFFER may be included in buffer listings."
  (and (buffer-live-p buffer)
       (not (string-prefix-p " " (buffer-name buffer)))
       (not (chat-plugin-emacs--sensitive-buffer-p buffer))
       (or chat-plugin-emacs-allow-all-buffers
           (and (eq buffer (current-buffer))
                (with-current-buffer buffer
                  (null buffer-file-name)))
           (chat-plugin-emacs--buffer-in-project-p buffer))))

(defun chat-plugin-emacs--readable-buffer (name)
  "Return the readable buffer named NAME, or signal a user-facing error."
  (let ((buffer (or (and (stringp name) (get-buffer name))
                    (current-buffer))))
    (unless (buffer-live-p buffer)
      (error "Buffer not found: %s" name))
    (unless (chat-plugin-emacs--buffer-visible-p buffer)
      (error "Buffer access denied: %s" (buffer-name buffer)))
    buffer))

(defun chat-plugin-emacs--register-tool (id name description parameters fn)
  "Register a read-only Emacs tool ID."
  (chat-plugin-register-tool
   (make-chat-forged-tool
    :id id
    :name name
    :description description
    :language 'elisp
    :parameters parameters
    :sensitivity 'project
    :effects '(read)
    :compiled-function fn
    :is-active t
    :usage-count 0)))

(defun chat-plugin-emacs--buffers ()
  "Return a compact listing of live file and named buffers."
  (let (rows)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (chat-plugin-emacs--buffer-listable-p buffer)
          (push (format "%s%s%s"
                        (buffer-name)
                        (if (buffer-modified-p) " *" "")
                        (if buffer-file-name
                            (format "  %s" buffer-file-name)
                          ""))
                rows))))
    (mapconcat #'identity (nreverse rows) "\n")))

(defun chat-plugin-emacs--read-buffer (name &optional start-line end-line)
  "Read buffer NAME, optionally from START-LINE to END-LINE."
  (let ((buffer (chat-plugin-emacs--readable-buffer name)))
    (with-current-buffer buffer
      (save-restriction
        (widen)
        (let* ((start (if (and (natnump start-line) (> start-line 0))
                          (save-excursion
                            (goto-char (point-min))
                            (forward-line (1- start-line))
                            (point))
                        (point-min)))
               (end (if (and (natnump end-line) (> end-line 0))
                        (save-excursion
                          (goto-char (point-min))
                          (forward-line end-line)
                          (point))
                      (point-max)))
               (text (buffer-substring-no-properties start end)))
          (when (> (length text) 16000)
            (setq text (concat (substring text 0 16000)
                               "\n... [truncated]")))
          (format "Buffer %s (%s:%d-%d)\n%s"
                  (buffer-name)
                  (or buffer-file-name "no-file")
                  (line-number-at-pos start)
                  (line-number-at-pos (max start (1- end)))
                  text))))))

(defun chat-plugin-emacs--imenu (name)
  "Return imenu entries for buffer NAME."
  (let ((buffer (chat-plugin-emacs--readable-buffer name)))
    (with-current-buffer buffer
      (require 'imenu)
      (condition-case err
          (let ((index (save-excursion
                         (imenu--make-index-alist t))))
            (setq index (or (remove (assoc "*Rescan*" index) index) index))
            (if (null index)
                (format "No imenu entries in %s" (buffer-name))
              (mapconcat
               (lambda (entry)
                 (cond
                  ((and (consp entry) (number-or-marker-p (cdr entry)))
                   (format "%s:%s" (car entry)
                           (line-number-at-pos (cdr entry))))
                  ((and (consp entry) (listp (cdr entry)))
                   (format "%s/" (car entry)))
                  (t (format "%s" entry))))
               index
               "\n")))
        (error (format "imenu failed: %s" (error-message-string err)))))))

(defun chat-plugin-emacs--xref (identifier)
  "Find definitions of IDENTIFIER through xref."
  (require 'xref)
  (let* ((ident (or identifier (xref-backend-identifier-at-point
                                (xref-find-backend))))
         (defs (ignore-errors
                 (xref-backend-definitions (xref-find-backend) ident)))
         (rows nil))
    (unless ident
      (error "No identifier"))
    (dolist (item defs)
      (let* ((loc (xref-item-location item))
             (group (xref-location-group loc))
             (line (ignore-errors (xref-location-line loc))))
        (push (format "%s:%s  %s"
                      group
                      (or line "?")
                      (substring-no-properties (xref-item-summary item)))
              rows)))
    (if rows
        (mapconcat #'identity (nreverse rows) "\n")
      (format "No xref definitions for %s" ident))))

(defun chat-plugin-emacs--project ()
  "Describe the current project.el project."
  (require 'project)
  (let ((project (project-current)))
    (if (not project)
        "No current project"
      (let* ((root (project-root project))
             (buffers (ignore-errors (project-buffers project)))
             (names (mapcar #'buffer-name (or buffers nil))))
        (format "root: %s\nbuffers: %d\n%s"
                root
                (length names)
                (mapconcat #'identity
                           (seq-take names 80)
                           "\n"))))))

(defun chat-plugin-emacs-setup (_ctx)
  "Register Emacs-native tools."
  (chat-plugin-emacs--register-tool
   'emacs_buffers "Emacs buffers"
   "List live Emacs buffers with file names and modified flags."
   nil
   (lambda (&rest _) (chat-plugin-emacs--buffers)))
  (chat-plugin-emacs--register-tool
   'emacs_read_buffer "Emacs read buffer"
   "Read a live Emacs buffer. Use name for the buffer name, optional start_line and end_line."
   '((:name "name" :type "string" :required nil)
     (:name "start_line" :type "integer" :required nil)
     (:name "end_line" :type "integer" :required nil))
   (lambda (name &optional start-line end-line)
     (chat-plugin-emacs--read-buffer
      name
      (chat-plugin-emacs--line start-line)
      (chat-plugin-emacs--line end-line))))
  (chat-plugin-emacs--register-tool
   'emacs_imenu "Emacs imenu"
   "List imenu symbols in a live buffer."
   '((:name "name" :type "string" :required nil))
   (lambda (&optional name) (chat-plugin-emacs--imenu name)))
  (chat-plugin-emacs--register-tool
   'emacs_xref "Emacs xref"
   "Find definitions of an identifier with Emacs xref."
   '((:name "identifier" :type "string" :required t))
   (lambda (identifier) (chat-plugin-emacs--xref identifier)))
  (chat-plugin-emacs--register-tool
   'emacs_project "Emacs project"
   "Describe the current project.el project root and open buffers."
   nil
   (lambda (&rest _) (chat-plugin-emacs--project)))
  (chat-plugin-provide 'emacs t))

(defun chat-plugin-emacs-teardown (_ctx)
  "Deactivate Emacs-native tools."
  (dolist (id '(emacs_buffers emacs_read_buffer emacs_imenu
                emacs_xref emacs_project))
    (when-let ((tool (chat-tool-forge-get id)))
      (setf (chat-forged-tool-is-active tool) nil))))

(chat-plugin-define
 'emacs
 :description "Expose live Emacs buffers, imenu, xref, and project.el."
 :inject '(chat-tool-forge)
 :setup #'chat-plugin-emacs-setup
 :teardown #'chat-plugin-emacs-teardown)

(provide 'chat-plugin-emacs)
;;; chat-plugin-emacs.el ends here
