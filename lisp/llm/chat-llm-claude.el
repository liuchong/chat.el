;;; chat-llm-claude.el --- Claude provider for chat.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: llm, claude, anthropic
;;; Commentary:
;; This module provides integration with the official Claude Messages API.
;;; Code:
(require 'chat-llm)
(defgroup chat-llm-claude nil
  "Claude provider configuration."
  :group 'chat-llm)
(defcustom chat-llm-claude-default-model "claude-sonnet-4-5"
  "Default Claude model to use."
  :type 'string
  :group 'chat-llm-claude)
(defcustom chat-llm-claude-api-key nil
  "API key for Claude."
  :type '(choice (const :tag "Use auth-source" nil)
                 (string :tag "API key"))
  :group 'chat-llm-claude)
(defcustom chat-llm-claude-api-key-fn nil
  "Function to retrieve Claude API key."
  :type '(choice (const :tag "None" nil)
                 (function :tag "Key function"))
  :group 'chat-llm-claude)
(defcustom chat-llm-claude-api-version "2023-06-01"
  "Claude API version header."
  :type 'string
  :group 'chat-llm-claude)
(defun chat-llm-claude--get-api-key ()
  "Get Claude API key from configuration."
  (or chat-llm-claude-api-key
      (when chat-llm-claude-api-key-fn
        (funcall chat-llm-claude-api-key-fn))
      (chat-llm--auth-source-lookup 'claude
                                    (chat-llm-get-provider-config 'claude))))
(defun chat-llm-claude--auth-headers (api-key _provider config)
  "Build Anthropic auth headers from API-KEY."
  (list (cons "x-api-key" api-key)
        (cons "anthropic-version"
              (or (plist-get config :anthropic-version)
                  chat-llm-claude-api-version))))
(defun chat-llm-claude--message-role (role)
  "Map internal ROLE to a Claude role string."
  (pcase role
    (:assistant "assistant")
    (:tool "user")
    (_ "user")))

(defun chat-llm-claude--input-part (part)
  "Encode typed PART for an Anthropic-compatible user message."
  (pcase (chat-content-part-type part)
    ('text
     `((type . "text") (text . ,(chat-content-part-text part))))
    ('image
     `((type . "image")
       (source . ((type . "base64")
                  (media_type . ,(chat-content-part-mime-type part))
                  (data . ,(chat-content-part-base64 part))))))
    ('file
     (cond
      ((chat-content-part-text-file-p part)
       `((type . "document")
         (source . ((type . "text")
                    (media_type . ,(chat-content-part-mime-type part))
                    (data . ,(chat-content-part-file-text part))))
         (title . ,(chat-content-part-name part))))
      ((equal (chat-content-part-mime-type part) "application/pdf")
       `((type . "document")
         (source . ((type . "base64")
                    (media_type . "application/pdf")
                    (data . ,(chat-content-part-base64 part))))
         (title . ,(chat-content-part-name part))))
      (t
       (error "Anthropic-compatible messages cannot inline file: %s"
              (chat-content-part-name part)))))
    (_
     (error "Content part %s is not valid user input"
            (chat-content-part-type part)))))

(defun chat-llm-claude--content-for (msg)
  "Build Claude content for MSG, including tool_use / tool_result blocks."
  (let ((role (chat-message-role msg))
        (content (or (chat-message-text msg) ""))
        (calls (chat-message-tool-calls msg))
        (metadata (chat-message-metadata msg)))
    (cond
     ((eq role :tool)
      (vector
       `((type . "tool_result")
         (tool_use_id . ,(or (plist-get metadata :tool-call-id)
                             (chat-message-id msg)))
         (content . ,content))))
     ((and (eq role :assistant) calls)
      (vconcat
       (append
        (unless (string-blank-p content)
          (list `((type . "text") (text . ,content))))
        (mapcar
         (lambda (call)
           `((type . "tool_use")
             (id . ,(or (plist-get call :id) (plist-get call :name)))
             (name . ,(plist-get call :name))
             (input . ,(or (plist-get call :arguments) (make-hash-table)))))
         calls))))
     ((seq-some (lambda (part)
                  (not (eq (chat-content-part-type part) 'text)))
                (chat-message-parts msg))
      (unless (eq role :user)
        (error "Only user messages may contain input attachments"))
      (vconcat (mapcar #'chat-llm-claude--input-part
                       (chat-message-parts msg))))
     (t content))))

(defun chat-llm-claude--build-request (provider messages options)
  "Build an Anthropic compatible request for PROVIDER with MESSAGES."
  (let* ((config (chat-llm--ensure-provider provider))
         (system-lines nil)
         (normal-messages nil)
         (tools (plist-get options :tools)))
    (dolist (msg messages)
      (let ((role (chat-message-role msg))
            (content (or (chat-message-text msg) "")))
        (cond
         ((eq role :system)
          (unless (string-empty-p content)
            (push content system-lines)))
         ((or (not (string-empty-p content))
              (chat-message-tool-calls msg)
              (eq role :tool))
          (push `((role . ,(chat-llm-claude--message-role role))
                  (content . ,(chat-llm-claude--content-for msg)))
                normal-messages)))))
    (let ((request
           (list :model (or (plist-get options :model)
                            (plist-get config :model))
                 :messages (vconcat (nreverse normal-messages))
                 :max_tokens (or (plist-get options :max-tokens)
                                 (plist-get config :max-output-tokens)
                                 4096)
                 :temperature (or (plist-get options :temperature) 0.7)
                 :stream (plist-get options :stream))))
      (when system-lines
        (setq request
              (plist-put request :system
                         (mapconcat #'identity (nreverse system-lines) "\n\n"))))
      (when tools
        (setq request
              (plist-put request :tools
                         (chat-llm-claude--tools-from-openai tools))))
      request)))

(defun chat-llm-claude--tools-from-openai (tools)
  "Convert OpenAI-style TOOLS vector into Anthropic tool definitions."
  (vconcat
   (mapcar
    (lambda (tool)
      (let ((fn (or (chat-llm--field tool 'function) tool)))
        (list :name (or (chat-llm--field fn 'name)
                        (chat-llm--field tool 'name))
              :description (or (chat-llm--field fn 'description) "")
              :input_schema (or (chat-llm--field fn 'parameters)
                                (list :type "object"
                                      :properties (make-hash-table :test 'equal)
                                      :required []
                                      :additionalProperties :json-false)))))
    (if (vectorp tools) (append tools nil) tools))))

(defun chat-llm-claude--parse-response (json-data)
  "Parse Claude response JSON-DATA."
  (when-let ((error-obj (cdr (assoc 'error json-data))))
    (error "Claude API error: %s"
           (or (cdr (assoc 'message error-obj))
               (json-encode error-obj))))
  (let ((blocks (cdr (assoc 'content json-data)))
        (texts nil))
    (dolist (block (if (vectorp blocks) (append blocks nil) blocks))
      (when (string= (cdr (assoc 'type block)) "text")
        (push (cdr (assoc 'text block)) texts)))
    (mapconcat #'identity (nreverse texts) "")))
(defun chat-llm-claude--parse-stream-chunk (json-data)
  "Parse Claude stream chunk JSON-DATA."
  (let ((delta (cdr (assoc 'delta json-data))))
    (or (cdr (assoc 'text delta))
        (cdr (assoc 'text (cdr (assoc 'content_block json-data)))))))
(defun chat-llm-register-anthropic-compatible-provider (symbol name base-url model &rest options)
  "Register SYMBOL as an Anthropic Messages API compatible provider.
NAME is the display name.
BASE-URL is the provider API base URL.
MODEL is the default remote model name.
OPTIONS are appended to the provider plist; useful keys include
`:request-path' (default `/v1/messages'), `:anthropic-version', and
`:api-key-fn'."
  (let ((capabilities
         (if (plist-member options :capabilities)
             (plist-get options :capabilities)
           '(:stream t :tools t :tool-choice nil
             :reasoning unknown :input-modalities (text)
             :structured-output nil
             :supported-options (:temperature :max-tokens)))))
    (apply #'chat-llm-register-provider
           symbol
           :name name
           :base-url base-url
           :request-path "/v1/messages"
           :model model
           :protocol 'anthropic
           :capabilities capabilities
           :auth-headers-fn #'chat-llm-claude--auth-headers
           :request-fn (lambda (messages request-options)
                         (chat-llm-claude--build-request
                          symbol messages request-options))
           :response-fn #'chat-llm-claude--parse-response
           :stream-fn #'chat-llm-claude--parse-stream-chunk
           options)))

(chat-llm-register-anthropic-compatible-provider
 'claude
 "Claude"
 "https://api.anthropic.com"
 chat-llm-claude-default-model
 :api-key-fn #'chat-llm-claude--get-api-key
 :model-capabilities
 (list (cons chat-llm-claude-default-model
             '(:input-modalities (text image file)))))
(provide 'chat-llm-claude)
;;; chat-llm-claude.el ends here
