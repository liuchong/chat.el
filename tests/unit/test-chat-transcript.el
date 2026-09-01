;;; test-chat-transcript.el --- Tests for chat-transcript.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the typed transcript model: how a run's steps are derived
;; from messages, how the answer is told apart from the steps, and how the
;; foldable channels turn into a render plan.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'cl-lib)
(require 'chat-transcript)

(defun test-chat-transcript--message (role content &optional calls reasoning id)
  "Build a message with ROLE, CONTENT, CALLS, REASONING and ID."
  (let ((message (make-chat-message
                  :id (or id (chat-session-new-message-id))
                  :role role
                  :content content
                  :tool-calls calls
                  :timestamp (current-time))))
    (when reasoning
      (chat-transcript-set-reasoning message reasoning))
    message))

(defun test-chat-transcript--categories (parts)
  "Return the (CATEGORY . WORK) pairs of PARTS."
  (mapcar (lambda (part)
            (cons (plist-get part :category) (plist-get part :work)))
          parts))

;; ------------------------------------------------------------------
;; Telling a step apart from the answer
;; ------------------------------------------------------------------

(ert-deftest chat-transcript-treats-text-shipped-with-tool-calls-as-a-step ()
  "Assistant prose that arrives alongside tool calls is progress, not an answer."
  (let* ((message (test-chat-transcript--message
                   :assistant "Let me look at the file."
                   (list (list :id "c1" :name "read_file"
                               :arguments "{\"path\":\"a.el\"}"))))
         (parts (chat-transcript-message-parts message)))
    (should (equal (test-chat-transcript--categories parts)
                   '((ai-progress . message)
                     (ai-progress . tool-call))))
    (should-not (chat-transcript-final-part-p (car parts)))))

(ert-deftest chat-transcript-treats-text-without-tool-calls-as-the-answer ()
  "Assistant prose with no tool calls is the answer the run arrived at."
  (let* ((message (test-chat-transcript--message :assistant "All done."))
         (parts (chat-transcript-message-parts message)))
    (should (equal (test-chat-transcript--categories parts) '((ai-final . nil))))
    (should (chat-transcript-final-part-p (car parts)))))

(ert-deftest chat-transcript-shows-durable-user-attachment-references ()
  "Reloaded user turns identify attachments without exposing local paths."
  (let* ((digest (make-string 64 ?a))
         (attachment
          (chat-content-part-create
           :type 'image :attachment-id digest :name "screen.png"
           :mime-type "image/png" :size 20 :sha256 digest))
         (message
          (make-chat-message
           :id "with-image" :role :user :content "inspect"
           :content-parts (list (chat-content-text-part "inspect") attachment)))
         (text (plist-get (car (chat-transcript-message-parts message)) :text)))
    (should (string-match-p "inspect" text))
    (should (string-match-p "\\[image\\] screen.png" text))
    (should-not (string-match-p chat-attachment-directory text))))

(ert-deftest chat-transcript-does-not-decide-final-by-position ()
  "A trailing step stays a step even when nothing follows it.

A last-one-wins rule would call the trailing message the answer, which is
how a run stopped at its step limit ends up impersonating a reply."
  (let* ((messages
          (list (test-chat-transcript--message :user "go")
                (test-chat-transcript--message :assistant "Answer first." nil)
                (test-chat-transcript--message
                 :assistant "Still working."
                 (list (list :id "c9" :name "shell" :arguments "ls")))))
         (parts (chat-transcript-parts messages))
         (finals (cl-remove-if-not #'chat-transcript-final-part-p parts)))
    (should (equal (length finals) 1))
    (should (equal (plist-get (car finals) :text) "Answer first."))
    (should-not (chat-transcript-final-part-p (car (last parts))))))

;; ------------------------------------------------------------------
;; Nothing is dropped
;; ------------------------------------------------------------------

(ert-deftest chat-transcript-keeps-every-step-of-a-multi-step-run ()
  "Every step of a run survives, not just the last one.

This is the regression guard for displays that rendered a whole run into
one mutable region and so overwrote each step with the next."
  (let* ((messages
          (list (test-chat-transcript--message :user "fix it")
                (test-chat-transcript--message
                 :assistant "STEP-ONE reading the file."
                 (list (list :id "c1" :name "read_file" :arguments "a.el"))
                 "First I need the file.")
                (test-chat-transcript--message :tool "contents of a.el")
                (test-chat-transcript--message
                 :assistant "STEP-TWO patching it."
                 (list (list :id "c2" :name "write_file" :arguments "a.el"))
                 "Now I can patch.")
                (test-chat-transcript--message :tool "wrote a.el")
                (test-chat-transcript--message :assistant "FINAL it is fixed.")))
         (parts (chat-transcript-parts messages))
         (texts (mapcar (lambda (part) (plist-get part :text)) parts)))
    (should (cl-find "STEP-ONE reading the file." texts :test #'equal))
    (should (cl-find "STEP-TWO patching it." texts :test #'equal))
    (should (cl-find "FINAL it is fixed." texts :test #'equal))
    (should (cl-find "First I need the file." texts :test #'equal))
    (should (cl-find "Now I can patch." texts :test #'equal))
    (should (equal (test-chat-transcript--categories parts)
                   '((user . nil)
                     (ai-progress . thinking)
                     (ai-progress . message)
                     (ai-progress . tool-call)
                     (ai-progress . tool-result)
                     (ai-progress . thinking)
                     (ai-progress . message)
                     (ai-progress . tool-call)
                     (ai-progress . tool-result)
                     (ai-final . nil))))))

(ert-deftest chat-transcript-orders-reasoning-before-the-text-it-produced ()
  "Reasoning comes before the prose and calls of the same step."
  (let* ((message (test-chat-transcript--message
                   :assistant "Calling out."
                   (list (list :id "c1" :name "shell" :arguments "ls"))
                   "I should list the directory."))
         (parts (chat-transcript-message-parts message)))
    (should (equal (mapcar (lambda (part) (plist-get part :work)) parts)
                   '(thinking message tool-call)))))

(ert-deftest chat-transcript-gives-each-part-of-a-message-its-own-key ()
  "Parts need distinct keys so fold groups stay put as a run grows."
  (let* ((message (test-chat-transcript--message
                   :assistant "text"
                   (list (list :id "c1" :name "a") (list :id "c2" :name "b"))
                   "reasoning"))
         (keys (mapcar (lambda (part) (plist-get part :key))
                       (chat-transcript-message-parts message))))
    (should (equal (length keys) 4))
    (should (equal (length (delete-dups (copy-sequence keys))) 4))))

(ert-deftest chat-transcript-skips-blank-content ()
  "A step that only called tools contributes no empty prose part."
  (let* ((message (test-chat-transcript--message
                   :assistant "   "
                   (list (list :id "c1" :name "shell" :arguments "ls"))))
         (parts (chat-transcript-message-parts message)))
    (should (equal (test-chat-transcript--categories parts)
                   '((ai-progress . tool-call))))))

;; ------------------------------------------------------------------
;; Reasoning storage
;; ------------------------------------------------------------------

(ert-deftest chat-transcript-reasoning-round-trips-through-a-session ()
  "Reasoning stored on a message survives a save and reload.

Message metadata goes through JSON, so this also pins that the value
comes back as a usable string rather than a mangled symbol."
  (let* ((session (chat-session-create "transcript-reasoning"))
         (message (test-chat-transcript--message
                   :assistant "done" nil "the reasoning text")))
    (chat-session-add-message session message)
    (chat-session-save session)
    (let* ((loaded (chat-session-load (chat-session-id session)))
           (restored (car (last (chat-session-messages loaded)))))
      (should (equal (chat-transcript-reasoning restored) "the reasoning text")))))

(ert-deftest chat-transcript-ignores-blank-reasoning ()
  "Whitespace is not reasoning and must not create an empty part."
  (let ((message (test-chat-transcript--message :assistant "done" nil "   ")))
    (should-not (chat-transcript-reasoning message))
    (should (equal (test-chat-transcript--categories
                    (chat-transcript-message-parts message))
                   '((ai-final . nil))))))

;; ------------------------------------------------------------------
;; Explicit structure
;; ------------------------------------------------------------------

(ert-deftest chat-transcript-stamp-survives-a-reload ()
  "Turn, step, category and work come back usable after a save.

Message metadata goes through JSON, which stringifies symbols and
numbers, so this pins the coercion on the way back in."
  (let* ((session (chat-session-create "transcript-stamp"))
         (message (test-chat-transcript--message :assistant "step text")))
    (chat-transcript-stamp message :turn 3 :step 2
                           :category 'ai-progress :work 'message)
    (chat-session-add-message session message)
    (chat-session-save session)
    (let* ((loaded (chat-session-load (chat-session-id session)))
           (restored (car (last (chat-session-messages loaded)))))
      (should (equal (chat-transcript-turn restored) 3))
      (should (equal (chat-transcript-step restored) 2))
      (should (eq (chat-transcript-category restored) 'ai-progress))
      (should (eq (chat-transcript-work restored) 'message)))))

(ert-deftest chat-transcript-stamped-category-outranks-the-fallback ()
  "A stamped step stays a step even with no tool calls to infer it from.

The fallback reads a bare assistant message as the answer.  Explicit
structure has to win, or a step whose tool calls were dropped would be
promoted to the reply."
  (let ((message (test-chat-transcript--message :assistant "still working")))
    (chat-transcript-stamp message :category 'ai-progress :work 'message)
    (let ((parts (chat-transcript-message-parts message)))
      (should (equal (test-chat-transcript--categories parts)
                     '((ai-progress . message))))
      (should-not (chat-transcript-final-part-p (car parts))))))

(ert-deftest chat-transcript-parts-carry-their-turn-and-step ()
  "A part knows which turn and step it came from."
  (let ((message (test-chat-transcript--message :tool "output")))
    (chat-transcript-stamp message :turn 2 :step 4
                           :category 'ai-progress :work 'tool-result)
    (let ((part (car (chat-transcript-message-parts message))))
      (should (equal (plist-get part :turn) 2))
      (should (equal (plist-get part :step) 4)))))

(ert-deftest chat-transcript-projects-structured-tool-result-format ()
  (let ((message (test-chat-transcript--message
                  :tool "- status: opened\n")))
    (setf (chat-message-metadata message) '(:content-format mdp))
    (chat-transcript-stamp message :category 'ai-progress :work 'tool-result)
    (let ((part (car (chat-transcript-message-parts message))))
      (should (eq 'mdp (plist-get part :content-format))))))

;; ------------------------------------------------------------------
;; Turn grouping
;; ------------------------------------------------------------------

(ert-deftest chat-transcript-turns-groups-a-question-its-steps-and-its-answer ()
  "A turn record holds one question, its ordered steps, and one answer."
  (let* ((question (test-chat-transcript--message :user "fix it"))
         (step-one (test-chat-transcript--message
                    :assistant "reading"
                    (list (list :id "c1" :name "read_file"))))
         (result (test-chat-transcript--message :tool "contents"))
         (answer (test-chat-transcript--message :assistant "fixed")))
    (chat-transcript-stamp question :turn 1 :step 0 :category 'user)
    (chat-transcript-stamp step-one :turn 1 :step 1
                           :category 'ai-progress :work 'message)
    (chat-transcript-stamp result :turn 1 :step 1
                           :category 'ai-progress :work 'tool-result)
    (chat-transcript-stamp answer :turn 1 :step 2 :category 'ai-final)
    (let* ((turns (chat-transcript-turns
                   (list question step-one result answer)))
           (turn (car turns)))
      (should (equal (length turns) 1))
      (should (equal (plist-get turn :turn) 1))
      (should (eq (plist-get turn :question) question))
      (should (eq (plist-get turn :answer) answer))
      (should (equal (length (plist-get turn :steps)) 1))
      (should (equal (plist-get (car (plist-get turn :steps)) :step) 1))
      (should (equal (plist-get (car (plist-get turn :steps)) :messages)
                     (list step-one result))))))

(ert-deftest chat-transcript-turns-orders-steps-ascending ()
  "Steps of a turn come back in the order the run took them."
  (let ((messages
         (list (test-chat-transcript--message :user "go")
               (test-chat-transcript--message :assistant "second" nil nil "b")
               (test-chat-transcript--message :assistant "first" nil nil "a"))))
    (chat-transcript-stamp (nth 0 messages) :turn 1 :step 0 :category 'user)
    (chat-transcript-stamp (nth 1 messages) :turn 1 :step 2
                           :category 'ai-progress :work 'message)
    (chat-transcript-stamp (nth 2 messages) :turn 1 :step 1
                           :category 'ai-progress :work 'message)
    (let ((steps (plist-get (car (chat-transcript-turns messages)) :steps)))
      (should (equal (mapcar (lambda (step) (plist-get step :step)) steps)
                     '(1 2))))))

(ert-deftest chat-transcript-turns-splits-unstamped-history-on-questions ()
  "History from before the stamps existed still splits into turns."
  (let* ((messages
          (list (test-chat-transcript--message :user "one")
                (test-chat-transcript--message :assistant "answer one")
                (test-chat-transcript--message :user "two")
                (test-chat-transcript--message :assistant "answer two")))
         (turns (chat-transcript-turns messages)))
    (should (equal (length turns) 2))
    (should (equal (chat-message-content (plist-get (car turns) :question))
                   "one"))
    (should (equal (chat-message-content (plist-get (car turns) :answer))
                   "answer one"))
    (should (equal (chat-message-content (plist-get (cadr turns) :answer))
                   "answer two"))))

;; ------------------------------------------------------------------
;; Request projection
;; ------------------------------------------------------------------

(ert-deftest chat-transcript-model-messages-drops-display-only-records ()
  "Command replies, shell output and notices stay out of the context.

They are stored and shown, which is the point of keeping a full record,
but sending them back would feed the model the client's own chrome."
  (let ((reply (test-chat-transcript--message :system "Working directory: /tmp"))
        (output (test-chat-transcript--message :system "total 0"))
        (notice (test-chat-transcript--message :system "Session restored"))
        (question (test-chat-transcript--message :user "hello"))
        (answer (test-chat-transcript--message :assistant "hi")))
    (chat-transcript-stamp reply :category 'command-reply)
    (chat-transcript-stamp output :category 'shell-output)
    (chat-transcript-stamp notice :category 'system-detail)
    (let ((kept (chat-transcript-model-messages
                 (list question reply output notice answer))))
      (should (equal kept (list question answer))))))

(ert-deftest chat-transcript-model-messages-keeps-steps-and-tool-results ()
  "The run's own steps stay in context; the model needs its working set."
  (let* ((step (test-chat-transcript--message
                :assistant "reading" (list (list :id "c1" :name "read_file"))))
         (result (test-chat-transcript--message :tool "contents"))
         (messages (list step result)))
    (should (equal (chat-transcript-model-messages messages) messages))))

(ert-deftest chat-transcript-model-messages-keeps-unstamped-system-messages ()
  "An unstamped system message stays in context.

A system prompt and a compaction summary are both stored as plain system
messages.  Excluding on the fallback category would drop the model's
instructions and its recovered history along with the chrome."
  (let* ((prompt (test-chat-transcript--message :system "You are a helper."))
         (summary (test-chat-transcript--message :system "Earlier: we fixed a."))
         (messages (list prompt summary)))
    (should (equal (chat-transcript-model-messages messages) messages))))

(ert-deftest chat-transcript-reasoning-never-reaches-a-request ()
  "Reasoning is stored on a step but absent from what a request carries."
  (let* ((message (test-chat-transcript--message
                   :assistant "answer" nil "private deliberation"))
         (formatted (chat-llm--format-messages
                     (chat-transcript-model-messages (list message))))
         (rendered (format "%S" formatted)))
    (should (chat-transcript-reasoning message))
    (should-not (string-match-p "private deliberation" rendered))))

;; ------------------------------------------------------------------
;; Channels
;; ------------------------------------------------------------------

(ert-deftest chat-transcript-channel-groups-calls-with-their-results ()
  "A tool call and its result share one channel so they fold together."
  (let ((call (car (chat-transcript-message-parts
                    (test-chat-transcript--message
                     :assistant "" (list (list :id "c1" :name "shell"))))))
        (result (car (chat-transcript-message-parts
                      (test-chat-transcript--message :tool "output")))))
    (should (eq (chat-transcript-channel call) 'tool-work))
    (should (eq (chat-transcript-channel result) 'tool-work))))

(ert-deftest chat-transcript-never-folds-the-answer-or-the-user ()
  "The answer and the prompt are not channels, so nothing can hide them."
  (let ((final (car (chat-transcript-message-parts
                     (test-chat-transcript--message :assistant "answer"))))
        (user (car (chat-transcript-message-parts
                    (test-chat-transcript--message :user "prompt")))))
    (should-not (chat-transcript-channel final))
    (should-not (chat-transcript-channel user))))

(ert-deftest chat-transcript-interim-prose-is-italic-and-the-answer-is-not ()
  "Progress prose is marked italic; the answer reads as ordinary text."
  (let ((interim (car (chat-transcript-message-parts
                       (test-chat-transcript--message
                        :assistant "step" (list (list :id "c" :name "t"))))))
        (final (car (chat-transcript-message-parts
                     (test-chat-transcript--message :assistant "answer")))))
    (should (eq (chat-transcript-part-face interim) 'chat-transcript-interim))
    (should-not (chat-transcript-part-face final))))

;; ------------------------------------------------------------------
;; Render plan
;; ------------------------------------------------------------------

(defun test-chat-transcript--plan-types (plan)
  "Return a readable shape of PLAN."
  (mapcar (lambda (instruction)
            (if (eq (plist-get instruction :type) 'fold-row)
                (list 'fold (plist-get instruction :channel)
                      (plist-get instruction :count)
                      (plist-get instruction :open))
              (list 'part (plist-get (plist-get instruction :part) :text))))
          plan))

(ert-deftest chat-transcript-plan-hides-a-collapsed-run-behind-one-row ()
  "A collapsed channel contributes a single summary row and no parts."
  (let* ((chat-transcript-fold-styles '((thinking . collapsed)))
         (messages (list (test-chat-transcript--message
                          :assistant "answer" nil "thought one")))
         (plan (chat-transcript-plan (chat-transcript-parts messages))))
    (should (equal (test-chat-transcript--plan-types plan)
                   '((fold thinking 1 nil)
                     (part "answer"))))))

(ert-deftest chat-transcript-plan-shows-a-group-the-reader-opened ()
  "Naming a group in OPENED-GROUPS reveals its parts and flips the row."
  (let* ((chat-transcript-fold-styles '((thinking . collapsed)))
         (parts (chat-transcript-parts
                 (list (test-chat-transcript--message
                        :assistant "answer" nil "thought one"))))
         (group (plist-get (car (chat-transcript-plan parts)) :group))
         (plan (chat-transcript-plan parts (list group))))
    (should group)
    (should (equal (test-chat-transcript--plan-types plan)
                   '((fold thinking 1 t)
                     (part "thought one")
                     (part "answer"))))))

(ert-deftest chat-transcript-plan-expanded-style-adds-no-row ()
  "An expanded channel shows everything with no chrome at all."
  (let* ((chat-transcript-fold-styles '((thinking . expanded)))
         (plan (chat-transcript-plan
                (chat-transcript-parts
                 (list (test-chat-transcript--message
                        :assistant "answer" nil "thought one"))))))
    (should (equal (test-chat-transcript--plan-types plan)
                   '((part "thought one")
                     (part "answer"))))))

(ert-deftest chat-transcript-plan-latest-expanded-keeps-only-the-newest ()
  "With `latest-expanded' the newest part of a channel stays in place."
  (let* ((chat-transcript-fold-styles '((thinking . latest-expanded)
                                        (tool-work . expanded)
                                        (interim . expanded)))
         (messages
          (list (test-chat-transcript--message
                 :assistant "step one"
                 (list (list :id "c1" :name "t")) "old thought")
                (test-chat-transcript--message
                 :assistant "answer" nil "new thought")))
         (plan (chat-transcript-plan (chat-transcript-parts messages)))
         (shape (test-chat-transcript--plan-types plan)))
    (should (member '(fold thinking 1 nil) shape))
    (should (member '(part "new thought") shape))
    (should-not (member '(part "old thought") shape))))

(ert-deftest chat-transcript-plan-keeps-runs-of-one-channel-separate ()
  "Two runs of the same channel get their own rows rather than merging."
  (let* ((chat-transcript-fold-styles '((thinking . collapsed)
                                        (interim . expanded)
                                        (tool-work . expanded)))
         (messages
          (list (test-chat-transcript--message
                 :assistant "step one"
                 (list (list :id "c1" :name "t")) "thought one")
                (test-chat-transcript--message
                 :assistant "answer" nil "thought two")))
         (plan (chat-transcript-plan (chat-transcript-parts messages)))
         (rows (cl-remove-if-not
                (lambda (instruction) (eq (plist-get instruction :type) 'fold-row))
                plan)))
    (should (equal (length rows) 2))
    (should (cl-every (lambda (row) (eq (plist-get row :channel) 'thinking)) rows))))

(ert-deftest chat-transcript-fold-row-text-reports-channel-and-count ()
  "The summary row says what is hidden and how much of it."
  (should (equal (chat-transcript-fold-row-text
                  (list :type 'fold-row :channel 'thinking :count 3 :open nil))
                 "▸ Thinking · 3"))
  (should (equal (chat-transcript-fold-row-text
                  (list :type 'fold-row :channel 'tool-work :count 1 :open t))
                 "▾ Tool work · 1")))

(ert-deftest chat-transcript-tool-call-label-names-the-arguments ()
  "A reader wants to see which file, not the shape of the transport."
  (should (equal (chat-transcript-tool-call-label
                  '(:name "files_read" :arguments (("path" . "config.el"))))
                 "files_read path=config.el"))
  (should (equal (chat-transcript-tool-call-label
                  '(:name "shell" :arguments (("command" . "ls") ("cwd" . "/tmp"))))
                 "shell command=ls cwd=/tmp")))

(ert-deftest chat-transcript-tool-call-label-survives-odd-arguments ()
  "Arguments are not always a mapping, and a label is still wanted."
  (should (equal (chat-transcript-tool-call-label '(:name "ping")) "ping"))
  (should (equal (chat-transcript-tool-call-label
                  '(:name "ping" :arguments ""))
                 "ping"))
  (should (string-prefix-p "ping "
                           (chat-transcript-tool-call-label
                            '(:name "ping" :arguments "raw text")))))

(ert-deftest chat-transcript-tool-call-label-shortens-a-long-value ()
  "A label is one line, so a large argument cannot take the whole row."
  (let ((label (chat-transcript-tool-call-label
                `(:name "write"
                  :arguments (("body" . ,(make-string 400 ?x)))))))
    (should (< (length label) 120))
    (should (string-match-p "\\.\\.\\." label))))

(provide 'test-chat-transcript)
;;; test-chat-transcript.el ends here
