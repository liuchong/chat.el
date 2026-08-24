;;; chat-agent.el --- Compatibility shim for the extracted kernel -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; The agent kernel now lives in lisp/agent/.  This file keeps
;; `(require 'chat-agent)` working when only lisp/core is on load-path.

;;; Code:

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (agent-dir (expand-file-name "../agent/" here)))
  (add-to-list 'load-path agent-dir)
  (load (expand-file-name "chat-agent.el" agent-dir) nil nil))

;;; chat-agent.el ends here
