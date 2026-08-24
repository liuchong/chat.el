;;; chat-agent-transcript.el --- Persist ordered agent messages -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Helpers for host UIs that persist messages emitted by the agent loop.
;; The loop owns ordering; hosts decide when to render.

;;; Code:

(require 'cl-lib)
(require 'chat-session)

(defun chat-agent-transcript-persistable-p (message)
  "Return non-nil when MESSAGE should be written to user history."
  (memq (chat-message-role message) '(:assistant :tool)))

(defun chat-agent-transcript-message-exists-p (session message-id)
  "Return non-nil when SESSION already contains MESSAGE-ID."
  (and message-id
       (cl-find message-id
                (chat-session-messages session)
                :key #'chat-message-id
                :test #'equal)))

(defun chat-agent-transcript-persist-message (session message)
  "Persist MESSAGE to SESSION once, preserving loop order."
  (when (and session
             (chat-agent-transcript-persistable-p message)
             (not (chat-agent-transcript-message-exists-p
                   session
                   (chat-message-id message))))
    (chat-session-add-message session message)
    message))

(provide 'chat-agent-transcript)
;;; chat-agent-transcript.el ends here
