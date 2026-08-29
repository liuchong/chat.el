;;; test-send-modes.el --- Sending while something runs -*- lexical-binding: t; -*-

;;; Commentary:

;; Three meanings for pressing return during a run, and the test that
;; matters most is the one about the word "queue": mode words are read from
;; an explicit `/send' and nowhere else, because plain input reaches the
;; same handler and would otherwise lose its first word.

;;; Code:

(require 'ert)
(require 'chat-ui)

;; ------------------------------------------------------------------
;; Reading a mode off the front of a message
;; ------------------------------------------------------------------

(ert-deftest chat-send-a-mode-name-is-read-off-the-front ()
  "A leading mode name is taken as the mode, and the rest as the message."
  (should (equal '(queue . "修一下这个")
                 (chat-ui--split-send-mode "queue 修一下这个")))
  (should (equal '(interrupt . "算了改这个")
                 (chat-ui--split-send-mode "interrupt 算了改这个")))
  (should (equal '(insert . "补一句")
                 (chat-ui--split-send-mode "insert 补一句"))))

(ert-deftest chat-send-a-mode-name-alone-names-no-message ()
  "A mode with nothing after it is a mode, not a message.
Which is what makes `/send queue' a setting rather than a message whose
text happens to be a mode name."
  (should (equal '(queue . "") (chat-ui--split-send-mode "queue")))
  (should (equal '(queue . "") (chat-ui--split-send-mode "  queue  "))))

(ert-deftest chat-send-a-word-that-is-not-a-mode-is-just-a-word ()
  "Only the three names are modes, and only exactly."
  (should-not (chat-ui--split-send-mode "queued the build"))
  (should-not (chat-ui--split-send-mode "queues"))
  (should-not (chat-ui--split-send-mode "把这个 queue 起来"))
  (should-not (chat-ui--split-send-mode "")))

(ert-deftest chat-send-typed-input-keeps-its-first-word ()
  "Typing \"queue the build\" sends those three words.

The trap this exists for: plain input and `/send' reach the same handler,
so a handler that reads mode words from both would send \"the build\" and
queue it, silently eating the word the user typed."
  (let ((sent nil))
    (cl-letf (((symbol-function 'chat-ui--send-user-message)
               (lambda (content &optional _parts _metadata)
                 (setq sent content)))
              ((symbol-function 'chat-agent-active-p) (lambda (_) nil)))
      (let ((chat-ui--input-was-typed t))
        (chat-ui--command-send "queue the build for tomorrow"))
      (should (equal "queue the build for tomorrow" sent))
      ;; Asked for explicitly, it is a mode.
      (setq sent nil)
      (let ((chat-ui--input-was-typed nil))
        (chat-ui--command-send "insert the build for tomorrow"))
      (should (equal "the build for tomorrow" sent)))))

;; ------------------------------------------------------------------
;; With nothing running, the modes are the same thing
;; ------------------------------------------------------------------

(ert-deftest chat-send-modes-agree-when-nothing-is-running ()
  "There is nothing to insert into, wait for, or interrupt."
  (dolist (mode chat-ui-send-modes)
    (let ((sent nil))
      (cl-letf (((symbol-function 'chat-ui--send-user-message)
                 (lambda (content &optional _parts _metadata)
                   (setq sent content)))
                ((symbol-function 'chat-agent-active-p) (lambda (_) nil)))
        (chat-ui--send-in-mode "问题" mode)
        (should (equal "问题" sent))))))

;; ------------------------------------------------------------------
;; queue
;; ------------------------------------------------------------------

(ert-deftest chat-send-queue-waits-instead-of-injecting ()
  "Queued input does not reach the run in progress."
  (let ((steered nil))
    (cl-letf (((symbol-function 'chat-agent-active-p) (lambda (_) t))
              ((symbol-function 'chat-ui--steer-active-agent)
               (lambda (c) (setq steered c))))
      (with-temp-buffer
        (setq-local chat-ui--queued-sends nil)
        (chat-ui--send-in-mode "等会儿再说" 'queue)
        (should-not steered)
        (should (equal '("等会儿再说")
                       (mapcar #'chat-ui--draft-text
                               chat-ui--queued-sends)))))))

(ert-deftest chat-send-queue-keeps-arrival-order-and-does-not-merge ()
  "Two queued messages become two runs, in the order they arrived.
Merging them would be `insert', and choosing `queue' is choosing not to."
  (let ((sent nil))
    (cl-letf (((symbol-function 'chat-agent-active-p) (lambda (_) t))
              ((symbol-function 'chat-ui--send-user-message)
               (lambda (c &optional _parts _metadata) (push c sent))))
      (with-temp-buffer
        (setq-local chat-ui--queued-sends nil)
        (chat-ui--send-in-mode "第一件" 'queue)
        (chat-ui--send-in-mode "第二件" 'queue)
        (should (equal '("第一件" "第二件")
                       (mapcar #'chat-ui--draft-text
                               chat-ui--queued-sends)))
        (chat-ui--drain-queued-sends)
        ;; Through a timer, so that it does not run inside the handler of
        ;; the run it was waiting for.
        (sit-for 0.05)
        (should (equal '("第一件") sent))
        (should (equal '("第二件")
                       (mapcar #'chat-ui--draft-text
                               chat-ui--queued-sends)))
        (chat-ui--drain-queued-sends)
        (sit-for 0.05)
        (should (equal '("第二件" "第一件") sent))))))

(ert-deftest chat-send-queue-drains-on-nothing-queued ()
  "Draining an empty queue is not an error and sends nothing."
  (with-temp-buffer
    (setq-local chat-ui--queued-sends nil)
    (should-not (chat-ui--drain-queued-sends))))

(ert-deftest chat-send-attachments-wait-as-one-typed-draft ()
  "An attachment submitted during a run starts the next turn intact."
  (let* ((digest (make-string 64 ?a))
         (part (chat-content-part-create
                :type 'image :attachment-id digest :name "screen.png"
                :mime-type "image/png" :size 12 :sha256 digest))
         sent-text
         sent-parts)
    (cl-letf (((symbol-function 'chat-agent-active-p) (lambda (_) t))
              ((symbol-function 'chat-ui--send-user-message)
               (lambda (text &optional parts _metadata)
                 (setq sent-text text sent-parts parts))))
      (with-temp-buffer
        (setq-local chat-ui--queued-sends nil)
        (chat-ui--send-in-mode "look" 'insert (list part))
        (should (= 1 (length chat-ui--queued-sends)))
        (should (equal (list part)
                       (chat-ui--draft-parts (car chat-ui--queued-sends))))
        (chat-ui--drain-queued-sends)
        (sit-for 0.05)
        (should (equal "look" sent-text))
        (should (equal (list part) sent-parts))))))

;; ------------------------------------------------------------------
;; interrupt
;; ------------------------------------------------------------------

(ert-deftest chat-send-interrupt-keeps-what-had-been-produced ()
  "The half-written reply survives the interruption as context.

It did not before: cancelling made the stream sentinel skip the result
handler and the UI's `cancelled' branch only clean up, so the text that
had arrived was dropped and \"the partial result is used as context\" had
nothing to point at."
  (chat-test-with-temp-dir
   (let ((session (chat-session-create "interrupt"))
         (sent nil)
         (cancelled nil))
     (cl-letf (((symbol-function 'chat-agent-active-p) (lambda (_) t))
               ((symbol-function 'chat-ui-cancel-response)
                (lambda () (setq cancelled t)))
               ((symbol-function 'chat-ui--redraw-conversation) #'ignore)
               ((symbol-function 'chat-ui--send-user-message)
                (lambda (c &optional _parts _metadata) (setq sent c))))
       (with-temp-buffer
         (setq-local chat--current-session session)
         (setq-local chat-ui--live-response-content
                     "一半的回答，还没写完")
         (chat-ui--send-in-mode "算了，改做这个" 'interrupt)))
     (should cancelled)
     (should (equal "算了，改做这个" sent))
     (let ((kept (car (last (chat-session-messages session)))))
       (should (eq :assistant (chat-message-role kept)))
       (should (string-match-p "\\[interrupted after 10 characters\\]"
                               (chat-message-content kept)))
       (should (string-match-p "一半的回答，还没写完"
                               (chat-message-content kept)))))))

(ert-deftest chat-send-interrupt-writes-nothing-when-nothing-arrived ()
  "Interrupting before the first token leaves no empty message behind."
  (chat-test-with-temp-dir
   (let ((session (chat-session-create "interrupt-early"))
         (before nil))
     (setq before (length (chat-session-messages session)))
     (cl-letf (((symbol-function 'chat-agent-active-p) (lambda (_) t))
               ((symbol-function 'chat-ui-cancel-response) #'ignore)
               ((symbol-function 'chat-ui--redraw-conversation) #'ignore)
               ((symbol-function 'chat-ui--send-user-message) #'ignore))
       (with-temp-buffer
         (setq-local chat--current-session session)
         (setq-local chat-ui--live-response-content "   ")
         (chat-ui--send-in-mode "换个问题" 'interrupt)))
     (should (= before (length (chat-session-messages session)))))))

(ert-deftest chat-send-interrupt-carries-typed-attachments-to-the-new-turn ()
  "Interrupt mode cancels first and then sends the attachment-bearing turn."
  (let* ((digest (make-string 64 ?d))
         (part (chat-content-part-create
                :type 'image :attachment-id digest :name "new.png"
                :mime-type "image/png" :size 12 :sha256 digest))
         cancelled
         sent-parts)
    (cl-letf (((symbol-function 'chat-agent-active-p) (lambda (_) t))
              ((symbol-function 'chat-ui-cancel-response)
               (lambda () (setq cancelled t)))
              ((symbol-function 'chat-ui--redraw-conversation) #'ignore)
              ((symbol-function 'chat-ui--send-user-message)
               (lambda (_text &optional parts _metadata)
                 (setq sent-parts parts))))
      (with-temp-buffer
        (setq-local chat-ui--live-response-content "")
        (chat-ui--send-in-mode "replace it" 'interrupt (list part))))
    (should cancelled)
    (should (equal (list part) sent-parts))))

;; ------------------------------------------------------------------
;; Choosing a mode
;; ------------------------------------------------------------------

(ert-deftest chat-send-a-mode-on-its-own-changes-the-default ()
  "`/send queue' with no message sets the mode for later ones."
  (with-temp-buffer
    (should (eq chat-send-default-mode (chat-ui-send-mode)))
    (let ((chat-ui--input-was-typed nil))
      (chat-ui--command-send "queue"))
    (should (eq 'queue (chat-ui-send-mode)))
    (let ((chat-ui--input-was-typed nil))
      (chat-ui--command-send "interrupt"))
    (should (eq 'interrupt (chat-ui-send-mode)))))

(ert-deftest chat-send-default-mode-is-what-it-has-always-done ()
  "The default is `insert', because changing it would change behaviour
for every existing user without their asking."
  (should (eq 'insert chat-send-default-mode)))

(provide 'test-send-modes)
;;; test-send-modes.el ends here
