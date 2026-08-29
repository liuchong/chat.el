;;; test-chat-session-export.el --- Session export tests -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for the public, privacy-safe session transcript projection.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-session-export)
(require 'chat-session-tree)

(defun chat-session-export-test--session ()
  "Return a session containing visible and private fixture data."
  (make-chat-session
   :id "session-1"
   :name "Export Test"
   :created-at (encode-time 0 0 12 1 8 2026 t)
   :updated-at (encode-time 30 15 13 2 8 2026 t)
   :model-id 'deepseek
   :model-name "deepseek-v4-flash"
   :branch-id "branch-1"
   :metadata '((working-directory . "/private/project"))
   :prompt-stack '("PRIVATE SYSTEM PROMPT")
   :messages
   (list
    (make-chat-message
     :id "system-1" :role :system :content "PRIVATE SYSTEM PROMPT")
    (make-chat-message
     :id "user-1" :role :user
     :timestamp (encode-time 0 1 12 1 8 2026 t)
     :content "Keep **this** Markdown.\n\n```elisp\n(message \"hi\")\n```")
    (make-chat-message
     :id "assistant-1" :role :assistant
     :timestamp (encode-time 0 2 12 1 8 2026 t)
     :content "Visible answer"
     :metadata '(:reasoning "PRIVATE REASONING")
     :tool-calls '((:id "call-1" :name "shell"
                    :arguments (("token" . "PRIVATE TOOL ARGUMENT"))))
     :tool-results '("PRIVATE TOOL RESULT")
     :raw-request "PRIVATE RAW REQUEST"
     :raw-response "PRIVATE RAW RESPONSE")
    (make-chat-message
     :id "tool-1" :role :tool :content "PRIVATE TOOL MESSAGE"))))

(ert-deftest chat-session-export-markdown-keeps-only-public-transcript ()
  "Export visible conversation text without private runtime records."
  (let ((text (chat-session-export-markdown
               (chat-session-export-test--session))))
    (should (string-match-p "# Export Test" text))
    (should (string-match-p "Model: deepseek / deepseek\\-v4\\-flash" text))
    (should (string-match-p "## User - 2026-08-01T12:01:00Z" text))
    (should (string-match-p (regexp-quote "Keep **this** Markdown.") text))
    (should (string-match-p (regexp-quote "```elisp") text))
    (should (string-match-p "## Assistant - 2026-08-01T12:02:00Z" text))
    (should (string-match-p "Visible answer" text))
    (dolist (private '("PRIVATE SYSTEM PROMPT" "PRIVATE REASONING"
                       "PRIVATE TOOL ARGUMENT" "PRIVATE TOOL RESULT"
                       "PRIVATE RAW REQUEST" "PRIVATE RAW RESPONSE"
                       "PRIVATE TOOL MESSAGE" "/private/project"))
      (should-not (string-match-p (regexp-quote private) text)))))

(ert-deftest chat-session-export-markdown-is-deterministic ()
  "The same session projects to byte-identical Markdown."
  (let ((session (chat-session-export-test--session)))
    (should (equal (chat-session-export-markdown session)
                   (chat-session-export-markdown session)))))

(ert-deftest chat-session-export-summarizes-attachments-without-identifiers ()
  "Attachment exports include display facts but no storage identifiers."
  (let* ((hash (make-string 64 ?a))
         (message
          (make-chat-message
           :id "user-attachment"
           :role :user
           :content "See image"
           :content-parts
           (list
            (chat-content-text-part "See image")
            (chat-content-part-create
             :type 'image :attachment-id hash :sha256 hash
             :name "preview.png" :mime-type "image/png" :size 42))))
         (session (make-chat-session
                   :id "attachments" :name "Attachments" :model-id 'local
                   :messages (list message)))
         (text (chat-session-export-markdown session)))
    (should (string-match-p
             (regexp-quote "- Attachment: preview.png (image/png, 42 bytes)")
             text))
    (should-not (string-match-p hash text))))

(ert-deftest chat-session-export-write-refuses-silent-overwrite ()
  "A destination remains untouched unless overwrite is explicit."
  (chat-test-with-temp-dir
   (let* ((file (expand-file-name "transcript.md" temp-dir))
          (session (chat-session-export-test--session)))
     (with-temp-file file (insert "original"))
     (should-error (chat-session-export-write session file)
                   :type 'file-already-exists)
     (should (equal (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))
                    "original"))
     (should (equal (chat-session-export-write session file t) file))
     (should (string-match-p
              "Visible answer"
              (with-temp-buffer
                (insert-file-contents file)
                (buffer-string)))))))

(ert-deftest chat-session-export-default-file-name-supports-cjk ()
  "Portable export names retain useful CJK session titles."
  (let ((session (make-chat-session :id "s1" :name "渲染 / 验收")))
    (should (equal (chat-session-export-default-file-name session)
                   "渲染-验收-s1.md"))))

(ert-deftest chat-session-tree-export-has-a-direct-key ()
  "The session browser exposes export without requiring command lookup."
  (with-temp-buffer
    (chat-session-tree-mode)
    (should (eq (lookup-key chat-session-tree-mode-map (kbd "e"))
                #'chat-session-tree-export))))

(ert-deftest chat-session-tree-export-rejects-an-empty-row ()
  "Export reports the missing tree row directly."
  (with-temp-buffer
    (chat-session-tree-mode)
    (cl-letf (((symbol-function 'tabulated-list-get-id) (lambda () nil)))
      (should-error (chat-session-tree-export) :type 'user-error))))

(provide 'test-chat-session-export)
;;; test-chat-session-export.el ends here
