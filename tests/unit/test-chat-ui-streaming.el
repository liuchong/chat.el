;;; test-chat-ui-streaming.el --- Test streaming response timer fix -*- lexical-binding: t -*-

;;; Commentary:
;; This test verifies that the streaming response timer fix works correctly.
;; The fix uses closure variable capture instead of timer argument passing
;; to avoid wrong-number-of-arguments errors in lexical binding mode.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-paths)
(require 'chat-ui)

;; ------------------------------------------------------------------
;; The event contract
;; ------------------------------------------------------------------

(defconst test-chat-ui--agent-event-sources
  '("lisp/agent/chat-agent-loop.el" "lisp/agent/chat-agent.el")
  "Files that emit agent events.")

(defconst test-chat-ui--events-without-a-branch
  '(agent-start turn-start context-transformed steering
                prepared-next-turn stream-result tool-batch-start
                tool-batch-end truncated error)
  "Emitted events the UI handler deliberately leaves to the catch-all.

Listed one by one on purpose.  Adding an event to the agent and forgetting
the UI is how a minute of streamed reasoning went missing, so a new event
has to be named here or given a branch; it cannot simply vanish.")

(defun test-chat-ui--emitted-events ()
  "Return every event type the agent emits, read from the source."
  (let ((types nil))
    (dolist (file test-chat-ui--agent-event-sources)
      (with-temp-buffer
        (insert-file-contents (expand-file-name file chat-test-root-dir))
        (goto-char (point-min))
        (while (re-search-forward
                "chat-agent--emit[[:space:]\n]+run[[:space:]\n]+'\\([a-z-]+\\)"
                nil t)
          (push (intern (match-string 1)) types))))
    (delete-dups types)))

(defun test-chat-ui--handled-events ()
  "Return every event type the UI handler names in a branch."
  (let ((types nil))
    (with-temp-buffer
      (insert-file-contents
       (expand-file-name "lisp/ui/chat-ui.el" chat-test-root-dir))
      (goto-char (point-min))
      (when (re-search-forward
             "defun chat-ui--make-agent-event-handler" nil t)
        (let ((end (save-excursion
                     (beginning-of-line)
                     (forward-sexp)
                     (point))))
          (while (re-search-forward "(eq type '\\([a-z-]+\\))" end t)
            (push (intern (match-string 1)) types)))))
    (delete-dups types)))

(ert-deftest chat-ui-every-agent-event-is-accounted-for ()
  "No event the agent emits may go unnoticed.

`stream-reasoning' was emitted and nothing listened, so a reasoning model
could think for a minute with the screen perfectly still and no error
anywhere.  This is the test that makes the omission loud."
  (let* ((emitted (test-chat-ui--emitted-events))
         (handled (test-chat-ui--handled-events))
         (unaccounted (seq-remove
                       (lambda (type)
                         (or (memq type handled)
                             (memq type
                                   test-chat-ui--events-without-a-branch)))
                       emitted)))
    (should emitted)
    (should (memq 'stream-reasoning handled))
    (should (null unaccounted))))

(ert-deftest chat-ui-the-event-handler-has-a-catch-all ()
  "A `cond' with no final clause drops what it does not name."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "lisp/ui/chat-ui.el" chat-test-root-dir))
    (goto-char (point-min))
    (should (re-search-forward "defun chat-ui--make-agent-event-handler" nil t))
    (let ((end (save-excursion (beginning-of-line) (forward-sexp) (point))))
      (should (re-search-forward "Unhandled agent event" end t)))))

;; ------------------------------------------------------------------
;; Live reasoning
;; ------------------------------------------------------------------

(ert-deftest chat-ui-live-reasoning-reads-the-accumulated-field ()
  "The event carries the running total as `:reasoning', the delta as `:text'.

The chunk event names its two the other way round, `:content' and
`:text', so reading `:content' here silently yields nothing."
  (let ((event (list :type 'stream-reasoning
                     :text "ing about it"
                     :reasoning "Think" )))
    (should (equal (plist-get event :reasoning) "Think"))
    (should-not (plist-get event :content))))

(ert-deftest chat-ui-reasoning-shows-its-tail-while-it-is-the-newest-thing ()
  "Expanded while nothing else is happening, per folding rule 2."
  (with-temp-buffer
    (setq-local chat-ui--live-reasoning-content
                "line one\nline two\nline three")
    (setq-local chat-ui--live-response-content "")
    (let ((chat-ui-live-reasoning-lines 2))
      (chat-ui--insert-live-reasoning))
    (let ((text (buffer-string)))
      (should (string-match-p "line two" text))
      (should (string-match-p "line three" text))
      (should-not (string-match-p "line one" text)))))

(ert-deftest chat-ui-reasoning-collapses-once-the-answer-starts ()
  "Folding rule 2: a reasoning segment folds as soon as anything follows it."
  (with-temp-buffer
    (setq-local chat-ui--live-reasoning-content "some thinking here")
    (setq-local chat-ui--live-response-content "The answer begins")
    (chat-ui--insert-live-reasoning)
    (let ((text (buffer-string)))
      (should-not (string-match-p "some thinking here" text))
      (should (string-match-p "18" text)))))

(ert-deftest chat-ui-no-reasoning-draws-nothing ()
  "A model that does not think leaves no trace of thinking."
  (with-temp-buffer
    (setq-local chat-ui--live-reasoning-content "")
    (setq-local chat-ui--live-response-content "answer")
    (chat-ui--insert-live-reasoning)
    (should (string-empty-p (buffer-string)))))

(ert-deftest chat-ui-streaming-is-on-by-default ()
  "Off meant the whole reply landed in one callback at the end."
  (should (eq (default-value 'chat-ui-use-streaming) t))
  (should (custom-variable-p 'chat-ui-use-streaming)))

(ert-deftest chat-ui-streaming-timer-lexical-binding ()
  "Test that run-with-idle-timer callback works with lexical binding."
  (let ((result nil)
        (callback nil)
        (var1 "test1")
        (var2 "test2"))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (&rest args)
                 (setq callback (nth 2 args)))))
      ;; Use closure capture like the fix does.
      (let ((v1 var1)
            (v2 var2))
        (run-with-idle-timer
         0.01 nil
         (lambda ()
           (setq result (cons v1 v2))))))
    (should callback)
    (funcall callback)
    (should (equal result '("test1" . "test2")))))

(ert-deftest chat-ui-streaming-timer-error-handling ()
  "Test that timer callback error handling works."
  (let ((callback nil)
        (caught-error nil))
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (&rest args)
                 (setq callback (nth 2 args)))))
      (let ((test-var "value"))
        (run-with-idle-timer
         0.01 nil
         (lambda ()
           (condition-case err
               (progn
                 (should (string= test-var "value"))
                 (error "intentional"))
             (error
              (setq caught-error (car err))))))))
    (should callback)
    (funcall callback)
    (should (eq caught-error 'error))))

(provide 'test-chat-ui-streaming)
;;; test-chat-ui-streaming.el ends here
