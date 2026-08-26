;;; chat-session-wire.el --- Per-session event stream -*- lexical-binding: t; -*-

;;; Commentary:

;; What a session did, in order, on disk.
;;
;; Three streams, three readers, and they were one file until now.  The
;; context stream -- `chat-session.el', `<id>.jsonl' -- holds what goes back
;; to the model: roles, final content, tool calls and results.  Diagnostics
;; -- `chat-log.el' -- hold what the program did to itself.  Between them sat
;; a gap: what actually happened during a run, in order, per session.
;;
;; That gap was being filled by appending free text to one global file for
;; every session at once.  It reached 119MB, 106.6MB of which was 77 copies
;; of a single conversation, because the clause reporting an unhandled agent
;; event printed the event and every event carries the run, and the run
;; carries the session.  Nothing about that file could be queried: no
;; session id, no turn, no schema, no rotation.
;;
;; So this is the third stream.  One file per session, one JSON object per
;; line, a fixed envelope around a typed payload.  A reader that meets a
;; kind it does not know skips the line, which is what lets a new event type
;; be added without changing anything that reads.
;;
;; The hard rule is that no unbounded value may enter it.  Large content is
;; already in the context stream, so this refers to it by id rather than
;; copying it, and a byte cap per record stands behind that as a backstop
;; for the day someone forgets.  Spec 009 has the reasoning.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'chat-log)

(defconst chat-session-wire-schema-version 1
  "Version of the wire record envelope.")

(defcustom chat-session-wire-enabled t
  "Whether sessions record their event stream to disk.

Off means a run leaves no trace of how it reached its answer, which is
what made \"why did this take three rounds\" unanswerable after the fact."
  :type 'boolean
  :group 'chat)

(defcustom chat-session-wire-max-bytes (* 32 1024 1024)
  "Bytes a session's event stream may reach before it is archived.

Not a limit anyone is expected to hit; a limit so that nobody has to
notice.  Measured on other tools on this machine, an event log left
uncapped reached 2.7GB."
  :type 'integer
  :group 'chat)

(defcustom chat-session-wire-max-record-bytes (* 64 1024)
  "Bytes one record may reach before its payload is replaced by a note.

The backstop for the rule that payloads stay bounded.  Records of 1.4MB
are what this exists to prevent, and they came from printing a structure
that reaches the whole session."
  :type 'integer
  :group 'chat)

(defvar chat-session-wire--sequences (make-hash-table :test 'equal)
  "Session id to the last sequence number written.")

(defvar chat-session-wire--sizes (make-hash-table :test 'equal)
  "Session id to bytes written, so a stat is not needed per record.")

(declare-function chat-session-directory-name "chat-session" ())

(defun chat-session-wire--directory ()
  "Return the directory holding event streams.

A directory of its own, under the session directory, rather than files
named alongside the sessions: `chat-session-list' finds sessions by
globbing `*.jsonl' and taking the base name, so a sibling stream would be
offered to `chat-session-load' as a session on every listing."
  (expand-file-name
   "wire/"
   (if (boundp 'chat-session-directory)
       (symbol-value 'chat-session-directory)
     (expand-file-name "~/.chat/sessions/"))))

(defun chat-session-wire-file (session-id)
  "Return the event stream file for SESSION-ID."
  (expand-file-name (format "%s.jsonl" session-id)
                    (chat-session-wire--directory)))

(defun chat-session-wire--archive-file (session-id index)
  "Return archive INDEX of the event stream for SESSION-ID."
  (expand-file-name (format "%s.%d.jsonl" session-id index)
                    (chat-session-wire--directory)))

(defun chat-session-wire--next-archive-index (session-id)
  "Return the first unused archive index for SESSION-ID."
  (let ((index 1))
    (while (file-exists-p (chat-session-wire--archive-file session-id index))
      (setq index (1+ index)))
    index))

(defun chat-session-wire-forget (session-id)
  "Drop cached sequence and size for SESSION-ID.

The counters are a cache over the file, not the truth: dropping them
makes the next write measure the file again."
  (remhash session-id chat-session-wire--sequences)
  (remhash session-id chat-session-wire--sizes))

(defun chat-session-wire--size (session-id)
  "Return bytes currently in SESSION-ID's event stream."
  (or (gethash session-id chat-session-wire--sizes)
      (puthash session-id
               (let ((file (chat-session-wire-file session-id)))
                 (if (file-exists-p file)
                     (file-attribute-size (file-attributes file))
                   0))
               chat-session-wire--sizes)))

(defun chat-session-wire--next-sequence (session-id)
  "Return the next sequence number for SESSION-ID.

Read from the file on first use, so a reopened session continues its
numbering rather than restarting it and making two records ambiguous."
  (let ((last (or (gethash session-id chat-session-wire--sequences)
                  (puthash session-id
                           (chat-session-wire--last-sequence session-id)
                           chat-session-wire--sequences))))
    (puthash session-id (1+ last) chat-session-wire--sequences)))

(defconst chat-session-wire--tail-bytes 8192
  "Bytes read from the end of a stream to recover its sequence.")

(defun chat-session-wire--last-sequence (session-id)
  "Return the highest sequence in SESSION-ID's stream, or 0.

Read from the tail rather than the whole file: this runs when a session
is reopened, and the file it would otherwise read can be tens of
megabytes to answer a question the last line already answers."
  (let ((file (chat-session-wire-file session-id)))
    (if (not (file-exists-p file))
        0
      (let* ((size (file-attribute-size (file-attributes file)))
             (from (max 0 (- size chat-session-wire--tail-bytes))))
        (with-temp-buffer
          (insert-file-contents file nil from size)
          (goto-char (point-max))
          (let ((seq 0)
                (found nil))
            ;; Backwards to the first line that parses.  The first line of
            ;; the window is usually cut in half, and the last can be torn
            ;; by a crash mid-append.
            (while (and (not found) (> (point) (point-min)))
              (forward-line -1)
              (let* ((line (buffer-substring-no-properties
                            (point) (line-end-position)))
                     (record (and (not (string-empty-p line))
                                  (condition-case nil
                                      (let ((json-object-type 'alist)
                                            (json-array-type 'list)
                                            (json-key-type 'symbol))
                                        (json-read-from-string line))
                                    (error nil)))))
                (when (and record (alist-get 'seq record))
                  (setq seq (alist-get 'seq record)
                        found t))))
            seq))))))

(defun chat-session-wire--encode (session-id kind payload &optional context)
  "Return one line for KIND and PAYLOAD in SESSION-ID's stream.

CONTEXT is an alist merged into the envelope, for the identifiers that
group records rather than describe one -- a turn, a step.  It lives in
the envelope rather than the payload so that grouping does not depend on
knowing each kind's shape.

Encoded before the cap is applied, because the cap is about the bytes
that reach the file and a payload's size is not knowable from its shape."
  (let* ((seq (chat-session-wire--next-sequence session-id))
         (stamp (round (* 1000 (float-time))))
         ;; One sequence number per record, taken once.  Taking it inside
         ;; the envelope meant the oversized branch consumed a second one
         ;; and left a hole, which reads as a lost event.
         (envelope
          (lambda (body)
            (json-encode
             (append
              (list (cons 'schema_version chat-session-wire-schema-version)
                    (cons 'seq seq)
                    (cons 'timestamp_ms stamp)
                    (cons 'session_id session-id)
                    (cons 'kind (format "%s" kind)))
              context
              (list (cons 'payload body))))))
         (line (funcall envelope payload)))
    (concat
     (if (<= (string-bytes line) chat-session-wire-max-record-bytes)
         line
       ;; Kept as a record rather than dropped: that a record was too
       ;; large is itself the finding, and a gap in the sequence would
       ;; read as a lost event instead of an oversized one.
       (funcall envelope
                (list (cons 'truncated t)
                      (cons 'original_bytes (string-bytes line)))))
     "\n")))

(defun chat-session-wire--maybe-archive (session-id incoming)
  "Archive SESSION-ID's stream if INCOMING bytes would take it over."
  (let ((file (chat-session-wire-file session-id)))
    (when (and (file-exists-p file)
               (> (+ (chat-session-wire--size session-id) incoming)
                  chat-session-wire-max-bytes))
      (let ((index (chat-session-wire--next-archive-index session-id)))
        (rename-file file (chat-session-wire--archive-file session-id index) t)
        (puthash session-id 0 chat-session-wire--sizes)
        ;; Written into the fresh file, so following the stream backwards
        ;; from here leads to where the rest of it went.
        (chat-session-wire--append
         session-id
         (chat-session-wire--encode session-id 'wire-archived
                                    (list (cons 'index index))))))))

(defun chat-session-wire--append (session-id line)
  "Append LINE to SESSION-ID's stream and account for its size.

A plain append, not the copy-and-rename the context stream uses: that
rewrites the whole file per record, which is quadratic in the number of
records, and an event stream has far more records than a transcript."
  (let ((coding-system-for-write 'utf-8)
        (file (chat-session-wire-file session-id)))
    (unless (file-directory-p (file-name-directory file))
      (make-directory (file-name-directory file) t))
    (write-region line nil file t 'silent)
    (puthash session-id
             (+ (chat-session-wire--size session-id) (string-bytes line))
             chat-session-wire--sizes)))

(defun chat-session-wire-record (session-id kind payload &optional context)
  "Record KIND with PAYLOAD in SESSION-ID's event stream.

PAYLOAD is an alist of scalars, identifiers and bounded summaries.  It is
never the place for a message body, a tool result, a buffer, a process or
a run: those are in the context stream, and this refers to them by id.
CONTEXT is envelope-level grouping, as in `chat-session-wire--encode'."
  (when (and chat-session-wire-enabled
             (stringp session-id)
             (not (string-empty-p session-id)))
    (condition-case err
        (let ((line (chat-session-wire--encode session-id kind payload context)))
          (chat-session-wire--maybe-archive session-id (string-bytes line))
          (chat-session-wire--append session-id line)
          t)
      ;; Recording must not be able to break the run it is recording.
      (error
       (chat-log "[WIRE] Could not record %s: %s"
                 kind (error-message-string err))
       nil))))

(defun chat-session-wire-read (session-id &optional kinds)
  "Return the records in SESSION-ID's stream, oldest first.

KINDS, when given, keeps only those kinds.  A line that does not parse is
skipped rather than raised: an append-only stream can end mid-line if
Emacs died while writing, and one torn line at the end is not a reason to
refuse the rest of the history."
  (let ((file (chat-session-wire-file session-id))
        (records nil))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (unless (string-empty-p line)
              (let ((record (condition-case nil
                                (let ((json-object-type 'alist)
                                      (json-array-type 'list)
                                      (json-key-type 'symbol))
                                  (json-read-from-string line))
                              (error nil))))
                (when (and record
                           (or (null kinds)
                               (member (alist-get 'kind record)
                                       (mapcar (lambda (k) (format "%s" k))
                                               kinds))))
                  (push record records)))))
          (forward-line 1))))
    (nreverse records)))

(provide 'chat-session-wire)
;;; chat-session-wire.el ends here
