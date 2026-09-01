;;; chat-agent-progress.el --- Detect and recover stalled Agent work -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A model may keep issuing valid tool calls while making no task progress.
;; This module tracks that condition without knowing providers, models, tools,
;; or programming languages.  The loop supplies semantic action classes and
;; receives a request-only recovery reminder or an explicit stop reason.

;;; Code:

(require 'cl-lib)

(defconst chat-agent-progress-warning-threshold 6
  "Inspection calls without recovery before the Agent receives a reminder.")

(defconst chat-agent-progress-stop-threshold 12
  "Inspection calls before the Agent stops after a stagnation warning.")

(cl-defstruct (chat-agent-progress-state
               (:constructor chat-agent-progress-state-create))
  (after-error-p nil)
  (inspection-after-error 0)
  (inspection-after-warning 0)
  last-inspection-key
  (same-inspection-count 0)
  (warning-count 0)
  reminder
  stop-reason)

(defun chat-agent-progress--reset (state)
  "Reset transient no-progress facts on STATE."
  (setf (chat-agent-progress-state-after-error-p state) nil
        (chat-agent-progress-state-inspection-after-error state) 0
        (chat-agent-progress-state-inspection-after-warning state) 0
        (chat-agent-progress-state-last-inspection-key state) nil
        (chat-agent-progress-state-same-inspection-count state) 0
        (chat-agent-progress-state-warning-count state) 0
        (chat-agent-progress-state-reminder state) nil
        (chat-agent-progress-state-stop-reason state) nil)
  state)

(defun chat-agent-progress--warning (state reason)
  "Record a request-only recovery warning on STATE for REASON."
  (let ((inspection-count
         (chat-agent-progress-state-inspection-after-error state)))
    (setf (chat-agent-progress-state-warning-count state)
          (1+ (chat-agent-progress-state-warning-count state))
          (chat-agent-progress-state-reminder state)
          (format
           (concat
            "[agent progress recovery required]\n"
            "The run is stalled: %s.\n"
            "Do not repeat another inspection merely to revisit evidence already read. "
            "Use the current evidence to perform one precise corrective action, choose "
            "a different mutation or verification tool, or report a concrete blocker.")
           (if (> inspection-count 0)
               (format "%d inspection calls followed a tool error without a successful mutation or verification"
                       inspection-count)
             reason))))
  (list :event 'stagnation-detected
        :inspection-count
        (chat-agent-progress-state-inspection-after-error state)
        :repeat-count
        (chat-agent-progress-state-same-inspection-count state)
        :warning-count
        (chat-agent-progress-state-warning-count state)))

(defun chat-agent-progress-observe (state kind &optional key)
  "Record one semantic action KIND on STATE and return an event plist.

KIND is `error', `inspection', `progress', or `neutral'.  KEY identifies an
inspection target without retaining tool arguments or output.  `progress'
means a successful task mutation or verification, not bookkeeping such as
creating a plan.  The return value is nil or describes a detected/recovered
stagnation event."
  (if (chat-agent-progress-state-stop-reason state)
      nil
    (pcase kind
    ('error
     (setf (chat-agent-progress-state-after-error-p state) t)
     nil)
    ('progress
     (let ((recovered (or (chat-agent-progress-state-reminder state)
                          (> (chat-agent-progress-state-inspection-after-error
                              state)
                             0))))
       (chat-agent-progress--reset state)
       (and recovered (list :event 'stagnation-recovered))))
    ('neutral nil)
    ('inspection
     (if (equal key (chat-agent-progress-state-last-inspection-key state))
         (setf (chat-agent-progress-state-same-inspection-count state)
               (1+ (chat-agent-progress-state-same-inspection-count state)))
       (setf (chat-agent-progress-state-last-inspection-key state) key
             (chat-agent-progress-state-same-inspection-count state) 1))
     (when (chat-agent-progress-state-after-error-p state)
       (setf (chat-agent-progress-state-inspection-after-error state)
             (1+ (chat-agent-progress-state-inspection-after-error state))))
     (when (chat-agent-progress-state-reminder state)
       (setf (chat-agent-progress-state-inspection-after-warning state)
             (1+ (chat-agent-progress-state-inspection-after-warning state))))
     (cond
      ((and (chat-agent-progress-state-after-error-p state)
            (>= (chat-agent-progress-state-inspection-after-error state)
                chat-agent-progress-stop-threshold))
       (setf (chat-agent-progress-state-stop-reason state)
             (format
              (concat "Agent stalled after a tool error: %d inspection calls "
                      "completed without a successful mutation or verification")
              (chat-agent-progress-state-inspection-after-error state)))
       (list :event 'stagnation-stopped
             :inspection-count
             (chat-agent-progress-state-inspection-after-error state)))
      ((>= (chat-agent-progress-state-inspection-after-warning state)
           chat-agent-progress-stop-threshold)
       (setf (chat-agent-progress-state-stop-reason state)
             (format
              (concat "Agent remained stalled after recovery guidance: %d "
                      "inspection calls completed without an observable "
                      "mutation or verification")
              (chat-agent-progress-state-inspection-after-warning state)))
       (list :event 'stagnation-stopped
             :inspection-count
             (chat-agent-progress-state-inspection-after-warning state)))
      ((and (null (chat-agent-progress-state-reminder state))
            (or (>= (chat-agent-progress-state-inspection-after-error state)
                    chat-agent-progress-warning-threshold)
                (>= (chat-agent-progress-state-same-inspection-count state)
                    chat-agent-progress-warning-threshold)))
       (chat-agent-progress--warning
        state
        (format "the same inspection target was queried %d times"
                (chat-agent-progress-state-same-inspection-count state))))
      (t nil)))
      (_ (error "Unknown Agent progress action: %S" kind)))))

(provide 'chat-agent-progress)
;;; chat-agent-progress.el ends here
