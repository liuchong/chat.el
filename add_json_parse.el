;;; add_json_parse.el --- Add JSON parsing support -*- lexical-binding: t -*-

(with-current-buffer (find-file-noselect "chat-tool-caller.el")
  ;; Find chat-tool-caller-parse function and replace it
  (goto-char (point-min))
  (when (search-forward "(defun chat-tool-caller-parse (content)" nil t)
    (beginning-of-line)
    (let ((start (point)))
      ;; Find the end of this function (next defun or end of section)
      (forward-sexp)
      (let ((end (point)))
        ;; Delete old function
        (delete-region start end)
        ;; Insert new functions
        (insert "
(defun chat-tool-caller-parse (content)
  \"Parse tool calls from AI response CONTENT.

Returns a list of tool call plists with :name and :arguments,
or nil if no tool calls found.
Supports both JSON code blocks and XML formats.\"
  ;; First try JSON format
  (let ((json-calls (chat-tool-caller--parse-json content)))
    (if json-calls
        json-calls
      ;; Fall back to XML format
      (chat-tool-caller--parse-xml content))))

(defun chat-tool-caller--parse-json (content)
  \"Parse JSON function calls from CONTENT in json code blocks.\"
  (let ((calls nil)
        (pos 0))
    (while (string-match \"```json\" content pos)
      (let ((block-start (match-end 0))
            (block-end (string-match \"```\" content (match-end 0))))
        (when block-end
          (let ((json-str (substring content block-start block-end)))
            (setq json-str (replace-regexp-in-string \"^\\s-+\" \"\" json-str))
            (setq json-str (replace-regexp-in-string \"\\s-+$\" \"\" json-str))
            (condition-case nil
                (let* ((data (json-read-from-string json-str))
                       (func-call (cdr (assoc 'function_call data))))
                  (when func-call
                    (let ((name (cdr (assoc 'name func-call)))
                          (args (cdr (assoc 'arguments func-call))))
                      (when name
                        (push (list :name (if (symbolp name) (symbol-name name) name)
                                    :arguments args)
                              calls))))
              (error nil))
            (setq pos block-end)))
        (setq pos (or block-end (length content)))))
    (nreverse calls)))

(defun chat-tool-caller--parse-xml (content)
  \"Parse XML tool calls from CONTENT.\"
")
        (save-buffer)
        (message "Added JSON parsing functions")))))
  (kill-buffer))

(message "Done")
