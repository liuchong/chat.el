;;; chat-agent-profile.el --- Composable, auditable agent profiles -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Agent profiles select role instructions, model facts, skills, tool
;; authority, approval strictness, and run budgets.  Resolution produces one
;; immutable snapshot before a run begins.  The snapshot is kept on the run
;; and projected into the session event stream without persisting prompt text.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-approval)
(require 'chat-extension-trust)
(require 'chat-model-capabilities)
(require 'chat-session)
(require 'chat-skill)

(defgroup chat-agent-profile nil
  "Composable role declarations for agent runs."
  :group 'chat)

(defconst chat-agent-profile-schema-version 1
  "Current agent profile schema version.")

(define-error 'chat-agent-profile-unsupported-schema
  "Unsupported agent profile schema")
(define-error 'chat-agent-profile-cycle
  "Agent profile inheritance cycle")
(define-error 'chat-agent-profile-capability-mismatch
  "Agent profile model capability mismatch")
(define-error 'chat-agent-profile-authority-expansion
  "Agent profile or skill would expand session authority")

(defcustom chat-agent-profile-user-directory
  (expand-file-name "agents/" (expand-file-name "~/.chat/"))
  "Directory containing user agent profile manifests."
  :type 'directory
  :group 'chat-agent-profile)

(defcustom chat-agent-profile-project-directory-name ".chat/agents"
  "Project-relative directory containing agent profile manifests."
  :type 'string
  :group 'chat-agent-profile)

(defcustom chat-agent-profile-additional-directories nil
  "Additional agent profile directories, in increasing priority order."
  :type '(repeat directory)
  :group 'chat-agent-profile)

(defcustom chat-agent-profile-manifest-max-bytes (* 256 1024)
  "Maximum accepted size of one agent profile manifest."
  :type 'integer
  :group 'chat-agent-profile)

(defcustom chat-agent-profile-instructions-max-chars (* 128 1024)
  "Maximum merged role and skill instruction text for one run."
  :type 'integer
  :group 'chat-agent-profile)

(defconst chat-agent-profile-audit-tool-limit 128
  "Maximum tool ids retained in one resolved profile audit snapshot.")

(cl-defstruct
    (chat-agent-profile
     (:constructor
      chat-agent-profile-create
      (&key (schema-version chat-agent-profile-schema-version)
            id revision extends instructions provider model
            required-capabilities skills resolved-skills tools
            tools-specified-p disabled-tools approval-mode max-steps
            context-budget subagent-limit background source path digest
            provenance diagnostics resolved-p)))
  "One declared or resolved agent profile."
  schema-version id revision extends instructions provider model
  required-capabilities skills resolved-skills tools tools-specified-p
  disabled-tools approval-mode max-steps context-budget subagent-limit
  background source path digest provenance diagnostics resolved-p)

(cl-defstruct (chat-agent-profile--candidate
               (:constructor chat-agent-profile--candidate-create))
  id path scope priority)

(defvar chat-agent-profile--registry (make-hash-table :test 'eq)
  "Explicit agent profile declarations keyed by id.")

(defvar chat-agent-profile--candidates (make-hash-table :test 'eq)
  "Discovered agent profile candidates keyed by id.")

(defvar chat-agent-profile--discovery-root nil
  "Canonical project root used for the current profile index.")

(defvar chat-agent-profile--discovered-p nil
  "Whether profile candidates have been indexed at least once.")

(defun chat-agent-profile--validate (profile)
  "Validate and return declared PROFILE."
  (unless (chat-agent-profile-p profile)
    (error "Not an agent profile: %S" profile))
  (let ((version (chat-agent-profile-schema-version profile))
        (approval (chat-agent-profile-approval-mode profile)))
    (when (> version chat-agent-profile-schema-version)
      (signal 'chat-agent-profile-unsupported-schema (list version)))
    (unless (= version chat-agent-profile-schema-version)
      (error "Agent profile schema must be %d"
             chat-agent-profile-schema-version))
    (unless (symbolp (chat-agent-profile-id profile))
      (error "Agent profile id must be a symbol"))
    (unless (seq-every-p
             #'symbolp
             (append (chat-agent-profile-extends profile)
                     (chat-agent-profile-skills profile)
                     (chat-agent-profile-tools profile)
                     (chat-agent-profile-disabled-tools profile)))
      (error "Agent profile references must be symbols: %s"
             (chat-agent-profile-id profile)))
    (unless (or (null (chat-agent-profile-instructions profile))
                (stringp (chat-agent-profile-instructions profile)))
      (error "Agent profile instructions must be text"))
    (unless (or (null (chat-agent-profile-provider profile))
                (symbolp (chat-agent-profile-provider profile)))
      (error "Agent profile provider must be a symbol"))
    (unless (or (null (chat-agent-profile-model profile))
                (stringp (chat-agent-profile-model profile)))
      (error "Agent profile model must be text"))
    (when (and approval
               (null (chat-agent-profile--approval-rank approval)))
      (error "Unknown agent profile approval mode: %S" approval))
    (dolist (value (list (chat-agent-profile-max-steps profile)
                         (chat-agent-profile-context-budget profile)
                         (chat-agent-profile-subagent-limit profile)))
      (unless (or (null value) (and (integerp value) (> value 0)))
        (error "Agent profile limits must be positive integers"))))
  profile)

(defun chat-agent-profile--symbol (value field &optional allow-nil)
  "Return VALUE as a symbol suitable for FIELD.
When ALLOW-NIL is non-nil, nil is accepted."
  (cond ((and allow-nil (null value)) nil)
        ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t (error "Agent profile %s must name a symbol: %S" field value))))

(defun chat-agent-profile--symbol-list (value field)
  "Return VALUE as a list of symbols for FIELD."
  (cond ((null value) nil)
        ((vectorp value)
         (chat-agent-profile--symbol-list (append value nil) field))
        ((listp value)
         (mapcar (lambda (item)
                   (chat-agent-profile--symbol item field))
                 value))
        (t (error "Agent profile %s must be an array" field))))

(defun chat-agent-profile--manifest-id (path)
  "Return the profile id encoded by manifest PATH."
  (intern (string-remove-suffix
           ".agent.json" (file-name-nondirectory path))))

(defun chat-agent-profile--candidate-less-p (left right)
  "Return non-nil when candidate LEFT has lower precedence than RIGHT."
  (let ((lp (chat-agent-profile--candidate-priority left))
        (rp (chat-agent-profile--candidate-priority right)))
    (if (= lp rp)
        (string< (chat-agent-profile--candidate-path left)
                 (chat-agent-profile--candidate-path right))
      (< lp rp))))

(defun chat-agent-profile--index-directory (directory scope priority)
  "Index profile manifests under DIRECTORY with SCOPE and PRIORITY."
  (when (file-directory-p directory)
    (dolist (path (directory-files directory t "\\.agent\\.json\\'" t))
      (let* ((id (chat-agent-profile--manifest-id path))
             (candidate
              (chat-agent-profile--candidate-create
               :id id :path path :scope scope :priority priority)))
        (puthash id
                 (cons candidate
                       (gethash id chat-agent-profile--candidates))
                 chat-agent-profile--candidates)))))

(defun chat-agent-profile-discover (&optional project-root)
  "Refresh profile manifest metadata for optional PROJECT-ROOT."
  (clrhash chat-agent-profile--candidates)
  (setq chat-agent-profile--discovery-root
        (and project-root
             (chat-extension--canonical-directory project-root)))
  (setq chat-agent-profile--discovered-p t)
  (chat-agent-profile--index-directory
   chat-agent-profile-user-directory 'user 10)
  (cl-loop for directory in chat-agent-profile-additional-directories
           for priority from 20
           do (chat-agent-profile--index-directory
               directory 'additional priority))
  (when (and project-root
             (chat-extension-project-trusted-p project-root))
    (chat-agent-profile--index-directory
     (expand-file-name chat-agent-profile-project-directory-name project-root)
     'project 100))
  chat-agent-profile--candidates)

(defun chat-agent-profile-register (profile)
  "Register explicit PROFILE and return it."
  (chat-agent-profile--validate profile)
  (puthash (chat-agent-profile-id profile) profile
           chat-agent-profile--registry)
  profile)

(defun chat-agent-profile-unregister (id)
  "Remove explicit profile ID and return the old declaration."
  (prog1 (gethash id chat-agent-profile--registry)
    (remhash id chat-agent-profile--registry)))

(defun chat-agent-profile-list (&optional project-root)
  "Return profile ids visible for optional PROJECT-ROOT without resolving them."
  (chat-agent-profile-discover project-root)
  (let (ids)
    (maphash (lambda (id _profile) (cl-pushnew id ids))
             chat-agent-profile--registry)
    (maphash (lambda (id _candidates) (cl-pushnew id ids))
             chat-agent-profile--candidates)
    (sort ids (lambda (left right)
                (string< (symbol-name left) (symbol-name right))))))

;;;###autoload
(defun chat-agent-profile-select (profile &optional session project-root)
  "Select PROFILE for SESSION, resolving it against PROJECT-ROOT first."
  (interactive
   (let* ((session (and (boundp 'chat--current-session)
                        chat--current-session))
          (root default-directory)
          (choices (mapcar #'symbol-name
                           (chat-agent-profile-list root))))
     (list (intern (completing-read "Agent profile: " choices nil t))
           session root)))
  (let ((session (or session
                     (and (boundp 'chat--current-session)
                          chat--current-session))))
    (unless session
      (error "No current chat session"))
    (chat-agent-profile-resolve profile (or project-root default-directory))
    (let ((config (copy-tree (chat-session-tool-config session))))
      (chat-session-set-tool-config
       session (plist-put config :profile profile)))
    profile))

;;;###autoload
(defun chat-agent-profile-clear (&optional session)
  "Clear the selected agent profile from SESSION."
  (interactive)
  (let ((session (or session
                     (and (boundp 'chat--current-session)
                          chat--current-session))))
    (unless session
      (error "No current chat session"))
    (let (clean)
      (cl-loop for (key value) on (chat-session-tool-config session) by #'cddr
               unless (eq key :profile)
               do (setq clean (append clean (list key value))))
      (chat-session-set-tool-config session clean))
    t))

(defun chat-agent-profile--read-file (candidate)
  "Parse and validate profile CANDIDATE."
  (let* ((path (chat-agent-profile--candidate-path candidate))
         (attributes (file-attributes path))
         (size (and attributes (file-attribute-size attributes))))
    (unless (and size (<= size chat-agent-profile-manifest-max-bytes))
      (error "Agent profile manifest is too large: %s" path))
    (with-temp-buffer
      (insert-file-contents path)
      (let* ((text (buffer-string))
             (object (json-parse-string
                      text :object-type 'alist :array-type 'list
                      :null-object nil :false-object :json-false))
             (version (or (chat-skill--json-get object 'schemaVersion) 0))
             (id (chat-agent-profile--symbol
                  (chat-skill--json-get object 'id) "id"))
             (instructions
              (or (chat-skill--json-get object 'instructions) ""))
             (tools-value (chat-skill--json-get object 'tools)))
        (when (> version chat-agent-profile-schema-version)
          (signal 'chat-agent-profile-unsupported-schema
                  (list version path)))
        (unless (= version chat-agent-profile-schema-version)
          (error "Agent profile schema must be %d: %s"
                 chat-agent-profile-schema-version path))
        (unless (eq id (chat-agent-profile--candidate-id candidate))
          (error "Agent profile id %s does not match manifest name %s"
                 id path))
        (unless (stringp instructions)
          (error "Agent profile instructions must be text: %s" path))
        (chat-agent-profile--validate
         (chat-agent-profile-create
          :id id
         :revision (format "%s"
                           (or (chat-skill--json-get object 'revision) "1"))
         :extends (chat-agent-profile--symbol-list
                   (chat-skill--json-get object 'extends) "extends")
         :instructions instructions
         :provider (chat-agent-profile--symbol
                    (chat-skill--json-get object 'provider)
                    "provider" t)
         :model (chat-skill--json-get object 'model)
         :required-capabilities
         (chat-skill--requirements
          (or (chat-skill--json-get object 'capabilityRequirements) nil))
         :skills (chat-agent-profile--symbol-list
                  (chat-skill--json-get object 'skills) "skills")
         :tools (chat-agent-profile--symbol-list tools-value "tools")
         :tools-specified-p
         (or tools-value
             (assoc 'tools object)
             (assoc "tools" object))
         :disabled-tools
         (chat-agent-profile--symbol-list
          (chat-skill--json-get object 'disabledTools) "disabledTools")
         :approval-mode
         (chat-agent-profile--symbol
          (chat-skill--json-get object 'approvalMode) "approvalMode" t)
         :max-steps (chat-skill--json-get object 'maxSteps)
         :context-budget (chat-skill--json-get object 'contextBudget)
         :subagent-limit (chat-skill--json-get object 'subagentLimit)
         :background (chat-skill--false-to-nil
                      (chat-skill--json-get object 'background))
          :source (chat-agent-profile--candidate-scope candidate)
          :path path
          :digest (secure-hash 'sha256 text)))))))

(defun chat-agent-profile--registered-priority (profile)
  "Return precedence for explicitly registered PROFILE."
  (if (eq (chat-agent-profile-source profile) 'builtin) 0 1000))

(defun chat-agent-profile--declaration (id project-root)
  "Return the highest-precedence declaration for ID at PROJECT-ROOT."
  (unless (and chat-agent-profile--discovered-p
               (equal chat-agent-profile--discovery-root
                      (and project-root
                           (chat-extension--canonical-directory
                            project-root))))
    (chat-agent-profile-discover project-root))
  (unless (or (gethash id chat-agent-profile--registry)
              (gethash id chat-agent-profile--candidates))
    (chat-agent-profile-discover project-root))
  (let* ((registered (gethash id chat-agent-profile--registry))
         (candidates (gethash id chat-agent-profile--candidates))
         (candidate (and candidates
                         (car (last
                               (sort (copy-sequence candidates)
                                     #'chat-agent-profile--candidate-less-p)))))
         (candidate-priority
          (and candidate (chat-agent-profile--candidate-priority candidate))))
    (cond
     ((and registered
           (or (null candidate)
               (>= (chat-agent-profile--registered-priority registered)
                   candidate-priority)))
      registered)
     (candidate (chat-agent-profile--read-file candidate))
     (t (error "Unknown agent profile: %s" id)))))

(defun chat-agent-profile--ordered-union (left right)
  "Return ordered union of LEFT followed by new members from RIGHT."
  (let ((result (copy-sequence left)))
    (dolist (item right result)
      (unless (memq item result)
        (setq result (append result (list item)))))))

(defun chat-agent-profile--intersection (left right)
  "Return ordered intersection of LEFT and RIGHT."
  (seq-filter (lambda (item) (memq item right)) left))

(defun chat-agent-profile--merge-requirements (left right)
  "Merge capability requirement plists LEFT and RIGHT conservatively."
  (let ((result (copy-tree left)))
    (cl-loop for (key value) on right by #'cddr
             do (let ((old (plist-get result key)))
                  (setq result
                        (plist-put
                         result key
                         (cond
                          ((null old) value)
                          ((equal old value) old)
                          ((and (numberp old) (numberp value))
                           (max old value))
                          ((and (listp old) (listp value))
                           (delete-dups (append old value)))
                          ((or (eq old t) (eq value t)) t)
                          (t
                           (error "Conflicting capability requirement %s"
                                  key)))))))
    result))

(defun chat-agent-profile--approval-rank (mode)
  "Return strictness rank for approval MODE."
  (pcase (chat-approval-normalize-mode mode)
    ('dangerous 0)
    ('guarded 1)
    ('manual 2)
    (_ nil)))

(defun chat-agent-profile--stricter-approval (left right)
  "Return the stricter approval mode of LEFT and RIGHT."
  (cond ((null left) right)
        ((null right) left)
        ((>= (chat-agent-profile--approval-rank left)
             (chat-agent-profile--approval-rank right)) left)
        (t right)))

(defun chat-agent-profile--min-present (left right)
  "Return the smaller non-nil value from LEFT and RIGHT."
  (cond ((null left) right)
        ((null right) left)
        (t (min left right))))

(defun chat-agent-profile--plist-delete (plist key)
  "Return PLIST without KEY and its value."
  (let (result)
    (cl-loop for (item value) on plist by #'cddr
             unless (eq item key)
             do (setq result (append result (list item value))))
    result))

(defun chat-agent-profile--merge (base addition)
  "Merge resolved BASE with declaration ADDITION."
  (let* ((result (copy-chat-agent-profile base))
         (provider-changed-p
          (and (chat-agent-profile-provider result)
               (chat-agent-profile-provider addition)
               (not (eq (chat-agent-profile-provider result)
                        (chat-agent-profile-provider addition)))))
        diagnostics
        (addition-instructions
         (let ((value (chat-agent-profile-instructions addition)))
           (cond ((and (stringp value) (not (string-blank-p value)))
                  (list value))
                 ((listp value) value)
                 (t nil)))))
    (when provider-changed-p
      (push (format "provider overridden by %s"
                    (chat-agent-profile-id addition)) diagnostics))
    (when (and (chat-agent-profile-model result)
               (chat-agent-profile-model addition)
               (not (equal (chat-agent-profile-model result)
                           (chat-agent-profile-model addition))))
      (push (format "model overridden by %s"
                    (chat-agent-profile-id addition)) diagnostics))
    (setf
     (chat-agent-profile-instructions result)
     (delq nil
           (append (chat-agent-profile-instructions result)
                   addition-instructions))
     (chat-agent-profile-provider result)
     (or (chat-agent-profile-provider addition)
         (chat-agent-profile-provider result))
     (chat-agent-profile-model result)
     (or (chat-agent-profile-model addition)
         (and (not provider-changed-p)
              (chat-agent-profile-model result)))
     (chat-agent-profile-required-capabilities result)
     (chat-agent-profile--merge-requirements
      (chat-agent-profile-required-capabilities result)
      (chat-agent-profile-required-capabilities addition))
     (chat-agent-profile-skills result)
     (chat-agent-profile--ordered-union
      (chat-agent-profile-skills result)
      (chat-agent-profile-skills addition))
     (chat-agent-profile-disabled-tools result)
     (chat-agent-profile--ordered-union
      (chat-agent-profile-disabled-tools result)
      (chat-agent-profile-disabled-tools addition))
     (chat-agent-profile-approval-mode result)
     (chat-agent-profile--stricter-approval
      (chat-agent-profile-approval-mode result)
      (chat-agent-profile-approval-mode addition))
     (chat-agent-profile-max-steps result)
     (chat-agent-profile--min-present
      (chat-agent-profile-max-steps result)
      (chat-agent-profile-max-steps addition))
     (chat-agent-profile-context-budget result)
     (chat-agent-profile--min-present
      (chat-agent-profile-context-budget result)
      (chat-agent-profile-context-budget addition))
     (chat-agent-profile-subagent-limit result)
     (chat-agent-profile--min-present
      (chat-agent-profile-subagent-limit result)
      (chat-agent-profile-subagent-limit addition))
     (chat-agent-profile-background result)
     (and (chat-agent-profile-background result)
          (chat-agent-profile-background addition))
     (chat-agent-profile-provenance result)
     (append
      (chat-agent-profile-provenance result)
      (or (and (chat-agent-profile-resolved-p addition)
               (chat-agent-profile-provenance addition))
          (list (list :id (chat-agent-profile-id addition)
                      :revision (chat-agent-profile-revision addition)
                      :source (chat-agent-profile-source addition)
                      :path (chat-agent-profile-path addition)
                      :digest (chat-agent-profile-digest addition)))))
     (chat-agent-profile-diagnostics result)
     (append (chat-agent-profile-diagnostics result)
             (nreverse diagnostics)))
    (when (chat-agent-profile-tools-specified-p addition)
      (if (chat-agent-profile-tools-specified-p result)
          (setf (chat-agent-profile-tools result)
                (chat-agent-profile--intersection
                 (chat-agent-profile-tools result)
                 (chat-agent-profile-tools addition)))
        (setf (chat-agent-profile-tools result)
              (copy-sequence (chat-agent-profile-tools addition))
              (chat-agent-profile-tools-specified-p result) t)))
    result))

(defun chat-agent-profile--resolve-declaration (id project-root stack)
  "Resolve profile ID for PROJECT-ROOT while tracking inheritance STACK."
  (when (memq id stack)
    (signal 'chat-agent-profile-cycle
            (list (reverse (cons id stack)))))
  (let* ((declaration (chat-agent-profile--declaration id project-root))
         (resolved (chat-agent-profile-create
                    :id id :revision (chat-agent-profile-revision declaration)
                    :instructions nil :source (chat-agent-profile-source declaration)
                    :background t :resolved-p t)))
    (dolist (parent (chat-agent-profile-extends declaration))
      (setq resolved
            (chat-agent-profile--merge
             resolved
             (chat-agent-profile--resolve-declaration
              parent project-root (cons id stack)))))
    (setq resolved (chat-agent-profile--merge resolved declaration))
    (setf (chat-agent-profile-id resolved) id
          (chat-agent-profile-revision resolved)
          (chat-agent-profile-revision declaration)
          (chat-agent-profile-source resolved)
          (chat-agent-profile-source declaration)
          (chat-agent-profile-path resolved)
          (chat-agent-profile-path declaration)
          (chat-agent-profile-resolved-p resolved) t)
    resolved))

(defun chat-agent-profile--capability-satisfies-p (actual required)
  "Return non-nil when ACTUAL satisfies REQUIRED."
  (cond
   ((eq required t) (eq actual t))
   ((numberp required)
    (and (numberp actual) (>= actual required)))
   ((listp required)
    (and (listp actual)
         (seq-every-p
          (lambda (item)
            (seq-some (lambda (available)
                        (equal (format "%s" available) (format "%s" item)))
                      actual))
          required)))
   (t (equal actual required))))

(defun chat-agent-profile--validate-capabilities
    (provider model requirements profile-id)
  "Require PROVIDER MODEL to satisfy REQUIREMENTS for PROFILE-ID."
  (let ((capabilities (chat-model-capabilities-resolve provider model)))
    (cl-loop for (key required) on requirements by #'cddr
             for actual = (chat-model-capability capabilities key)
             unless (chat-agent-profile--capability-satisfies-p
                     actual required)
             do (signal
                 'chat-agent-profile-capability-mismatch
                 (list profile-id key required actual provider model)))))

(defun chat-agent-profile--effective-tool-config (session profile)
  "Return conservative tool config combining SESSION and PROFILE."
  (let* ((session-config (and session (chat-session-tool-config session)))
         (session-enabled (plist-get session-config :enabled-tools))
         (session-enabled-specified-p
          (and session-config (plist-member session-config :enabled-tools)))
         (session-disabled (plist-get session-config :disabled-tools))
         (profile-enabled
          (and (chat-agent-profile-tools-specified-p profile)
               (chat-agent-profile-tools profile)))
         (enabled
          (cond
           ((and session-enabled-specified-p
                 (chat-agent-profile-tools-specified-p profile))
            (chat-agent-profile--intersection
             session-enabled profile-enabled))
           (session-enabled-specified-p (copy-sequence session-enabled))
           ((chat-agent-profile-tools-specified-p profile)
            (copy-sequence profile-enabled))
           (t nil)))
         (disabled
          (chat-agent-profile--ordered-union
           session-disabled (chat-agent-profile-disabled-tools profile)))
         (config (copy-tree session-config)))
    (setq config (plist-put config :profile (chat-agent-profile-id profile)))
    (when (chat-agent-profile-subagent-limit profile)
      (setq config
            (plist-put config :subagent-max-depth
                       (chat-agent-profile-subagent-limit profile))))
    (if enabled
        (setq config (plist-put config :enabled-tools enabled))
      (when (or session-enabled-specified-p
                (chat-agent-profile-tools-specified-p profile))
        (setq config (plist-put config :enabled-tools nil))))
    (if disabled
        (setq config (plist-put config :disabled-tools disabled))
      (setq config (plist-put config :disabled-tools nil)))
    config))

(defun chat-agent-profile--tool-authorized-p (tool config)
  "Return non-nil when TOOL is permitted by effective CONFIG."
  (let ((enabled (plist-get config :enabled-tools))
        (disabled (plist-get config :disabled-tools)))
    (and (or (not (plist-member config :enabled-tools))
             (memq tool enabled))
         (not (memq tool disabled)))))

(defun chat-agent-profile--validate-skill-tools (skills tool-config profile-id)
  "Ensure SKILLS do not widen TOOL-CONFIG for PROFILE-ID."
  (dolist (skill skills)
    (dolist (tool (chat-skill-tools skill))
      (unless (chat-agent-profile--tool-authorized-p tool tool-config)
        (signal 'chat-agent-profile-authority-expansion
                (list profile-id (chat-skill-id skill) tool))))))

(defun chat-agent-profile--digest (profile)
  "Return a deterministic digest of resolved PROFILE."
  (secure-hash
   'sha256
   (prin1-to-string
    (list (chat-agent-profile-id profile)
          (chat-agent-profile-revision profile)
          (chat-agent-profile-provider profile)
          (chat-agent-profile-model profile)
          (chat-agent-profile-required-capabilities profile)
          (chat-agent-profile-skills profile)
          (chat-agent-profile-tools profile)
          (chat-agent-profile-tools-specified-p profile)
          (chat-agent-profile-disabled-tools profile)
          (chat-agent-profile-approval-mode profile)
          (chat-agent-profile-max-steps profile)
          (chat-agent-profile-context-budget profile)
          (chat-agent-profile-subagent-limit profile)
          (chat-agent-profile-background profile)
          (secure-hash 'sha256
                       (or (chat-agent-profile-instructions profile) ""))
          (mapcar
           (lambda (skill)
             (list (chat-skill-id skill)
                   (chat-skill-revision skill)
                   (chat-skill-source skill)
                   (chat-skill-digest skill)
                   (secure-hash 'sha256
                                (or (chat-skill-instructions skill) ""))
                   (chat-skill-tools skill)
                   (chat-skill-capability-requirements skill)))
           (chat-agent-profile-resolved-skills profile))
          (chat-agent-profile-provenance profile)))))

(defun chat-agent-profile-resolve (id &optional project-root)
  "Resolve agent profile ID for optional PROJECT-ROOT."
  (let* ((id (chat-agent-profile--symbol id "id"))
         (profile (chat-agent-profile--resolve-declaration
                   id project-root nil))
         (skills (mapcar (lambda (skill-id)
                           (chat-skill-resolve skill-id project-root))
                         (chat-agent-profile-skills profile)))
         (instructions
          (append
           (chat-agent-profile-instructions profile)
           (delq nil
                 (mapcar (lambda (skill)
                           (let ((text (chat-skill-instructions skill)))
                             (and (not (string-blank-p text)) text)))
                         skills))))
         (requirements (chat-agent-profile-required-capabilities profile)))
    (dolist (skill skills)
      (setq requirements
            (chat-agent-profile--merge-requirements
             requirements (chat-skill-capability-requirements skill))))
    (let ((merged (string-join instructions "\n\n")))
      (when (> (length merged) chat-agent-profile-instructions-max-chars)
        (error "Resolved instructions exceed the profile limit: %s" id))
      (setf (chat-agent-profile-instructions profile) merged))
    (setf (chat-agent-profile-resolved-skills profile) skills
          (chat-agent-profile-required-capabilities profile) requirements)
    (setf (chat-agent-profile-digest profile)
          (chat-agent-profile--digest profile))
    profile))

(defun chat-agent-profile--execution-session
    (session tool-config approval-mode)
  "Return a transient SESSION copy with TOOL-CONFIG and APPROVAL-MODE."
  (let ((execution (if session
                       (copy-chat-session session)
                     (make-chat-session))))
    (setf (chat-session-tool-config execution) tool-config
          (chat-session-approval-mode execution) approval-mode)
    execution))

(defun chat-agent-profile-prepare-config (config)
  "Resolve the selected profile in CONFIG and return prepared run config.

The original session and its message history are never mutated."
  (let* ((session (plist-get config :session))
         (session-profile
          (and session
               (plist-get (chat-session-tool-config session) :profile)))
         (selected (or (plist-get config :profile) session-profile)))
    (if (null selected)
        config
      (let* ((project-root (or (plist-get config :project-root)
                               default-directory))
             (profile (chat-agent-profile-resolve selected project-root))
             (base-provider (plist-get config :model))
             (provider (or (chat-agent-profile-provider profile)
                           base-provider))
             (request-options (copy-tree
                               (or (plist-get config :request-options) nil)))
             (model (or (chat-agent-profile-model profile)
                        (and (eq provider base-provider)
                             (or (plist-get request-options :model)
                                 (and session
                                      (chat-session-model-name session))))))
             (tool-config
              (chat-agent-profile--effective-tool-config session profile))
             (base-approval (chat-approval-effective-mode session))
             (profile-approval (chat-agent-profile-approval-mode profile))
             (effective-approval
              (chat-agent-profile--stricter-approval
               base-approval profile-approval))
             (messages (copy-sequence (plist-get config :messages)))
             (instructions (chat-agent-profile-instructions profile))
             (caller-max (plist-get config :max-steps))
             (profile-max (chat-agent-profile-max-steps profile)))
        (unless provider
          (error "Agent profile %s did not resolve a provider" selected))
        (when (chat-agent-profile-required-capabilities profile)
          (chat-agent-profile--validate-capabilities
           provider model
           (chat-agent-profile-required-capabilities profile)
           (chat-agent-profile-id profile)))
        (chat-agent-profile--validate-skill-tools
         (chat-agent-profile-resolved-skills profile)
         tool-config (chat-agent-profile-id profile))
        (when (and profile-approval
                   (< (chat-agent-profile--approval-rank profile-approval)
                      (chat-agent-profile--approval-rank base-approval)))
          (setf (chat-agent-profile-diagnostics profile)
                (append
                 (chat-agent-profile-diagnostics profile)
                 (list (format "approval mode %s could not weaken %s"
                               profile-approval base-approval)))))
        (when (and (chat-agent-profile-provider profile)
                   (not (eq provider base-provider))
                   (null (chat-agent-profile-model profile)))
          (setq request-options
                (chat-agent-profile--plist-delete request-options :model)))
        (when (and model (chat-agent-profile-model profile))
          (setq request-options (plist-put request-options :model model)))
        (when (and (stringp instructions)
                   (not (string-blank-p instructions)))
          (setq messages
                (cons
                 (make-chat-message
                  :id (chat-session-new-message-id "agent-profile")
                  :role :system
                  :content instructions
                  :timestamp (current-time)
                  :metadata
                  (list :runtime-profile (chat-agent-profile-id profile)
                        :revision (chat-agent-profile-revision profile)))
                 messages)))
        (let ((prepared (copy-tree config)))
          (setq prepared (plist-put prepared :model provider))
          (setq prepared (plist-put prepared :messages messages))
          (setq prepared (plist-put prepared :request-options request-options))
          (setq prepared (plist-put prepared :profile-resolved profile))
          (setq prepared
                (plist-put
                 prepared :execution-session
                 (chat-agent-profile--execution-session
                  session tool-config effective-approval)))
          (when (or caller-max profile-max)
            (setq prepared
                  (plist-put prepared :max-steps
                             (chat-agent-profile--min-present
                              caller-max profile-max))))
          prepared)))))

(defun chat-agent-profile--audit-tool-names (tools)
  "Return bounded string ids for TOOLS."
  (mapcar #'symbol-name
          (seq-take (or tools nil) chat-agent-profile-audit-tool-limit)))

(defun chat-agent-profile-snapshot (profile &optional execution-session)
  "Return bounded audit facts for resolved PROFILE.
When EXECUTION-SESSION is non-nil, include the actual effective authority."
  (when (chat-agent-profile-p profile)
    (let* ((tool-config (and execution-session
                             (chat-session-tool-config execution-session)))
           (enabled-specified-p
            (and tool-config (plist-member tool-config :enabled-tools)))
           (enabled (plist-get tool-config :enabled-tools))
           (disabled (plist-get tool-config :disabled-tools))
           (effective-approval
            (and execution-session
                 (chat-session-approval-mode execution-session))))
      (list
       (cons 'profile_id (symbol-name (chat-agent-profile-id profile)))
       (cons 'revision (chat-agent-profile-revision profile))
       (cons 'source (format "%s" (chat-agent-profile-source profile)))
       (cons 'digest (chat-agent-profile-digest profile))
       (cons 'provider (and (chat-agent-profile-provider profile)
                            (symbol-name
                             (chat-agent-profile-provider profile))))
       (cons 'model (chat-agent-profile-model profile))
       (cons 'skills
             (mapcar
              (lambda (skill)
                (list
                 (cons 'id (symbol-name (chat-skill-id skill)))
                 (cons 'revision (chat-skill-revision skill))
                 (cons 'source (format "%s" (chat-skill-source skill)))
                 (cons 'digest (chat-skill-digest skill))))
              (chat-agent-profile-resolved-skills profile)))
       (cons 'tool_count
             (and (chat-agent-profile-tools-specified-p profile)
                  (length (chat-agent-profile-tools profile))))
       (cons 'enabled_tools_specified
             (and enabled-specified-p t))
       (cons 'enabled_tools
             (and enabled-specified-p
                  (chat-agent-profile--audit-tool-names enabled)))
       (cons 'enabled_tools_truncated
             (and enabled-specified-p
                  (> (length enabled) chat-agent-profile-audit-tool-limit)))
       (cons 'disabled_tools
             (chat-agent-profile--audit-tool-names disabled))
       (cons 'disabled_tools_truncated
             (> (length disabled) chat-agent-profile-audit-tool-limit))
       (cons 'approval_mode
             (and (chat-agent-profile-approval-mode profile)
                  (symbol-name
                   (chat-agent-profile-approval-mode profile))))
       (cons 'effective_approval_mode
             (and effective-approval (symbol-name effective-approval)))
       (cons 'max_steps (chat-agent-profile-max-steps profile))
       (cons 'context_budget (chat-agent-profile-context-budget profile))
       (cons 'subagent_max_depth
             (chat-agent-profile-subagent-limit profile))
       (cons 'background (and (chat-agent-profile-background profile) t))
       (cons 'diagnostics (chat-agent-profile-diagnostics profile))))))

(provide 'chat-agent-profile)
;;; chat-agent-profile.el ends here
