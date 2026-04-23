;;; chat-tool-caller.el --- AI tool calling with JSON format -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: tools, llm

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module defines the JSON tool calling contract used by chat.el.
;; It builds the system prompt, parses model responses, and executes tools.

;;; Code:

(require 'cl-lib)
(require 'chat-approval)
(require 'chat-files)
(require 'chat-tool-forge)
(require 'json)
(require 'pp)
(require 'seq)
(require 'subr-x)

(chat-files-register-built-in-tools)

(defcustom chat-tool-caller-enabled t
  "Enable AI tool calling."
  :type 'boolean
  :group 'chat)

(defun chat-tool-caller--tool-available-p (tool)
  "Return non-nil when TOOL should be exposed to the model."
  (cond
   ((eq (chat-forged-tool-id tool) 'shell_execute)
    (bound-and-true-p chat-tool-shell-enabled))
   (t
    (chat-forged-tool-is-active tool))))

(defun chat-tool-caller--available-tools ()
  "Return tools that can currently be called."
  (seq-filter #'chat-tool-caller--tool-available-p
              (chat-tool-forge-list)))

(defun chat-tool-caller--tool-argument-spec (tool)
  "Return a JSON example string for TOOL arguments."
  (let ((params (chat-forged-tool-parameters tool)))
    (if (and (listp params) params)
        (concat "{"
                (mapconcat
                 (lambda (param)
                   (format "\"%s\": \"value\""
                           (plist-get param :name)))
                 params
                 ", ")
                "}")
      "{\"input\": \"value\"}")))

(defun chat-tool-caller--format-tool-line (tool)
  "Format TOOL as one line for the system prompt."
  (format "- %s: %s arguments %s"
          (chat-forged-tool-id tool)
          (or (chat-forged-tool-description tool) "No description")
          (chat-tool-caller--tool-argument-spec tool)))

(defun chat-tool-caller--tool-usage-guidance ()
  "Return human readable usage guidance for built in tools."
  (mapconcat
   #'identity
   '("Tool usage guidance:"
     "- `files_list` lists directory entries. Use it first to understand what exists."
     "- `files_find` searches recursively across a directory for files whose contents match a pattern."
     "- `files_grep` searches one known file path. Do not use it on directories."
     "- `files_read` reads a file body. Prefer `files_read_lines` when you already know the line range."
     "- `files_read_lines` reads a specific line range and is better for large files."
     "- `files_write` writes a full file body and is best for new files or deliberate whole-file rewrites."
     "- `files_replace` is for exact or regex search/replace when you can identify the current text precisely."
     "- `files_replace` should usually include `expected_count` or `line_hint` when the target may be ambiguous."
     "- `apply_patch` is for targeted multi-hunk edits to existing files using codex patch text."
     "- `files_patch` is a legacy structured search/replace tool. Prefer `apply_patch` for complex existing-file edits."
     "- `shell_execute` is only for lightweight readonly inspection when file tools are not enough."
     "- If a write tool needs approval, wait for approval instead of printing the intended file body in chat.")
   "\n"))

(defun chat-tool-caller-build-system-prompt (base-prompt)
  "Extend BASE-PROMPT with tool calling instructions."
  (if (not chat-tool-caller-enabled)
      base-prompt
    (let ((tools (chat-tool-caller--available-tools)))
      (if (null tools)
          base-prompt
        (concat
         base-prompt
         "\n\n"
         "You can call one tool per response when it is necessary.\n"
         "If a tool is needed, respond with only one JSON object and no markdown.\n"
         "After a tool runs, the system will send the tool result back to you.\n"
         "You may then either answer normally or call one more tool.\n"
         "Some tools may require user approval before execution.\n"
         "Read files before editing them.\n"
         "Use `files_write` for new files or whole-file rewrites.\n"
         "Use `files_replace` for exact text replacements with strong match constraints.\n"
         "Use `apply_patch` for precise existing-file edits across one or more hunks.\n"
         "Use files_find for recursive directory text search and use files_grep for one known file.\n"
         "After editing, inspect the result or diff before declaring success.\n"
         (chat-tool-caller--tool-usage-guidance)
         "\n"
         "Use this exact shape:\n"
         "{\"function_call\": {\"name\": \"TOOL_NAME\", \"arguments\": {\"param\": \"value\"}}}\n"
         "For `apply_patch`, pass a single string argument named `patch` using this envelope:\n"
         "*** Begin Patch\n"
         "*** Update File: path/to/file\n"
         "@@\n"
         "-old line\n"
         "+new line\n"
         "*** End Patch\n"
         "Rules:\n"
         "- Use exactly one tool name from the list below.\n"
         "- Use the exact argument names shown for that tool.\n"
         "- Do not rename keys.\n"
         "- Do not print raw file contents in chat when a write tool should be used.\n"
         "- If editing an existing file, prefer `apply_patch` or `files_replace` over `files_write`.\n"
         "- If no tool is needed, answer normally.\n"
         "Available tools:\n"
         (mapconcat #'chat-tool-caller--format-tool-line tools "\n"))))))

(defun chat-tool-caller--fix-broken-json (string)
  "Apply small compatibility fixes to STRING."
  (let ((result (string-trim string)))
    (setq result (replace-regexp-in-string "\\`json[ \t\n\r]*" "" result))
    (when (string-prefix-p "```json" result)
      (setq result (string-trim-left (string-remove-prefix "```json" result))))
    (setq result (replace-regexp-in-string "[ \t\n\r]*```\\'" "" result))
    (setq result (replace-regexp-in-string "\"_call\"" "\"function_call\"" result))
    (setq result (replace-regexp-in-string "\"_execute\"" "\"shell_execute\"" result))
    result))

(defun chat-tool-caller--decode-json (string)
  "Decode tool call JSON from STRING."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'string))
    (json-read-from-string (chat-tool-caller--fix-broken-json string))))

(defun chat-tool-caller--extract-fenced-json (content)
  "Extract JSON code blocks from CONTENT."
  (let ((blocks nil)
        (pos 0))
    (while (string-match "```json" content pos)
      (let* ((start (match-end 0))
             (end (string-match "```" content start)))
        (unless end
          (setq start nil))
        (when start
          (push (substring content start end) blocks)
          (setq pos (+ end 3)))))
    (nreverse blocks)))

(defun chat-tool-caller--extract-inline-json-fragments (content)
  "Extract balanced inline JSON object fragments from CONTENT."
  (let ((len (length content))
        (pos 0)
        (fragments nil))
    (while (< pos len)
      (let ((start (string-match "{" content pos)))
        (if (null start)
            (setq pos len)
          (let ((depth 0)
                (idx start)
                (in-string nil)
                (escaped nil)
                end)
            (while (and (< idx len) (null end))
              (let ((ch (aref content idx)))
                (cond
                 (escaped
                  (setq escaped nil))
                 ((eq ch ?\\)
                  (when in-string
                    (setq escaped t)))
                 ((eq ch ?\")
                  (setq in-string (not in-string)))
                 ((not in-string)
                  (cond
                   ((eq ch ?{)
                    (setq depth (1+ depth)))
                   ((eq ch ?})
                    (setq depth (1- depth))
                    (when (= depth 0)
                      (setq end (1+ idx))))))))
              (setq idx (1+ idx)))
            (if end
                (progn
                  (push (substring content start end) fragments)
                  (setq pos end))
              (setq pos (1+ start)))))))
    (nreverse fragments)))

(defun chat-tool-caller--tool-json-fragments (content)
  "Return parseable tool call JSON fragments found in CONTENT."
  (let (fragments)
    (dolist (candidate (append (chat-tool-caller--extract-fenced-json content)
                               (chat-tool-caller--extract-inline-json-fragments content)))
      (condition-case nil
          (when (chat-tool-caller--call-from-data
                 (chat-tool-caller--decode-json candidate))
            (push candidate fragments))
        (error nil)))
    (nreverse (delete-dups fragments))))

(defun chat-tool-caller--extract-json-candidates (content)
  "Extract candidate JSON fragments from CONTENT."
  (let ((candidates nil)
        (trimmed (string-trim content)))
    (when (and (string-prefix-p "{" trimmed)
               (string-suffix-p "}" trimmed))
      (push trimmed candidates))
    (dolist (block (chat-tool-caller--extract-fenced-json content))
      (push block candidates))
    (dolist (fragment (chat-tool-caller--extract-inline-json-fragments content))
      (push fragment candidates))
    (nreverse (delete-dups candidates))))

(defun chat-tool-caller--call-from-data (data)
  "Extract one tool call plist from decoded JSON DATA."
  (let* ((function-call (cdr (assoc "function_call" data)))
         (name (and (listp function-call)
                    (cdr (assoc "name" function-call))))
         (arguments (and (listp function-call)
                         (cdr (assoc "arguments" function-call)))))
    (when (and (stringp name) (listp arguments))
      (list :name name
            :arguments arguments))))

(defun chat-tool-caller-parse (content)
  "Parse tool calls from CONTENT."
  (let ((calls nil))
    (dolist (candidate (chat-tool-caller--extract-json-candidates content))
      (condition-case nil
          (let ((call (chat-tool-caller--call-from-data
                       (chat-tool-caller--decode-json candidate))))
            (when call
              (push call calls)))
        (error nil)))
    (nreverse (delete-dups calls))))

(defun chat-tool-caller--argument-value (arguments key)
  "Read KEY from ARGUMENTS."
  (let ((value (or (cdr (assoc key arguments))
                   (cdr (assoc (intern key) arguments)))))
    (if (eq value :json-false)
        nil
      value)))

(defun chat-tool-caller--required-argument-p (param)
  "Return non-nil when PARAM is required."
  (plist-get param :required))

(defun chat-tool-caller--missing-required-arguments (params arguments)
  "Return missing required parameter names from PARAMS and ARGUMENTS."
  (let (missing)
    (dolist (param params)
      (let ((name (plist-get param :name)))
        (when (and (chat-tool-caller--required-argument-p param)
                   (null (chat-tool-caller--argument-value arguments name)))
          (push name missing))))
    (nreverse missing)))

(defun chat-tool-caller--arguments-to-argv (tool arguments)
  "Convert TOOL ARGUMENTS alist to an argv list."
  (let ((params (chat-forged-tool-parameters tool)))
    (cond
     ((and (listp params) params)
      (let ((missing (chat-tool-caller--missing-required-arguments params arguments)))
        (when missing
          (error "Missing required arguments: %s"
                 (mapconcat #'identity missing ", ")))
        (mapcar (lambda (param)
                  (chat-tool-caller--argument-value
                   arguments
                   (plist-get param :name)))
                params)))
     ((chat-tool-caller--argument-value arguments "input")
      (list (chat-tool-caller--argument-value arguments "input")))
     (t
      (mapcar #'cdr arguments)))))

(defun chat-tool-caller--stringify-result (result)
  "Convert RESULT into a stable string."
  (cond
   ((stringp result) result)
   ((null result) "nil")
   (t
    (string-trim-right (pp-to-string result)))))

(defun chat-tool-caller--shell-whitelist-approve-p (call)
  "Check if shell command in CALL is whitelisted for auto-approval."
  (let ((arguments (plist-get call :arguments))
        (require (require 'chat-tool-shell nil t)))
    (when require
      (let ((command (cdr (assoc "command" arguments))))
        (and command
             (fboundp 'chat-tool-shell-whitelist-match-p)
             (chat-tool-shell-whitelist-match-p command))))))

(defun chat-tool-caller--code-project-root ()
  "Return the current code mode project root, when available."
  (when (and (boundp 'chat-code--current-session)
             chat-code--current-session
             (fboundp 'chat-code-session-project-root))
    (chat-code-session-project-root chat-code--current-session)))

(defun chat-tool-caller--allowed-directories ()
  "Return effective file roots for the current tool execution."
  (let ((project-root (chat-tool-caller--code-project-root)))
    (delete-dups
     (append (when project-root
               (list project-root))
             chat-files-allowed-directories))))

(defun chat-tool-caller--execution-directory ()
  "Return the working directory for the current tool execution."
  (or (chat-tool-caller--code-project-root)
      default-directory))

(defun chat-tool-caller-execute (call &optional session)
  "Execute one parsed tool CALL.
Optional SESSION is the current chat session for approval context.
If SESSION is nil, uses `chat--current-session' if bound."
  (let* ((name (plist-get call :name))
         (arguments (plist-get call :arguments))
         (tool-id (intern name))
         (tool (or (chat-tool-forge-get tool-id)
                   (when (and (eq tool-id 'shell_execute)
                              (require 'chat-tool-shell nil t))
                     (chat-tool-forge-get tool-id))))
         (actual-session (or session
                             (when (boundp 'chat--current-session)
                               chat--current-session))))
    (condition-case err
        (let ((chat-files-allowed-directories (chat-tool-caller--allowed-directories))
              (default-directory (file-name-as-directory
                                  (chat-files--resolved-path
                                   (chat-tool-caller--execution-directory)))))
          (if tool
              ;; Check shell whitelist first for shell_execute
              (if (and (eq tool-id 'shell_execute)
                       (chat-tool-caller--shell-whitelist-approve-p call))
                  ;; Whitelisted shell command: execute without approval
                  (chat-tool-caller--stringify-result
                   (chat-tool-forge-execute
                    tool-id
                    (chat-tool-caller--arguments-to-argv tool arguments)))
                ;; Normal approval flow
                (if (chat-approval-request-tool-call tool call actual-session)
                    (chat-tool-caller--stringify-result
                     (chat-tool-forge-execute
                      tool-id
                      (chat-tool-caller--arguments-to-argv tool arguments)))
                  (format "Approval denied for tool '%s'" name)))
            (format "Error: Tool '%s' not found" name)))
      (error
       (format "Error executing tool '%s': %s"
               name
               (error-message-string err))))))

(defun chat-tool-caller-extract-content (content)
  "Extract user-facing text from CONTENT."
  (let* ((trimmed (string-trim content))
         (fragments (chat-tool-caller--tool-json-fragments content)))
    (cond
     ((null fragments)
      content)
     ((and (string-prefix-p "{" trimmed)
           (string-suffix-p "}" trimmed))
      "")
     (t
      (let ((result content)
            (pos 0))
        (while (string-match "```json" result pos)
          (let ((start (match-beginning 0))
                (after-start (match-end 0))
                end)
            (setq end (string-match "```" result after-start))
            (if end
                (setq result (concat (substring result 0 start)
                                     (substring result (+ end 3))))
              (setq pos (length result)))))
        (dolist (fragment fragments)
          (setq result (replace-regexp-in-string
                        (regexp-quote fragment)
                        ""
                        result
                        t
                        t)))
        (string-trim-right result))))))

(defun chat-tool-caller-process-response-data (content &optional session)
  "Process CONTENT for SESSION and return a result plist."
  (let* ((calls (chat-tool-caller-parse content))
         (tool-results (mapcar (lambda (call)
                                 (chat-tool-caller-execute call session))
                               calls)))
    (list :content (string-trim-right (chat-tool-caller-extract-content content))
          :tool-calls calls
          :tool-results tool-results)))

(defun chat-tool-caller-process-response (content callback)
  "Process CONTENT then call CALLBACK."
  (let* ((result (chat-tool-caller-process-response-data content))
         (tool-results (plist-get result :tool-results)))
    (funcall callback
             (plist-get result :content)
             (when tool-results
               (mapconcat #'identity tool-results "\n")))))

(provide 'chat-tool-caller)
;;; chat-tool-caller.el ends here
