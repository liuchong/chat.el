;;; chat-model-capabilities.el --- Versioned model capability facts -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: llm, runtime, capabilities

;;; Commentary:

;; Model behavior is data here, not a branch on a model name.  Static
;; registration is the offline floor, discovery may refresh it, and an
;; explicit user declaration outranks both.  Unknown is a real value: it
;; never silently becomes either supported or unsupported.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-content)

(declare-function chat-llm-get-provider-config "chat-llm" (provider))
(declare-function chat-message-parts "chat-session" (message))

(defgroup chat-model-capabilities nil
  "Model capability declarations and discovery cache."
  :group 'chat-llm)

(defconst chat-model-capabilities-schema-version 1
  "Current `chat-model-capabilities' schema version.")

(defconst chat-model-discovery-cache-schema-version 1
  "Current model discovery cache schema version.")

(define-error 'chat-model-discovery-unsupported-schema
  "Unsupported model discovery cache schema")

(defcustom chat-model-discovery-cache-file
  (expand-file-name "model-discovery.json" (expand-file-name "~/.chat/"))
  "Versioned cache of dynamically discovered model capability facts."
  :type 'file
  :group 'chat-model-capabilities)

(defcustom chat-model-discovery-cache-ttl 86400
  "Default lifetime in seconds for dynamically discovered model facts."
  :type 'integer
  :group 'chat-model-capabilities)

(cl-defstruct
    (chat-model-capabilities
     (:constructor
      chat-model-capabilities-create
      (&key
       (schema-version chat-model-capabilities-schema-version)
       provider model (source 'unknown) updated-at expires-at
       (stream 'unknown) (tools 'unknown) (tool-choice 'unknown)
       (reasoning 'unknown) (input-modalities 'unknown)
       (structured-output 'unknown) (context-window 'unknown)
       (max-output-tokens 'unknown) (supported-options 'unknown))))
  "Resolved, versioned facts for one provider MODEL.

Boolean capabilities use t, nil or `unknown'.  Collection and numeric
capabilities also use `unknown' when no declaration is available."
  schema-version provider model source updated-at expires-at
  stream tools tool-choice reasoning input-modalities structured-output
  context-window max-output-tokens supported-options)

(defconst chat-model-capabilities--fields
  '(:stream :tools :tool-choice :reasoning :input-modalities
    :structured-output :context-window :max-output-tokens
    :supported-options)
  "Capability keys accepted in registration plists.")

(defvar chat-model-capabilities--registry nil
  "Capability declarations before source-priority resolution.")

(defvar chat-model-discovery--cache (make-hash-table :test 'eq)
  "Provider symbols to discovery cache entries.")

(defvar chat-model-discovery--loaded nil
  "Whether `chat-model-discovery-cache-file' has been read.")

(defun chat-model-capabilities--source-priority (source)
  "Return merge priority for capability SOURCE."
  (pcase source
    ('fallback 0)
    ('static 10)
    ('discovered 20)
    ('user 30)
    (_ 0)))

(defun chat-model-capabilities--clean-values (values)
  "Return the supported capability entries from plist VALUES."
  (let (clean)
    (dolist (key chat-model-capabilities--fields)
      (when (plist-member values key)
        (setq clean (plist-put clean key (plist-get values key)))))
    clean))

(defun chat-model-capabilities-register
    (provider model values &optional source updated-at expires-at)
  "Register capability VALUES for PROVIDER and optional MODEL.

SOURCE is `fallback', `static', `discovered' or `user'.  A declaration
with the same provider, model and source replaces the earlier one."
  (unless (symbolp provider)
    (error "Capability provider must be a symbol: %S" provider))
  (unless (or (null model) (stringp model))
    (error "Capability model must be a string or nil: %S" model))
  (let ((source (or source 'static)))
    (setq chat-model-capabilities--registry
          (cons (list :provider provider
                      :model model
                      :source source
                      :updated-at updated-at
                      :expires-at expires-at
                      :values (chat-model-capabilities--clean-values values))
                (seq-remove
                 (lambda (entry)
                   (and (eq provider (plist-get entry :provider))
                        (equal model (plist-get entry :model))
                        (eq source (plist-get entry :source))))
                 chat-model-capabilities--registry)))))

(defun chat-model-capabilities-register-provider (provider config)
  "Register capability facts carried by provider CONFIG for PROVIDER."
  (setq chat-model-capabilities--registry
        (seq-remove
         (lambda (entry)
           (and (eq provider (plist-get entry :provider))
                (memq (plist-get entry :source) '(fallback static))))
         chat-model-capabilities--registry))
  (let* ((source (or (plist-get config :capabilities-source) 'fallback))
         (values (copy-tree (or (plist-get config :capabilities) nil))))
    (when (and (plist-get config :context-window)
               (not (plist-member values :context-window)))
      (setq values (plist-put values :context-window
                              (plist-get config :context-window))))
    (when (and (plist-get config :max-output-tokens)
               (not (plist-member values :max-output-tokens)))
      (setq values (plist-put values :max-output-tokens
                              (plist-get config :max-output-tokens))))
    (chat-model-capabilities-register provider nil values source)
    (dolist (entry (plist-get config :model-capabilities))
      (chat-model-capabilities-register
       provider (car entry) (cdr entry) source))))

(defun chat-model-capabilities--entry-less-p (left right)
  "Return non-nil when LEFT should be applied before RIGHT."
  (let ((lp (chat-model-capabilities--source-priority
             (plist-get left :source)))
        (rp (chat-model-capabilities--source-priority
             (plist-get right :source))))
    (if (= lp rp)
        (and (null (plist-get left :model))
             (plist-get right :model))
      (< lp rp))))

(defun chat-model-capabilities--set (capabilities key value)
  "Set KEY on CAPABILITIES to VALUE."
  (pcase key
    (:stream (setf (chat-model-capabilities-stream capabilities) value))
    (:tools (setf (chat-model-capabilities-tools capabilities) value))
    (:tool-choice
     (setf (chat-model-capabilities-tool-choice capabilities) value))
    (:reasoning
     (setf (chat-model-capabilities-reasoning capabilities) value))
    (:input-modalities
     (setf (chat-model-capabilities-input-modalities capabilities) value))
    (:structured-output
     (setf (chat-model-capabilities-structured-output capabilities) value))
    (:context-window
     (setf (chat-model-capabilities-context-window capabilities) value))
    (:max-output-tokens
     (setf (chat-model-capabilities-max-output-tokens capabilities) value))
    (:supported-options
     (setf (chat-model-capabilities-supported-options capabilities) value))))

(defun chat-model-capabilities-resolve (provider &optional model)
  "Resolve capability facts for PROVIDER and optional MODEL."
  (chat-model-discovery-load-cache)
  (let* ((entries
          (seq-filter
           (lambda (entry)
             (and (eq provider (plist-get entry :provider))
                  (or (null (plist-get entry :model))
                      (equal model (plist-get entry :model)))))
           chat-model-capabilities--registry))
         (ordered (sort (copy-sequence entries)
                        #'chat-model-capabilities--entry-less-p))
         (resolved (chat-model-capabilities-create
                    :provider provider :model model))
         (sources nil))
    (dolist (entry ordered)
      (let ((values (plist-get entry :values)))
        (dolist (key chat-model-capabilities--fields)
          (when (and (plist-member values key)
                     (not (eq 'unknown (plist-get values key))))
            (chat-model-capabilities--set resolved key (plist-get values key))))
        (when values
          (push (plist-get entry :source) sources)
          (setf (chat-model-capabilities-updated-at resolved)
                (or (plist-get entry :updated-at)
                    (chat-model-capabilities-updated-at resolved)))
          (setf (chat-model-capabilities-expires-at resolved)
                (or (plist-get entry :expires-at)
                    (chat-model-capabilities-expires-at resolved))))))
    (setf (chat-model-capabilities-source resolved)
          (or (car sources) 'unknown))
    resolved))

(defun chat-model-capability (capabilities key)
  "Return capability KEY from CAPABILITIES."
  (pcase key
    (:stream (chat-model-capabilities-stream capabilities))
    (:tools (chat-model-capabilities-tools capabilities))
    (:tool-choice (chat-model-capabilities-tool-choice capabilities))
    (:reasoning (chat-model-capabilities-reasoning capabilities))
    (:input-modalities (chat-model-capabilities-input-modalities capabilities))
    (:structured-output
     (chat-model-capabilities-structured-output capabilities))
    (:context-window (chat-model-capabilities-context-window capabilities))
    (:max-output-tokens
     (chat-model-capabilities-max-output-tokens capabilities))
    (:supported-options
     (chat-model-capabilities-supported-options capabilities))
    (_ (error "Unknown model capability: %S" key))))

(defun chat-model-capability-supported-p (capabilities key)
  "Return non-nil only when CAPABILITIES explicitly supports KEY."
  (eq t (chat-model-capability capabilities key)))

(defun chat-model-capabilities-message-modalities (messages)
  "Return distinct model input modalities required by MESSAGES."
  (delete-dups
   (apply #'append
          (mapcar
           (lambda (message)
             (mapcar #'chat-content-part-required-modality
                     (chat-message-parts message)))
           messages))))

(defun chat-model-capabilities-validate-messages
    (provider model messages)
  "Validate that PROVIDER MODEL accepts all content in MESSAGES."
  (let* ((capabilities (chat-model-capabilities-resolve provider model))
         (supported (chat-model-capabilities-input-modalities capabilities))
         (required (delq 'text
                         (chat-model-capabilities-message-modalities messages))))
    (dolist (modality required)
      (cond
       ((eq supported 'unknown)
        (error "Input capability is unknown for %s/%s; cannot send %s"
               provider model modality))
       ((not (memq modality supported))
        (error "Model %s/%s does not support %s input"
               provider model modality))))
    capabilities))

(defun chat-model-capabilities--requested-mode (value)
  "Normalize requested capability VALUE to a symbol."
  (cond ((symbolp value) value)
        ((stringp value) (intern value))
        (t value)))

(defun chat-model-capabilities-prepare-options (provider model options)
  "Validate and normalize request OPTIONS for PROVIDER and MODEL.

Known unsupported feature combinations signal before dispatch.  Optional
sampling controls that are known to be ignored are removed.  Unknown facts
remain visible through the resolved contract and do not become false."
  (let* ((capabilities (chat-model-capabilities-resolve provider model))
         (prepared (copy-tree options))
         (stream (chat-model-capabilities-stream capabilities))
         (tools (chat-model-capabilities-tools capabilities))
         (choices (chat-model-capabilities-tool-choice capabilities))
         (structured (chat-model-capabilities-structured-output capabilities))
         (reasoning (chat-model-capabilities-reasoning capabilities))
         (modalities (chat-model-capabilities-input-modalities capabilities))
         (max-output (chat-model-capabilities-max-output-tokens capabilities))
         (supported (chat-model-capabilities-supported-options capabilities)))
    (when (and (plist-get prepared :stream) (null stream))
      (error "Model %s on %s does not support streaming" model provider))
    (when (and (plist-get prepared :tools) (null tools))
      (error "Model %s on %s does not support tools" model provider))
    (when-let* ((choice (plist-get prepared :tool-choice)))
      (let ((choice (chat-model-capabilities--requested-mode choice)))
        (cond
         ((null choices)
          (error "Model %s on %s does not support tool choice" model provider))
         ((and (listp choices) (not (memq choice choices)))
          (error "Model %s on %s does not support tool choice %s"
                 model provider choice)))))
    (when-let* ((format (plist-get prepared :response-format)))
      (let ((mode (chat-model-capabilities--requested-mode format)))
        (cond
         ((null structured)
          (error "Model %s on %s does not support structured output"
                 model provider))
         ((and (listp structured) (not (memq mode structured)))
          (error "Model %s on %s does not support structured output %s"
                 model provider mode)))))
    (when (and (or (plist-get prepared :reasoning)
                   (plist-get prepared :thinking))
               (null reasoning))
      (error "Model %s on %s does not support reasoning" model provider))
    (when-let* ((requested (plist-get prepared :modalities)))
      (when (and (listp modalities)
                 (seq-some (lambda (item) (not (memq item modalities)))
                           requested))
        (error "Model %s on %s does not support requested modalities"
               model provider)))
    (when-let* ((requested-max (plist-get prepared :max-tokens)))
      (when (and (integerp max-output)
                 (> requested-max max-output))
        (error "Requested %d output tokens exceeds %s limit %d"
               requested-max model max-output)))
    (when (listp supported)
      (dolist (key '(:temperature :top-p :presence-penalty
                     :frequency-penalty :reasoning-effort))
        (when (and (plist-member prepared key)
                   (not (memq key supported)))
          (setq prepared (chat-model-capabilities--plist-delete
                          prepared key)))))
    prepared))

(defun chat-model-capabilities--plist-delete (plist key)
  "Return a copy of PLIST without KEY and its value."
  (let (result)
    (cl-loop for (item value) on plist by #'cddr
             unless (eq item key)
             do (setq result (append result (list item value))))
    result))

(defun chat-model-capabilities--wire-value (value)
  "Encode capability VALUE for JSON persistence."
  (cond ((eq value 'unknown) "unknown")
        ((null value) :json-false)
        ((eq value t) t)
        ((symbolp value) (symbol-name value))
        ((listp value)
         (vconcat (mapcar (lambda (item)
                            (if (symbolp item) (symbol-name item) item))
                          value)))
        (t value)))

(defun chat-model-capabilities--unwire-value (value)
  "Decode one persisted capability VALUE."
  (cond ((equal value "unknown") 'unknown)
        ((eq value :json-false) nil)
        ((vectorp value)
         (mapcar (lambda (item)
                   (if (stringp item) (intern item) item))
                 (append value nil)))
        (t value)))

(defun chat-model-capabilities--values-to-wire (values)
  "Encode capability plist VALUES as an alist."
  (mapcar (lambda (key)
            (cons (symbol-name key)
                  (chat-model-capabilities--wire-value
                   (plist-get values key))))
          (seq-filter (lambda (key) (plist-member values key))
                      chat-model-capabilities--fields)))

(defun chat-model-capabilities--wire-to-values (wire)
  "Decode capability alist WIRE into a plist."
  (let (values)
    (dolist (key chat-model-capabilities--fields)
      (let* ((name (symbol-name key))
             (cell (or (assoc key wire) (assoc name wire))))
        (when cell
          (setq values
                (plist-put values key
                           (chat-model-capabilities--unwire-value
                            (cdr cell)))))))
    values))

(defun chat-model-discovery--fresh-p (entry)
  "Return non-nil when discovery cache ENTRY is still fresh."
  (and entry
       (numberp (plist-get entry :expires-at))
       (> (plist-get entry :expires-at) (float-time))))

(defun chat-model-discovery--static-models (provider)
  "Return statically configured model ids for PROVIDER."
  (let ((config (and (fboundp 'chat-llm-get-provider-config)
                     (chat-llm-get-provider-config provider))))
    (or (plist-get config :models)
        (when-let* ((model (plist-get config :model)))
          (list model)))))

(defun chat-model-discovery-models (provider)
  "Return fresh discovered models for PROVIDER, or its static fallback."
  (chat-model-discovery-load-cache)
  (let ((entry (gethash provider chat-model-discovery--cache)))
    (if (chat-model-discovery--fresh-p entry)
        (mapcar (lambda (item) (plist-get item :id))
                (plist-get entry :models))
      (chat-model-discovery--static-models provider))))

(defun chat-model-discovery-update (provider models &optional ttl)
  "Store discovered MODELS for PROVIDER for TTL seconds.

Each model is a string or a plist with `:id' and optional `:capabilities'."
  (let* ((now (float-time))
         (ttl (or ttl chat-model-discovery-cache-ttl))
         (expires (+ now ttl))
         (normalized
          (mapcar (lambda (item)
                    (if (stringp item)
                        (list :id item :capabilities nil)
                      (list :id (plist-get item :id)
                            :capabilities (plist-get item :capabilities))))
                  models)))
    (unless (seq-every-p (lambda (item)
                           (and (stringp (plist-get item :id))
                                (not (string-empty-p (plist-get item :id)))))
                         normalized)
      (error "Discovered model entries require non-empty ids"))
    (setq chat-model-capabilities--registry
          (seq-remove
           (lambda (entry)
             (and (eq provider (plist-get entry :provider))
                  (eq 'discovered (plist-get entry :source))))
           chat-model-capabilities--registry))
    (dolist (item normalized)
      (chat-model-capabilities-register
       provider (plist-get item :id) (plist-get item :capabilities)
       'discovered now expires))
    (puthash provider
             (list :fetched-at now :expires-at expires :models normalized)
             chat-model-discovery--cache)
    (setq chat-model-discovery--loaded t)
    (chat-model-discovery-save-cache)
    normalized))

(defun chat-model-discovery-request (provider callback &optional force)
  "Discover models for PROVIDER and invoke CALLBACK with (MODELS SOURCE).

The optional provider `:discover-models-fn' receives PROVIDER, success and
error callbacks.  Without one, or after an error, static registration is
returned.  A fresh cache wins unless FORCE is non-nil."
  (chat-model-discovery-load-cache)
  (let* ((entry (gethash provider chat-model-discovery--cache))
         (config (and (fboundp 'chat-llm-get-provider-config)
                      (chat-llm-get-provider-config provider)))
         (discover (plist-get config :discover-models-fn))
         (finished nil)
         (finish (lambda (models source)
                   (unless finished
                     (setq finished t)
                     (funcall callback models source)))))
    (cond
     ((and (not force) (chat-model-discovery--fresh-p entry))
      (funcall finish (plist-get entry :models) 'cache))
     ((not (functionp discover))
      (funcall finish
               (mapcar (lambda (id) (list :id id :capabilities nil))
                       (chat-model-discovery--static-models provider))
               'static))
     (t
      (condition-case _err
          (let ((returned
                 (funcall
                  discover provider
                  (lambda (models &optional ttl)
                    (funcall finish
                             (chat-model-discovery-update provider models ttl)
                             'discovered))
                  (lambda (&rest _)
                    (funcall finish
                             (mapcar
                              (lambda (id) (list :id id :capabilities nil))
                              (chat-model-discovery--static-models provider))
                             'static)))))
            (when (and (listp returned) (not finished))
              (funcall finish
                       (chat-model-discovery-update provider returned)
                       'discovered)))
        (error
         (funcall finish
                  (mapcar (lambda (id) (list :id id :capabilities nil))
                          (chat-model-discovery--static-models provider))
                  'static)))))))

(defun chat-model-discovery-save-cache ()
  "Atomically write the current discovery cache."
  (when chat-model-discovery-cache-file
    (let* ((file (expand-file-name chat-model-discovery-cache-file))
           (directory (file-name-directory file))
           (temporary nil)
           (entries nil))
      (maphash
       (lambda (provider entry)
         (push
          `((provider . ,(symbol-name provider))
            (fetchedAt . ,(plist-get entry :fetched-at))
            (expiresAt . ,(plist-get entry :expires-at))
            (models .
                    ,(vconcat
                      (mapcar
                       (lambda (item)
                         `((id . ,(plist-get item :id))
                           (capabilities .
                                         ,(chat-model-capabilities--values-to-wire
                                           (plist-get item :capabilities)))))
                       (plist-get entry :models)))))
          entries))
       chat-model-discovery--cache)
      (make-directory directory t)
      (setq temporary (make-temp-file
                       (expand-file-name ".model-discovery-" directory)))
      (unwind-protect
          (progn
            (with-temp-file temporary
              (insert
               (json-encode
                `((schemaVersion . ,chat-model-discovery-cache-schema-version)
                  (entries . ,(vconcat (nreverse entries))))))
              (insert "\n"))
            (rename-file temporary file t)
            (setq temporary nil))
        (when (and temporary (file-exists-p temporary))
          (delete-file temporary))))))

(defun chat-model-discovery-load-cache ()
  "Load the discovery cache once, rejecting unknown newer schemas."
  (unless chat-model-discovery--loaded
    (if (not (and chat-model-discovery-cache-file
                  (file-readable-p chat-model-discovery-cache-file)))
        (setq chat-model-discovery--loaded t)
      (condition-case err
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (document (json-read-file chat-model-discovery-cache-file))
                 (version (alist-get 'schemaVersion document))
                 decoded)
            (when (and (integerp version)
                       (> version chat-model-discovery-cache-schema-version))
              (signal 'chat-model-discovery-unsupported-schema
                      (list version)))
            ;; Decode completely before changing live state.  A damaged
            ;; cache therefore cannot leave a half-loaded registry.
            (when (= (or version 0) chat-model-discovery-cache-schema-version)
              (dolist (wire (alist-get 'entries document))
                (let* ((provider-name (alist-get 'provider wire))
                       (fetched (alist-get 'fetchedAt wire))
                       (expires (alist-get 'expiresAt wire))
                       (models
                        (mapcar
                         (lambda (item)
                           (list :id (alist-get 'id item)
                                 :capabilities
                                 (chat-model-capabilities--wire-to-values
                                  (alist-get 'capabilities item))))
                         (alist-get 'models wire))))
                  (unless (stringp provider-name)
                    (error "Discovery cache provider is not a string"))
                  (push (list :provider (intern provider-name)
                              :fetched-at fetched
                              :expires-at expires
                              :models models)
                        decoded))))
            (dolist (entry decoded)
              (let ((provider (plist-get entry :provider))
                    (fetched (plist-get entry :fetched-at))
                    (expires (plist-get entry :expires-at))
                    (models (plist-get entry :models)))
                (puthash provider
                         (list :fetched-at fetched :expires-at expires
                               :models models)
                         chat-model-discovery--cache)
                (dolist (item models)
                  (chat-model-capabilities-register
                   provider (plist-get item :id)
                   (plist-get item :capabilities)
                   'discovered fetched expires))))
            (setq chat-model-discovery--loaded t))
        (chat-model-discovery-unsupported-schema
         (signal (car err) (cdr err)))
        (error
         ;; Corrupt local cache is disposable; static declarations remain.
         (setq chat-model-discovery--loaded t))))))

(provide 'chat-model-capabilities)
;;; chat-model-capabilities.el ends here
