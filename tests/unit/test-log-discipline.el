;;; test-log-discipline.el --- What the diagnostic log costs -*- lexical-binding: t; -*-

;;; Commentary:

;; The diagnostic log used to be free only in the sense that nobody was
;; charged for it.  It was a function, so every argument at every call site
;; was computed whether or not it would be written -- the request builder
;; formatted a 250KB payload on each send to hand it to a call that might
;; discard it -- and it never rotated, so it reached 119MB.
;;
;; These are the two tests that would have caught both.

;;; Code:

(require 'ert)
(require 'chat-log)

(ert-deftest chat-log-off-does-not-evaluate-its-arguments ()
  "With logging off, nothing a log line would have said is computed.
It was a function, so `(chat-log \"%S\" (build-the-payload))' built the
payload regardless.  As a macro the argument is inside the condition."
  (let ((computed 0))
    (cl-flet ((expensive () (cl-incf computed) "x"))
      (let ((chat-log-enabled nil))
        (chat-log "value: %s" (expensive)))
      (should (= 0 computed))
      (chat-test-with-temp-dir
       (let ((chat-log-enabled t))
         (chat-log "value: %s" (expensive))))
      (should (= 1 computed)))))

(ert-deftest chat-log-starts-a-new-file-when-the-day-turns ()
  "Yesterday's log is set aside rather than appended to forever.
Per day rather than per size, because the question asked of this file is
always \"what happened when I saw it\", and a date answers that."
  (chat-test-with-temp-dir
   (let ((chat-log-enabled t)
         (chat-log--day nil))
     (chat-log "today")
     (let* ((file (expand-file-name chat-log-file))
            (yesterday (format-time-string
                        "%Y-%m-%d" (time-subtract (current-time)
                                                  (days-to-time 1)))))
       ;; Backdate the file, then log again as though the day had turned.
       (set-file-times file (time-subtract (current-time) (days-to-time 1)))
       (setq chat-log--day nil)
       (chat-log "tomorrow")
       (should (file-exists-p (concat file "." yesterday)))
       (should (file-exists-p file))
       (with-temp-buffer
         (insert-file-contents file)
         (should (string-match-p "tomorrow" (buffer-string)))
         (should-not (string-match-p "today" (buffer-string))))))))

(ert-deftest chat-log-drops-the-oldest-rotations-past-its-cap ()
  "Rotations are bounded in total, so the log cannot grow without end."
  (chat-test-with-temp-dir
   (let* ((file (expand-file-name chat-log-file))
          (chat-log-max-total-bytes 100))
     (dolist (day '("2026-01-01" "2026-01-02" "2026-01-03"))
       (write-region (make-string 80 ?x) nil (concat file "." day)
                     nil 'silent))
     (chat-log--prune)
     (should-not (file-exists-p (concat file ".2026-01-01")))
     (should (file-exists-p (concat file ".2026-01-03"))))))

(provide 'test-log-discipline)
;;; test-log-discipline.el ends here
