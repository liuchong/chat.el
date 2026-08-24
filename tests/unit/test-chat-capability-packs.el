;;; test-chat-capability-packs.el --- Tests for capability packs -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-capability-packs)

(ert-deftest chat-capability-profile-applies-session-tool-overlay ()
  "Test capability profiles scope visible tools through session config."
  (let ((session (make-chat-session :id "profile")))
    (chat-capability-apply-profile session 'daily)
    (should (chat-session-tool-enabled-p session 'daily_calendar_today))
    (should-not (chat-session-tool-enabled-p session 'programming_git_status))
    (should (eq (plist-get (chat-session-tool-config session) :profile)
                'daily))))

(ert-deftest chat-capability-office-tools-read_and_mutate_allowed_roots ()
  "Test office tools read Org headings and mutate allowed directories."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (org-file (expand-file-name "notes.org" temp-dir))
          (dir (expand-file-name "folder" temp-dir))
          (renamed (expand-file-name "renamed" temp-dir)))
     (with-temp-file org-file
       (insert "* Inbox\n** Follow up\n"))
     (should (equal (mapcar (lambda (headline)
                              (cdr (assoc 'title headline)))
                            (chat-capability-office-org-headlines org-file))
                    '("Inbox" "Follow up")))
     (chat-capability-office-dired-mkdir dir)
     (should (file-directory-p dir))
     (chat-capability-office-dired-rename dir renamed)
     (should (file-directory-p renamed))
     (should (string= (chat-capability-office-calc-eval "2+3") "5")))))

(ert-deftest chat-capability-daily-tools_keep_mail_as_drafts ()
  "Test daily tools support diary and unsent mail drafts."
  (chat-test-with-temp-dir
   (let* ((chat-files-allowed-directories (list temp-dir))
          (chat-capability-mail-drafts nil)
          (diary (expand-file-name "diary" temp-dir)))
     (with-temp-file diary)
     (chat-capability-daily-diary-insert "2026-08-24 Work" diary)
     (should (string-match-p "Work"
                             (chat-capability-daily-diary-read diary)))
     (let ((draft (chat-capability-daily-mail-draft-create
                   "user@example.test" "Hello" "Body")))
       (should (string= (cdr (assoc 'status draft)) "draft"))
       (should (= (length (chat-capability-daily-mail-draft-list)) 1))
       (chat-capability-daily-mail-draft-delete (cdr (assoc 'id draft)))
       (should-not (chat-capability-daily-mail-draft-list))))))

(ert-deftest chat-capability-register-tools-adds_metadata ()
  "Test capability tools register with owner and permission metadata."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq)))
    (chat-capability-register-tools)
    (let ((tool (chat-tool-forge-get 'daily_mail_draft_create)))
      (should tool)
      (should (eq (chat-forged-tool-owner tool) 'capability-packs))
      (should (eq (chat-forged-tool-sensitivity tool) 'correspondence))
      (should (memq 'write (chat-forged-tool-effects tool))))))

(provide 'test-chat-capability-packs)
;;; test-chat-capability-packs.el ends here
