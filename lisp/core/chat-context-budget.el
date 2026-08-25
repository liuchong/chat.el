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
(require 'json)

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
;; Allocation
;; ------------------------------------------------------------------

;; A window is not one pool.  It is spent by several sources that grow for
;; unrelated reasons -- a tool set that got richer, an instructions file
;; that got longer, a conversation that ran on -- and any of them can
;; starve the others.
;;
;; What makes the categories worth separating is not their size but what
;; can be done when one overflows, which differs enough that a single
;; policy would be wrong for most of them:
;;
;;   demote   Honour what fits and move the excess to compactable.  Used
;;            for declared resident text, where the author's ordering
;;            decides what keeps its guarantee.
;;   compact  Summarize.  Used where a condensed record is still useful.
;;   trim     Drop entries outright.  Only for content that can be
;;            fetched again, such as file excerpts.
;;   warn     Report and change nothing.  Used for tool schemas: dropping
;;            one produces a call that fails at the provider instead of a
;;            context that fits, so the fix belongs to whoever enabled the
;;            tools.
;;
;; Shares are fractions of usable context rather than absolute counts, so
;; the table holds across models.  What does not scale is the cost of a
;; tool set: schemas cost what they cost regardless of the window, so on a
;; small model a full set will not fit its share.  That is a real
;; constraint rather than a defect in the table, and
;; `chat-context-allocation-minimum-window' reports it directly.

(defcustom chat-context-allocation
  '((system-prompt
     :share 0.04 :region fixed :policy warn
     :label "System prompt")
    (resident-rules
     :share 0.10 :region fixed :policy demote
     :label "Resident rules")
    (tool-definitions
     :share 0.12 :region fixed :policy warn
     :label "Tool definitions")
    (capability-packs
     :share 0.04 :region fixed :policy warn
     :label "Capability packs")
    (mcp-tools
     :share 0.03 :region fixed :policy warn
     :label "MCP and dynamic tools")
    (subagent-definitions
     :share 0.01 :region fixed :policy warn
     :label "Subagent definitions")
    (memory
     :share 0.01 :region fixed :policy trim
     :label "Long term memory")
    (project-notes
     :share 0.05 :region compactable :policy compact
     :label "Project instructions")
    (file-context
     :share 0.20 :region compactable :policy trim
     :label "File context")
    (conversation
     :share 0.40 :region compactable :policy compact
     :label "Conversation"))
  "How usable context is divided, and what happens when a share is exceeded.

Each entry is a category followed by a plist of `:share', its fraction of
usable context, `:region', either `fixed' or `compactable', `:policy',
one of `demote', `compact', `trim' or `warn', and `:label' for display.

The fixed shares must stay within `chat-context-protected-max-ratio' and
the whole table within 1.0, or the window is promised away twice."
  :type '(alist :key-type symbol :value-type plist)
  :group 'chat-context-budget)

(defun chat-context-allocation-entry (category)
  "Return the allocation plist for CATEGORY, or nil."
  (cdr (assq category chat-context-allocation)))

(defun chat-context-allocation-share (category)
  "Return the fraction of usable context allotted to CATEGORY."
  (or (plist-get (chat-context-allocation-entry category) :share) 0))

(defun chat-context-allocation-policy (category)
  "Return what happens when CATEGORY exceeds its share."
  (plist-get (chat-context-allocation-entry category) :policy))

(defun chat-context-allocation-label (category)
  "Return the display name of CATEGORY."
  (or (plist-get (chat-context-allocation-entry category) :label)
      (symbol-name category)))

(defun chat-context-allocation-region-share (region)
  "Return the total share of usable context assigned to REGION."
  (cl-loop for (_category . plist) in chat-context-allocation
           when (eq (plist-get plist :region) region)
           sum (plist-get plist :share)))

(defun chat-context-allocation-tokens (category window)
  "Return how many tokens CATEGORY may use given WINDOW."
  (floor (* (chat-context-budget-usable window)
            (chat-context-allocation-share category))))

(defun chat-context-allocation-table (window)
  "Return the allocation for WINDOW as a list of plists.

Each entry carries `:category', `:label', `:region', `:policy',
`:share' and `:tokens'."
  (mapcar
   (lambda (entry)
     (let ((category (car entry))
           (plist (cdr entry)))
       (list :category category
             :label (chat-context-allocation-label category)
             :region (plist-get plist :region)
             :policy (plist-get plist :policy)
             :share (plist-get plist :share)
             :tokens (chat-context-allocation-tokens category window))))
   chat-context-allocation))

(defun chat-context-allocation-minimum-window (category tokens)
  "Return the smallest window where CATEGORY can hold TOKENS.

The question a tool set actually raises: not whether it is too big, but
which models it fits on."
  (let ((share (chat-context-allocation-share category)))
    (if (<= share 0)
        nil
      (ceiling (/ tokens
                  (* share (- 1.0 chat-context-reply-reserve-ratio)))))))

(defun chat-context-allocation-check (category measured window)
  "Return a warning when MEASURED exceeds CATEGORY's share of WINDOW.

The wording follows the category's policy, because the remedy differs:
schemas have to be disabled by a person, whereas history condenses on its
own."
  (let ((allowed (chat-context-allocation-tokens category window)))
    (when (> measured allowed)
      (format
       "%s uses %d tokens, over its %d token share. %s"
       (chat-context-allocation-label category)
       measured allowed
       (pcase (chat-context-allocation-policy category)
         ('warn (format
                 (concat "Nothing is dropped, because a missing definition "
                         "fails at the provider instead of fitting. Disable "
                         "what is not needed, or move to a window of at "
                         "least %d tokens.")
                 (chat-context-allocation-minimum-window category measured)))
         ('demote "The excess is compactable, in document order.")
         ('compact "The excess is summarized.")
         ('trim "The excess is dropped and can be read again when needed.")
         (_ ""))))))

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

(defun chat-context-budget--measure-tools ()
  "Return the tokens the advertised tool schemas cost, or nil.

Measured by encoding what is actually sent rather than by counting tools,
because schema size is what fills a window and tools differ wildly in how
much of it they describe."
  (when (fboundp 'chat-tool-caller-provider-tools)
    (when-let ((tools (ignore-errors (chat-tool-caller-provider-tools))))
      (chat-context-count-tokens
       (or (ignore-errors (json-encode tools)) "")))))

(defun chat-context-budget-measurements (session)
  "Return measured tokens per category for SESSION as an alist.

Only categories with a cheap and honest measurement appear.  A source
this cannot see is left out rather than estimated, since a number nobody
can trace is worse than an admitted gap."
  (let ((measured nil))
    (when-let ((tools (chat-context-budget--measure-tools)))
      (push (cons 'tool-definitions tools) measured))
    (when (fboundp 'chat-memory-snippet)
      (when-let ((snippet (ignore-errors (chat-memory-snippet))))
        (push (cons 'memory (chat-context-count-tokens snippet)) measured)))
    (when (and session (fboundp 'chat-project-instructions-partitioned))
      (when-let* ((dir (or (chat-session-working-directory session)
                           default-directory))
                  (parts (ignore-errors
                           (chat-project-instructions-partitioned dir))))
        (when-let ((resident (plist-get parts :resident)))
          (push (cons 'resident-rules
                      (chat-context-count-tokens resident))
                measured))
        (when-let ((notes (plist-get parts :compactable)))
          (push (cons 'project-notes (chat-context-count-tokens notes))
                measured))))
    (when session
      (push (cons 'conversation
                  (chat-context-total-tokens
                   (chat-context-budget-measurable
                    (chat-session-messages session))))
            measured))
    (nreverse measured)))

;;;###autoload
(defun chat-context-budget-panel ()
  "Show how this session's context window is divided and what it holds.

Allowances come from `chat-context-allocation'; measurements cover the
sources that can be counted directly.  A category with no measurement is
shown as unmeasured rather than guessed at."
  (interactive)
  (let* ((session (and (boundp 'chat--current-session) chat--current-session))
         (model (and session (chat-session-model-id session)))
         (window (chat-context-window-for-model model))
         (measured (chat-context-budget-measurements session))
         (state (and session
                     (chat-context-budget-state
                      (chat-session-messages session) model))))
    (with-current-buffer (get-buffer-create "*chat context budget*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Context window: %d tokens, %d usable after the "
                        window (chat-context-budget-usable window))
                (format "%.0f%% reply reserve\n"
                        (* 100 chat-context-reply-reserve-ratio)))
        (when state
          (insert (format "In play: %d tokens (%d%%), %d left\n"
                          (plist-get state :used)
                          (chat-context-budget-percent state)
                          (plist-get state :remaining))))
        (insert "\n")
        (insert (format "%-24s %-12s %-8s %6s %10s %10s\n"
                        "Category" "Region" "Overflow" "Share" "Allowed" "Measured"))
        (insert (make-string 74 ?-) "\n")
        (dolist (row (chat-context-allocation-table window))
          (let* ((category (plist-get row :category))
                 (hit (assq category measured)))
            (insert (format "%-24s %-12s %-8s %5.0f%% %10d %10s\n"
                            (plist-get row :label)
                            (plist-get row :region)
                            (plist-get row :policy)
                            (* 100 (plist-get row :share))
                            (plist-get row :tokens)
                            (if hit (number-to-string (cdr hit)) "-")))))
        (insert "\n")
        (dolist (hit measured)
          (when-let ((warning (chat-context-allocation-check
                               (car hit) (cdr hit) window)))
            (insert warning "\n")))
        (goto-char (point-min))
        (special-mode))
      (display-buffer (current-buffer)))))

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
