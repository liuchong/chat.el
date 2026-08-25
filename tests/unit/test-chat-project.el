;;; test-chat-project.el --- Tests for chat-project -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-project)

(defmacro chat-project-test--with-tree (&rest body)
  "Create a nested project tree and run BODY with root/a/b bound."
  `(chat-test-with-temp-dir
    (let* ((root (file-truename temp-dir))
           (a (expand-file-name "a" root))
           (b (expand-file-name "a/b" root)))
      (make-directory b t)
      ,@body)))

(ert-deftest chat-project-collects-ancestors-root-first ()
  "Test AGENTS.md files are collected from the root down, root first."
  (chat-project-test--with-tree
   (with-temp-file (expand-file-name "AGENTS.md" root)
     (insert "root rules"))
   (with-temp-file (expand-file-name "AGENTS.md" a)
     (insert "a rules"))
   (let* ((all (chat-project-collect-agents-files b))
          (local (seq-filter (lambda (f) (string-prefix-p root f)) all)))
     (should (= (length local) 2))
     (should (string-suffix-p "a/AGENTS.md" (nth 1 local))))))

(ert-deftest chat-project-instructions-merge-with-source-annotations ()
  "Test merged instructions carry per file source annotations."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "root rules"))
     (with-temp-file (expand-file-name "AGENTS.md" a)
       (insert "a rules"))
     (let ((text (chat-project-instructions b)))
       (should (string-match-p "Project instructions from" text))
       (should (string-match-p "root rules" text))
       (should (string-match-p "a rules" text))
       ;; root content comes before the deeper file content
       (should (< (string-match "root rules" text)
                  (string-match "a rules" text)))))))

(ert-deftest chat-project-instructions-includes-global-file-first ()
  "Test the global instructions file precedes local ones."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "global.md" temp-dir)))
     (with-temp-file chat-project-global-agents-file
       (insert "global rules"))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "root rules"))
     (let ((text (chat-project-instructions b)))
       (should (< (string-match "global rules" text)
                  (string-match "root rules" text)))))))

(ert-deftest chat-project-instructions-capped-with-marker ()
  "Test oversized merged instructions are truncated with a marker."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir))
         (chat-project-instructions-max-chars 100))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert (make-string 500 ?r)))
     (let ((text (chat-project-instructions b)))
       (should (string-match-p "project instructions truncated" text))))))

(ert-deftest chat-project-instructions-nil-without-files ()
  "Test no instructions are produced without any instruction files."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir))
         (chat-project-agents-file-names '("NO_SUCH_FILE.md")))
     (should-not (chat-project-instructions b)))))

(ert-deftest chat-ui-prepare-messages-includes-project-instructions ()
  "Test plain chat injects project instructions into the system prompt."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "plain chat rules"))
     (let ((default-directory b)
           captured-prompt)
       (cl-letf (((symbol-function 'chat-tool-caller-build-system-prompt)
                  (lambda (prompt &optional _step-limit)
                    (setq captured-prompt prompt)
                    prompt)))
         (chat-ui--prepare-messages-with-tools nil))
       (should (string-match-p "plain chat rules" captured-prompt))))))

(ert-deftest chat-context-code-optimize-terminates-without-removable-sources ()
  "Test the context optimizer stops when nothing can be removed."
  (let ((context (make-chat-code-context
                  :files nil
                  :sources nil
                  :symbols nil
                  :total-tokens 100
                  :budget 10)))
    (chat-context-code--optimize context)
    (should (= (chat-code-context-total-tokens context) 10))))

(provide 'test-chat-project)
;;; test-chat-project.el ends here
