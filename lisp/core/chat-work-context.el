;;; chat-work-context.el --- Scoped context and working notes -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Typed context remains structured until the provider boundary.  Working notes
;; are session/task evidence with optimistic revisions; they are neither
;; project instructions nor long-term memory.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-event)

(defgroup chat-work-context nil
  "Structured context and short-lived working notes."
  :group 'chat)

(defconst chat-work-context-schema-version 1)
(defconst chat-context-fragment-kinds
  '(system instruction objective working-note history code tool-schema
           runtime-fact verification artifact))
(defconst chat-context-authorities
  '(system user project runtime agent untrusted))
(defconst chat-context-scopes
  '(global project directory path session turn task child-task))
(defconst chat-work-note-kinds
  '(fact decision constraint hypothesis artifact blocker next-step note))
(defconst chat-work-note-statuses
  '(active resolved superseded archived))

(defcustom chat-work-context-directory
  (expand-file-name "work-context/" (expand-file-name "~/.chat/"))
  "Directory containing session-owned work context."
  :type 'directory :group 'chat-work-context)

(defcustom chat-work-context-max-notes 512
  "Maximum notes retained for one session."
  :type 'integer :group 'chat-work-context)

(defcustom chat-work-context-max-value-bytes (* 32 1024)
  "Maximum encoded value size for one note."
  :type 'integer :group 'chat-work-context)

(defcustom chat-work-context-max-metadata-bytes 4096
  "Maximum encoded metadata size for one note or fragment."
  :type 'integer :group 'chat-work-context)

(defcustom chat-work-context-max-projection-chars 32768
  "Maximum compactable characters projected into one Agent request.
Protected fragments are retained even when they exceed this limit; the
bundle records that overflow so it remains visible to diagnostics."
  :type 'integer :group 'chat-work-context)

(define-error 'chat-work-context-invalid "Invalid work context")
(define-error 'chat-work-context-stale-revision "Stale work note revision")

(cl-defstruct
    (chat-context-fragment
     (:constructor chat-context-fragment-create
                   (&key (schema-version chat-work-context-schema-version)
                         id kind authority source-kind source-id source-path
                         source-range scope scope-id priority residency
                         budget-policy payload digest created-at updated-at
                         (status 'active) metadata)))
  "One attributable and scoped context region."
  schema-version id kind authority source-kind source-id source-path
  source-range scope scope-id priority residency budget-policy payload digest
  created-at updated-at status metadata)

(cl-defstruct
    (chat-context-bundle
     (:constructor chat-context-bundle-create
                   (&key (schema-version chat-work-context-schema-version)
                         session-id turn-id task-id project-root target-path
                         fragments omitted measured-chars digest diagnostics)))
  "One deterministic context selection."
  schema-version session-id turn-id task-id project-root target-path fragments
  omitted measured-chars digest diagnostics)

(cl-defstruct
    (chat-work-note
     (:constructor chat-work-note-create-record
                   (&key (schema-version chat-work-context-schema-version)
                         id key (revision 1) kind value display tags related-ids
                         session-id task-id scope scope-id source-kind source-id
                         confidence verification (status 'active) created-at
                         updated-at metadata)))
  "One revisioned item in a session's working memory."
  schema-version id key revision kind value display tags related-ids session-id
  task-id scope scope-id source-kind source-id confidence verification status
  created-at updated-at metadata)

(defvar chat-work-context--stores (make-hash-table :test 'equal))
(defvar chat-work-context--indexes (make-hash-table :test 'equal))

(defun chat-work-context--timestamp ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-work-context--symbol (value)
  "Return VALUE as a symbol when possible."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))))

(defun chat-work-context--json-bytes (value)
  "Return the encoded byte count of VALUE."
  (string-bytes (json-encode value)))

(defun chat-work-context--canonical-path (path)
  "Return a stable canonical representation of PATH."
  (when (and (stringp path) (not (string-empty-p path)))
    (let ((expanded (expand-file-name path)))
      (if (file-exists-p expanded)
          (file-truename expanded)
        (let ((parent (file-name-directory expanded)))
          (expand-file-name
           (file-name-nondirectory expanded)
           (if (and parent (file-exists-p parent))
               (file-truename parent)
             parent)))))))

(defun chat-work-context--normalize-scope-id
    (scope scope-id session-id task-id)
  "Return canonical SCOPE-ID for SCOPE, SESSION-ID and TASK-ID."
  (pcase scope
    ('global nil)
    ('session (or scope-id session-id))
    ((or 'project 'directory 'path)
     (chat-work-context--canonical-path scope-id))
    ('task (or scope-id task-id))
    ('child-task (or scope-id task-id))
    ('turn
     (let ((value (or scope-id (and session-id (cons session-id nil)))))
       (cond ((vectorp value) (append value nil))
             ((consp value) value)
             (t value))))
    (_ scope-id)))

(defun chat-work-context--inside-p (path directory)
  "Return non-nil when canonical PATH is inside DIRECTORY."
  (let ((path (chat-work-context--canonical-path path))
        (directory (and directory
                        (file-name-as-directory
                         (chat-work-context--canonical-path directory)))))
    (and path directory
         (or (equal (file-name-as-directory path) directory)
             (string-prefix-p directory path)))))

(defun chat-context-scope-matches-p (scope scope-id context)
  "Return non-nil when SCOPE and SCOPE-ID apply to CONTEXT.
CONTEXT is a plist with project, path, session, turn, task and task lineage."
  (pcase scope
    ('global t)
    ('project
     (equal (chat-work-context--canonical-path scope-id)
            (chat-work-context--canonical-path
             (plist-get context :project-root))))
    ('directory
     (chat-work-context--inside-p (plist-get context :target-path) scope-id))
    ('path
     (equal (chat-work-context--canonical-path scope-id)
            (chat-work-context--canonical-path
             (plist-get context :target-path))))
    ('session (equal scope-id (plist-get context :session-id)))
    ('turn (equal scope-id
                  (cons (plist-get context :session-id)
                        (plist-get context :turn-id))))
    ('task (equal scope-id (plist-get context :task-id)))
    ('child-task
     (or (equal scope-id (plist-get context :task-id))
         (member scope-id (plist-get context :task-lineage))))
    (_ nil)))

(defun chat-work-context--fragment-digest (fragment)
  "Return a deterministic digest for FRAGMENT."
  (secure-hash
   'sha256
   (prin1-to-string
    (list (chat-context-fragment-kind fragment)
          (chat-context-fragment-authority fragment)
          (chat-context-fragment-source-id fragment)
          (chat-context-fragment-scope fragment)
          (chat-context-fragment-scope-id fragment)
          (chat-context-fragment-payload fragment)))))

(defun chat-context-fragment-validate (fragment)
  "Validate and return FRAGMENT."
  (unless (chat-context-fragment-p fragment)
    (signal 'chat-work-context-invalid '("not a context fragment")))
  (unless (= (or (chat-context-fragment-schema-version fragment) 0)
             chat-work-context-schema-version)
    (signal 'chat-work-context-invalid '("unsupported fragment schema")))
  (unless (memq (chat-context-fragment-kind fragment)
                chat-context-fragment-kinds)
    (signal 'chat-work-context-invalid '("invalid fragment kind")))
  (unless (memq (chat-context-fragment-authority fragment)
                chat-context-authorities)
    (signal 'chat-work-context-invalid '("invalid fragment authority")))
  (unless (memq (chat-context-fragment-scope fragment) chat-context-scopes)
    (signal 'chat-work-context-invalid '("invalid fragment scope")))
  (unless (and (stringp (chat-context-fragment-id fragment))
               (stringp (chat-context-fragment-source-id fragment)))
    (signal 'chat-work-context-invalid '("fragment identity missing")))
  (when (> (chat-work-context--json-bytes
            (chat-context-fragment-metadata fragment))
           chat-work-context-max-metadata-bytes)
    (signal 'chat-work-context-invalid '("fragment metadata too large")))
  (setf (chat-context-fragment-digest fragment)
        (or (chat-context-fragment-digest fragment)
            (chat-work-context--fragment-digest fragment)))
  fragment)

(defun chat-work-context--authority-rank (value)
  "Return ordering rank for authority VALUE."
  (or (seq-position chat-context-authorities value) 99))

(defun chat-work-context--scope-rank (value)
  "Return descending specificity rank for scope VALUE."
  (or (cdr (assq value '((global . 0) (project . 1) (directory . 2)
                          (path . 3) (session . 4) (turn . 5)
                          (task . 6) (child-task . 7))))
      -1))

(defun chat-work-context--residency-rank (value)
  "Return ordering rank for residency VALUE."
  (pcase value ('protected 0) ('partitioned 1) ('compactable 2) (_ 3)))

(defun chat-work-context--fragment-less-p (left right)
  "Return non-nil when LEFT precedes RIGHT."
  (let ((la (chat-work-context--authority-rank
             (chat-context-fragment-authority left)))
        (ra (chat-work-context--authority-rank
             (chat-context-fragment-authority right)))
        (ls (chat-work-context--scope-rank
             (chat-context-fragment-scope left)))
        (rs (chat-work-context--scope-rank
             (chat-context-fragment-scope right)))
        (lr (chat-work-context--residency-rank
             (chat-context-fragment-residency left)))
        (rr (chat-work-context--residency-rank
             (chat-context-fragment-residency right)))
        (lp (or (chat-context-fragment-priority left) 0))
        (rp (or (chat-context-fragment-priority right) 0)))
    (cond ((/= la ra) (< la ra))
          ((/= ls rs) (< ls rs))
          ((/= lr rr) (< lr rr))
          ((/= lp rp) (> lp rp))
          (t (string< (chat-context-fragment-id left)
                      (chat-context-fragment-id right))))))

(cl-defun chat-context-bundle-build
    (fragments &key session-id turn-id task-id task-lineage project-root
               target-path max-chars)
  "Build a deterministic scoped bundle from FRAGMENTS."
  (let ((context (list :session-id session-id :turn-id turn-id :task-id task-id
                       :task-lineage task-lineage :project-root project-root
                       :target-path target-path))
        selected omitted diagnostics (used 0))
    (dolist (fragment fragments)
      (chat-context-fragment-validate fragment)
      (cond
       ((not (eq (chat-context-fragment-status fragment) 'active))
        (let ((item (list :id (chat-context-fragment-id fragment)
                          :reason 'inactive)))
          (push item omitted)
          (push item diagnostics)))
       ((not (chat-context-scope-matches-p
              (chat-context-fragment-scope fragment)
              (chat-context-fragment-scope-id fragment) context))
        (let ((item (list :id (chat-context-fragment-id fragment)
                          :reason 'scope-mismatch)))
          (push item omitted)
          (push item diagnostics)))
       (t (push fragment selected))))
    (setq selected (sort selected #'chat-work-context--fragment-less-p))
    (when max-chars
      (let (kept)
        (dolist (fragment selected)
          (let ((size (length (format "%s"
                                     (chat-context-fragment-payload fragment)))))
            (if (or (eq (chat-context-fragment-residency fragment) 'protected)
                    (<= (+ used size) max-chars))
                (progn
                  (setq used (+ used size))
                  (push fragment kept)
                  (push (list :id (chat-context-fragment-id fragment)
                              :reason 'selected)
                        diagnostics))
              (let ((item (list :id (chat-context-fragment-id fragment)
                                :reason 'budget)))
                (push item omitted)
                (push item diagnostics)))))
        (setq selected (nreverse kept))))
    (unless max-chars
      (setq used
            (apply #'+
                   (mapcar
                    (lambda (fragment)
                      (push (list :id (chat-context-fragment-id fragment)
                                  :reason 'selected)
                            diagnostics)
                      (length (format "%s"
                                      (chat-context-fragment-payload fragment))))
                    selected))))
    (when (and max-chars (> used max-chars))
      (push (list :reason 'protected-overflow
                  :measured-chars used :max-chars max-chars)
            diagnostics))
    (let ((bundle
           (chat-context-bundle-create
            :session-id session-id :turn-id turn-id :task-id task-id
            :project-root project-root :target-path target-path
            :fragments selected :omitted (nreverse omitted)
            :measured-chars used :diagnostics (nreverse diagnostics)
            :digest (secure-hash
                     'sha256
                     (mapconcat #'chat-context-fragment-digest selected "\n")))))
      (when (and session-id (fboundp 'chat-event-publish))
        (chat-event-publish
         (chat-event-create
          :type 'context-bundle-built :session-id session-id :task-id task-id
          :source 'work-context
          :payload `((digest . ,(chat-context-bundle-digest bundle))
                     (candidateCount . ,(length fragments))
                     (selectedCount . ,(length selected))
                     (omittedCount . ,(length omitted))
                     (measuredChars . ,used)))))
      bundle)))

(defun chat-context-bundle-render (bundle)
  "Render BUNDLE at the compatibility/provider boundary."
  (mapconcat
   (lambda (fragment)
     (format "[%s; authority=%s; scope=%s; source=%s]\n%s"
             (chat-context-fragment-kind fragment)
             (chat-context-fragment-authority fragment)
             (chat-context-fragment-scope fragment)
             (chat-context-fragment-source-id fragment)
             (chat-context-fragment-payload fragment)))
   (chat-context-bundle-fragments bundle) "\n\n"))

(defun chat-work-context--file (session-id)
  "Return the durable state path for SESSION-ID."
  (expand-file-name
   (concat (secure-hash 'sha256 (format "%s" session-id)) ".json")
   chat-work-context-directory))

(defun chat-work-context--note-to-json (note)
  "Return JSON-safe data for NOTE."
  `((schemaVersion . ,(chat-work-note-schema-version note))
    (id . ,(chat-work-note-id note)) (key . ,(chat-work-note-key note))
    (revision . ,(chat-work-note-revision note))
    (kind . ,(symbol-name (chat-work-note-kind note)))
    (value . ,(chat-work-note-value note)) (display . ,(chat-work-note-display note))
    (tags . ,(vconcat (or (chat-work-note-tags note) nil)))
    (relatedIds . ,(vconcat (or (chat-work-note-related-ids note) nil)))
    (sessionId . ,(chat-work-note-session-id note))
    (taskId . ,(chat-work-note-task-id note))
    (scope . ,(symbol-name (chat-work-note-scope note)))
    (scopeId . ,(chat-work-note-scope-id note))
    (sourceKind . ,(symbol-name (chat-work-note-source-kind note)))
    (sourceId . ,(chat-work-note-source-id note))
    (confidence . ,(chat-work-note-confidence note))
    (verification . ,(chat-work-note-verification note))
    (status . ,(symbol-name (chat-work-note-status note)))
    (createdAt . ,(chat-work-note-created-at note))
    (updatedAt . ,(chat-work-note-updated-at note))
    (metadata . ,(chat-work-note-metadata note))))

(defun chat-work-context--note-from-json (data)
  "Decode and validate note DATA."
  (chat-work-note-validate
   (chat-work-note-create-record
    :schema-version (or (alist-get 'schemaVersion data) 0)
    :id (alist-get 'id data) :key (alist-get 'key data)
    :revision (alist-get 'revision data)
    :kind (chat-work-context--symbol (alist-get 'kind data))
    :value (alist-get 'value data) :display (alist-get 'display data)
    :tags (mapcar #'chat-work-context--symbol
                  (append (alist-get 'tags data) nil))
    :related-ids (append (alist-get 'relatedIds data) nil)
    :session-id (alist-get 'sessionId data) :task-id (alist-get 'taskId data)
    :scope (chat-work-context--symbol (alist-get 'scope data))
    :scope-id (alist-get 'scopeId data)
    :source-kind (chat-work-context--symbol (alist-get 'sourceKind data))
    :source-id (alist-get 'sourceId data)
    :confidence (alist-get 'confidence data)
    :verification (alist-get 'verification data)
    :status (chat-work-context--symbol (alist-get 'status data))
    :created-at (alist-get 'createdAt data) :updated-at (alist-get 'updatedAt data)
    :metadata (alist-get 'metadata data))))

(defun chat-work-context--scope-key (scope scope-id key)
  "Return the deterministic index key for SCOPE, SCOPE-ID and KEY."
  (prin1-to-string (list scope scope-id key)))

(defun chat-work-context--index-add (table key id)
  "Add ID to KEY in index TABLE without duplication."
  (puthash key (cons id (delete id (gethash key table))) table))

(defun chat-work-context--build-indexes (table)
  "Build bounded secondary indexes for note TABLE."
  (let ((scope-key (make-hash-table :test 'equal))
        (kind (make-hash-table :test 'eq))
        (tag (make-hash-table :test 'eq)))
    (maphash
     (lambda (id note)
       (when (eq (chat-work-note-status note) 'active)
         (puthash
          (chat-work-context--scope-key
           (chat-work-note-scope note) (chat-work-note-scope-id note)
           (chat-work-note-key note))
          id scope-key)
         (chat-work-context--index-add kind (chat-work-note-kind note) id)
         (dolist (item (chat-work-note-tags note))
           (chat-work-context--index-add tag item id))))
     table)
    (list :scope-key scope-key :kind kind :tag tag)))

(defun chat-work-note-validate (note)
  "Validate and return NOTE."
  (unless (and (chat-work-note-p note)
               (= (or (chat-work-note-schema-version note) 0)
                  chat-work-context-schema-version))
    (signal 'chat-work-context-invalid '("unsupported note schema")))
  (unless (and (stringp (chat-work-note-id note))
               (stringp (chat-work-note-key note))
               (not (string-empty-p (chat-work-note-key note)))
               (stringp (chat-work-note-session-id note)))
    (signal 'chat-work-context-invalid '("note identity missing")))
  (unless (and (integerp (chat-work-note-revision note))
               (> (chat-work-note-revision note) 0))
    (signal 'chat-work-context-invalid '("invalid note revision")))
  (unless (memq (chat-work-note-kind note) chat-work-note-kinds)
    (signal 'chat-work-context-invalid '("invalid note kind")))
  (unless (memq (chat-work-note-status note) chat-work-note-statuses)
    (signal 'chat-work-context-invalid '("invalid note status")))
  (unless (memq (chat-work-note-scope note) chat-context-scopes)
    (signal 'chat-work-context-invalid '("invalid note scope")))
  (unless (or (eq (chat-work-note-scope note) 'global)
              (chat-work-note-scope-id note))
    (signal 'chat-work-context-invalid '("note scope identity missing")))
  (when (and (eq (chat-work-note-scope note) 'session)
             (not (equal (chat-work-note-scope-id note)
                         (chat-work-note-session-id note))))
    (signal 'chat-work-context-invalid '("session note scope mismatch")))
  (unless (memq (chat-work-note-source-kind note)
                '(user agent runtime imported))
    (signal 'chat-work-context-invalid '("invalid note source")))
  (unless (and (numberp (chat-work-note-confidence note))
               (<= 0 (chat-work-note-confidence note) 1))
    (signal 'chat-work-context-invalid '("invalid note confidence")))
  (when (> (chat-work-context--json-bytes (chat-work-note-value note))
           chat-work-context-max-value-bytes)
    (signal 'chat-work-context-invalid '("note value too large")))
  (when (> (chat-work-context--json-bytes (chat-work-note-metadata note))
           chat-work-context-max-metadata-bytes)
    (signal 'chat-work-context-invalid '("note metadata too large")))
  (setf (chat-work-note-tags note)
        (delete-dups
         (mapcar #'chat-work-context--symbol
                 (or (chat-work-note-tags note) nil))))
  note)

(defun chat-work-context--load (session-id)
  "Return SESSION-ID's note table, loading it once."
  (or (gethash session-id chat-work-context--stores)
      (let ((table (make-hash-table :test 'equal))
            (file (chat-work-context--file session-id)))
        (when (file-exists-p file)
          (let* ((data (json-parse-string
                        (with-temp-buffer
                          (insert-file-contents file) (buffer-string))
                        :object-type 'alist :array-type 'list
                        :null-object nil :false-object nil))
                 (schema (alist-get 'schemaVersion data)))
            (unless (= (or schema 0) chat-work-context-schema-version)
              (signal 'chat-work-context-invalid
                      (list "unsupported work context schema" schema)))
            (dolist (item (alist-get 'notes data))
              (let ((note (chat-work-context--note-from-json item)))
                (puthash (chat-work-note-id note) note table)))))
        (puthash session-id table chat-work-context--stores)
        (puthash session-id (chat-work-context--build-indexes table)
                 chat-work-context--indexes)
        table)))

(defun chat-work-context--save (session-id table)
  "Atomically save SESSION-ID's note TABLE."
  (make-directory chat-work-context-directory t)
  (let* ((file (chat-work-context--file session-id))
         (temp (make-temp-file
                (expand-file-name ".work-context-" chat-work-context-directory)))
         notes)
    (maphash (lambda (_id note) (push note notes)) table)
    (setq notes (sort notes (lambda (left right)
                              (string< (chat-work-note-id left)
                                       (chat-work-note-id right)))))
    (unwind-protect
        (progn
          (with-temp-file temp
            (insert (json-encode
                     `((schemaVersion . ,chat-work-context-schema-version)
                       (sessionId . ,session-id)
                       (notes . ,(vconcat
                                  (mapcar #'chat-work-context--note-to-json
                                          notes)))))))
          (rename-file temp file t))
      (when (file-exists-p temp) (delete-file temp))))
  (puthash session-id (chat-work-context--build-indexes table)
           chat-work-context--indexes))

(defun chat-work-context--emit-note (note type)
  "Publish bounded lifecycle TYPE for NOTE."
  (when (fboundp 'chat-event-publish)
    (let ((event (chat-event-create
                  :type type :session-id (chat-work-note-session-id note)
                  :task-id (chat-work-note-task-id note) :source 'work-context
                  :payload `((id . ,(chat-work-note-id note))
                             (key . ,(chat-work-note-key note))
                             (revision . ,(chat-work-note-revision note))
                             (kind . ,(chat-work-note-kind note))
                             (status . ,(chat-work-note-status note))))))
      (chat-event-publish event))))

(defun chat-work-context--revision-conflict (note)
  "Emit a bounded revision conflict for NOTE and signal it."
  (chat-work-context--emit-note note 'work-note-conflict)
  (signal 'chat-work-context-stale-revision
          (list (chat-work-note-id note)
                (chat-work-note-revision note))))

(cl-defun chat-work-note-upsert
    (session-id key value &key expected-revision task-id (kind 'note) tags
                related-ids (scope 'session) scope-id (source-kind 'agent)
                source-id (confidence 0.5) verification display metadata)
  "Create or update KEY in SESSION-ID with optimistic revision control."
  (setq scope-id
        (chat-work-context--normalize-scope-id scope scope-id session-id task-id))
  (let* ((table (chat-work-context--load session-id))
         (indexes (or (gethash session-id chat-work-context--indexes)
                      (chat-work-context--build-indexes table)))
         (existing-id
          (gethash (chat-work-context--scope-key scope scope-id key)
                   (plist-get indexes :scope-key)))
         (existing (and existing-id (gethash existing-id table))))
    (when (and existing
               (not (equal expected-revision
                           (chat-work-note-revision existing))))
      (chat-work-context--revision-conflict existing))
    (when (and (null existing) expected-revision)
      (signal 'chat-work-context-stale-revision (list nil 0)))
    (when (and (null existing)
               (>= (hash-table-count table) chat-work-context-max-notes))
      (signal 'chat-work-context-invalid '("note limit reached")))
    (let* ((now (chat-work-context--timestamp))
           (note (chat-work-note-create-record
                  :id (if existing (chat-work-note-id existing)
                        (format "work-note-%s-%06x" now (random #x1000000)))
                  :key key :revision (if existing (1+ expected-revision) 1)
                  :kind kind :value value :display display :tags tags
                  :related-ids related-ids :session-id session-id :task-id task-id
                  :scope scope :scope-id scope-id
                  :source-kind source-kind
                  :source-id (or source-id "agent:unknown")
                  :confidence confidence :verification verification :status 'active
                  :created-at (if existing (chat-work-note-created-at existing) now)
                  :updated-at now :metadata metadata)))
      (chat-work-note-validate note)
      (puthash (chat-work-note-id note) note table)
      (chat-work-context--save session-id table)
      (chat-work-context--emit-note note
                                    (if existing 'work-note-updated
                                      'work-note-created))
      note)))

(cl-defun chat-work-note-list (session-id &key task-id kind tag status context)
  "Return deterministically ordered notes matching filters."
  (let* ((table (chat-work-context--load session-id))
         (indexes (or (gethash session-id chat-work-context--indexes)
                      (chat-work-context--build-indexes table)))
         (candidate-ids
          (cond
           ((and kind tag)
            (seq-intersection (gethash kind (plist-get indexes :kind))
                              (gethash tag (plist-get indexes :tag)) #'equal))
           (kind (copy-sequence (gethash kind (plist-get indexes :kind))))
           (tag (copy-sequence (gethash tag (plist-get indexes :tag))))
           (t (let (ids) (maphash (lambda (id _note) (push id ids)) table) ids))))
         notes)
    (dolist (id candidate-ids)
      (let ((note (gethash id table)))
       (when (and (or (null task-id) (equal task-id (chat-work-note-task-id note)))
                  (or (null kind) (eq kind (chat-work-note-kind note)))
                  (or (null tag) (member tag (chat-work-note-tags note)))
                  (or (null status) (eq status (chat-work-note-status note)))
                  (or (null context)
                      (chat-context-scope-matches-p
                       (chat-work-note-scope note)
                       (chat-work-note-scope-id note) context)))
          (push note notes))))
    (sort notes (lambda (left right)
                  (let ((lu (chat-work-note-updated-at left))
                        (ru (chat-work-note-updated-at right)))
                    (if (/= lu ru) (> lu ru)
                      (string< (chat-work-note-id left)
                               (chat-work-note-id right))))))))

(defun chat-work-note-get (session-id id)
  "Return note ID in SESSION-ID."
  (gethash id (chat-work-context--load session-id)))

(defun chat-work-note-set-status (session-id id expected-revision status)
  "Set note ID to STATUS when EXPECTED-REVISION matches."
  (unless (memq status chat-work-note-statuses)
    (signal 'chat-work-context-invalid '("invalid note status")))
  (let* ((table (chat-work-context--load session-id))
         (note (gethash id table)))
    (unless note (signal 'chat-work-context-invalid '("unknown note")))
    (unless (= expected-revision (chat-work-note-revision note))
      (chat-work-context--revision-conflict note))
    (setf (chat-work-note-status note) status
          (chat-work-note-revision note) (1+ expected-revision)
          (chat-work-note-updated-at note) (chat-work-context--timestamp))
    (chat-work-context--save session-id table)
    (chat-work-context--emit-note note
                                  (intern (format "work-note-%s" status)))
    note))

(defun chat-work-note-resolve (session-id id expected-revision)
  "Resolve note ID in SESSION-ID at EXPECTED-REVISION."
  (chat-work-note-set-status session-id id expected-revision 'resolved))

(cl-defun chat-work-note-supersede
    (session-id id expected-revision key value
                &key kind tags related-ids source-kind source-id confidence
                verification display metadata)
  "Supersede note ID and create a distinct active replacement atomically."
  (let* ((table (chat-work-context--load session-id))
         (old (gethash id table)))
    (unless old (signal 'chat-work-context-invalid '("unknown note")))
    (unless (= expected-revision (chat-work-note-revision old))
      (chat-work-context--revision-conflict old))
    (when (>= (hash-table-count table) chat-work-context-max-notes)
      (signal 'chat-work-context-invalid '("note limit reached")))
    (let* ((now (chat-work-context--timestamp))
           (replacement
            (chat-work-note-create-record
             :id (format "work-note-%s-%06x" now (random #x1000000))
             :key key :revision 1 :kind (or kind (chat-work-note-kind old))
             :value value :display display
             :tags (or tags (chat-work-note-tags old))
             :related-ids (delete-dups
                           (cons id (append related-ids
                                            (chat-work-note-related-ids old))))
             :session-id session-id :task-id (chat-work-note-task-id old)
             :scope (chat-work-note-scope old)
             :scope-id (chat-work-note-scope-id old)
             :source-kind (or source-kind 'agent)
             :source-id (or source-id "agent:unknown")
             :confidence (or confidence (chat-work-note-confidence old))
             :verification (or verification (chat-work-note-verification old))
             :status 'active :created-at now :updated-at now :metadata metadata)))
      (chat-work-note-validate replacement)
      (setf (chat-work-note-status old) 'superseded
            (chat-work-note-revision old) (1+ expected-revision)
            (chat-work-note-updated-at old) now)
      (puthash (chat-work-note-id replacement) replacement table)
      (chat-work-context--save session-id table)
      (chat-work-context--emit-note old 'work-note-superseded)
      (chat-work-context--emit-note replacement 'work-note-created)
      replacement)))

(defun chat-work-note-delete (session-id id expected-revision)
  "Delete note ID when EXPECTED-REVISION matches."
  (let* ((table (chat-work-context--load session-id))
         (note (gethash id table)))
    (unless note (signal 'chat-work-context-invalid '("unknown note")))
    (unless (= expected-revision (chat-work-note-revision note))
      (chat-work-context--revision-conflict note))
    (remhash id table)
    (chat-work-context--save session-id table)
    (chat-work-context--emit-note note 'work-note-deleted)
    t))

(defun chat-work-note-fragments (session-id context)
  "Return active scoped note fragments for SESSION-ID and CONTEXT."
  (mapcar
   (lambda (note)
     (chat-context-fragment-create
      :id (concat "fragment:" (chat-work-note-id note))
      :kind 'working-note :authority 'agent :source-kind 'work-note
      :source-id (chat-work-note-id note) :scope (chat-work-note-scope note)
      :scope-id (chat-work-note-scope-id note) :priority 50
      :residency (if (memq (chat-work-note-kind note)
                            '(blocker decision constraint next-step))
                     'protected 'compactable)
      :budget-policy 'compact
      :payload (format "%s=%s%s"
                       (chat-work-note-key note)
                       (or (chat-work-note-display note)
                           (format "%s" (chat-work-note-value note)))
                       (if (eq (chat-work-note-kind note) 'hypothesis)
                           " [unverified]" ""))
      :status 'active :metadata `((revision . ,(chat-work-note-revision note)))))
   (chat-work-note-list session-id :status 'active :context context)))

(defun chat-work-note-to-alist (note)
  "Return a bounded public projection of NOTE."
  `((id . ,(chat-work-note-id note)) (key . ,(chat-work-note-key note))
    (revision . ,(chat-work-note-revision note))
    (kind . ,(symbol-name (chat-work-note-kind note)))
    (value . ,(chat-work-note-value note)) (display . ,(chat-work-note-display note))
    (tags . ,(vconcat (mapcar #'symbol-name (or (chat-work-note-tags note) nil))))
    (relatedIds . ,(vconcat (or (chat-work-note-related-ids note) nil)))
    (sessionId . ,(chat-work-note-session-id note))
    (taskId . ,(chat-work-note-task-id note))
    (scope . ,(symbol-name (chat-work-note-scope note)))
    (scopeId . ,(chat-work-note-scope-id note))
    (sourceKind . ,(symbol-name (chat-work-note-source-kind note)))
    (sourceId . ,(chat-work-note-source-id note))
    (confidence . ,(chat-work-note-confidence note))
    (verification . ,(chat-work-note-verification note))
    (status . ,(symbol-name (chat-work-note-status note)))
    (createdAt . ,(chat-work-note-created-at note))
    (updatedAt . ,(chat-work-note-updated-at note))))

(provide 'chat-work-context)
;;; chat-work-context.el ends here
