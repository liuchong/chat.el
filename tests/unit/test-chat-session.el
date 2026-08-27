;;; test-chat-session.el --- Tests for chat-session.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat-session.el session management functionality.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'cl-lib)
(require 'chat-session-tree)

;; Test session structure
(ert-deftest chat-session-structure-test ()
  "Test that chat-session struct is defined correctly."
  (skip-unless (featurep 'chat-session))
  (let ((session (make-chat-session
                  :id "test-id"
                  :name "test-session"
                  :model-id 'gpt-4o)))
    (should (chat-session-p session))
    (should (string= (chat-session-id session) "test-id"))
    (should (string= (chat-session-name session) "test-session"))
    (should (eq (chat-session-model-id session) 'gpt-4o))))

(ert-deftest chat-session-defaults-test ()
  "Test that chat-session has correct default values."
  (skip-unless (featurep 'chat-session))
  (let ((session (make-chat-session :id "test")))
    (should (listp (chat-session-messages session)))
    (should (null (chat-session-messages session)))
    (should (listp (chat-session-prompt-stack session)))))

;; Test message structure
(ert-deftest chat-message-structure-test ()
  "Test that chat-message struct is defined correctly."
  (let ((msg (make-chat-message
              :id "msg-1"
              :role :user
              :content "Hello world")))
    (should (chat-message-p msg))
    (should (string= (chat-message-id msg) "msg-1"))
    (should (eq (chat-message-role msg) :user))
    (should (string= (chat-message-content msg) "Hello world"))))

;; Test session creation
(ert-deftest chat-session-create-test ()
  "Test creating a new session."
  (skip-unless (fboundp 'chat-session-create))
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently
                    (chat-session-create "My Session" 'gpt-4o))))
     (should session)
     (should (chat-session-p session))
     (should (string= (chat-session-name session) "My Session"))
     (should (eq (chat-session-model-id session) 'gpt-4o))
     (should (stringp (chat-session-id session))))))

;; Test session persistence
(ert-deftest chat-session-save-and-load-test ()
  "Test saving and loading a session."
  (skip-unless (and (fboundp 'chat-session-save)
                    (fboundp 'chat-session-load)))
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently
                    (chat-session-create "Test" 'gpt-4o)))
          (session-id (chat-session-id session)))
     ;; Add a message
     (chat-session-add-message session
                               (make-chat-message
                                :id "m1"
                                :role :user
                                :content "Test message"))
     ;; Save
     (chat-session-save session)
     ;; Load
     (let ((loaded (chat-session-load session-id)))
       (should loaded)
       (should (string= (chat-session-id loaded) session-id))
       (should (string= (chat-session-name loaded) "Test"))
       (should (= (length (chat-session-messages loaded)) 1))))))

(ert-deftest chat-session-save-and-load-preserves-tool-fields ()
  "Test saving and loading message tool fields."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently
                    (chat-session-create "Test" 'gpt-4o)))
          (session-id (chat-session-id session)))
     (chat-session-add-message
      session
      (make-chat-message
       :id "m1"
       :role :assistant
       :content ""
       :tool-calls '((:id "call-1" :name "demo" :arguments (("input" . "hello"))))
       :tool-results '("done")
       :raw-request "{\"request\":true}"
       :raw-response "{\"response\":true}"))
     (chat-session-save session)
     (let* ((loaded (chat-session-load session-id))
            (message (car (chat-session-messages loaded))))
       (should (equal (chat-message-tool-calls message)
                      '((:id "call-1" :name "demo" :arguments (("input" . "hello"))))))
       (should (equal (chat-message-tool-results message) '("done")))
       (should (string= (chat-message-raw-request message) "{\"request\":true}"))
       (should (string= (chat-message-raw-response message) "{\"response\":true}"))))))

(ert-deftest chat-session-a-message-keeps-its-date-through-a-reopen ()
  "A reopened session used to come back dated 1970.

`parse-time-string' returns a decoded time and the loader handed it to
`decode-time', which reads its argument as a time value instead: the
seconds and minutes were taken for the halves of an epoch offset, so every
message landed a few weeks into January 1970.  Saving was correct, which
is why this only showed up in sessions that had been opened again -- and
then the wrong date was written back over the right one."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "Test" 'gpt-4o))
          (session-id (chat-session-id session))
          (when-sent (encode-time 30 45 14 26 8 2026)))
     (chat-session-add-message
      session
      (make-chat-message :id "m1" :role :user :content "hi"
                         :timestamp when-sent))
     (chat-session-save session)
     (let* ((loaded (chat-session-load session-id))
            (message (car (chat-session-messages loaded))))
       (should (equal (format-time-string "%Y-%m-%dT%H:%M:%S"
                                          (chat-message-timestamp message))
                      "2026-08-26T14:45:30"))))))

(ert-deftest chat-session-a-date-survives-two-reopens ()
  "The corrupted date was written back, so each reopen had to be checked."
  (chat-test-with-temp-dir
   (let ((session-id nil))
     (let ((session (chat-session-create "Test" 'gpt-4o)))
       (setq session-id (chat-session-id session))
       (chat-session-add-message
        session
        (make-chat-message :id "m1" :role :user :content "hi"
                           :timestamp (encode-time 0 0 12 1 6 2026)))
       (chat-session-save session))
     (chat-session-save (chat-session-load session-id))
     (let ((message (car (chat-session-messages
                          (chat-session-load session-id)))))
       (should (equal (format-time-string "%Y-%m-%d"
                                          (chat-message-timestamp message))
                      "2026-06-01"))))))

(ert-deftest chat-session-keeps-its-own-dates-through-a-reopen ()
  "The session header carried the same bug as its messages."
  (chat-test-with-temp-dir
   (let* ((session (chat-session-create "Test" 'gpt-4o))
          (session-id (chat-session-id session))
          (created (chat-session-created-at session)))
     (chat-session-save session)
     (let ((loaded (chat-session-load session-id)))
       (should (equal (format-time-string "%Y-%m-%dT%H:%M:%S" created)
                      (format-time-string
                       "%Y-%m-%dT%H:%M:%S"
                       (chat-session-created-at loaded))))))))

(ert-deftest chat-session-save-and-load-preserves-keyword-roles ()
  "Test role keywords survive a save and load round trip."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently
                    (chat-session-create "Role Test" 'gpt-4o)))
          (session-id (chat-session-id session)))
     (chat-session-add-message
      session
      (make-chat-message
       :id "m1"
       :role :assistant
       :content ""
       :timestamp (current-time)))
     (chat-session-save session)
     (let* ((loaded (chat-session-load session-id))
            (message (car (chat-session-messages loaded))))
       (should (eq (chat-message-role message) :assistant))))))

(ert-deftest chat-session-save-and-load-preserves-tool-config ()
  "Test per-session tool overlays survive a save and load round trip."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently
                    (chat-session-create "Tool Config" 'gpt-4o)))
          (session-id (chat-session-id session)))
     (chat-session-set-tool-config
      session
      '(:default t
        :disabled-tools (danger-tool)
        :enabled-tools (safe-tool)
        :packs (programming office)))
     (chat-session-save session)
     (let ((loaded (chat-session-load session-id)))
       (should (equal (chat-session-tool-config loaded)
                      '(:default t
                        :disabled-tools (danger-tool)
                        :enabled-tools (safe-tool)
                        :packs (programming office))))
       (should (chat-session-tool-enabled-p loaded 'safe-tool))
       (should-not (chat-session-tool-enabled-p loaded 'danger-tool))))))

(ert-deftest chat-session-explicit-empty-tool-list-disables-every-tool ()
  "An explicit empty allowlist means no tools, not an absent allowlist."
  (let ((session (make-chat-session
                  :id "no-tools" :tool-config '(:enabled-tools nil))))
    (should-not (chat-session-tool-enabled-p session 'anything))))

(ert-deftest chat-session-save-and-load-preserves-tree-and-summary-data ()
  "Test session tree metadata, message branch fields, and summaries persist."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Branch" 'kimi))
          (session-id (chat-session-id session)))
     (chat-session-set-tree-info
      session
      :parent-session-id "parent-session"
      :branch-id "branch-a"
      :leaf-message-id "m1")
     (chat-session-add-message
      session
      (make-chat-message
       :id "m1"
       :role :user
       :content "hello"
       :parent-id "root"
       :branch-ids '("m2")))
     (chat-session-add-summary session "Earlier context" '((kind . "manual")))
     (chat-session-save session)
     (let* ((loaded (chat-session-load session-id))
            (message (car (chat-session-messages loaded)))
            (summary (car (chat-session-summaries loaded))))
       (should (string= (chat-session-parent-session-id loaded)
                        "parent-session"))
       (should (string= (chat-session-branch-id loaded) "branch-a"))
       (should (string= (chat-session-leaf-message-id loaded) "m1"))
       (should (string= (chat-message-parent-id message) "root"))
       (should (equal (chat-message-branch-ids message) '("m2")))
       (should (string= (cdr (assoc 'summary summary)) "Earlier context"))))))

;; Test session listing
(ert-deftest chat-session-list-test ()
  "Test listing all sessions."
  (skip-unless (fboundp 'chat-session-list))
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir))
     ;; Create two sessions
     (chat-session-create "Session 1" 'gpt-4o)
     (chat-session-create "Session 2" 'claude-sonnet)
     ;; List
     (let ((sessions (chat-session-list)))
       (should (= (length sessions) 2))
       (should (cl-find "Session 1" sessions
                        :key #'chat-session-name
                        :test #'string=))
       (should (cl-find "Session 2" sessions
                        :key #'chat-session-name
                        :test #'string=))))))

;; Test message addition
(ert-deftest chat-session-add-message-test ()
  "Test adding messages to a session."
  (skip-unless (fboundp 'chat-session-add-message))
  (skip-unless (featurep 'chat-session))
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "m1" :role :user :content "Hello"))
    (should (= (length (chat-session-messages session)) 1))
    (chat-session-add-message
     session
     (make-chat-message :id "m2" :role :assistant :content "Hi"))
    (should (= (length (chat-session-messages session)) 2))
    (should (eq (chat-message-role
                 (car (last (chat-session-messages session))))
                :assistant))))

(ert-deftest chat-session-clear-messages-test ()
  "Test clearing all messages from a session."
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (chat-session-clear-messages session)
    (should (equal (chat-session-messages session) nil))))

(ert-deftest chat-session-find-last-message-without-predicate-returns-tail ()
  "Test the generic last-message helper returns the final message by default."
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (chat-session-add-message
     session
     (make-chat-message :id "a1" :role :assistant :content "hi"))
    (should (string= (chat-message-id (chat-session-find-last-message session))
                     "a1"))))

(ert-deftest chat-session-find-last-message-by-role-test ()
  "Test finding the last message for a given role."
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (chat-session-add-message
     session
     (make-chat-message :id "a1" :role :assistant :content "hi"))
    (chat-session-add-message
     session
     (make-chat-message :id "u2" :role :user :content "again"))
    (let ((user-msg (chat-session-find-last-message-by-role session :user))
          (assistant-msg (chat-session-find-last-message-by-role session :assistant)))
      (should (string= (chat-message-id user-msg) "u2"))
      (should (string= (chat-message-id assistant-msg) "a1")))))

(ert-deftest chat-session-find-last-message-by-role-returns-nil-when-missing ()
  "Test role lookup returns nil when no message matches."
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (should-not (chat-session-find-last-message-by-role session :assistant))))

(ert-deftest chat-session-truncate-after-message-test ()
  "Test truncating session history at a message boundary."
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (chat-session-add-message
     session
     (make-chat-message :id "a1" :role :assistant :content "hi"))
    (chat-session-add-message
     session
     (make-chat-message :id "u2" :role :user :content "again"))
    (should (chat-session-truncate-after-message session "a1"))
    (should (equal (mapcar #'chat-message-id (chat-session-messages session))
                   '("u1" "a1")))
    (should (chat-session-truncate-after-message session "a1" t))
    (should (equal (mapcar #'chat-message-id (chat-session-messages session))
                   '("u1")))))

(ert-deftest chat-session-truncate-after-message-returns-nil-for-missing-id ()
  "Test truncation leaves history unchanged when the message is missing."
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (should-not (chat-session-truncate-after-message session "missing"))
    (should (equal (mapcar #'chat-message-id (chat-session-messages session))
                   '("u1")))))

(ert-deftest chat-session-replace-message-content-test ()
  "Test replacing content on an existing message."
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (should (chat-session-replace-message-content session "u1" "updated"))
    (should (string= (chat-message-content
                      (car (chat-session-messages session)))
                     "updated"))))

(ert-deftest chat-session-replace-message-content-returns-nil-for-missing-id ()
  "Test replacement leaves history unchanged when the message is missing."
  (let ((session (make-chat-session :id "test")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (should-not (chat-session-replace-message-content session "missing" "updated"))
    (should (string= (chat-message-content
                      (car (chat-session-messages session)))
                     "hello"))))

;; Test session deletion
(ert-deftest chat-session-delete-test ()
  "Test deleting a session."
  (skip-unless (fboundp 'chat-session-delete))
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently
                    (chat-session-create "To Delete" 'gpt-4o)))
          (id (chat-session-id session)))
     (chat-session-save session)
     (should (file-exists-p
              (expand-file-name (format "%s.jsonl" id) temp-dir)))
     (chat-session-delete id)
     (should-not (file-exists-p
                  (expand-file-name (format "%s.jsonl" id) temp-dir))))))

;; Test session rename
(ert-deftest chat-session-rename-test ()
  "Test renaming a session."
  (skip-unless (fboundp 'chat-session-rename))
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Old Name" 'gpt-4o))
          (id (chat-session-id session)))
     (chat-session-rename id "New Name")
     (let ((loaded (chat-session-load id)))
       (should (string= (chat-session-name loaded) "New Name"))))))

(ert-deftest chat-session-list-ignores-invalid-json-files ()
  "Test listing sessions ignores unreadable JSON files."
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir))
     (chat-session-create "Valid Session" 'gpt-4o)
     (with-temp-file (expand-file-name "broken.json" temp-dir)
       (insert "{not-valid"))
     (let ((sessions (chat-session-list)))
       (should (= (length sessions) 1))
       (should (string= (chat-session-name (car sessions)) "Valid Session"))))))

(ert-deftest chat-session-message-ids-are-unique ()
  "Test generated message ids never repeat."
  (let ((ids (cl-loop repeat 2000 collect (chat-session-new-message-id))))
    (should (= (length ids) (length (delete-dups ids))))))

(ert-deftest chat-session-load-returns-nil-on-corrupt-file ()
  "Test a corrupt session file loads as nil instead of signaling."
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir))
     (with-temp-file (expand-file-name "broken.json" temp-dir)
       (insert "{not json"))
     (should-not (chat-session-load "broken")))))

(ert-deftest chat-session-save-leaves-no-temp-files ()
  "Test atomic save cleans up its temporary file."
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir))
     (chat-session-save (chat-session-create "atomic" 'kimi))
     (should (null (directory-files temp-dir nil "^\\.session-"))))))

(ert-deftest chat-session-jsonl-atomic-append-keeps-complete-records ()
  "Test atomic append keeps one complete record per line."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Append Session" 'kimi)))
     (chat-session-add-message
      session
      (make-chat-message :id "m1" :role :user
                         :content "one" :timestamp (current-time)))
     (chat-session-add-message
      session
      (make-chat-message :id "m2" :role :assistant
                         :content "two" :timestamp (current-time)))
     (let* ((file (expand-file-name
                   (format "%s.jsonl" (chat-session-id session))
                   temp-dir))
            (lines (split-string
                    (with-temp-buffer
                      (insert-file-contents file)
                      (buffer-string))
                    "\n" t)))
       ;; header + state, then message + state per added message
       (should (= (length lines) 6))
       (should (string-match-p "\"header\"" (nth 0 lines)))
       (should (string-match-p "\"message\"" (nth 2 lines)))
       (should (null (directory-files temp-dir nil "^\\.append-")))))))

(ert-deftest chat-session-load-migrates-legacy-json ()
  "Test legacy JSON session files load and migrate to JSONL."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Legacy Session" 'kimi))
          (id (chat-session-id session)))
     ;; Rewrite the on-disk file in the legacy single-JSON format.
     (with-temp-file (expand-file-name (format "%s.json" id) temp-dir)
       (insert (json-encode (chat-session--serialize session))))
     (delete-file (expand-file-name (format "%s.jsonl" id) temp-dir))
     (let ((loaded (chat-session-load id)))
       (should loaded)
       (should (string= (chat-session-name loaded) "Legacy Session"))
       (should (file-exists-p
                (expand-file-name (format "%s.jsonl" id) temp-dir)))
       (should-not (file-exists-p
                    (expand-file-name (format "%s.json" id) temp-dir)))))))

(ert-deftest chat-session-jsonl-tolerates-corrupt-lines ()
  "Test JSONL loading skips unreadable lines."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Corrupt Session" 'kimi)))
     (chat-session-add-message
      session
      (make-chat-message :id "m1" :role :user
                         :content "one" :timestamp (current-time)))
     (let ((file (expand-file-name
                  (format "%s.jsonl" (chat-session-id session))
                  temp-dir)))
       (write-region "{not json\n" nil file 'append 'silent)
       (let ((loaded (chat-session-load (chat-session-id session))))
         (should loaded)
         (should (= (length (chat-session-messages loaded)) 1)))))))

(ert-deftest chat-session-jsonl-append-recovers-after-partial-tail ()
  "Test append isolates a partial trailing line instead of merging records."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Partial Append" 'kimi)))
     (chat-session-add-message
      session
      (make-chat-message :id "m1" :role :user
                         :content "one" :timestamp (current-time)))
     (let ((file (expand-file-name
                  (format "%s.jsonl" (chat-session-id session))
                  temp-dir)))
       (write-region "{\"type\":\"message\"" nil file 'append 'silent)
       (chat-session-add-message
        session
        (make-chat-message :id "m2" :role :assistant
                           :content "two" :timestamp (current-time)))
       (let ((loaded (chat-session-load (chat-session-id session))))
         (should loaded)
         (should (equal (mapcar #'chat-message-id
                                (chat-session-messages loaded))
                        '("m1" "m2"))))))))

(ert-deftest chat-session-load-detects-interrupted-tool-pairs ()
  "Test loading marks missing tool results without inventing success."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Interrupted" 'kimi)))
     (chat-session-add-message
      session
      (make-chat-message
       :id "a1"
       :role :assistant
       :content ""
       :tool-calls '((:id "call-1" :name "demo" :arguments nil))))
     (let* ((loaded (chat-session-load (chat-session-id session)))
            (recovery (chat-session-recovery-state loaded)))
       (should (eq (plist-get recovery :type) 'interrupted-tool-run))
       (should (equal (plist-get recovery :missing-tool-call-ids)
                      '("call-1")))))))

(ert-deftest chat-session-recovery-marks-interrupted-tools-failed ()
  "Test recovery records failure without inventing successful output."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Recover" 'kimi)))
     (chat-session-add-message
      session
      (make-chat-message
       :id "a1"
       :role :assistant
       :content ""
       :tool-calls '((:id "call-1" :name "demo" :arguments nil))))
     (setf (chat-session-recovery-state session)
           (chat-session-detect-interrupted-run session))
     (chat-session-recover-interrupted-run session 'mark-failed)
     (let ((result (car (last (chat-session-messages session)))))
       (should (eq (chat-message-role result) :tool))
       (should (equal (plist-get (chat-message-metadata result)
                                 :tool-call-id)
                      "call-1"))
       (should (eq (plist-get (chat-message-metadata result) :status)
                   'failed))
       (should-not (chat-session-detect-interrupted-run session))))))

(ert-deftest chat-session-branching-preserves-original-history ()
  "Test branches copy a prefix without truncating the source session."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Root" 'kimi))
          (user (make-chat-message :id "u1" :role :user :content "ask"))
          (assistant
           (make-chat-message :id "a1" :role :assistant :content "answer")))
     (chat-session-add-message session user)
     (chat-session-add-message session assistant)
     (let ((branch
            (chat-session-create-branch-before-message
             session "a1" nil '((reason . "regenerate")))))
       (should (equal (mapcar #'chat-message-id
                              (chat-session-messages session))
                      '("u1" "a1")))
       (should (equal (mapcar #'chat-message-id
                              (chat-session-messages branch))
                      '("u1")))
       (should (equal (chat-session-parent-session-id branch)
                      (chat-session-id session)))
       (should (member (chat-session-id branch)
                       (chat-message-branch-ids user)))
       (should (chat-session-load (chat-session-id branch)))))))

(ert-deftest chat-session-branch-carries-forward-what-the-session-knew ()
  "A branch keeps the parent's metadata, not only its own entries.

A branch continues a session, so the working directory and every other
recorded property continue with it. Replacing the alist wholesale is
invisible until a shell command runs in the wrong place after a
regenerate."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Root" 'kimi)))
     (chat-session-set-working-directory session temp-dir)
     (chat-session-metadata-set session 'code-enabled t)
     (chat-session-add-message
      session (make-chat-message :id "u1" :role :user :content "ask"))
     (chat-session-add-message
      session (make-chat-message :id "a1" :role :assistant :content "answer"))
     (let ((branch (chat-session-create-branch-before-message
                    session "a1" nil '((reason . "regenerate")))))
       (should (equal (chat-session-working-directory branch)
                      (chat-session-working-directory session)))
       (should (eq (chat-session-metadata-get branch 'code-enabled) t))
       ;; The branch's own entries still take effect.
       (should (equal (chat-session-metadata-get branch 'reason)
                      "regenerate"))))))

(ert-deftest chat-session-branch-metadata-does-not-mutate-the-parent ()
  "Merging for a branch leaves the source session alone.

Sharing structure would let a branch's entry appear in the session it
came from, which is worse than losing it."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Root" 'kimi)))
     (chat-session-set-working-directory session temp-dir)
     (chat-session-add-message
      session (make-chat-message :id "u1" :role :user :content "ask"))
     (chat-session-add-message
      session (make-chat-message :id "a1" :role :assistant :content "answer"))
     (chat-session-create-branch-before-message
      session "a1" nil '((reason . "regenerate")))
     (should-not (chat-session-metadata-get session 'reason)))))

(ert-deftest chat-session-metadata-merge-overrides-by-key ()
  "An override replaces the parent value for the same key."
  (let ((session (make-chat-session
                  :id "m" :metadata '((working-directory . "/old/")
                                      (keep . "kept")))))
    (let ((merged (chat-session-metadata-merge
                   session '((working-directory . "/new/")))))
      (should (equal (cdr (assq 'working-directory merged)) "/new/"))
      (should (equal (cdr (assq 'keep merged)) "kept")))))

(ert-deftest chat-session-tool-pair-safe-cut-index-refuses-open-pair ()
  "Test compaction cut points do not split assistant/tool pairs."
  (let ((session (make-chat-session :id "safe-cut")))
    (chat-session-add-message
     session
     (make-chat-message :id "u1" :role :user :content "hello"))
    (chat-session-add-message
     session
     (make-chat-message
      :id "a1"
      :role :assistant
      :content ""
      :tool-calls '((:id "call-1" :name "demo" :arguments nil))))
    (should (= (chat-session-tool-pair-safe-cut-index session 1) 0))
    (chat-session-add-message
     session
     (make-chat-message
      :id "t1"
      :role :tool
      :content "done"
      :metadata '(:tool-call-id "call-1")))
    (should (= (chat-session-tool-pair-safe-cut-index session 2) 2))))

(ert-deftest chat-session-tree-flatten-orders-children-under-parent ()
  "Test session tree flattening uses parent session metadata."
  (let* ((parent (make-chat-session
                  :id "parent"
                  :name "Parent"
                  :created-at (current-time)
                  :updated-at (current-time)
                  :model-id 'kimi))
         (child (make-chat-session
                 :id "child"
                 :name "Child"
                 :created-at (current-time)
                 :updated-at (current-time)
                 :model-id 'kimi
                 :parent-session-id "parent"))
         (nodes (chat-session-tree-flatten (list child parent))))
    (should (equal (mapcar (lambda (node)
                             (chat-session-id
                              (chat-session-tree-node-session node)))
                           nodes)
                   '("parent" "child")))
    (should (= (chat-session-tree-node-depth (cadr nodes)) 1))))

(ert-deftest chat-session-list-prefers-jsonl-over-legacy ()
  "Test listing counts a session once when both file formats exist."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Dup Session" 'kimi))
          (id (chat-session-id session)))
     (with-temp-file (expand-file-name (format "%s.json" id) temp-dir)
       (insert (json-encode (chat-session--serialize session))))
     (let ((sessions (chat-session-list)))
       (should (= (length sessions) 1))
       (should (string= (chat-session-name (car sessions)) "Dup Session"))))))

(ert-deftest chat-session-metadata-survives-a-reload ()
  "Metadata written through the API reads back after loading the session.
A keyword key must keep working, because a JSON round trip turns it into
a plain symbol."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-session-auto-save nil)
          (session (chat-session-create "Metadata Session" 'kimi)))
     (chat-session-metadata-set session :working-directory "/tmp/")
     (chat-session-metadata-set session 'other "kept")
     (chat-session-save session)
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (equal "/tmp/" (chat-session-metadata-get loaded :working-directory)))
       (should (equal "/tmp/" (chat-session-metadata-get loaded 'working-directory)))
       (should (equal "kept" (chat-session-metadata-get loaded 'other)))))))

(ert-deftest chat-session-metadata-set-overwrites-one-key ()
  "Writing a key twice replaces its value and leaves the others alone."
  (let ((session (make-chat-session :id "x" :name "x")))
    (chat-session-metadata-set session 'a 1)
    (chat-session-metadata-set session 'b 2)
    (chat-session-metadata-set session 'a 3)
    (should (equal 3 (chat-session-metadata-get session 'a)))
    (should (equal 2 (chat-session-metadata-get session 'b)))))

(ert-deftest chat-session-metadata-get-reads-a-legacy-plist ()
  "A keyword plist left in memory by an older writer still reads."
  (let ((session (make-chat-session :id "x" :name "x")))
    (setf (chat-session-metadata session) '(:working-directory "/tmp/"))
    (should (equal "/tmp/" (chat-session-metadata-get session :working-directory)))
    ;; Writing converts the plist, keeping the entry that was already there.
    (chat-session-metadata-set session 'other "new")
    (should (equal "/tmp/" (chat-session-metadata-get session 'working-directory)))
    (should (equal "new" (chat-session-metadata-get session 'other)))))

(ert-deftest chat-session-working-directory-round-trips ()
  "A recorded working directory is normalized and survives reopening."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (chat-session-auto-save t)
          (session (chat-session-create "Cwd Session" 'kimi))
          (stored (chat-session-set-working-directory session temp-dir)))
     (should (string-suffix-p "/" stored))
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (equal (file-name-as-directory (file-truename temp-dir))
                      (file-truename (chat-session-working-directory loaded))))))))

(ert-deftest chat-session-working-directory-ignores-a-missing-path ()
  "A directory that no longer exists reads as nil instead of misdirecting."
  (let ((session (make-chat-session :id "x" :name "x")))
    (chat-session-metadata-set session 'working-directory "/nonexistent-chat-el-dir/")
    (should-not (chat-session-working-directory session))))

(ert-deftest chat-session-can-name-its-own-history-file ()
  "A session had no way to say where its history lives.

Callers had to know the naming scheme and rebuild the path themselves,
which is knowledge that belongs here."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "history" 'kimi))
          (path (chat-session-history-file session)))
     (should (file-name-absolute-p path))
     (should (string-suffix-p ".jsonl" path))
     (should (string-match-p (regexp-quote (chat-session-id session)) path))
     (chat-session-save session)
     (should (file-exists-p path)))))

(ert-deftest chat-session-history-file-follows-a-moved-directory ()
  "Derived, not stored: a stale absolute path is worse than none."
  (let ((session (make-chat-session :id "abc" :name "abc")))
    (let ((chat-session-directory "/one/"))
      (should (equal (chat-session-history-file session) "/one/abc.jsonl")))
    (let ((chat-session-directory "/two/"))
      (should (equal (chat-session-history-file session) "/two/abc.jsonl")))))

;; ------------------------------------------------------------------
;; The model a session runs on
;; ------------------------------------------------------------------

(ert-deftest chat-session-a-new-session-pins-no-model ()
  "nil means \"the provider's default at request time\", which is what
almost every session wants.  Writing the default in would freeze one
snapshot of a setting the configuration may change."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently (chat-session-create "T" 'kimi-code))))
     (should (null (chat-session-model-name session))))))

(ert-deftest chat-session-a-pinned-model-survives-a-round-trip ()
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently
                    (chat-session-create "T" 'kimi-code "k3-256k"))))
     (chat-session-save session)
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (equal "k3-256k" (chat-session-model-name loaded)))))))

(ert-deftest chat-session-an-unpinned-model-reads-back-unpinned ()
  "JSON null must not come back as a model called \"null\"."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently (chat-session-create "T" 'kimi-code))))
     (chat-session-save session)
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (null (chat-session-model-name loaded)))))))

(ert-deftest chat-session-a-provider-changed-mid-session-is-persisted ()
  "Which provider a session runs on is state, not identity.

It lived only in the header, and the append path does not rewrite the
header, so a switch made mid-session could be saved and lost."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently (chat-session-create "T" 'kimi-code))))
     (chat-session-save session)
     (setf (chat-session-model-id session) 'deepseek)
     (setf (chat-session-model-name session) "deepseek-v4-pro")
     (chat-session-add-message session
                               (make-chat-message :id "m1" :role :user
                                                  :content "hi"))
     (let ((loaded (chat-session-load (chat-session-id session))))
       (should (eq 'deepseek (chat-session-model-id loaded)))
       (should (equal "deepseek-v4-pro" (chat-session-model-name loaded)))))))

(ert-deftest chat-session-a-branch-inherits-the-model-it-branched-from ()
  "A branch continues a conversation; a different model is a different one."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-test-silently
                    (chat-session-create "T" 'kimi-code "k3"))))
     (chat-session-add-message session
                               (make-chat-message :id "m1" :role :user
                                                  :content "hi"))
     (let ((branch (chat-test-silently
                    (chat-session-create-branch session "m1"))))
       (should (eq 'kimi-code (chat-session-model-id branch)))
       (should (equal "k3" (chat-session-model-name branch)))))))

(provide 'test-chat-session)
;;; test-chat-session.el ends here
