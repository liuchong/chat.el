;;; chat-model-selection.el --- Delayed model selection state -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A chat has three model identities: the active target used by requests,
;; the prepared target shown at the prompt, and an optional pending switch
;; waiting for a request boundary.  Keeping them separate lets a reader
;; choose or command a new model without mutating a request already in flight.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-session)
(require 'chat-llm)

(cl-defstruct chat-model-target provider model)

(defconst chat-model-selection-metadata-key 'modelSelection
  "Session metadata key for prepared and pending model state.")

(defun chat-model-selection--provider (value)
  "Return VALUE as a provider symbol, or nil."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t nil)))

(defun chat-model-selection-target (provider &optional model)
  "Return a validated concrete target for PROVIDER and MODEL."
  (setq provider (chat-model-selection--provider provider))
  (let ((config (and provider (chat-llm-get-provider-config provider))))
    (unless config
      (user-error "Unknown provider: %s" provider))
    (setq model (or model (plist-get config :model)))
    (unless (and (stringp model) (not (string-empty-p model)))
      (user-error "Provider %s has no concrete model" provider))
    (when (and (chat-llm-provider-models provider)
               (not (member model (chat-llm-provider-models provider))))
      (user-error "Provider %s does not serve model %s" provider model))
    (make-chat-model-target :provider provider :model model)))

(defun chat-model-selection-target-equal-p (left right)
  "Return non-nil when LEFT and RIGHT name the same provider and model."
  (and (chat-model-target-p left)
       (chat-model-target-p right)
       (eq (chat-model-target-provider left)
           (chat-model-target-provider right))
       (equal (chat-model-target-model left)
              (chat-model-target-model right))))

(defun chat-model-selection--target-to-alist (target)
  "Encode TARGET for session metadata."
  `((provider . ,(symbol-name (chat-model-target-provider target)))
    (model . ,(chat-model-target-model target))))

(defun chat-model-selection--target-from-alist (value)
  "Decode a model target from metadata VALUE, or nil."
  (when (listp value)
    (let ((provider (chat-model-selection--provider
                     (alist-get 'provider value)))
          (model (alist-get 'model value)))
      (when (and provider (stringp model) (not (string-empty-p model)))
        (make-chat-model-target :provider provider :model model)))))

(defun chat-model-selection-active (session)
  "Return SESSION's concrete active request target."
  (chat-model-selection-target
   (chat-session-model-id session)
   (chat-session-model-name session)))

(defun chat-model-selection--state (session)
  "Return SESSION's model-selection metadata alist."
  (let ((state (chat-session-metadata-get
                session chat-model-selection-metadata-key)))
    (and (listp state) state)))

(defun chat-model-selection-prepared (session)
  "Return SESSION's prepared target, falling back to its active target."
  (or (chat-model-selection--target-from-alist
       (alist-get 'prepared (chat-model-selection--state session)))
      (chat-model-selection-active session)))

(defun chat-model-selection-pending (session)
  "Return SESSION's pending switch record, or nil."
  (let ((pending (alist-get 'pending (chat-model-selection--state session))))
    (and (listp pending) pending)))

(defun chat-model-selection-pending-target (session)
  "Return the target of SESSION's pending switch, or nil."
  (chat-model-selection--target-from-alist
   (chat-model-selection-pending session)))

(defun chat-model-selection-dirty-p (session)
  "Return non-nil when SESSION's prompt target is not active yet."
  (not (chat-model-selection-target-equal-p
        (chat-model-selection-active session)
        (chat-model-selection-prepared session))))

(defun chat-model-selection--save-state (session prepared pending)
  "Persist PREPARED and PENDING selection state for SESSION."
  (chat-session-metadata-set
   session chat-model-selection-metadata-key
   (delq nil
         (list (cons 'prepared
                     (chat-model-selection--target-to-alist prepared))
               (and pending (cons 'pending pending)))))
  (setf (chat-session-updated-at session) (current-time))
  (when (and (boundp 'chat-session-auto-save) chat-session-auto-save)
    (chat-session-save session))
  prepared)

(defun chat-model-selection-prepare (session target &optional keep-pending)
  "Prepare TARGET for SESSION without changing its active target.
Unless KEEP-PENDING is non-nil, an earlier commanded switch is superseded."
  (chat-model-selection--save-state
   session target
   (and keep-pending (chat-model-selection-pending session))))

(defun chat-model-selection-request (session target source)
  "Prepare TARGET and create SESSION's pending switch from SOURCE."
  (let ((pending
         `((id . ,(chat-session-new-message-id "model-switch"))
           (provider . ,(symbol-name (chat-model-target-provider target)))
           (model . ,(chat-model-target-model target))
           (source . ,(symbol-name source))
           (requestedAt . ,(format-time-string "%Y-%m-%dT%H:%M:%S%z")))))
    (chat-model-selection--save-state session target pending)
    pending))

(defun chat-model-selection-activate (session target &optional operation-id)
  "Make TARGET active for SESSION and return a matching pending record.

When OPERATION-ID is non-nil, consume pending state only when its identifier
matches.  This prevents a late event from consuming a newer request for the
same target.

A prepared target newer than TARGET is preserved.  This matters for queued
messages: each one owns the model captured when it was sent, while the prompt
may already be preparing a later message for another model."
  (let* ((prepared (chat-model-selection-prepared session))
         (pending (chat-model-selection-pending session))
         (pending-target (chat-model-selection--target-from-alist pending))
         (consumed (and (or (null operation-id)
                            (equal operation-id (alist-get 'id pending)))
                        (chat-model-selection-target-equal-p
                         target pending-target)
                        pending)))
    (setf (chat-session-model-id session) (chat-model-target-provider target)
          (chat-session-model-name session) (chat-model-target-model target))
    (chat-model-selection--save-state
     session
     (if (or consumed
             (chat-model-selection-target-equal-p prepared target))
         target
       prepared)
     (unless consumed pending))
    consumed))

(provide 'chat-model-selection)
;;; chat-model-selection.el ends here
