;;; test-chat-ui-transcript.el --- Transcript rendering and folding -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A run reasons, calls a tool, reads the result, reasons again, and only
;; then answers.  The display used to draw all of that into one mutable
;; region, so each step was deleted to make room for the next and the
;; reader was left with a question at the top, an answer at the bottom,
;; and nothing in between.
;;
;; These tests are about what is on screen, not about what is stored --
;; the record was already complete while the screen was not.  So they run
;; a real agent loop against a stub provider and then read the buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-ui)
(require 'chat-transcript)

(defun chat-ui-transcript-test--register-tool ()
  "Register the tool the stubbed run calls."
  (chat-tool-forge-register
   (make-chat-forged-tool
    :id 'demo_tool
    :name "Demo Tool"
    :description "Echo one argument"
    :language 'elisp
    :parameters '((:name "input" :type "string" :required t))
    :compiled-function (lambda (input) (format "echo:%s" input))
    :is-active t
    :usage-count 0)))

(defmacro chat-ui-transcript-test--with-run (bindings &rest body)
  "Run a two-step agent turn, then evaluate BODY in the chat buffer.

BINDINGS may set `responses' to override what the stub provider returns.
The default is a first step that calls a tool while also saying something,
and a second step that answers."
  (declare (indent 1))
  `(chat-test-with-temp-dir
    (let* ((chat-session-directory temp-dir)
           (chat-tool-forge--registry (make-hash-table :test 'eq))
           (session (chat-session-create "Transcript Session" 'kimi))
           (responses
            (list
             '(:content "Looking that up now.\n{\"function_call\":{\"name\":\"demo_tool\",\"arguments\":{\"input\":\"hi\"}}}")
             '(:content "The answer is 42.")))
           ,@bindings)
      (chat-ui-transcript-test--register-tool)
      (chat-session-add-message
       session
       (make-chat-message :id "user-1" :role :user
                          :content "Use a tool"
                          :timestamp (current-time)))
      (with-temp-buffer
        (setq-local chat--current-session session)
        (chat-ui-setup-buffer session)
        (cl-letf (((symbol-function 'chat-llm-request-async)
                   (lambda (_model _messages success _error _options)
                     (funcall success (pop responses))
                     'request-handle)))
          (chat-ui--get-response-sync))
        ,@body))))

(defun chat-ui-transcript-test--visible ()
  "Return the conversation area as a string."
  (buffer-substring-no-properties chat-ui--conversation-start
                                  chat-ui--messages-end))

(defun chat-ui-transcript-test--count (needle)
  "Return how many times NEEDLE appears in the conversation area."
  (let ((text (chat-ui-transcript-test--visible))
        (start 0)
        (count 0))
    (while (string-match (regexp-quote needle) text start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun chat-ui-transcript-test--fold-groups ()
  "Return the fold group keys on screen, in order."
  (let ((position chat-ui--conversation-start)
        groups)
    (while (and position (< position chat-ui--messages-end))
      (when-let ((group (get-text-property position 'chat-ui-fold-group)))
        (unless (member group groups)
          (push group groups)))
      (setq position (next-single-property-change
                      position 'chat-ui-fold-group nil chat-ui--messages-end)))
    (nreverse groups)))

(defun chat-ui-transcript-test--face-of (needle)
  "Return the face covering the first occurrence of NEEDLE."
  (save-excursion
    (goto-char chat-ui--conversation-start)
    (when (search-forward needle chat-ui--messages-end t)
      (get-text-property (match-beginning 0) 'face))))

;; ------------------------------------------------------------------
;; Nothing is thrown away
;; ------------------------------------------------------------------

(ert-deftest chat-ui-transcript-keeps-an-intermediate-step-on-screen ()
  "The prose of a step survives the step that follows it.

This is the whole complaint: the question stayed at the top, the answer
arrived at the bottom, and everything the run did in between was gone."
  (chat-ui-transcript-test--with-run ()
    (let ((visible (chat-ui-transcript-test--visible)))
      (should (string-match-p "Use a tool" visible))
      (should (string-match-p "Looking that up now" visible))
      (should (string-match-p "The answer is 42" visible)))))

(ert-deftest chat-ui-transcript-never-shows-the-tool-call-as-prose ()
  "A step's prose arrives with the tool call embedded; that is not prose."
  (chat-ui-transcript-test--with-run ()
    (should-not (string-match-p "function_call"
                                (chat-ui-transcript-test--visible)))))

(ert-deftest chat-ui-transcript-draws-the-answer-once ()
  "The answer is recorded and also arrives as the finished response.

Drawing both would show it twice."
  (chat-ui-transcript-test--with-run ()
    (should (= (chat-ui-transcript-test--count "The answer is 42.") 1))))

(ert-deftest chat-ui-transcript-survives-being-reopened ()
  "Reopening a session shows what the run showed.

The screen is drawn from the record, so a reload cannot show less than
the live run did -- which it did when the live run kept its steps in a
buffer region and the record was never read back."
  (chat-ui-transcript-test--with-run ()
    (let ((live (chat-ui-transcript-test--visible))
          (id (chat-session-id chat--current-session)))
      ;; Equality is only worth asserting if the live screen held the
      ;; steps in the first place.
      (should (string-match-p "Looking that up now" live))
      (should (string-match-p "The answer is 42" live))
      (chat-session-save chat--current-session)
      ;; A reopen is a fresh buffer over a session read back from disk,
      ;; not a redraw of the buffer that still holds the run's state.
      (with-temp-buffer
        (let ((reloaded (chat-session-load id)))
          (should reloaded)
          (setq-local chat--current-session reloaded)
          (chat-ui-setup-buffer reloaded)
          (should (equal (chat-ui-transcript-test--visible) live)))))))

;; ------------------------------------------------------------------
;; What folds and what does not
;; ------------------------------------------------------------------

(ert-deftest chat-ui-transcript-folds-tool-work-behind-a-row ()
  "Tool work starts folded: a summary row stands in for it."
  (chat-ui-transcript-test--with-run ()
    (let ((visible (chat-ui-transcript-test--visible)))
      (should (string-match-p "Tool work" visible))
      ;; The call and its result are behind the row, not on screen.
      (should-not (string-match-p "echo:hi" visible))
      (should-not (string-match-p "demo_tool" visible)))))

(ert-deftest chat-ui-transcript-fold-row-carries-a-group-to-toggle ()
  "A fold row is identified, so a toggle has something to name."
  (chat-ui-transcript-test--with-run ()
    (should (chat-ui-transcript-test--fold-groups))))

(ert-deftest chat-ui-transcript-toggling-a-fold-reveals-what-it-hid ()
  "Folded is not lost: opening the group shows the tool work."
  (chat-ui-transcript-test--with-run ()
    (let ((group (car (chat-ui-transcript-test--fold-groups))))
      (setq chat-ui--opened-fold-groups (list group))
      (chat-ui--redraw-conversation)
      (let ((visible (chat-ui-transcript-test--visible)))
        (should (string-match-p "demo_tool" visible))
        (should (string-match-p "echo:hi" visible))))))

(ert-deftest chat-ui-transcript-toggle-command-works-from-the-row ()
  "`chat-ui-toggle-fold' opens the group under point and closes it again."
  (chat-ui-transcript-test--with-run ()
    (goto-char chat-ui--conversation-start)
    (should (text-property-search-forward 'chat-ui-fold-group))
    (goto-char (previous-single-property-change (point) 'chat-ui-fold-group))
    (chat-ui-toggle-fold)
    (should (string-match-p "echo:hi" (chat-ui-transcript-test--visible)))
    (goto-char chat-ui--conversation-start)
    (should (text-property-search-forward 'chat-ui-fold-group))
    (goto-char (previous-single-property-change (point) 'chat-ui-fold-group))
    (chat-ui-toggle-fold)
    (should-not (string-match-p "echo:hi" (chat-ui-transcript-test--visible)))))

(ert-deftest chat-ui-transcript-toggle-refuses-where-there-is-no-fold ()
  "Pressing the key on ordinary text says so rather than doing nothing."
  (chat-ui-transcript-test--with-run ()
    (goto-char chat-ui--conversation-start)
    (should (search-forward "The answer is 42." nil t))
    (should-error (chat-ui-toggle-fold) :type 'user-error)))

(ert-deftest chat-ui-transcript-toggle-all-folds-opens-then-closes ()
  "One command reaches the detail without hunting for a row."
  (chat-ui-transcript-test--with-run ()
    (chat-ui-toggle-all-folds)
    (should (string-match-p "echo:hi" (chat-ui-transcript-test--visible)))
    (chat-ui-toggle-all-folds)
    (should-not (string-match-p "echo:hi"
                                (chat-ui-transcript-test--visible)))))

(ert-deftest chat-ui-transcript-does-not-fold-the-answer ()
  "The answer is not a channel and is never hidden."
  (chat-ui-transcript-test--with-run ()
    (should (string-match-p "The answer is 42."
                            (chat-ui-transcript-test--visible)))
    (should-not (chat-transcript-channel
                 '(:category ai-final :work nil)))))

;; ------------------------------------------------------------------
;; Typography
;; ------------------------------------------------------------------

(ert-deftest chat-ui-transcript-interim-prose-is-italic ()
  "Prose on the way to the answer is meant to be read, not mistaken for it."
  (chat-ui-transcript-test--with-run ()
    (should (eq (chat-ui-transcript-test--face-of "Looking that up now")
                'chat-transcript-interim))
    (should (eq (face-attribute 'chat-transcript-interim :slant nil t)
                'italic))))

(ert-deftest chat-ui-transcript-separates-the-answer-from-the-detail ()
  "Detail lines run together as one block, so the answer needs air.

Without it the answer's header reads as one more detail line."
  (chat-ui-transcript-test--with-run ()
    (should (string-match-p "\n\nAssistant:"
                            (chat-ui-transcript-test--visible)))))

(ert-deftest chat-ui-transcript-detail-lines-stay-one-block ()
  "Consecutive detail is not broken up by blank lines."
  (chat-ui-transcript-test--with-run ()
    (chat-ui-toggle-all-folds)
    (should (string-match-p "Tool call:[^\n]*\n  Tool result:"
                            (chat-ui-transcript-test--visible)))))

(ert-deftest chat-ui-transcript-the-answer-is-ordinary-text ()
  "The answer carries no detail face of its own."
  (chat-ui-transcript-test--with-run ()
    (let ((face (chat-ui-transcript-test--face-of "The answer is 42.")))
      (should-not (memq face '(chat-transcript-interim
                               chat-transcript-thinking
                               chat-transcript-tool-call
                               chat-transcript-tool-result
                               chat-transcript-fold-row))))))

(ert-deftest chat-ui-transcript-thinking-is-dim-and-folded-by-default ()
  "Reasoning is detail: dim, and behind a row until asked for."
  (should (eq (chat-transcript-fold-style 'thinking) 'collapsed))
  (should (eq (chat-transcript-fold-style 'tool-work) 'collapsed))
  (should (eq (chat-transcript-fold-style 'interim) 'expanded))
  (should (eq (chat-transcript-part-face '(:category ai-progress
                                           :work thinking))
              'chat-transcript-thinking)))

(ert-deftest chat-ui-transcript-reasoning-reaches-the-screen ()
  "Reasoning rides on the step that produced it, so it has to be drawn.

It lives in metadata rather than in a message of its own, which is what
keeps it out of a request; a display that only walked messages would
never show it at all."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Reasoning Session" 'kimi))
          (message (make-chat-message :id "a-1" :role :assistant
                                      :content "Answer."
                                      :timestamp (current-time))))
     (chat-transcript-set-reasoning message "Weighing two options.")
     (chat-session-add-message session message)
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       ;; Folded by default, so the row is what shows.
       (should (string-match-p "Thinking" (chat-ui-transcript-test--visible)))
       (chat-ui-toggle-all-folds)
       (should (string-match-p "Weighing two options"
                               (chat-ui-transcript-test--visible)))))))

;; ------------------------------------------------------------------
;; The live tail
;; ------------------------------------------------------------------

(ert-deftest chat-ui-transcript-streaming-appends-only-the-delta ()
  "A reply arrives in many chunks; redrawing all of it each time is
quadratic, so the tail appends when the new text extends the old."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Stream Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui--render-response-state (current-buffer) chat-ui--live-start
                                       "Hello" nil)
       (let ((body (plist-get chat-ui--last-render :body-start)))
         (should body)
         (chat-ui--render-response-state (current-buffer) chat-ui--live-start
                                         "Hello there" nil)
         ;; Same body position means the text above it was not rewritten.
         (should (= (plist-get chat-ui--last-render :body-start) body)))
       (should (string-match-p "Hello there"
                               (chat-ui-transcript-test--visible)))))))

(ert-deftest chat-ui-transcript-live-tail-does-not-eat-committed-steps ()
  "The tail is bounded below by the record, so it cannot overwrite it."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Bound Session" 'kimi)))
     (chat-session-add-message
      session
      (make-chat-message :id "user-1" :role :user :content "First question"
                         :timestamp (current-time)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui--render-response-state (current-buffer) chat-ui--live-start
                                       "partial reply" nil)
       (let ((visible (chat-ui-transcript-test--visible)))
         (should (string-match-p "First question" visible))
         (should (string-match-p "partial reply" visible)))))))

(ert-deftest chat-ui-transcript-a-recorded-step-leaves-the-tail ()
  "Once a step is on the record the tail starts over, so the next chunk
cannot reach back over it."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Handoff Session" 'kimi)))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       (chat-ui--render-response-state (current-buffer) chat-ui--live-start
                                       "step one text" nil)
       (let ((tail-before (marker-position chat-ui--live-start)))
         (chat-session-add-message
          session
          (make-chat-message :id "a-1" :role :assistant
                             :content "step one text"
                             :timestamp (current-time)))
         (setq chat-ui--live-response-content "")
         (chat-ui--redraw-conversation)
         (should (> (marker-position chat-ui--live-start) tail-before))
         (chat-ui--render-response-state (current-buffer) chat-ui--live-start
                                         "step two text" nil)
         (let ((visible (chat-ui-transcript-test--visible)))
           (should (string-match-p "step one text" visible))
           (should (string-match-p "step two text" visible))))))))

;; ------------------------------------------------------------------
;; Drawing a reply
;; ------------------------------------------------------------------

(defun chat-ui-transcript-test--fenced (blocks)
  "Return BLOCKS paragraphs, each followed by a fenced code block."
  (mapconcat (lambda (index)
               (format "Paragraph %d.\n\n```elisp\n(marker %d)\n```\n\n"
                       index index))
             (number-sequence 1 blocks) ""))

(defun chat-ui-transcript-test--draw-cost (blocks)
  "Return bytes allocated drawing a reply of BLOCKS blocks."
  (cl-flet ((allocated ()
              (let ((counts (memory-use-counts)))
                (+ (* 16 (nth 0 counts)) (* 8 (nth 2 counts)) (nth 4 counts)))))
    (let ((content (chat-ui-transcript-test--fenced blocks)))
      (with-temp-buffer
        (let ((before (allocated)))
          (chat-ui--insert-formatted-response content)
          (- (allocated) before))))))

(ert-deftest chat-ui-transcript-drawing-a-reply-is-linear-in-its-length ()
  "Drawing searched a fresh copy of the text that remained, per block.

Two copies per block, so a reply cost its length times its number of
blocks: 320KB of prose and code allocated 986MB and took 592ms, ten times
a collection threshold to draw one reply once.  Nothing about that is
visible at the size of a test, so what is asserted is the shape: four
times the text may not cost sixteen times as much."
  (let ((small (chat-ui-transcript-test--draw-cost 200))
        (large (chat-ui-transcript-test--draw-cost 800)))
    (should (> small 0))
    (should (< large (* 8 small)))))

(ert-deftest chat-ui-transcript-a-drawn-reply-keeps-its-blocks-and-prose ()
  "Faces on the blocks, and everything between them still there."
  (with-temp-buffer
    (chat-ui--insert-formatted-response
     "Before.\n\n```elisp\n(one)\n```\n\nBetween.\n\n```\n(two)\n```\n\nAfter.")
    (let ((text (buffer-string)))
      (dolist (part '("Before." "(one)" "Between." "(two)" "After."))
        (should (string-match-p (regexp-quote part) text))))
    (goto-char (point-min))
    (should (search-forward "(one)" nil t))
    ;; A language names the block, so it is drawn as code.
    (should (eq (get-text-property (match-beginning 0) 'face)
                'chat-code-block-face))))

(ert-deftest chat-ui-transcript-an-unclosed-block-is-drawn-as-it-arrived ()
  "The half-arrived block of a reply still streaming."
  (with-temp-buffer
    (chat-ui--insert-formatted-response "Text.\n\n```elisp\n(unfinished")
    (should (equal (buffer-string) "Text.\n\n```elisp\n(unfinished"))))

(ert-deftest chat-ui-transcript-a-batched-update-can-carry-whole-code-blocks ()
  "The stream now publishes in fewer, larger steps as a reply grows.

Accumulating a reply cost 165 times its own size when every piece was
handed over, so the agent hands over less often once the reply is long --
which means one update now carries what a dozen used to.  With small
pieces a fence spanned several updates and only the last one closed it;
with a large one a single update opens and closes many.  The append
resumes from a fence-safe point in the *old* text, so all of the new text
has to be drawn however much of it arrives at once."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (chat-session-create "Batched Session" 'kimi))
          (reply (mapconcat
                  (lambda (index)
                    (format "Paragraph %d.\n\n```elisp\n(marker %d)\n```\n\n"
                            index index))
                  (number-sequence 1 40) "")))
     (with-temp-buffer
       (setq-local chat--current-session session)
       (chat-ui-setup-buffer session)
       ;; Handed over the way the accumulator hands it over: every update
       ;; is the whole reply so far, and the steps grow with it.
       (let ((published 0))
         (while (< published (length reply))
           (setq published (min (length reply)
                                (+ published (max 200 (/ published 8)))))
           (chat-ui--render-response-state (current-buffer)
                                           chat-ui--live-start
                                           (substring reply 0 published)
                                           nil)))
       (let ((visible (chat-ui-transcript-test--visible)))
         (dolist (index '(1 2 20 39 40))
           (should (string-match-p (format "Paragraph %d\\." index) visible))
           (should (string-match-p (format "(marker %d)" index) visible))))))))

(provide 'test-chat-ui-transcript)
;;; test-chat-ui-transcript.el ends here
