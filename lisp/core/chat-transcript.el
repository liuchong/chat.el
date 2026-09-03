;;; chat-transcript.el --- Typed transcript parts for chat displays -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; One agent run is not one answer.  It reasons, calls tools, reads the
;; results, reasons again, and only then replies.  A display that treats the
;; whole run as a single mutable region has to erase what it drew for step N
;; when step N+1 arrives, so every intermediate step disappears and only the
;; last one is left standing.
;;
;; This module turns a session's messages into an ordered list of typed
;; parts.  A renderer can then append parts as they arrive instead of
;; overwriting one slot, and give each kind its own visibility and
;; typography: reasoning and tool work are detail worth hiding by default,
;; a step's prose is worth showing but not worth mistaking for the answer,
;; and the answer itself reads as ordinary text.
;;
;; The shape a session records is a hierarchy, and it is stored explicitly
;; rather than guessed at read time:
;;
;;     session
;;     └── turn N              one question
;;         ├── question        category `user', step 0
;;         ├── step 1          reasoning, prose, tool calls, tool results
;;         ├── step 2          ...
;;         └── answer          category `ai-final'
;;
;; The producer of a message stamps its turn, step, category and work kind,
;; and those survive a reload.  Inference from role and tool calls is kept
;; only as a fallback for sessions written before the stamps existed; new
;; data never depends on it.  Position is never used to pick the answer,
;; because a last-one-wins rule mislabels a run that stopped at its step
;; limit as if it had replied.
;;
;; Storing everything is only safe because what is stored and what is sent
;; are different things.  `chat-session-messages' is the record; the request
;; context is a projection of it through `chat-transcript-model-messages',
;; which drops the parts that exist for the reader alone -- reasoning,
;; command replies, captured shell output, bookkeeping notices.  Without
;; that split, keeping a complete record would mean feeding the model its
;; own scratch work.

;;; Code:

(require 'cl-lib)
(require 'chat-session)
(require 'chat-i18n)

(defgroup chat-transcript nil
  "Typed conversation parts shared by the chat displays."
  :group 'chat)

(defconst chat-transcript-categories
  '(user ai-progress ai-final command-reply shell-output system-detail)
  "Every category a transcript part can carry.

`ai-progress' is the run's account of its own work; `ai-final' is the
answer the run arrived at.  Keeping them apart is what lets a display
show both without confusing one for the other.")

(defconst chat-transcript-work-kinds
  '(thinking tool-call tool-result message)
  "Work kinds that refine a part in the `ai-progress' category.")

(defconst chat-transcript-channels
  '(thinking tool-work interim system-detail)
  "Foldable channels.  A part outside these always shows.")

;; ------------------------------------------------------------------
;; Presentation policy
;; ------------------------------------------------------------------

(defcustom chat-transcript-fold-styles
  '((thinking . collapsed)
    (tool-work . collapsed)
    (interim . expanded)
    (system-detail . collapsed))
  "How much of each foldable channel a display shows by default.

`collapsed' hides a whole run behind one summary row.  `expanded' shows
every part.  `latest-expanded' keeps only the newest part of that channel
in place and folds the older ones as soon as a newer one arrives, which
suits reasoning that would otherwise push the answer off screen.

Channels missing from this alist are shown in full.  The answer is not a
channel and is never folded."
  :type '(alist :key-type symbol
                :value-type (choice (const collapsed)
                                    (const latest-expanded)
                                    (const expanded)))
  :group 'chat-transcript)

(defcustom chat-transcript-channel-labels nil
  "Overrides for the text naming each channel in a fold row.

An entry here wins over the localized label, so customizing one channel
does not mean restating the rest of them in whatever language the
interface is set to."
  :type '(alist :key-type symbol :value-type string)
  :group 'chat-transcript)

(defun chat-transcript-channel-label (channel)
  "Return the text naming CHANNEL in a fold row."
  (or (alist-get channel chat-transcript-channel-labels)
      (pcase channel
        ('thinking (chat-i18n 'channel-thinking "Thinking"))
        ('tool-work (chat-i18n 'channel-tool-work "Tool work"))
        ('interim (chat-i18n 'channel-interim "Progress"))
        ('system-detail (chat-i18n 'channel-system "System"))
        (_ (symbol-name channel)))))

(defface chat-transcript-thinking
  '((t :inherit shadow))
  "Face for reasoning the model reported while working."
  :group 'chat-transcript)

(defface chat-transcript-tool-call
  '((t :inherit shadow))
  "Face for a tool invocation."
  :group 'chat-transcript)

(defface chat-transcript-tool-result
  '((t :inherit shadow))
  "Face for what a tool returned."
  :group 'chat-transcript)

(defface chat-transcript-interim
  '((t :slant italic))
  "Face for prose a run produced on the way to its answer.

Italic rather than dimmed: this text is meant to be read, it just must
not be mistaken for the final answer."
  :group 'chat-transcript)

(defface chat-transcript-system
  '((t :inherit font-lock-comment-face))
  "Face for bookkeeping notices."
  :group 'chat-transcript)

(defface chat-transcript-fold-row
  '((t :inherit shadow))
  "Face for the summary row standing in for folded parts."
  :group 'chat-transcript)

;; ------------------------------------------------------------------
;; Reading and writing classification
;; ------------------------------------------------------------------

(defun chat-transcript--symbol (value)
  "Coerce VALUE to a symbol.

Message metadata is written through JSON, which turns a symbol into its
name, so a value read back from disk arrives as a string."
  (cond
   ((null value) nil)
   ((symbolp value) value)
   ((stringp value) (and (not (string-empty-p value)) (intern value)))
   (t nil)))

(defun chat-transcript--number (value)
  "Coerce VALUE to a number, tolerating the string JSON hands back."
  (cond
   ((numberp value) value)
   ((and (stringp value) (string-match-p "\\`-?[0-9]+\\'" value))
    (string-to-number value))
   (t nil)))

(defun chat-transcript--field (message key)
  "Return metadata KEY of MESSAGE."
  (plist-get (chat-message-metadata message) key))

(defun chat-transcript-turn (message)
  "Return the turn MESSAGE belongs to, or nil when it was never stamped."
  (chat-transcript--number (chat-transcript--field message :turn)))

(defun chat-transcript-step (message)
  "Return the step of its turn that produced MESSAGE, or nil."
  (chat-transcript--number (chat-transcript--field message :step)))

(defun chat-transcript-category (message)
  "Return the stamped category of MESSAGE, falling back to its role.

The fallback exists for sessions recorded before categories were stored.
It reads an assistant message carrying tool calls as a step, because that
is the only reason the loop would have taken another turn."
  (or (chat-transcript--symbol (chat-transcript--field message :category))
      (pcase (chat-message-role message)
        (:user 'user)
        (:tool 'ai-progress)
        (:assistant (if (chat-message-tool-calls message) 'ai-progress 'ai-final))
        (_ 'system-detail))))

(defun chat-transcript-work (message)
  "Return the stamped work kind of MESSAGE, falling back to its role."
  (or (chat-transcript--symbol (chat-transcript--field message :work))
      (pcase (chat-message-role message)
        (:tool 'tool-result)
        (:assistant (and (chat-message-tool-calls message) 'message))
        (_ nil))))

(defun chat-transcript-stamp (message &rest properties)
  "Record structural PROPERTIES on MESSAGE and return it.

PROPERTIES is a plist of `:turn', `:step', `:category', `:work' and
`:reasoning'.  Stamping at the point a message is produced is what keeps
the display from having to guess later."
  (when message
    (let ((metadata (chat-message-metadata message)))
      (dolist (key '(:turn :step :category :work :reasoning))
        (let ((value (plist-get properties key)))
          (when value
            (setq metadata (plist-put metadata key value)))))
      (setf (chat-message-metadata message) metadata)))
  message)

(defun chat-transcript-reasoning (message)
  "Return the reasoning text recorded on MESSAGE, or nil.

Reasoning lives on the step that produced it rather than in a record of
its own.  A transport may replay it only when the same assistant step
also produced tool calls and the selected model explicitly supports the
provider's reasoning continuation field."
  (let ((value (chat-transcript--field message :reasoning)))
    (and (stringp value)
         (not (string-empty-p (string-trim value)))
         value)))

(defun chat-transcript-set-reasoning (message reasoning)
  "Record REASONING on MESSAGE and return MESSAGE.

Reasoning rides along with the step that produced it rather than
becoming its own message.  Request adapters decide whether the selected
model requires it for a tool-call continuation."
  (when (and message (stringp reasoning)
             (not (string-empty-p (string-trim reasoning))))
    (setf (chat-message-metadata message)
          (plist-put (chat-message-metadata message) :reasoning reasoning)))
  message)

;; ------------------------------------------------------------------
;; Deriving parts from messages
;; ------------------------------------------------------------------

(defun chat-transcript--part (message category work text &rest extra)
  "Build a part of MESSAGE with CATEGORY, WORK, TEXT and EXTRA properties."
  (append (list :category category
                :work work
                :text (or text "")
                :message message
                :message-id (chat-message-id message)
                :timestamp (chat-message-timestamp message)
                :turn (chat-transcript-turn message)
                :step (chat-transcript-step message))
          extra))

(defun chat-transcript--format-duration (seconds)
  "Render SECONDS of wall time as a compact suffix like 4.2s or 3m 05s."
  (cond
   ((null seconds) nil)
   ((< seconds 10) (format "%.1fs" seconds))
   ((< seconds 60) (format "%ds" (round seconds)))
   (t (format "%dm %02ds" (/ (truncate seconds) 60)
              (mod (truncate seconds) 60)))))

(defun chat-transcript--compact (value)
  "Render VALUE as one short line."
  (let* ((text (if (stringp value) value (format "%S" value)))
         (flat (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim text))))
    (if (> (length flat) 72)
        (concat (substring flat 0 72) "...")
      flat)))

(defun chat-transcript--argument-pairs (arguments)
  "Return ARGUMENTS as `key=value' text, or nil when it is not a mapping.

Tool arguments arrive as an alist of names to values.  Printed as a Lisp
object they read as `((\"path\" . \"x\"))', which is the transport showing
through; a reader wants to see which file."
  (when (and (consp arguments) (not (keywordp (car arguments))))
    (let (pairs)
      (dolist (entry arguments)
        (when (consp entry)
          (let ((key (car entry))
                (value (cdr entry)))
            (push (format "%s=%s"
                          (if (stringp key) key (format "%s" key))
                          (chat-transcript--compact
                           (if (stringp value) value (format "%S" value))))
                  pairs))))
      (and pairs (string-join (nreverse pairs) " ")))))

(defun chat-transcript-tool-call-label (call)
  "Return a one line label for tool CALL."
  (let* ((name (or (plist-get call :name) "tool"))
         (arguments (plist-get call :arguments))
         (rendered (and arguments
                        (not (equal arguments ""))
                        (or (chat-transcript--argument-pairs arguments)
                            (chat-transcript--compact arguments)))))
    (if rendered
        (format "%s %s" name rendered)
      (format "%s" name))))

(defun chat-transcript--blank-p (text)
  "Return non-nil when TEXT has nothing to show."
  (or (null text) (string-empty-p (string-trim text))))

(defun chat-transcript--assistant-parts (message)
  "Return the parts assistant MESSAGE contributes, in production order."
  (let* ((calls (chat-message-tool-calls message))
         (content (chat-message-content message))
         (reasoning (chat-transcript-reasoning message))
         parts)
    (when reasoning
      (push (chat-transcript--part message 'ai-progress 'thinking reasoning)
            parts))
    (unless (chat-transcript--blank-p content)
      (let ((category (chat-transcript-category message)))
        (push (if (eq category 'ai-final)
                  (chat-transcript--part message 'ai-final nil content)
                (chat-transcript--part message category
                                       (or (chat-transcript-work message) 'message)
                                       content))
              parts)))
    (dolist (call calls)
      (push (chat-transcript--part message 'ai-progress 'tool-call
                                   (chat-transcript-tool-call-label call)
                                   :tool-call call)
            parts))
    (nreverse parts)))

(defun chat-transcript--attachment-summary (message)
  "Return the durable attachment summary shown with user MESSAGE."
  (let (lines)
    (dolist (part (chat-message-parts message))
      (when (memq (chat-content-part-type part) '(image file))
        (push (format "[%s] %s (%s)"
                      (symbol-name (chat-content-part-type part))
                      (chat-content-part-name part)
                      (chat-content-part-mime-type part))
              lines)))
    (when lines
      (concat "Attachments:\n" (string-join (nreverse lines) "\n")))))

(defun chat-transcript--user-text (message)
  "Return MESSAGE text followed by its attachment references."
  (let ((text (chat-message-text message))
        (attachments (chat-transcript--attachment-summary message)))
    (cond
     ((and (not (chat-transcript--blank-p text)) attachments)
      (concat text "\n\n" attachments))
     (attachments attachments)
     (t text))))

(defun chat-transcript-message-parts (message)
  "Return the ordered parts MESSAGE contributes to a transcript."
  (let ((parts
         (if (eq (chat-message-role message) :assistant)
             (chat-transcript--assistant-parts message)
           ;; Everything else contributes one part, typed by whatever the
           ;; producer stamped: a captured shell run, a command reply and a
           ;; bookkeeping notice are all stored, and each reads differently.
           (let* ((part
                   (chat-transcript--part
                    message
                    (chat-transcript-category message)
                    (chat-transcript-work message)
                    (if (eq (chat-message-role message) :user)
                        (chat-transcript--user-text message)
                      (chat-message-text message))))
                  (content-format
                   (plist-get (chat-message-metadata message)
                              :content-format)))
             (list (if content-format
                       (plist-put part :content-format content-format)
                     part)))))
        (index -1))
    ;; A message can contribute several parts, so a part needs a key of its
    ;; own for fold groups to stay put while later parts stream in.
    (mapcar (lambda (part)
              (setq index (1+ index))
              (append part
                      (list :key (format "%s/%d"
                                         (or (plist-get part :message-id) "message")
                                         index))))
            parts)))

(defun chat-transcript-parts (messages)
  "Return the ordered transcript parts described by MESSAGES."
  (apply #'append (mapcar #'chat-transcript-message-parts messages)))

;; ------------------------------------------------------------------
;; Turns
;; ------------------------------------------------------------------

(defun chat-transcript-turns (messages)
  "Group MESSAGES into turn records.

Each record is (:turn N :question MESSAGE :steps STEPS :answer MESSAGE),
where STEPS is an ascending list of (:step N :messages MESSAGES).  This is
the shape a session actually has -- one question, the run's steps, then
the answer it arrived at -- and it is what a display groups by.

Messages stamped with a turn are grouped by it.  Messages from before the
stamps existed fall back to starting a new turn at every user message,
which is the same boundary the stamps record."
  (let ((fallback 0)
        turns)
    (dolist (message messages)
      (let* ((category (chat-transcript-category message))
             (turn (or (chat-transcript-turn message)
                       (progn
                         (when (eq category 'user)
                           (setq fallback (1+ fallback)))
                         fallback)))
             (record (or (assq turn turns)
                         (let ((fresh (cons turn (list :turn turn))))
                           (push fresh turns)
                           fresh))))
        (pcase category
          ('user (setf (cdr record)
                       (plist-put (cdr record) :question message)))
          ('ai-final (setf (cdr record)
                           (plist-put (cdr record) :answer message)))
          (_
           (let* ((step (or (chat-transcript-step message) 0))
                  (steps (plist-get (cdr record) :steps))
                  (entry (assq step steps)))
             (unless entry
               (setq entry (cons step (list :step step :messages nil)))
               (setq steps (append steps (list entry)))
               (setf (cdr record) (plist-put (cdr record) :steps steps)))
             (setf (cdr entry)
                   (plist-put (cdr entry) :messages
                              (append (plist-get (cdr entry) :messages)
                                      (list message)))))))))
    (mapcar (lambda (record)
              (let ((body (cdr record)))
                (plist-put body :steps
                           (mapcar #'cdr
                                   (sort (plist-get body :steps)
                                         (lambda (a b) (< (car a) (car b))))))))
            (sort (nreverse turns) (lambda (a b) (< (car a) (car b)))))))

;; ------------------------------------------------------------------
;; Request projection
;; ------------------------------------------------------------------

(defconst chat-transcript-display-only-categories
  '(system-detail command-reply shell-output turn-outcome)
  "Categories stored and shown but never sent to a model.

A command reply, a captured shell run and a bookkeeping notice are part
of the record the reader needs.  Feeding them back as conversation would
teach the model to imitate the client's own chrome.")

(defun chat-transcript-model-message-p (message)
  "Return non-nil when MESSAGE belongs in a request context.

Only an explicit stamp excludes a message.  The fallback categories are
deliberately not consulted here: an unstamped `:system' message is a
system prompt or a compaction summary, both of which the model must see,
and reading it as a bookkeeping notice would quietly drop it."
  (not (memq (chat-transcript--symbol
              (chat-transcript--field message :category))
             chat-transcript-display-only-categories)))

(defun chat-transcript-model-messages (messages)
  "Return the subset of MESSAGES a request should carry.

The record is deliberately larger than the context.  Reasoning stays out
by living in metadata, which is never serialized into a request, and the
display-only categories are dropped here."
  (cl-remove-if-not #'chat-transcript-model-message-p messages))

;; ------------------------------------------------------------------
;; Channels, faces and labels
;; ------------------------------------------------------------------

(defun chat-transcript-channel (part)
  "Return the foldable channel PART belongs to, or nil when it always shows."
  (pcase (plist-get part :category)
    ('system-detail 'system-detail)
    ('ai-progress
     (pcase (plist-get part :work)
       ('thinking 'thinking)
       ;; A call and its result fold together: splitting them into two rows
       ;; would double the chrome without telling the reader anything more.
       ((or 'tool-call 'tool-result) 'tool-work)
       (_ 'interim)))
    (_ nil)))

(defun chat-transcript-fold-style (channel)
  "Return the configured fold style for CHANNEL."
  (or (cdr (assq channel chat-transcript-fold-styles)) 'expanded))

(defun chat-transcript-part-face (part)
  "Return the face a display should use for PART, or nil for ordinary text."
  (pcase (plist-get part :category)
    ('ai-final nil)
    ('user nil)
    ('system-detail 'chat-transcript-system)
    ('turn-outcome 'chat-transcript-system)
    ('ai-progress
     (pcase (plist-get part :work)
       ('thinking 'chat-transcript-thinking)
       ('tool-call 'chat-transcript-tool-call)
       ('tool-result 'chat-transcript-tool-result)
       (_ 'chat-transcript-interim)))
    (_ nil)))

(defun chat-transcript-part-label (part)
  "Return the header naming PART, or nil when it needs none."
  (pcase (plist-get part :category)
    ('turn-outcome (chat-i18n 'part-outcome "Outcome"))
    ('ai-progress
     (pcase (plist-get part :work)
       ('thinking (chat-i18n 'part-thinking "Thinking"))
       ('tool-call (chat-i18n 'part-tool-call "Tool call"))
       ('tool-result (chat-i18n 'part-tool-result "Tool result"))
       (_ (chat-i18n 'part-progress "Progress"))))
    (_ nil)))

(defun chat-transcript-final-part-p (part)
  "Return non-nil when PART is an answer rather than a step."
  (eq (plist-get part :category) 'ai-final))

;; ------------------------------------------------------------------
;; Render plan
;; ------------------------------------------------------------------

(defun chat-transcript--latest-per-channel (parts)
  "Return an alist of channel to the index of its last part in PARTS."
  (let ((index -1)
        latest)
    (dolist (part parts)
      (setq index (1+ index))
      (when-let ((channel (chat-transcript-channel part)))
        (setf (alist-get channel latest) index)))
    latest))

(defun chat-transcript--runs (parts)
  "Split PARTS into runs of consecutive parts sharing one channel.

Each run is (CHANNEL . INDEXES) with INDEXES in ascending order.  A part
outside every channel forms its own run with a nil channel."
  (let ((index -1)
        runs current current-channel)
    (dolist (part parts)
      (setq index (1+ index))
      (let ((channel (chat-transcript-channel part)))
        (if (and current (eq channel current-channel) channel)
            (push index current)
          (when current
            (push (cons current-channel (nreverse current)) runs))
          (setq current-channel channel
                current (list index)))))
    (when current
      (push (cons current-channel (nreverse current)) runs))
    (nreverse runs)))

(defun chat-transcript-plan (parts &optional opened-groups)
  "Return render instructions for PARTS, expanding OPENED-GROUPS.

Each instruction is either (:type part :part PART) for something to draw
or (:type fold-row :channel C :group ID :count N :open FLAG) for a
summary row standing in for the parts hidden behind it.

A group is a run of consecutive parts sharing one channel, keyed by its
first part so a toggle survives later parts arriving.  OPENED-GROUPS is
a list of group keys the reader has expanded by hand.

A fold row also carries the run's wall time: the distance from the
previous part's timestamp to the last timestamp in the run.  A step's
cost is otherwise invisible once the step is folded, and an invisible
cost is how a slow tool pass goes unnoticed until the run is blamed."
  (let* ((vector (vconcat parts))
         (latest (chat-transcript--latest-per-channel parts))
         (plan)
         (previous-timestamp nil))
    (dolist (run (chat-transcript--runs parts))
      (let* ((channel (car run))
             (indexes (cdr run))
             (style (and channel (chat-transcript-fold-style channel)))
             (hidden
              (and channel
                   (pcase style
                     ('expanded nil)
                     ('collapsed indexes)
                     ('latest-expanded
                      (let ((newest (alist-get channel latest)))
                        (cl-remove newest indexes)))
                     (_ nil))))
             (group (and hidden
                         (plist-get (aref vector (car indexes)) :key)))
             (open (and group (member group opened-groups) t))
             (run-end-timestamp
              (and indexes
                   (plist-get (aref vector (car (last indexes)))
                              :timestamp)))
             (duration
              (and run-end-timestamp
                   previous-timestamp
                   (float-time
                    (time-subtract run-end-timestamp previous-timestamp)))))
        (if (null hidden)
            (dolist (index indexes)
              (push (list :type 'part :part (aref vector index)) plan))
          (push (list :type 'fold-row
                      :channel channel
                      :group group
                      :count (length hidden)
                      :open open
                      :duration (and duration (>= duration 0) duration))
                plan)
          (dolist (index indexes)
            (when (or open (not (memq index hidden)))
              (push (list :type 'part :part (aref vector index)) plan))))
        (when run-end-timestamp
          (setq previous-timestamp run-end-timestamp))))
    (nreverse plan)))

(defun chat-transcript-fold-row-text (instruction)
  "Return the line describing fold-row INSTRUCTION."
  (concat
   (format "%s %s · %d"
           (if (plist-get instruction :open) "▾" "▸")
           (chat-transcript-channel-label (plist-get instruction :channel))
           (plist-get instruction :count))
   (when-let ((duration
               (chat-transcript--format-duration
                (plist-get instruction :duration))))
     (concat " · " duration))))

(provide 'chat-transcript)
;;; chat-transcript.el ends here
