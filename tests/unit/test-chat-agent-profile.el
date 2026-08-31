;;; test-chat-agent-profile.el --- Agent profile contract tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-agent)
(require 'chat-agent-profile)
(require 'chat-subagent)

(defmacro chat-agent-profile-test--isolated (&rest body)
  "Run BODY with isolated profile, skill, and capability registries."
  `(let ((chat-agent-profile--registry (make-hash-table :test 'eq))
         (chat-agent-profile--candidates (make-hash-table :test 'eq))
         (chat-agent-profile--discovery-root nil)
         (chat-agent-profile--discovered-p nil)
         (chat-skill--registry (make-hash-table :test 'eq))
         (chat-skill--candidates (make-hash-table :test 'eq))
         (chat-skill--discovery-root nil)
         (chat-skill--discovered-p nil)
         (chat-model-capabilities--registry nil)
         (chat-model-discovery--loaded t)
         (chat-session-auto-save nil)
         (chat-extension-trusted-project-roots nil))
     ,@body))

(defun chat-agent-profile-test--register (id &rest fields)
  "Register profile ID with FIELDS and return it."
  (chat-agent-profile-register
   (apply #'chat-agent-profile-create
          :id id :revision "1" :source 'test fields)))

(ert-deftest chat-agent-profile-advertisement-narrows-without-changing-authority ()
  "A runtime tool menu can narrow, but cannot widen, profile authority."
  (chat-agent-profile-test--isolated
   (let* ((profile (chat-agent-profile-create
                    :id 'code :revision "1" :source 'test
                    :tools '(read write) :tools-specified-p t))
          (chat-agent-profile-tool-advertisement-functions
           (list (lambda (_session _profile _authorized)
                   '(:advertised-tools (read)))))
          (config (chat-agent-profile--effective-tool-config nil profile)))
     (should (equal '(read write) (plist-get config :enabled-tools)))
     (should (equal '(read) (plist-get config :advertised-tools))))
   (let* ((profile (chat-agent-profile-create
                    :id 'code :revision "1" :source 'test
                    :tools '(read) :tools-specified-p t))
          (chat-agent-profile-tool-advertisement-functions
           (list (lambda (_session _profile _authorized)
                   '(:advertised-tools (write))))))
     (should-error (chat-agent-profile--effective-tool-config nil profile)
                   :type 'chat-agent-profile-authority-expansion))))

(ert-deftest chat-agent-profile-inheritance-only-tightens-tool-authority ()
  "Inherited tool lists intersect and budgets choose the lower ceiling."
  (chat-agent-profile-test--isolated
   (chat-agent-profile-test--register
    'base :instructions "base" :tools '(read write)
    :tools-specified-p t :max-steps 20)
   (chat-agent-profile-test--register
    'child :extends '(base) :instructions "child"
    :tools '(read inspect) :tools-specified-p t :max-steps 8)
   (let ((profile (chat-agent-profile-resolve 'child)))
     (should (equal (chat-agent-profile-tools profile) '(read)))
     (should (= (chat-agent-profile-max-steps profile) 8))
     (should (equal (chat-agent-profile-instructions profile)
                    "base\n\nchild"))
     (should (equal (mapcar (lambda (item) (plist-get item :id))
                            (chat-agent-profile-provenance profile))
                    '(base child))))))

(ert-deftest chat-agent-profile-detects-inheritance-cycles ()
  "A cyclic profile graph is rejected with its own condition."
  (chat-agent-profile-test--isolated
   (chat-agent-profile-test--register 'left :extends '(right))
   (chat-agent-profile-test--register 'right :extends '(left))
   (should-error (chat-agent-profile-resolve 'left)
                 :type 'chat-agent-profile-cycle)))

(ert-deftest chat-agent-profile-validates-model-capabilities-before-run ()
  "A known incompatible model is rejected before transport dispatch."
  (chat-agent-profile-test--isolated
   (chat-model-capabilities-register
    'demo "small" '(:tools nil :reasoning nil) 'user)
   (chat-agent-profile-test--register
    'reasoner :provider 'demo :model "small"
    :required-capabilities '(:reasoning t))
   (should-error
    (chat-agent-profile-prepare-config
     (list :profile 'reasoner :provider 'demo :messages nil))
    :type 'chat-agent-profile-capability-mismatch)))

(ert-deftest chat-agent-profile-provider-override-resolves-new-model-name ()
  "Changing providers freezes the new default instead of carrying the old id."
  (chat-agent-profile-test--isolated
   (chat-agent-profile-test--register 'other :provider 'deepseek)
   (let ((prepared
          (chat-agent-profile-prepare-config
           (list :profile 'other :provider 'kimi :model "k3" :messages nil
                 :request-options '(:timeout 10)))))
     (should (eq (plist-get prepared :provider) 'deepseek))
     (should (equal
              (plist-get (chat-llm-get-provider-config 'deepseek) :model)
              (plist-get prepared :model)))
     (should-not (plist-member (plist-get prepared :request-options)
                               :model))
     (should (= (plist-get (plist-get prepared :request-options) :timeout)
                10)))))

(ert-deftest chat-agent-profile-inherited-provider-drops-parent-model ()
  "A provider override in an inheritance chain clears the parent model."
  (chat-agent-profile-test--isolated
   (chat-agent-profile-test--register
    'base-model :provider 'kimi :model "k3")
   (chat-agent-profile-test--register
    'other-provider :extends '(base-model) :provider 'deepseek)
   (let ((profile (chat-agent-profile-resolve 'other-provider)))
     (should (eq (chat-agent-profile-provider profile) 'deepseek))
     (should-not (chat-agent-profile-model profile)))))

(ert-deftest chat-agent-profile-trusted-project-overrides-user-file ()
  "Project manifests outrank user manifests only inside trusted roots."
  (chat-agent-profile-test--isolated
   (chat-test-with-temp-dir
    (let* ((project (expand-file-name "project/" temp-dir))
           (user (expand-file-name "user/" temp-dir))
           (chat-agent-profile-user-directory user)
           (chat-extension-trusted-project-roots (list project)))
      (dolist (entry `((,(expand-file-name "shared.agent.json" user)
                         . "user")
                        (,(expand-file-name
                           ".chat/agents/shared.agent.json" project)
                         . "project")))
        (make-directory (file-name-directory (car entry)) t)
        (with-temp-file (car entry)
          (insert (json-encode
                   `((schemaVersion . 1)
                     (id . "shared")
                     (revision . "1")
                     (instructions . ,(cdr entry)))))))
      (should (equal
               (chat-agent-profile-instructions
                (chat-agent-profile-resolve 'shared project))
               "project"))))))

(ert-deftest chat-agent-profile-selection-preserves-session-overlays ()
  "Selecting and clearing a profile does not erase independent tool policy."
  (chat-agent-profile-test--isolated
   (chat-agent-profile-test--register 'review :instructions "review")
   (let ((session (make-chat-session
                   :id "select"
                   :tool-config '(:enabled-tools (read) :disabled-tools (write)))))
     (chat-agent-profile-select 'review session default-directory)
     (should (eq (plist-get (chat-session-tool-config session) :profile)
                 'review))
     (should (equal (plist-get (chat-session-tool-config session)
                               :enabled-tools)
                    '(read)))
     (chat-agent-profile-clear session)
     (should-not (plist-member (chat-session-tool-config session) :profile))
     (should (equal (plist-get (chat-session-tool-config session)
                               :disabled-tools)
                    '(write))))))

(ert-deftest chat-agent-profile-refuses-skill-tool-authority-expansion ()
  "A skill may request authority but can never grant it to itself."
  (chat-agent-profile-test--isolated
   (chat-skill-register
    (chat-skill-create
     :id 'writer :revision "1" :instructions "write"
     :tools '(write) :source 'test))
   (chat-agent-profile-test--register
    'reader :skills '(writer) :tools '(read) :tools-specified-p t)
   (should-error
    (chat-agent-profile-prepare-config
     (list :profile 'reader :provider 'demo :messages nil))
    :type 'chat-agent-profile-authority-expansion)))

(ert-deftest chat-agent-profile-cannot-weaken-session-approval ()
  "Profile policy is transient, stricter-only, and leaves SESSION unchanged."
  (chat-agent-profile-test--isolated
   (let* ((session (make-chat-session
                    :id "approval" :approval-mode 'manual
                    :tool-config '(:enabled-tools (read write))))
          (original (copy-tree (chat-session-tool-config session))))
     (chat-agent-profile-test--register
      'attempt :tools '(read) :tools-specified-p t
      :approval-mode 'dangerous)
     (let* ((prepared
             (chat-agent-profile-prepare-config
              (list :profile 'attempt :provider 'demo :session session
                    :messages nil :max-steps 12)))
            (execution (plist-get prepared :execution-session))
            (profile (plist-get prepared :profile-resolved)))
       (should (eq (chat-session-approval-mode execution) 'manual))
       (should (chat-session-tool-enabled-p execution 'read))
       (should-not (chat-session-tool-enabled-p execution 'write))
       (should (equal (chat-session-tool-config session) original))
       (should (eq (chat-session-approval-mode session) 'manual))
       (should (seq-some
                (lambda (text) (string-match-p "could not weaken" text))
                (chat-agent-profile-diagnostics profile)))))))

(ert-deftest chat-agent-profile-projects-subagent-limit-into-execution ()
  "The resolved nested-agent ceiling travels with the execution session."
  (chat-agent-profile-test--isolated
   (chat-agent-profile-test--register 'shallow :subagent-limit 1)
   (let* ((prepared
           (chat-agent-profile-prepare-config
            (list :profile 'shallow :provider 'kimi :messages nil)))
          (execution (plist-get prepared :execution-session)))
     (should (= (plist-get (chat-session-tool-config execution)
                           :subagent-max-depth)
                1))
     (should-error (chat-subagent--ensure-depth 2 execution)))))

(ert-deftest chat-agent-profile-digest-covers-instructions-and-skills ()
  "Resolved digests change when behavior changes, not only ids do."
  (chat-agent-profile-test--isolated
   (chat-skill-register
    (chat-skill-create
     :id 'guidance :revision "1" :instructions "first" :source 'test))
   (chat-agent-profile-test--register
    'worker :instructions "profile" :skills '(guidance))
   (let ((before (chat-agent-profile-digest
                  (chat-agent-profile-resolve 'worker))))
     (chat-skill-register
      (chat-skill-create
       :id 'guidance :revision "1" :instructions "second" :source 'test))
     (should-not
      (equal before
             (chat-agent-profile-digest
              (chat-agent-profile-resolve 'worker)))))))

(ert-deftest chat-agent-profile-snapshot-records-effective-authority ()
  "Audit snapshots describe the execution session after intersection."
  (chat-agent-profile-test--isolated
   (chat-agent-profile-test--register
    'writer :tools '(read write) :tools-specified-p t
    :approval-mode 'guarded)
   (let* ((session (make-chat-session
                    :id "snapshot"
                    :approval-mode 'manual
                    :tool-config '(:enabled-tools (read) :disabled-tools (shell))))
          (prepared
           (chat-agent-profile-prepare-config
            (list :profile 'writer :provider 'demo :session session
                  :messages nil)))
          (snapshot
           (chat-agent-profile-snapshot
            (plist-get prepared :profile-resolved)
            (plist-get prepared :execution-session))))
     (should (equal (cdr (assoc 'enabled_tools snapshot)) '("read")))
     (should (equal (cdr (assoc 'disabled_tools snapshot)) '("shell")))
     (should (equal (cdr (assoc 'effective_approval_mode snapshot))
                    "manual")))))

(ert-deftest chat-agent-profile-run-is-reproducible-and-does-not-persist-prompt ()
  "A run receives one resolved snapshot while session history stays clean."
  (chat-agent-profile-test--isolated
   (chat-model-capabilities-register 'kimi nil '(:tools nil) 'user)
   (chat-agent-profile-test--register
    'review :instructions "Review objectively" :max-steps 4)
   (let* ((user (make-chat-message :id "u" :role :user :content "inspect"))
          (session (make-chat-session
                    :id "profile-run" :messages (list user)))
          events calls run)
     (cl-letf (((symbol-function 'chat-llm-request-async)
                (lambda (_model messages success _error _options)
                  (setq calls messages)
                  (funcall success '(:content "done"))
                  'stub)))
       (setq run
             (chat-agent-start
              (list :profile 'review :provider 'kimi :session session
                    :messages (list user) :max-steps 10
                    :on-event (lambda (event) (push event events))))))
     (should (= (chat-agent-run-state-max-steps run) 4))
     (should (chat-agent-profile-p (chat-agent-run-state-profile run)))
     (should (eq (chat-message-role (car calls)) :system))
     (should (equal (chat-message-content (car calls)) "Review objectively"))
     (should (equal (chat-session-messages session) (list user)))
     (let ((event (seq-find (lambda (item)
                              (eq (plist-get item :type) 'profile-resolved))
                            events)))
       (should event)
       (should (equal
                (cdr (assoc 'profile_id
                            (chat-agent-profile-snapshot
                             (plist-get event :profile))))
                "review"))))))

(provide 'test-chat-agent-profile)
;;; test-chat-agent-profile.el ends here
