;;; test-chat-tool-caller.el --- Tests for chat-tool-caller -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
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

(ert-deftest chat-tool-caller-extracts-content-from-raw-json ()
  "Test that bare tool JSON does not leak into user-facing text."
  (should (string= (chat-tool-caller-extract-content
                    "{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}")
                   "")))

(ert-deftest chat-tool-caller-extracts-content-from-fenced-json ()
  "Test that fenced tool JSON is removed from displayed text."
  (let ((content (chat-tool-caller-extract-content
                  "Working...\n```json\n{\"function_call\":{\"name\":\"demo\",\"arguments\":{\"input\":\"hello\"}}}\n```")))
    (should (string= content "Working...\n"))))

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
      (should (string-match-p "files_patch" prompt))
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
                (lambda (tool _call)
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

(ert-deftest chat-tool-caller-processes-response-without-tools ()
  "Test processing a plain response."
  (let ((result nil))
    (chat-tool-caller-process-response
     "Hello, how can I help?"
     (lambda (content tool-results)
       (setq result (list content tool-results))))
    (should (string= (nth 0 result) "Hello, how can I help?"))
    (should (null (nth 1 result)))))

(provide 'test-chat-tool-caller)
;;; test-chat-tool-caller.el ends here
