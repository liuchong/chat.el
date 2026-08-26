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

(ert-deftest chat-project-instructions-partition-declared-residency ()
  "Test a marked span is separated from the rest of the instructions."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "## Resident Rules <!-- chat:resident -->\n"
               "- RULE-01 never thin out rules\n"
               "## Notes\n"
               "background chatter\n"))
     (let ((parts (chat-project-instructions-partitioned b)))
       (should (string-match-p "RULE-01" (plist-get parts :resident)))
       (should-not (string-match-p "chatter" (plist-get parts :resident)))
       (should (string-match-p "chatter" (plist-get parts :compactable)))))))

(ert-deftest chat-project-instructions-cap-spares-resident-text ()
  "Test a declared span survives a size cap that the rest does not.

Truncating the merged text by character count cut whatever sat at the
end, so a long file lost its last rules silently.  A declared span has to
outrank the cap or the declaration means nothing."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir))
         (chat-project-instructions-max-chars 80))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert (make-string 500 ?r)
               "\n<!-- chat:resident -->\n"
               "RULE-01 must survive\n"
               "<!-- chat:end -->\n"))
     (let ((parts (chat-project-instructions-partitioned b))
           (text (chat-project-instructions b)))
       (should (string-match-p "RULE-01 must survive"
                               (plist-get parts :resident)))
       (should (string-match-p "project instructions truncated"
                               (plist-get parts :compactable)))
       ;; The merged form keeps it too, and puts it first.
       (should (string-match-p "RULE-01 must survive" text))
       (should (< (string-match "RULE-01 must survive" text)
                  (string-match "project instructions truncated" text)))))))

(ert-deftest chat-project-instructions-unmarked-file-behaves-as-before ()
  "Test an unmarked instructions file is unchanged by the new scheme."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "## Rules\n- one\n"))
     (let ((parts (chat-project-instructions-partitioned b)))
       (should-not (plist-get parts :resident))
       (should (string-match-p "- one" (plist-get parts :compactable)))))))

(ert-deftest chat-project-instructions-nil-without-files ()
  "Test no instructions are produced without any instruction files."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir))
         (chat-project-agents-file-names '("NO_SUCH_FILE.md")))
     (should-not (chat-project-instructions b)))))

;; ------------------------------------------------------------------
;; Caching
;; ------------------------------------------------------------------
;;
;; Instructions are read once per request.  Before caching that meant
;; reading every applicable AGENTS.md off disk and re-running the resident
;; partition over 20-30KB on every single send.

(defmacro chat-project-test--counting-reads (counter &rest body)
  "Run BODY with COUNTER incremented for each instructions file read."
  (declare (indent 1))
  `(let ((,counter 0))
     (cl-letf* ((real (symbol-function 'insert-file-contents))
                ((symbol-function 'insert-file-contents)
                 (lambda (file &rest args)
                   (when (string-match-p "AGENTS\\|global" file)
                     (setq ,counter (1+ ,counter)))
                   (apply real file args))))
       ,@body)))

(ert-deftest chat-project-a-second-ask-does-not-read-the-files-again ()
  "The files and the parse are the expensive part; the walk is not."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "root rules"))
     (chat-project-cache-clear)
     (chat-project-test--counting-reads reads
       (should (chat-project-instructions b))
       (should (= 1 reads))
       (dotimes (_ 5) (chat-project-instructions b))
       (should (= 1 reads))))))

(ert-deftest chat-project-a-changed-file-is-noticed ()
  "A cache that serves stale rules is worse than no cache."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir))
         (path (expand-file-name "AGENTS.md" root)))
     (with-temp-file path (insert "first rules"))
     (chat-project-cache-clear)
     (should (string-match-p "first rules" (chat-project-instructions b)))
     ;; A modification time the filesystem clock can distinguish, since
     ;; two writes inside one second are what this cannot see.
     (with-temp-file path (insert "second rules"))
     (set-file-times path (time-add (current-time) 2))
     (should (string-match-p "second rules"
                             (chat-project-instructions b))))))

(ert-deftest chat-project-a-file-added-further-up-is-noticed ()
  "Which is why the walk that finds the files is not itself cached."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "root rules"))
     (chat-project-cache-clear)
     (should-not (string-match-p "a rules" (chat-project-instructions b)))
     (with-temp-file (expand-file-name "AGENTS.md" a)
       (insert "a rules"))
     (should (string-match-p "a rules" (chat-project-instructions b))))))

(ert-deftest chat-project-a-removed-file-is-noticed ()
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir))
         (path (expand-file-name "AGENTS.md" a)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "root rules"))
     (with-temp-file path (insert "a rules"))
     (chat-project-cache-clear)
     (should (string-match-p "a rules" (chat-project-instructions b)))
     (delete-file path)
     (should-not (string-match-p "a rules" (chat-project-instructions b))))))

(ert-deftest chat-project-a-changed-cap-is-not-served-the-old-answer ()
  "The cap shapes the answer and leaves no trace in the file stamps."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert (make-string 500 ?r)))
     (chat-project-cache-clear)
     (let ((chat-project-instructions-max-chars 100))
       (should (string-match-p "truncated" (chat-project-instructions b))))
     (let ((chat-project-instructions-max-chars 100000))
       (should-not (string-match-p "truncated"
                                   (chat-project-instructions b)))))))

(ert-deftest chat-project-two-directories-do-not-share-an-answer ()
  "Different projects, different rules."
  (chat-project-test--with-tree
   (let ((chat-project-global-agents-file
          (expand-file-name "no-such-global.md" temp-dir)))
     (with-temp-file (expand-file-name "AGENTS.md" root)
       (insert "root rules"))
     (with-temp-file (expand-file-name "AGENTS.md" a)
       (insert "a rules"))
     (chat-project-cache-clear)
     (should-not (string-match-p "a rules" (chat-project-instructions root)))
     (should (string-match-p "a rules" (chat-project-instructions b))))))

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
                  (lambda (prompt &optional _step-limit _session)
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
