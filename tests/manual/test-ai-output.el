(load (expand-file-name "../test-paths.el" (file-name-directory load-file-name)) nil t)
(require 'chat-tool-caller)

;; 测试 AI 实际输出的格式
(setq ai-output "json
{\"function_call\":name\": \"_execute\", \"\": {\"input\":pwd\"}}}")

(message "AI output: %s" ai-output)
(message "Parsed: %S" (chat-tool-caller-parse ai-output))

;; 尝试修复
(message "\nTrying to fix...")
(let* ((fixed (replace-regexp-in-string "^json\\s-*" "" ai-output))
       (fixed2 (replace-regexp-in-string "name\"" "\"name\"" fixed)))
  (message "After fix 1 (remove 'json' prefix): %s" fixed)
  (message "After fix 2 (fix name quote): %s" fixed2))
