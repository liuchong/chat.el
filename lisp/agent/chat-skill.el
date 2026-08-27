;;; chat-skill.el --- Declarative, lazy agent knowledge packs -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A skill contributes knowledge and declares what runtime capabilities it
;; expects.  Manifests are data only: discovery indexes file names, while the
;; manifest and its instructions are parsed only when a profile selects it.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-extension-trust)

(defgroup chat-skill nil
  "Declarative knowledge packs for agent profiles."
  :group 'chat)

(defconst chat-skill-schema-version 1
  "Current skill manifest schema version.")

(define-error 'chat-skill-unsupported-schema
  "Unsupported skill manifest schema")

(defcustom chat-skill-user-directory
  (expand-file-name "skills/" (expand-file-name "~/.chat/"))
  "Directory containing user skill manifests."
  :type 'directory
  :group 'chat-skill)

(defcustom chat-skill-project-directory-name ".chat/skills"
  "Project-relative directory containing skill manifests."
  :type 'string
  :group 'chat-skill)

(defcustom chat-skill-additional-directories nil
  "Additional skill manifest directories, in increasing priority order."
  :type '(repeat directory)
  :group 'chat-skill)

(defcustom chat-skill-manifest-max-bytes (* 256 1024)
  "Maximum accepted size of one skill manifest."
  :type 'integer
  :group 'chat-skill)

(defcustom chat-skill-instructions-max-chars (* 64 1024)
  "Maximum instruction text accepted from one skill."
  :type 'integer
  :group 'chat-skill)

(cl-defstruct
    (chat-skill
     (:constructor chat-skill-create
                   (&key (schema-version chat-skill-schema-version)
                         id revision description instructions tools
                         capability-requirements source path digest)))
  "One validated skill declaration."
  schema-version id revision description instructions tools
  capability-requirements source path digest)

(cl-defstruct (chat-skill--candidate
               (:constructor chat-skill--candidate-create))
  id path scope priority)

(defvar chat-skill--registry (make-hash-table :test 'eq)
  "Explicit skill declarations keyed by id.")

(defvar chat-skill--candidates (make-hash-table :test 'eq)
  "Discovered manifest candidates keyed by id.")

(defvar chat-skill--discovery-root nil
  "Canonical project root used for the current candidate index.")

(defvar chat-skill--discovered-p nil
  "Whether the candidate index has been populated at least once.")

(defun chat-skill--validate (skill)
  "Validate and return SKILL."
  (unless (chat-skill-p skill)
    (error "Not a skill declaration: %S" skill))
  (let ((version (chat-skill-schema-version skill))
        (instructions (or (chat-skill-instructions skill) "")))
    (when (> version chat-skill-schema-version)
      (signal 'chat-skill-unsupported-schema (list version)))
    (unless (= version chat-skill-schema-version)
      (error "Skill schema must be %d" chat-skill-schema-version))
    (unless (symbolp (chat-skill-id skill))
      (error "Skill id must be a symbol"))
    (unless (and (or (null (chat-skill-revision skill))
                     (stringp (chat-skill-revision skill)))
                 (or (null (chat-skill-description skill))
                     (stringp (chat-skill-description skill)))
                 (stringp instructions))
      (error "Skill revision, description, and instructions must be text"))
    (when (> (length instructions) chat-skill-instructions-max-chars)
      (error "Skill instructions exceed the configured limit: %s"
             (chat-skill-id skill)))
    (unless (seq-every-p #'symbolp (or (chat-skill-tools skill) nil))
      (error "Skill tools must be symbols: %s" (chat-skill-id skill)))
    (cl-loop for (key _value) on
             (chat-skill-capability-requirements skill) by #'cddr
             do (chat-skill-capability-key
                 (if (keywordp key)
                     (substring (symbol-name key) 1)
                   key))))
  skill)

(defun chat-skill--json-get (object key)
  "Return KEY from parsed JSON OBJECT, accepting symbol or string keys."
  (or (alist-get key object)
      (alist-get (symbol-name key) object nil nil #'equal)))

(defun chat-skill--false-to-nil (value)
  "Normalize JSON false VALUE to nil."
  (if (eq value :json-false) nil value))

(defun chat-skill--symbol (value field)
  "Return VALUE as a symbol suitable for FIELD."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t (error "Skill %s must name a symbol: %S" field value))))

(defun chat-skill--symbol-list (value field)
  "Return JSON array VALUE as a symbol list for FIELD."
  (cond ((null value) nil)
        ((listp value)
         (mapcar (lambda (item) (chat-skill--symbol item field)) value))
        ((vectorp value)
         (mapcar (lambda (item) (chat-skill--symbol item field))
                 (append value nil)))
        (t (error "Skill %s must be an array" field))))

(defun chat-skill--requirements (object)
  "Normalize capability requirement JSON OBJECT to a keyword plist."
  (let (requirements)
    (dolist (entry object)
      (let* ((name (if (symbolp (car entry))
                       (symbol-name (car entry))
                     (car entry)))
             (key (chat-skill-capability-key name))
             (value (chat-skill--false-to-nil (cdr entry))))
        (setq requirements
              (plist-put requirements key
                         (cond ((vectorp value) (append value nil))
                               (t value))))))
    requirements))

(defun chat-skill-capability-key (name)
  "Return the canonical model capability keyword for NAME."
  (let ((plain (if (symbolp name) (symbol-name name) name)))
    (or (cdr (assoc plain
                    '(("stream" . :stream)
                      ("tools" . :tools)
                      ("toolChoice" . :tool-choice)
                      ("tool-choice" . :tool-choice)
                      ("reasoning" . :reasoning)
                      ("inputModalities" . :input-modalities)
                      ("input-modalities" . :input-modalities)
                      ("structuredOutput" . :structured-output)
                      ("structured-output" . :structured-output)
                      ("contextWindow" . :context-window)
                      ("context-window" . :context-window)
                      ("maxOutputTokens" . :max-output-tokens)
                      ("max-output-tokens" . :max-output-tokens)
                      ("supportedOptions" . :supported-options)
                      ("supported-options" . :supported-options))))
        (error "Unknown model capability requirement: %s" name))))

(defun chat-skill--manifest-id (path)
  "Return the skill id encoded by manifest PATH."
  (intern (string-remove-suffix
           ".skill.json" (file-name-nondirectory path))))

(defun chat-skill--candidate-less-p (left right)
  "Return non-nil when candidate LEFT has lower precedence than RIGHT."
  (let ((lp (chat-skill--candidate-priority left))
        (rp (chat-skill--candidate-priority right)))
    (if (= lp rp)
        (string< (chat-skill--candidate-path left)
                 (chat-skill--candidate-path right))
      (< lp rp))))

(defun chat-skill--index-directory (directory scope priority)
  "Index manifests under DIRECTORY with SCOPE and PRIORITY."
  (when (file-directory-p directory)
    (dolist (path (directory-files directory t "\\.skill\\.json\\'" t))
      (let* ((id (chat-skill--manifest-id path))
             (candidate (chat-skill--candidate-create
                         :id id :path path :scope scope :priority priority)))
        (puthash id
                 (cons candidate (gethash id chat-skill--candidates))
                 chat-skill--candidates)))))

(defun chat-skill-discover (&optional project-root)
  "Refresh the lazy skill index for optional PROJECT-ROOT.

No manifest body is parsed by this operation."
  (clrhash chat-skill--candidates)
  (setq chat-skill--discovery-root
        (and project-root
             (chat-extension--canonical-directory project-root)))
  (setq chat-skill--discovered-p t)
  (chat-skill--index-directory chat-skill-user-directory 'user 10)
  (cl-loop for directory in chat-skill-additional-directories
           for priority from 20
           do (chat-skill--index-directory directory 'additional priority))
  (when (and project-root
             (chat-extension-project-trusted-p project-root))
    (chat-skill--index-directory
     (expand-file-name chat-skill-project-directory-name project-root)
     'project 100))
  chat-skill--candidates)

(defun chat-skill-register (skill)
  "Register explicit SKILL, replacing an explicit declaration of its id."
  (chat-skill--validate skill)
  (puthash (chat-skill-id skill) skill chat-skill--registry)
  skill)

(defun chat-skill-unregister (id)
  "Remove explicit skill ID and return non-nil when it existed."
  (prog1 (gethash id chat-skill--registry)
    (remhash id chat-skill--registry)))

(defun chat-skill--read-file (candidate)
  "Parse and validate one skill CANDIDATE."
  (let* ((path (chat-skill--candidate-path candidate))
         (attributes (file-attributes path))
         (size (and attributes (file-attribute-size attributes))))
    (unless (and size (<= size chat-skill-manifest-max-bytes))
      (error "Skill manifest is too large: %s" path))
    (with-temp-buffer
      (insert-file-contents path)
      (let* ((text (buffer-string))
             (object (json-parse-string
                      text :object-type 'alist :array-type 'list
                      :null-object nil :false-object :json-false))
             (version (or (chat-skill--json-get object 'schemaVersion) 0))
             (id (chat-skill--symbol
                  (chat-skill--json-get object 'id) "id"))
             (instructions
              (or (chat-skill--json-get object 'instructions) "")))
        (when (> version chat-skill-schema-version)
          (signal 'chat-skill-unsupported-schema (list version path)))
        (unless (= version chat-skill-schema-version)
          (error "Skill manifest schema must be %d: %s"
                 chat-skill-schema-version path))
        (unless (eq id (chat-skill--candidate-id candidate))
          (error "Skill id %s does not match manifest name %s" id path))
        (unless (and (stringp instructions)
                     (<= (length instructions)
                         chat-skill-instructions-max-chars))
          (error "Skill instructions are invalid or too large: %s" path))
        (chat-skill--validate
         (chat-skill-create
          :id id
          :revision (format "%s"
                            (or (chat-skill--json-get object 'revision) "1"))
          :description (or (chat-skill--json-get object 'description) "")
          :instructions instructions
          :tools (chat-skill--symbol-list
                  (chat-skill--json-get object 'tools) "tools")
          :capability-requirements
          (chat-skill--requirements
           (or (chat-skill--json-get object 'capabilityRequirements) nil))
          :source (chat-skill--candidate-scope candidate)
          :path path
          :digest (secure-hash 'sha256 text)))))))

(defun chat-skill-resolve (id &optional project-root)
  "Resolve skill ID for optional PROJECT-ROOT, loading it on demand."
  (let ((id (chat-skill--symbol id "id")))
    (or (gethash id chat-skill--registry)
        (progn
          (unless (and chat-skill--discovered-p
                       (equal chat-skill--discovery-root
                              (and project-root
                                   (chat-extension--canonical-directory
                                    project-root))))
            (chat-skill-discover project-root))
          ;; A manifest may have appeared since startup.  Refresh once on a
          ;; miss; successful lookups remain metadata-only and allocation
          ;; free until the selected manifest is parsed below.
          (unless (gethash id chat-skill--candidates)
            (chat-skill-discover project-root))
          (when-let* ((candidates (gethash id chat-skill--candidates))
                      (candidate (car (last
                                       (sort (copy-sequence candidates)
                                             #'chat-skill--candidate-less-p)))))
            (chat-skill--read-file candidate)))
        (error "Unknown skill: %s" id))))

(defun chat-skill-list (&optional project-root)
  "Return skill ids visible for optional PROJECT-ROOT without loading them."
  (chat-skill-discover project-root)
  (let (ids)
    (maphash (lambda (id _skill) (cl-pushnew id ids)) chat-skill--registry)
    (maphash (lambda (id _candidates) (cl-pushnew id ids))
             chat-skill--candidates)
    (sort ids (lambda (left right)
                (string< (symbol-name left) (symbol-name right))))))

(provide 'chat-skill)
;;; chat-skill.el ends here
