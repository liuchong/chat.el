;;; test-chat-tool-caller.el --- Tests for chat-tool-caller -*- lexical-binding: t -*-

(require 'ert)
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

(provide 'test-chat-tool-caller)
;;; test-chat-tool-caller.el ends here
