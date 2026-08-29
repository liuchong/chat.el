;;; chat-session-export.el --- Privacy-safe session exports -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, sessions, export

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Produce a stable, user-readable transcript without copying the private
;; runtime record.  System prompts, reasoning, tool traffic, raw transport
;; payloads, and session metadata are deliberately outside this projection.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-session)

(defgroup chat-session-export nil
  "Privacy-safe session transcript exports."
  :group 'chat-session)

(defcustom chat-session-export-directory nil
  "Default directory for exported session transcripts.
When nil, use `default-directory'."
  :type '(choice (const :tag "Current directory" nil) directory)
  :group 'chat-session-export)

(defconst chat-session-export-schema-version 1
  "Version of the public Markdown transcript projection.")

(defun chat-session-export--single-line (value)
  "Return VALUE as a safe single display line."
  (let ((text (if (stringp value) value (format "%s" (or value "")))))
    (string-trim
     (replace-regexp-in-string "[[:cntrl:]\n\r]+" " " text))))

(defun chat-session-export--markdown-text (value)
  "Escape Markdown punctuation in single-line VALUE."
  (mapconcat
   (lambda (character)
     (if (memq character '(?\\ ?` ?* ?_ ?\[ ?\]))
         (concat "\\" (char-to-string character))
       (char-to-string character)))
   (string-to-list (chat-session-export--single-line value))
   ""))

(defun chat-session-export--timestamp (time)
  "Return TIME in a deterministic UTC representation."
  (and time (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t)))

(defun chat-session-export--model (session)
  "Return the public model label for SESSION."
  (let ((provider (chat-session-model-id session))
        (model (chat-session-model-name session)))
    (if (and (stringp model) (not (string-empty-p model)))
        (format "%s / %s" provider model)
      (format "%s" provider))))

(defun chat-session-export--attachment-lines (message)
  "Return public attachment summary lines for MESSAGE.
Payload paths, content hashes, metadata, and bytes are not included."
  (let (lines)
    (dolist (part (chat-message-parts message))
      (when (memq (chat-content-part-type part) '(image file))
        (push (format "- Attachment: %s (%s, %d bytes)"
                      (chat-session-export--markdown-text
                       (chat-content-part-name part))
                      (chat-session-export--markdown-text
                       (chat-content-part-mime-type part))
                      (chat-content-part-size part))
              lines)))
    (nreverse lines)))

(defun chat-session-export--message-body (message)
  "Return the public body for MESSAGE, or nil when it is empty."
  (let* ((text (chat-message-text message))
         (attachments (chat-session-export--attachment-lines message))
         (pieces (append (unless (string-empty-p (or text "")) (list text))
                         (when attachments
                           (list (string-join attachments "\n"))))))
    (when pieces (string-join pieces "\n\n"))))

(defun chat-session-export--public-message-p (message)
  "Return non-nil when MESSAGE belongs in the public transcript."
  (memq (chat-message-role message) '(:user :assistant)))

(defun chat-session-export--render-message (message)
  "Return the public Markdown projection of MESSAGE, or nil."
  (when-let* ((body (chat-session-export--message-body message)))
    (format "## %s%s\n\n%s"
            (if (eq (chat-message-role message) :user) "User" "Assistant")
            (if-let* ((stamp (chat-session-export--timestamp
                              (chat-message-timestamp message))))
                (format " - %s" stamp)
              "")
            body)))

(defun chat-session-export-markdown (session)
  "Return a deterministic, privacy-safe Markdown export of SESSION.

Only ordinary user and assistant text plus bounded attachment summaries
are included.  Internal prompts, reasoning, tool calls and results, raw
transport data, approval state, working paths, and metadata are omitted."
  (unless (chat-session-p session)
    (signal 'wrong-type-argument (list 'chat-session-p session)))
  (let* ((raw-title (chat-session-export--single-line
                     (chat-session-name session)))
         (title (if (string-empty-p raw-title) "Session" raw-title))
         (header
          (delq nil
                (list
                 (format "# %s" (chat-session-export--markdown-text title))
                 (format "Export schema: %d" chat-session-export-schema-version)
                 (format "Session ID: %s"
                         (chat-session-export--markdown-text
                          (chat-session-id session)))
                 (format "Model: %s"
                         (chat-session-export--markdown-text
                          (chat-session-export--model session)))
                 (when-let* ((created (chat-session-export--timestamp
                                       (chat-session-created-at session))))
                   (format "Created: %s" created))
                 (when-let* ((updated (chat-session-export--timestamp
                                       (chat-session-updated-at session))))
                   (format "Updated: %s" updated))
                 (when-let* ((parent (chat-session-parent-session-id session)))
                   (format "Parent session: %s"
                           (chat-session-export--markdown-text parent)))
                 (when-let* ((branch (chat-session-branch-id session)))
                   (format "Branch: %s"
                           (chat-session-export--markdown-text branch))))))
         (messages
          (delq nil
                (mapcar (lambda (message)
                          (when (chat-session-export--public-message-p message)
                            (chat-session-export--render-message message)))
                        (chat-session-messages session)))))
    (concat (string-join header "\n\n")
            "\n\n---\n\n"
            (string-join messages "\n\n---\n\n")
            "\n")))

(defun chat-session-export-default-file-name (session)
  "Return a portable default Markdown file name for SESSION."
  (let* ((name (chat-session-export--single-line
                (or (chat-session-name session) "session")))
         (name (replace-regexp-in-string "[\\/:*?\"<>|]+" "-" name))
         (name (replace-regexp-in-string "[[:space:]]+" "-" name))
         (name (replace-regexp-in-string "-+" "-" name))
         (name (string-trim name "[-.]+" "[-.]+"))
         (name (if (string-empty-p name) "session" name)))
    (format "%s-%s.md" name (chat-session-id session))))

(defun chat-session-export-write (session filename &optional overwrite)
  "Atomically write SESSION's public transcript to FILENAME.
Refuse an existing destination unless OVERWRITE is non-nil.  Return the
absolute destination path after a successful rename."
  (let* ((filename (expand-file-name filename))
         (directory (file-name-directory filename))
         (temp-file nil))
    (unless (file-directory-p directory)
      (signal 'file-missing (list "Export directory does not exist" directory)))
    (when (and (file-exists-p filename) (not overwrite))
      (signal 'file-already-exists (list filename)))
    (setq temp-file (make-temp-file
                     (expand-file-name ".chat-session-export-" directory)
                     nil ".md"))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file temp-file
              (insert (chat-session-export-markdown session))))
          (rename-file temp-file filename overwrite)
          (setq temp-file nil)
          filename)
      (when (and temp-file (file-exists-p temp-file))
        (delete-file temp-file)))))

(defun chat-session-export-interactive (session)
  "Prompt for a destination and export SESSION.
Return the exported file, or signal `user-error' when SESSION is nil."
  (unless (chat-session-p session)
    (user-error "No session to export"))
  (let* ((directory (file-name-as-directory
                     (expand-file-name
                      (or chat-session-export-directory default-directory))))
         (filename
          (read-file-name "Export session: " directory nil nil
                          (chat-session-export-default-file-name session)))
         (overwrite
          (and (file-exists-p filename)
               (yes-or-no-p (format "Overwrite %s? " filename)))))
    (when (and (file-exists-p filename) (not overwrite))
      (user-error "Export cancelled"))
    (let ((written (chat-session-export-write session filename overwrite)))
      (message "Session exported to %s" written)
      written)))

(provide 'chat-session-export)
;;; chat-session-export.el ends here
