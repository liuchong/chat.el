;;; chat-changed-files.el --- Session-attributed changed files -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This module stores successful file-change contributions on their owning
;; session and derives the current changed-file projection from those facts.
;; It never scans a repository or asks the filesystem what should be attributed
;; to a conversation.  Checkpoint completion and rollback are the writers.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-session)

(defconst chat-changed-files-schema-version 1
  "Current changed-file ledger schema version.")

(defconst chat-changed-files-ui-limit 50
  "Maximum changed-file entries returned to one UI projection.")

(define-error 'chat-changed-files-error "Invalid changed-file ledger")

(cl-defstruct
    (chat-changed-file-contribution
     (:constructor chat-changed-file-contribution-create-record))
  "One successful checkpoint-owned file effect."
  schema-version id path canonical-path operation turn-id evidence-id
  updated-at rename-from)

(cl-defstruct
    (chat-changed-file-entry
     (:constructor chat-changed-file-entry-create-record))
  "One current file effect derived from successful contributions."
  schema-version id path canonical-path operation first-turn last-turn
  latest-evidence-id revision updated-at rename-history)

(cl-defstruct
    (chat-changed-file-ledger
     (:constructor chat-changed-file-ledger-create-record))
  "Durable per-session contributions and their indexed projection."
  schema-version revision contributions entries)

(defvar chat-changed-files--registry (make-hash-table :test 'equal)
  "Latest decoded ledger by session ID.")

(defun chat-changed-files--timestamp-ms ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-changed-files--operation (value)
  "Return current-schema operation symbol for VALUE."
  (let ((operation (if (symbolp value) value (and value (intern value)))))
    (unless (memq operation '(added modified deleted renamed))
      (signal 'chat-changed-files-error (list "Invalid operation" value)))
    operation))

(defun chat-changed-files--nonempty-string-p (value)
  "Return non-nil when VALUE is a nonempty string."
  (and (stringp value) (not (string-empty-p value))))

(defun chat-changed-files--stable-id (prefix &rest parts)
  "Return a stable ID beginning with PREFIX for PARTS."
  (format "%s-%s" prefix
          (substring
           (secure-hash 'sha256 (mapconcat (lambda (part) (format "%s" part))
                                            parts "\0"))
           0 24)))

(defun chat-changed-files--validate-contribution (contribution)
  "Return CONTRIBUTION after strict current-schema validation."
  (unless (chat-changed-file-contribution-p contribution)
    (signal 'chat-changed-files-error (list "Not a contribution" contribution)))
  (unless (= (or (chat-changed-file-contribution-schema-version contribution) 0)
             chat-changed-files-schema-version)
    (signal 'chat-changed-files-error
            (list "Unsupported contribution schema"
                  (chat-changed-file-contribution-schema-version contribution))))
  (dolist (value (list (chat-changed-file-contribution-id contribution)
                       (chat-changed-file-contribution-path contribution)
                       (chat-changed-file-contribution-canonical-path contribution)
                       (chat-changed-file-contribution-evidence-id contribution)))
    (unless (chat-changed-files--nonempty-string-p value)
      (signal 'chat-changed-files-error
              (list "Contribution requires nonempty string fields"))))
  (unless (file-name-absolute-p
           (chat-changed-file-contribution-canonical-path contribution))
    (signal 'chat-changed-files-error
            (list "Canonical path must be absolute"
                  (chat-changed-file-contribution-canonical-path contribution))))
  (setf (chat-changed-file-contribution-operation contribution)
        (chat-changed-files--operation
         (chat-changed-file-contribution-operation contribution)))
  (unless (and (integerp (chat-changed-file-contribution-updated-at contribution))
               (>= (chat-changed-file-contribution-updated-at contribution) 0))
    (signal 'chat-changed-files-error (list "Invalid contribution timestamp")))
  contribution)

(defun chat-changed-files--validate-entry (entry)
  "Return derived ENTRY after strict current-schema validation."
  (unless (chat-changed-file-entry-p entry)
    (signal 'chat-changed-files-error (list "Not a changed-file entry" entry)))
  (unless (= (or (chat-changed-file-entry-schema-version entry) 0)
             chat-changed-files-schema-version)
    (signal 'chat-changed-files-error
            (list "Unsupported entry schema"
                  (chat-changed-file-entry-schema-version entry))))
  (dolist (value (list (chat-changed-file-entry-id entry)
                       (chat-changed-file-entry-path entry)
                       (chat-changed-file-entry-canonical-path entry)
                       (chat-changed-file-entry-latest-evidence-id entry)))
    (unless (chat-changed-files--nonempty-string-p value)
      (signal 'chat-changed-files-error
              (list "Changed-file entry requires nonempty string fields"))))
  (setf (chat-changed-file-entry-operation entry)
        (chat-changed-files--operation (chat-changed-file-entry-operation entry)))
  entry)

(defun chat-changed-files--empty-ledger ()
  "Return an empty current-schema ledger."
  (chat-changed-file-ledger-create-record
   :schema-version chat-changed-files-schema-version
   :revision 0 :contributions nil :entries nil))

(defun chat-changed-files--contribution-to-json (contribution)
  "Return JSON-friendly data for CONTRIBUTION."
  (setq contribution
        (chat-changed-files--validate-contribution contribution))
  `((schemaVersion . ,(chat-changed-file-contribution-schema-version contribution))
    (id . ,(chat-changed-file-contribution-id contribution))
    (path . ,(chat-changed-file-contribution-path contribution))
    (canonicalPath . ,(chat-changed-file-contribution-canonical-path contribution))
    (operation . ,(symbol-name
                    (chat-changed-file-contribution-operation contribution)))
    (turnId . ,(chat-changed-file-contribution-turn-id contribution))
    (evidenceId . ,(chat-changed-file-contribution-evidence-id contribution))
    (updatedAt . ,(chat-changed-file-contribution-updated-at contribution))
    (renameFrom . ,(chat-changed-file-contribution-rename-from contribution))))

(defun chat-changed-files--contribution-from-json (data)
  "Decode current-schema contribution DATA."
  (chat-changed-files--validate-contribution
   (chat-changed-file-contribution-create-record
    :schema-version (or (alist-get 'schemaVersion data) 0)
    :id (alist-get 'id data)
    :path (alist-get 'path data)
    :canonical-path (alist-get 'canonicalPath data)
    :operation (alist-get 'operation data)
    :turn-id (alist-get 'turnId data)
    :evidence-id (alist-get 'evidenceId data)
    :updated-at (or (alist-get 'updatedAt data) 0)
    :rename-from (alist-get 'renameFrom data))))

(defun chat-changed-files--entry-to-json (entry)
  "Return JSON-friendly data for derived ENTRY."
  (setq entry (chat-changed-files--validate-entry entry))
  `((schemaVersion . ,(chat-changed-file-entry-schema-version entry))
    (id . ,(chat-changed-file-entry-id entry))
    (path . ,(chat-changed-file-entry-path entry))
    (canonicalPath . ,(chat-changed-file-entry-canonical-path entry))
    (operation . ,(symbol-name (chat-changed-file-entry-operation entry)))
    (firstTurn . ,(chat-changed-file-entry-first-turn entry))
    (lastTurn . ,(chat-changed-file-entry-last-turn entry))
    (latestEvidenceId . ,(chat-changed-file-entry-latest-evidence-id entry))
    (revision . ,(chat-changed-file-entry-revision entry))
    (updatedAt . ,(chat-changed-file-entry-updated-at entry))
    (renameHistory . ,(vconcat
                       (chat-changed-file-entry-rename-history entry)))))

(defun chat-changed-files--entry-from-json (data)
  "Decode current-schema derived entry DATA."
  (chat-changed-files--validate-entry
   (chat-changed-file-entry-create-record
    :schema-version (or (alist-get 'schemaVersion data) 0)
    :id (alist-get 'id data)
    :path (alist-get 'path data)
    :canonical-path (alist-get 'canonicalPath data)
    :operation (alist-get 'operation data)
    :first-turn (alist-get 'firstTurn data)
    :last-turn (alist-get 'lastTurn data)
    :latest-evidence-id (alist-get 'latestEvidenceId data)
    :revision (or (alist-get 'revision data) 0)
    :updated-at (or (alist-get 'updatedAt data) 0)
    :rename-history (append (alist-get 'renameHistory data) nil))))

(defun chat-changed-files-ledger-to-json (ledger)
  "Return JSON-friendly data for LEDGER."
  (unless (chat-changed-file-ledger-p ledger)
    (signal 'chat-changed-files-error (list "Not a changed-file ledger" ledger)))
  `((schemaVersion . ,(chat-changed-file-ledger-schema-version ledger))
    (revision . ,(chat-changed-file-ledger-revision ledger))
    (contributions . ,(vconcat
                       (mapcar #'chat-changed-files--contribution-to-json
                               (chat-changed-file-ledger-contributions ledger))))
    (entries . ,(vconcat
                 (mapcar #'chat-changed-files--entry-to-json
                         (chat-changed-file-ledger-entries ledger))))))

(defun chat-changed-files-ledger-from-json (data)
  "Decode strict current-schema ledger DATA."
  (cond
   ((chat-changed-file-ledger-p data) data)
   ((listp data)
    (let ((version (or (alist-get 'schemaVersion data) 0)))
      (unless (= version chat-changed-files-schema-version)
        (signal 'chat-changed-files-error
                (list "Unsupported changed-file ledger schema" version)))
      (chat-changed-file-ledger-create-record
       :schema-version version
       :revision (or (alist-get 'revision data) 0)
       :contributions
       (mapcar #'chat-changed-files--contribution-from-json
               (append (alist-get 'contributions data) nil))
       :entries
       (mapcar #'chat-changed-files--entry-from-json
               (append (alist-get 'entries data) nil)))))
   (t
    (signal 'chat-changed-files-error
            (list "Unsupported changed-file ledger representation" data)))))

(defun chat-changed-files-current (session)
  "Return SESSION's current changed-file ledger without scanning files."
  (unless (chat-session-p session)
    (signal 'chat-changed-files-error (list "Invalid session" session)))
  (let ((session-id (chat-session-id session)))
    (or (gethash session-id chat-changed-files--registry)
        (let* ((stored (chat-session-metadata-get session 'changed-file-ledger))
               (ledger (if stored
                           (chat-changed-files-ledger-from-json stored)
                         (chat-changed-files--empty-ledger))))
          (puthash session-id ledger chat-changed-files--registry)
          ledger))))

(defun chat-changed-files--new-entry (contribution revision)
  "Create one derived entry from CONTRIBUTION at REVISION."
  (chat-changed-file-entry-create-record
   :schema-version chat-changed-files-schema-version
   :id (chat-changed-file-contribution-id contribution)
   :path (chat-changed-file-contribution-path contribution)
   :canonical-path (chat-changed-file-contribution-canonical-path contribution)
   :operation (chat-changed-file-contribution-operation contribution)
   :first-turn (chat-changed-file-contribution-turn-id contribution)
   :last-turn (chat-changed-file-contribution-turn-id contribution)
   :latest-evidence-id
   (chat-changed-file-contribution-evidence-id contribution)
   :revision revision
   :updated-at (chat-changed-file-contribution-updated-at contribution)
   :rename-history
   (when (chat-changed-file-contribution-rename-from contribution)
     (list (chat-changed-file-contribution-rename-from contribution)))))

(defun chat-changed-files--next-operation (old new)
  "Return net operation after OLD is followed by NEW, or nil for no effect."
  (pcase (cons old new)
    (`(added . deleted) nil)
    (`(added . ,_) 'added)
    (`(deleted . added) 'modified)
    (`(deleted . modified) 'modified)
    (`(renamed . modified) 'renamed)
    (`(renamed . added) 'renamed)
    (`(,old-operation . ,new-operation)
     (or new-operation old-operation))))

(defun chat-changed-files--apply-contribution (table contribution revision)
  "Apply CONTRIBUTION to projection TABLE at REVISION."
  (let* ((path (chat-changed-file-contribution-path contribution))
         (operation (chat-changed-file-contribution-operation contribution))
         (rename-from (chat-changed-file-contribution-rename-from contribution)))
    (if (eq operation 'renamed)
        (let* ((source (and rename-from (gethash rename-from table)))
               (target (gethash path table))
               (entry (or source target
                          (chat-changed-files--new-entry contribution revision)))
               (history (delete-dups
                         (append (chat-changed-file-entry-rename-history entry)
                                 (and rename-from (list rename-from))))))
          (when rename-from (remhash rename-from table))
          (setf (chat-changed-file-entry-path entry) path
                (chat-changed-file-entry-canonical-path entry)
                (chat-changed-file-contribution-canonical-path contribution)
                (chat-changed-file-entry-operation entry)
                (if (and source
                         (eq (chat-changed-file-entry-operation source) 'added))
                    'added
                  'renamed)
                (chat-changed-file-entry-last-turn entry)
                (chat-changed-file-contribution-turn-id contribution)
                (chat-changed-file-entry-latest-evidence-id entry)
                (chat-changed-file-contribution-evidence-id contribution)
                (chat-changed-file-entry-revision entry) revision
                (chat-changed-file-entry-updated-at entry)
                (chat-changed-file-contribution-updated-at contribution)
                (chat-changed-file-entry-rename-history entry) history)
          (puthash path entry table))
      (let ((entry (gethash path table)))
        (if (not entry)
            (puthash path (chat-changed-files--new-entry contribution revision)
                     table)
          (let ((next (chat-changed-files--next-operation
                       (chat-changed-file-entry-operation entry) operation)))
            (if (not next)
                (remhash path table)
              (setf (chat-changed-file-entry-operation entry) next
                    (chat-changed-file-entry-canonical-path entry)
                    (chat-changed-file-contribution-canonical-path contribution)
                    (chat-changed-file-entry-last-turn entry)
                    (chat-changed-file-contribution-turn-id contribution)
                    (chat-changed-file-entry-latest-evidence-id entry)
                    (chat-changed-file-contribution-evidence-id contribution)
                    (chat-changed-file-entry-revision entry) revision
                    (chat-changed-file-entry-updated-at entry)
                    (chat-changed-file-contribution-updated-at contribution)))))))))

(defun chat-changed-files--derive-entries (contributions revision)
  "Derive current entries from CONTRIBUTIONS at ledger REVISION."
  (let ((table (make-hash-table :test 'equal)))
    ;; The persisted contribution sequence is the execution order.  A
    ;; millisecond timestamp is metadata, not an ordering key: two successful
    ;; writes can share one and a hash-derived ID must never reverse them.
    (dolist (contribution contributions)
      (chat-changed-files--apply-contribution table contribution revision))
    (let (entries)
      (maphash (lambda (_path entry)
                 (push (chat-changed-files--validate-entry entry) entries))
               table)
      (sort entries
            (lambda (left right)
              (string< (chat-changed-file-entry-path left)
                       (chat-changed-file-entry-path right)))))))

(defun chat-changed-files--contribution-from-fact (evidence-id fact)
  "Create one contribution for EVIDENCE-ID from FACT plist."
  (let* ((path (plist-get fact :path))
         (canonical-path (plist-get fact :canonical-path))
         (operation (chat-changed-files--operation (plist-get fact :operation)))
         (turn-id (plist-get fact :turn-id))
         (updated-at (or (plist-get fact :updated-at)
                         (chat-changed-files--timestamp-ms)))
         (rename-from (plist-get fact :rename-from)))
    (chat-changed-files--validate-contribution
     (chat-changed-file-contribution-create-record
      :schema-version chat-changed-files-schema-version
      :id (chat-changed-files--stable-id
           "change" evidence-id path operation rename-from)
      :path path :canonical-path canonical-path :operation operation
      :turn-id turn-id :evidence-id evidence-id :updated-at updated-at
      :rename-from rename-from))))

(defun chat-changed-files--persist (session ledger event-type evidence-id)
  "Persist LEDGER for SESSION and emit EVENT-TYPE for EVIDENCE-ID."
  (let ((session-id (chat-session-id session)))
    (puthash session-id ledger chat-changed-files--registry)
    (chat-session-metadata-set
     session 'changed-file-ledger (chat-changed-files-ledger-to-json ledger))
    (chat-session-save session)
    (chat-event-emit
     event-type :session-id session-id :source 'changed-files
     :payload
     `((revision . ,(chat-changed-file-ledger-revision ledger))
       (file_count . ,(length (chat-changed-file-ledger-entries ledger)))
       (evidence_id . ,evidence-id)))
    ledger))

(defun chat-changed-files-record-success
    (session evidence-id facts replace-paths)
  "Record successful FACTS for EVIDENCE-ID on SESSION.

REPLACE-PATHS names paths touched by the successful operation.  Existing
contributions for the same evidence and paths are replaced, which lets repeated
writes in one checkpoint converge to their latest post-state."
  (unless (chat-changed-files--nonempty-string-p evidence-id)
    (signal 'chat-changed-files-error (list "Missing evidence ID")))
  (let* ((ledger (chat-changed-files-current session))
         (old (chat-changed-file-ledger-contributions ledger))
         (kept
          (seq-remove
           (lambda (contribution)
             (and (equal evidence-id
                         (chat-changed-file-contribution-evidence-id contribution))
                  (or (member (chat-changed-file-contribution-path contribution)
                              replace-paths)
                      (member
                       (chat-changed-file-contribution-rename-from contribution)
                       replace-paths))))
           old))
         (added (mapcar (lambda (fact)
                          (chat-changed-files--contribution-from-fact
                           evidence-id fact))
                        facts))
         (revision (1+ (chat-changed-file-ledger-revision ledger)))
         (contributions (append kept added))
         (next
          (chat-changed-file-ledger-create-record
           :schema-version chat-changed-files-schema-version
           :revision revision
           :contributions contributions
           :entries (chat-changed-files--derive-entries contributions revision))))
    (chat-changed-files--persist
     session next 'changed-files-updated evidence-id)))

(defun chat-changed-files-rollback-evidence (session evidence-id)
  "Remove EVIDENCE-ID effects from SESSION and rebuild its projection."
  (let* ((ledger (chat-changed-files-current session))
         (old (chat-changed-file-ledger-contributions ledger))
         (contributions
          (seq-remove
           (lambda (contribution)
             (equal evidence-id
                    (chat-changed-file-contribution-evidence-id contribution)))
           old)))
    (if (= (length old) (length contributions))
        ledger
      (let* ((revision (1+ (chat-changed-file-ledger-revision ledger)))
             (next
              (chat-changed-file-ledger-create-record
               :schema-version chat-changed-files-schema-version
               :revision revision :contributions contributions
               :entries
               (chat-changed-files--derive-entries contributions revision))))
        (chat-changed-files--persist
         session next 'changed-files-rolled-back evidence-id)))))

(defun chat-changed-files-ui-projection (session)
  "Return a bounded indexed changed-file projection for SESSION."
  (let* ((ledger (chat-changed-files-current session))
         (entries (chat-changed-file-ledger-entries ledger))
         (shown (seq-take entries chat-changed-files-ui-limit)))
    (when entries
      (list :revision (chat-changed-file-ledger-revision ledger)
            :count (length entries)
            :entries shown
            :omitted (- (length entries) (length shown))))))

(provide 'chat-changed-files)
;;; chat-changed-files.el ends here
