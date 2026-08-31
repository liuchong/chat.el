;;; run-coding-campaign.el --- Reproducible live coding campaign -*- lexical-binding: t; -*-

;;; Commentary:

;; Required environment:
;;   CHAT_CAMPAIGN_ID, CHAT_CAMPAIGN_ROLE, CHAT_CAMPAIGN_PROVIDER,
;;   CHAT_CAMPAIGN_MODEL, CHAT_IMPLEMENTATION_ROOT,
;;   CHAT_IMPLEMENTATION_REVISION, CHAT_HARNESS_REVISION.
;;
;; Actual runs also require CHAT_CAMPAIGN_SETUP_FILE.  That explicitly trusted
;; local Emacs Lisp file configures credentials without storing secrets here.
;; Set CHAT_CAMPAIGN_PREFLIGHT=1 for a no-network descriptor check.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defconst chat-campaign-runner--harness-root
  (file-name-as-directory
   (file-truename
    (expand-file-name "../.." (file-name-directory load-file-name)))))

(defun chat-campaign-runner--required-env (name)
  "Return nonempty environment variable NAME or fail."
  (let ((value (getenv name)))
    (unless (and (stringp value) (not (string-empty-p value)))
      (error "%s is required" name))
    value))

(defun chat-campaign-runner--positive-integer (name default)
  "Return positive integer from environment NAME or DEFAULT."
  (let ((value (or (getenv name) (number-to-string default))))
    (unless (string-match-p "\\`[1-9][0-9]*\\'" value)
      (error "%s must be a positive integer" name))
    (string-to-number value)))

(defun chat-campaign-runner--validate-qualification-model (provider model)
  "Require the exact qualified MODEL identity for a known PROVIDER."
  (let ((required
         (pcase provider
           ('deepseek "deepseek-v4-flash")
           ('kimi-code "k3-256k"))))
    (when (and required (not (equal model required)))
      (error "Campaign provider %s requires exact model %s, not %s"
             provider required model))
    model))

(defun chat-campaign-runner--agent-config-v1
    (provider _model common-config)
  "Bind PROVIDER to COMMON-CONFIG for the frozen Agent v1 contract.

The concrete model remains in `:request-options', where v1 carries it through
every turn instead of consulting mutable provider defaults."
  (append (list :model provider) common-config))

(defun chat-campaign-runner--model-observer-v0-advice
    (request provider messages callback &optional options)
  "Project v0 normalized REQUEST events into the v1 observer contract."
  (let ((observer (plist-get options :event-observer))
        (transport-options (copy-tree options)))
    (cl-remf transport-options :event-observer)
    (funcall
     request provider messages
     (if (functionp observer)
         (lambda (event)
           (condition-case err
               (funcall observer event)
             (error
              (chat-log "[CAMPAIGN] Model observer failed: %s"
                        (error-message-string err))))
           (funcall callback event))
       callback)
     transport-options)))

(defun chat-campaign-runner--capability-snapshot-v1 (provider model)
  "Project frozen capability schema v1 for PROVIDER and MODEL."
  (let ((facts (chat-model-capabilities-resolve provider model)))
    (chat-eval--sanitize-value
     `((schemaVersion . ,(chat-model-capabilities-schema-version facts))
       (provider . ,(symbol-name provider))
       (model . ,model)
       (source . ,(symbol-name (chat-model-capabilities-source facts)))
       (stream . ,(chat-model-capabilities-stream facts))
       (tools . ,(chat-model-capabilities-tools facts))
       (toolChoice . ,(chat-model-capabilities-tool-choice facts))
       (reasoning . ,(chat-model-capabilities-reasoning facts))
       (structuredOutput .
                         ,(chat-model-capabilities-structured-output facts))
       (contextWindow . ,(chat-model-capabilities-context-window facts))
       (maxOutputTokens .
                        ,(chat-model-capabilities-max-output-tokens facts))))))

(defun chat-campaign-runner--configure-implementation-contracts
    (agent-version observer-version capability-version)
  "Configure Eval adapters for frozen implementation protocol versions."
  (pcase agent-version
    (2 nil)
    ('nil
     (setq chat-coding-eval-agent-config-function
           #'chat-campaign-runner--agent-config-v1))
    (_ (error "Unsupported frozen Agent config protocol: %S" agent-version)))
  (pcase observer-version
    (1 nil)
    ('nil
     (unless (advice-member-p #'chat-campaign-runner--model-observer-v0-advice
                              'chat-model-request-events)
       (advice-add 'chat-model-request-events :around
                   #'chat-campaign-runner--model-observer-v0-advice)))
    (_ (error "Unsupported frozen model observer protocol: %S"
              observer-version)))
  (pcase capability-version
    (2 nil)
    (1
     (setq chat-coding-eval-capability-snapshot-function
           #'chat-campaign-runner--capability-snapshot-v1))
    (_ (error "Unsupported frozen capability schema: %S"
              capability-version))))

(defun chat-campaign-runner--git-output (root &rest arguments)
  "Return trimmed Git output under ROOT for ARGUMENTS."
  (with-temp-buffer
    (unless (zerop (apply #'process-file "git" nil t nil
                          "-C" root arguments))
      (error "Git command failed under %s: %S" root arguments))
    (string-trim (buffer-string))))

(defun chat-campaign-runner--validate-checkout
    (root expected-revision label allow-dirty)
  "Validate ROOT against EXPECTED-REVISION and cleanliness for LABEL.

ALLOW-DIRTY is accepted only by no-network preflight runs."
  (let ((actual (chat-campaign-runner--git-output root "rev-parse" "HEAD"))
        (changes (chat-campaign-runner--git-output root "status" "--porcelain")))
    (unless (equal expected-revision actual)
      (error "%s revision mismatch: expected %s, found %s"
             label expected-revision actual))
    (unless (or (string-empty-p changes) allow-dirty)
      (error "%s worktree has uncommitted changes" label))
    (string-empty-p changes)))

(defun chat-campaign-runner--same-root-p (left right)
  "Return non-nil when LEFT and RIGHT resolve to the same directory."
  (equal (file-name-as-directory (file-truename left))
         (file-name-as-directory (file-truename right))))

(defconst chat-campaign-runner--harness-contracts
  '(("lisp/core/chat-eval.el" . chat-eval--result-to-json)
    ("lisp/agent/chat-coding-eval.el" . chat-coding-eval--start-campaign))
  "Harness-owned modules and representative contract functions.")

(defun chat-campaign-runner--load-harness-contracts (implementation-root)
  "Load and verify harness-owned contracts for IMPLEMENTATION-ROOT.

The frozen checkout owns product behavior.  The current harness always owns
campaign orchestration and durable result serialization, so historical code
cannot change or erase the evidence schema used for comparison."
  (unless (chat-campaign-runner--same-root-p
           implementation-root chat-campaign-runner--harness-root)
    (dolist (contract chat-campaign-runner--harness-contracts)
      (load (expand-file-name (car contract)
                              chat-campaign-runner--harness-root)
            nil nil t)))
  (dolist (contract chat-campaign-runner--harness-contracts)
    (let ((owner (symbol-file (cdr contract) 'defun)))
      (unless (and owner
                   (file-in-directory-p
                    (file-truename owner)
                    chat-campaign-runner--harness-root))
        (error "Campaign contract %s is not owned by harness %s"
               (cdr contract) chat-campaign-runner--harness-root)))))

(defun chat-campaign-runner--install-runtime-home (runtime-home)
  "Install isolated RUNTIME-HOME without leaving a stale tilde directory."
  (when runtime-home
    (let* ((developer-home (getenv "HOME"))
           (developer-rustup-home
            (and developer-home
                 (expand-file-name ".rustup" developer-home)))
           (home (file-name-as-directory (expand-file-name runtime-home))))
      (make-directory home t)
      (when (and (not (getenv "RUSTUP_HOME"))
                 (file-directory-p (or developer-rustup-home "")))
        (setenv "RUSTUP_HOME" (file-truename developer-rustup-home)))
      (setenv "HOME" home)
      ;; `default-directory' may have been recorded as ~/... before HOME was
      ;; replaced.  A subprocess expands it after the replacement and then
      ;; cannot start, even though the checkout itself still exists.
      (setq default-directory chat-campaign-runner--harness-root)
      home)))

(defun chat-campaign-runner--call-with-isolated-runtime (function)
  "Call FUNCTION with campaign state isolated from the developer HOME.

The campaign evidence directory and setup file are resolved before HOME
changes.  An implicit runtime directory is temporary; an explicitly configured
one is retained for investigation or a later invocation."
  (let* ((process-environment (copy-sequence process-environment))
         (original-directory default-directory)
         (configured-home (getenv "CHAT_CAMPAIGN_RUNTIME_HOME"))
         (temporary-home (unless configured-home
                           (make-temp-file "chat-campaign-runtime-" t)))
         (runtime-home (or configured-home temporary-home))
         (campaign-directory
          (expand-file-name
           (or (getenv "CHAT_CAMPAIGN_DIRECTORY")
               "~/.chat/evaluations/coding-campaigns/")))
         (setup-file (getenv "CHAT_CAMPAIGN_SETUP_FILE")))
    (setenv "CHAT_CAMPAIGN_DIRECTORY" campaign-directory)
    (setenv "CHAT_CAMPAIGN_RUNTIME_HOME" runtime-home)
    (when setup-file
      (setenv "CHAT_CAMPAIGN_SETUP_FILE" (expand-file-name setup-file)))
    (unwind-protect
        (progn
          (chat-campaign-runner--install-runtime-home runtime-home)
          (funcall function))
      (setq default-directory original-directory)
      (when (and temporary-home (file-directory-p temporary-home))
        (delete-directory temporary-home t)))))

(defun chat-campaign-runner--provider-readiness (provider model)
  "Require one minimal successful response from PROVIDER and MODEL."
  (let* ((message
          (make-chat-message :role :user :content "Reply exactly READY."))
         (response
          (chat-llm-request provider (list message)
                            (list :model model :max-tokens 512 :timeout 30)))
         (content (plist-get response :content)))
    (unless (and (stringp content) (not (string-blank-p content)))
      (error "Provider readiness response is empty"))
    content))

(defun chat-campaign-runner--validate-judge-executables (tasks)
  "Resolve versioned judge toolchain evidence required by TASKS."
  (chat-coding-eval-resolve-toolchain tasks))

(defun chat-campaign-runner--descriptor-summary (descriptor)
  "Return bounded JSON summary for campaign DESCRIPTOR."
  (json-encode
   `((campaignId . ,(alist-get 'campaignId descriptor))
     (role . ,(alist-get 'role descriptor))
     (provider . ,(alist-get 'provider descriptor))
     (model . ,(alist-get 'model descriptor))
     (taskCount . ,(alist-get 'taskCount descriptor))
     (repetitions . ,(alist-get 'repetitions descriptor))
     (expectedResultCount . ,(alist-get 'expectedResultCount descriptor))
     (implementationRevision .
                             ,(alist-get 'implementationRevision descriptor))
     (toolchain . ,(alist-get 'toolchain descriptor))
     (manifestDigest . ,(alist-get 'manifestDigest descriptor))
     (configurationDigest . ,(alist-get 'configurationDigest descriptor)))))

(defun chat-campaign-runner--start-or-resume
    (campaign-directory provider repetitions manifest model campaign-id
                        implementation-revision role toolchain)
  "Start a new campaign or resume validated missing work in CAMPAIGN-DIRECTORY."
  (if (file-exists-p campaign-directory)
      (progn
        (unless (file-directory-p campaign-directory)
          (error "Campaign path is not a directory: %s" campaign-directory))
        (chat-coding-eval-resume-live
         campaign-directory manifest implementation-revision toolchain))
    (chat-coding-eval-run-live
     provider repetitions manifest model campaign-id implementation-revision role
     toolchain)))

(defun chat-campaign-runner--main-in-isolated-runtime ()
  "Validate configuration, then preflight or run one live campaign."
  (let* ((preflight (equal "1" (getenv "CHAT_CAMPAIGN_PREFLIGHT")))
       (allow-dirty
        (and preflight
             (equal "1" (getenv "CHAT_CAMPAIGN_ALLOW_DIRTY"))))
       (campaign-id (chat-campaign-runner--required-env "CHAT_CAMPAIGN_ID"))
       (role (chat-campaign-runner--required-env "CHAT_CAMPAIGN_ROLE"))
       (provider
        (intern (chat-campaign-runner--required-env "CHAT_CAMPAIGN_PROVIDER")))
       (model (chat-campaign-runner--required-env "CHAT_CAMPAIGN_MODEL"))
       (implementation-root
        (file-name-as-directory
         (file-truename
          (chat-campaign-runner--required-env "CHAT_IMPLEMENTATION_ROOT"))))
       (implementation-revision
        (chat-campaign-runner--required-env "CHAT_IMPLEMENTATION_REVISION"))
       (harness-revision
        (chat-campaign-runner--required-env "CHAT_HARNESS_REVISION"))
       (repetitions
        (chat-campaign-runner--positive-integer "CHAT_CAMPAIGN_REPETITIONS" 5))
       (deadline-seconds
        (chat-campaign-runner--positive-integer
         "CHAT_CAMPAIGN_DEADLINE_SECONDS" 21600))
       (manifest
        (file-truename
         (or (getenv "CHAT_CAMPAIGN_MANIFEST")
             (expand-file-name "tests/fixtures/coding-eval/manifest.json"
                               chat-campaign-runner--harness-root))))
       (campaign-root
        (file-name-as-directory
         (expand-file-name
          (or (getenv "CHAT_CAMPAIGN_DIRECTORY")
              "~/.chat/evaluations/coding-campaigns/"))))
       (runtime-home (getenv "CHAT_CAMPAIGN_RUNTIME_HOME"))
       (setup-file (getenv "CHAT_CAMPAIGN_SETUP_FILE"))
       implementation-clean harness-clean toolchain suite)
  (unless (member role '("baseline" "current"))
    (error "CHAT_CAMPAIGN_ROLE must be baseline or current"))
  (chat-campaign-runner--validate-qualification-model provider model)
  (unless (file-regular-p manifest)
    (error "Campaign manifest is unavailable: %s" manifest))
  (setq implementation-clean
        (chat-campaign-runner--validate-checkout
         implementation-root implementation-revision "Implementation"
         allow-dirty)
        harness-clean
        (chat-campaign-runner--validate-checkout
         chat-campaign-runner--harness-root harness-revision "Harness"
         allow-dirty))
  (unless runtime-home
    (error "Campaign runtime HOME was not isolated by the runner entrypoint"))
  (load (expand-file-name "chat.el" implementation-root) nil nil t)
  (let ((agent-version
         (and (boundp 'chat-agent-config-protocol-version)
              chat-agent-config-protocol-version))
        (observer-version
         (and (boundp 'chat-model-event-observer-protocol-version)
              chat-model-event-observer-protocol-version))
        (capability-version
         (and (boundp 'chat-model-capabilities-schema-version)
              chat-model-capabilities-schema-version)))
    (chat-campaign-runner--load-harness-contracts implementation-root)
    (chat-campaign-runner--configure-implementation-contracts
     agent-version observer-version capability-version))
  (setq chat-default-model provider
        chat-eval-auto-save t
        chat-coding-eval-approval-mode 'guarded
        chat-coding-eval-max-fixture-files 12000
        chat-coding-eval-campaign-directory campaign-root)
  (when-let ((config (chat-llm-get-provider-config provider)))
    (plist-put config :model model))
  (setq toolchain
        (chat-campaign-runner--validate-judge-executables
         (chat-coding-eval-load-suite manifest)))
  (princ
   (format "CAMPAIGN_TOOLCHAIN_READY executables=%s\n"
           (mapconcat (lambda (entry) (alist-get 'name entry))
                      toolchain ",")))
  (if preflight
      (let* ((chat-coding-eval-campaign-directory
              (make-temp-file "chat-campaign-preflight-" t))
             (campaign
              (chat-coding-eval-prepare-campaign
               campaign-id provider model repetitions manifest
               :implementation-revision implementation-revision :role role
               :toolchain toolchain))
             (descriptor (plist-get campaign :descriptor)))
        (unwind-protect
            (princ
             (format "CAMPAIGN_PREFLIGHT clean=%s descriptor=%s\n"
                     (if (and implementation-clean harness-clean) "true" "false")
                     (chat-campaign-runner--descriptor-summary descriptor)))
          (delete-directory chat-coding-eval-campaign-directory t)))
    (unless (and (stringp setup-file) (file-regular-p setup-file))
      (error "CHAT_CAMPAIGN_SETUP_FILE must name a trusted regular file"))
    (load (file-truename setup-file) nil nil t)
    (unless (chat-llm-provider-configured-p provider)
      (error "Campaign provider is not configured: %s" provider))
    (let ((response (chat-campaign-runner--provider-readiness provider model)))
      (princ (format "CAMPAIGN_PROVIDER_READY provider=%s model=%s chars=%d\n"
                     provider model (length response))))
    (let* ((campaign-directory (expand-file-name campaign-id campaign-root))
           (completion (expand-file-name "completion.json" campaign-directory))
           (lock (expand-file-name ".running.json" campaign-directory))
           (deadline (+ (float-time) deadline-seconds)))
      (unwind-protect
          (progn
            (setq suite
                  (chat-campaign-runner--start-or-resume
                   campaign-directory provider repetitions manifest model
                   campaign-id implementation-revision role toolchain))
            (while (and (file-exists-p lock) (< (float-time) deadline))
              (accept-process-output nil 1))
            (cond
             ((file-exists-p completion)
              (princ (format "CAMPAIGN_COMPLETE directory=%s\n"
                             campaign-directory)))
             ((>= (float-time) deadline)
              (error "Campaign exceeded its runner deadline"))
             (t
              (error "Campaign paused before completion: %s"
                     campaign-directory))))
        (when (and suite (file-exists-p lock))
          (chat-coding-eval-cancel-suite suite)
          (let ((cleanup-deadline (+ (float-time) 10)))
            (while (and (file-exists-p lock)
                        (< (float-time) cleanup-deadline))
              (accept-process-output nil 0.1)))))))))

(defun chat-campaign-runner-main ()
  "Run one campaign inside a dedicated runtime HOME."
  (chat-campaign-runner--call-with-isolated-runtime
   #'chat-campaign-runner--main-in-isolated-runtime))

(unless (equal "1" (getenv "CHAT_CAMPAIGN_RUNNER_LIBRARY_ONLY"))
  (chat-campaign-runner-main))

(provide 'run-coding-campaign)

;;; run-coding-campaign.el ends here
