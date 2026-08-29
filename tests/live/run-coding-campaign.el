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

(defun chat-campaign-runner--install-runtime-home (runtime-home)
  "Install isolated RUNTIME-HOME without leaving a stale tilde directory."
  (when runtime-home
    (let ((home (file-name-as-directory (expand-file-name runtime-home))))
      (make-directory home t)
      (setenv "HOME" home)
      ;; `default-directory' may have been recorded as ~/... before HOME was
      ;; replaced.  A subprocess expands it after the replacement and then
      ;; cannot start, even though the checkout itself still exists.
      (setq default-directory chat-campaign-runner--harness-root)
      home)))

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
     (manifestDigest . ,(alist-get 'manifestDigest descriptor))
     (configurationDigest . ,(alist-get 'configurationDigest descriptor)))))

(defun chat-campaign-runner--start-or-resume
    (campaign-directory provider repetitions manifest model campaign-id
                        implementation-revision role)
  "Start a new campaign or resume validated missing work in CAMPAIGN-DIRECTORY."
  (if (file-exists-p campaign-directory)
      (progn
        (unless (file-directory-p campaign-directory)
          (error "Campaign path is not a directory: %s" campaign-directory))
        (chat-coding-eval-resume-live
         campaign-directory manifest implementation-revision))
    (chat-coding-eval-run-live
     provider repetitions manifest model campaign-id implementation-revision role)))

(defun chat-campaign-runner-main ()
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
       implementation-clean harness-clean suite)
  (unless (member role '("baseline" "current"))
    (error "CHAT_CAMPAIGN_ROLE must be baseline or current"))
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
  (setq runtime-home
        (chat-campaign-runner--install-runtime-home runtime-home))
  (load (expand-file-name "chat.el" implementation-root) nil nil t)
  (unless (chat-campaign-runner--same-root-p
           implementation-root chat-campaign-runner--harness-root)
    ;; Preserve the historical Agent/runtime while sharing the frozen campaign
    ;; and result contract with the current implementation.
    (load (expand-file-name "lisp/agent/chat-coding-eval.el"
                            chat-campaign-runner--harness-root)
          nil nil t))
  (setq chat-default-model provider
        chat-eval-auto-save t
        chat-coding-eval-approval-mode 'guarded
        chat-coding-eval-max-fixture-files 12000
        chat-coding-eval-campaign-directory campaign-root)
  (when-let ((config (chat-llm-get-provider-config provider)))
    (plist-put config :model model))
  (if preflight
      (let* ((chat-coding-eval-campaign-directory
              (make-temp-file "chat-campaign-preflight-" t))
             (campaign
              (chat-coding-eval-prepare-campaign
               campaign-id provider model repetitions manifest
               :implementation-revision implementation-revision :role role))
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
                   campaign-id implementation-revision role))
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

(unless (equal "1" (getenv "CHAT_CAMPAIGN_RUNNER_LIBRARY_ONLY"))
  (chat-campaign-runner-main))

(provide 'run-coding-campaign)

;;; run-coding-campaign.el ends here
