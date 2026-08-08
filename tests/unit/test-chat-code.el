;;; test-chat-code.el --- Tests for chat-code.el -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;; This file is not part of GNU Emacs.
;;; Commentary:
;; Unit tests for chat-code.el interaction flow.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-code)
(require 'chat-request-diagnostics)

(ert-deftest chat-code-setup-buffer-creates-input-markers ()
  "Test code mode buffer setup creates stable message and input markers."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Code Session" temp-dir)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (should (markerp chat-code--messages-end))
       (should (markerp chat-code--input-marker))
       (should (< (marker-position chat-code--messages-end)
                  (marker-position chat-code--input-marker)))
       (should (eq chat-code--status-state 'idle))
       (should (string= chat-code--status-detail "Ready"))
       (should header-line-format)
       (should mode-line-format)
       (goto-char (point-min))
       (should (search-forward "> " nil t))))))

(ert-deftest chat-code-send-message-persists-history-and-keeps-input-open ()
  "Test sending a code-mode message preserves history and keeps the prompt editable."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Code Session" temp-dir))
          sent)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (goto-char (point-max))
       (insert "Fix this function")
       (cl-letf (((symbol-function 'chat-code--send-to-llm)
                  (lambda ()
                    (setq sent t))))
         (chat-code-send-message))
       (should sent)
       (should (= (length (chat-session-messages (chat-code-session-base-session session))) 1))
       (let ((saved (car (chat-session-messages (chat-code-session-base-session session)))))
         (should (eq (chat-message-role saved) :user))
         (should (string= (chat-message-content saved) "Fix this function")))
       (should (= (marker-position chat-code--input-marker) (point-max)))
       (goto-char (point-min))
       (should (search-forward "You:" nil t))
       (should (search-forward "Fix this function" nil t))))))

(ert-deftest chat-code-send-message-blocks-while-request-is-active ()
  "Test code mode blocks duplicate sends while another response is active."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Busy Session" temp-dir))
          (chat-code--active-request-handle 'request-handle)
          sent)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (setq-local chat-code--active-request-handle 'request-handle)
       (goto-char (point-max))
       (insert "Should not send")
       (cl-letf (((symbol-function 'chat-code--send-to-llm)
                  (lambda ()
                    (setq sent t))))
         (chat-code-send-message))
       (should-not sent)
       (should-not (chat-session-messages (chat-code-session-base-session session)))))))

(ert-deftest chat-code-from-chat-reuses-current-chat-session ()
  "Test converting from chat mode reuses the currently bound base session."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (base-session (chat-session-create "Chat Session" 'kimi))
          opened-session)
     (with-temp-buffer
       (setq-local chat--current-session base-session)
       (cl-letf (((symbol-function 'chat-code--open-session)
                  (lambda (session)
                    (setq opened-session session))))
         (chat-code-from-chat))
       (should (chat-code-session-p opened-session))
       (should (eq (chat-code-session-base-session opened-session)
                   base-session))
       (should (string= (chat-session-name
                         (chat-code-session-base-session opened-session))
                        "Chat Session"))))))

(ert-deftest chat-code-regenerate-last-response-replays-last-user-turn ()
  "Test code mode regenerates by dropping the trailing assistant turn."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Replay Session" temp-dir))
          (base-session (chat-code-session-base-session session))
          replayed)
     (chat-session-add-message
      base-session
      (make-chat-message :id "u1" :role :user :content "Fix bug" :timestamp (current-time)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "a1" :role :assistant :content "Old fix" :timestamp (current-time)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (cl-letf (((symbol-function 'chat-code--send-to-llm)
                  (lambda ()
                    (setq replayed t))))
         (chat-code-regenerate-last-response))
       (should replayed)
       (should (equal (mapcar #'chat-message-id (chat-session-messages base-session))
                      '("u1")))
       (goto-char (point-min))
       (should (search-forward "Fix bug" nil t))
       (should-not (search-forward "Old fix" nil t))))))

(ert-deftest chat-code-edit-last-user-message-restores-input-and-truncates-history ()
  "Test code mode restores the last user turn into the input area."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Edit Session" temp-dir))
          (base-session (chat-code-session-base-session session)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "u1" :role :user :content "First" :timestamp (current-time)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "a1" :role :assistant :content "Answer 1" :timestamp (current-time)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "u2" :role :user :content "Refine this" :timestamp (current-time)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "a2" :role :assistant :content "Answer 2" :timestamp (current-time)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (chat-code-edit-last-user-message)
       (should (equal (mapcar #'chat-message-id (chat-session-messages base-session))
                      '("u1" "a1")))
       (should (string= (buffer-substring-no-properties
                         (marker-position chat-code--input-marker)
                         (point-max))
                        "Refine this"))
       (goto-char (point-min))
       (should (search-forward "Answer 1" nil t))
       (should-not (search-forward "Answer 2" nil t))))))

(ert-deftest chat-code-quote-region-inserts-structured-reference ()
  "Test quoting a region inserts file, line, and code context into the input."
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message")
             (set-mark (line-beginning-position))
             (goto-char (line-end-position))
             (activate-mark)
             (chat-code-quote-region)
             (with-current-buffer (chat-code--buffer-name chat-code--current-session)
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-code--input-marker)
                              (point-max))))
                 (should (string-match-p "Question about this code:" quoted))
                 (should (string-match-p "File: " quoted))
                 (should (string-match-p "Lines: " quoted))
                 (should (string-match-p "Kind: region" quoted))
                 (should (string-match-p "message" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-ask-region-sends-structured-reference ()
  "Test asking about a region sends a structured quoted message."
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message")
             (set-mark (line-beginning-position))
             (goto-char (line-end-position))
             (activate-mark)
             (cl-letf (((symbol-function 'chat-code-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-code--input-marker)
                                 (point-max))))))
               (chat-code-ask-region "Why is this call here?"))
             (should (string-match-p "Question about this code:" sent-content))
             (should (string-match-p "Why is this call here\\?" sent-content))
             (should (string-match-p "Kind: region" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-quote-defun-inserts-structured-reference ()
  "Test quoting the defun at point inserts file, line, and code context."
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n\n(defun beta ()\n  (message \"b\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (chat-code-quote-defun)
             (with-current-buffer (chat-code--buffer-name chat-code--current-session)
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-code--input-marker)
                              (point-max))))
                 (should (string-match-p "Question about this code:" quoted))
                 (should (string-match-p "File: " quoted))
                 (should (string-match-p "Lines: 4-5" quoted))
                 (should (string-match-p "Kind: defun" quoted))
                 (should (string-match-p "defun beta" quoted))
                 (should-not (string-match-p "defun alpha" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-ask-defun-sends-structured-reference ()
  "Test asking about the defun at point sends a structured quoted message."
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n\n(defun beta ()\n  (message \"b\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (cl-letf (((symbol-function 'chat-code-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-code--input-marker)
                                 (point-max))))))
               (chat-code-ask-defun "Why does beta log?"))
             (should (string-match-p "Question about this code:" sent-content))
             (should (string-match-p "Why does beta log\\?" sent-content))
             (should (string-match-p "Kind: defun" sent-content))
             (should (string-match-p "defun beta" sent-content))
             (should-not (string-match-p "defun alpha" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-quote-near-point-inserts-structured-reference ()
  "Test quoting nearby context inserts bounded file, line, and code context."
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\")\n  (message \"aa\"))\n\n(defun beta ()\n  (message \"b\")\n  (message \"bb\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (chat-code-quote-near-point)
             (with-current-buffer (chat-code--buffer-name chat-code--current-session)
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-code--input-marker)
                              (point-max))))
                 (should (string-match-p "Question about this code:" quoted))
                 (should (string-match-p "File: " quoted))
                 (should (string-match-p "Kind: near-point" quoted))
                 (should (string-match-p "defun beta" quoted))
                 (should (string-match-p "message \"b\"" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-ask-near-point-sends-structured-reference ()
  "Test asking about nearby context sends a structured quoted message."
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\")\n  (message \"aa\"))\n\n(defun beta ()\n  (message \"b\")\n  (message \"bb\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (cl-letf (((symbol-function 'chat-code-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-code--input-marker)
                                 (point-max))))))
               (chat-code-ask-near-point "What matters around here?"))
             (should (string-match-p "Question about this code:" sent-content))
             (should (string-match-p "What matters around here\\?" sent-content))
             (should (string-match-p "Kind: near-point" sent-content))
             (should (string-match-p "defun beta" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-quote-current-file-inserts-structured-reference ()
  "Test quoting the current file inserts file-wide structured context."
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (chat-code-quote-current-file)
             (with-current-buffer (chat-code--buffer-name chat-code--current-session)
               (let ((quoted (buffer-substring-no-properties
                              (marker-position chat-code--input-marker)
                              (point-max))))
                 (should (string-match-p "Question about this code:" quoted))
                 (should (string-match-p "Lines: 1-2" quoted))
                 (should (string-match-p "Kind: current-file" quoted))
                 (should (string-match-p "defun alpha" quoted)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-ask-current-file-sends-structured-reference ()
  "Test asking about the current file sends a structured quoted message."
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir))
         sent-content)
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (cl-letf (((symbol-function 'chat-code-send-message)
                        (lambda ()
                          (setq sent-content
                                (buffer-substring-no-properties
                                 (marker-position chat-code--input-marker)
                                 (point-max))))))
               (chat-code-ask-current-file "How is this file structured?"))
             (should (string-match-p "Question about this code:" sent-content))
             (should (string-match-p "Kind: current-file" sent-content))
             (should (string-match-p "How is this file structured\\?" sent-content))
             (should (string-match-p "defun alpha" sent-content)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-quote-current-file-propagates-oversized-file-error ()
  "Test quoting the current file respects the shared size guard."
  (chat-test-with-temp-dir
   (let ((chat-reading-current-file-max-lines 1)
         (source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-code-quote-current-file) :type 'user-error)
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-code-prepare-reading-session-reuses-current-session ()
  "Test reading workflow commands reuse the active code session."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Reuse Session" temp-dir)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (should (eq (chat-code--prepare-reading-session) session))))))

(ert-deftest chat-code-mode-map-includes-reading-and-session-shortcuts ()
  "Test code mode keymap exposes reading and session workflow shortcuts."
  (should (eq (lookup-key chat-code-mode-map (kbd "C-c C-e")) 'chat-code-edit-last-user-message))
  (should (eq (lookup-key chat-code-mode-map (kbd "C-c C-g")) 'chat-code-regenerate-last-response))
  (should (eq (lookup-key chat-code-mode-map (kbd "C-c C-h")) 'chat-code-show-help))
  (should (eq (lookup-key chat-code-mode-map (kbd "<S-return>")) 'chat-code-insert-newline))
  (should (eq (lookup-key chat-code-mode-map (kbd "C-c C-q")) 'chat-code-quote-region))
  (should (eq (lookup-key chat-code-mode-map (kbd "C-c C-SPC")) 'chat-code-ask-region))
  (should (fboundp 'chat-code-quote-defun))
  (should (fboundp 'chat-code-ask-defun))
  (should (fboundp 'chat-code-quote-near-point))
  (should (fboundp 'chat-code-ask-near-point))
  (should (fboundp 'chat-code-quote-current-file))
  (should (fboundp 'chat-code-ask-current-file)))

(ert-deftest chat-code-show-help-command-is-bound ()
  "Test code mode exposes a native help command."
  (should (commandp 'chat-code-show-help))
  (should (eq (lookup-key chat-code-mode-map (kbd "C-c C-h")) 'chat-code-show-help)))

(ert-deftest chat-code-show-help-renders-reading-workflow-section ()
  "Test code-mode help renders the key reading and session commands."
  (chat-code-show-help)
  (with-current-buffer "*Chat Code Help*"
    (should (string-match-p "Reading Workflow:" (buffer-string)))
    (should (string-match-p "Documentation Workflow:" (buffer-string)))
    (should (string-match-p "C-c C-f" (buffer-string)))
    (should (string-match-p "S-RET" (buffer-string)))
    (should (string-match-p "chat-code-quote-region" (buffer-string)))
    (should (string-match-p "chat-code-ask-current-file" (buffer-string)))
    (should (string-match-p "section by section" (buffer-string)))
    (should (string-match-p "C-c C-e" (buffer-string)))
    (should (string-match-p "C-c C-g" (buffer-string)))))

(ert-deftest chat-code-insert-newline-keeps-input-open ()
  "Test S-RET style newline insertion does not send the message."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Newline Session" temp-dir))
          sent)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (goto-char (point-max))
       (insert "first line")
       (cl-letf (((symbol-function 'chat-code--process-message)
                  (lambda ()
                    (setq sent t))))
         (chat-code-insert-newline))
       (insert "second line")
       (should-not sent)
       (should (string= (buffer-substring-no-properties
                         (marker-position chat-code--input-marker)
                         (point-max))
                        "first line\nsecond line"))))))

(ert-deftest chat-code-path-completion-at-point-detects-relative-path-token ()
  "Test input completion returns file candidates for relative path fragments."
  (chat-test-with-temp-dir
   (let* ((project-root temp-dir)
          (doc-dir (expand-file-name "docs" project-root))
          (session (chat-code-session-create "Path Session" project-root)))
     (make-directory doc-dir t)
     (with-temp-file (expand-file-name "guide.md" doc-dir)
       (insert "hello"))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (goto-char (point-max))
       (insert "See docs/gu")
       (let* ((capf (chat-code--path-completion-at-point))
              (start (nth 0 capf))
              (end (nth 1 capf))
              (table (nth 2 capf))
              (candidates (all-completions "docs/gu" table)))
         (should capf)
         (should (string= (buffer-substring-no-properties start end) "docs/gu"))
         (should (member "docs/guide.md" candidates)))))))

(ert-deftest chat-code-auto-path-completion-only-triggers-for-path-like-input ()
  "Test post-self-insert auto completion only runs for path-like tokens."
  (chat-test-with-temp-dir
   (let* ((session (chat-code-session-create "Auto Path Session" temp-dir))
          path-triggered
          plain-triggered)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (goto-char (point-max))
       (insert "docs/gu")
       (let ((last-command-event ?u))
         (cl-letf (((symbol-function 'completion-at-point)
                    (lambda ()
                      (setq path-triggered t))))
           (chat-code--maybe-complete-path-after-insert)))
       (delete-region (marker-position chat-code--input-marker) (point-max))
       (goto-char (point-max))
       (insert "plainword")
       (let ((last-command-event ?d))
         (cl-letf (((symbol-function 'completion-at-point)
                    (lambda ()
                      (setq plain-triggered t))))
           (chat-code--maybe-complete-path-after-insert))))
     (should path-triggered)
     (should-not plain-triggered))))

(ert-deftest chat-code-show-help-enables-view-mode ()
  "Test code-mode help uses view-mode like chat help."
  (chat-code-show-help)
  (with-current-buffer "*Chat Code Help*"
    (should view-mode)))

(ert-deftest chat-code-start-agent-run-uses-stream-transport ()
  "Test code mode streaming goes through the agent stream transport."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Stream Session" temp-dir))
          captured-config)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (cl-letf (((symbol-function 'chat-agent-start)
                    (lambda (config)
                      (setq captured-config config)
                      nil)))
           (chat-code--start-agent-run
            'stream 'kimi '(message-a message-b) content-start)))
       (should (eq (plist-get captured-config :transport) 'stream))
       (should (equal (plist-get captured-config :messages)
                      '(message-a message-b)))
       (should (plist-get captured-config :on-event))
       (should (= (plist-get captured-config :max-steps)
                  chat-code-tool-loop-max-steps))))))

(ert-deftest chat-code-agent-run-persists-assistant-message ()
  "Test code mode stores assistant replies and keeps the prompt ready."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Reply Session" temp-dir)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (cl-letf (((symbol-function 'chat-llm-request-async)
                    (lambda (_model _messages success _error _options)
                      (funcall success '(:content "Here is the answer."
                                         :raw-request "{}"
                                         :raw-response "{}"))
                      'request-handle)))
           (chat-code--start-agent-run 'sync 'kimi '(message-a) content-start)))
       (should-not (chat-agent-active-p chat-code--active-agent-run))
       (should (= (length (chat-session-messages
                           (chat-code-session-base-session session)))
                  1))
       (let ((saved (car (chat-session-messages
                          (chat-code-session-base-session session)))))
         (should (eq (chat-message-role saved) :assistant))
         (should (string= (chat-message-content saved) "Here is the answer.")))
       (should (eq chat-code--status-state 'success))
       (should (string= chat-code--status-detail "Completed"))
       (should (= (marker-position chat-code--input-marker) (point-max)))
       (goto-char (point-min))
       (should (search-forward "Here is the answer." nil t))))))

(ert-deftest chat-code-send-to-llm-builds-json-tool-prompt ()
  "Test code mode reuses the JSON tool-calling prompt contract."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Prompt Session" temp-dir))
          captured-messages)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((chat-code-use-streaming nil))
         (cl-letf (((symbol-function 'chat-context-code-build)
                    (lambda (_session)
                      (make-chat-code-context :files nil :sources nil :symbols nil :total-tokens 0)))
                   ((symbol-function 'chat-context-code-to-string)
                    (lambda (_context) "Context body"))
                   ((symbol-function 'chat-code-lsp-available-p)
                    (lambda () nil))
                   ((symbol-function 'chat-code--start-agent-run)
                    (lambda (transport _model messages _content-start)
                      (setq captured-transport transport)
                      (setq captured-messages messages))))
           (chat-code--send-to-llm)))
       (should captured-messages)
       (let ((system-message (car captured-messages)))
         (should (eq (chat-message-role system-message) :system))
         (should (string-match-p "\"function_call\"" (chat-message-content system-message)))
         (should (string-match-p "Use this exact shape" (chat-message-content system-message)))
         (should (string-match-p "Non-negotiable rules:" (chat-message-content system-message)))
         (should (string-match-p "Obey project instruction files" (chat-message-content system-message)))
         (should (string-match-p "Programming best practices:" (chat-message-content system-message)))
         (should (string-match-p "trust the implementation" (chat-message-content system-message)))
         (should (string-match-p "Editing protocol:" (chat-message-content system-message)))
         (should (string-match-p "Prefer apply_patch for existing-file edits" (chat-message-content system-message)))
         (should (string-match-p "Operational guardrails" (chat-message-content system-message)))
         (should (string-match-p "Active project root" (chat-message-content system-message)))
         (should (string-match-p "If the user asked to create or change files" (chat-message-content system-message))))
       (should (eq captured-transport 'sync))
       (should (eq chat-code--status-state 'running))
       (should (string= chat-code--status-detail "Waiting for model"))))))

(ert-deftest chat-code-send-to-llm-summarizes-older-history-before-request ()
  "Test code mode compresses older history with a summary message."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "History Session" temp-dir))
          (base-session (chat-code-session-base-session session))
          captured-messages)
     (chat-session-add-message
      base-session
      (make-chat-message :id "u-1" :role :user :content "first task details" :timestamp (current-time)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "a-1" :role :assistant :content (make-string 240 ?a) :timestamp (current-time)))
     (chat-session-add-message
      base-session
      (make-chat-message :id "u-2" :role :user :content "latest question" :timestamp (current-time)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((chat-code-use-streaming nil)
             (chat-code-history-max-tokens 40))
         (cl-letf (((symbol-function 'chat-context-code-build)
                    (lambda (_session)
                      (make-chat-code-context :files nil :sources nil :symbols nil :total-tokens 0)))
                   ((symbol-function 'chat-context-code-to-string)
                    (lambda (_context) "Context body"))
                   ((symbol-function 'chat-code-lsp-available-p)
                    (lambda () nil))
                   ((symbol-function 'chat-code--start-agent-run)
                    (lambda (transport _model messages _content-start)
                      (setq captured-transport transport)
                      (setq captured-messages messages))))
           (chat-code--send-to-llm)))
       (should captured-messages)
       (should (eq (chat-message-role (car captured-messages)) :system))
       (should (seq-find (lambda (msg)
                           (and (eq (chat-message-role msg) :system)
                                (string-match-p "Earlier conversation summary"
                                                (chat-message-content msg))))
                         captured-messages))
       (should (string= (chat-message-content (car (last captured-messages)))
                        "latest question"))))))

(ert-deftest chat-code-tool-followup-summarizes-structured-results ()
  "Test tool follow-up messages carry real tool result content.
Structured results are fed back verbatim up to
`chat-tool-caller-result-max-chars', so the model can actually see
file contents instead of only a short summary."
  (let* ((tool-calls '((:name "files_read"
                       :arguments (("path" . "/tmp/demo.el")))))
         (tool-results '("(:path \"/tmp/demo.el\" :content \"(message \\\"hello\\\")\\n(second-line)\" :size 24)"))
         (message (chat-code--tool-followup-message tool-calls tool-results)))
    (should (string-match-p (regexp-quote "(message \\\"hello\\\")") message))
    (should (string-match-p (regexp-quote "(second-line)") message))))

(ert-deftest chat-code-tool-summary-keeps-short-directory-lists-readable ()
  "Test short directory listings keep all visible file names."
  (let* ((result (mapcar (lambda (name)
                           (list :name name :path (concat "/tmp/" name) :type 'file))
                         '("a.md" "b.md" "c.md" "d.md" "e.md")))
         (summary (chat-code--tool-result-summary (format "%S" result))))
    (should (string-match-p "a.md" summary))
    (should (string-match-p "e.md" summary))))

(ert-deftest chat-code-tool-summary-shows-files-find-matches ()
  "Test files_find summaries include matched file names."
  (let* ((result '(:directory "/tmp/specs"
                  :pattern "voice|image"
                  :matches ("/tmp/specs/a.md" "/tmp/specs/b.md" "/tmp/specs/c.md")
                  :match-count 3))
         (summary (chat-code--tool-result-summary (format "%S" result))))
    (should (string-match-p "3 matches" summary))
    (should (string-match-p "a.md" summary))
    (should (string-match-p "c.md" summary))))

(ert-deftest chat-code-tool-summary-shows-read-lines-content ()
  "Test files_read_lines summaries include visible line text."
  (let* ((result '(:path "/tmp/cmd/msg.go"
                  :lines ("package cmd" "func main() {}")
                  :start 1
                  :end 2))
         (summary (chat-code--tool-result-summary (format "%S" result))))
    (should (string-match-p "msg.go" summary))
    (should (string-match-p "package cmd" summary))))

(ert-deftest chat-code-agent-run-resolves-json-tool-call ()
  "Test code mode executes JSON tool calls and stores the follow-up answer."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Tool Session" temp-dir))
          (chat-tool-forge-directory temp-dir)
          (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'demo-tool
       :name "Demo Tool"
       :description "Echo"
       :language 'elisp
       :parameters '((:name "input" :type "string" :required t))
       :compiled-function (lambda (input) (format "ran:%s" input))
       :is-active t
       :usage-count 0))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator))
             (responses (list "{\"function_call\":{\"name\":\"demo-tool\",\"arguments\":{\"input\":\"hello\"}}}"
                              "Tool finished successfully.")))
         (cl-letf (((symbol-function 'chat-approval-request-tool-call)
                    (lambda (_tool _call &optional _session _observer) t))
                   ((symbol-function 'chat-llm-request-async)
                    (lambda (_model _messages success _error _options)
                      (funcall success (list :content (pop responses)
                                             :raw-request "{}"
                                             :raw-response "{}"))
                      'request-handle)))
           (chat-code--start-agent-run
            'sync
            'kimi-code
            (list (make-chat-message
                   :id "user-1"
                   :role :user
                   :content "Run a tool"
                   :timestamp (current-time)))
            content-start)))
       (let ((saved (car (last (chat-session-messages
                                (chat-code-session-base-session session))))))
         (should (string= (chat-message-content saved) "Tool finished successfully."))
         (should (equal (chat-message-tool-results saved) '("ran:hello")))
         (should (equal (plist-get (car (chat-message-tool-calls saved)) :name)
                        "demo-tool"))
         (goto-char (point-min))
         (should (search-forward "Tool finished successfully." nil t)))))))

(ert-deftest chat-code-start-agent-run-uses-followup-timeout ()
  "Test code mode passes the follow-up timeout to the agent kernel."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Timeout Session" temp-dir nil))
         captured-config)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (cl-letf (((symbol-function 'chat-agent-start)
                    (lambda (config)
                      (setq captured-config config)
                      nil)))
           (chat-code--start-agent-run 'sync 'kimi-code '(message-a) content-start)))
       (should (equal (plist-get captured-config :followup-request-options)
                      (list :timeout chat-code-tool-followup-timeout)))
       (should (= (plist-get (plist-get captured-config :request-options)
                             :timeout)
                  chat-code-request-timeout))))))

(ert-deftest chat-code-display-processed-response-hides-tool-json-at-loop-limit ()
  "Test code mode hides raw tool JSON when the tool loop hits its safety limit."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Loop Limit" temp-dir nil)))
     (with-temp-buffer
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (chat-code--display-processed-response
          '(:content "{\"function_call\":{\"name\":\"shell_execute\",\"arguments\":{\"command\":\"pwd\"}}}"
            :tool-calls ((:name "shell_execute"
                          :arguments (("command" . "pwd"))))
            :tool-results ("/tmp/project")
            :tool-loop-limit-reached t)
          content-start))
       (goto-char (point-min))
       (should-not (search-forward "{\"function_call\"" nil t))
       (should (search-forward "Tool loop stopped after reaching the safety limit." nil t))))))

(ert-deftest chat-code-handle-llm-error-updates-status ()
  "Test code mode sets failed status on request errors."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Error Session" temp-dir nil)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (chat-code--handle-llm-error "boom")
       (should (eq chat-code--status-state 'failed))
       (should (string= chat-code--status-detail "boom"))))))

(ert-deftest chat-code-cancel-updates-status ()
  "Test code mode sets cancelled status when the user stops a request."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Cancel Session" temp-dir nil)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (setq-local chat-code--active-request-handle 'request-handle)
       (cl-letf (((symbol-function 'chat-llm-cancel-request)
                  (lambda (_handle) t)))
         (chat-code-cancel))
       (should (eq chat-code--status-state 'cancelled))
       (should (string= chat-code--status-detail "Cancelled by user"))))))

(ert-deftest chat-code-start-agent-run-attaches-request-diagnostics ()
  "Test code mode passes a request id into agent run requests."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Diag Session" temp-dir nil))
         captured-options)
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (setq-local chat-code--current-request-id "req-code")
       (let ((content-start (chat-code--show-assistant-indicator)))
         (cl-letf (((symbol-function 'chat-llm-request-async)
                    (lambda (_model _messages _success _error options)
                      (setq captured-options options)
                      'request-handle)))
           (chat-code--start-agent-run 'sync 'kimi '(message-a) content-start)))
       (should (equal (plist-get captured-options :request-id) "req-code"))))))

(ert-deftest chat-code-show-current-request-status-opens-diagnostics-buffer ()
  "Test the code-mode status command displays the current request diagnostics."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        shown-buffer)
    (puthash "req-code"
             (make-chat-request-trace
              :id "req-code"
              :mode 'code
              :provider 'kimi-code
              :model 'kimi-code
              :phase 'waiting
              :started-at (current-time)
              :updated-at (current-time))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (chat-code-mode)
      (setq-local chat-code--current-request-id "req-code")
      (cl-letf (((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _args)
                   (setq shown-buffer buffer)
                   buffer)))
        (chat-code-show-current-request-status)
        (should (bufferp shown-buffer))
        (with-current-buffer shown-buffer
          (should (search-forward "Request: req-code" nil t)))))))

(ert-deftest chat-code-toggle-request-panel-opens-panel-buffer ()
  "Test code mode can toggle the structured request panel."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        shown-buffer)
    (puthash "req-code"
             (make-chat-request-trace
              :id "req-code"
              :mode 'code
              :provider 'kimi-code
              :model 'kimi-code
              :phase 'waiting
              :started-at (current-time)
              :updated-at (current-time))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (chat-code-mode)
      (setq-local chat-code--current-request-id "req-code")
      (cl-letf (((symbol-function 'display-buffer-in-side-window)
                 (lambda (buffer _alist)
                   (setq shown-buffer buffer)
                   buffer)))
        (chat-code-toggle-request-panel)
        (should (bufferp shown-buffer))
        (with-current-buffer shown-buffer
          (should (search-forward "Request: req-code" nil t)))))))

(ert-deftest chat-code-request-live-detail-reflects-stream-chunks ()
  "Test code mode builds a useful live label from stream diagnostics."
  (let* ((now (current-time))
         (label (chat-code--request-live-detail
                 (list :phase 'streaming
                       :stream-chunk-count 5
                       :last-chunk-at now))))
    (should (string-match-p "Receiving response (5 chunks" label))))

(ert-deftest chat-code-handle-request-diagnostics-update-refreshes-status ()
  "Test diagnostics updates refresh code-mode live status."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal)))
    (puthash "req-code"
             (make-chat-request-trace
              :id "req-code"
              :mode 'code
              :provider 'kimi-code
              :model 'kimi-code
              :phase 'streaming
              :started-at (current-time)
              :updated-at (current-time)
              :stream-chunk-count 3
              :last-chunk-at (current-time))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (chat-code-mode)
      (setq-local chat-code--current-request-id "req-code")
      (setq-local chat-code--status-state 'running)
      (setq-local chat-code--status-detail "Waiting")
      (chat-code--handle-request-diagnostics-update "req-code" nil nil)
      (should (string-match-p "Receiving response (3 chunks" chat-code--status-detail)))))

(ert-deftest chat-code-handle-request-diagnostics-update-refreshes-live-transcript ()
  "Test diagnostics updates refresh the transient live narrative in the transcript."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal)))
    (puthash "req-code"
             (make-chat-request-trace
              :id "req-code"
              :mode 'code
              :provider 'kimi-code
              :model 'kimi-code
              :phase 'tool-loop
              :started-at (current-time)
              :updated-at (current-time)
              :last-event '(:type tool-loop-step :summary "Resolving tool step 1"))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (chat-code-mode)
      (insert "Assistant:\n")
      (setq-local chat-code--messages-end (point-max-marker))
      (let ((content-start (point-marker)))
        (setq-local chat-code--live-response-start content-start)
        (setq-local chat-code--live-response-content "")
        (setq-local chat-code--current-request-id "req-code")
        (setq-local chat-code--status-state 'running)
        (chat-code--handle-request-diagnostics-update "req-code" nil nil)
        (goto-char content-start)
        (should (search-forward "[Live] Resolving tool step 1" nil t))))))

(ert-deftest chat-code-track-tool-targets-promotes-single-file-focus ()
  "Test tool activity promotes a single file target into the current focus."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (target-file (expand-file-name "docs/spec.md" temp-dir))
          (session (chat-code-session-create "Track Session" temp-dir)))
     (make-directory (file-name-directory target-file) t)
     (with-temp-file target-file
       (insert "# Spec\n"))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--track-tool-targets
        `((:type tool-call
           :tool "files_read"
           :arguments (("path" . ,target-file)))))
       (should (equal (chat-code-session-focus-file session)
                      (file-truename target-file)))
       (should (member (file-truename target-file)
                       (chat-code-session-context-files session)))))))

(ert-deftest chat-code-render-response-state-follows-live-output-near-input ()
  "Test code mode auto-follows rendered output when the window is at the live edge."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (chat-code-mode)
      (setq-local chat-code--messages-end (point-max-marker))
      (setq-local chat-code--input-marker (point-max-marker))
      (insert "placeholder")
      (setq chat-code--messages-end (copy-marker (point)))
      (insert "\n> ")
      (setq chat-code--input-marker (point-marker))
      (goto-char (marker-position chat-code--input-marker))
      (chat-code--render-response-state (point-min) "Streaming body" nil)
      (should (= (point) (marker-position chat-code--messages-end))))))

(ert-deftest chat-code-render-response-state-announces-approval-shortcuts ()
  "Test code mode surfaces approval shortcuts in minibuffer feedback."
  (with-temp-buffer
    (chat-code-mode)
    (let ((chat-code--messages-end (point-max-marker))
          (chat-code--input-marker (point-max-marker)))
      (should
       (string-match-p
        "Approval pending"
        (chat-code--maybe-announce-approval-shortcuts
         '((:type approval-pending
            :index 1
            :tool "shell_execute"
            :actions ("C-c C-a once"
                      "C-c C-s session"
                      "C-c C-t tool"
                      "C-c C-c command"
                      "C-c C-d deny"))))))
      (should-not
       (chat-code--maybe-announce-approval-shortcuts
       '((:type approval-pending
           :index 1
           :tool "shell_execute"
           :actions ("C-c C-a once"
                     "C-c C-s session"
                     "C-c C-t tool"
                     "C-c C-c command"
                     "C-c C-d deny"))))))))

(ert-deftest chat-code-header-and-mode-line-show-pending-approval ()
  "Test code mode header and mode line reflect pending approvals."
  (with-temp-buffer
    (chat-code-mode)
    (setq-local chat-code--status-state 'running)
    (setq-local chat-code--status-detail "Waiting for model")
    (setq-local chat-code--request-tool-events
                '((:type approval-pending
                   :index 1
                   :tool "shell_execute"
                   :actions ("C-c C-a once"
                             "C-c C-s session"
                             "C-c C-t tool"
                             "C-c C-c command"
                             "C-c C-d deny"))))
    (let ((header (chat-code--header-line))
          (mode (chat-code--mode-line-status)))
      (should (string-match-p "Approval Pending" header))
      (should (string-match-p "shell_execute" header))
      (should (string-match-p "APPROVAL" mode)))))

(ert-deftest chat-code-header-and-mode-line-ignore-nonblocking-events ()
  "Test code mode status surfaces ignore non-blocking tool events."
  (with-temp-buffer
    (chat-code-mode)
    (setq-local chat-code--status-state 'running)
    (setq-local chat-code--status-detail "Waiting for model")
    (setq-local chat-code--request-tool-events
                '((:type thinking :summary "Scanning")
                  (:type tool-call :index 1 :tool "files_find")))
    (let ((header (chat-code--header-line))
          (mode (chat-code--mode-line-status)))
      (should-not (string-match-p "Approval Pending" header))
      (should-not (string-match-p "APPROVAL" mode)))))

(ert-deftest chat-code-tool-loop-default-is-production-sized ()
  "Test code mode tool loop default is production sized."
  (should (= chat-code-tool-loop-max-steps 100)))

(ert-deftest chat-code-tool-result-lines-keep-real-content ()
  "Test follow-up lines carry real multi-line tool results."
  (let ((lines (chat-code--tool-result-lines
                '((:name "files_read" :arguments (("path" . "/tmp/x"))))
                (list "line one\nline two\nline three"))))
    (should (string-match-p "line one\nline two" (car lines)))))

(ert-deftest chat-code-tool-result-lines-truncate-long-results ()
  "Test oversized tool results are truncated with an omission marker."
  (let* ((chat-tool-caller-result-max-chars 10)
         (lines (chat-code--tool-result-lines
                 '((:name "files_read" :arguments (("path" . "/tmp/x"))))
                 (list (make-string 40 ?y)))))
    (should (string-match-p "truncated, 30 chars omitted" (car lines)))))

(ert-deftest chat-code-fence-safe-prefix-length-tracks-open-fences ()
  "Test the fence safe prefix covers only complete fenced regions."
  (should (= (chat-code--fence-safe-prefix-length "no fences")
             (length "no fences")))
  (let ((balanced "before\n```py\nx\n```\nafter"))
    (should (= (chat-code--fence-safe-prefix-length balanced)
               (length balanced))))
  (let* ((unclosed "pre\n```\nmid")
         (last-close (length "pre\n```")))
    ;; One fence is open, so the safe prefix ends at its opening.
    (should (= (chat-code--fence-safe-prefix-length unclosed) 0)))
  (let* ((text "```\na\n```\ntail\n```\nopen")
         (expected (length "```\na\n```")))
    (should (= (chat-code--fence-safe-prefix-length text) expected))))

(ert-deftest chat-code-render-response-state-appends-delta-on-growth ()
  "Test growing content reuses the slot and appends only the delta."
  (chat-test-with-temp-dir
   (let ((session (chat-code-session-create "Render" temp-dir nil)))
     (with-temp-buffer
       (chat-code-mode)
       (setq-local chat-code--current-session session)
       (chat-code--setup-buffer session)
       (let ((content-start (chat-code--show-assistant-indicator)))
         (chat-code--render-response-state content-start "abc" nil)
         (chat-code--render-response-state content-start "abcdef" nil)
         (should (string-match-p "abcdef" (buffer-string)))
         (should-not (string-match-p "abcabcdef" (buffer-string)))
         ;; Shrinking content falls back to a full replace.
         (chat-code--render-response-state content-start "ab" nil)
         (should (string-match-p "ab\n\n" (buffer-string))))))))

(provide 'test-chat-code)
;;; test-chat-code.el ends here
