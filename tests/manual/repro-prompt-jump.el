;;; repro-prompt-jump.el --- reproduce prompt jumping to top -*- lexical-binding: t -*-
(require 'chat)
(let* ((session (chat-session-create "repro" 'kimi)))
  (save-window-excursion
    (chat--open-chat-session session)
    (with-current-buffer (chat--buffer-name session)
      (let ((win (get-buffer-window (current-buffer) nil)))
        ;; Fake history: taller than the 24-line batch window.
        (chat-ui--append-to-messages
         (lambda ()
           (dotimes (i 120)
             (insert (format "history line %03d\n" i)))))
        ;; Emulate a live run tail.
        (setq chat-ui--live-start (copy-marker chat-ui--messages-end nil))
        ;; Idle user: cursor in the input area, window start in the
        ;; stable history region while riding the bottom.
        (goto-char (point-max))
        (set-window-point win (point-max))
        (set-window-start win (save-excursion
                                (goto-char (point-max))
                                (forward-line -20)
                                (point))
                          t)
        (redisplay t)
        (message "INIT  start-line=%d point-line=%d input-line=%d max-line=%d"
                 (line-number-at-pos (window-start win))
                 (line-number-at-pos (window-point win))
                 (line-number-at-pos (marker-position chat-ui--input-overlay))
                 (line-number-at-pos (point-max)))
        (dotimes (i 6)
          (chat-ui--render-response-state
           (current-buffer) nil
           (mapconcat (lambda (n) (format "stream text line %d" n))
                      (number-sequence 0 (* 3 i)) "\n")
           nil nil nil nil)
          (redisplay t)
          (message "CHUNK %d  start-line=%d point-line=%d input-line=%d max-line=%d"
                   i
                   (line-number-at-pos (window-start win))
                   (line-number-at-pos (window-point win))
                   (line-number-at-pos (marker-position chat-ui--input-overlay))
                   (line-number-at-pos (point-max))))))))
;;; repro-prompt-jump.el ends here
