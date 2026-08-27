;;; test-chat-code.el --- Tests for code capability -*- lexical-binding: t -*-
;; Copyright (C) 2026 chat.el contributors
;; Author: chat.el contributors
;; Keywords: tests
;; This file is not part of GNU Emacs.
;;; Commentary:
;; Tests for code capability: what a session gains when it is pointed at
;; a project, and what stays out of the way when it is not.
;;
;; The request, rendering, status and keymap behaviour a code session
;; relies on is covered once, in test-chat-ui.el and test-chat.el, because
;; there is now one implementation of each.  This file used to re-test all
;; of it through a second surface; those tests passed while the two copies
;; drifted, which is the argument against having had them.
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-code)
(require 'chat-ui)
(require 'chat-request-diagnostics)

;; ------------------------------------------------------------------
;; Prompt priority
;; ------------------------------------------------------------------

(ert-deftest chat-code-highest-priority-rules-lead-the-system-prompt ()
  "Task discipline comes before persona and operational instructions."
  (let ((chat-code-highest-priority-rules '("OBJECTIVE-FIRST"))
        (chat-code-system-prompt "PERSONA"))
    (let ((prompt (chat-code--compose-system-prompt)))
      (should (string-prefix-p
               "Highest-priority task rules:\n- OBJECTIVE-FIRST\n\nPERSONA"
               prompt))
      (should (< (string-match "OBJECTIVE-FIRST" prompt)
                 (string-match "PERSONA" prompt)))
      (should (< (string-match "PERSONA" prompt)
                 (string-match "Non-negotiable rules:" prompt))))))

(ert-deftest chat-code-default-task-rules-reject-appeasement-and-retaliation ()
  "Objectivity is not implemented by becoming hostile in the other direction."
  (let ((text (string-join chat-code-highest-priority-rules "\n")))
    (should (string-match-p "Do not flatter" text))
    (should (string-match-p "State errors, contradictions" text))
    (should (string-match-p "do not retaliate" text))
    (should (string-match-p "clear, actionable instruction" text))))

;; ------------------------------------------------------------------
;; Capability is a session property
;; ------------------------------------------------------------------

(ert-deftest chat-code-from-chat-reuses-current-chat-session ()
  "Enabling capability from a chat buffer keeps the session it was on."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (base-session (chat-session-create "Chat Session" 'kimi))
          opened-session)
     (with-temp-buffer
       (setq-local chat--current-session base-session)
       (cl-letf (((symbol-function 'chat-code--open-session)
                  (lambda (session) (setq opened-session session))))
         (chat-code-from-chat))
       (should (chat-code-session-p opened-session))
       (should (eq opened-session base-session))
       (should (string= (chat-session-name opened-session) "Chat Session"))))))

(ert-deftest chat-code-enable-does-not-restart-a-conversation ()
  "Turning capability on keeps the session and its history.

`chat-code-from-chat' used to create a session and then overwrite its
contents with the existing one, which read as reuse and was a swap."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Ongoing" 'kimi)))
     (chat-session-add-message
      session (make-chat-message :id "u1" :role :user :content "hi"))
     (let ((same (chat-code-enable session temp-dir nil)))
       (should (eq same session))
       (should (chat-code-session-p session))
       (should (equal (mapcar #'chat-message-id
                              (chat-session-messages session))
                      '("u1")))))))

(ert-deftest chat-code-session-survives-being-saved-and-reopened ()
  "A code session reloads with its project context intact.

Code capability used to live in a wrapper struct that was never
serialized, so the more capable surface was the one that could not resume
a conversation. Putting it in session metadata is what fixes that."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Code: demo" "/tmp/proj/" nil)))
     (chat-session-save session)
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should loaded)
       (should (chat-code-session-p loaded))
       (should (equal (chat-code-session-project-root loaded) "/tmp/proj/"))
       (should (eq (chat-code-session-context-strategy loaded)
                   chat-code-default-strategy))))))

(ert-deftest chat-code-session-properties-keep-their-type-across-a-save ()
  "Metadata reads back as the type the code compares against.

JSON does not distinguish a symbol from a string or a list from an array,
so a strategy written as a symbol returns as a string after a save and
every `eq' against it silently stops matching."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (focus (expand-file-name "a.el" temp-dir))
          (session (chat-code-session-create "Code: types" temp-dir focus)))
     (chat-session-save session)
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (symbolp (chat-code-session-context-strategy loaded)))
       (should (eq (chat-code-session-context-strategy loaded)
                   (chat-code-session-context-strategy session)))
       (should (listp (chat-code-session-context-files loaded)))))))

(ert-deftest chat-code-session-appears-in-the-session-list ()
  "A code session is an ordinary session, so it lists like one."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Code: listed" temp-dir nil)))
     (chat-session-save session)
     (should (cl-find (chat-session-id session) (chat-session-list)
                      :key (lambda (entry)
                             (if (chat-session-p entry)
                                 (chat-session-id entry)
                               (cdr (assq 'id entry))))
                      :test #'equal)))))

(ert-deftest chat-code-focus-file-is-recorded-on-the-session ()
  "Focus and context files are session state, so they persist too."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (focus (expand-file-name "a.el" temp-dir))
          (session (chat-code-session-create "Code: focus" temp-dir focus)))
     (chat-session-save session)
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (equal (chat-code-session-focus-file loaded) focus))
       (should (member focus (chat-code-session-context-files loaded)))))))

(ert-deftest chat-code-session-property-has-a-callable-setter ()
  "Properties are writable by name, not only through `setf'.

The shared surface is loaded before this module, so a `setf' place here
would have to expand before its expander exists."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-code-session-create "Code: setter" temp-dir nil)))
     (chat-code-session-set-focus-file session "/tmp/x.el")
     (should (equal (chat-code-session-focus-file session) "/tmp/x.el"))
     (chat-code-session-set-context-files session '("/tmp/x.el" "/tmp/y.el"))
     (should (equal (chat-code-session-context-files session)
                    '("/tmp/x.el" "/tmp/y.el"))))))

;; ------------------------------------------------------------------
;; Capability on the one surface
;; ------------------------------------------------------------------

(ert-deftest chat-code-session-opens-on-the-one-surface ()
  "A code session opens as a chat buffer, with its context in the header.

It used to open its own buffer in its own major mode, which is what
forced a second copy of the request and rendering pipeline."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (focus (expand-file-name "main.el" temp-dir))
          (session (chat-code-session-create "Code: routed" temp-dir focus)))
     (with-temp-file focus (insert ";; main\n"))
     (unwind-protect
         (progn
           (chat-test-silently (chat--open-session session))
           (with-current-buffer (chat--buffer-name session)
             (should (derived-mode-p 'chat-mode))
             (should (eq chat--current-session session))
             (goto-char (point-min))
             (should (search-forward "Code:" nil t))
             (goto-char (point-min))
             (should (search-forward "Focus:" nil t))
             (should (search-forward "main.el" nil t))))
       (when (get-buffer (chat--buffer-name session))
         (kill-buffer (chat--buffer-name session)))))))

(ert-deftest chat-code-plain-session-shows-no-capability-header ()
  "A conversation without code capability says nothing about projects."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Plain" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (goto-char (point-min))
       (should-not (search-forward "Code:" nil t))
       (goto-char (point-min))
       (should-not (search-forward "Focus:" nil t))))))

(ert-deftest chat-code-tool-activity-moves-the-focus-of-a-code-session ()
  "What a run touches becomes the focus the next request carries."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (target-file (expand-file-name "docs/spec.md" temp-dir))
          (session (chat-code-session-create "Track Session" temp-dir)))
     (make-directory (file-name-directory target-file) t)
     (with-temp-file target-file (insert "# Spec\n"))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui--track-tool-targets
        `((:type tool-call
           :tool "files_read"
           :arguments (("path" . ,target-file)))))
       (should (equal (chat-code-session-focus-file session)
                      (file-truename target-file)))
       (should (member (file-truename target-file)
                       (chat-code-session-context-files session)))))))

(ert-deftest chat-code-tool-activity-leaves-a-plain-session-without-a-focus ()
  "A session with no code capability gains no focus file to carry."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (target-file (expand-file-name "spec.md" temp-dir))
          (session (chat-session-create "Plain Track" 'kimi)))
     (with-temp-file target-file (insert "# Spec\n"))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui--track-tool-targets
        `((:type tool-call
           :tool "files_read"
           :arguments (("path" . ,target-file)))))
       ;; The generic hint is still recorded; only the code state is not.
       (should (chat-ui--session-metadata-get
                :chat-ui-preferred-target-path))
       (should-not (chat-code-session-focus-file session))))))

;; ------------------------------------------------------------------
;; Proposed edits
;; ------------------------------------------------------------------

(defun chat-code-test--edit-reply (relative-file)
  "Return a reply proposing a rewrite of RELATIVE-FILE."
  (concat "Here you go.\n\n```code-edit\n"
          (json-encode
           `((type . "rewrite")
             (file . ,relative-file)
             (description . "Rewrite file")
             (new_content . "(new)\n")))
          "\n```\n"))

(ert-deftest chat-code-a-code-session-is-offered-the-edit-a-reply-proposes ()
  "An edit block in a reply becomes a proposal, not just text."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (target (expand-file-name "demo.el" temp-dir))
          (session (chat-code-session-create "Edit Offer" temp-dir target)))
     (with-temp-file target (insert "(old)\n"))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (let ((content-start (copy-marker chat-ui--messages-end)))
         (chat-ui--finalize-response
          session "m1" (current-buffer) content-start
          (list :content (chat-code-test--edit-reply "demo.el"))))
       (should chat-code--pending-edit)
       (should (equal (chat-edit-file chat-code--pending-edit) target))))))

(ert-deftest chat-code-a-plain-session-is-not-offered-an-edit ()
  "The same reply in a plain conversation stays ordinary text.

Nothing in a session without code capability should start proposing to
write to files, and the reply itself must not disappear."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (target (expand-file-name "demo.el" temp-dir))
          (session (chat-session-create "No Edit" 'kimi)))
     (with-temp-file target (insert "(old)\n"))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (let ((content-start (copy-marker chat-ui--messages-end)))
         (chat-ui--finalize-response
          session "m1" (current-buffer) content-start
          (list :content (chat-code-test--edit-reply "demo.el"))))
       (should-not chat-code--pending-edit)
       (goto-char (point-min))
       (should (search-forward "Here you go." nil t))))))

;; ------------------------------------------------------------------
;; Budgets
;; ------------------------------------------------------------------

(ert-deftest chat-code-tool-loop-default-is-production-sized ()
  "Code capability defers to the global step budget."
  (should-not chat-code-tool-loop-max-steps)
  (should (>= chat-agent-max-steps 300)))

;;; test-chat-code.el ends here
