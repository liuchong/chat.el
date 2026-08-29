;;; test-chat-work-shelf.el --- Work-shelf provider tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-work-shelf)

(ert-deftest chat-work-shelf-provider-registry-orders-and-bounds-output ()
  "Providers are ordered deterministically and cannot return unbounded text."
  (let ((chat-work-shelf-providers nil)
        (chat-work-shelf-summary-width 8)
        (chat-work-shelf-detail-width 10)
        (chat-work-shelf-detail-limit 2))
    (chat-work-shelf-register-provider
     (chat-work-shelf-provider-create
      :id 'late :priority 20
      :project-fn (lambda (_session) 'late)
      :summary-fn (lambda (_projection) "long summary text")
      :details-fn (lambda (_projection)
                    '("first detail row" "second detail row" "third row"))
      :event-types '(late-updated)))
    (chat-work-shelf-register-provider
     (chat-work-shelf-provider-create
      :id 'early :priority 10
      :project-fn (lambda (_session) 'early)
      :summary-fn (lambda (_projection) "early")
      :details-fn (lambda (_projection) nil)
      :event-types '(early-updated)))
    (let ((sections (chat-work-shelf-project nil)))
      (should (equal '(early late)
                     (mapcar #'chat-work-shelf-section-id sections)))
      (let ((late (cadr sections)))
        (should (<= (string-width (chat-work-shelf-section-summary late)) 8))
        (should (= 3 (length (chat-work-shelf-section-detail-lines late))))
        (should (string-match-p
                 "more" (car (last
                               (chat-work-shelf-section-detail-lines late)))))
        (dolist (line (butlast
                       (chat-work-shelf-section-detail-lines late)))
          (should (<= (string-width line) 10)))))
    (let ((event (chat-event-create
                  :type 'late-updated :session-id "session"
                  :timestamp-ms 0 :source 'test)))
      (should (equal '(late)
                     (chat-work-shelf-provider-ids-for-event event))))))

(ert-deftest chat-work-shelf-projection-does-not-scan-files-or-run-processes ()
  "Built-in projection reads indexed session state without synchronous scans."
  (chat-test-with-temp-dir
   (let ((session (chat-session-create "No scan" 'kimi)))
     (chat-work-plan-create
      session "No scan" '(((id . "one") (title . "One"))))
     (cl-letf (((symbol-function 'directory-files)
                (lambda (&rest _args) (ert-fail "directory scan"))))
       (should (equal '(todo)
                      (mapcar #'chat-work-shelf-section-id
                              (chat-work-shelf-project session))))))))

(provide 'test-chat-work-shelf)
;;; test-chat-work-shelf.el ends here
