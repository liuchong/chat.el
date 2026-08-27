;;; chat-eval-scenarios.el --- Built-in runtime evaluations -*- lexical-binding: t; -*-

;;; Commentary:

;; Deterministic, offline scenarios that exercise runtime contracts rather
;; than provider wording.

;;; Code:

(require 'cl-lib)
(require 'chat-eval)
(require 'chat-edit)
(require 'chat-approval-guard)
(require 'chat-checkpoint)
(require 'chat-context-resident)
(require 'chat-model-runtime)

(defun chat-eval-scenario--file-text (file)
  "Return FILE contents."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun chat-eval-scenario-editing (_fixture)
  "Exercise reversible file editing."
  (let* ((root (make-temp-file "chat-eval-edit-" t))
         (file (expand-file-name "sample.txt" root))
         (chat-files-allowed-directories (list root))
         (chat-edit-backup-directory (expand-file-name "backups/" root))
         (chat-edit--history nil)
         changed restored)
    (unwind-protect
        (progn
          (with-temp-file file (insert "alpha\n"))
          (chat-edit-apply-patch file "alpha" "beta")
          (setq changed (equal "beta\n"
                               (chat-eval-scenario--file-text file)))
          (let ((edit (chat-edit-get-last)))
            (when edit (chat-edit-undo edit)))
          (setq restored (equal "alpha\n"
                                (chat-eval-scenario--file-text file)))
          (list (chat-eval-check "patch-applied" changed t changed)
                (chat-eval-check "backup-restored" restored t restored)))
      (when (file-directory-p root)
        (delete-directory root t)))))

(defun chat-eval-scenario-guard (_fixture)
  "Exercise the deterministic Guard floor."
  (let* ((env (chat-approval-guard--environment nil))
         (force-reason
          (chat-approval-guard-never-allow-p
           'shell_execute
           '(("command" . "git push --force-with-lease origin main"))
           env))
         (read-reason
          (chat-approval-guard-never-allow-p
           'shell_execute '(("command" . "git log -3 --oneline")) env)))
    (list
     (chat-eval-check "history-rewrite-refused"
                      (stringp force-reason) "refusal reason"
                      (if force-reason "refused" "not-refused"))
     (chat-eval-check "read-command-outside-floor"
                      (null read-reason) "not refused"
                      (if read-reason "refused" "not-refused")))))

(defun chat-eval-scenario-recovery (_fixture)
  "Exercise the owned-state drift predicate used by rollback."
  (let ((entry (chat-checkpoint-file-create
                :path "owned.txt" :status 'owned
                :post-kind 'file :post-digest "digest-after")))
    (list
     (chat-eval-check
      "owned-post-state-matches"
      (chat-checkpoint--current-matches-post-p
       entry '(:kind file :digest "digest-after"))
      t t)
     (chat-eval-check
      "external-drift-detected"
      (not (chat-checkpoint--current-matches-post-p
            entry '(:kind file :digest "external")))
      t t)
     (chat-eval-check
      "kind-change-detected"
      (not (chat-checkpoint--current-matches-post-p
            entry '(:kind missing :digest nil)))
      t t))))

(defun chat-eval-scenario-compaction (_fixture)
  "Exercise protected instruction cap ordering."
  (let* ((middle (mapconcat #'identity (make-list 40 "overflow") " "))
         (resident (format "keep\n\n%s\n\ntail" middle))
         (result (chat-context-resident-apply-cap resident 1))
         (kept (plist-get result :resident))
         (demoted (plist-get result :demoted)))
    (list
     (chat-eval-check "first-block-remains"
                      (equal kept "keep") "keep" kept)
     (chat-eval-check "overflow-is-demoted"
                      (and demoted (string-match-p "overflow" demoted))
                      t (and demoted t))
     (chat-eval-check "tail-does-not-jump-the-overflow"
                      (and demoted (string-match-p "tail" demoted))
                      t (and demoted
                             (string-match-p "tail" demoted)
                             t)))))

(defun chat-eval-scenario-provider-protocol (_fixture)
  "Exercise normalized response event ordering and shapes."
  (let (events)
    (chat-model-runtime--response-events
     '(:reasoning "reason"
       :content "answer"
       :tool-calls ((:id "call-1" :name "files_read" :arguments "{}"))
       :usage (:input-tokens 5 :output-tokens 3 :total-tokens 8))
     (lambda (type payload)
       (push (cons type payload) events)))
    (setq events (nreverse events))
    (let ((types (mapcar #'car events))
          (tool (cdr (assq 'tool-call-delta events)))
          (usage (cdr (assq 'usage events))))
      (list
       (chat-eval-check
        "normalized-event-order"
        (equal types '(reasoning-delta text-delta tool-call-delta usage))
        '(reasoning-delta text-delta tool-call-delta usage) types)
       (chat-eval-check "tool-identity-preserved"
                        (equal "call-1" (plist-get tool :id))
                        "call-1" (plist-get tool :id))
       (chat-eval-check "usage-total-preserved"
                        (= 8 (plist-get usage :total-tokens))
                        8 (plist-get usage :total-tokens))))))

(defun chat-eval-register-built-ins ()
  "Register the deterministic built-in Agent scenarios."
  (dolist
      (scenario
       (list
        (chat-eval-scenario-create-record
         :schema-version 1 :id "editing-owned-file" :revision 1
         :category "editing" :description "Reversible direct file edit"
         :fixture-id "editing-basic-v1" :fixture '((search . "alpha"))
         :tags '("offline" "editing")
         :function #'chat-eval-scenario-editing)
        (chat-eval-scenario-create-record
         :schema-version 1 :id "guard-permanent-floor" :revision 1
         :category "guard" :description "Permanent floor classification"
         :fixture-id "guard-floor-v1" :fixture '((commandClass . "git"))
         :tags '("offline" "guard")
         :function #'chat-eval-scenario-guard)
        (chat-eval-scenario-create-record
         :schema-version 1 :id "recovery-external-drift" :revision 1
         :category "recovery" :description "Owned post-state comparison"
         :fixture-id "recovery-drift-v1" :fixture '((kind . "file"))
         :tags '("offline" "recovery")
         :function #'chat-eval-scenario-recovery)
        (chat-eval-scenario-create-record
         :schema-version 1 :id "compaction-resident-order" :revision 1
         :category "compaction" :description "Resident instruction ordering"
         :fixture-id "compaction-resident-v1" :fixture '((cap . 1))
         :tags '("offline" "compaction")
         :function #'chat-eval-scenario-compaction)
        (chat-eval-scenario-create-record
         :schema-version 1 :id "provider-normalized-events" :revision 1
         :category "provider-protocol"
         :description "Normalized reasoning, text, tool and usage events"
         :fixture-id "provider-events-v1" :fixture '((transport . "fixture"))
         :tags '("offline" "provider-protocol")
         :function #'chat-eval-scenario-provider-protocol)))
    (chat-eval-register scenario t))
  (chat-eval-scenarios))

(chat-eval-register-built-ins)

(provide 'chat-eval-scenarios)
;;; chat-eval-scenarios.el ends here
