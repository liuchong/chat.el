;;; test-chat-request-panel.el --- Tests for request panel -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-request-panel)

(ert-deftest chat-request-panel-update-renders-request-and-tool-events ()
  "Test the request panel renders diagnostics and tool steps."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        panel-buffer)
    (puthash "req-panel"
             (make-chat-request-trace
              :id "req-panel"
              :mode 'chat
              :provider 'kimi
              :model 'kimi
              :phase 'tool-loop
              :started-at (current-time)
              :updated-at (current-time)
              :events '((:type request-dispatched :summary "Dispatch")
                        (:type tool-loop-step :summary "Resolving tool step 1")))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (setq panel-buffer
            (chat-request-panel--buffer (current-buffer)))
      (chat-request-panel-update
       (current-buffer)
       "req-panel"
       '((:type tool-call :index 1 :tool "files_find")
         (:type tool-result :index 1 :result-summary "3 matches")))
      (with-current-buffer panel-buffer
        (goto-char (point-min))
        (should (search-forward "Request Panel" nil t))
        (should (search-forward "Request: req-panel" nil t))
        (should (search-forward "Tool Call 1: files_find" nil t))
        (should (search-forward "Tool Result 1: 3 matches" nil t))
        (should (search-forward "tool-loop-step" nil t))))))

(ert-deftest chat-request-panel-toggle-closes-open-panel ()
  "Test toggling closes an already open request panel."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        displayed)
    (puthash "req-panel"
             (make-chat-request-trace
              :id "req-panel"
              :mode 'chat
              :provider 'kimi
              :model 'kimi
              :phase 'waiting
              :started-at (current-time)
              :updated-at (current-time))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (cl-letf (((symbol-function 'display-buffer-in-side-window)
                 (lambda (buffer _alist)
                   (setq displayed buffer)
                   (display-buffer buffer))))
        (chat-request-panel-toggle (current-buffer) "req-panel" nil)
        (should (bufferp displayed))
        (chat-request-panel-toggle (current-buffer) "req-panel" nil)
        (should-not (get-buffer (chat-request-panel--buffer-name (current-buffer))))))))

(ert-deftest chat-request-panel-renders-approval-context-and-whitelist-updates ()
  "Test the request panel renders approval decisions and whitelist mutations."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        panel-buffer)
    (puthash "req-panel"
             (make-chat-request-trace
              :id "req-panel"
              :mode 'chat
              :provider 'kimi
              :model 'kimi
              :phase 'tool-loop
              :started-at (current-time)
              :updated-at (current-time))
             chat-request-diagnostics--traces)
    (with-temp-buffer
      (setq panel-buffer
            (chat-request-panel--buffer (current-buffer)))
      (chat-request-panel-update
       (current-buffer)
       "req-panel"
       '((:type approval-pending
          :index 1
          :tool "shell_execute"
          :command "rg -n StickerManager ."
          :options (("allow once" . allow-once)
                    ("allow for session" . allow-session)
                    ("always allow this tool" . allow-tool)
                    ("always allow this command" . allow-command)
                    ("deny" . deny)))
         (:type approval
          :index 1
          :tool "shell_execute"
          :command "rg -n StickerManager ."
          :decision allow-command)
         (:type whitelist-update
          :index 1
          :tool "shell_execute"
          :scope command
          :pattern "rg -n StickerManager .")))
      (with-current-buffer panel-buffer
        (goto-char (point-min))
        (should (search-forward "Approval Pending 1: shell_execute" nil t))
        (should (search-forward "Command: rg -n StickerManager ." nil t))
        (should (search-forward "Choices: allow once, allow for session, always allow this tool, always allow this command, deny" nil t))
        (should (search-forward "Approval 1: allow-command" nil t))
        (should (search-forward "Whitelist 1: command rg -n StickerManager ." nil t))))))

(provide 'test-chat-request-panel)
