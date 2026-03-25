;;; chat-tool-caller.el --- AI tool calling with JSON format -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tools, llm

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module defines the JSON tool calling contract used by chat.el.
;; It builds the system prompt, parses model responses, and executes tools.

;;; Code:

(require 'cl-lib)
(require 'chat-tool-forge)
(require 'json)
(require 'seq)
(require 'subr-x)

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
         "You can call one tool when it is necessary.\n"
         "If a tool is needed, respond with only one JSON object and no markdown.\n"
         "Use this exact shape:\n"
         "{\"function_call\": {\"name\": \"TOOL_NAME\", \"arguments\": {\"param\": \"value\"}}}\n"
         "Rules:\n"
         "- Use exactly one tool name from the list below.\n"
         "- Use the exact argument names shown for that tool.\n"
         "- Do not rename keys.\n"
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

(defun chat-tool-caller--extract-json-candidates (content)
  "Extract candidate JSON fragments from CONTENT."
  (let ((candidates nil)
        (trimmed (string-trim content)))
    (when (and (string-prefix-p "{" trimmed)
               (string-suffix-p "}" trimmed))
      (push trimmed candidates))
    (dolist (block (chat-tool-caller--extract-fenced-json content))
      (push block candidates))
    (when (string-match "{.*}" content)
      (push (match-string 0 content) candidates))
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
  (or (cdr (assoc key arguments))
      (cdr (assoc (intern key) arguments))))

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

(defun chat-tool-caller-execute (call)
  "Execute one parsed tool CALL."
  (let* ((name (plist-get call :name))
         (arguments (plist-get call :arguments))
         (tool-id (intern name))
         (tool (chat-tool-forge-get tool-id)))
    (condition-case err
        (if tool
            (chat-tool-forge-execute
             tool-id
             (chat-tool-caller--arguments-to-argv tool arguments))
          (format "Error: Tool '%s' not found" name))
      (error
       (format "Error executing tool '%s': %s"
               name
               (error-message-string err))))))

(defun chat-tool-caller-extract-content (content)
  "Extract user-facing text from CONTENT."
  (let ((trimmed (string-trim content)))
    (cond
     ((null (chat-tool-caller-parse content))
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
        result)))))

(defun chat-tool-caller-process-response-data (content)
  "Process CONTENT and return a result plist."
  (let* ((calls (chat-tool-caller-parse content))
         (tool-results (mapcar #'chat-tool-caller-execute calls)))
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
