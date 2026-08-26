;;; chat-llm-ark.el --- Volcengine Ark provider for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: llm, ark, volcengine

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Volcengine Ark Coding Plan speaks both the OpenAI protocol and the
;; Anthropic Messages protocol on the same host, so it registers one
;; provider through each compatibility factory.

;;; Code:

(require 'chat-llm)
(require 'chat-llm-claude)

(defgroup chat-llm-ark nil
  "Volcengine Ark provider configuration."
  :group 'chat-llm)

(defcustom chat-llm-ark-default-model "ark-code-latest"
  "Default Ark model to use."
  :type 'string
  :group 'chat-llm-ark)

(defcustom chat-llm-ark-api-key nil
  "API key for Ark."
  :type '(choice (const :tag "Use auth-source" nil)
                 (string :tag "API key"))
  :group 'chat-llm-ark)

(defcustom chat-llm-ark-api-key-fn nil
  "Function to retrieve the Ark API key."
  :type '(choice (const :tag "None" nil)
                 (function :tag "Key function"))
  :group 'chat-llm-ark)

(defun chat-llm-ark--get-api-key ()
  "Get the Ark API key from configuration."
  (or chat-llm-ark-api-key
      (when chat-llm-ark-api-key-fn
        (funcall chat-llm-ark-api-key-fn))
      (chat-llm--auth-source-lookup 'ark
                                    (chat-llm-get-provider-config 'ark-code))))

(chat-llm-register-openai-compatible-provider
 'ark-code
 "Ark Code"
 "https://ark.cn-beijing.volces.com/api/plan/v3"
 chat-llm-ark-default-model
 :vendor 'ark
 :api-key-fn #'chat-llm-ark--get-api-key)

(chat-llm-register-anthropic-compatible-provider
 'ark-code-anthropic
 "Ark Code (Anthropic)"
 "https://ark.cn-beijing.volces.com/api/plan"
 chat-llm-ark-default-model
 :vendor 'ark
 :api-key-fn #'chat-llm-ark--get-api-key)

(provide 'chat-llm-ark)
;;; chat-llm-ark.el ends here
