;;; test-chat-work-context.el --- Structured context tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-work-context)

(defmacro chat-work-context-test--isolated (&rest body)
  "Run BODY with an empty durable work-context store."
  (declare (indent 0))
  `(chat-test-with-temp-dir
    (let ((chat-work-context-directory temp-dir)
          (chat-work-context--stores (make-hash-table :test 'equal)))
      ,@body)))

(defun chat-work-context-test--fragment (id authority scope scope-id payload)
  "Return a test fragment."
  (chat-context-fragment-create
   :id id :kind 'instruction :authority authority :source-kind 'file
   :source-id id :scope scope :scope-id scope-id :priority 0
   :residency 'compactable :budget-policy 'compact :payload payload
   :status 'active))

(ert-deftest chat-work-context-scope-isolates-directory-and-session ()
  "Directory and session scopes cannot leak into siblings or other sessions."
  (chat-test-with-temp-dir
   (let* ((root (file-name-as-directory (file-truename temp-dir)))
          (left (expand-file-name "left/a.el" root))
          (right (expand-file-name "right/b.el" root)))
     (make-directory (file-name-directory left) t)
     (make-directory (file-name-directory right) t)
     (let* ((fragments
             (list
              (chat-work-context-test--fragment
               "left" 'project 'directory (file-name-directory left) "LEFT")
              (chat-work-context-test--fragment
               "session" 'agent 'session "s1" "SESSION")))
            (left-bundle
             (chat-context-bundle-build
              fragments :session-id "s1" :project-root root :target-path left))
            (right-bundle
             (chat-context-bundle-build
              fragments :session-id "s2" :project-root root :target-path right)))
       (should (equal (mapcar #'chat-context-fragment-id
                              (chat-context-bundle-fragments left-bundle))
                      '("left" "session")))
       (should-not (chat-context-bundle-fragments right-bundle))
       (should (= (length (chat-context-bundle-omitted right-bundle)) 2))))))

(ert-deftest chat-work-context-authority-and-scope-order-are-deterministic ()
  "Selection orders authority first and specificity second."
  (let* ((fragments
          (list
           (chat-work-context-test--fragment "agent" 'agent 'global nil "A")
           (chat-work-context-test--fragment "project" 'project 'global nil "P")
           (chat-work-context-test--fragment "system" 'system 'global nil "S")))
         (bundle (chat-context-bundle-build fragments)))
    (should (equal (mapcar #'chat-context-fragment-id
                           (chat-context-bundle-fragments bundle))
                   '("system" "project" "agent")))
    (should (equal (chat-context-bundle-digest bundle)
                   (chat-context-bundle-digest
                    (chat-context-bundle-build (reverse fragments)))))))

(ert-deftest chat-work-context-budget-explains-omissions ()
  "A bounded bundle keeps an explicit reason for excluded fragments."
  (let* ((first (chat-work-context-test--fragment
                 "first" 'system 'global nil "12345"))
         (second (chat-work-context-test--fragment
                  "second" 'agent 'global nil "67890"))
         (bundle (chat-context-bundle-build (list second first) :max-chars 5)))
    (should (equal (mapcar #'chat-context-fragment-id
                           (chat-context-bundle-fragments bundle))
                   '("first")))
    (should (equal (plist-get (car (chat-context-bundle-omitted bundle)) :reason)
                   'budget))))

(ert-deftest chat-work-context-budget-never-trims-protected-fragments ()
  "Resident rules remain selected and expose a protected overflow."
  (let* ((resident (chat-work-context-test--fragment
                    "resident" 'project 'global nil "123456"))
         (ordinary (chat-work-context-test--fragment
                    "ordinary" 'project 'global nil "x")))
    (setf (chat-context-fragment-residency resident) 'protected)
    (let ((bundle (chat-context-bundle-build
                   (list ordinary resident) :max-chars 2)))
      (should (equal (mapcar #'chat-context-fragment-id
                             (chat-context-bundle-fragments bundle))
                     '("resident")))
      (should (seq-some
               (lambda (item)
                 (eq (plist-get item :reason) 'protected-overflow))
               (chat-context-bundle-diagnostics bundle))))))

(ert-deftest chat-work-note-revision-conflict-preserves-durable-bytes ()
  "A stale writer cannot overwrite the current note."
  (chat-work-context-test--isolated
    (let* ((note (chat-work-note-upsert
                  "s" "decision.api" '((choice . "v1"))
                  :kind 'decision :source-id "turn:1"))
           (updated (chat-work-note-upsert
                     "s" "decision.api" '((choice . "v2"))
                     :expected-revision 1 :kind 'decision :source-id "turn:2"))
           (file (chat-work-context--file "s"))
           (before (with-temp-buffer
                     (insert-file-contents-literally file) (buffer-string))))
      (should (= (chat-work-note-revision updated) 2))
      (should-error
       (chat-work-note-upsert
        "s" "decision.api" '((choice . "stale"))
        :expected-revision 1 :kind 'decision :source-id "turn:1")
       :type 'chat-work-context-stale-revision)
      (should (equal before
                     (with-temp-buffer
                       (insert-file-contents-literally file) (buffer-string))))
      (should (equal (chat-work-note-value (chat-work-note-get "s" (chat-work-note-id note)))
                     '((choice . "v2")))))))

(ert-deftest chat-work-note-restarts-and-queries-by-kind-tag-and-scope ()
  "Indexed note fields remain queryable after a fresh load."
  (chat-work-context-test--isolated
    (chat-work-note-upsert
     "s" "next" "run tests" :task-id "task" :kind 'next-step
     :tags '(verification) :scope 'task :scope-id "task" :source-id "turn:3")
    (clrhash chat-work-context--stores)
    (let ((notes (chat-work-note-list
                  "s" :task-id "task" :kind 'next-step :tag 'verification
                  :status 'active
                  :context '(:session-id "s" :task-id "task"))))
      (should (= (length notes) 1))
      (should (equal (chat-work-note-value (car notes)) "run tests")))))

(ert-deftest chat-work-note-identity-includes-scope ()
  "The same key in two scopes creates two independently revisioned notes."
  (chat-work-context-test--isolated
    (let ((session-note
           (chat-work-note-upsert
            "s" "decision.api" "session" :kind 'decision
            :scope 'session :source-id "turn:1"))
          (task-note
           (chat-work-note-upsert
            "s" "decision.api" "task" :kind 'decision :task-id "task-1"
            :scope 'task :scope-id "task-1" :source-id "turn:1")))
      (should-not (equal (chat-work-note-id session-note)
                         (chat-work-note-id task-note)))
      (should (= (length (chat-work-note-list "s" :status 'active)) 2))
      (should (= (chat-work-note-revision session-note) 1))
      (should (= (chat-work-note-revision task-note) 1)))))

(ert-deftest chat-work-note-status-and-delete-require-current-revision ()
  "Archival and deletion participate in optimistic concurrency."
  (chat-work-context-test--isolated
    (let* ((note (chat-work-note-upsert "s" "blocker" "missing tool"
                                        :kind 'blocker :source-id "turn:1"))
           (id (chat-work-note-id note))
           (archived (chat-work-note-set-status "s" id 1 'archived)))
      (should (= (chat-work-note-revision archived) 2))
      (should-error (chat-work-note-delete "s" id 1)
                    :type 'chat-work-context-stale-revision)
      (should (chat-work-note-delete "s" id 2))
      (should-not (chat-work-note-get "s" id)))))

(ert-deftest chat-work-note-supersede-preserves-both-identities ()
  "Superseding archives the old identity and creates a linked replacement."
  (chat-work-context-test--isolated
    (let* ((old (chat-work-note-upsert
                 "s" "decision.backend" "one" :kind 'decision
                 :source-id "turn:1"))
           (replacement
            (chat-work-note-supersede
             "s" (chat-work-note-id old) 1 "decision.backend" "two"
             :source-id "turn:2")))
      (should-not (equal (chat-work-note-id old)
                         (chat-work-note-id replacement)))
      (should (eq (chat-work-note-status
                   (chat-work-note-get "s" (chat-work-note-id old)))
                  'superseded))
      (should (member (chat-work-note-id old)
                      (chat-work-note-related-ids replacement)))
      (should (= (length (chat-work-note-list "s" :status 'active)) 1)))))

(ert-deftest chat-work-note-fragments-never-gain-instruction-authority ()
  "Agent working notes project as Agent evidence, not project rules."
  (chat-work-context-test--isolated
    (chat-work-note-upsert "s" "guess" "maybe nil" :kind 'hypothesis
                           :source-id "turn:1")
    (let ((fragment
           (car (chat-work-note-fragments
                 "s" '(:session-id "s")))))
      (should (eq (chat-context-fragment-kind fragment) 'working-note))
      (should (eq (chat-context-fragment-authority fragment) 'agent))
      (should (string-match-p "unverified"
                              (chat-context-fragment-payload fragment))))))

(provide 'test-chat-work-context)
;;; test-chat-work-context.el ends here
