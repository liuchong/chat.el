;;; test-chat-work-plan-ui.el --- Native work-plan UI tests -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-ui)
(require 'chat-work-plan)

(defun chat-work-plan-ui-test--session ()
  "Return one code-capable UI test session."
  (let ((session (chat-session-create "Plan UI" 'kimi)))
    (chat-session-metadata-set session 'code-enabled t)
    session))

(defun chat-work-plan-ui-test--region ()
  "Return the visible native plan region."
  (buffer-substring-no-properties chat-ui--plan-start chat-ui--plan-end))

(ert-deftest chat-work-plan-ui-renders-collapsed-and-expanded-cjk-items ()
  "The native plan view is compact by default and expands in place."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session)))
     (chat-work-plan-create
      session "完善聊天计划"
      '(((id . "inspect") (title . "分析现状"))
        ((id . "implement") (title . "实现功能")
         (dependencies . ["inspect"]))))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (should (equal "Plan 1/2 · 分析现状\n"
                      (chat-work-plan-ui-test--region)))
       (goto-char chat-ui--plan-start)
       (should (keymapp (get-text-property (point) 'keymap)))
       (chat-ui-toggle-work-plan)
       (let ((visible (chat-work-plan-ui-test--region)))
         (should (string-match-p "\\[ \\] 分析现状" visible))
         (should (string-match-p "\\[ \\] 实现功能" visible)))))))

(ert-deftest chat-work-plan-ui-event-adds-plan-without-transcript-redraw ()
  "A plan event refreshes only the plan region of its bound session."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (should (string-empty-p (chat-work-plan-ui-test--region)))
       (let ((conversation-start (marker-position chat-ui--conversation-start))
             (messages-end (marker-position chat-ui--messages-end)))
         (chat-work-plan-create
          session "Event"
          '(((id . "event") (title . "Event item"))))
         (should (equal "Plan 1/1 · Event item\n"
                        (chat-work-plan-ui-test--region)))
         (should (= conversation-start
                    (marker-position chat-ui--conversation-start)))
         (should (= messages-end (marker-position chat-ui--messages-end))))))))

(ert-deftest chat-work-plan-ui-thousand-updates-preserve-input-and-window ()
  "Frequent plan refreshes leave input point and scroll anchors stable."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session))
         (buffer (generate-new-buffer " *plan-ui-stability*")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buffer)
           (setq-local chat--current-session session)
           (dotimes (index 250)
             (chat-session-add-message
              session
              (make-chat-message
               :id (format "m-%d" index) :role :user
               :content (format "transcript line %d" index)
               :timestamp (current-time))))
           (chat-work-plan-create
            session "Stable"
            '(((id . "stable") (title . "Stable item"))))
           (chat-ui-setup-buffer session)
           (goto-char (point-max))
           (insert "draft 输入")
           (let* ((input-offset (- (point)
                                   (marker-position chat-ui--input-overlay)))
                  (anchor (save-excursion
                            (goto-char (point-min))
                            (search-forward "transcript line 80")
                            (copy-marker (line-beginning-position) nil)))
                  (window (selected-window)))
             (set-window-start window anchor t)
             (cl-letf (((symbol-function 'run-at-time)
                        (lambda (&rest _)
                          (ert-fail "plan rendering scheduled a timer"))))
               (dotimes (_ 1000)
                 (chat-ui--render-work-plan)))
             (should (= input-offset
                        (- (point)
                           (marker-position chat-ui--input-overlay))))
             (should (equal "draft 输入"
                            (buffer-substring-no-properties
                             chat-ui--input-overlay (point-max))))
             (should (= (marker-position anchor) (window-start window)))
             (should-not (overlays-in chat-ui--plan-start chat-ui--plan-end))
             (set-marker anchor nil)))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))))))

(provide 'test-chat-work-plan-ui)
;;; test-chat-work-plan-ui.el ends here
