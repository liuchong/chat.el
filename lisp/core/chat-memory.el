;;; chat-memory.el --- Attributable long term memory -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, memory

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Long term memory has two explicit sources.  The original `memory.md'
;; remains a user-curated global note.  Structured items add provenance,
;; scope, confidence, retention and sensitivity without rewriting that note.
;; Automatic capture is disabled by default and never bypasses validation.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defconst chat-memory-schema-version 1
  "Current structured memory document schema.")

(defconst chat-memory-item-schema-version 1
  "Current `chat-memory-item' schema.")

(defcustom chat-memory-file (expand-file-name "memory.md" "~/.chat/")
  "User-curated global memory injected into system prompts."
  :type 'file
  :group 'chat)

(defcustom chat-memory-directory (expand-file-name "memory/" "~/.chat/")
  "Directory holding structured memory state."
  :type 'directory
  :group 'chat)

(defcustom chat-memory-max-chars 8000
  "Maximum total characters of memory injected into a prompt."
  :type 'integer
  :group 'chat)

(defcustom chat-memory-max-item-chars 4000
  "Maximum characters in one structured memory item."
  :type 'integer
  :group 'chat)

(defcustom chat-memory-max-items 1000
  "Maximum structured memory items retained in one store."
  :type 'integer
  :group 'chat)

(defcustom chat-memory-max-metadata-bytes 4096
  "Maximum encoded bytes in one memory item's metadata."
  :type 'integer
  :group 'chat)

(defcustom chat-memory-automatic-enabled nil
  "Default automatic-memory state when no durable preference exists."
  :type 'boolean
  :group 'chat)

(defcustom chat-memory-default-retention-days 30
  "Days an automatically captured memory candidate remains active."
  :type 'integer
  :group 'chat)

(defcustom chat-memory-secret-patterns
  '("-----BEGIN [A-Z ]*PRIVATE KEY-----"
    "\\(?:api[_-]?key\\|password\\|secret\\|token\\)[[:space:]]*[:=][[:space:]]*[^[:space:]]\\{12,\\}"
    "\\_<AKIA[[:alnum:]]\\{16\\}\\_>")
  "Patterns that structured memory refuses to persist.

These are a last-resort boundary, not a complete secret scanner.  Callers
must still classify sensitive candidates before calling the memory API."
  :type '(repeat regexp)
  :group 'chat)

(cl-defstruct (chat-memory-item
               (:constructor chat-memory-item-create-record))
  "One attributable, scoped memory item."
  schema-version id content source-kind source-id scope scope-id confidence
  created-at updated-at expires-at retention sensitivity status metadata)

(defun chat-memory--items-file ()
  "Return the structured memory document path."
  (expand-file-name "items.json" chat-memory-directory))

(defun chat-memory--timestamp-ms ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-memory--new-id ()
  "Return a new memory item identifier."
  (format "memory-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%S%N" nil t)
          (random #x1000000)))

(defun chat-memory--symbol (value fallback)
  "Return VALUE as a symbol, or FALLBACK when VALUE is empty."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t fallback)))

(defun chat-memory--secret-like-p (content)
  "Return non-nil when CONTENT matches a configured secret pattern."
  (seq-some (lambda (pattern) (string-match-p pattern content))
            chat-memory-secret-patterns))

(defun chat-memory--canonical-project (directory)
  "Return a canonical project identity for DIRECTORY."
  (when (and (stringp directory) (not (string-empty-p directory)))
    (file-name-as-directory
     (if (file-exists-p directory)
         (file-truename directory)
       (expand-file-name directory)))))

(defun chat-memory--session-id (session)
  "Return SESSION's identifier, accepting an identifier string too."
  (cond ((stringp session) session)
        ((and session (fboundp 'chat-session-id))
         (chat-session-id session))))

(defun chat-memory--session-project (session)
  "Return SESSION's canonical project identity, or nil."
  (when (and session (not (stringp session))
             (fboundp 'chat-session-working-directory))
    (chat-memory--canonical-project
     (chat-session-working-directory session))))

(defun chat-memory--normalize-scope-id (scope scope-id)
  "Return normalized SCOPE-ID for SCOPE."
  (pcase scope
    ('global nil)
    ('project (chat-memory--canonical-project scope-id))
    ('session (and scope-id (format "%s" scope-id)))
    (_ scope-id)))

(defun chat-memory--validate-item (item)
  "Validate ITEM and return it."
  (unless (chat-memory-item-p item)
    (error "Not a memory item"))
  (unless (= (or (chat-memory-item-schema-version item) 0)
             chat-memory-item-schema-version)
    (error "Unsupported memory item schema: %s"
           (chat-memory-item-schema-version item)))
  (let ((id (chat-memory-item-id item))
        (content (and (stringp (chat-memory-item-content item))
                      (string-trim (chat-memory-item-content item))))
        (source-id (chat-memory-item-source-id item))
        (source-kind (chat-memory-item-source-kind item))
        (scope (chat-memory-item-scope item))
        (confidence (chat-memory-item-confidence item))
        (retention (chat-memory-item-retention item))
        (sensitivity (chat-memory-item-sensitivity item))
        (status (chat-memory-item-status item)))
    (unless (and (stringp id) (not (string-empty-p id))
                 (<= (length id) 256))
      (error "Memory item id is missing or too long"))
    (unless (and content (not (string-empty-p content)))
      (error "Memory item content is empty"))
    (when (> (length content) chat-memory-max-item-chars)
      (error "Memory item exceeds %d characters" chat-memory-max-item-chars))
    (when (chat-memory--secret-like-p content)
      (error "Memory item looks like a secret and was not persisted"))
    (unless (memq source-kind '(user inferred imported merged))
      (error "Unsupported memory source kind: %s" source-kind))
    (unless (and (stringp source-id) (not (string-empty-p source-id))
                 (<= (length source-id) 512))
      (error "Memory source id is missing or too long"))
    (unless (memq scope '(global project session))
      (error "Unsupported memory scope: %s" scope))
    (when (and (memq scope '(project session))
               (not (and (stringp (chat-memory-item-scope-id item))
                         (not (string-empty-p
                               (chat-memory-item-scope-id item))))))
      (error "%s memory requires a scope id" scope))
    (unless (and (numberp confidence) (<= 0 confidence) (<= confidence 1))
      (error "Memory confidence must be between zero and one"))
    (unless (memq retention '(permanent expiring session))
      (error "Unsupported memory retention: %s" retention))
    (when (and (eq retention 'expiring)
               (not (numberp (chat-memory-item-expires-at item))))
      (error "Expiring memory requires an expiry timestamp"))
    (unless (memq sensitivity '(normal sensitive))
      (error "Unsupported memory sensitivity: %s" sensitivity))
    (unless (memq status '(active archived rejected))
      (error "Unsupported memory status: %s" status))
    (when (> (string-bytes (json-encode (chat-memory-item-metadata item)))
             chat-memory-max-metadata-bytes)
      (error "Memory metadata exceeds %d bytes"
             chat-memory-max-metadata-bytes))
    (setf (chat-memory-item-content item) content
          (chat-memory-item-scope-id item)
          (chat-memory--normalize-scope-id
           scope (chat-memory-item-scope-id item)))
    item))

(defun chat-memory--item-to-json (item)
  "Return JSON-friendly data for ITEM."
  `((schemaVersion . ,(chat-memory-item-schema-version item))
    (id . ,(chat-memory-item-id item))
    (content . ,(chat-memory-item-content item))
    (sourceKind . ,(symbol-name (chat-memory-item-source-kind item)))
    (sourceId . ,(chat-memory-item-source-id item))
    (scope . ,(symbol-name (chat-memory-item-scope item)))
    (scopeId . ,(chat-memory-item-scope-id item))
    (confidence . ,(chat-memory-item-confidence item))
    (createdAt . ,(chat-memory-item-created-at item))
    (updatedAt . ,(chat-memory-item-updated-at item))
    (expiresAt . ,(chat-memory-item-expires-at item))
    (retention . ,(symbol-name (chat-memory-item-retention item)))
    (sensitivity . ,(symbol-name (chat-memory-item-sensitivity item)))
    (status . ,(symbol-name (chat-memory-item-status item)))
    (metadata . ,(chat-memory-item-metadata item))))

(defun chat-memory--item-from-json (data)
  "Return a validated memory item decoded from DATA."
  (chat-memory--validate-item
   (chat-memory-item-create-record
    :schema-version (or (alist-get 'schemaVersion data) 0)
    :id (alist-get 'id data)
    :content (alist-get 'content data)
    :source-kind (chat-memory--symbol (alist-get 'sourceKind data) nil)
    :source-id (alist-get 'sourceId data)
    :scope (chat-memory--symbol (alist-get 'scope data) nil)
    :scope-id (alist-get 'scopeId data)
    :confidence (alist-get 'confidence data)
    :created-at (alist-get 'createdAt data)
    :updated-at (alist-get 'updatedAt data)
    :expires-at (alist-get 'expiresAt data)
    :retention (chat-memory--symbol (alist-get 'retention data) nil)
    :sensitivity (chat-memory--symbol (alist-get 'sensitivity data) nil)
    :status (chat-memory--symbol (alist-get 'status data) nil)
    :metadata (alist-get 'metadata data))))

(defun chat-memory--empty-state ()
  "Return a new in-memory state plist."
  (list :automatic chat-memory-automatic-enabled :items nil))

(defun chat-memory--load-state ()
  "Read and validate the structured memory document."
  (let ((file (chat-memory--items-file)))
    (if (not (file-exists-p file))
        (chat-memory--empty-state)
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol)
             (data (json-read-file file))
             (version (or (alist-get 'schemaVersion data) 0))
             (raw-items (alist-get 'items data)))
        (unless (= version chat-memory-schema-version)
          (error "Unsupported memory document schema: %s" version))
        (when (> (length raw-items) chat-memory-max-items)
          (error "Memory document exceeds %d items" chat-memory-max-items))
        (list :automatic (eq t (alist-get 'automaticEnabled data))
              :items (mapcar #'chat-memory--item-from-json raw-items))))))

(defun chat-memory--save-state (state)
  "Atomically persist structured memory STATE and return STATE."
  (let ((items (plist-get state :items)))
    (when (> (length items) chat-memory-max-items)
      (error "Memory document exceeds %d items" chat-memory-max-items))
    (mapc #'chat-memory--validate-item items)
    (make-directory chat-memory-directory t)
    (let* ((target (chat-memory--items-file))
           (temp (make-temp-file
                  (expand-file-name ".memory-" chat-memory-directory))))
      (unwind-protect
          (progn
            (with-temp-file temp
              (let ((coding-system-for-write 'utf-8))
                (insert
                 (json-encode
                  `((schemaVersion . ,chat-memory-schema-version)
                    (automaticEnabled
                     . ,(if (plist-get state :automatic) t :json-false))
                    (items . ,(mapcar #'chat-memory--item-to-json items)))))))
            (rename-file temp target t))
        (when (file-exists-p temp)
          (delete-file temp)))))
  state)

(defun chat-memory-list (&optional include-inactive)
  "Return structured memory items in deterministic order.

When INCLUDE-INACTIVE is nil, return active items only."
  (let ((items (copy-sequence (plist-get (chat-memory--load-state) :items))))
    (unless include-inactive
      (setq items (seq-filter (lambda (item)
                                (eq (chat-memory-item-status item) 'active))
                              items)))
    (sort items
          (lambda (left right)
            (let ((lu (or (chat-memory-item-updated-at left) 0))
                  (ru (or (chat-memory-item-updated-at right) 0)))
              (if (= lu ru)
                  (string< (chat-memory-item-id left)
                           (chat-memory-item-id right))
                (> lu ru)))))))

(defun chat-memory-get (id)
  "Return the structured memory item named ID, or nil."
  (seq-find (lambda (item) (equal id (chat-memory-item-id item)))
            (chat-memory-list t)))

(cl-defun chat-memory-add
    (content &key (source-kind 'user) source-id (scope 'global) scope-id
             (confidence 1.0) expires-at (retention 'permanent)
             (sensitivity 'normal) (status 'active) metadata id)
  "Create, persist and return one structured memory item for CONTENT."
  (let* ((state (chat-memory--load-state))
         (now (chat-memory--timestamp-ms))
         (item (chat-memory-item-create-record
                :schema-version chat-memory-item-schema-version
                :id (or id (chat-memory--new-id))
                :content content
                :source-kind source-kind
                :source-id (or source-id "user:manual")
                :scope scope
                :scope-id (chat-memory--normalize-scope-id scope scope-id)
                :confidence confidence
                :created-at now
                :updated-at now
                :expires-at expires-at
                :retention retention
                :sensitivity sensitivity
                :status status
                :metadata metadata)))
    (chat-memory--validate-item item)
    (when (seq-some (lambda (existing)
                      (equal (chat-memory-item-id existing)
                             (chat-memory-item-id item)))
                    (plist-get state :items))
      (error "Memory item already exists: %s" (chat-memory-item-id item)))
    (setf (plist-get state :items)
          (cons item (plist-get state :items)))
    (chat-memory--save-state state)
    item))

(defun chat-memory--apply-change (item key value)
  "Set ITEM field named by KEY to VALUE."
  (pcase key
    (:content (setf (chat-memory-item-content item) value))
    (:source-kind (setf (chat-memory-item-source-kind item) value))
    (:source-id (setf (chat-memory-item-source-id item) value))
    (:scope (setf (chat-memory-item-scope item) value))
    (:scope-id (setf (chat-memory-item-scope-id item) value))
    (:confidence (setf (chat-memory-item-confidence item) value))
    (:expires-at (setf (chat-memory-item-expires-at item) value))
    (:retention (setf (chat-memory-item-retention item) value))
    (:sensitivity (setf (chat-memory-item-sensitivity item) value))
    (:status (setf (chat-memory-item-status item) value))
    (:metadata (setf (chat-memory-item-metadata item) value))
    (_ (error "Unsupported memory update field: %s" key))))

(defun chat-memory-update (id changes)
  "Apply CHANGES plist to memory item ID, persist and return it."
  (let* ((state (chat-memory--load-state))
         (item (seq-find (lambda (candidate)
                           (equal id (chat-memory-item-id candidate)))
                         (plist-get state :items))))
    (unless item
      (error "Unknown memory item: %s" id))
    (let ((rest changes))
      (while rest
        (unless (cdr rest)
          (error "Memory update plist has no value for %s" (car rest)))
        (chat-memory--apply-change item (car rest) (cadr rest))
        (setq rest (cddr rest))))
    (setf (chat-memory-item-updated-at item) (chat-memory--timestamp-ms)
          (chat-memory-item-scope-id item)
          (chat-memory--normalize-scope-id
           (chat-memory-item-scope item)
           (chat-memory-item-scope-id item)))
    (chat-memory--validate-item item)
    (chat-memory--save-state state)
    item))

(defun chat-memory-archive (id)
  "Archive memory item ID and return it."
  (chat-memory-update id '(:status archived)))

(defun chat-memory-delete (id)
  "Delete memory item ID and return non-nil when it existed."
  (let* ((state (chat-memory--load-state))
         (items (plist-get state :items))
         (remaining (seq-remove
                     (lambda (item) (equal id (chat-memory-item-id item)))
                     items)))
    (when (= (length items) (length remaining))
      (error "Unknown memory item: %s" id))
    (setf (plist-get state :items) remaining)
    (chat-memory--save-state state)
    t))

(cl-defun chat-memory-merge (ids content &key scope scope-id confidence)
  "Merge memory IDS into one attributable item containing CONTENT."
  (let* ((state (chat-memory--load-state))
         (items (plist-get state :items))
         (sources (mapcar
                   (lambda (id)
                     (or (seq-find
                          (lambda (item) (equal id (chat-memory-item-id item)))
                          items)
                         (error "Unknown memory item: %s" id)))
                   (delete-dups (copy-sequence ids)))))
    (unless (> (length sources) 1)
      (error "Merging memory requires at least two items"))
    (let ((source-scopes
           (delete-dups
            (mapcar (lambda (item)
                      (cons (chat-memory-item-scope item)
                            (chat-memory-item-scope-id item)))
                    sources))))
      (when (and (> (length source-scopes) 1) (null scope))
        (error "Cross-scope memory merge requires an explicit target scope")))
    (let* ((now (chat-memory--timestamp-ms))
           (item (chat-memory-item-create-record
                  :schema-version chat-memory-item-schema-version
                  :id (chat-memory--new-id)
                  :content content
                  :source-kind 'merged
                  :source-id
                  (concat "merge:"
                          (secure-hash
                           'sha256
                           (mapconcat #'chat-memory-item-id sources "\n")))
                  :scope (or scope (chat-memory-item-scope (car sources)))
                  :scope-id (or scope-id
                                (chat-memory-item-scope-id (car sources)))
                  :confidence (or confidence
                                  (apply #'min
                                         (mapcar #'chat-memory-item-confidence
                                                 sources)))
                  :created-at now :updated-at now
                  :retention 'permanent
                  :sensitivity (if (seq-some
                                    (lambda (source)
                                      (eq (chat-memory-item-sensitivity source)
                                          'sensitive))
                                    sources)
                                   'sensitive
                                 'normal)
                  :status 'active
                  :metadata `((mergedFrom . ,(mapcar #'chat-memory-item-id
                                                     sources))))))
      (chat-memory--validate-item item)
      (dolist (source sources)
        (setf (chat-memory-item-status source) 'archived
              (chat-memory-item-updated-at source) now))
      (setf (plist-get state :items) (cons item items))
      (chat-memory--save-state state)
      item)))

(defun chat-memory-auto-enabled-p ()
  "Return the durable automatic-memory preference."
  (plist-get (chat-memory--load-state) :automatic))

(defun chat-memory-set-automatic (enabled)
  "Persist automatic-memory state ENABLED and return its boolean value."
  (let ((state (chat-memory--load-state)))
    (setf (plist-get state :automatic) (and enabled t))
    (chat-memory--save-state state)
    (plist-get state :automatic)))

(cl-defun chat-memory-capture-candidate
    (content &key source-id (scope 'global) scope-id (confidence 0.5)
             expires-at (retention 'expiring) (sensitivity 'normal) metadata)
  "Persist an inferred CONTENT candidate when automatic memory is enabled."
  (when (chat-memory-auto-enabled-p)
    (let ((deadline
           (or expires-at
               (and (eq retention 'expiring)
                    (+ (chat-memory--timestamp-ms)
                       (* chat-memory-default-retention-days
                          24 60 60 1000))))))
      (chat-memory-add content
                       :source-kind 'inferred
                       :source-id (or source-id "inferred:unknown")
                       :scope scope :scope-id scope-id :confidence confidence
                       :expires-at deadline :retention retention
                       :sensitivity sensitivity :status 'active
                       :metadata metadata))))

(defun chat-memory--expired-p (item now)
  "Return non-nil when ITEM has expired before NOW."
  (let ((expires-at (chat-memory-item-expires-at item)))
    (and (numberp expires-at) (<= expires-at now))))

(defun chat-memory--scope-matches-p (item session)
  "Return non-nil when ITEM applies to SESSION."
  (pcase (chat-memory-item-scope item)
    ('global t)
    ('project
     (equal (chat-memory-item-scope-id item)
            (chat-memory--session-project session)))
    ('session
     (equal (chat-memory-item-scope-id item)
            (chat-memory--session-id session)))
    (_ nil)))

(defun chat-memory-effective-items (&optional session now)
  "Return prompt-eligible structured items for SESSION at NOW.

Sensitive, inactive, expired or out-of-scope items are omitted."
  (let ((stamp (or now (chat-memory--timestamp-ms))))
    (sort
     (seq-filter
      (lambda (item)
        (and (eq (chat-memory-item-status item) 'active)
             (eq (chat-memory-item-sensitivity item) 'normal)
             (not (chat-memory--expired-p item stamp))
             (chat-memory--scope-matches-p item session)))
      (chat-memory-list t))
     (lambda (left right)
       (let ((ls (pcase (chat-memory-item-scope left)
                   ('session 3) ('project 2) (_ 1)))
             (rs (pcase (chat-memory-item-scope right)
                   ('session 3) ('project 2) (_ 1))))
         (cond ((/= ls rs) (> ls rs))
               ((/= (chat-memory-item-confidence left)
                     (chat-memory-item-confidence right))
                (> (chat-memory-item-confidence left)
                   (chat-memory-item-confidence right)))
               ((/= (or (chat-memory-item-updated-at left) 0)
                     (or (chat-memory-item-updated-at right) 0))
                (> (or (chat-memory-item-updated-at left) 0)
                   (or (chat-memory-item-updated-at right) 0)))
               (t (string< (chat-memory-item-id left)
                           (chat-memory-item-id right)))))))))

(defun chat-memory-read ()
  "Return the compatible memory note content, or nil when empty."
  (when (file-exists-p chat-memory-file)
    (let ((content (string-trim
                    (with-temp-buffer
                      (insert-file-contents chat-memory-file)
                      (buffer-string)))))
      (unless (string-empty-p content)
        (if (> (length content) chat-memory-max-chars)
            (concat (substring content 0 chat-memory-max-chars)
                    "\n... [memory truncated]")
          content)))))

(defun chat-memory--item-prompt-line (item)
  "Return one attributable prompt line for ITEM."
  (format "- [%s; confidence=%.2f; source=%s:%s] %s"
          (chat-memory-item-scope item)
          (chat-memory-item-confidence item)
          (chat-memory-item-source-kind item)
          (chat-memory-item-source-id item)
          (chat-memory-item-content item)))

(defun chat-memory-snippet (&optional session)
  "Return the prompt section for memory applicable to SESSION, or nil."
  (let* ((legacy (chat-memory-read))
         (items (chat-memory-effective-items session))
         (sections
          (delq nil
                (list (and legacy
                           (concat "Long term memory curated by the user:\n"
                                   legacy))
                      (and items
                           (concat
                            "Structured long term memory (scoped and attributable):\n"
                            (mapconcat #'chat-memory--item-prompt-line
                                       items "\n"))))))
         (content (and sections (string-join sections "\n\n"))))
    (when content
      (if (> (length content) chat-memory-max-chars)
          (concat (substring content 0 chat-memory-max-chars)
                  "\n... [memory truncated]")
        content))))

;;;###autoload
(defun chat-edit-memory ()
  "Open the compatible user-curated memory note for editing."
  (interactive)
  (find-file chat-memory-file))

(provide 'chat-memory)
;;; chat-memory.el ends here
