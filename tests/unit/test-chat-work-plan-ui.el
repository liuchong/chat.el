;;; test-chat-work-plan-ui.el --- Native work-plan UI tests -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-ui)
(require 'chat-work-plan)
(require 'chat-goal)
(require 'chat-plan-mode)

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

(ert-deftest chat-goal-ui-renders-collapsed-and-expanded-contract ()
  "The Goal summary and contract share the stable native work region."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session)))
     (chat-goal-create
      session "完成跨轮目标"
      '(((id . "state") (title . "状态可恢复"))
        ((id . "tests") (title . "测试全部通过")))
      "全部必要条件都有可解析证据")
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (should (equal "Goal [active] 0/2 · 完成跨轮目标\n"
                      (chat-work-plan-ui-test--region)))
       (goto-char chat-ui--plan-start)
       (should (eq (lookup-key (get-text-property (point) 'keymap)
                               (kbd "TAB"))
                   'chat-ui-toggle-goal))
       (chat-ui-toggle-goal)
       (let ((visible (chat-work-plan-ui-test--region)))
         (should (string-match-p "Stop: 全部必要条件都有可解析证据" visible))
         (should (string-match-p "\\[ \\] 状态可恢复" visible))
         (should (string-match-p "\\[ \\] 测试全部通过" visible)))))))

(ert-deftest chat-goal-slash-command-creates-and-controls-user-lifecycle ()
  "Slash controls own pause, resume and clear without exposing Agent tools."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui--command-goal "完成 Goal :: 验证测试通过")
       (should (eq 'active (chat-goal-status (chat-goal-current session))))
       (chat-ui--command-goal "pause")
       (should (eq 'paused (chat-goal-status (chat-goal-current session))))
       (chat-ui--command-goal "resume")
       (should (eq 'active (chat-goal-status (chat-goal-current session))))
       (chat-ui--command-goal "clear")
       (should-not (chat-goal-current session))
       (should (= 1 (length (chat-goal-list session))))))))

(ert-deftest chat-plan-mode-ui-and-slash-command-require-user-approval ()
  "Plan Mode stays visibly read-only until the user approves a ready plan."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui--command-plan "on")
       (should (string-match-p "Plan Mode \\[researching\\] · read-only"
                               (chat-work-plan-ui-test--region)))
       (let ((plan
              (chat-work-plan-create
               session "Approved plan"
               '(((id . "step") (title . "Step")
                  (acceptance . "Evidence is recorded"))))))
         (chat-plan-mode-submit session (chat-work-plan-id plan) 1))
       (should (string-match-p "Plan Mode \\[ready\\] · read-only"
                               (chat-work-plan-ui-test--region)))
       (chat-ui--command-plan "approve")
       (should-not (chat-plan-mode-active-p session))
       (should-not (string-match-p "Plan Mode \\[[^]]+\\] · read-only"
                                   (chat-work-plan-ui-test--region)))))))

(ert-deftest chat-goal-automatic-continuation-is-bounded-and-auditable ()
  "Goal continuation stops at its own budget and leaves needs-attention state."
  (chat-test-with-temp-dir
   (let* ((session (chat-work-plan-ui-test--session))
          (chat-goal-max-continuations-per-run 1))
     (chat-goal-create
      session "Continue Goal"
      '(((id . "done") (title . "Evidence is known")))
      "Required evidence is known")
     (let ((callback (chat-ui--goal-followup-function session)))
       (should (stringp (funcall callback nil)))
       (should-not (funcall callback nil)))
     (let ((goal (chat-goal-current session)))
       (should (eq 'active (chat-goal-status goal)))
       (should (string-match-p
                "budget exhausted"
                (chat-goal--get (chat-goal-metadata goal) 'needsAttention)))
       (should (string-match-p
                "Needs attention"
                (chat-context-fragment-payload
                 (chat-goal-context-fragment session))))))))

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
           (chat-goal-create
            session "Stable Goal"
            '(((id . "stable-goal") (title . "Stable Goal evidence")))
            "Stable Goal evidence is known")
           (chat-work-plan-create
            session "Stable"
            '(((id . "stable") (title . "Stable item"))))
           (chat-plan-mode-enter session)
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
