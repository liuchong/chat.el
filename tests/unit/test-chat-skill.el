;;; test-chat-skill.el --- Declarative skill tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-skill)

(defmacro chat-skill-test--isolated (&rest body)
  "Run BODY with isolated skill registries."
  `(let ((chat-skill--registry (make-hash-table :test 'eq))
         (chat-skill--candidates (make-hash-table :test 'eq))
         (chat-skill--discovery-root nil)
         (chat-skill--discovered-p nil)
         (chat-skill-additional-directories nil)
         (chat-extension-trusted-project-roots nil))
     ,@body))

(defun chat-skill-test--write (path id instructions &optional version tools)
  "Write one test manifest at PATH for ID and INSTRUCTIONS."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert
     (json-encode
      `((schemaVersion . ,(or version 1))
        (id . ,id)
        (revision . "r1")
        (description . "test")
        (instructions . ,instructions)
        (tools . ,(or tools []))
        (capabilityRequirements . ((tools . t))))))))

(ert-deftest chat-skill-discovery-does-not-parse-manifest-bodies ()
  "Discovery indexes names; malformed content fails only on resolution."
  (chat-skill-test--isolated
   (chat-test-with-temp-dir
    (let* ((chat-skill-user-directory temp-dir)
           (path (expand-file-name "lazy.skill.json" temp-dir)))
      (with-temp-file path (insert "not-json"))
      (should (equal (chat-skill-list) '(lazy)))
      (should-error (chat-skill-resolve 'lazy))))))

(ert-deftest chat-skill-trusted-project-overrides-user-manifest ()
  "Trusted project skill metadata has higher precedence than user data."
  (chat-skill-test--isolated
   (chat-test-with-temp-dir
    (let* ((project (expand-file-name "project/" temp-dir))
           (user (expand-file-name "user/" temp-dir))
           (chat-skill-user-directory user)
           (chat-extension-trusted-project-roots (list project)))
      (chat-skill-test--write
       (expand-file-name "shared.skill.json" user) "shared" "user")
      (chat-skill-test--write
       (expand-file-name ".chat/skills/shared.skill.json" project)
       "shared" "project")
      (should (equal (chat-skill-instructions
                      (chat-skill-resolve 'shared project))
                     "project"))))))

(ert-deftest chat-skill-untrusted-project-is-not-visible ()
  "Project-local skills remain inert until the project is trusted."
  (chat-skill-test--isolated
   (chat-test-with-temp-dir
    (let* ((project (expand-file-name "project/" temp-dir))
           (chat-skill-user-directory
            (expand-file-name "missing-user/" temp-dir)))
      (chat-skill-test--write
       (expand-file-name ".chat/skills/local.skill.json" project)
       "local" "project")
      (should-not (memq 'local (chat-skill-list project)))
      (should-error (chat-skill-resolve 'local project))))))

(ert-deftest chat-skill-rejects-future-schema-without-evaluating-text ()
  "Future manifests fail closed and instruction text is never evaluated."
  (chat-skill-test--isolated
   (chat-test-with-temp-dir
    (let* ((chat-skill-user-directory temp-dir)
           (chat-skill-test-side-effect nil))
      (chat-skill-test--write
       (expand-file-name "future.skill.json" temp-dir)
       "future" "knowledge" 99)
      (should-error (chat-skill-resolve 'future)
                    :type 'chat-skill-unsupported-schema)
      (chat-skill-test--write
       (expand-file-name "data.skill.json" temp-dir)
       "data" "(setq chat-skill-test-side-effect t)")
      (should (string-prefix-p
               "(setq" (chat-skill-instructions
                         (chat-skill-resolve 'data))))
      (should-not chat-skill-test-side-effect)))))

(provide 'test-chat-skill)
;;; test-chat-skill.el ends here
