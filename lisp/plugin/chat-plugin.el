;;; chat-plugin.el --- Scoped Emacs plugin host -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A small plugin kernel for chat.el.  The agent loop remains the only
;; concrete driver; surrounding capabilities are added through named
;; extension points.  Emacs already has features, hooks, and
;; unwind-protect; this module gives those a scoped service context:
;;
;;   (chat-plugin-define 'emacs
;;     :inject '(chat-tool-forge)
;;     :setup (lambda (ctx) ...)
;;     :teardown (lambda (ctx) ...))
;;
;; Plugins must not be eval'd from disk unless listed in
;; `chat-plugin-enabled'.  User files under ~/.chat/plugins/ are only
;; loaded when `chat-plugin-load-user-directory' is non-nil.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-log)
(require 'chat-runtime-hook)
(require 'chat-tool-forge)

(defgroup chat-plugin nil
  "Plugin host for chat.el."
  :group 'chat
  :prefix "chat-plugin-")

(defcustom chat-plugin-enabled '(emacs)
  "Built-in plugin names started with `chat-plugin-start-enabled'."
  :type '(repeat symbol)
  :group 'chat-plugin)

(defcustom chat-plugin-directory
  (expand-file-name "~/.chat/plugins/")
  "Directory of optional user plugins."
  :type 'directory
  :group 'chat-plugin)

(defcustom chat-plugin-load-user-directory nil
  "When non-nil, load `*.el' files from `chat-plugin-directory'.
Disabled by default because those files run as Lisp."
  :type 'boolean
  :group 'chat-plugin)

(cl-defstruct (chat-plugin
               (:constructor chat-plugin-create)
               (:copier nil))
  name
  description
  inject
  setup
  teardown
  (active nil)
  (state 'pending)
  error
  owner
  owned-tools
  owned-services
  owned-hooks
  owned-resources)

(defvar chat-plugin--registry (make-hash-table :test 'eq)
  "Registered plugins keyed by name.")

(defvar chat-plugin--services (make-hash-table :test 'eq)
  "Named services provided by the running plugin context.")

(defvar chat-plugin--started nil
  "Plugin names started in this Emacs session.")

(defvar chat-plugin--current-owner nil
  "Plugin currently running setup or teardown.")

(defvar chat-plugin--retrying nil
  "Non-nil while pending plugin dependencies are being retried.")

(defvar chat-plugin-before-tool-call-functions nil
  "Hook: (run call) -> nil or (:block t :reason STRING).")
(defvar chat-plugin-after-tool-call-functions nil
  "Hook: (run call result).")
(defvar chat-plugin-pre-step-functions nil
  "Hook: (run) before each LLM turn.")
(defvar chat-plugin-post-turn-functions nil
  "Hook: (run processed) after each turn.")

(defun chat-plugin-define (name &rest spec)
  "Register plugin NAME from SPEC keys :description :inject :setup :teardown."
  (puthash name
           (chat-plugin-create
            :name name
            :description (plist-get spec :description)
            :inject (plist-get spec :inject)
            :setup (plist-get spec :setup)
            :teardown (plist-get spec :teardown)
            :owner name
            :active nil)
           chat-plugin--registry)
  name)

(defun chat-plugin-get (name)
  "Return the registered plugin named NAME, or nil."
  (gethash name chat-plugin--registry))

(defun chat-plugin-list ()
  "Return registered plugin names."
  (let (names)
    (maphash (lambda (name _plugin) (push name names))
             chat-plugin--registry)
    (sort names (lambda (a b)
                  (string< (symbol-name a) (symbol-name b))))))

(defun chat-plugin-provide (service value)
  "Provide SERVICE with VALUE in the plugin context."
  (when-let ((plugin (and chat-plugin--current-owner
                          (chat-plugin-get chat-plugin--current-owner))))
    (let ((missing (make-symbol "missing-service")))
      (push (list :type 'service
                  :id service
                  :previous (gethash service chat-plugin--services missing)
                  :missing missing)
            (chat-plugin-owned-resources plugin)))
    (push service (chat-plugin-owned-services plugin)))
  (puthash service value chat-plugin--services)
  (unless chat-plugin--current-owner
    (chat-plugin-retry-pending))
  value)

(defun chat-plugin-service (name)
  "Return the service named NAME, or nil."
  (gethash name chat-plugin--services))

(defun chat-plugin-context ()
  "Return a snapshot alist of current plugin services."
  (let (items)
    (maphash (lambda (key value) (push (cons key value) items))
             chat-plugin--services)
    items))

(defun chat-plugin--inject-ready-p (plugin)
  "Return non-nil when PLUGIN inject requirements are satisfied."
  (cl-every (lambda (name)
              (or (chat-plugin-service name)
                  (featurep name)))
            (or (chat-plugin-inject plugin) nil)))

(defun chat-plugin--record-tool (plugin tool-id)
  "Record TOOL-ID as owned by PLUGIN."
  (cl-pushnew tool-id (chat-plugin-owned-tools plugin)))

(defun chat-plugin-register-tool (tool)
  "Register TOOL and mark it as owned by the current plugin when any."
  (when chat-plugin--current-owner
    (setf (chat-forged-tool-owner tool) chat-plugin--current-owner))
  (let* ((previous (chat-tool-forge-get (chat-forged-tool-id tool)))
         (registered (chat-tool-forge-register tool)))
    (when-let ((plugin (and chat-plugin--current-owner
                            (chat-plugin-get chat-plugin--current-owner))))
      (chat-plugin--record-tool plugin (chat-forged-tool-id registered))
      (push (list :type 'tool
                  :id (chat-forged-tool-id registered)
                  :previous previous)
            (chat-plugin-owned-resources plugin)))
    registered))

(defun chat-plugin-add-hook (hook function)
  "Add FUNCTION to HOOK and record ownership for rollback."
  (let ((already-present (and (boundp hook)
                              (member function (symbol-value hook)))))
    (add-hook hook function)
    (when-let ((plugin (and chat-plugin--current-owner
                            (chat-plugin-get chat-plugin--current-owner))))
      (unless already-present
        (push (cons hook function) (chat-plugin-owned-hooks plugin))
        (push (list :type 'hook :hook hook :function function)
              (chat-plugin-owned-resources plugin))))
    function))

(defun chat-plugin-register-runtime-hook (declaration)
  "Register runtime hook DECLARATION with plugin ownership and rollback."
  (unless (chat-runtime-hook-p declaration)
    (error "Not a runtime hook declaration: %S" declaration))
  (when (and chat-plugin--current-owner
             (null (chat-runtime-hook-owner declaration)))
    (setf (chat-runtime-hook-owner declaration) chat-plugin--current-owner))
  (let* ((id (chat-runtime-hook-id declaration))
         (previous (chat-runtime-hook-get id))
         (registered (chat-runtime-hook-register declaration)))
    (when-let* ((plugin (and chat-plugin--current-owner
                             (chat-plugin-get chat-plugin--current-owner))))
      (push (list :type 'runtime-hook :id id :previous previous)
            (chat-plugin-owned-resources plugin)))
    registered))

(defun chat-plugin--rollback-resource (resource)
  "Rollback one owned RESOURCE."
  (pcase (plist-get resource :type)
    ('runtime-hook
     (if-let* ((previous (plist-get resource :previous)))
         (chat-runtime-hook-register previous)
       (chat-runtime-hook-unregister (plist-get resource :id))))
    ('hook
     (remove-hook (plist-get resource :hook)
                  (plist-get resource :function)))
    ('tool
     (if-let ((previous (plist-get resource :previous)))
         (puthash (plist-get resource :id)
                  previous
                  chat-tool-forge--registry)
       (chat-tool-forge-unload (plist-get resource :id))))
    ('service
     (let ((previous (plist-get resource :previous))
           (missing (plist-get resource :missing))
           (id (plist-get resource :id)))
       (if (eq previous missing)
           (remhash id chat-plugin--services)
         (puthash id previous chat-plugin--services))))))

(defun chat-plugin--rollback-owned (plugin)
  "Rollback owned resources for PLUGIN in reverse registration order."
  (dolist (resource (chat-plugin-owned-resources plugin))
    (condition-case err
        (chat-plugin--rollback-resource resource)
      (error
       (chat-log "[plugin] rollback failed for %S: %s"
                 resource (error-message-string err)))))
  (setf (chat-plugin-owned-resources plugin) nil
        (chat-plugin-owned-hooks plugin) nil
        (chat-plugin-owned-tools plugin) nil
        (chat-plugin-owned-services plugin) nil))

(defun chat-plugin-start (name)
  "Start plugin NAME.  Return the plugin or nil."
  (let ((plugin (chat-plugin-get name)))
    (cond
     ((null plugin)
      (chat-log "[plugin] unknown plugin %s" name)
      nil)
     ((chat-plugin-active plugin)
      plugin)
     ((not (chat-plugin--inject-ready-p plugin))
      (chat-log "[plugin] %s waiting for inject %S"
                name (chat-plugin-inject plugin))
      (setf (chat-plugin-state plugin) 'pending)
      nil)
     (t
      (condition-case err
          (let ((chat-plugin--current-owner name))
            (when (functionp (chat-plugin-setup plugin))
              (funcall (chat-plugin-setup plugin) (chat-plugin-context)))
            (setf (chat-plugin-active plugin) t
                  (chat-plugin-state plugin) 'active
                  (chat-plugin-error plugin) nil)
            (cl-pushnew name chat-plugin--started)
            (unless chat-plugin--retrying
              (chat-plugin-retry-pending))
            plugin)
        (error
         (chat-plugin--rollback-owned plugin)
         (setf (chat-plugin-active plugin) nil
               (chat-plugin-state plugin) 'failed
               (chat-plugin-error plugin) (error-message-string err))
         (chat-log "[plugin] failed to start %s: %s"
                   name (error-message-string err))
         nil))))))

(defun chat-plugin-stop (name)
  "Stop plugin NAME if it is active."
  (when-let ((plugin (chat-plugin-get name)))
    (when (chat-plugin-active plugin)
      (let ((chat-plugin--current-owner name)
            teardown-error)
        (unwind-protect
            (condition-case err
                (when (functionp (chat-plugin-teardown plugin))
                  (funcall (chat-plugin-teardown plugin)
                           (chat-plugin-context)))
              (error
               (setq teardown-error (error-message-string err))
               (chat-log "[plugin] teardown failed for %s: %s"
                         name teardown-error)))
          (chat-plugin--rollback-owned plugin))
        (setf (chat-plugin-error plugin) teardown-error))
      (setf (chat-plugin-active plugin) nil
            (chat-plugin-state plugin) 'disposed)
      (setq chat-plugin--started (delq name chat-plugin--started)))
    plugin))

(defun chat-plugin-retry-pending ()
  "Retry plugins that are pending and explicitly enabled."
  (let ((chat-plugin--retrying t))
    (maphash
     (lambda (name plugin)
       (when (and (eq (chat-plugin-state plugin) 'pending)
                  (memq name chat-plugin-enabled)
                  (not (chat-plugin-active plugin))
                  (chat-plugin--inject-ready-p plugin))
         (chat-plugin-start name)))
     chat-plugin--registry)))

(defun chat-plugin-start-enabled ()
  "Start every plugin listed in `chat-plugin-enabled'."
  (dolist (name chat-plugin-enabled)
    (chat-plugin-start name)))

(defun chat-plugin-load-user-files ()
  "Load explicitly enabled user plugin files when allowed.
Each enabled plugin NAME maps to NAME.el under `chat-plugin-directory';
unlisted Lisp files are never evaluated."
  (when (and chat-plugin-load-user-directory
             (file-directory-p chat-plugin-directory))
    (dolist (name chat-plugin-enabled)
      (let ((file (expand-file-name
                   (concat (symbol-name name) ".el")
                   chat-plugin-directory)))
        (when (file-regular-p file)
          (condition-case err
              (load file nil t)
            (error
             (chat-log "[plugin] failed to load %s: %s"
                       file (error-message-string err)))))))))

(provide 'chat-plugin)
;;; chat-plugin.el ends here
