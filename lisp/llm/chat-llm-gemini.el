;;; chat-llm-gemini.el --- Gemini provider for chat.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: llm, gemini, google
;;; Commentary:
;; This module provides integration with the official Gemini API.
;;; Code:
(require 'chat-llm)
(defgroup chat-llm-gemini nil
  "Gemini provider configuration."
  :group 'chat-llm)
(defcustom chat-llm-gemini-default-model "gemini-2.5-flash"
  "Default Gemini model to use."
  :type 'string
  :group 'chat-llm-gemini)
(defcustom chat-llm-gemini-api-key nil
  "API key for Gemini."
  :type '(choice (const :tag "Use auth-source" nil)
                 (string :tag "API key"))
  :group 'chat-llm-gemini)
(defcustom chat-llm-gemini-api-key-fn nil
  "Function to retrieve Gemini API key."
  :type '(choice (const :tag "None" nil)
                 (function :tag "Key function"))
  :group 'chat-llm-gemini)
(defun chat-llm-gemini--get-api-key ()
  "Get Gemini API key from configuration."
  (or chat-llm-gemini-api-key
      (when chat-llm-gemini-api-key-fn
        (funcall chat-llm-gemini-api-key-fn))
      (chat-llm--auth-source-lookup 'gemini
                                    (chat-llm-get-provider-config 'gemini))))
(defun chat-llm-gemini--auth-headers (api-key _provider _config)
  "Build Gemini auth headers from API-KEY."
  (list (cons "x-goog-api-key" api-key)))
(defun chat-llm-gemini--request-url (_provider config options)
  "Build Gemini request URL from CONFIG and OPTIONS."
  (let ((model (or (plist-get options :model)
                   (plist-get config :model))))
    (format "%s/v1/models/%s:%s"
            (plist-get config :base-url)
            model
            (if (plist-get options :stream)
                "streamGenerateContent?alt=sse"
              "generateContent"))))
(defun chat-llm-gemini--message-role (role)
  "Map internal ROLE to a Gemini role string."
  (if (eq role :assistant)
      "model"
    "user"))
(defun chat-llm-gemini--message-part (content)
  "Build one Gemini text part from CONTENT."
  `((text . ,content)))
(defun chat-llm-gemini--build-request (messages options)
  "Build Gemini request with MESSAGES and OPTIONS."
  (let ((system-lines nil)
        (contents nil))
    (dolist (msg messages)
      (let ((role (chat-message-role msg))
            (content (or (chat-message-content msg) "")))
        (when (not (string-empty-p content))
          (if (eq role :system)
              (push content system-lines)
            (push `((role . ,(chat-llm-gemini--message-role role))
                    (parts . [,(chat-llm-gemini--message-part content)]))
                  contents)))))
    (let ((request
           (list :contents (vconcat (nreverse contents))
                 :generationConfig
                 (list :temperature (or (plist-get options :temperature) 0.7)
                       :maxOutputTokens (or (plist-get options :max-tokens) 4096)))))
      (when system-lines
        (setq request
              (plist-put request :systemInstruction
                         `((parts . [((text . ,(mapconcat #'identity
                                                          (nreverse system-lines)
                                                          "\n\n")))])))))
      request)))
(defun chat-llm-gemini--extract-parts-text (parts)
  "Extract concatenated text from Gemini PARTS."
  (let ((texts nil))
    (dolist (part (if (vectorp parts) (append parts nil) parts))
      (when-let ((text (cdr (assoc 'text part))))
        (push text texts)))
    (mapconcat #'identity (nreverse texts) "")))
(defun chat-llm-gemini--parse-response (json-data)
  "Parse Gemini response JSON-DATA."
  (when-let ((error-obj (cdr (assoc 'error json-data))))
    (error "Gemini API error: %s"
           (or (cdr (assoc 'message error-obj))
               (json-encode error-obj))))
  (let* ((candidates (cdr (assoc 'candidates json-data)))
         (first-candidate (car (if (vectorp candidates)
                                   (append candidates nil)
                                 candidates)))
         (content (cdr (assoc 'content first-candidate)))
         (parts (cdr (assoc 'parts content)))
         (text (chat-llm-gemini--extract-parts-text parts)))
    (unless (> (length text) 0)
      (error "Unexpected Gemini response format: %s" (json-encode json-data)))
    text))
(defun chat-llm-gemini--parse-stream-chunk (json-data)
  "Parse Gemini stream chunk JSON-DATA."
  (ignore-errors
    (chat-llm-gemini--parse-response json-data)))
(chat-llm-register-provider
 'gemini
 :name "Gemini"
 :base-url "https://generativelanguage.googleapis.com"
 :api-key-fn #'chat-llm-gemini--get-api-key
 :auth-headers-fn #'chat-llm-gemini--auth-headers
 :request-url-fn #'chat-llm-gemini--request-url
 :model chat-llm-gemini-default-model
 :request-fn #'chat-llm-gemini--build-request
 :response-fn #'chat-llm-gemini--parse-response
 :stream-fn #'chat-llm-gemini--parse-stream-chunk)
(provide 'chat-llm-gemini)
;;; chat-llm-gemini.el ends here
