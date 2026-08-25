;;; test-chat-context-budget.el --- Tests for chat-context-budget.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the context budget: measuring the window, capping the
;; fixed region, and what the run is told about both.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-context-budget)

(defun test-chat-context-budget--message (role content)
  "Build a message with ROLE and CONTENT."
  (make-chat-message
   :id (chat-session-new-message-id)
   :role role
   :content content
   :timestamp (current-time)))

(defun test-chat-context-budget--filler (tokens)
  "Return text costing roughly TOKENS to send."
  (make-string (* 4 tokens) ?x))

;; ------------------------------------------------------------------
;; Measuring the window
;; ------------------------------------------------------------------

(ert-deftest chat-context-budget-prefers-the-window-the-model-declares ()
  "A provider that states its window is believed over the default."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key)
               (and (eq key :context-window) 262144))))
    (should (equal (chat-context-window-for-model 'kimi-code) 262144))))

(ert-deftest chat-context-budget-falls-back-to-a-conservative-window ()
  "With nothing declared the assumed window is used.

Undershooting only compacts early; overshooting gets the request
rejected, so the fallback leans small."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (&rest _) nil)))
    (should (equal (chat-context-window-for-model 'whatever)
                   chat-context-default-window))))

(ert-deftest chat-context-budget-holds-back-room-for-the-reply ()
  "Usable context is smaller than the window, since the reply shares it."
  (let ((chat-context-reply-reserve-ratio 0.15))
    (should (equal (chat-context-budget-usable 1000) 850))))

;; ------------------------------------------------------------------
;; State
;; ------------------------------------------------------------------

(ert-deftest chat-context-budget-state-separates-fixed-from-compactable ()
  "The standing instructions are measured apart from the history.

Compaction refuses to cut leading system messages, so the budget has to
count the same span or the two will disagree about what can be freed."
  (cl-letf (((symbol-function 'chat-llm-provider-option) (lambda (&rest _) nil)))
    (let* ((messages
            (list (test-chat-context-budget--message
                   :system (test-chat-context-budget--filler 100))
                  (test-chat-context-budget--message
                   :user (test-chat-context-budget--filler 200))
                  (test-chat-context-budget--message
                   :assistant (test-chat-context-budget--filler 300))))
           (state (chat-context-budget-state messages 'model)))
      (should (> (plist-get state :protected) 90))
      (should (< (plist-get state :protected) 120))
      (should (> (plist-get state :compactable) 480))
      (should (equal (+ (plist-get state :protected)
                        (plist-get state :compactable))
                     (plist-get state :used))))))

(ert-deftest chat-context-budget-state-counts-only-leading-system-messages ()
  "A system message later in the history is compactable, not fixed."
  (cl-letf (((symbol-function 'chat-llm-provider-option) (lambda (&rest _) nil)))
    (let* ((messages
            (list (test-chat-context-budget--message :user "hello")
                  (test-chat-context-budget--message
                   :system (test-chat-context-budget--filler 100))))
           (state (chat-context-budget-state messages 'model)))
      (should (< (plist-get state :protected) 10)))))

(ert-deftest chat-context-budget-reports-when-compaction-is-due ()
  "Crossing the configured share marks the session for compaction."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key) (and (eq key :context-window) 1000))))
    (let* ((chat-context-reply-reserve-ratio 0.0)
           (chat-context-compact-at-ratio 0.75)
           (small (chat-context-budget-state
                   (list (test-chat-context-budget--message
                          :user (test-chat-context-budget--filler 100)))
                   'model))
           (large (chat-context-budget-state
                   (list (test-chat-context-budget--message
                          :user (test-chat-context-budget--filler 900)))
                   'model)))
      (should-not (plist-get small :should-compact))
      (should (plist-get large :should-compact)))))

(ert-deftest chat-context-budget-tolerates-entries-it-cannot-measure ()
  "A stray non-message reduces the estimate instead of failing the turn.

Callers assemble a context from several sources, and an estimate that can
raise is an estimate that can abort a request."
  (cl-letf (((symbol-function 'chat-llm-provider-option) (lambda (&rest _) nil)))
    (let ((state (chat-context-budget-state
                  (list 'not-a-message
                        (test-chat-context-budget--message :user "hello")
                        nil)
                  'model)))
      (should (> (plist-get state :used) 0))
      (should-not (chat-context-budget-reminder state)))))

(ert-deftest chat-context-budget-remaining-never-goes-negative ()
  "An over-full context reports zero room, not a negative amount."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key) (and (eq key :context-window) 100))))
    (let* ((chat-context-reply-reserve-ratio 0.0)
           (state (chat-context-budget-state
                   (list (test-chat-context-budget--message
                          :user (test-chat-context-budget--filler 500)))
                   'model)))
      (should (equal (plist-get state :remaining) 0)))))

;; ------------------------------------------------------------------
;; The fixed region's ceiling
;; ------------------------------------------------------------------

(ert-deftest chat-context-budget-caps-the-fixed-region ()
  "Standing instructions past their share are reported as overflow.

The fixed region grows through ordinary use and never shrinks on its
own, so without a ceiling it crowds out the room a run works in."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key) (and (eq key :context-window) 1000))))
    (let* ((chat-context-reply-reserve-ratio 0.0)
           (chat-context-protected-max-ratio 0.35)
           (state (chat-context-budget-state
                   (list (test-chat-context-budget--message
                          :system (test-chat-context-budget--filler 600)))
                   'model)))
      (should (chat-context-budget-protected-overflow-p state))
      (should (> (plist-get state :protected-overflow) 200))
      (should (equal (plist-get state :protected-cap) 350)))))

(ert-deftest chat-context-budget-accepts-a-fixed-region-within-its-share ()
  "Instructions inside the cap raise no complaint."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key) (and (eq key :context-window) 1000))))
    (let* ((chat-context-reply-reserve-ratio 0.0)
           (chat-context-protected-max-ratio 0.35)
           (state (chat-context-budget-state
                   (list (test-chat-context-budget--message
                          :system (test-chat-context-budget--filler 100)))
                   'model)))
      (should-not (chat-context-budget-protected-overflow-p state))
      (should-not (chat-context-budget-overflow-warning state)))))

(ert-deftest chat-context-budget-overflow-warning-names-the-remedy ()
  "The warning is addressed to whoever can actually fix it."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key) (and (eq key :context-window) 1000))))
    (let* ((chat-context-reply-reserve-ratio 0.0)
           (state (chat-context-budget-state
                   (list (test-chat-context-budget--message
                          :system (test-chat-context-budget--filler 600)))
                   'model))
           (warning (chat-context-budget-overflow-warning state)))
      (should (string-match-p "Standing instructions" warning))
      (should (string-match-p "chat-context-protected-max-ratio" warning)))))

;; ------------------------------------------------------------------
;; What the model is told
;; ------------------------------------------------------------------

(ert-deftest chat-context-budget-note-states-usage-and-the-policy ()
  "The standing note reports usage and says what happens when it fills."
  (cl-letf (((symbol-function 'chat-llm-provider-option) (lambda (&rest _) nil)))
    (let* ((state (chat-context-budget-state
                   (list (test-chat-context-budget--message :user "hi"))
                   'model))
           (note (chat-context-budget-note state)))
      (should (string-match-p "usable tokens" note))
      (should (string-match-p "summarized rather than deleted" note))
      (should (string-match-p "never summarized" note)))))

(ert-deftest chat-context-budget-policy-says-what-may-be-compacted ()
  "The run is told which part of its context is fixed and which is not."
  (let ((policy (chat-context-budget-policy-note)))
    (should (string-match-p "standing instructions" policy))
    (should (string-match-p "never summarized" policy))
    (should (string-match-p "Everything after them can" policy))))

(ert-deftest chat-context-budget-stays-quiet-while-there-is-room ()
  "No reminder is spent until compaction is actually near."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key) (and (eq key :context-window) 100000))))
    (let ((state (chat-context-budget-state
                  (list (test-chat-context-budget--message :user "hi"))
                  'model)))
      (should-not (chat-context-budget-reminder state)))))

(ert-deftest chat-context-budget-reminder-asks-for-conclusions-first ()
  "The tight reminder names the action that survives a summary.

Reporting the shortage alone invites hoarding; the useful instruction is
to write down conclusions while the raw material is still in view."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key) (and (eq key :context-window) 1000))))
    (let* ((chat-context-reply-reserve-ratio 0.0)
           (state (chat-context-budget-state
                   (list (test-chat-context-budget--message
                          :user (test-chat-context-budget--filler 900)))
                   'model))
           (reminder (chat-context-budget-reminder state)))
      (should reminder)
      (should (string-match-p "summarized soon" reminder))
      (should (string-match-p "conclusion" reminder)))))

(ert-deftest chat-context-budget-compaction-limit-follows-the-model ()
  "Compaction aims at the model's own window rather than a flat figure."
  (cl-letf (((symbol-function 'chat-llm-provider-option)
             (lambda (_model key) (and (eq key :context-window) 200000))))
    (let ((chat-context-reply-reserve-ratio 0.15))
      (should (equal (chat-context-budget-compaction-limit 'model) 170000)))))

(provide 'test-chat-context-budget)
;;; test-chat-context-budget.el ends here
