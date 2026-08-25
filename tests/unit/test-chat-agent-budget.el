;;; test-chat-agent-budget.el --- Tests for chat-agent-budget.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the step budget: how the ceiling is read, when the run is
;; out of steps, and how much of that the model is told.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-agent-budget)

;; ------------------------------------------------------------------
;; Reading the ceiling
;; ------------------------------------------------------------------

(ert-deftest chat-agent-budget-default-is-three-hundred-steps ()
  "The shipped ceiling is large enough for real multi-step work."
  (should (equal chat-agent-max-steps 300)))

(ert-deftest chat-agent-budget-accepts-every-spelling-of-unlimited ()
  "The parameter stays in place when the ceiling is lifted.

`unlimited' is the spelling to write; nil and a non-positive count mean
the same so a caller can express it however reads best."
  (should (chat-agent-budget-unlimited-p 'unlimited))
  (should (chat-agent-budget-unlimited-p nil))
  (should (chat-agent-budget-unlimited-p 0))
  (should (chat-agent-budget-unlimited-p -1))
  (should-not (chat-agent-budget-unlimited-p 300)))

(ert-deftest chat-agent-budget-never-exhausts-an-unlimited-run ()
  "An unlimited run has no step at which it is out of budget."
  (should-not (chat-agent-budget-exhausted-p 'unlimited 1))
  (should-not (chat-agent-budget-exhausted-p 'unlimited 100000))
  (should-not (chat-agent-budget-final-step-p 'unlimited 100000))
  (should-not (chat-agent-budget-remaining 'unlimited 5)))

(ert-deftest chat-agent-budget-counts-down-to-the-ceiling ()
  "Remaining steps and exhaustion track the ceiling."
  (should (equal (chat-agent-budget-remaining 10 3) 7))
  (should (equal (chat-agent-budget-remaining 10 10) 0))
  (should-not (chat-agent-budget-exhausted-p 10 9))
  (should (chat-agent-budget-exhausted-p 10 10))
  (should (chat-agent-budget-final-step-p 10 10)))

(ert-deftest chat-agent-budget-effective-limit-defers-to-the-global-one ()
  "A display with no override follows the global budget."
  (let ((chat-agent-max-steps 300))
    (should (equal (chat-agent-budget-effective-limit nil) 300))
    (should (equal (chat-agent-budget-effective-limit 25) 25))
    (should (eq (chat-agent-budget-effective-limit 'unlimited) 'unlimited))))

(ert-deftest chat-agent-budget-label-names-an-unlimited-ceiling ()
  "A status line can print either kind of ceiling."
  (should (equal (chat-agent-budget-label 300) "300"))
  (should (equal (chat-agent-budget-label 'unlimited) "unlimited")))

;; ------------------------------------------------------------------
;; What the model is told
;; ------------------------------------------------------------------

(ert-deftest chat-agent-budget-system-note-states-the-ceiling ()
  "The standing note names the budget and says what the last step means."
  (let ((note (chat-agent-budget-system-note 300)))
    (should (string-match-p "300" note))
    (should (string-match-p "step" note))
    (should (string-match-p "last step" note))))

(ert-deftest chat-agent-budget-note-says-exhaustion-is-not-the-end ()
  "The note defuses the reading that makes a run quit early.

A shrinking budget is otherwise read as \"answer now\", and the run
discards work it was close to finishing.  Saying the user can continue
turns the pressure into a request to converge."
  (let ((note (chat-agent-budget-system-note 300)))
    (should (string-match-p "not a failure" note))
    (should (string-match-p "another round" note))
    (should (string-match-p "do not abandon" (downcase note)))))

(ert-deftest chat-agent-budget-reminders-all-carry-the-reassurance ()
  "Every reminder that mentions a shrinking budget also says it is survivable."
  (dolist (reminder (list (chat-agent-budget-nearing-instruction 100 80)
                          (chat-agent-budget-final-instruction 100 100)))
    (should (string-match-p "not a failure" reminder))
    (should (string-match-p "new round" reminder))))

(ert-deftest chat-agent-budget-system-note-covers-the-unlimited-case ()
  "An unlimited run is told so, rather than being told a fake number."
  (let ((note (chat-agent-budget-system-note 'unlimited)))
    (should (string-match-p "unlimited" note))
    (should-not (string-match-p "at most" note))))

(ert-deftest chat-agent-budget-stays-quiet-early-in-a-large-budget ()
  "Nothing is injected while there is comfortable room left.

A countdown delivered early reads as pressure to give up, so the default
spends its context budget only when the advice would change something."
  (let ((chat-agent-budget-disclosure 'nearing))
    (should-not (chat-agent-budget-reminder 300 1))
    (should-not (chat-agent-budget-reminder 300 100))
    (should-not (chat-agent-budget-reminder 300 200))))

(ert-deftest chat-agent-budget-asks-the-run-to-converge-when-tight ()
  "Past the threshold the reminder reports the count and asks to converge."
  (let ((chat-agent-budget-disclosure 'nearing)
        (chat-agent-budget-nearing-ratio 0.75))
    (let ((reminder (chat-agent-budget-reminder 100 80)))
      (should reminder)
      (should (string-match-p "Step 80 of 100" reminder))
      (should (string-match-p "20 left" reminder))
      (should (string-match-p "converging" reminder)))))

(ert-deftest chat-agent-budget-always-mode-reports-every-step ()
  "`always' reports the count from the first step, for anyone who wants it."
  (let ((chat-agent-budget-disclosure 'always))
    (let ((reminder (chat-agent-budget-reminder 300 1)))
      (should reminder)
      (should (string-match-p "Step 1 of 300" reminder))
      (should (string-match-p "299 left" reminder)))))

(ert-deftest chat-agent-budget-always-mode-still-escalates-when-tight ()
  "`always' upgrades from a bare count to converge-now near the ceiling."
  (let ((chat-agent-budget-disclosure 'always))
    (should-not (string-match-p
                 "converging" (chat-agent-budget-reminder 100 10)))
    (should (string-match-p
             "converging" (chat-agent-budget-reminder 100 90)))))

(ert-deftest chat-agent-budget-final-step-withdraws-tools-in-the-text ()
  "The last step is told tools are gone and it must answer."
  (let ((chat-agent-budget-disclosure 'nearing))
    (let ((reminder (chat-agent-budget-reminder 10 10)))
      (should (string-match-p "Final step (10 of 10)" reminder))
      (should (string-match-p "withdrawn" reminder))
      (should (string-match-p "text only" reminder)))))

(ert-deftest chat-agent-budget-final-only-mode-speaks-once ()
  "`final-only' says nothing until the wrap-up step."
  (let ((chat-agent-budget-disclosure 'final-only))
    (should-not (chat-agent-budget-reminder 10 9))
    (should (chat-agent-budget-reminder 10 10))))

(ert-deftest chat-agent-budget-never-mode-says-nothing-at-all ()
  "`never' keeps the budget entirely on this side of the wire."
  (let ((chat-agent-budget-disclosure 'never))
    (should-not (chat-agent-budget-reminder 10 1))
    (should-not (chat-agent-budget-reminder 10 10))))

(ert-deftest chat-agent-budget-unlimited-run-gets-no-per-step-reminder ()
  "With no ceiling there is no countdown to report."
  (let ((chat-agent-budget-disclosure 'nearing))
    (should-not (chat-agent-budget-reminder 'unlimited 5000))))

(ert-deftest chat-agent-budget-unlimited-run-can-still-report-its-step ()
  "`always' reports the step number even with no ceiling to divide by."
  (let ((chat-agent-budget-disclosure 'always))
    (let ((reminder (chat-agent-budget-reminder 'unlimited 42)))
      (should (string-match-p "Step 42" reminder))
      (should (string-match-p "no step limit" reminder)))))

(provide 'test-chat-agent-budget)
;;; test-chat-agent-budget.el ends here
