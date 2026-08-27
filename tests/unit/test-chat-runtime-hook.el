;;; test-chat-runtime-hook.el --- Runtime hook declaration tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-runtime-hook)

(defmacro chat-runtime-hook-test--isolated (&rest body)
  "Run BODY with isolated runtime hook and event registries."
  `(let ((chat-runtime-hook--registry (make-hash-table :test 'eq))
         (chat-runtime-hook--blocker-wrappers nil)
         (chat-runtime-hook--observer-wrappers nil)
         (chat-event-blocker-functions nil)
         (chat-event-observer-functions nil)
         (chat-extension-trusted-project-roots nil))
     (unwind-protect
         (progn ,@body)
       (dolist (declaration (chat-runtime-hook-list))
         (chat-runtime-hook-unregister
          (chat-runtime-hook-id declaration))))))

(ert-deftest chat-runtime-hook-orders-and-filters-observers ()
  "Named hooks run deterministically and only for declared event types."
  (chat-runtime-hook-test--isolated
   (let (seen)
     (chat-runtime-hook-register
      (chat-runtime-hook-create
       :id 'later :phase 'observer :events '(post-tool)
       :priority 20 :handler (lambda (_event) (push 'later seen))))
     (chat-runtime-hook-register
      (chat-runtime-hook-create
       :id 'earlier :phase 'observer :events '(post-tool)
       :priority 10 :handler (lambda (_event) (push 'earlier seen))))
     (chat-event-publish (chat-event-create :type 'turn-start))
     (should-not seen)
     (chat-event-publish (chat-event-create :type 'post-tool))
     (should (equal (nreverse seen) '(earlier later))))))

(ert-deftest chat-runtime-hook-blockers-use-the-lifecycle-policy ()
  "Blocker declarations return decisions through the M1 event bus."
  (chat-runtime-hook-test--isolated
   (chat-runtime-hook-register
    (chat-runtime-hook-create
     :id 'deny-write :phase 'blocker :events '(pre-tool)
     :handler (lambda (_event)
                (list :decision 'block :reason "policy"))))
   (let ((outcome
          (chat-event-publish (chat-event-create :type 'pre-tool))))
     (should-not (chat-event-allowed-p outcome))
     (should (equal (plist-get outcome :reason) "policy")))
   (should-error
    (chat-runtime-hook-register
     (chat-runtime-hook-create
      :id 'invalid :phase 'blocker :events '(post-tool)
      :handler #'ignore)))))

(ert-deftest chat-runtime-hook-honors-declaration-timeout ()
  "A hook-local timeout is reported through the lifecycle failure policy."
  (chat-runtime-hook-test--isolated
   (let ((chat-event-blocker-timeout nil))
     (chat-runtime-hook-register
      (chat-runtime-hook-create
       :id 'slow :phase 'blocker :events '(pre-tool) :timeout 0.001
       :handler (lambda (_event) (sleep-for 0.02) 'allow)))
     (let ((outcome
            (chat-event-publish (chat-event-create :type 'pre-tool))))
       (should-not (chat-event-allowed-p outcome))
       (should (eq (plist-get outcome :failure) 'timeout))))))

(ert-deftest chat-runtime-hook-project-source-requires-trust ()
  "A project hook cannot register outside an explicitly trusted root."
  (chat-runtime-hook-test--isolated
   (chat-test-with-temp-dir
    (let ((declaration
           (chat-runtime-hook-create
            :id 'project-hook :phase 'observer :events '(turn-start)
            :source 'project :project-root temp-dir :handler #'ignore)))
      (should-error (chat-runtime-hook-register declaration))
      (let ((chat-extension-trusted-project-roots (list temp-dir)))
        (should (eq (chat-runtime-hook-id
                     (chat-runtime-hook-register declaration))
                    'project-hook)))))))

(ert-deftest chat-runtime-hook-owner-removal-is-atomic ()
  "Owners can roll back every declaration they installed."
  (chat-runtime-hook-test--isolated
   (dolist (id '(one two))
     (chat-runtime-hook-register
      (chat-runtime-hook-create
       :id id :phase 'observer :events '(turn-start)
       :owner 'demo :handler #'ignore)))
   (chat-runtime-hook-register
    (chat-runtime-hook-create
     :id 'other :phase 'observer :events '(turn-start)
     :owner 'elsewhere :handler #'ignore))
   (should (equal (chat-runtime-hook-unregister-owner 'demo) '(one two)))
   (should-not (chat-runtime-hook-get 'one))
   (should (chat-runtime-hook-get 'other))))

(provide 'test-chat-runtime-hook)
;;; test-chat-runtime-hook.el ends here
