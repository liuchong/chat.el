;;; chat-llm-kimi-code.el --- Kimi Code China provider for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Your Name
;; Keywords: tools, convenience

;; This file is part of chat.el.

;;; Commentary:

;; Kimi Code China provider configuration.
;; API documentation: https://www.kimi.com/code/docs/more/third-party-agents.html

;;; Code:

(require 'chat-llm)
(require 'chat-llm-claude)

;; ------------------------------------------------------------------
;; Configuration
;; ------------------------------------------------------------------

(defgroup chat-llm-kimi-code nil
  "Kimi Code China provider for chat.el."
  :group 'chat)

(defcustom chat-llm-kimi-code-api-key nil
  "API key for Kimi Code China.
Get your key from: https://www.kimi.com/code"
  :type '(choice (string :tag "API Key")
                 (function :tag "Function returning API key"))
  :group 'chat-llm-kimi-code)

(defcustom chat-llm-kimi-code-api-key-fn nil
  "Function to retrieve Kimi Code API key dynamically."
  :type '(choice (const nil) function)
  :group 'chat-llm-kimi-code)

(defcustom chat-llm-kimi-code-default-model "kimi-for-coding"
  "Default model for Kimi Code China."
  :type 'string
  :group 'chat-llm-kimi-code)

;; ------------------------------------------------------------------
;; Provider Implementation
;; ------------------------------------------------------------------

(defun chat-llm-kimi-code--get-api-key ()
  "Get Kimi Code API key from configuration."
  (or chat-llm-kimi-code-api-key
      (when chat-llm-kimi-code-api-key-fn
        (funcall chat-llm-kimi-code-api-key-fn))
      (chat-llm--auth-source-lookup 'kimi-code
                                    (chat-llm-get-provider-config 'kimi-code))))

(defun chat-llm-kimi-code--build-request (messages options)
  "Build Kimi Code request with MESSAGES and OPTIONS.

Uses OpenAI-compatible format."
  (let* ((model (or (plist-get options :model)
                    chat-llm-kimi-code-default-model))
         (max-tokens (or (plist-get options :max-tokens) 32768))
         (stream (plist-get options :stream)))
    `((model . ,model)
      (messages . ,(chat-llm--format-messages
                    messages
                    (chat-llm--replay-reasoning-p 'kimi-code model)))
      ;; 这个端点只接受 temperature 1，k3、k3-256k、kimi-for-coding 一律
      ;; 如此，别的值一律 400 invalid temperature。调用方给的值只能丢掉：
      ;; chat-ui 固定传 0.7，照传过去每个请求都会失败。
      (temperature . 1)
      (max_tokens . ,max-tokens)
      ,@(when stream `((stream . ,stream)))
      ,@(when-let ((tools (plist-get options :tools)))
          `((tools . ,tools)
            (tool_choice . "auto"))))))

(defun chat-llm-kimi-code--parse-response (json-data)
  "Parse Kimi Code API JSON-DATA response.

Handles OpenAI-compatible response format."
  ;; Check for API error response
  (when-let ((error-obj (cdr (assoc 'error json-data))))
    (let ((err-msg (cdr (assoc 'message error-obj)))
          (err-type (cdr (assoc 'type error-obj))))
      (error "Kimi Code API error: %s (%s)"
             (or err-msg "Unknown")
             (or err-type "unknown"))))
  ;; Parse normal response
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (and choices
                            (if (vectorp choices)
                                (aref choices 0)
                              (car choices))))
         (message (and first-choice (cdr (assoc 'message first-choice)))))
    (unless message
      (error "Unexpected response format: %s"
             (json-encode json-data)))
    (chat-llm--normalize-content (cdr (assoc 'content message)))))

(defun chat-llm-kimi-code--parse-stream-chunk (json-data)
  "Parse a Kimi Code streaming chunk JSON-DATA.

Uses OpenAI-compatible streaming format."
  (let* ((choices (cdr (assoc 'choices json-data)))
         (first-choice (and choices
                            (if (vectorp choices)
                                (aref choices 0)
                              (car choices))))
         (delta (and first-choice (cdr (assoc 'delta first-choice))))
         (content (and delta (cdr (assoc 'content delta)))))
    content))

;; ------------------------------------------------------------------
;; Custom Headers
;; ------------------------------------------------------------------

(defun chat-llm-kimi-code--headers ()
  "Generate headers for Kimi Code API.

报自己的真实标识。这里曾经写死 claude-code/0.1.0，理由是服务端只放行
「已认可的 coding agent」；实测该前提不成立：同一个 key 打
/coding/v1/chat/completions 和 /coding/v1/messages，用 chat.el 自己的
标识、curl 的默认标识、乃至完全不发 User-Agent，都是 200。
而官方社区倡议明确禁止伪造客户端身份，冒用会让会员权益有被暂停的风险，
所以没有任何理由继续冒用。

如果哪天真的收到 403 access_terminated_error，应先复现确认是 UA 导致
（服务端先验 key 再验 UA，key 失效时任何 UA 都只会回 401，那种状态下改
UA 是验证不了的），再走反馈渠道申请把 chat.el 纳入可识别的客户端。
参考 https://www.kimi.com/code/docs/kimi-code/community-guidelines.html"
  `(("User-Agent" . ,(format "chat.el/%s"
                             (or (bound-and-true-p chat-version) "0.1.0")))
    ("Accept" . "application/json")))

;; ------------------------------------------------------------------
;; Provider Registration
;; ------------------------------------------------------------------

(defconst chat-llm-kimi-code-models
  '("k3" "k3-256k" "kimi-for-coding" "kimi-for-coding-highspeed")
  "Model ids the Kimi Code channel serves, as its own /models returns them.

`k3' carries a million tokens of context for members who have unlocked
it, `k3-256k' is the same model at a quarter of that and about half the
consumption, and the two `kimi-for-coding' ids are the previous
generation, the highspeed one gated behind a higher tier.")

(chat-llm-register-provider
 'kimi-code
 :name "Kimi Code"
 :base-url "https://api.kimi.com/coding/v1"
 :async-transport 'curl
 :api-key-fn #'chat-llm-kimi-code--get-api-key
 :model chat-llm-kimi-code-default-model
 :vendor 'kimi-code
 :models chat-llm-kimi-code-models
 :context-window 262144
 :max-output-tokens 32768
 :capabilities '(:stream t :tools t :tool-choice (auto)
                 :reasoning t :input-modalities (text)
                 :structured-output unknown
                 :supported-options (:max-tokens))
 :headers #'chat-llm-kimi-code--headers
 :build-request-fn #'chat-llm-kimi-code--build-request
 :response-fn #'chat-llm-kimi-code--parse-response
 :stream-fn #'chat-llm-kimi-code--parse-stream-chunk)

;; Kimi Code also speaks the Anthropic Messages protocol on the same
;; host, so it registers through the anthropic compatible factory.
(chat-llm-register-anthropic-compatible-provider
 'kimi-code-anthropic
 "Kimi Code (Anthropic)"
 "https://api.kimi.com/coding"
 chat-llm-kimi-code-default-model
 :async-transport 'curl
 :api-key-fn #'chat-llm-kimi-code--get-api-key
 :vendor 'kimi-code
 :models chat-llm-kimi-code-models
 :context-window 262144
 :max-output-tokens 32768
 :capabilities '(:stream t :tools t :tool-choice nil
                 :reasoning t :input-modalities (text)
                 :structured-output nil
                 :supported-options (:max-tokens)))

(provide 'chat-llm-kimi-code)
;;; chat-llm-kimi-code.el ends here
