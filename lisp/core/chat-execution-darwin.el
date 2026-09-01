;;; chat-execution-darwin.el --- Capability-tested Darwin isolation -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; This backend treats sandbox-exec as a measured platform capability, not as
;; a portable promise.  It is installed only after a bounded probe proves that
;; a deny-default profile is enforced.  Every command gets canonical roots, an
;; explicit environment, a backend-owned timeout and Emacs' separate process
;; group for pipe subprocesses.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-execution)

(defgroup chat-execution-darwin nil
  "Darwin execution isolation backend."
  :group 'chat-execution)

(defcustom chat-execution-darwin-probe-timeout 3
  "Maximum seconds allowed for one backend availability probe."
  :type 'number
  :group 'chat-execution-darwin)

(defcustom chat-execution-darwin-termination-grace 0.2
  "Seconds allowed between process-group TERM and KILL."
  :type 'number
  :group 'chat-execution-darwin)

(defconst chat-execution-darwin--standard-read-roots
  '("/System" "/Library/Apple" "/Library/Developer"
    "/Library/Java/JavaVirtualMachines" "/Applications/Xcode.app"
    "/bin" "/sbin" "/usr/bin" "/usr/lib" "/usr/libexec" "/usr/share"
    "/usr/local" "/opt/homebrew" "/private/etc/ssl" "/dev")
  "System locations required by ordinary compiler and test processes.")

(defconst chat-execution-darwin--rust-command-regexp
  (concat "\\(?:\\`\\|[;&|]\\)[[:space:]]*"
          "\\(?:[[:alnum:]_]+=[^[:space:]]+[[:space:]]+\\)*"
          "\\(?:cargo\\|rustc\\|rustdoc\\|rustup\\)"
          "\\(?:[[:space:]]\\|\\'\\)")
  "Shell command pattern for tools whose location is managed by rustup.")

(defun chat-execution-darwin--environment-value (request name)
  "Return NAME from REQUEST's supplied environment, if present."
  (when-let* ((entry
               (seq-find
                (lambda (value)
                  (and (stringp value)
                       (string-prefix-p (concat name "=") value)))
                (chat-execution-request-environment request))))
    (substring entry (1+ (length name)))))

(defun chat-execution-darwin--developer-directory (request)
  "Return REQUEST's existing Xcode developer directory, if available."
  (let ((directory
         (or (chat-execution-darwin--environment-value request "DEVELOPER_DIR")
             "/Applications/Xcode.app/Contents/Developer")))
    (and (file-directory-p directory) (file-truename directory))))

(defun chat-execution-darwin--rust-command-p (request)
  "Return non-nil when REQUEST invokes a rustup-managed command."
  (seq-some
   (lambda (argument)
     (and (stringp argument)
          (string-match-p chat-execution-darwin--rust-command-regexp
                          argument)))
   (chat-execution-request-command request)))

(defun chat-execution-darwin--rustup-home (request)
  "Return REQUEST's existing rustup home for a Rust command, if any."
  (when (chat-execution-darwin--rust-command-p request)
    (let* ((developer-home
            (chat-execution-darwin--environment-value request "HOME"))
           (directory
            (or (chat-execution-darwin--environment-value request
                                                           "RUSTUP_HOME")
                (and developer-home
                     (expand-file-name ".rustup" developer-home)))))
      (and (file-directory-p (or directory ""))
           (file-truename directory)))))

(defun chat-execution-darwin--scheme-string (value)
  "Return VALUE escaped as one sandbox profile string literal."
  (concat "\""
          (replace-regexp-in-string
           "[\\\"]" (lambda (match) (concat "\\" match)) value t t)
          "\""))

(defun chat-execution-darwin--subpath-filter (path)
  "Return one sandbox subpath filter for canonical PATH."
  (format "(subpath %s)"
          (chat-execution-darwin--scheme-string
           (file-name-as-directory (file-truename path)))))

(defun chat-execution-darwin--profile (request temp-root)
  "Build a deny-default sandbox profile for REQUEST and TEMP-ROOT."
  (let* ((standard
          (seq-filter #'file-directory-p
                      chat-execution-darwin--standard-read-roots))
         (read-roots
          (delete-dups
           (append (chat-execution-request-read-roots request)
                   standard
                   (delq nil (list (chat-execution-darwin--developer-directory
                                    request)
                                   (chat-execution-darwin--rustup-home request)
                                   temp-root)))))
         (write-roots
          (delete-dups
           (append (chat-execution-request-write-roots request)
                   (list temp-root)))))
    (string-join
     (delq nil
           (list
            "(version 1)"
            "(deny default)"
            "(import \"system.sb\")"
            "(allow process*)"
            "(allow signal)"
            "(allow sysctl-read)"
            "(allow file-read-metadata file-test-existence)"
            (format "(allow file-read* file-test-existence %s)"
                    (mapconcat #'chat-execution-darwin--subpath-filter
                               read-roots " "))
            (format "(allow file-write* %s)"
                    (mapconcat #'chat-execution-darwin--subpath-filter
                               write-roots " "))
            (and (chat-execution-request-network request)
                 "(allow network*)")))
     "")))

(defun chat-execution-darwin--environment (request temp-root)
  "Return REQUEST environment filtered to declared keys and TEMP-ROOT."
  (let* ((source (or (chat-execution-request-environment request)
                     process-environment))
         (allowed (chat-execution-request-environment-keys request))
         (developer-directory
          (chat-execution-darwin--developer-directory request))
         (sdk-root
          (and developer-directory
               (expand-file-name
                "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
                developer-directory)))
         (rustup-home (chat-execution-darwin--rustup-home request))
         result)
    (dolist (entry source)
      (let ((name (and (stringp entry)
                       (car (split-string entry "=")))))
        (when (and name (member name allowed)
                   (not (assoc-string name result t)))
          (push entry result))))
    (setq result
          (delq
           nil
           (append
            (list (concat "HOME=" temp-root)
                  (concat "CFFIXED_USER_HOME=" temp-root)
                  (concat "TMPDIR=" temp-root)
                  (concat "CHAT_EXECUTION_POLICY="
                          (symbol-name (chat-execution-request-policy request)))
                  (and developer-directory
                       (concat "DEVELOPER_DIR=" developer-directory))
                  (and (file-directory-p (or sdk-root ""))
                       (concat "SDKROOT=" (file-truename sdk-root)))
                  (and rustup-home (concat "RUSTUP_HOME=" rustup-home)))
            (nreverse
             (cl-remove-if
              (lambda (entry)
                (or (string-prefix-p "HOME=" entry)
                    (string-prefix-p "CFFIXED_USER_HOME=" entry)
                    (string-prefix-p "TMPDIR=" entry)
                    (string-prefix-p "DEVELOPER_DIR=" entry)
                    (string-prefix-p "SDKROOT=" entry)
                    (string-prefix-p "RUSTUP_HOME=" entry)
                    (string-prefix-p "CHAT_EXECUTION_POLICY=" entry)))
              result)))))
    (when developer-directory
      (let* ((developer-paths
              (seq-filter
               #'file-directory-p
               (list
                (expand-file-name "usr/bin" developer-directory)
                (expand-file-name
                 "Toolchains/XcodeDefault.xctoolchain/usr/bin"
                 developer-directory))))
             (path-entry
              (seq-find (lambda (entry) (string-prefix-p "PATH=" entry))
                        result))
             (path-value (and path-entry (substring path-entry 5))))
        (setq result
              (cons (concat "PATH="
                            (string-join
                             (append developer-paths
                                     (and path-value (list path-value)))
                             path-separator))
                    (cl-remove-if
                     (lambda (entry) (string-prefix-p "PATH=" entry))
                     result)))))
    result))

(defun chat-execution-darwin--program (request)
  "Return REQUEST command with an absolute executable."
  (let* ((argv (copy-sequence (chat-execution-request-command request)))
         (program (car argv))
         (relative (expand-file-name
                    program (chat-execution-request-directory request)))
         (resolved
          (cond ((and (file-name-absolute-p program) (file-executable-p program))
                 program)
                ((file-executable-p relative) relative)
                ((executable-find program))))
         (developer-directory
          (chat-execution-darwin--developer-directory request))
         (tool-name (file-name-nondirectory (or resolved program)))
         (shim-p
          (and resolved
               (file-exists-p "/usr/bin/git")
               (ignore-errors (file-equal-p resolved "/usr/bin/git"))))
         (developer-tool
          (and shim-p developer-directory
               (seq-find
                #'file-executable-p
                (list
                 (expand-file-name (concat "usr/bin/" tool-name)
                                   developer-directory)
                 (expand-file-name
                  (concat "Toolchains/XcodeDefault.xctoolchain/usr/bin/"
                          tool-name)
                  developer-directory))))))
    (unless resolved
      (signal 'file-missing (list "Executable not found" program)))
    (setcar argv (file-truename (or developer-tool resolved)))
    argv))

(defun chat-execution-darwin--cleanup (process &optional fallback-root)
  "Cancel PROCESS timer and remove its managed or FALLBACK-ROOT temporary root."
  (when-let* ((timer (process-get process 'chat-execution-timeout-timer)))
    (when (timerp timer) (cancel-timer timer))
    (process-put process 'chat-execution-timeout-timer nil))
  (when-let* ((root (or (process-get process 'chat-execution-temp-root)
                        fallback-root)))
    (when (file-directory-p root)
      (ignore-errors (delete-directory root t)))
    (process-put process 'chat-execution-temp-root nil)))

(defun chat-execution-darwin--signal-group (process signal)
  "Send SIGNAL to PROCESS's private process group."
  (when-let* ((pid (and (processp process) (process-id process))))
    (condition-case nil
        (signal-process (- pid) signal)
      (error
       (when (process-live-p process)
         (signal-process process signal))))))

(defun chat-execution-darwin--terminate-tree (process)
  "Terminate PROCESS and every descendant in its private process group."
  (when (processp process)
    (chat-execution-darwin--signal-group process 'SIGTERM)
    (let ((deadline (+ (float-time) chat-execution-darwin-termination-grace)))
      (while (and (process-live-p process) (< (float-time) deadline))
        (accept-process-output process 0.02)))
    ;; The group may still contain a descendant after its leader exits.
    (chat-execution-darwin--signal-group process 'SIGKILL)
    (when (process-live-p process) (delete-process process))))

(defun chat-execution-darwin--start (request options sentinel)
  "Start restricted REQUEST with process OPTIONS and SENTINEL."
  (let ((base (expand-file-name "sandbox/" chat-execution-directory))
        temp-root
        process)
    (condition-case err
        (progn
          (make-directory base t)
          (setq temp-root
                (file-name-as-directory
                 (make-temp-file (expand-file-name "execution-" base) t)))
          (let* ((argv (chat-execution-darwin--program request))
                 (profile (chat-execution-darwin--profile request temp-root))
                 (command
                  (append (list "/usr/bin/sandbox-exec" "-p" profile) argv))
                 (default-directory
                  (chat-execution-request-directory request))
                 (process-environment
                  (chat-execution-darwin--environment request temp-root)))
            (setq
             process
             (make-process
              :name (or (plist-get options :name)
                        (chat-execution-request-id request))
              :buffer (plist-get options :buffer)
              :command command
              :stderr (plist-get options :stderr)
              :noquery (if (plist-member options :noquery)
                           (plist-get options :noquery) t)
              :connection-type (or (plist-get options :connection-type) 'pipe)
              :coding (plist-get options :coding)
              :filter (plist-get options :filter)
              :sentinel
              (lambda (proc event)
                (unless (process-live-p proc)
                  (chat-execution-darwin--cleanup proc temp-root))
                (funcall sentinel proc event)))))
          (process-put process 'chat-execution-temp-root temp-root)
          (when-let* ((timeout (chat-execution-request-timeout request)))
            (process-put
             process 'chat-execution-timeout-timer
             (run-at-time
              timeout nil
              (lambda ()
                (when (process-live-p process)
                  (process-put process 'chat-execution-terminal-status 'timed-out)
                  (process-put process 'chat-execution-terminal-reason
                               "backend timeout")
                  (chat-execution-darwin--terminate-tree process))))))
          process)
      (error
       (when (file-directory-p temp-root)
         (ignore-errors (delete-directory temp-root t)))
       (signal (car err) (cdr err))))))

(defun chat-execution-darwin--cancel (process)
  "Cancel restricted PROCESS and clean its owned temporary state."
  (chat-execution-darwin--terminate-tree process)
  (chat-execution-darwin--cleanup process))

(defun chat-execution-darwin--live-p (process)
  "Return non-nil while restricted PROCESS is alive."
  (and (processp process) (process-live-p process)))

(defun chat-execution-darwin--bounded-probe (command)
  "Run probe COMMAND in the foreground with a hard timeout."
  (let* ((buffer (generate-new-buffer " *chat-execution-probe*"))
         (process (make-process :name "chat-execution-probe" :buffer buffer
                                :command command :connection-type 'pipe
                                :noquery t))
         (deadline (+ (float-time) chat-execution-darwin-probe-timeout)))
    (unwind-protect
        (progn
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.02))
          (when (process-live-p process)
            (delete-process process)
            (signal 'chat-execution-capability-unavailable
                    (list "Darwin sandbox probe timed out")))
          (process-exit-status process))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun chat-execution-darwin-probe ()
  "Return measured Darwin isolation capability facts."
  (let* ((supported (and (eq system-type 'darwin)
                         (file-executable-p "/usr/bin/sandbox-exec")))
         (deny-status
          (and supported
               (chat-execution-darwin--bounded-probe
                '("/usr/bin/sandbox-exec" "-p"
                  "(version 1)(deny default)" "/bin/echo" "denied"))))
         (available (and supported (integerp deny-status)
                         (not (zerop deny-status)))))
    (chat-execution-capabilities-create
     :filesystem (if available 'scoped 'unavailable)
     :network (if available 'controlled 'unavailable)
     :environment (if available 'explicit 'unavailable)
     :timeout available :process-tree-cleanup available
     :platform system-type
     :availability (if available "available" "probe-failed"))))

(defun chat-execution-install-darwin-backend ()
  "Probe and register the Darwin backend, returning capability facts."
  (let ((facts (chat-execution-darwin-probe)))
    (chat-execution-register-backend
     (chat-execution-backend-create
      :id 'darwin-sandbox :capabilities facts
      :start-function #'chat-execution-darwin--start
      :cancel-function #'chat-execution-darwin--cancel
      :live-p-function #'chat-execution-darwin--live-p))
    facts))

(provide 'chat-execution-darwin)
;;; chat-execution-darwin.el ends here
