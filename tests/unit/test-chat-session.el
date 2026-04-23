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
       :tool-calls '((:name "demo" :arguments (("input" . "hello"))))
       :tool-results '("done")
       :raw-request "{\"request\":true}"
       :raw-response "{\"response\":true}"))
     (chat-session-save session)
     (let* ((loaded (chat-session-load session-id))
            (message (car (chat-session-messages loaded))))
       (should (equal (chat-message-tool-calls message)
                      '((:name "demo" :arguments (("input" . "hello"))))))
       (should (equal (chat-message-tool-results message) '("done")))
       (should (string= (chat-message-raw-request message) "{\"request\":true}"))
       (should (string= (chat-message-raw-response message) "{\"response\":true}"))))))

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
              (expand-file-name (format "%s.json" id) temp-dir)))
     (chat-session-delete id)
     (should-not (file-exists-p
                  (expand-file-name (format "%s.json" id) temp-dir))))))

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

(provide 'test-chat-session)
;;; test-chat-session.el ends here
