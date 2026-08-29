;;; test-chat-work-plan-ui.el --- Input work-shelf UI tests -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-ui)
(require 'chat-work-plan)
(require 'chat-goal)
(require 'chat-plan-mode)
(require 'chat-changed-files)

(defun chat-work-plan-ui-test--session ()
  "Return one code-capable UI test session."
  (let ((session (chat-session-create "Plan UI" 'kimi)))
    (chat-session-metadata-set session 'code-enabled t)
    session))

(defun chat-work-plan-ui-test--region ()
  "Return the visible input work-shelf region."
  (buffer-substring-no-properties
   chat-ui--work-shelf-start chat-ui--work-shelf-end))

(defun chat-work-plan-ui-test--prompt-start ()
  "Return the first position in the visible input prompt."
  (car (chat-ui--input-prompt-bounds)))

(ert-deftest chat-work-shelf-defaults-closed-and-expands-without-key-focus ()
  "The two-level shelf is closed by default and owns no keyboard keys."
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
       (should (string-empty-p (chat-work-plan-ui-test--region)))
       (let* ((prompt-start (chat-work-plan-ui-test--prompt-start))
              (map (get-text-property prompt-start 'keymap)))
         (should (equal "▸" (buffer-substring-no-properties
                             prompt-start (1+ prompt-start))))
         (should (eq (lookup-key map [mouse-1])
                     'chat-ui-toggle-work-shelf))
         (should-not (lookup-key map (kbd "TAB")))
         (should-not (lookup-key map (kbd "RET")))
         (should-not (lookup-key map (kbd "<left>")))
         (should-not (lookup-key map "x")))
       (goto-char (point-max))
       (insert "draft 输入")
       (let ((input-offset (- (point)
                              (marker-position chat-ui--input-overlay))))
         (chat-ui-toggle-work-shelf)
         (should (= input-offset
                    (- (point)
                       (marker-position chat-ui--input-overlay)))))
       (should (equal "▸ TODO 0/2 · 分析现状\n"
                      (chat-work-plan-ui-test--region)))
       (goto-char chat-ui--work-shelf-start)
       (let ((map (get-text-property (point) 'keymap)))
         (should (eq 'todo (get-text-property
                            (point) 'chat-work-shelf-section)))
         (should (eq (lookup-key map [mouse-1])
                     'chat-ui-toggle-work-shelf-section))
         (should-not (lookup-key map (kbd "TAB")))
         (should-not (lookup-key map (kbd "RET")))
         (should-not (lookup-key map (kbd "<down>")))
         (should-not (lookup-key map "x")))
       (goto-char (point-max))
       (let ((input-offset (- (point)
                              (marker-position chat-ui--input-overlay))))
         (chat-ui-toggle-work-shelf-section nil 'todo)
         (should (= input-offset
                    (- (point)
                       (marker-position chat-ui--input-overlay)))))
       (let ((visible (chat-work-plan-ui-test--region)))
         (should (string-match-p "▾ TODO 0/2" visible))
         (should (string-match-p (regexp-quote "[ ] 分析现状") visible))
         (should (string-match-p (regexp-quote "[ ] 实现功能") visible)))
       (chat-ui-toggle-work-shelf)
       (should (string-empty-p (chat-work-plan-ui-test--region)))
       (chat-ui-toggle-work-shelf)
       (should (string-match-p "▾ TODO 0/2"
                               (chat-work-plan-ui-test--region)))
       (chat-ui-setup-buffer session)
       (should-not chat-ui--work-shelf-open)
       (should (string-empty-p (chat-work-plan-ui-test--region)))))))

(ert-deftest chat-work-shelf-event-adds-section-without-transcript-redraw ()
  "A provider event refreshes only the open shelf of its bound session."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui-toggle-work-shelf)
       (should (string-empty-p (chat-work-plan-ui-test--region)))
       (let ((conversation-start (marker-position chat-ui--conversation-start))
             (messages-end (marker-position chat-ui--messages-end)))
         (chat-work-plan-create
          session "Event"
          '(((id . "event") (title . "Event item"))))
         (should (equal "▸ TODO 0/1 · Event item\n"
                        (chat-work-plan-ui-test--region)))
         (should (= conversation-start
                    (marker-position chat-ui--conversation-start)))
         (should (= messages-end (marker-position chat-ui--messages-end))))))))

(ert-deftest chat-work-shelf-event-refreshes-only-affected-provider ()
  "A Goal event does not redraw sibling shelf sections."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session)))
     (chat-work-plan-create
      session "Work" '(((id . "work") (title . "Do work"))))
     (chat-goal-create
      session "Goal" '(((id . "goal") (title . "Goal evidence")))
      "Goal evidence is known")
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui-toggle-work-shelf)
       (let ((inserted nil)
             (original (symbol-function 'chat-ui--insert-work-shelf-section)))
         (cl-letf (((symbol-function 'chat-ui--insert-work-shelf-section)
                    (lambda (section)
                      (push (chat-work-shelf-section-id section) inserted)
                      (funcall original section))))
           (chat-event-emit
            'goal-progressed :session-id (chat-session-id session)
            :source 'test :payload nil))
         (should (equal '(goal) inserted)))))))

(ert-deftest chat-work-shelf-provider-order-and-independent-details ()
  "TODO, files, Goal and Plan appear in canonical independent sections."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session)))
     (chat-work-plan-create
      session "Work" '(((id . "work") (title . "Do work"))))
     (chat-changed-files-record-success
      session "evidence-1"
      (list (list :path "lisp/work.el"
                  :canonical-path
                  (expand-file-name "lisp/work.el" default-directory)
                  :operation 'added :turn-id "turn-1"))
      '("lisp/work.el"))
     (chat-goal-create
      session "完成跨轮目标"
      '(((id . "state") (title . "状态可恢复"))
        ((id . "tests") (title . "测试全部通过")))
      "全部必要条件都有可解析证据")
     (chat-plan-mode-enter session)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui-toggle-work-shelf)
       (let* ((visible (chat-work-plan-ui-test--region))
              (todo (string-match "TODO" visible))
              (files (string-match "Changed files" visible))
              (goal (string-match "Goal" visible))
              (plan (string-match (regexp-quote "Plan [researching]")
                                  visible)))
         (should (< todo files))
         (should (< files goal))
         (should (< goal plan)))
       (chat-ui-toggle-work-shelf-section nil 'changed-files)
       (chat-ui-toggle-work-shelf-section nil 'goal)
       (let ((visible (chat-work-plan-ui-test--region)))
         (should (string-match-p (regexp-quote "[+] lisp/work.el") visible))
         (should (string-match-p
                  "Stop: 全部必要条件都有可解析证据" visible))
         (should (string-match-p (regexp-quote "[ ] 状态可恢复")
                                 visible)))))))

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
       (chat-ui-toggle-work-shelf)
       (should (string-match-p (regexp-quote
                                "Plan [researching] · revision 1")
                               (chat-work-plan-ui-test--region)))
       (let ((plan
              (chat-work-plan-create
               session "Approved plan"
               '(((id . "step") (title . "Step")
                  (acceptance . "Evidence is recorded"))))))
         (chat-plan-mode-submit session (chat-work-plan-id plan) 1))
       (should (string-match-p (regexp-quote "Plan [ready]")
                               (chat-work-plan-ui-test--region)))
       (chat-ui--command-plan "approve")
       (should-not (chat-plan-mode-active-p session))
       (should-not (string-match-p "Plan \\[[^]]+\\]"
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

(ert-deftest chat-work-shelf-thousand-updates-preserve-input-and-window ()
  "Frequent shelf refreshes leave input, point and scroll anchors stable."
  (chat-test-with-temp-dir
   (let ((session (chat-work-plan-ui-test--session))
         (buffer (generate-new-buffer " *work-shelf-stability*")))
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
           (chat-ui-toggle-work-shelf)
           (chat-ui-toggle-work-shelf-section nil 'todo)
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
                          (ert-fail "shelf rendering scheduled a timer"))))
               (dotimes (_ 1000)
                 (chat-ui--render-work-shelf)))
             (should (= input-offset
                        (- (point)
                           (marker-position chat-ui--input-overlay))))
             (should (equal "draft 输入"
                            (buffer-substring-no-properties
                             chat-ui--input-overlay (point-max))))
             (should (= (marker-position anchor) (window-start window)))
             (should-not
              (overlays-in chat-ui--work-shelf-start
                           chat-ui--work-shelf-end))
             (set-marker anchor nil)))
       (when (buffer-live-p buffer)
         (kill-buffer buffer))))))

(provide 'test-chat-work-plan-ui)
;;; test-chat-work-plan-ui.el ends here
