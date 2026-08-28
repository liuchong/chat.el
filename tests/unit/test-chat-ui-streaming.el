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
  '(agent-start profile-resolved turn-start context-transformed steering
                prepared-next-turn stream-result tool-batch-start
                tool-batch-end turn-ended turn-failed truncated error)
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

(ert-deftest chat-ui-an-unhandled-event-is-named-and-not-printed ()
  "The clause that reports a dropped event printed the whole session.

`chat-agent--emit' puts `:run' on every event and the run holds the
session, so one `%S' wrote the entire conversation -- and seven event
types reach this clause, several times per turn."
  (should (equal (chat-ui--event-payload-keys
                  (list :type 'turn-start :step 2 :run 'the-whole-session
                        :messages '(a b) :model 'kimi))
                 "messages model"))
  (should (equal (chat-ui--event-payload-keys
                  (list :type 'agent-start :step 0 :run 'the-whole-session))
                 "nothing")))

(ert-deftest chat-ui-streaming-is-on-by-default ()
  "Off meant the whole reply landed in one callback at the end."
  (should (eq (default-value 'chat-ui-use-streaming) t))
  (should (custom-variable-p 'chat-ui-use-streaming)))

;; ------------------------------------------------------------------
;; Nothing on the request path may block
;; ------------------------------------------------------------------

(defconst test-chat-ui--blocking-calls
  '(url-retrieve-synchronously accept-process-output sleep-for sit-for
                               call-process call-process-shell-command)
  "Calls that stop the Emacs main loop.

Banned on the request path only.  `chat-llm--post-sync' exists on purpose
for callers that want to wait, and the file tools shell out; the rule is
that sending a message and drawing the reply must never wait.")

(defconst test-chat-ui--request-path
  '(("lisp/ui/chat-ui.el"
     chat-ui-send-message chat-ui--send-user-message chat-ui--get-response
     chat-ui--start-agent-run chat-ui--render-live-region
     chat-ui--insert-live-reasoning chat-ui--follow-live-output
     chat-ui--make-agent-event-handler)
    ("lisp/agent/chat-agent-loop.el"
     chat-agent--dispatch chat-agent--dispatch-stream
     chat-agent--dispatch-sync chat-agent--handle-result
     chat-agent--complete-result)
    ("lisp/core/chat-stream.el"
     chat-stream-request chat-stream--handle-output)
    ("lisp/llm/chat-llm.el"
     chat-llm-request-async chat-llm--post-async))
  "Functions a message passes through, by file.")

(defun test-chat-ui--function-source (file name)
  "Return the source sexp of NAME as written in FILE."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file chat-test-root-dir))
    (goto-char (point-min))
    (when (re-search-forward
           (format "^(\\(?:cl-\\)?defun %s[ \n]" (regexp-quote (symbol-name name)))
           nil t)
      (goto-char (match-beginning 0))
      (read (current-buffer)))))

(defun test-chat-ui--calls-in (form)
  "Return every symbol in FORM, flattened."
  (cond
   ((symbolp form) (list form))
   ((consp form) (append (test-chat-ui--calls-in (car form))
                         (test-chat-ui--calls-in (cdr form))))
   (t nil)))

(ert-deftest chat-ui-the-request-path-never-blocks ()
  "Sending a message and drawing the reply must not stop the main loop.

Acceptance item 21 of specs/004.  A blocking call anywhere along here
freezes the frame the user is trying to read and scroll while the answer
arrives."
  (let ((offenders nil))
    (dolist (entry test-chat-ui--request-path)
      (let ((file (car entry)))
        (dolist (name (cdr entry))
          (let ((source (test-chat-ui--function-source file name)))
            ;; A name that has been renamed away would pass vacuously.
            (should source)
            (dolist (call (test-chat-ui--calls-in source))
              (when (memq call test-chat-ui--blocking-calls)
                (push (list file name call) offenders)))))))
    (should-not offenders)))

(ert-deftest chat-ui-a-send-records-where-its-time-went ()
  "A hitch nobody measured is a hitch nobody can find.

The costs that decide whether RET feels instant live in the display and
in whatever hooks the reader's configuration installs, and neither exists
in batch mode or in an `emacs -Q'.  So the path has to measure itself
where the complaint happens, and the mark before the paint is the one
that matters: everything ahead of it stands between the keystroke and the
reader seeing their own question."
  (let ((log-file (make-temp-file "chat-timing")))
    (unwind-protect
        (chat-test-with-temp-dir
         (let* ((chat-log-file log-file)
                (chat-log-enabled t)
                (chat-log-timings t)
                (chat-session-directory temp-dir)
                (chat-input-history-file
                 (expand-file-name "history.eld" temp-dir))
                (session (chat-session-create "Timing" 'kimi)))
           (with-temp-buffer
             (setq-local chat--current-session session)
             (chat-ui-setup-buffer session)
             (cl-letf (((symbol-function 'chat-agent-start)
                        (lambda (&rest _) nil)))
               (goto-char (point-max))
               (insert "a question")
               (chat-ui-send-message)))
           (let ((logged (with-temp-buffer
                           (insert-file-contents log-file)
                           (buffer-string))))
             (should (string-match-p "\\[TIMING\\]" logged))
             ;; The phases, in the order the path runs them.  Split finely
             ;; enough to name a culprit: the first real measurement put
             ;; 98% of a send inside one unbroken phase, which located
             ;; nothing.
             ;; The run itself marks the phases past this point, so with
             ;; the transport stubbed out the line ends at the handover.
             (should (equal (chat-test-timing-phases logged)
                            '("prompt" "history" "record" "redraw" "live"
                              "PAINT" "tools" "start")))
             ;; And the facts about the buffer that explain an outlier.
             (should (string-match-p "total [0-9]+ms" logged))
             (should (string-match-p "post-command hooks" logged)))))
      (delete-file log-file))))

(defun chat-test-timing-phases (logged)
  "Return the phase labels, in order, from the timing line in LOGGED."
  (let ((line (car (last (split-string (string-trim logged) "\n")))))
    (mapcar (lambda (phase) (car (split-string (string-trim phase) " ")))
            (split-string
             (car (split-string
                   (cadr (split-string line "\\[TIMING\\] [^:]+: "))
                   " | "))
             " -> "))))

(ert-deftest chat-ui-a-phase-is-charged-for-the-collection-it-triggered ()
  "A wall-clock number alone blames whoever was running when the GC landed.

The same phase measured 924ms once and 29ms every time after, which reads
as expensive work but is the shape of a collection falling on whoever
happened to allocate past the threshold.  Attributing the collections to
the phase they happened in is what tells those two apart."
  (let ((log-file (make-temp-file "chat-timing")))
    (unwind-protect
        (let ((chat-log-file log-file)
              (chat-log-enabled t)
              (chat-log-timings t))
          (chat-log-timing-start)
          (chat-log-timing-mark "quiet")
          (garbage-collect)
          (chat-log-timing-mark "collected")
          (chat-log-timing-report "probe")
          (let ((logged (with-temp-buffer
                          (insert-file-contents log-file)
                          (buffer-string))))
            ;; The phase that provoked the collection carries it, and the
            ;; one before it stays clean.
            (should (string-match-p "collected [0-9]+ \\[gc [0-9]+, [0-9]+ms\\]"
                                    logged))
            (should-not (string-match-p "quiet [0-9]+ \\[gc" logged))
            (should (string-match-p "total [0-9]+ms, gc [0-9]+ [0-9]+ms"
                                    logged))))
      (delete-file log-file))))

(ert-deftest chat-ui-timings-can-be-turned-off ()
  "Measuring is cheap, but nothing that logs every send is unconditional."
  (let ((chat-log-timings nil))
    (chat-ui--clock-start)
    (chat-ui--clock "prompt")
    (should-not chat-log--clock)
    (should-not chat-log--marks)))

(ert-deftest chat-ui-the-paint-before-the-request-cannot-be-skipped ()
  "`redisplay' with no argument does nothing while input is pending.

It returns nil to say so, and a send is exactly when something is likely
to be queued -- a held key, an autorepeat, a second RET.  So the one
paint standing between the keystroke and the request was the one most
liable to be skipped, which puts the reader back to seeing nothing until
the command returns.  Asserted in the source because batch mode never
paints and reports no window worth painting into."
  (let* ((source (test-chat-ui--function-source
                  "lisp/ui/chat-ui.el" 'chat-ui--start-agent-run))
         (calls (test-chat-ui--calls-in source)))
    (should source)
    ;; Present at all: without it there is no paint before the transport.
    (should (memq 'redisplay calls))
    ;; And forced.  Read as text, since the argument is what distinguishes
    ;; the two and a flattened symbol list cannot show it.
    (with-temp-buffer
      (insert (format "%S" source))
      (goto-char (point-min))
      (should (search-forward "(redisplay t)" nil t))
      (goto-char (point-min))
      (should-not (search-forward "(redisplay)" nil t)))))

;; The rule is tested rather than the scrolling, because a batch window
;; reports its end as the end of the buffer whatever the buffer holds, so
;; every window looks like it is at the bottom and no arrangement of one
;; can tell the two cases apart.

(ert-deftest chat-ui-live-output-never-recenters-the-input-point ()
  "A growing reply scrolls by the minimum needed instead of jumping halfway."
  (with-temp-buffer
    (chat-mode)
    ;; Emacs assigns the special never-recenter behaviour to values above
    ;; 100.  Testing the buffer policy is deterministic in batch, unlike
    ;; redisplay itself, which has no graphical window here.
    (should (> scroll-conservatively 100))))

(ert-deftest chat-ui-a-scrolled-reader-is-left-alone ()
  "Being pulled back to the bottom mid-read is worse than no following."
  (should-not (chat-ui-window-follows-p 100 400 nil 1 5000)))

(ert-deftest chat-ui-a-reader-at-the-edge-keeps-up ()
  "Someone already at the end does want the new output."
  (should (chat-ui-window-follows-p 4900 5000 nil 1 5000)))

(ert-deftest chat-ui-a-window-just-short-of-the-end-still-follows ()
  "Exactly at the end is too strict; a line or two of slack is not."
  (should (chat-ui-window-follows-p 4900 4950 nil 1 5000))
  (should-not (chat-ui-window-follows-p 4900 4800 nil 1 5000)))

(ert-deftest chat-ui-a-cursor-in-the-input-area-is-never-moved ()
  "Following while someone types would take the cursor out from under them."
  (should-not (chat-ui-window-follows-p 4990 5000 4980 1 5000)))

(ert-deftest chat-ui-a-short-buffer-always-follows ()
  "A buffer smaller than the slack has no scrolled-up state to protect."
  (should (chat-ui-window-follows-p 1 20 nil 1 20)))

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
