;;; test-session-index.el --- The session index -*- lexical-binding: t; -*-

;;; Commentary:

;; The index is a cache, and the tests are mostly about it being one:
;; reconstructible from the sessions, skippable when absent, and never the
;; only place something is written down.

;;; Code:

(require 'ert)
(require 'chat-session-index)

(defmacro chat-test-with-index (&rest body)
  "Run BODY with a session directory and index of its own."
  `(chat-test-with-temp-dir
    (let ((chat-session-index--written (make-hash-table :test 'equal))
          (chat-session-index-enabled t))
      ,@body)))

(ert-deftest chat-index-holds-what-a-list-shows ()
  "An entry names the session without holding its messages."
  (chat-test-with-index
   (let ((session (chat-session-create "关于索引")))
     (chat-session-add-message
      session (make-chat-message :id "m1" :role :user :content "问题"))
     (chat-session-save session)
     (let ((entry (car (chat-session-index-read))))
       (should (equal (chat-session-id session)
                      (alist-get 'session_id entry)))
       (should (equal "关于索引" (alist-get 'title entry)))
       (should (equal 1 (alist-get 'turn_count entry)))
       (should (> (alist-get 'context_bytes entry) 0))))))

(ert-deftest chat-index-lives-clear-of-the-session-files ()
  "The index is not somewhere `chat-session-list' will find it.
It globs `*.jsonl' in the session directory and hands each base name to
`chat-session-load', so an index in there would be offered to the rebuild
that reads it as though it were a session."
  (chat-test-with-index
   (should-not (equal (file-name-directory (chat-session-index-file))
                      (file-name-as-directory
                       (expand-file-name chat-session-directory))))))

(ert-deftest chat-index-one-line-per-turn-not-per-message ()
  "Saving each message of a turn does not add a line for each.
A save happens per message; an index line per message would make the
index grow with the conversation it exists to summarise.  Five saves here
-- the session's own, then four messages -- and two lines: the session
appearing, and its first turn."
  (chat-test-with-index
   (let ((session (chat-session-create "turns")))
     (chat-session-add-message
      session (make-chat-message :id "m1" :role :user :content "ask"))
     (chat-session-save session)
     (dolist (id '("m2" "m3" "m4"))
       (chat-session-add-message
        session (make-chat-message :id id :role :assistant :content "step"))
       (chat-session-save session))
     (let ((lines (with-temp-buffer
                    (insert-file-contents (chat-session-index-file))
                    (count-lines (point-min) (point-max)))))
       (should (= 2 lines))))))

(ert-deftest chat-index-can-be-rebuilt-from-the-sessions ()
  "Losing the index loses nothing.
The reason it can be written cheaply: it is derived, so it cannot be the
copy that mattered."
  (chat-test-with-index
   (dolist (name '("one" "two" "three"))
     (let ((session (chat-session-create name)))
       (chat-session-add-message
        session (make-chat-message :id (concat name "-m") :role :user
                                   :content "x"))
       (chat-session-save session)))
   (delete-file (chat-session-index-file))
   (should (= 3 (chat-session-index-rebuild)))
   (should (equal '("one" "three" "two")
                  (sort (mapcar (lambda (e) (alist-get 'title e))
                                (chat-session-index-read))
                        #'string<)))))

(ert-deftest chat-index-a-later-line-wins-for-the-same-session ()
  "A renamed session reads as its new name, not both names."
  (chat-test-with-index
   (let ((session (chat-session-create "before")))
     (chat-session-add-message
      session (make-chat-message :id "m1" :role :user :content "x"))
     (chat-session-save session)
     (setf (chat-session-name session) "after")
     (chat-session-add-message
      session (make-chat-message :id "m2" :role :user :content "y"))
     (chat-session-save session)
     (let ((entries (chat-session-index-read)))
       (should (= 1 (length entries)))
       (should (equal "after" (alist-get 'title (car entries))))))))

(ert-deftest chat-index-off-leaves-no-file ()
  "Turning it off means no index, not an empty one."
  (chat-test-with-index
   ;; `let*': a session saves itself as it is created, so binding the
   ;; switch and creating the session in one `let' creates it while the
   ;; switch still holds its old value.
   (let* ((chat-session-index-enabled nil)
          (session (chat-session-create "quiet")))
     (chat-session-save session)
     (should-not (file-exists-p (chat-session-index-file))))))

(provide 'test-session-index)
;;; test-session-index.el ends here
