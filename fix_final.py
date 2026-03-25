with open('chat-tool-caller.el', 'r') as f:
    content = f.read()

# Replace the parse function with a more robust version
old_parse = '''(defun chat-tool-caller-parse (content)
  "Parse JSON tool calls from code blocks."
  (let ((calls nil) (pos 0))
    (while (string-match "```json" content pos)
      (let ((start (match-end 0))
            (end (string-match "```" content (match-end 0))))
        (when end
          (let ((json-str (substring content start end)))
            (setq json-str (replace-regexp-in-string "^\\\\s-+" "" json-str))
            (setq json-str (replace-regexp-in-string "\\\\s-+$" "" json-str))
            (condition-case nil
                (let* ((data (json-read-from-string json-str))
                       (fc (cdr (assoc 'function_call data))))
                  (when fc
                    (push (list :name (cdr (assoc 'name fc))
                               :arguments (cdr (assoc 'arguments fc)))
                          calls)))
              (error nil)))
          (setq pos end))
        (setq pos (or end (length content)))))
    (nreverse calls)))'''

new_parse = '''(defun chat-tool-caller-parse (content)
  "Parse JSON tool calls from code blocks.
Handles correct format and common AI mistakes."
  (let ((calls nil) (pos 0))
    ;; Try standard ```json blocks
    (while (string-match "```json" content pos)
      (let ((start (match-end 0))
            (end (string-match "```" content (match-end 0))))
        (when end
          (let ((json-str (substring content start end)))
            (setq json-str (replace-regexp-in-string "^\\\\s-+" "" json-str))
            (setq json-str (replace-regexp-in-string "\\\\s-+$" "" json-str))
            ;; Try normal parse first
            (condition-case nil
                (let* ((data (json-read-from-string json-str))
                       (fc (or (cdr (assoc 'function_call data))
                               (cdr (assoc '_call data)))))
                  (when fc
                    (let ((name (cdr (assoc 'name fc)))
                          (args (cdr (assoc 'arguments fc))))
                      ;; Normalize tool name
                      (when (string= name "_execute") (setq name "shell_execute"))
                      (push (list :name name :arguments args) calls))))
              ;; If fails, try fixing common AI mistakes
              (error
               (condition-case nil
                   (let* ((fixed (chat-tool-caller--fix-json json-str))
                          (data (json-read-from-string fixed))
                          (fc (or (cdr (assoc 'function_call data))
                                  (cdr (assoc '_call data)))))
                     (when fc
                       (let ((name (cdr (assoc 'name fc)))
                             (args (cdr (assoc 'arguments fc))))
                         (when (string= name "_execute") (setq name "shell_execute"))
                         (push (list :name name :arguments args) calls))))
                 (error nil)))))
          (setq pos end))
        (setq pos (or end (length content)))))
    ;; Try finding JSON without code blocks
    (when (null calls)
      (condition-case nil
          (when (string-match "{.*function" content)
            (let ((json-str (match-string 0 content)))
              (condition-case nil
                  (let* ((data (json-read-from-string json-str))
                         (fc (or (cdr (assoc 'function_call data))
                                 (cdr (assoc '_call data)))))
                    (when fc
                      (let ((name (cdr (assoc 'name fc)))
                            (args (cdr (assoc 'arguments fc))))
                        (when (string= name "_execute") (setq name "shell_execute"))
                        (push (list :name name :arguments args) calls))))
                (error nil))))
        (error nil)))
    (nreverse calls)))

(defun chat-tool-caller--fix-json (str)
  "Fix common AI JSON mistakes."
  (let ((result str))
    ;; Remove json prefix
    (setq result (replace-regexp-in-string "^json\\\\s-*" "" result))
    ;; Fix name\": to \"name\":
    (setq result (replace-regexp-in-string "name\\\\s-*:\\"" "\\\"name\\\":" result))
    ;; Fix _call to function_call  
    (setq result (replace-regexp-in-string "\\\"_call\\\"" "\\\"function_call\\\"" result))
    ;; Fix _execute to shell_execute
    (setq result (replace-regexp-in-string "\\\"_execute\\\"" "\\\"shell_execute\\\"" result))
    ;; Fix unquoted values like pwd\" to \"pwd\"
    (setq result (replace-regexp-in-string ":\\\\s-*\\([^\\\"{}]+\\)\"" ":\"\\1\"" result))
    result))'''

if old_parse in content:
    content = content.replace(old_parse, new_parse)
    print("Parse function updated")
else:
    print("Old parse function not found")

with open('chat-tool-caller.el', 'w') as f:
    f.write(content)

print("Done")
