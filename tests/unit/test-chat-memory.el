;;; test-chat-memory.el --- Tests for chat-memory -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-memory)
(require 'chat-tool-caller)

(defmacro chat-memory-test-with-store (&rest body)
  "Run BODY with isolated compatible and structured memory files."
  `(chat-test-with-temp-dir
    (let ((chat-memory-file (expand-file-name "memory.md" temp-dir))
          (chat-memory-directory (expand-file-name "structured/" temp-dir))
          (chat-memory-automatic-enabled nil))
      ,@body)))

(ert-deftest chat-memory-snippet-nil-when-missing ()
  "Test no memory section is produced without a memory file."
  (let ((chat-memory-file (expand-file-name "no-such-memory.md" "/tmp")))
    (should-not (chat-memory-snippet))))

(ert-deftest chat-memory-snippet-reads-and-injects-content ()
  "Test memory content appears in the system prompt."
  (chat-test-with-temp-dir
   (let ((chat-memory-file (expand-file-name "memory.md" temp-dir)))
     (with-temp-file chat-memory-file
       (insert "User prefers concise answers."))
     (let ((snippet (chat-memory-snippet)))
       (should (string-match-p "concise answers" snippet)))
     (let ((prompt (chat-tool-caller-build-system-prompt "Base.")))
       (should (string-match-p "Long term memory" prompt))
       (should (string-match-p "concise answers" prompt))))))

(ert-deftest chat-memory-snippet-truncates-oversized-memory ()
  "Test oversized memory files are truncated with a marker."
  (chat-test-with-temp-dir
   (let ((chat-memory-file (expand-file-name "memory.md" temp-dir))
         (chat-memory-max-chars 20))
     (with-temp-file chat-memory-file
       (insert (make-string 100 ?m)))
     (let ((snippet (chat-memory-snippet)))
       (should (string-match-p "memory truncated" snippet))))))

(ert-deftest chat-memory-empty-file-produces-no-snippet ()
  "Test an empty or blank memory file is ignored."
  (chat-test-with-temp-dir
   (let ((chat-memory-file (expand-file-name "memory.md" temp-dir)))
     (with-temp-file chat-memory-file
       (insert "  \n  "))
     (should-not (chat-memory-snippet)))))

(ert-deftest chat-memory-structured-items-survive-a-reload ()
  "Structured memory is durable and retains its provenance."
  (chat-memory-test-with-store
   (let ((created
          (chat-memory-add "Use the repository formatter."
                           :id "format-rule"
                           :source-kind 'user
                           :source-id "message:m1"
                           :confidence 0.9)))
     (should (file-exists-p (chat-memory--items-file)))
     (let ((loaded (chat-memory-get (chat-memory-item-id created))))
       (should (equal "Use the repository formatter."
                      (chat-memory-item-content loaded)))
       (should (eq 'user (chat-memory-item-source-kind loaded)))
       (should (equal "message:m1" (chat-memory-item-source-id loaded)))))))

(ert-deftest chat-memory-retrieval-enforces-session-and-project-scope ()
  "A scoped item is visible only in the session or project it names."
  (chat-memory-test-with-store
   (let* ((project-a (expand-file-name "a/" temp-dir))
          (project-b (expand-file-name "b/" temp-dir))
          (session-a (chat-session-create "a"))
          (session-b (chat-session-create "b")))
     (make-directory project-a t)
     (make-directory project-b t)
     (chat-session-set-working-directory session-a project-a)
     (chat-session-set-working-directory session-b project-b)
     (chat-memory-add "global" :id "global")
     (chat-memory-add "project-a" :id "project"
                      :scope 'project :scope-id project-a)
     (chat-memory-add "session-a" :id "session"
                      :scope 'session
                      :scope-id (chat-session-id session-a))
     (should (equal '("session" "project" "global")
                    (mapcar #'chat-memory-item-id
                            (chat-memory-effective-items session-a))))
     (should (equal '("global")
                    (mapcar #'chat-memory-item-id
                            (chat-memory-effective-items session-b)))))))

(ert-deftest chat-memory-sensitive-expired-and-archived-items-stay-out ()
  "Only active, current, normal memory enters a prompt."
  (chat-memory-test-with-store
   (chat-memory-add "normal" :id "normal")
   (chat-memory-add "sensitive" :id "sensitive" :sensitivity 'sensitive)
   (chat-memory-add "expired" :id "expired" :retention 'expiring
                    :expires-at 10)
   (chat-memory-add "archived" :id "archived" :status 'archived)
   (let ((snippet (chat-memory-snippet nil)))
     (should (string-match-p "normal" snippet))
     (should-not (string-match-p "sensitive" snippet))
     (should-not (string-match-p "expired" snippet))
     (should-not (string-match-p "archived" snippet)))))

(ert-deftest chat-memory-refuses-secret-like-content-before-writing ()
  "Likely credentials are not left in the durable memory document."
  (chat-memory-test-with-store
   (should-error
    (chat-memory-add "api_key=abcdefghijklmnop" :id "credential"))
   (should-not (file-exists-p (chat-memory--items-file)))))

(ert-deftest chat-memory-automatic-capture-is-off-until-enabled ()
  "Automatic candidates require a durable opt-in and receive an expiry."
  (chat-memory-test-with-store
   (should-not
    (chat-memory-capture-candidate "inferred preference" :source-id "turn:1"))
   (chat-memory-set-automatic t)
   (let ((item
          (chat-memory-capture-candidate
           "inferred preference" :source-id "turn:1")))
     (should (chat-memory-item-p item))
     (should (eq 'inferred (chat-memory-item-source-kind item)))
     (should (numberp (chat-memory-item-expires-at item))))
   (should (chat-memory-auto-enabled-p))
   (chat-memory-set-automatic nil)
   (should-not (chat-memory-auto-enabled-p))))

(ert-deftest chat-memory-merge-preserves-sources-and-delete-removes-result ()
  "Merge archives inputs, records their IDs and leaves deletion explicit."
  (chat-memory-test-with-store
   (chat-memory-add "first" :id "first" :confidence 0.8)
   (chat-memory-add "second" :id "second" :confidence 0.6)
   (let* ((merged (chat-memory-merge '("first" "second") "combined"))
          (metadata (chat-memory-item-metadata merged)))
     (should (equal '("first" "second")
                    (alist-get 'mergedFrom metadata)))
     (should (= 0.6 (chat-memory-item-confidence merged)))
     (should (eq 'archived
                 (chat-memory-item-status (chat-memory-get "first"))))
     (should (chat-memory-delete (chat-memory-item-id merged)))
     (should-not (chat-memory-get (chat-memory-item-id merged))))))

(ert-deftest chat-memory-cross-scope-merge-requires-a-target ()
  "Merging unrelated scopes cannot silently inherit the first item."
  (chat-memory-test-with-store
   (chat-memory-add "global" :id "global")
   (chat-memory-add "session" :id "session"
                    :scope 'session :scope-id "s1")
   (should-error
    (chat-memory-merge '("global" "session") "ambiguous"))))

(provide 'test-chat-memory)
;;; test-chat-memory.el ends here
