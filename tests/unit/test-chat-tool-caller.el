;;; test-chat-tool-caller.el --- Tests for chat-tool-caller -*- lexical-binding: t -*-

(require 'ert)
(require 'json)
(require 'test-helper)
(require 'chat-code)
(require 'chat-tool-caller)

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

(ert-deftest chat-tool-caller-denies-unapproved-dangerous-tool ()
  "Test that dangerous tools are blocked when approval is denied."
  (chat-test-with-temp-dir
   (let* ((target-file (expand-file-name "blocked.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          captured-tool)
     (chat-files-register-built-in-tools)
     (cl-letf (((symbol-function 'chat-approval-request-tool-call)
                (lambda (tool _call &optional _session _observer)
                  (setq captured-tool (chat-forged-tool-id tool))
                  nil)))
       (let ((result (chat-tool-caller-execute
                      `(:name "files_write"
                        :arguments (("path" . ,target-file)
                                    ("content" . "blocked"))))))
         (should (eq captured-tool 'files_write))
         (should (string-match-p "Approval denied" result))
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
         (should (eq (plist-get approval :decision) 'whitelisted-directory))
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
       (setq-local chat-code--current-session
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
       (setq-local chat-code--current-session
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
       (setq-local chat-code--current-session
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
       (setq-local chat-code--current-session
                   (chat-code-session-create "Code Project" project-root nil))
       (let ((result (chat-tool-caller-execute
                      '(:name "shell_execute"
                        :arguments (("command" . "pwd"))))))
         (should (string= (string-trim result) (file-truename project-root))))))))

(ert-deftest chat-tool-caller-processes-response-without-tools ()
  "Test processing a plain response."
  (let ((result nil))
    (chat-tool-caller-process-response
     "Hello, how can I help?"
     (lambda (content tool-results)
       (setq result (list content tool-results))))
    (should (string= (nth 0 result) "Hello, how can I help?"))
    (should (null (nth 1 result)))))

(ert-deftest chat-tool-caller-process-response-data-uses-session-for-approval ()
  "Test tool execution receives the provided session context."
  (chat-test-with-temp-dir
   (let* ((target-file (expand-file-name "new.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (session (chat-session-create "Approval Session"))
          captured-session)
     (chat-files-register-built-in-tools)
     (cl-letf (((symbol-function 'chat-approval-request-tool-call)
                (lambda (_tool _call &optional maybe-session _observer)
                  (setq captured-session maybe-session)
                  t)))
       (let ((result (chat-tool-caller-process-response-data
                      (format "{\"function_call\":{\"name\":\"files_write\",\"arguments\":{\"path\":\"%s\",\"content\":\"ok\"}}}"
                              target-file)
                      session)))
         (should (eq captured-session session))
         (should (file-exists-p target-file))
         (should (= (length (plist-get result :tool-results)) 1)))))))

(ert-deftest chat-tool-caller-process-response-data-collects-tool-events ()
  "Test tool processing returns structured event data."
  (chat-test-with-temp-dir
   (let* ((source-file (expand-file-name "source.txt" temp-dir))
          (chat-files-allowed-directories (list temp-dir))
          (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (with-temp-file source-file
       (insert "hello tool"))
     (chat-files-register-built-in-tools)
     (let ((result (chat-tool-caller-process-response-data
                    (format "{\"function_call\":{\"name\":\"files_read\",\"arguments\":{\"path\":\"%s\"}}}"
                            source-file))))
       (should (= (length (plist-get result :tool-events)) 2))
       (should (eq (plist-get (car (plist-get result :tool-events)) :type) 'tool-call))
       (should (eq (plist-get (cadr (plist-get result :tool-events)) :type) 'tool-result))))))

(ert-deftest chat-tool-caller-whitelisted-shell-event-keeps-command-context ()
  "Test whitelisted shell execution reports command context."
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
          (should (eq (plist-get approval :decision) 'whitelisted-command))
          (should (equal (plist-get approval :command) "pwd")))))))

(ert-deftest chat-tool-caller-file-access-denied-suggests-code-mode ()
  "Test file access denial explains how to switch to code mode."
  (let ((chat-files-allowed-directories '("/tmp/"))
        (chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-files-register-built-in-tools)
    (let ((result (chat-tool-caller-execute
                   '(:name "files_find"
                     :arguments (("directory" . "/Users/liu/projects/demo")
                                 ("pattern" . "StickerManager"))))))
      (should (string-match-p "Access denied" result))
      (should (string-match-p "code mode" result)))))

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
      :parameters '((:name "input" :type "string" :required t))
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
                                   (cdr (assoc "function" (car decoded))))))))))

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

(ert-deftest chat-tool-forge-persists-parameter-schemas ()
  "Test forged tools reload with their parameter schema."
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
       :parameters '((:name "input" :type "string" :required t))
       :is-active t
       :usage-count 0))
     (setq chat-tool-forge--registry (make-hash-table :test 'eq))
     (chat-tool-forge-load-all)
     (should (equal (chat-forged-tool-parameters
                     (chat-tool-forge-get 'persisted_tool))
                    '((:name "input" :type "string" :required t)))))))

(provide 'test-chat-tool-caller)
;;; test-chat-tool-caller.el ends here
