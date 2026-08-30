;;; test-chat-tool-caller.el --- Tests for chat-tool-caller -*- lexical-binding: t -*-

(require 'ert)
(require 'json)
(require 'test-helper)
(require 'chat-code)
(require 'chat-tool-caller)
;; Several tests bind `chat-tool-shell-enabled'.  Loading the module here
;; makes the variable special before that happens; otherwise the first such
;; binding is lexical and loading the module later fails outright.
(require 'chat-tool-shell)

(ert-deftest chat-tool-caller-parses-raw-json ()
  "Test parsing a bare JSON tool call."
  (let* ((response "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")
         (calls (chat-tool-caller-parse response)))
    (should (= (length calls) 1))
    (should (string= (plist-get (car calls) :name) "demo"))
    (should (equal (plist-get (car calls) :arguments)
                   '(("input" . "hello"))))))

(ert-deftest chat-tool-caller-parses-fenced-json ()
  "Test parsing a fenced JSON tool call."
  (let* ((response "```json\n{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}\n```")
         (calls (chat-tool-caller-parse response)))
    (should (= (length calls) 1))
    (should (string= (plist-get (car calls) :name) "demo"))))

(ert-deftest chat-tool-caller-a-parsed-call-arrives-with-an-id ()
  "A call read out of the reply text is persisted with its result, so it
needs the id that will pair the two in the next request.  Without one,
turns reached disk id-less and the request builder guessed twice."
  (let* ((response "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")
         (calls (chat-tool-caller-parse response)))
    (should (= (length calls) 1))
    (should (stringp (plist-get (car calls) :id)))))

(ert-deftest chat-tool-caller-two-calls-to-one-tool-get-two-ids ()
  "Ids identify a call, not a tool."
  (let* ((response (concat
                    "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"n\":1}}}\n"
                    "```json\n"
                    "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"n\":2}}}\n"
                    "```"))
         (calls (chat-tool-caller-parse response))
         (ids (mapcar (lambda (call) (plist-get call :id)) calls)))
    (should (= (length calls) 2))
    (should (= (length (delete-dups (copy-sequence ids))) 2))))

(ert-deftest chat-tool-caller-still-drops-a-call-repeated-verbatim ()
  "Ids are assigned after duplicates are dropped.

Minting them during extraction would make every call unique and quietly
turn one repeated call into two executions."
  (let* ((fragment "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")
         (response (concat fragment "\n```json\n" fragment "\n```"))
         (calls (chat-tool-caller-parse response)))
    (should (= (length calls) 1))))

(ert-deftest chat-tool-caller-normalizes-json-false-to-nil ()
  "Test JSON false values are converted to nil for tool arguments."
  (should-not (chat-tool-caller--argument-value '(("recursive" . :json-false)) "recursive")))

(ert-deftest chat-tool-caller-extracts-content-from-raw-json ()
  "Test that bare tool JSON does not leak into user-facing text."
  (should (string= (chat-tool-caller-extract-content
                    "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")
                   "")))

(ert-deftest chat-tool-caller-extracts-content-from-fenced-json ()
  "Test that fenced tool JSON is removed from displayed text."
  (let ((content (chat-tool-caller-extract-content
                  "Working...\n```json\n{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}\n```")))
    (should (string= content "Working..."))))

(ert-deftest chat-tool-caller-extracts-content-from-inline-json ()
  "Test that inline tool JSON is removed from displayed text."
  (let ((content (chat-tool-caller-extract-content
                  "先看一下目录。 {\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")))
    (should (string= content "先看一下目录。"))))

(ert-deftest chat-tool-caller-executes-tool-with-declared-parameters ()
  "Test that declared parameter names map to tool argv."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'demo-tool
       :name "Demo Tool"
       :description "Echo one argument"
       :language 'elisp
       :parameters '((:name "command" :type "string" :required t))
       :compiled-function (lambda (command) (format "ran:%s" command))
       :is-active t
       :usage-count 0))
     (let ((result (chat-tool-caller-execute
                    '(:name "demo-tool"
                      :arguments (("command" . "pwd"))))))
       (should (string= result "ran:pwd"))))))

(ert-deftest chat-tool-caller-advertises-and-executes-only-the-current-menu ()
  "Authorized tools outside the current advertisement menu stay unavailable."
  (let* ((chat-tool-forge--registry (make-hash-table :test 'eq))
         (session (make-chat-session :id "tool-menu"))
         (chat-tool-caller-current-session session)
         (hidden-runs 0))
    (dolist (spec `((visible . ,#'identity)
                    (hidden . ,(lambda () (cl-incf hidden-runs) "hidden"))))
      (chat-tool-forge-register
       (make-chat-forged-tool
        :id (car spec) :name (symbol-name (car spec)) :language 'elisp
        :compiled-function (cdr spec) :is-active t :usage-count 0)))
    (chat-session-set-tool-config
     session '(:enabled-tools (visible hidden) :advertised-tools (visible)))
    (should (equal '("visible")
                   (mapcar (lambda (definition)
                             (alist-get 'name (alist-get 'function definition)))
                           (append (chat-tool-caller-provider-tools) nil))))
    (should (string-match-p
             "unavailable for this turn"
             (chat-tool-caller-execute
              '(:name "hidden" :arguments nil) session)))
    (should (= hidden-runs 0))))

(ert-deftest chat-tool-caller-omits-only-empty-schema-descriptions ()
  "Compact schemas retain useful descriptions and omit empty placeholders."
  (let* ((tool
          (make-chat-forged-tool
           :id 'compact-schema :name "Compact Schema" :language 'elisp
           :parameters
           '((:name "plain" :type "string")
             (:name "explained" :type "integer"
              :description "A useful explanation"))
           :compiled-function #'ignore :is-active t))
         (properties (alist-get 'properties
                                (chat-tool-caller--json-schema tool)))
         (plain (alist-get "plain" properties nil nil #'string=))
         (explained (alist-get "explained" properties nil nil #'string=)))
    (should-not (assq 'description plain))
    (should (equal "A useful explanation"
                   (alist-get 'description explained)))))

(ert-deftest chat-tool-caller-rejects-mistyped-and-unknown-arguments ()
  "Test runtime validation rejects schema violations before execution."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq))
         (executions 0))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'validated-tool
       :name "Validated Tool"
       :description "Validate inputs"
       :language 'elisp
       :parameters '((:name "count" :type "integer" :required t))
       :compiled-function (lambda (_count) (cl-incf executions) "ok")
       :is-active t
       :usage-count 0))
     (should
      (string-match-p
       "must be integer"
       (chat-tool-caller-execute
        '(:name "validated-tool" :arguments (("count" . "one"))))))
     (should
      (string-match-p
       "Unknown arguments"
       (chat-tool-caller-execute
        '(:name "validated-tool"
          :arguments (("count" . 1) ("extra" . t))))))
     (should (= executions 0)))))

(ert-deftest chat-tool-caller-accepts-declared-legacy-argument-types ()
  "Provider schemas stay strict while a declared old wire shape still runs."
  (let* ((tool
          (make-chat-forged-tool
           :id 'compatible-tool :name "Compatible" :language 'elisp
           :parameters
           '((:name "evidence" :type "array" :required nil
              :items ((type . "string")) :accepted-types ("string")))
           :compiled-function #'identity :is-active t))
         (schema (chat-tool-caller--json-schema tool))
         (property (cdr (assoc "evidence"
                               (cdr (assoc 'properties schema))))))
    (should (equal (cdr (assoc 'type property)) "array"))
    (should-not (assoc 'acceptedTypes property))
    (should (equal
             (chat-tool-caller--arguments-to-argv
              tool '(("evidence" . "[\"event-one\"]")))
             '("[\"event-one\"]")))
    (should-error
     (chat-tool-caller--validate-arguments
      tool '(("evidence" . 42))))))

(ert-deftest chat-tool-caller-accepts-required-json-false ()
  "Test required booleans distinguish false from a missing argument."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'boolean-tool
       :name "Boolean Tool"
       :description "Accept false"
       :language 'elisp
       :parameters '((:name "enabled" :type "boolean" :required t))
       :compiled-function (lambda (enabled) (if enabled "true" "false"))
       :is-active t
       :usage-count 0))
     (should
      (string=
       (chat-tool-caller-execute
        '(:name "boolean-tool"
          :arguments (("enabled" . :json-false))))
       "false")))))

(ert-deftest chat-tool-caller-zero-argument-tools-reject-extra-input ()
  "Test zero-argument tools enforce additionalProperties false at runtime."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq))
         (executed nil))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'zero-tool
       :name "Zero Tool"
       :description "Accept no arguments"
       :language 'elisp
       :parameters nil
       :compiled-function (lambda () (setq executed t) "ok")
       :is-active t
       :usage-count 0))
     (should
      (string-match-p
       "Unknown arguments"
       (chat-tool-caller-execute
        '(:name "zero-tool" :arguments (("input" . "unexpected"))))))
     (should-not executed))))

(ert-deftest chat-tool-caller-builds-prompt-with-real-argument-names ()
  "Test that the system prompt advertises declared argument names."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'demo-tool
       :name "Demo Tool"
       :description "Echo one argument"
       :language 'elisp
       :parameters '((:name "command" :type "string" :required t))
       :compiled-function (lambda (_command) "ok")
       :is-active t
       :usage-count 0))
     (let ((prompt (chat-tool-caller-build-system-prompt "Base")))
       (should (string-match-p "\"command\"" prompt))
       (should (string-match-p "demo-tool" prompt))))))

(ert-deftest chat-tool-caller-hides-session-disabled-tools ()
  "Test per-session overlays filter provider-visible tools."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq))
         (chat-tool-caller-current-session
          (make-chat-session
           :id "session"
           :tool-config '(:disabled-tools (demo-tool)))))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'demo-tool
       :name "Demo Tool"
       :description "Echo one argument"
       :language 'elisp
       :parameters '((:name "command" :type "string" :required t))
       :compiled-function (lambda (_command) "ok")
       :is-active t
       :usage-count 0))
     (let ((prompt (chat-tool-caller-build-system-prompt "Base")))
       (should-not (string-match-p "demo-tool" prompt))))))

(ert-deftest chat-tool-caller-refuses-session-disabled-execution ()
  "Test per-session overlays block direct tool execution."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq))
         (session (make-chat-session
                   :id "session"
                   :tool-config '(:disabled-tools (demo-tool))))
         events)
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'demo-tool
       :name "Demo Tool"
       :description "Echo one argument"
       :language 'elisp
       :parameters '((:name "command" :type "string" :required t))
       :compiled-function (lambda (_command) "should not run")
       :is-active t
       :usage-count 0))
     (let ((result (chat-tool-caller-execute
                    '(:name "demo-tool"
                      :arguments (("command" . "pwd")))
                    session
                    (lambda (event) (push event events)))))
       (should (string-match-p "disabled for this session" result))
       (should (seq-find (lambda (event)
                           (and (eq (plist-get event :type) 'tool-error)
                                (string-match-p "disabled"
                                                (plist-get event :result-summary))))
                         events))))))

(ert-deftest chat-tool-caller-hides-disabled-shell-tool ()
  "Test that disabled shell tool is not advertised."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq))
         (chat-tool-shell-enabled nil))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'shell_execute
       :name "Shell Execute"
       :description "Run shell"
       :language 'elisp
       :parameters '((:name "command" :type "string" :required t))
       :compiled-function (lambda (_command) "ok")
       :is-active t
       :usage-count 0))
     (let ((prompt (chat-tool-caller-build-system-prompt "Base")))
       (should-not (string-match-p "shell_execute" prompt))))))

(ert-deftest chat-tool-caller-builds-prompt-with-built-in-file-tools ()
  "Test that file tools are advertised with their declared parameters."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (chat-tool-shell-enabled nil))
    (chat-files-register-built-in-tools)
    (let ((prompt (chat-tool-caller-build-system-prompt "Base")))
      (should (string-match-p "files_read" prompt))
      (should (string-match-p "files_find" prompt))
      (should (string-match-p "files_patch" prompt))
      (should (string-match-p "apply_patch" prompt))
      (should (string-match-p "Use files_find for recursive directory text search" prompt))
      (should (string-match-p "`files_grep` searches one known file path" prompt))
      (should (string-match-p "Read files before editing" prompt))
      (should (string-match-p "\"path\"" prompt)))))

(ert-deftest chat-tool-caller-asks-for-markdown-in-the-system-prompt ()
  "The answer format is stated, not left to the model's habit.

Every model writes Markdown by habit, and the renderer was built around
that habit, so leaving it unsaid makes the display depend on something
nobody asked for."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (chat-tool-shell-enabled nil)
        (chat-language 'en))
    (let ((prompt (chat-tool-caller-build-system-prompt "Base")))
      (should (string-match-p "Markdown" prompt)))))

(ert-deftest chat-tool-caller-narrows-markdown-to-what-renders-well ()
  "Each restriction in the subset is present, and each carries its reason.

A prompt rule without a reason reads as optional."
  (let ((chat-language 'en))
    (let ((note (chat-tool-caller--output-format-note)))
      ;; The restrictions.
      (should (string-match-p "ATX" note))
      (should (string-match-p "level two" note))
      (should (string-match-p "hard-wrap" note))
      (should (string-match-p "names its language" note))
      (should (string-match-p "literal code or source" note))
      (should (string-match-p "rendering demonstration" note))
      (should (string-match-p "two levels" note))
      (should (string-match-p "four\n?[ ]*columns" note))
      (should (string-match-p "Inline code" note))
      (should (string-match-p "No HTML" note))
      (should (string-match-p "LaTeX" note))
      ;; The reasons, which are what stop a rule reading as optional.
      (should (string-match-p "wrapped to the window" note))
      (should (string-match-p "selects syntax highlighting" note))
      (should (string-match-p "shown as source" note))
      (should (string-match-p "does not fit a window" note))
      (should (string-match-p "not rendered\\|none of these" note)))))

(ert-deftest chat-tool-caller-states-the-format-whether-or-not-tools-exist ()
  "Format is about how to answer, so it does not depend on having tools."
  (let ((chat-language 'en))
    (let ((without (let ((chat-tool-caller-enabled nil))
                     (chat-tool-caller-build-system-prompt "Base")))
          (with (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
                      (chat-tool-shell-enabled nil))
                  (chat-files-register-built-in-tools)
                  (chat-tool-caller-build-system-prompt "Base"))))
      (should (string-match-p "Markdown" without))
      (should (string-match-p "Markdown" with)))))

(ert-deftest chat-tool-caller-denies-unapproved-dangerous-tool ()
  "A denied tool does not run, and the assistant is told enough to move on.

The text says the policy refused rather than the user, and names the ways
forward.  Both matter for what happens next: a person refusing means stop
and wait, a policy refusing means this route is closed and another may be
open -- and a bare \"denied\" is what sent a run round the same call for
eight minutes."
  (chat-test-with-temp-dir
   (let* ((target-file (expand-file-name "blocked.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          captured-tool)
     (chat-files-register-built-in-tools)
     (cl-letf (((symbol-function 'chat-approval-authorize)
                (lambda (tool _call &optional _session _observer)
                  (setq captured-tool (chat-forged-tool-id tool))
                  nil)))
       (let ((result (chat-tool-caller-execute
                      `(:name "files_write"
                        :arguments (("path" . ,target-file)
                                    ("content" . "blocked"))))))
         (should (eq captured-tool 'files_write))
         (should (string-match-p "Denied" result))
         (should (string-match-p "not the user declining" result))
         (should (string-match-p "different approach" result))
         ;; And it does not tell the assistant to halt: a policy denial is
         ;; usually worth working around.
         (should-not (string-match-p "STOP" result))
         (should-not (file-exists-p target-file)))))))

(ert-deftest chat-tool-caller-directory-whitelist-auto-approves-file-write ()
  "Test directory whitelists let file writes execute without a fresh prompt."
  (chat-test-with-temp-dir
   (let* ((target-file (expand-file-name "docs/guide.md" temp-dir))
          (target-dir (chat-approval--normalize-directory
                       (file-name-directory target-file)))
          (chat-files-allowed-directories (list temp-dir))
          (chat-approval-always-approve-directories (list target-dir))
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (chat-approval-decision-function
           (lambda (&rest _args)
             (ert-fail "directory whitelist should bypass approval prompt")))
          events)
     (chat-files-register-built-in-tools)
     (let ((result (chat-tool-caller-execute
                    `(:name "files_write"
                      :arguments (("path" . ,target-file)
                                  ("content" . "hello docs")))
                    nil
                    (lambda (event)
                      (push event events)))))
       (should (string-match-p "hello docs" (with-temp-buffer
                                              (insert-file-contents target-file)
                                              (buffer-string))))
       (should (string-match-p ":path" result))
       (let ((approval (seq-find (lambda (event)
                                   (eq (plist-get event :type) 'approval))
                                 events)))
         (should (eq (plist-get approval :decision) 'granted))
         (should (eq (plist-get approval :scope) 'directory))
         (should (equal (plist-get approval :directory) target-dir)))))))

(ert-deftest chat-tool-caller-stringifies-built-in-file-results ()
  "Test that file tool results are converted to strings for follow up prompts."
  (chat-test-with-temp-dir
   (let* ((source-file (expand-file-name "source.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (with-temp-file source-file
       (insert "hello tool"))
     (chat-files-register-built-in-tools)
     (let ((result (chat-tool-caller-execute
                    `(:name "files_read"
                      :arguments (("path" . ,source-file))))))
       (should (stringp result))
       (should (string-match-p "hello tool" result))
       (should (string-match-p ":content" result))))))

(ert-deftest chat-tool-caller-allows-code-project-root-for-file-tools ()
  "Test file tools can access the active code session project root."
  (chat-test-with-temp-dir
   (let* ((project-root (expand-file-name "project" temp-dir))
          (target-file (expand-file-name "README.md" project-root))
          (chat-files-allowed-directories (list "/tmp/"))
          (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (make-directory project-root t)
     (with-temp-file target-file
       (insert "project read ok"))
     (chat-files-register-built-in-tools)
     (with-temp-buffer
       (setq-local chat--current-session
                   (chat-code-session-create "Code Project" project-root nil))
       (let ((result (chat-tool-caller-execute
                      `(:name "files_read"
                        :arguments (("path" . ,target-file))))))
         (should (string-match-p "project read ok" result)))))))

(ert-deftest chat-tool-caller-open-file-opens-buffer-at-line ()
  "Test open_file opens a safe file and moves point to the requested line."
  (chat-test-with-temp-dir
   (let* ((project-root (expand-file-name "project" temp-dir))
          (target-file (expand-file-name "README.md" project-root))
          (chat-files-allowed-directories (list "/tmp/"))
          opened-buffer)
     (make-directory project-root t)
     (with-temp-file target-file
       (insert "line1\nline2\nline3\n"))
     (chat-files-register-built-in-tools)
     (with-temp-buffer
       (setq-local chat--current-session
                   (chat-code-session-create "Code Project" project-root nil))
       (cl-letf (((symbol-function 'pop-to-buffer)
                  (lambda (buffer &rest _args)
                    (setq opened-buffer buffer)
                    buffer)))
         (let ((result
                (chat-tool-caller-execute
                 `(:name "open_file"
                   :arguments (("path" . ,target-file)
                               ("line" . 3))))))
           (should (stringp result))
           (should (string-match-p "opened" result))
           (should (buffer-live-p opened-buffer))
           (with-current-buffer opened-buffer
             (should (string= (file-truename (buffer-file-name))
                              (file-truename target-file)))
             (should (= (line-number-at-pos) 3)))))))))

(ert-deftest chat-tool-caller-open-file-denies-outside-paths ()
  "Test open_file obeys file safety boundaries."
  (chat-test-with-temp-dir
   (let* ((project-root (expand-file-name "project" temp-dir))
          (outside-file (expand-file-name "secret.txt" temp-dir))
          (chat-files-allowed-directories (list "/tmp/")))
     (make-directory project-root t)
     (with-temp-file outside-file
       (insert "secret"))
     (chat-files-register-built-in-tools)
     (with-temp-buffer
       (setq-local chat--current-session
                   (chat-code-session-create "Code Project" project-root nil))
       (let ((result
              (chat-tool-caller-execute
               `(:name "open_file"
                 :arguments (("path" . ,outside-file))))))
         (should (string-match-p "Access denied\\|outside allowed directories\\|Error executing tool" result)))))))

(ert-deftest chat-tool-caller-uses-project-root-as-shell-working-directory ()
  "Test shell tools execute from the active code session project root."
  (chat-test-with-temp-dir
   (let* ((project-root (expand-file-name "project" temp-dir))
          (chat-files-allowed-directories (list "/tmp/"))
          (chat-tool-shell-enabled t))
     (make-directory project-root t)
     (with-temp-buffer
       (setq-local chat--current-session
                   (chat-code-session-create "Code Project" project-root nil))
       (let ((result (chat-tool-caller-execute
                      '(:name "shell_execute"
                        :arguments (("command" . "pwd"))))))
         (should (string= (string-trim result) (file-truename project-root))))))))

(ert-deftest chat-tool-caller-plain-session-grants-no-project-root ()
  "A session without code capability widens nothing.

The project root used to be read from a variable only a code buffer
bound, so the check was \"is this a code buffer\".  Now every session is
in the same variable and the check has to be the capability itself."
  (chat-test-with-temp-dir
   (let* ((project-root (expand-file-name "project" temp-dir))
          (chat-files-allowed-directories (list "/tmp/"))
          (chat-session-auto-save nil))
     (make-directory project-root t)
     (with-temp-buffer
       ;; Code capability off, but the session does carry a root, so a
       ;; check that ignored the capability would still find it.
       (setq-local chat--current-session
                   (chat-session-create "Plain" 'kimi))
       (chat-session-metadata-set chat--current-session
                                  'project-root project-root)
       (should-not (chat-tool-caller--code-project-root))
       (should-not (member project-root
                           (chat-tool-caller--allowed-directories))))
     (with-temp-buffer
       (setq-local chat--current-session
                   (chat-code-session-create "Code" project-root nil))
       (should (equal (chat-tool-caller--code-project-root) project-root))
       (should (equal (chat-tool-caller--code-project-root
                       chat--current-session)
                      project-root))
       (should (member project-root
                       (chat-tool-caller--allowed-directories)))))))

(ert-deftest chat-tool-caller-uses-session-working-directory-for-shell ()
  "Test shell tools follow the working directory chosen for the session."
  (chat-test-with-temp-dir
   (let* ((session-dir (expand-file-name "chosen" temp-dir))
          (chat-files-allowed-directories (list "/tmp/"))
          (chat-session-auto-save nil)
          (chat-tool-shell-enabled t)
          (session (chat-session-create "Cwd Session" 'kimi)))
     (make-directory session-dir t)
     (chat-session-set-working-directory session session-dir)
     (let ((result (chat-tool-caller-execute
                    '(:name "shell_execute"
                      :arguments (("command" . "pwd")))
                    session)))
       (should (string= (string-trim result) (file-truename session-dir)))))))

(ert-deftest chat-tool-caller-session-directory-outranks-project-root ()
  "Test an explicit session directory wins over the detected project root."
  (chat-test-with-temp-dir
   (let* ((project-root (expand-file-name "project" temp-dir))
          (session-dir (expand-file-name "chosen" temp-dir))
          (chat-files-allowed-directories (list "/tmp/"))
          (chat-session-auto-save nil)
          (chat-tool-shell-enabled t)
          (session (chat-session-create "Cwd Session" 'kimi)))
     (make-directory project-root t)
     (make-directory session-dir t)
     (chat-session-set-working-directory session session-dir)
     (with-temp-buffer
       (setq-local chat--current-session
                   (chat-code-session-create "Code Project" project-root nil))
       (let ((result (chat-tool-caller-execute
                      '(:name "shell_execute"
                        :arguments (("command" . "pwd")))
                      session)))
         (should (string= (string-trim result) (file-truename session-dir))))))))

(ert-deftest chat-tool-caller-processes-response-without-tools ()
  "Test processing a plain response."
  (let ((result nil))
    (chat-tool-caller-process-response
     "Hello, how can I help?"
     (lambda (content tool-results)
       (setq result (list content tool-results))))
    (should (string= (nth 0 result) "Hello, how can I help?"))
    (should (null (nth 1 result)))))

(ert-deftest chat-tool-caller-process-response-data-parses-without-executing ()
  "This function reports what the model asked for; it does not run it.

It used to hold a loop that executed each parsed call, reachable from no
caller -- the agent loop calls this only where there are no calls -- and
authorizing nothing on the way.  A route to execution that skips approval
and has no caller to keep it honest is the next hole, not dead code, so
the loop is gone and this pins that down."
  (chat-test-with-temp-dir
   (let* ((target-file (expand-file-name "new.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (session (chat-session-create "Approval Session"))
          (asked nil))
     (chat-files-register-built-in-tools)
     (cl-letf (((symbol-function 'chat-approval-authorize)
                (lambda (&rest _args) (setq asked t) 'human)))
       (let ((result (chat-tool-caller-process-response-data
                      (format "{\"function_call\":{\"name\":\"files_write\",\"arguments\":{\"path\":\"%s\",\"content\":\"ok\"}}}"
                              target-file)
                      session)))
         (should (= (length (plist-get result :tool-calls)) 1))
         (should (equal (plist-get (car (plist-get result :tool-calls)) :name)
                        "files_write"))
         (should-not (plist-get result :tool-results))
         (should-not (plist-get result :tool-events))
         (should-not asked)
         (should-not (file-exists-p target-file)))))))

(ert-deftest chat-tool-caller-process-response-data-keeps-the-call-ids ()
  "Parsed calls are persisted beside their results and paired by id.

A text-shaped call carries no id of its own, so one is minted here.  It
has to survive this function, because the result stored against it is
matched back by that id on the next request."
  (let ((result (chat-tool-caller-process-response-data
                 "Thinking about it.\n{\"function_call\":{\"name\":\"files_read\",\"arguments\":{\"path\":\"/tmp/x\"}}}")))
    (should (equal (plist-get result :content) "Thinking about it."))
    (let ((call (car (plist-get result :tool-calls))))
      (should (equal (plist-get call :name) "files_read"))
      (should (stringp (plist-get call :id)))
      (should-not (string-empty-p (plist-get call :id))))
    (should-not (plist-get result :parse-error))))

(ert-deftest chat-tool-caller-whitelisted-shell-event-keeps-command-context ()
  "Test whitelisted shell execution reports command context."
  (chat-test-with-grants
   (let ((chat-tool-shell-enabled t)
         (chat-tool-shell-whitelist '("pwd"))
         (events nil))
     (with-temp-buffer
       (let ((result
              (chat-tool-caller-execute
               '(:name "shell_execute"
                 :arguments (("command" . "pwd")))
               nil
               (lambda (event)
                 (push event events)))))
         (should (stringp result))
         (let ((approval (seq-find (lambda (event)
                                     (eq (plist-get event :type) 'approval))
                                   events)))
           ;; One decision covers every tool now, so the event says
           ;; `granted' and names the source rather than carrying a
           ;; shell-specific label from the path that only shell took.
           (should (eq (plist-get approval :decision) 'granted))
           (should (eq (plist-get approval :source) 'user))
           (should (equal (plist-get approval :command) "pwd"))))))))

(ert-deftest chat-tool-caller-file-access-denied-names-a-way-forward ()
  "A refusal has to say what to do about it, by naming a command that
exists.  This hint used to advise switching to `code mode', which stopped
being a thing the reader could do when the two surfaces merged."
  (let ((chat-files-allowed-directories '("/tmp/"))
        (chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-files-register-built-in-tools)
    (let ((result (chat-tool-caller-execute
                   '(:name "files_find"
                     :arguments (("directory" . "/Users/liu/projects/demo")
                                 ("pattern" . "StickerManager"))))))
      (should (string-match-p "Access denied" result))
      (should (string-match-p "chat-code-start" result))
      (should (string-match-p "chat-code-from-chat" result))
      (should (commandp 'chat-code-start))
      (should (commandp 'chat-code-from-chat)))))

(ert-deftest chat-tool-caller-unclosed-fence-does-not-hang ()
  "Test that an unclosed ```json fence terminates instead of looping forever."
  (let ((response "```json\n{\"function_call\":{\"name\":\"demo\",\"arguments\":{"))
    (should (null (chat-tool-caller--extract-fenced-json response)))
    (should (null (chat-tool-caller-parse response)))))

(ert-deftest chat-tool-caller-unclosed-fence-keeps-earlier-blocks ()
  "Test that complete blocks before an unclosed fence are still extracted."
  (let* ((response (concat "```json\n{\"function_call\":{\"name\":\"demo\",\"arguments\":{}}}\n```\n"
                           "```json\n{\"function_call\":{\"name\":\"broken\""))
         (calls (chat-tool-caller-parse response)))
    (should (= (length calls) 1))
    (should (string= (plist-get (car calls) :name) "demo"))))

(ert-deftest chat-tool-caller-detects-failed-tool-call-attempt ()
  "Test that broken function_call content is flagged as a parse error."
  (should (chat-tool-caller--attempted-tool-call-p
           "```json\n{\"function_call\":{\"name\":\"demo\""))
  (should (chat-tool-caller--attempted-tool-call-p
           "{\"_call\":{\"name\":\"demo\"}"))
  (should-not (chat-tool-caller--attempted-tool-call-p "Just a normal answer."))
  (should-not (chat-tool-caller--attempted-tool-call-p
               "Example JSON: ```json\n{\"a\":1}\n```")))

(ert-deftest chat-tool-caller-process-response-flags-parse-error ()
  "Test that process-response-data reports parse errors for failed attempts."
  (let ((broken (chat-tool-caller-process-response-data
                 "```json\n{\"function_call\":{\"name\":\"demo\",\"arguments\":{"))
        (plain (chat-tool-caller-process-response-data "All done."))
        (valid (chat-tool-caller-process-response-data
                "{\"function_call\":{\"name\":\"demo\",\"arguments\":{}}}")))
    (should (plist-get broken :parse-error))
    (should-not (plist-get plain :parse-error))
    (should-not (plist-get valid :parse-error))))

(ert-deftest chat-tool-caller-provider-tools-are-json-objects ()
  "Test provider tool schemas encode as JSON objects, not arrays."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'demo-tool
      :name "Demo Tool"
      :description "Echo one argument"
      :language 'elisp
      :parameters '((:name "input" :type "string"
                     :enum ("one" "two") :required t))
      :compiled-function (lambda (input) input)
      :is-active t
      :usage-count 0))
    (let* ((tools (chat-tool-caller-provider-tools))
           (encoded (json-encode tools))
           (decoded (let ((json-object-type 'alist)
                          (json-array-type 'list)
                          (json-key-type 'string))
                      (json-read-from-string encoded))))
      (should (arrayp tools))
      (should (string-match-p "\"demo-tool\"" encoded))
      (should (string-match-p "\"type\":\"function\"" encoded))
      (should (stringp (cdr (assoc "name"
                                   (cdr (assoc "function" (car decoded)))))))
      (let* ((definition (aref tools 0))
             (schema (cdr (assoc 'parameters
                                 (cdr (assoc 'function definition)))))
             (property (cdr (assoc "input"
                                   (cdr (assoc 'properties schema))))))
        (should (equal (cdr (assoc 'enum property))
                       ["one" "two"]))))))

(ert-deftest chat-tool-caller-files-patch-schema-describes-object-items ()
  "The provider sees the nested patch contract instead of an untyped array."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-files-register-built-in-tools)
    (let* ((tools (chat-tool-caller-provider-tools))
           (definition
            (seq-find
             (lambda (item)
               (string= (cdr (assoc 'name (cdr (assoc 'function item))))
                        "files_patch"))
             (append tools nil)))
           (schema (cdr (assoc 'parameters
                               (cdr (assoc 'function definition)))))
           (patches (cdr (assoc "patches" (cdr (assoc 'properties schema)))))
           (items (cdr (assoc 'items patches)))
           (item-properties (cdr (assoc 'properties items))))
      (should (equal (cdr (assoc 'type items)) "object"))
      (should (equal (cdr (assoc 'minItems patches)) 1))
      (should (assoc "search" item-properties))
      (should (assoc "replace" item-properties))
      (should (eq (cdr (assoc 'additionalProperties items)) :json-false)))))

(ert-deftest chat-tool-caller-executes-files-patch-with-kimi-json-shape ()
  "A JSON array of patch objects remains an array through tool execution."
  (chat-test-with-temp-dir
   (let* ((path (expand-file-name "target.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (chat-approval-always-approve-directories
           (list (chat-approval--normalize-directory temp-dir)))
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (arguments
           (let ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'string))
             (json-read-from-string
              (format
               "{\"path\":%s,\"patches\":[{\"search\":\"alpha\",\"replace\":\"beta\"}]}"
               (json-encode-string path))))))
     (with-temp-file path (insert "alpha\n"))
     (chat-files-register-built-in-tools)
     (chat-files-read path)
     (let ((result
            (chat-tool-caller-execute
             (list :name "files_patch" :arguments arguments))))
       (should (string-match-p ":status success" result))
       (should (string= (with-temp-buffer
                          (insert-file-contents path)
                          (buffer-string))
                        "beta\n"))))))

(ert-deftest chat-tool-caller-zero-arg-provider-schema-is-empty-object ()
  "Test zero-argument tools use an empty object schema."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'no_arg_tool
      :name "No Arg Tool"
      :description "Needs no arguments"
      :language 'elisp
      :compiled-function (lambda (&rest _) "ok")
      :is-active t
      :usage-count 0))
    (let* ((tools (chat-tool-caller-provider-tools))
           (schema (cdr (assoc 'parameters
                               (cdr (assoc 'function (aref tools 0))))))
           (encoded (json-encode schema)))
      (should (string-match-p "\"properties\":{}" encoded))
      (should (string-match-p "\"required\":\\[\\]" encoded))
      (should-not (string-match-p "input" encoded)))))

(ert-deftest chat-tool-forge-persists-schema-and-permission-metadata ()
  "Test forged tools reload with schema and permission metadata."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'persisted_tool
       :name "Persisted Tool"
       :description "Echo one argument"
       :language 'elisp
       :source-code "(lambda (input) input)"
       :parameters '((:name "input" :type "string"
                      :enum ("one" "two") :accepted-types ("integer")
                      :required t))
       :owner 'persisted-owner
       :sensitivity 'personal
       :effects '(read outbound)
       :is-active t
       :usage-count 0))
     (setq chat-tool-forge--registry (make-hash-table :test 'eq))
     (chat-tool-forge-load-all)
     (let ((tool (chat-tool-forge-get 'persisted_tool)))
       (should
        (equal (chat-forged-tool-parameters tool)
               '((:name "input" :type "string"
                  :enum ("one" "two") :accepted-types ("integer")
                  :required t))))
       (should (eq (chat-forged-tool-owner tool) 'persisted-owner))
       (should (eq (chat-forged-tool-sensitivity tool) 'personal))
       (should (equal (chat-forged-tool-effects tool)
                      '(read outbound)))))))

(ert-deftest chat-tool-caller-validates-nested-array-object-schema ()
  "Nested provider schemas fail locally with the exact invalid item path."
  (let ((tool
         (make-chat-forged-tool
          :id 'nested-tool :name "Nested" :language 'elisp
          :parameters
          '((:name "items" :type "array" :required t :min-items 1
             :items ((type . "object")
                     (properties
                      . (("title" . ((type . "string")))
                         ("acceptance" . ((type . "string")))))
                     (required . ["title" "acceptance"])
                     (additionalProperties . :json-false))))
          :compiled-function #'identity :is-active t)))
    (condition-case err
        (progn
          (chat-tool-caller--validate-arguments
           tool '(("items" . ((("title" . "Implement"))))))
          (ert-fail "Expected missing nested acceptance field"))
      (error
       (should (string-match-p
                "items\\[0\\]\\.acceptance"
                (error-message-string err)))))))

(ert-deftest chat-tool-caller-distinguishes-work-plan-from-plan-mode ()
  "The system prompt keeps TODO planning separate from read-only Plan Mode."
  (let ((tools
         (list
          (make-chat-forged-tool
           :id 'programming_plan_create :name "Plan" :language 'elisp
           :is-active t))))
    (let ((guidance (chat-tool-caller--plan-usage-guidance tools)))
      (should (string-match-p "durable TODO list" guidance))
      (should (string-match-p "Never batch dependent transitions" guidance))
      (should (string-match-p "returned revision" guidance))
      (should (string-match-p "Do not enter Plan Mode" guidance))
      (should (string-match-p "explicitly asks" guidance)))))

(ert-deftest chat-tool-caller-restores-execution-context-after-async-approval ()
  "A delayed guard verdict keeps the task correlation of the original call."
  (chat-test-with-temp-dir
   (let* ((chat-tool-forge--registry (make-hash-table :test 'eq))
         (read-set (make-hash-table :test 'equal))
         (context (list :session-id "session-1" :turn-id 7
                        :task-id "task-2" :read-set read-set))
         decision
         observed
         observed-read-set
         observed-enforcement
         observed-observation-context
         result)
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'context-tool
       :name "Context Tool"
       :description "Observe execution context"
       :language 'elisp
       :parameters nil
       :compiled-function
       (lambda ()
         (setq observed chat-execution-current-context)
         (setq observed-read-set chat-files-current-read-set)
         (setq observed-enforcement chat-files-enforce-read-set)
         (setq observed-observation-context
               chat-files-current-observation-context)
         "ok")
       :is-active t
       :usage-count 0))
     (cl-letf (((symbol-function 'chat-approval-authorize-async)
                (lambda (_tool _call _session _observer callback)
                  (setq decision callback)
                  'pending-approval)))
       (chat-tool-caller-execute-async
        '(:name "context-tool" :arguments nil)
        nil #'ignore
        (lambda (value) (setq result value))
        #'ert-fail
        context))
     (should decision)
     (funcall decision t 'guard)
     (should (equal observed context))
     (should (eq observed-read-set read-set))
     (should observed-enforcement)
     (should (equal observed-observation-context context))
     (should (string= result "ok")))))

(ert-deftest chat-tool-caller-publishes-typed-file-consistency-errors ()
  "File consistency failures retain a stable type in observer events."
  (let* ((chat-tool-forge--registry (make-hash-table :test 'eq))
         events
         (tool
          (make-chat-forged-tool
           :id 'stale-tool
           :name "Stale Tool"
           :description "Signal a stale file"
           :language 'elisp
           :parameters nil
           :compiled-function
           (lambda ()
             (signal 'chat-files-stale-file '("stale-file: demo.txt")))
           :is-active t
           :usage-count 0)))
    (chat-tool-forge-register tool)
    (let ((result
           (chat-tool-caller--execute-authorized
            tool '(:name "stale-tool" :arguments nil) nil
            (lambda (event) (push event events)) t)))
      (should (string-match-p "stale-file" result))
      (should (eq (plist-get (car events) :type) 'tool-error))
      (should (eq (plist-get (car events) :error-type) 'stale-file)))))

(provide 'test-chat-tool-caller)
;;; test-chat-tool-caller.el ends here
