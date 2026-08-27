;;; test-chat-event.el --- Runtime lifecycle event contract -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-event)

(defmacro chat-event-test-with-wire (&rest body)
  "Run BODY with isolated event persistence state."
  `(chat-test-with-temp-dir
    (let ((chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (chat-session-wire-enabled t)
          (chat-event-observer-functions nil)
          (chat-event-blocker-functions nil)
          (chat-event--id-sequence 0))
      ,@body)))

(ert-deftest chat-event-contract-generates-identity-and-provenance ()
  "A published event has stable identity and durable provenance."
  (chat-event-test-with-wire
   (let* ((seen nil)
          (event (chat-event-create
                  :type 'turn-start
                  :session-id "session-1"
                  :turn-id 3
                  :source 'agent
                  :payload '((step . 2)))))
     (chat-event-add-observer (lambda (item) (setq seen item)))
     (should (equal 'observe (plist-get (chat-event-publish event) :decision)))
     (should (eq event seen))
     (should (string-prefix-p "event-" (chat-event-id event)))
     (should (integerp (chat-event-timestamp-ms event)))
     (let ((record (car (chat-session-wire-read "session-1"))))
       (should (equal (chat-event-id event) (alist-get 'event_id record)))
       (should (equal chat-event-schema-version
                      (alist-get 'event_schema_version record)))
       (should (equal "agent" (alist-get 'source record)))
       (should (equal 3 (alist-get 'turn_id record)))
       (should (equal "observe" (alist-get 'event_decision record)))))))

(ert-deftest chat-event-observers-run-in-registration-order-and-cannot-break-publish ()
  "Observer failures are diagnostic and later observers still run."
  (let ((chat-event-observer-functions nil)
        (order nil)
        (chat-log-enabled nil))
    (chat-event-add-observer
     (lambda (_event) (push 'first order) (error "observer failed")))
    (chat-event-add-observer (lambda (_event) (push 'second order)))
    (should
     (equal 'observe
            (plist-get
             (chat-event-publish (chat-event-create :type 'turn-start))
             :decision)))
    (should (equal '(first second) (nreverse order)))))

(ert-deftest chat-event-nonblocking-events-never-run-blockers ()
  "Only declared blocking types consult synchronous policy."
  (let ((chat-event-blocker-functions
         (list (lambda (_event) (error "must not run"))))
        (chat-event-blocking-types '(pre-tool)))
    (should
     (equal 'observe
            (plist-get
             (chat-event-publish (chat-event-create :type 'turn-start))
             :decision)))))

(ert-deftest chat-event-blockers-can-modify-then-block-in-order ()
  "A later blocker sees modifications made by an earlier blocker."
  (let ((chat-event-blocking-types '(pre-tool))
        (chat-event-blocker-functions nil)
        (event (chat-event-create
                :type 'pre-tool
                :payload '((tool . "shell") (command . "old"))
                :subject '(:command "old"))))
    (chat-event-add-blocker
     (lambda (_event)
       '(:decision modify
         :payload ((tool . "shell") (command . "checked"))
         :subject (:command "checked"))))
    (chat-event-add-blocker
     (lambda (item)
       (when (equal "checked" (alist-get 'command (chat-event-payload item)))
         '(:decision block :reason "policy refused the checked command"))))
    (let ((outcome (chat-event-publish event)))
      (should-not (chat-event-allowed-p outcome))
      (should (equal "policy refused the checked command"
                     (plist-get outcome :reason)))
      (should (equal "checked"
                     (alist-get 'command (chat-event-payload event))))
      (should (equal "checked"
                     (plist-get (chat-event-subject event) :command))))))

(ert-deftest chat-event-live-subject-never-reaches-the-wire ()
  "Runtime objects are available to policy but absent from persistence."
  (chat-event-test-with-wire
   (let ((chat-event-blocking-types '(pre-tool))
         (chat-event-blocker-functions nil)
         (secret-object (list :command (make-string 5000 ?x))))
     (chat-event-add-blocker
      (lambda (event)
        (should (eq secret-object (chat-event-subject event)))
        nil))
     (chat-event-publish
      (chat-event-create
       :type 'pre-tool
       :session-id "session-private"
       :payload '((tool . "shell"))
       :subject secret-object))
     (let ((encoded
            (json-encode
             (car (chat-session-wire-read "session-private")))))
       (should-not (string-match-p (make-string 100 ?x) encoded))))))

(ert-deftest chat-event-security-blocker-errors-fail-closed ()
  "A broken security blocker cannot turn into permission."
  (let ((chat-event-blocking-types '(pre-tool))
        (chat-event-failure-policies '((pre-tool . fail-closed)))
        (chat-event-blocker-functions
         (list (lambda (_event) (error "policy unavailable")))))
    (let ((outcome
           (chat-event-publish
            (chat-event-create :type 'pre-tool))))
      (should-not (chat-event-allowed-p outcome))
      (should (eq 'error (plist-get outcome :failure)))
      (should (string-match-p "policy unavailable"
                              (plist-get outcome :reason))))))

(ert-deftest chat-event-invalid-security-modifications-fail-closed-and-roll-back ()
  "Malformed policy replacements cannot corrupt or authorize an event."
  (let* ((original '((tool . "shell")))
         (event (chat-event-create :type 'pre-tool :payload original))
         (chat-event-blocking-types '(pre-tool))
         (chat-event-failure-policies '((pre-tool . fail-closed)))
         (chat-event-blocker-functions
          (list (lambda (_event)
                  '(:decision modify :payload "not-an-alist")))))
    (let ((outcome (chat-event-publish event)))
      (should-not (chat-event-allowed-p outcome))
      (should (eq 'invalid-modification (plist-get outcome :failure)))
      (should (eq original (chat-event-payload event))))))

(ert-deftest chat-event-producer-context-cannot-spoof-runtime-metadata ()
  "Only the runtime may write event identity and decision envelope fields."
  (chat-event-test-with-wire
   (let ((event (chat-event-create
                 :type 'turn-start
                 :session-id "session-reserved"
                 :source 'agent
                 :context '((event_id . "forged")
                            (event_decision . "block")
                            (extension . "kept")))))
     (chat-event-publish event)
     (let ((record (car (chat-session-wire-read "session-reserved"))))
       (should (equal (chat-event-id event) (alist-get 'event_id record)))
       (should (equal "observe" (alist-get 'event_decision record)))
       (should (equal "kept" (alist-get 'extension record)))
       (should (= 1 (length (seq-filter
                             (lambda (entry) (eq (car entry) 'event_id))
                             record))))))))

(ert-deftest chat-event-notification-policy-errors-fail-open-and-are-audited ()
  "A fail-open hook failure is visible without blocking the action."
  (chat-event-test-with-wire
   (let ((chat-event-blocking-types '(user-prompt-submitted))
         (chat-event-failure-policies nil)
         (chat-event-blocker-functions
          (list (lambda (_event) 'not-a-valid-result))))
     (let ((outcome
            (chat-event-publish
             (chat-event-create
              :type 'user-prompt-submitted
              :session-id "session-2"))))
       (should (chat-event-allowed-p outcome))
       (should (eq 'invalid-result
                   (plist-get (car (plist-get outcome :failures)) :failure)))
       (let* ((record (car (chat-session-wire-read "session-2")))
              (failures (alist-get 'event_failures record)))
         (should (equal "allow" (alist-get 'event_decision record)))
         (should (equal "invalid-result"
                        (alist-get 'failure (car failures)))))))))

(ert-deftest chat-event-security-blocker-timeouts-fail-closed ()
  "A security blocker that does not answer within its budget blocks."
  (let ((chat-event-blocking-types '(pre-tool))
        (chat-event-failure-policies '((pre-tool . fail-closed)))
        (chat-event-blocker-timeout 0.001)
        (chat-event-blocker-functions
         (list (lambda (_event) (sleep-for 0.05) nil))))
    (let ((outcome
           (chat-event-publish (chat-event-create :type 'pre-tool))))
      (should-not (chat-event-allowed-p outcome))
      (should (eq 'timeout (plist-get outcome :failure))))))

(provide 'test-chat-event)
;;; test-chat-event.el ends here
