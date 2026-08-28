;;; chat-code-intelligence.el --- Unified code intelligence facade -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This module gives coding sessions one typed, asynchronous interface to
;; semantic and structural code intelligence.  Backends are ordered and
;; replaceable; an unavailable backend is not confused with a successful
;; empty query.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup chat-code-intelligence nil
  "Unified code intelligence for chat.el."
  :group 'chat-code
  :prefix "chat-code-intelligence-")

(defcustom chat-code-intelligence-timeout 1.5
  "Maximum seconds for one facade query."
  :type 'number
  :group 'chat-code-intelligence)

(cl-defstruct chat-code-intelligence-backend
  "A code intelligence backend registered with the facade."
  name priority operations available query synchronous-query)

(defvar chat-code-intelligence--backends nil
  "Registered code intelligence backends.")

(defconst chat-code-intelligence--statuses
  '(ok empty unavailable timeout error))

(defconst chat-code-intelligence--operations
  '(definition references implementations symbols callers callees diagnostics))

(defun chat-code-intelligence-register-backend (backend)
  "Register BACKEND, replacing another backend with the same name."
  (unless (chat-code-intelligence-backend-p backend)
    (error "Invalid code intelligence backend: %S" backend))
  (setq chat-code-intelligence--backends
        (cons backend
              (seq-remove
               (lambda (existing)
                 (eq (chat-code-intelligence-backend-name existing)
                     (chat-code-intelligence-backend-name backend)))
               chat-code-intelligence--backends)))
  (setq chat-code-intelligence--backends
        (sort chat-code-intelligence--backends
              (lambda (a b)
                (let ((pa (chat-code-intelligence-backend-priority a))
                      (pb (chat-code-intelligence-backend-priority b)))
                  (if (= pa pb)
                      (string< (symbol-name (chat-code-intelligence-backend-name a))
                               (symbol-name (chat-code-intelligence-backend-name b)))
                    (< pa pb))))))
  backend)

(defun chat-code-intelligence-unregister-backend (name)
  "Remove the backend named NAME."
  (setq chat-code-intelligence--backends
        (seq-remove
         (lambda (backend)
           (eq (chat-code-intelligence-backend-name backend) name))
         chat-code-intelligence--backends)))

(defun chat-code-intelligence--backend-supports-p (backend operation)
  "Return non-nil when BACKEND supports OPERATION."
  (memq operation (chat-code-intelligence-backend-operations backend)))

(defun chat-code-intelligence--path-in-root-p (path root)
  "Return non-nil when PATH is inside ROOT."
  (and (stringp path)
       (stringp root)
       (condition-case nil
           (let ((canonical-path (file-truename path))
                 (canonical-root (file-name-as-directory (file-truename root))))
             (string-prefix-p canonical-root canonical-path))
         (file-error nil))))

(defun chat-code-intelligence--normalize-item (item backend root)
  "Normalize ITEM from BACKEND and constrain it to ROOT."
  (let ((path (plist-get item :path)))
    (when (and path (chat-code-intelligence--path-in-root-p path root))
      (list :path (file-truename path)
            :line (max 1 (or (plist-get item :line) 1))
            :column (max 0 (or (plist-get item :column) 0))
            :name (or (plist-get item :name) "")
            :kind (or (plist-get item :kind) 'unknown)
            :confidence (max 0.0 (min 1.0 (or (plist-get item :confidence) 0.5)))
            :source (or (plist-get item :source) backend)
            :detail (plist-get item :detail)))))

(defun chat-code-intelligence--item-less-p (a b)
  "Return non-nil when normalized item A sorts before B."
  (let ((ca (plist-get a :confidence))
        (cb (plist-get b :confidence)))
    (cond
     ((/= ca cb) (> ca cb))
     ((not (string= (plist-get a :path) (plist-get b :path)))
      (string< (plist-get a :path) (plist-get b :path)))
     ((/= (plist-get a :line) (plist-get b :line))
      (< (plist-get a :line) (plist-get b :line)))
     ((/= (plist-get a :column) (plist-get b :column))
      (< (plist-get a :column) (plist-get b :column)))
     (t (string< (plist-get a :name) (plist-get b :name))))))

(defun chat-code-intelligence--normalize-result (result operation backend request)
  "Normalize backend RESULT for OPERATION, BACKEND, and REQUEST."
  (let* ((status (plist-get result :status))
         (root (plist-get request :project-root))
         (items (delq nil
                      (mapcar
                       (lambda (item)
                         (chat-code-intelligence--normalize-item item backend root))
                       (plist-get result :items)))))
    (unless (memq status chat-code-intelligence--statuses)
      (setq status 'error))
    (when (and (eq status 'ok) (null items))
      (setq status 'empty))
    (list :status status
          :operation operation
          :backend backend
          :revision (or (plist-get result :revision) "unknown")
          :items (sort (delete-dups items) #'chat-code-intelligence--item-less-p)
          :diagnostics (plist-get result :diagnostics)
          :reason (plist-get result :reason))))

(defun chat-code-intelligence--terminal-result (status operation attempts &optional reason)
  "Build a terminal STATUS result for OPERATION and ATTEMPTS."
  (list :status status
        :operation operation
        :backend nil
        :revision "none"
        :items nil
        :diagnostics nil
        :attempts (nreverse attempts)
        :reason reason))

(defun chat-code-intelligence-query-async (operation request callback &optional timeout)
  "Query OPERATION with REQUEST and call CALLBACK with a typed result.

REQUEST must include `:project-root'.  The returned function cancels the
query.  Backends are tried in priority order until one returns items.
Empty, unavailable, timeout and error attempts remain distinguishable in
the final result."
  (unless (memq operation chat-code-intelligence--operations)
    (error "Unsupported code intelligence operation: %S" operation))
  (let* ((candidates
          (seq-filter
           (lambda (backend)
             (and (chat-code-intelligence--backend-supports-p backend operation)
                  (let ((available
                         (chat-code-intelligence-backend-available backend)))
                    (or (null available) (funcall available request operation)))))
           chat-code-intelligence--backends))
         (pending candidates)
         (attempts nil)
         (done nil)
         (timer nil))
    (cl-labels
        ((finish (result)
           (unless done
             (setq done t)
             (when (timerp timer) (cancel-timer timer))
             (funcall callback (plist-put result :attempts (nreverse attempts)))))
         (next ()
           (if (null pending)
               (let* ((statuses (mapcar (lambda (a) (plist-get a :status)) attempts))
                      (status (cond
                               ((memq 'empty statuses) 'empty)
                               ((memq 'timeout statuses) 'timeout)
                               ((memq 'error statuses) 'error)
                               (t 'unavailable))))
                 (finish (chat-code-intelligence--terminal-result
                          status operation nil "No backend returned semantic items")))
             (let* ((backend (pop pending))
                    (name (chat-code-intelligence-backend-name backend))
                    (query (chat-code-intelligence-backend-query backend)))
               (condition-case err
                   (funcall
                    query request operation
                    (lambda (raw)
                      (unless done
                        (let ((result
                               (chat-code-intelligence--normalize-result
                                raw operation name request)))
                          (push (list :backend name
                                      :status (plist-get result :status)
                                      :reason (plist-get result :reason))
                                attempts)
                          (if (eq (plist-get result :status) 'ok)
                              (finish result)
                            (next))))))
                 (error
                  (push (list :backend name :status 'error
                              :reason (error-message-string err))
                        attempts)
                  (next)))))))
      (setq timer
            (run-at-time
             (or timeout chat-code-intelligence-timeout) nil
             (lambda ()
               (finish
                (chat-code-intelligence--terminal-result
                 'timeout operation nil "Code intelligence query timed out")))))
      (run-at-time 0 nil #'next)
      (lambda ()
        (setq done t)
        (when (timerp timer) (cancel-timer timer))))))

(defun chat-code-intelligence-query-cached (operation request)
  "Return the first synchronous cached result for OPERATION and REQUEST.

This function never starts a service or scans a project.  It is intended
for latency-sensitive request assembly."
  (let ((backends chat-code-intelligence--backends)
        result
        attempts)
    (while (and backends (not (eq (plist-get result :status) 'ok)))
      (let* ((backend (pop backends))
             (name (chat-code-intelligence-backend-name backend))
             (query (chat-code-intelligence-backend-synchronous-query backend)))
        (when (and query
                   (chat-code-intelligence--backend-supports-p backend operation)
                   (let ((available (chat-code-intelligence-backend-available backend)))
                     (or (null available) (funcall available request operation))))
          (condition-case err
              (let ((candidate
                     (chat-code-intelligence--normalize-result
                      (funcall query request operation) operation name request)))
                (push (list :backend name :status (plist-get candidate :status)) attempts)
                (setq result candidate))
            (error
             (push (list :backend name :status 'error
                         :reason (error-message-string err)) attempts))))))
    (plist-put
     (or result
         (chat-code-intelligence--terminal-result
          'unavailable operation nil "No warm code intelligence backend"))
     :attempts (nreverse attempts))))

(defun chat-code-intelligence--index-available-p (request _operation)
  "Return non-nil when REQUEST has a warm structural index."
  (and (fboundp 'chat-code-intel-active-index)
       (chat-code-intel-active-index (plist-get request :project-root))))

(defun chat-code-intelligence--index-item (object source)
  "Convert index OBJECT to a facade item from SOURCE."
  (cond
   ((and (fboundp 'chat-code-symbol-p) (chat-code-symbol-p object))
    (list :path (chat-code-symbol-file object)
          :line (chat-code-symbol-line object)
          :column (or (chat-code-symbol-column object) 0)
          :name (chat-code-symbol-name object)
          :kind (chat-code-symbol-type object)
          :confidence 0.72 :source source))
   ((and (fboundp 'chat-code-reference-p) (chat-code-reference-p object))
    (list :path (chat-code-reference-file object)
          :line (chat-code-reference-line object)
          :column (or (chat-code-reference-column object) 0)
          :name (chat-code-reference-symbol-name object)
          :kind (chat-code-reference-type object)
          :confidence 0.62 :source source))))

(defun chat-code-intelligence--index-revision (index)
  "Return a deterministic revision for INDEX."
  (secure-hash
   'sha256
   (mapconcat #'identity (sort (copy-sequence (chat-code-index-files index)) #'string<)
              "\0")))

(defun chat-code-intelligence--index-query (request operation)
  "Query the warm fallback index for REQUEST and OPERATION."
  (let* ((index (chat-code-intel-active-index (plist-get request :project-root)))
         (name (plist-get request :symbol))
         (path (plist-get request :path))
         raw)
    (if (null index)
        (list :status 'unavailable :reason "Structural index is not warm")
      (setq raw
            (pcase operation
              ('definition (and name (chat-code-intel-find-definition index name)))
              ('references (and name (chat-code-intel-find-references index name)))
              ('symbols (and path (chat-code-intel-get-file-symbols index path)))
              ('callers
               (apply #'append
                      (mapcar (lambda (caller)
                                (chat-code-intel-find-definition index caller))
                              (or (and name (chat-code-intel-get-callers index name)) nil))))
              ('callees
               (apply #'append
                      (mapcar (lambda (callee)
                                (chat-code-intel-find-definition index callee))
                              (or (and name (chat-code-intel-get-callees index name)) nil))))
              (_ nil)))
      (list :status (if raw 'ok 'empty)
            :revision (chat-code-intelligence--index-revision index)
            :items (delq nil
                         (mapcar (lambda (item)
                                   (chat-code-intelligence--index-item item 'index))
                                 raw))))))

(defun chat-code-intelligence-install-default-backends ()
  "Install built-in public semantic and structural backends."
  (when (fboundp 'chat-code-lsp-backend)
    (chat-code-intelligence-register-backend (chat-code-lsp-backend)))
  (when (featurep 'chat-code-intel)
    (chat-code-intelligence-register-backend
     (make-chat-code-intelligence-backend
      :name 'index :priority 30
      :operations '(definition references symbols callers callees)
      :available #'chat-code-intelligence--index-available-p
      :query (lambda (request operation callback)
               (run-at-time
                0 nil callback
                (chat-code-intelligence--index-query request operation)))
      :synchronous-query #'chat-code-intelligence--index-query))))

(provide 'chat-code-intelligence)
;;; chat-code-intelligence.el ends here
