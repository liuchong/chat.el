;;; chat-session-index.el --- What sessions exist -*- lexical-binding: t; -*-

;;; Commentary:

;; Answering "what sessions are there" without reading all of them.
;;
;; `chat-session-list' answers it by loading every session file in full and
;; sorting the results, so the cost of naming a session is the cost of
;; parsing every message of every session ever held.  With sessions that
;; reach hundreds of kilobytes that is seconds of parsing to draw a list of
;; titles.
;;
;; So: one line per session in one file, holding what a list needs -- id,
;; title, model, timestamps, counts, sizes -- and nothing a list does not.
;;
;; The index is a cache, not a record.  It is derived entirely from the
;; session files, `chat-session-index-rebuild' reconstructs it from them,
;; and a reader that finds it missing or stale falls back to reading the
;; sessions.  This matters because an index that is the only copy of
;; something becomes a thing that can be lost; this one cannot be, which is
;; why it can be written cheaply and without ceremony.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'chat-log)

(declare-function chat-session-id "chat-session" (session))
(declare-function chat-session-name "chat-session" (session))
(declare-function chat-session-model-id "chat-session" (session))
(declare-function chat-session-model-name "chat-session" (session))
(declare-function chat-session-created-at "chat-session" (session))
(declare-function chat-session-updated-at "chat-session" (session))
(declare-function chat-session-messages "chat-session" (session))
(declare-function chat-message-role "chat-session" (message))
(declare-function chat-session-load "chat-session" (id))
(declare-function chat-session-list "chat-session" ())
(declare-function chat-session--file-name "chat-session" (id))
(declare-function chat-session-wire-file "chat-session-wire" (id))

(defconst chat-session-index-schema-version 1
  "Version of the session index record shape.")

(defcustom chat-session-index-enabled t
  "Whether session metadata is cached in an index file."
  :type 'boolean
  :group 'chat-session)

(defun chat-session-index-file ()
  "Return the session index file.

Beside the session directory rather than inside it, for the reason
`chat-session-wire--directory' gives: everything ending in `.jsonl' in
that directory is offered to `chat-session-load' as a session, and the
index would be offered to it by the very rebuild that reads it."
  (expand-file-name
   "index.jsonl"
   (file-name-directory
    (directory-file-name
     (if (boundp 'chat-session-directory)
         (symbol-value 'chat-session-directory)
       (expand-file-name "~/.chat/sessions/"))))))

(defun chat-session-index--seconds (time)
  "Return TIME as whole seconds since the epoch, or nil."
  (and time (ignore-errors (floor (float-time time)))))

(defun chat-session-index--file-size (file)
  "Return the size of FILE, or 0 if it is not there."
  (if (and file (file-exists-p file))
      (file-attribute-size (file-attributes file))
    0))

(defun chat-session-index-entry (session)
  "Return the index record for SESSION.

Turn count rather than message count, because a turn is what a reader
counts when judging how much a session holds: one turn is one thing the
user asked, however many messages it took to answer."
  (let ((messages (chat-session-messages session)))
    (list (cons 'schema_version chat-session-index-schema-version)
          (cons 'session_id (chat-session-id session))
          (cons 'title (or (chat-session-name session) ""))
          (cons 'provider (format "%s" (or (chat-session-model-id session) "")))
          (cons 'model (or (chat-session-model-name session) ""))
          (cons 'created_at (chat-session-index--seconds
                             (chat-session-created-at session)))
          (cons 'updated_at (chat-session-index--seconds
                             (chat-session-updated-at session)))
          (cons 'message_count (length messages))
          (cons 'turn_count
                (cl-count-if (lambda (message)
                               (eq (chat-message-role message) :user))
                             messages))
          (cons 'context_bytes
                (chat-session-index--file-size
                 (chat-session--file-name (chat-session-id session))))
          (cons 'wire_bytes
                (chat-session-index--file-size
                 (chat-session-wire-file (chat-session-id session)))))))

(defun chat-session-index-read ()
  "Return index records, newest first, skipping lines that do not parse.

Later records win for the same session: the file is append-only, so an
updated session appears again rather than in place."
  (let ((file (chat-session-index-file))
        (by-id (make-hash-table :test 'equal))
        (order nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p line)
              (when-let* ((record (condition-case nil
                                      (let ((json-object-type 'alist)
                                            (json-array-type 'list)
                                            (json-key-type 'symbol))
                                        (json-read-from-string line))
                                    (error nil)))
                          (id (alist-get 'session_id record)))
                (unless (gethash id by-id) (push id order))
                (puthash id record by-id))))
          (forward-line 1))))
    (sort (mapcar (lambda (id) (gethash id by-id)) (nreverse order))
          (lambda (a b) (> (or (alist-get 'updated_at a) 0)
                           (or (alist-get 'updated_at b) 0))))))

(defvar chat-session-index--written (make-hash-table :test 'equal)
  "Session id to the last summary written, so unchanged ones are skipped.")

(defun chat-session-index--summary (entry)
  "Return the part of ENTRY a session list actually shows.

Message count and timestamps are left out on purpose.  A save happens per
message, so keying on them would write an index line per message of every
turn; keying on what a list displays writes one per turn, which is the
granularity at which the list changes."
  (list (alist-get 'title entry)
        (alist-get 'provider entry)
        (alist-get 'model entry)
        (alist-get 'turn_count entry)))

(defun chat-session-index-update (session)
  "Append SESSION's current metadata to the index, if it has changed.

Appended rather than rewritten in place: rewriting means holding the
whole index to change one line, and the index is compacted when it is
rebuilt, which happens often enough that duplicate lines never accumulate
into a cost."
  (when (and chat-session-index-enabled session)
    (condition-case err
        (let* ((entry (chat-session-index-entry session))
               (id (alist-get 'session_id entry))
               (summary (chat-session-index--summary entry)))
          (if (equal summary (gethash id chat-session-index--written))
              t
            (puthash id summary chat-session-index--written)
            (chat-session-index--append entry)))
      (error
       (chat-log "[INDEX] Could not update: %s" (error-message-string err))
       nil))))

(defun chat-session-index--append (entry)
  "Append ENTRY to the index file."
  (let ((file (chat-session-index-file))
        (coding-system-for-write 'utf-8))
    (unless (file-directory-p (file-name-directory file))
      (make-directory (file-name-directory file) t))
    (write-region (concat (json-encode entry) "\n") nil file t 'silent)
    t))

(defun chat-session-index-rebuild ()
  "Rebuild the index from the session files and return how many it found.

The reason the index may be treated as disposable."
  (let ((sessions (chat-session-list))
        (file (chat-session-index-file)))
    (unless (file-directory-p (file-name-directory file))
      (make-directory (file-name-directory file) t))
    (with-temp-file file
      (dolist (session sessions)
        (insert (json-encode (chat-session-index-entry session)) "\n")))
    (clrhash chat-session-index--written)
    (length sessions)))

;;;###autoload
(defun chat-session-index-install ()
  "Keep the session index current as sessions are saved."
  (add-hook 'chat-session-after-save-functions #'chat-session-index-update))

(provide 'chat-session-index)
;;; chat-session-index.el ends here
