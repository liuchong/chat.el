#!/usr/bin/env emacs -Q --script
;;; test-kimi-code-api.el --- Test Kimi Code API integration -*- lexical-binding: t -*-

;; This prototype verifies Kimi Code China API works with chat.el
;; Reference: https://www.kimi.com/code/docs/more/third-party-agents.html

(load (expand-file-name "../test-paths.el" (file-name-directory load-file-name)) nil t)

(require 'cl-lib)
(require 'chat-session)
(require 'chat-llm)
(require 'chat-llm-kimi)
(require 'chat-llm-kimi-code)
(require 'chat-log)

;; Load local config for API key
(let ((local-config (expand-file-name "../../chat-config.local.el"
                                       (file-name-directory load-file-name))))
  (when (file-exists-p local-config)
    (load local-config nil t)))

;; If kimi-code key not set but kimi key is, use that
(when (and (not chat-llm-kimi-code-api-key) 
           chat-llm-kimi-api-key)
  (setq chat-llm-kimi-code-api-key chat-llm-kimi-api-key))

(setq chat-log-enable t)
(setq chat-log-file "~/.chat/chat.log")

(defun test-kimi-code-simple-request ()
  "Test simple non-streaming request to Kimi Code."
  (message "=== Testing Kimi Code API ===")
  
  ;; Check API key
  (let ((api-key (chat-llm-kimi-code--get-api-key)))
    (unless api-key
      (error "No API key found. Set chat-llm-kimi-code-api-key"))
    (message "API Key: %s..." (substring api-key 0 (min 20 (length api-key)))))
  
  ;; Make request
  (let* ((messages (list (make-chat-message 
                          :id "test-1"
                          :role :user 
                          :content "Hello from chat.el prototype test"
                          :timestamp (current-time))))
         (start-time (float-time)))
    
    (message "Sending request...")
    (condition-case err
        (let ((response (chat-llm-request 'kimi-code messages 
                                          '(:temperature 0.7 :max-tokens 512))))
          (message "✓ SUCCESS in %.2f seconds" (- (float-time) start-time))
          (message "Response: %s" (substring response 0 (min 200 (length response))))
          t)
      (error
       (message "✗ FAILED: %s" (error-message-string err))
       nil))))

;; Run test
(if (test-kimi-code-simple-request)
    (progn
      (message "\n=== Kimi Code API Test PASSED ===")
      (kill-emacs 0))
  (message "\n=== Kimi Code API Test FAILED ===")
  (kill-emacs 1))
