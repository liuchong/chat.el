;;; chat-agent-budget.el --- Step budget for a bounded agent run -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A run works in steps: one model turn that may call tools, then another
;; turn that reads the results.  Left alone a loop can grind, so a run gets
;; a step budget.  This module owns two decisions: when the budget is spent,
;; and what the model is told about it.
;;
;; The second decision is the interesting one.  Announcing "you have N steps
;; left" on every step is the obvious design and mostly a mistake: with a
;; large budget it is noise, and a countdown partway through a hard task
;; reads as pressure to give up rather than pressure to focus, which shows
;; up as runs that abandon work they could have finished.  So disclosure is
;; tiered instead:
;;
;;   - the system prompt says once that a budget exists and how big it is,
;;     which is cheap and stays out of the way;
;;   - nothing is said while there is comfortable room left;
;;   - a reminder appears once the budget is genuinely tight, telling the
;;     run to converge rather than to quit;
;;   - the final step withdraws the tools, so the only thing left to do is
;;     write down what was found.
;;
;; Every tier is configurable, including "tell me every step", for anyone
;; who would rather watch the counter than trust the default.

;;; Code:

(require 'cl-lib)

(defgroup chat-agent-budget nil
  "How many steps an agent run may take, and what it is told about that."
  :group 'chat)

(defcustom chat-agent-max-steps 300
  "How many steps one agent run may take.

A step is one model turn, which may call tools.  `unlimited' removes the
ceiling: the run then stops only when the model stops asking for tools,
is cancelled, or fails.  The parameter still exists in that case, so a
run can be capped again without changing anything else."
  :type '(choice (integer :tag "Steps")
                 (const :tag "Unlimited" unlimited))
  :group 'chat-agent-budget)

(defcustom chat-agent-budget-disclosure 'nearing
  "How much of the step budget the model is told, and when.

`nearing' stays quiet until the budget is tight and then asks the run to
converge.  `always' reports the count on every step.  `final-only' speaks
just once, on the last step.  `never' keeps the budget entirely on this
side and lets the run stop without explanation.

`nearing' is the default because a countdown delivered early tends to
make a run wrap up work it had not finished yet."
  :type '(choice (const :tag "Only when the budget is tight" nearing)
                 (const :tag "Every step" always)
                 (const :tag "Only on the final step" final-only)
                 (const :tag "Never" never))
  :group 'chat-agent-budget)

(defcustom chat-agent-budget-nearing-ratio 0.75
  "Fraction of the budget that must be spent before a reminder appears.

Only consulted when `chat-agent-budget-disclosure' is `nearing'."
  :type 'number
  :group 'chat-agent-budget)

;; ------------------------------------------------------------------
;; Reading the budget
;; ------------------------------------------------------------------

(defun chat-agent-budget-unlimited-p (limit)
  "Return non-nil when LIMIT places no ceiling on a run.

`unlimited', nil and any non-positive number all mean the same thing, so
a caller can express it whichever way reads best where it is written."
  (or (null limit)
      (eq limit 'unlimited)
      (and (numberp limit) (<= limit 0))))

(defun chat-agent-budget-limit (limit)
  "Return LIMIT as a step count, or nil when it is unlimited."
  (and (not (chat-agent-budget-unlimited-p limit))
       limit))

(defun chat-agent-budget-effective-limit (override)
  "Return the limit in force given a local OVERRIDE.

A display may cap its own runs more tightly than the global budget.  nil
means it does not, and defers to `chat-agent-max-steps', so the budget
has one place to be changed."
  (if (null override) chat-agent-max-steps override))

(defun chat-agent-budget-label (limit)
  "Return LIMIT as short text for a status line."
  (if (chat-agent-budget-unlimited-p limit)
      "unlimited"
    (format "%d" limit)))

(defun chat-agent-budget-remaining (limit step)
  "Return how many steps remain after STEP under LIMIT, or nil if unlimited."
  (when-let ((ceiling (chat-agent-budget-limit limit)))
    (max 0 (- ceiling step))))

(defun chat-agent-budget-exhausted-p (limit step)
  "Return non-nil when STEP has already used up LIMIT."
  (when-let ((ceiling (chat-agent-budget-limit limit)))
    (>= step ceiling)))

(defun chat-agent-budget-final-step-p (limit step)
  "Return non-nil when STEP is the last one LIMIT allows.

The final step is the one that has to produce an answer, so it is the
step on which tools are withdrawn."
  (when-let ((ceiling (chat-agent-budget-limit limit)))
    (>= step ceiling)))

(defun chat-agent-budget-nearing-p (limit step)
  "Return non-nil when STEP has spent enough of LIMIT to be worth saying."
  (when-let ((ceiling (chat-agent-budget-limit limit)))
    (>= (/ (float step) ceiling) chat-agent-budget-nearing-ratio)))

;; ------------------------------------------------------------------
;; What the model is told
;; ------------------------------------------------------------------

(defun chat-agent-budget-system-note (limit)
  "Return the standing note describing LIMIT for a system prompt.

This is the one piece that is always present.  It says a budget exists
without counting down, so the run can plan for it from the first step
and the text stays identical across steps."
  (if (chat-agent-budget-unlimited-p limit)
      (concat
       "Step budget: unlimited. You may take as many steps as the task "
       "needs, where a step is one of your turns and may call tools. "
       "Still converge as directly as you can and stop once the task is "
       "done.")
    (format
     (concat
      "Step budget: at most %d steps for this task, where a step is one "
      "of your turns and may call tools. Plan to finish well inside it.\n\n"
      ;; Models read "the budget is running out" as "deliver a final answer
      ;; immediately" and start cutting work short.  Saying plainly that
      ;; the run can be continued turns the reminder into a request to
      ;; converge instead of a reason to give up.
      "Running out of steps is not a failure and not the end of the work: "
      "the user can start another round that picks up where you stopped. "
      "So do not abandon a task early to conserve steps, and do not treat "
      "a shrinking budget as bad news.\n\n"
      "On the last step tools are withdrawn and you must reply with text. "
      "Spending that one step on a clear handoff -- what is done, what is "
      "left, what to do next -- costs almost nothing and is worth far more "
      "than one extra tool call, so aim to leave the work in a state "
      "someone can resume.")
     limit)))

(defun chat-agent-budget-final-instruction (limit step)
  "Return the wrap-up instruction for the final STEP of LIMIT.

Framed as a handoff rather than a failure: the run is being asked to
spend its last step well, not to apologize for reaching it."
  (format
   (concat
    "[step budget] Final step (%d of %d). Tools are withdrawn, so reply "
    "with text only. This is a handoff, not a failure: say what you "
    "accomplished, what is still unfinished, and the next concrete action. "
    "The user can continue from your summary in a new round, so write it "
    "for whoever picks the work up.")
   step (or (chat-agent-budget-limit limit) step)))

(defun chat-agent-budget-nearing-instruction (limit step)
  "Return the converge-now reminder for STEP of LIMIT.

Carries the same reassurance as the standing note.  A bare countdown is
read as \"answer now\", and a run that believes it is out of time starts
discarding work it was about to finish."
  (format
   (concat
    "[step budget] Step %d of %d, %d left. Start converging: finish the "
    "piece of work you are on and avoid opening new lines of inquiry. "
    "Running out is not a failure -- the user can continue in a new round "
    "-- so do not cut corners on what you have already started.")
   step limit (chat-agent-budget-remaining limit step)))

(defun chat-agent-budget-plain-note (limit step)
  "Return a bare count of STEP against LIMIT."
  (if (chat-agent-budget-unlimited-p limit)
      (format "[step budget] Step %d, no step limit." step)
    (format "[step budget] Step %d of %d, %d left."
            step limit (chat-agent-budget-remaining limit step))))

(defun chat-agent-budget-reminder (limit step)
  "Return the reminder to attach before STEP of LIMIT, or nil for silence.

Silence is the common answer.  A reminder is only worth its place in the
context when it changes what the run should do next."
  (unless (eq chat-agent-budget-disclosure 'never)
    (cond
     ((chat-agent-budget-final-step-p limit step)
      (chat-agent-budget-final-instruction limit step))
     ((eq chat-agent-budget-disclosure 'final-only) nil)
     ((eq chat-agent-budget-disclosure 'always)
      (if (chat-agent-budget-nearing-p limit step)
          (chat-agent-budget-nearing-instruction limit step)
        (chat-agent-budget-plain-note limit step)))
     ((and (eq chat-agent-budget-disclosure 'nearing)
           (chat-agent-budget-nearing-p limit step))
      (chat-agent-budget-nearing-instruction limit step)))))

(provide 'chat-agent-budget)
;;; chat-agent-budget.el ends here
