;;; chat-runtime-hook.el --- Versioned runtime hook declarations -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Runtime hooks are named declarations over `chat-event'.  A declaration
;; says which lifecycle events it observes or blocks, who owns it and where it
;; belongs in the deterministic order.  It does not create another hook bus.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'chat-event)
(require 'chat-extension-trust)

(defconst chat-runtime-hook-schema-version 1
  "Current runtime hook declaration schema version.")

(define-error 'chat-runtime-hook-unsupported-schema
  "Unsupported runtime hook schema")

(cl-defstruct
    (chat-runtime-hook
     (:constructor chat-runtime-hook-create
                   (&key
                    (schema-version chat-runtime-hook-schema-version)
                    id phase events handler (priority 0) owner description
                    source project-root timeout wrapper)))
  "One named declaration backed by the lifecycle event bus."
  schema-version id phase events handler priority owner description source
  project-root timeout wrapper)

(defvar chat-runtime-hook--registry (make-hash-table :test 'eq)
  "Runtime hook declarations keyed by id.")

(defvar chat-runtime-hook--blocker-wrappers nil
  "Generated blocker symbols currently installed on `chat-event'.")

(defvar chat-runtime-hook--observer-wrappers nil
  "Generated observer symbols currently installed on `chat-event'.")

(defun chat-runtime-hook--wrapper-symbol (id)
  "Return the stable wrapper symbol for hook ID."
  (intern (format "chat-runtime-hook/%s" id)))

(defun chat-runtime-hook--normalize (declaration)
  "Validate and return runtime hook DECLARATION."
  (unless (chat-runtime-hook-p declaration)
    (error "Not a runtime hook declaration: %S" declaration))
  (let ((version (chat-runtime-hook-schema-version declaration))
        (id (chat-runtime-hook-id declaration))
        (phase (chat-runtime-hook-phase declaration))
        (events (chat-runtime-hook-events declaration))
        (handler (chat-runtime-hook-handler declaration))
        (priority (chat-runtime-hook-priority declaration))
        (source (chat-runtime-hook-source declaration))
        (project-root (chat-runtime-hook-project-root declaration))
        (timeout (chat-runtime-hook-timeout declaration)))
    (when (> version chat-runtime-hook-schema-version)
      (signal 'chat-runtime-hook-unsupported-schema (list version)))
    (unless (= version chat-runtime-hook-schema-version)
      (error "Runtime hook schema must be %d" chat-runtime-hook-schema-version))
    (unless (symbolp id)
      (error "Runtime hook id must be a symbol: %S" id))
    (unless (memq phase '(blocker observer))
      (error "Runtime hook phase must be blocker or observer: %S" phase))
    (unless (and (listp events) events (seq-every-p #'symbolp events))
      (error "Runtime hook events must be a non-empty symbol list"))
    (when (and (eq phase 'blocker)
               (seq-some (lambda (event)
                           (not (memq event chat-event-blocking-types)))
                         events))
      (error "Blocker hook %s names a non-blocking lifecycle event" id))
    (unless (functionp handler)
      (error "Runtime hook handler must be callable: %S" handler))
    (unless (numberp priority)
      (error "Runtime hook priority must be numeric: %S" priority))
    (unless (or (null timeout) (and (numberp timeout) (> timeout 0)))
      (error "Runtime hook timeout must be a positive number or nil"))
    (when (and (eq source 'project)
               (not (chat-extension-project-trusted-p project-root)))
      (error "Project runtime hook %s is outside the trusted roots" id)))
  declaration)

(defun chat-runtime-hook--invoke (declaration event)
  "Invoke DECLARATION for EVENT with its optional timeout."
  (let ((timeout (chat-runtime-hook-timeout declaration))
        (handler (chat-runtime-hook-handler declaration)))
    (if timeout
        (with-timeout
            (timeout
             (list :failure 'timeout
                   :reason (format "runtime hook %s timed out after %.3fs"
                                   (chat-runtime-hook-id declaration)
                                   timeout)))
          (funcall handler event))
      (funcall handler event))))

(defun chat-runtime-hook--less-p (left right)
  "Return non-nil when LEFT runs before RIGHT."
  (let ((lp (chat-runtime-hook-priority left))
        (rp (chat-runtime-hook-priority right)))
    (if (= lp rp)
        (string< (symbol-name (chat-runtime-hook-id left))
                 (symbol-name (chat-runtime-hook-id right)))
      (< lp rp))))

(defun chat-runtime-hook--declarations (phase)
  "Return registered declarations for PHASE in execution order."
  (let (items)
    (maphash
     (lambda (_id declaration)
       (when (eq phase (chat-runtime-hook-phase declaration))
         (push declaration items)))
     chat-runtime-hook--registry)
    (sort items #'chat-runtime-hook--less-p)))

(defun chat-runtime-hook--remove-installed (phase)
  "Remove generated wrappers installed for PHASE."
  (let ((wrappers (if (eq phase 'blocker)
                      chat-runtime-hook--blocker-wrappers
                    chat-runtime-hook--observer-wrappers)))
    (dolist (wrapper wrappers)
      (if (eq phase 'blocker)
          (chat-event-remove-blocker wrapper)
        (chat-event-remove-observer wrapper)))
    (if (eq phase 'blocker)
        (setq chat-runtime-hook--blocker-wrappers nil)
      (setq chat-runtime-hook--observer-wrappers nil))))

(defun chat-runtime-hook--install-wrapper (declaration)
  "Install the generated event wrapper for DECLARATION."
  (let* ((id (chat-runtime-hook-id declaration))
         (phase (chat-runtime-hook-phase declaration))
         (wrapper (chat-runtime-hook--wrapper-symbol id)))
    (fset wrapper
          (lambda (event)
            (let ((current (gethash id chat-runtime-hook--registry)))
              (when (and current
                         (memq (chat-event-type event)
                               (chat-runtime-hook-events current)))
                (chat-runtime-hook--invoke current event)))))
    (setf (chat-runtime-hook-wrapper declaration) wrapper)
    (if (eq phase 'blocker)
        (progn
          (chat-event-add-blocker wrapper)
          (setq chat-runtime-hook--blocker-wrappers
                (append chat-runtime-hook--blocker-wrappers (list wrapper))))
      (chat-event-add-observer wrapper)
      (setq chat-runtime-hook--observer-wrappers
            (append chat-runtime-hook--observer-wrappers (list wrapper))))))

(defun chat-runtime-hook--rebuild (phase)
  "Rebuild generated wrappers for PHASE in declaration order."
  (chat-runtime-hook--remove-installed phase)
  (dolist (declaration (chat-runtime-hook--declarations phase))
    (chat-runtime-hook--install-wrapper declaration)))

(defun chat-runtime-hook-register (declaration)
  "Register versioned runtime hook DECLARATION."
  (chat-runtime-hook--normalize declaration)
  (let* ((id (chat-runtime-hook-id declaration))
         (old (gethash id chat-runtime-hook--registry))
         (old-phase (and old (chat-runtime-hook-phase old))))
    (puthash id declaration chat-runtime-hook--registry)
    (when old-phase
      (chat-runtime-hook--rebuild old-phase))
    (unless (eq old-phase (chat-runtime-hook-phase declaration))
      (chat-runtime-hook--rebuild (chat-runtime-hook-phase declaration)))
    declaration))

(defun chat-runtime-hook-unregister (id)
  "Unregister runtime hook ID and return non-nil when it existed."
  (when-let* ((declaration (gethash id chat-runtime-hook--registry)))
    (let ((phase (chat-runtime-hook-phase declaration))
          (wrapper (chat-runtime-hook-wrapper declaration)))
      (remhash id chat-runtime-hook--registry)
      (chat-runtime-hook--rebuild phase)
      (when (and wrapper (fboundp wrapper))
        (fmakunbound wrapper))
      t)))

(defun chat-runtime-hook-unregister-owner (owner)
  "Unregister every runtime hook owned by OWNER and return their ids."
  (let (ids)
    (maphash
     (lambda (id declaration)
       (when (equal owner (chat-runtime-hook-owner declaration))
         (push id ids)))
     chat-runtime-hook--registry)
    (dolist (id ids)
      (chat-runtime-hook-unregister id))
    (sort ids (lambda (left right)
                (string< (symbol-name left) (symbol-name right))))))

(defun chat-runtime-hook-get (id)
  "Return the runtime hook declaration named ID."
  (gethash id chat-runtime-hook--registry))

(defun chat-runtime-hook-list ()
  "Return all runtime hook declarations in deterministic order."
  (append (chat-runtime-hook--declarations 'blocker)
          (chat-runtime-hook--declarations 'observer)))

(provide 'chat-runtime-hook)
;;; chat-runtime-hook.el ends here
