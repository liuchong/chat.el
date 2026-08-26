;;; chat-llm-compatible-providers.el --- OpenAI compatible providers -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: llm, api, providers
;;; Commentary:
;; This module registers mainstream OpenAI compatible providers.
;;; Code:
(require 'chat-llm)
;; For the Anthropic factory: one of these vendors serves both protocols.
(require 'chat-llm-claude)
(defgroup chat-llm-compatible-providers nil
  "OpenAI compatible provider configuration."
  :group 'chat-llm)
(defun chat-llm-compatible--api-key (provider api-key-var api-key-fn-var)
  "Return API key for PROVIDER from API-KEY-VAR or API-KEY-FN-VAR."
  (or (and (boundp api-key-var) (symbol-value api-key-var))
      (when-let ((fn (and (boundp api-key-fn-var)
                          (symbol-value api-key-fn-var))))
        (funcall fn))
      (chat-llm--auth-source-lookup provider
                                    (chat-llm-get-provider-config provider))))
(defmacro chat-llm-compatible--define-provider (symbol display-name base-url default-model &rest options)
  "Define one OpenAI compatible provider SYMBOL.

OPTIONS are passed through to the registration, for the things that vary
between vendors rather than between compatibility layers -- a vendor
identity shared with another protocol, or the model list it serves."
  (let* ((prefix (format "chat-llm-%s" symbol))
         (group-symbol (intern prefix))
         (default-model-symbol (intern (format "%s-default-model" prefix)))
         (api-key-symbol (intern (format "%s-api-key" prefix)))
         (api-key-fn-symbol (intern (format "%s-api-key-fn" prefix))))
    `(progn
       (defgroup ,group-symbol nil
         ,(format "%s provider configuration." display-name)
         :group 'chat-llm-compatible-providers)
       (defcustom ,default-model-symbol ,default-model
         ,(format "Default %s model to use." display-name)
         :type 'string
         :group ',group-symbol)
       (defcustom ,api-key-symbol nil
         ,(format "API key for %s." display-name)
         :type '(choice (const :tag "Use auth-source" nil)
                        (string :tag "API key"))
         :group ',group-symbol)
       (defcustom ,api-key-fn-symbol nil
         ,(format "Function to retrieve %s API key." display-name)
         :type '(choice (const :tag "None" nil)
                        (function :tag "Key function"))
         :group ',group-symbol)
       (apply #'chat-llm-register-openai-compatible-provider
              ',symbol
              ,display-name
              ,base-url
              ,default-model-symbol
              :api-key-fn (lambda ()
                            (chat-llm-compatible--api-key
                             ',symbol
                             ',api-key-symbol
                             ',api-key-fn-symbol))
              (list ,@options)))))
;; `deepseek-chat' used to stand here.  It answers, but as an alias: a
;; request naming it comes back reporting `deepseek-v4-flash', so the
;; registration could not say which model a session had actually used.
;; The ids below are what the vendor's own /models returns.
(chat-llm-compatible--define-provider
 deepseek
 "DeepSeek"
 "https://api.deepseek.com/v1"
 "deepseek-v4-flash"
 :vendor 'deepseek
 :models '("deepseek-v4-flash"
           "deepseek-v4-pro"
           "deepseek-v4-flash-vision-exp"))

;; The same host also speaks the Anthropic Messages protocol, under a
;; path of its own.  Kept out of menus, reachable by name -- see
;; `chat-llm-vendor-primary-provider'.
(chat-llm-register-anthropic-compatible-provider
 'deepseek-anthropic
 "DeepSeek (Anthropic)"
 "https://api.deepseek.com/anthropic"
 chat-llm-deepseek-default-model
 :vendor 'deepseek
 :models '("deepseek-v4-flash"
           "deepseek-v4-pro"
           "deepseek-v4-flash-vision-exp")
 :api-key-fn (lambda ()
               (chat-llm-compatible--api-key
                'deepseek
                'chat-llm-deepseek-api-key
                'chat-llm-deepseek-api-key-fn)))
(chat-llm-compatible--define-provider
 qwen
 "Qwen"
 "https://dashscope.aliyuncs.com/compatible-mode/v1"
 "qwen-plus")
(chat-llm-compatible--define-provider
 grok
 "Grok"
 "https://api.x.ai/v1"
 "grok-4-fast-non-reasoning")
(chat-llm-compatible--define-provider
 mistral
 "Mistral"
 "https://api.mistral.ai/v1"
 "mistral-large-latest")
(chat-llm-compatible--define-provider
 glm
 "GLM"
 "https://open.bigmodel.cn/api/paas/v4"
 "glm-4-plus")
(chat-llm-compatible--define-provider
 doubao
 "Doubao"
 "https://ark.cn-beijing.volces.com/api/v3"
 "doubao-pro-32k")
(chat-llm-compatible--define-provider
 hunyuan
 "Hunyuan"
 "https://api.hunyuan.cloud.tencent.com/v1"
 "hunyuan-turbo")
(chat-llm-compatible--define-provider
 minimax
 "MiniMax"
 "https://api.minimax.chat/v1"
 "MiniMax-Text-01")
(provide 'chat-llm-compatible-providers)
;;; chat-llm-compatible-providers.el ends here
