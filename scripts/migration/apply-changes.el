(with-current-buffer
    (find-file-noselect
     (expand-file-name "../../lisp/tools/chat-tool-caller.el"
                       (file-name-directory load-file-name)))
  (let ((new-parse-function "(defun chat-tool-caller-parse (content)
  \"Parse tool calls from AI response CONTENT.

Returns a list of tool call plists with :name and :arguments,
or nil if no tool calls found.
Expects JSON format in ```json code blocks.\"
  (let ((calls nil)
        (pos 0))
    (while (string-match \"```json\" content pos)
      (let ((block-start (match-end 0))
            (block-end (string-match \"```\" content (match-end 0))))
        (when block-end
          (let ((json-str (substring content block-start block-end)))
            (setq json-str (replace-regexp-in-string \"^\\\\s-+\" \"\" json-str))
            (setq json-str (replace-regexp-in-string \"\\\\s-+$\" \"\" json-str))
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
    (nreverse calls)))"))
    
    ;; Replace the parse function
    (goto-char (point-min))
    (when (search-forward "(defun chat-tool-caller-parse (content)" nil t)
      (beginning-of-line)
      (let ((start (point)))
        (forward-sexp)
        (delete-region start (point))
        (insert new-parse-function)))
    
    ;; Update prompt format
    (goto-char (point-min))
    (when (search-forward "respond with a function_call in this exact format:" nil t)
      (replace-match "respond with ONLY a JSON function call in this exact format (no other text):"))
    
    ;; Replace XML with JSON example
    (goto-char (point-min))
    (when (search-forward "<function_calls>" nil t)
      (let ((start (match-beginning 0)))
        (when (search-forward "</function_calls>" nil t)
          (delete-region start (point))
          (insert "{\\\"function_call\\\": {\\\"name\\\": \\\"TOOL_NAME\\\", \\\"arguments\\\": {\\\"arg1\\\": \\\"value1\\\", \\\"arg2\\\": \\\"value2\\\"}}}")
          (message "XML replaced with JSON"))))
    
    ;; Update trailing text
    (goto-char (point-min))
    (when (search-forward "After receiving tool results, continue helping the user naturally." nil t)
      (replace-match "After the function executes, you will receive the result and can continue helping the user."))
    
    ;; Update extract-content to handle JSON blocks
    (goto-char (point-min))
    (when (search-forward "(while (search-forward \"<function_calls>\" nil t)" nil t)
      (beginning-of-line)
      (let ((start (point)))
        (forward-line 6)
        (delete-region start (point))
        (insert "    ;; Remove JSON code blocks\n    (while (search-forward \"```json\" nil t)\n      (let ((start (match-beginning 0)))\n        (when (search-forward \"```\" nil t)\n          (delete-region start (point))\n          (when (looking-at \"\\\\s-*\")\n            (delete-region (match-beginning 0) (match-end 0))))))\n    ;; Remove any remaining XML blocks for backward compatibility\n    (goto-char (point-min))\n"))))
    
    (save-buffer))
  (kill-buffer))
(message "Changes applied")
