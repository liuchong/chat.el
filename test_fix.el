(add-to-list 'load-path ".")
(require 'chat-tool-caller)

;; 测试 AI 实际输出的格式
(setq ai-output "json
{\"function_call\":name\": \"_execute\", \"\": {\"input\":pwd\"}}}")

(message "AI output: %s" ai-output)
(message "Fixed: %s" (chat-tool-caller--fix-broken-json ai-output))
(message "Parsed: %S" (chat-tool-caller-parse ai-output))
