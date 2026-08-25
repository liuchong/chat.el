;;; chat-context-budget.el --- Context window budget and compaction policy -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A run has two budgets and they fail differently.  The step budget is a
;; count this client picks and can stop on gracefully.  The context budget
;; is a ceiling the provider imposes, and crossing it is a rejected request
;; rather than an orderly ending.
;;
;; Both go wrong the same way when the run cannot see them.  A run that does
;; not know how much room is left either wastes it -- reading whole files it
;; needed one line from -- or hoards it, declining useful work out of
;; caution.  So the usage is reported, and so is what happens when it fills
;; up: earlier history is summarized, not discarded.  Knowing that is what
;; separates "I am running out of room" from "my work is about to be lost",
;; and only the second is worth being anxious about.
;;
;; What may be summarized has to be said out loud, because the answer is not
;; obvious from the inside.  The leading system messages -- the prompt,
;; project instructions, remembered facts -- are the run's standing orders;
;; summarizing them would quietly change the task.  Everything after them is
;; history and can be compacted.
;;
;; That fixed region needs a ceiling of its own.  It grows through ordinary
;; use, a longer instructions file or a few more remembered facts, and
;; nothing about it shrinks on its own.  Without a cap it can crowd out the
;; room a run needs to work in, producing a session that can do nothing but
;; recite its own instructions.  `chat-context-protected-max-ratio' bounds
;; it, and overflow is reported rather than trimmed: silently dropping part
;; of a system prompt changes behaviour in a way nobody can trace back.

;;; Code:

(require 'cl-lib)
(require 'chat-context)

(defgroup chat-context-budget nil
  "How much context a run may use, and what it is told about that."
  :group 'chat)

(defcustom chat-context-default-window 131072
  "Context window in tokens assumed when a provider does not declare one.

Deliberately not optimistic: overshooting produces a rejected request,
while undershooting only compacts earlier than strictly necessary."
  :type 'integer
  :group 'chat-context-budget)

(defcustom chat-context-reply-reserve-ratio 0.15
  "Fraction of the window held back for the model's own reply.

The window covers the request and the response together, so filling it
with history leaves nothing to answer with."
  :type 'number
  :group 'chat-context-budget)

(defcustom chat-context-protected-max-ratio 0.35
  "Largest share of usable context the fixed region may occupy.

The fixed region is the standing instructions, which compaction never
touches.  Past this share a session spends more of its window restating
its orders than doing the work, so the overflow is reported."
  :type 'number
  :group 'chat-context-budget)

(defcustom chat-context-compact-at-ratio 0.75
  "Share of usable context that triggers compaction and a warning."
  :type 'number
  :group 'chat-context-budget)

;; ------------------------------------------------------------------
;; Measuring
;; ------------------------------------------------------------------

(defun chat-context-window-for-model (model)
  "Return the context window MODEL declares, or the assumed default."
  (or (and model
           (fboundp 'chat-llm-provider-option)
           (chat-llm-provider-option model :context-window))
      chat-context-default-window))

(defun chat-context-budget-usable (window)
  "Return how much of WINDOW a request may fill.

The remainder is left for the reply, which shares the same window."
  (max 1 (floor (* window (- 1.0 chat-context-reply-reserve-ratio)))))

(defun chat-context-budget-measurable (messages)
  "Return the entries of MESSAGES this module can measure.

An estimate must never be able to fail a request.  Callers assemble a
context from several sources and a stray entry that is not a message is a
reason to report less, not a reason to abort the turn."
  (cl-remove-if-not #'chat-message-p messages))

(defun chat-context-budget-protected-tokens (messages)
  "Return the tokens MESSAGES spend on standing instructions.

Those are the leading system messages, which is exactly what compaction
refuses to cut, so measuring the same span keeps the two in agreement."
  (chat-context-total-tokens
   (car (chat-context--partition-system-messages
         (chat-context-budget-measurable messages)))))

(defun chat-context-budget-state (messages &optional model)
  "Return the context budget of MESSAGES against MODEL as a plist.

Keys are `:window', `:usable', `:used', `:remaining', `:ratio',
`:protected', `:protected-cap', `:protected-overflow', `:compactable'
and `:should-compact'."
  (let* ((window (chat-context-window-for-model model))
         (usable (chat-context-budget-usable window))
         (used (chat-context-total-tokens
                (chat-context-budget-measurable messages)))
         (protected (chat-context-budget-protected-tokens messages))
         (cap (max 1 (floor (* usable chat-context-protected-max-ratio)))))
    (list :window window
          :usable usable
          :used used
          :remaining (max 0 (- usable used))
          :ratio (/ (float used) usable)
          :protected protected
          :protected-cap cap
          :protected-overflow (max 0 (- protected cap))
          :compactable (max 0 (- used protected))
          :should-compact (>= (/ (float used) usable)
                              chat-context-compact-at-ratio))))

(defun chat-context-budget-percent (state)
  "Return the share of usable context STATE reports as a whole number."
  (round (* 100 (plist-get state :ratio))))

;; ------------------------------------------------------------------
;; What the model is told
;; ------------------------------------------------------------------

(defun chat-context-budget-policy-note ()
  "Return the standing description of how context is managed.

States the rule rather than a number, so it is identical on every step
and says what the run should do about it."
  (concat
   "Context policy: when the context fills up, earlier history is "
   "summarized rather than deleted, so nothing is lost outright but "
   "detail is. Read what you need and not more: prefer targeted reads "
   "over whole files, and write down what you concluded rather than "
   "quoting at length, because a conclusion survives summarizing and raw "
   "output may not.\n\n"
   "Your standing instructions -- this prompt, project instructions and "
   "remembered facts -- are never summarized. Everything after them can "
   "be."))

(defun chat-context-budget-note (state)
  "Return the standing context note for STATE, including current usage."
  (format
   (concat "Context budget: about %d of %d usable tokens are in play "
           "(%d%%), leaving room for roughly %d more.\n\n%s")
   (plist-get state :used)
   (plist-get state :usable)
   (chat-context-budget-percent state)
   (plist-get state :remaining)
   (chat-context-budget-policy-note)))

(defun chat-context-budget-reminder (state)
  "Return a reminder for STATE when context is tight, or nil.

Tells the run what to do about it, not merely that it is happening: the
useful action before a summary is to record conclusions while the raw
material is still in view."
  (when (plist-get state :should-compact)
    (format
     (concat
      "[context budget] %d%% of the usable context is in play, about %d "
      "tokens left. Earlier history will be summarized soon. Finish what "
      "depends on detail you have already read, and state any conclusion "
      "you want to keep -- a summary preserves what you wrote down, not "
      "what you merely looked at.")
     (chat-context-budget-percent state)
     (plist-get state :remaining))))

;; ------------------------------------------------------------------
;; The fixed region's ceiling
;; ------------------------------------------------------------------

(defun chat-context-budget-protected-overflow-p (state)
  "Return non-nil when STATE reports standing instructions over the cap."
  (> (plist-get state :protected-overflow) 0))

(defun chat-context-budget-overflow-warning (state)
  "Return the operator-facing warning for STATE, or nil when in bounds.

Addressed to whoever configured the session rather than to the model:
the fix is to shorten the instructions or raise the cap, and neither is
something a run can do for itself."
  (when (chat-context-budget-protected-overflow-p state)
    (format
     (concat
      "Standing instructions use %d tokens, %d over the %d token cap "
      "(%.0f%% of usable context). A session this front-loaded has little "
      "room left to work in. Shorten the project instructions or "
      "remembered facts, or raise `chat-context-protected-max-ratio'.")
     (plist-get state :protected)
     (plist-get state :protected-overflow)
     (plist-get state :protected-cap)
     (* 100 chat-context-protected-max-ratio))))

;;;###autoload
(defun chat-context-budget-report ()
  "Report the context budget of the current session.

Shows what the fixed region costs, because that is the number a person
can act on: history compacts itself, standing instructions do not."
  (interactive)
  (let ((session (and (boundp 'chat--current-session) chat--current-session)))
    (unless session
      (user-error "No chat session in this buffer"))
    (let* ((state (chat-context-budget-state
                   (chat-session-messages session)
                   (chat-session-model-id session)))
           (warning (chat-context-budget-overflow-warning state)))
      (message
       "Context: %d/%d usable (%d%%), %d left. Fixed %d of %d allowed.%s"
       (plist-get state :used)
       (plist-get state :usable)
       (chat-context-budget-percent state)
       (plist-get state :remaining)
       (plist-get state :protected)
       (plist-get state :protected-cap)
       (if warning (concat "\n" warning) "")))))

(defun chat-context-budget-compaction-limit (model)
  "Return the token budget compaction should aim at for MODEL.

Derived from the model's own window instead of a flat figure, so a large
window is actually used and a small one is not overrun."
  (chat-context-budget-usable (chat-context-window-for-model model)))

(provide 'chat-context-budget)
;;; chat-context-budget.el ends here
