;;; chat-plugin.el --- Emacs plugin host inspired by Cordis -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A small plugin kernel for chat.el.  DeepSeek's harness treats the
;; agent loop as the only concrete driver and puts everything else on
;; extension points.  Emacs already has features, hooks, and
;; unwind-protect; this module gives those a named service context:
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
  (active nil))

(defvar chat-plugin--registry (make-hash-table :test 'eq)
  "Registered plugins keyed by name.")

(defvar chat-plugin--services (make-hash-table :test 'eq)
  "Named services provided by the running plugin context.")

(defvar chat-plugin--started nil
  "Plugin names started in this Emacs session.")

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
  (puthash service value chat-plugin--services)
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
      nil)
     (t
      (when (functionp (chat-plugin-setup plugin))
        (funcall (chat-plugin-setup plugin) (chat-plugin-context)))
      (setf (chat-plugin-active plugin) t)
      (cl-pushnew name chat-plugin--started)
      plugin))))

(defun chat-plugin-stop (name)
  "Stop plugin NAME if it is active."
  (when-let ((plugin (chat-plugin-get name)))
    (when (chat-plugin-active plugin)
      (when (functionp (chat-plugin-teardown plugin))
        (funcall (chat-plugin-teardown plugin) (chat-plugin-context)))
      (setf (chat-plugin-active plugin) nil)
      (setq chat-plugin--started (delq name chat-plugin--started)))
    plugin))

(defun chat-plugin-start-enabled ()
  "Start every plugin listed in `chat-plugin-enabled'."
  (dolist (name chat-plugin-enabled)
    (chat-plugin-start name)))

(defun chat-plugin-load-user-files ()
  "Load user plugin files when that is explicitly enabled."
  (when (and chat-plugin-load-user-directory
             (file-directory-p chat-plugin-directory))
    (dolist (file (directory-files chat-plugin-directory t "\\.el\\'"))
      (condition-case err
          (load file nil t)
        (error
         (chat-log "[plugin] failed to load %s: %s"
                   file (error-message-string err)))))))

(provide 'chat-plugin)
;;; chat-plugin.el ends here
