;;; test-chat-execution-isolation.el --- Real execution isolation tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-execution)
(require 'chat-execution-darwin)

(defun chat-execution-isolation-test--wait (record &optional seconds)
  "Wait at most SECONDS for RECORD to stop."
  (let ((deadline (+ (float-time) (or seconds 5))))
    (while (and (chat-execution-live-p record) (< (float-time) deadline))
      (accept-process-output (chat-execution-native-handle record) 0.02))
    (accept-process-output nil 0.02))
  record)

(defun chat-execution-isolation-test--request
    (root command policy &optional environment timeout)
  "Build a restricted request rooted at ROOT for COMMAND and POLICY."
  (chat-execution-request-create
   :backend 'darwin-sandbox :command command :directory root
   :environment environment :policy policy :read-roots (list root)
   :write-roots (and (memq policy '(build networked-build)) (list root))
   :network (eq policy 'networked-build)
   :environment-keys '("PATH" "VISIBLE")
   :require-process-tree-cleanup t :timeout (or timeout 3)
   :session-id "isolation-session" :task-id "isolation-task"
   :idempotency 'idempotent))

(defmacro chat-execution-isolation-test--with-runtime (&rest body)
  "Run BODY with isolated execution registries and Darwin backend."
  (declare (indent 0) (debug t))
  `(let ((chat-execution-directory
          (expand-file-name "executions/" chat-state-dir))
         (chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq))
         (chat-execution--network-authorizations
          (make-hash-table :test 'equal)))
     (chat-execution-install-local-backend)
     (chat-execution-install-darwin-backend)
     ,@body))

(ert-deftest chat-execution-isolation-capabilities-come-from-a-real-probe ()
  "Restricted capability claims match the platform probe."
  (let ((facts (chat-execution-darwin-probe)))
    (if (eq system-type 'darwin)
        (progn
          (should (equal "available"
                         (chat-execution-capabilities-availability facts)))
          (should (eq 'scoped
                      (chat-execution-capabilities-filesystem facts)))
          (should (eq 'controlled
                      (chat-execution-capabilities-network facts)))
          (should (chat-execution-capabilities-process-tree-cleanup facts)))
      (should (equal "probe-failed"
                     (chat-execution-capabilities-availability facts))))))

(ert-deftest chat-execution-isolation-inspect-blocks-outside-read-and-all-write ()
  "Inspect can read its project but neither outside data nor project writes."
  (skip-unless (eq system-type 'darwin))
  (chat-test-with-temp-dir
   (chat-execution-isolation-test--with-runtime
     (let* ((project (expand-file-name "project/" temp-dir))
            (outside (expand-file-name "outside-secret" temp-dir))
            (inside (expand-file-name "inside" project)))
       (make-directory project)
       (write-region "inside" nil inside nil 'silent)
       (write-region "outside" nil outside nil 'silent)
       (let ((allowed
              (chat-execution-start
               (chat-execution-isolation-test--request
                project (list "/bin/cat" inside) 'inspect)))
             (read-escape
              (chat-execution-start
               (chat-execution-isolation-test--request
                project (list "/bin/cat" outside) 'inspect)))
             (write-attempt
              (chat-execution-start
               (chat-execution-isolation-test--request
                project
                (list "/bin/sh" "-c"
                      (format "printf denied >%s"
                              (shell-quote-argument
                               (expand-file-name "created" project))))
                'inspect))))
         (mapc #'chat-execution-isolation-test--wait
               (list allowed read-escape write-attempt))
         (should (eq 'completed (chat-execution-record-status allowed)))
         (should (eq 'failed (chat-execution-record-status read-escape)))
         (should (eq 'failed (chat-execution-record-status write-attempt)))
         (should-not (file-exists-p (expand-file-name "created" project))))))))

(ert-deftest chat-execution-isolation-build-allows-project-write-and-blocks-escapes ()
  "Build writes its project but not a parent path or symlink target."
  (skip-unless (eq system-type 'darwin))
  (chat-test-with-temp-dir
   (chat-execution-isolation-test--with-runtime
     (let* ((project (expand-file-name "project/" temp-dir))
            (outside (expand-file-name "outside/" temp-dir))
            (inside-file (expand-file-name "build.out" project))
            (parent-file (expand-file-name "parent.out" temp-dir))
            (escaped-file (expand-file-name "escaped.out" outside)))
       (make-directory project)
       (make-directory outside)
       (make-symbolic-link outside (expand-file-name "link" project))
       (let ((inside
              (chat-execution-start
               (chat-execution-isolation-test--request
                project (list "/usr/bin/touch" inside-file) 'build)))
             (parent
              (chat-execution-start
               (chat-execution-isolation-test--request
                project (list "/usr/bin/touch" parent-file) 'build)))
             (symlink
              (chat-execution-start
               (chat-execution-isolation-test--request
                project
                (list "/usr/bin/touch"
                      (expand-file-name "link/escaped.out" project))
                'build))))
         (mapc #'chat-execution-isolation-test--wait
               (list inside parent symlink))
         (should (eq 'completed (chat-execution-record-status inside)))
         (should (file-exists-p inside-file))
         (should (eq 'failed (chat-execution-record-status parent)))
         (should (eq 'failed (chat-execution-record-status symlink)))
         (should-not (file-exists-p parent-file))
         (should-not (file-exists-p escaped-file)))))))

(ert-deftest chat-execution-isolation-build-compiles-a-project-artifact ()
  "Build policy permits a real compiler to create a project-local artifact."
  (skip-unless (and (eq system-type 'darwin)
                    (file-executable-p "/usr/bin/clang")))
  (chat-test-with-temp-dir
   (chat-execution-isolation-test--with-runtime
     (let* ((project (expand-file-name "project/" temp-dir))
            (source (expand-file-name "main.c" project))
            (binary (expand-file-name "main" project))
            (output (generate-new-buffer " *isolation-clang-output*"))
            (errors (generate-new-buffer " *isolation-clang-errors*")))
       (make-directory project)
       (write-region "int main(void) { return 0; }\n" nil source nil 'silent)
       (unwind-protect
           (let ((compile
                  (chat-execution-start
                   (chat-execution-isolation-test--request
                    project (list "/usr/bin/clang" source "-o" binary) 'build)
                   :buffer output :stderr errors)))
             (chat-execution-isolation-test--wait compile 10)
             (ert-info ((concat (with-current-buffer output (buffer-string))
                                (with-current-buffer errors (buffer-string))))
               (should (eq 'completed (chat-execution-record-status compile))))
             (should (file-executable-p binary))
             (let ((run
                    (chat-execution-start
                     (chat-execution-isolation-test--request
                      project (list binary) 'inspect))))
               (chat-execution-isolation-test--wait run)
               (should (eq 'completed (chat-execution-record-status run))))
         (when (buffer-live-p output) (kill-buffer output))
         (when (buffer-live-p errors) (kill-buffer errors))))))))

(ert-deftest chat-execution-isolation-filters-environment-and-denies-network ()
  "Restricted execution sees declared variables only and has no network."
  (skip-unless (eq system-type 'darwin))
  (chat-test-with-temp-dir
   (chat-execution-isolation-test--with-runtime
     (let* ((project (expand-file-name "project/" temp-dir))
            (environment
             '("PATH=/usr/bin:/bin" "VISIBLE=yes" "SECRET_TOKEN=hidden"))
            (env-record nil)
            (network-record nil))
       (make-directory project)
       (setq env-record
             (chat-execution-start
              (chat-execution-isolation-test--request
               project
               '("/bin/sh" "-c"
                 "test \"$VISIBLE\" = yes && test -z \"$SECRET_TOKEN\"")
               'inspect environment)))
       (setq network-record
             (chat-execution-start
              (chat-execution-isolation-test--request
               project
               '("/usr/bin/python3" "-c"
                 "import socket; s=socket.socket(); s.bind(('127.0.0.1',0))")
               'inspect environment)))
       (mapc #'chat-execution-isolation-test--wait
             (list env-record network-record))
       (should (eq 'completed (chat-execution-record-status env-record)))
       (should (eq 'failed (chat-execution-record-status network-record)))))))

(ert-deftest chat-execution-isolation-timeout-kills-the-whole-process-group ()
  "Backend timeout kills a spawned child and removes its managed temp root."
  (skip-unless (eq system-type 'darwin))
  (chat-test-with-temp-dir
   (chat-execution-isolation-test--with-runtime
     (let* ((project (expand-file-name "project/" temp-dir))
            (pid-file (expand-file-name "child.pid" project))
            (script "sleep 30 & echo $! > child.pid; wait")
            record child-pid)
       (make-directory project)
       (setq record
             (chat-execution-start
              (chat-execution-isolation-test--request
               project (list "/bin/sh" "-c" script) 'build nil 0.4)))
       (chat-execution-isolation-test--wait record 3)
       (should (eq 'timed-out (chat-execution-record-status record)))
       (should (file-exists-p pid-file))
       (setq child-pid (string-to-number
                        (string-trim
                         (with-temp-buffer
                           (insert-file-contents pid-file)
                           (buffer-string)))))
       (let ((deadline (+ (float-time) 0.5)))
         (while (and (< (float-time) deadline)
                     (process-attributes child-pid))
           (accept-process-output nil 0.02)))
       (should-not (process-attributes child-pid))
       (let ((sandbox-root (expand-file-name "sandbox/" chat-execution-directory)))
         (should (or (not (file-directory-p sandbox-root))
                     (null (directory-files sandbox-root nil "^[^.].*")))))))))

(ert-deftest chat-execution-isolation-cancel-kills-the-whole-process-group ()
  "Explicit cancellation kills descendants and removes managed temp state."
  (skip-unless (eq system-type 'darwin))
  (chat-test-with-temp-dir
   (chat-execution-isolation-test--with-runtime
     (let* ((project (expand-file-name "project/" temp-dir))
            (pid-file (expand-file-name "child.pid" project))
            (script "sleep 30 & echo $! > child.pid; wait")
            record child-pid)
       (make-directory project)
       (setq record
             (chat-execution-start
              (chat-execution-isolation-test--request
               project (list "/bin/sh" "-c" script) 'build nil 10)))
       (let ((deadline (+ (float-time) 1)))
         (while (and (< (float-time) deadline) (not (file-exists-p pid-file)))
           (accept-process-output (chat-execution-native-handle record) 0.02)))
       (should (file-exists-p pid-file))
       (setq child-pid
             (string-to-number
              (string-trim
               (with-temp-buffer
                 (insert-file-contents pid-file)
                 (buffer-string)))))
       (chat-execution-cancel record "test cancellation")
       (should (eq 'canceled (chat-execution-record-status record)))
       (let ((deadline (+ (float-time) 0.5)))
         (while (and (< (float-time) deadline)
                     (process-attributes child-pid))
           (accept-process-output nil 0.02)))
       (should-not (process-attributes child-pid))
       (let ((sandbox-root (expand-file-name "sandbox/" chat-execution-directory)))
         (should (or (not (file-directory-p sandbox-root))
                     (null (directory-files sandbox-root nil "^[^.].*")))))))))

(ert-deftest chat-execution-isolation-restricted-policy-never-falls-back-local ()
  "A missing or mismatched restricted backend blocks instead of running local."
  (chat-test-with-temp-dir
   (let ((chat-execution--records (make-hash-table :test 'equal))
         (chat-execution--backends (make-hash-table :test 'eq)))
     (chat-execution-install-local-backend)
     (should-error (chat-execution-backend-for-policy 'build)
                   :type 'chat-execution-capability-unavailable)
     (make-directory (expand-file-name "project/" temp-dir))
     (should-error
      (chat-execution-start
       (chat-execution-request-create
        :backend 'local :command '("/bin/echo" "must not run")
        :directory (expand-file-name "project/" temp-dir)
        :policy 'build :read-roots (list (expand-file-name "project/" temp-dir))
        :write-roots (list (expand-file-name "project/" temp-dir))
        :network nil :timeout 1))
      :type 'chat-execution-capability-unavailable)
     (should (= 0 (hash-table-count chat-execution--records))))))

(ert-deftest chat-execution-isolation-start-preparation-failure-cleans-temp-root ()
  "A backend preparation error cannot strand its temporary directory."
  (skip-unless (eq system-type 'darwin))
  (chat-test-with-temp-dir
   (chat-execution-isolation-test--with-runtime
     (let ((project (expand-file-name "project/" temp-dir)))
       (make-directory project)
       (cl-letf (((symbol-function 'chat-execution-darwin--environment)
                  (lambda (&rest _arguments) (error "injected failure"))))
         (should-error
          (chat-execution-start
           (chat-execution-isolation-test--request
            project '("/bin/echo" "unreachable") 'inspect))))
       (let ((sandbox-root (expand-file-name "sandbox/" chat-execution-directory)))
         (should (or (not (file-directory-p sandbox-root))
                     (null (directory-files sandbox-root nil "^[^.].*")))))))))

(ert-deftest chat-execution-isolation-migrates-v1-records-to-explicit-local ()
  "Version-one records retain behavior by migrating to explicit local policy."
  (let* ((request
          (chat-execution--request-from-json
           '((schemaVersion . 1)
             (id . "legacy-execution")
             (backend . "local")
             (command . ["/bin/echo" "legacy"])
             (directory . "/tmp")
             (idempotency . "read-only")))))
    (should (= chat-execution-schema-version
               (chat-execution-request-schema-version request)))
    (should (eq 'local (chat-execution-request-policy request)))
    (should (eq 'local (chat-execution-request-backend request)))
    (should-not (chat-execution-request-network request))
    (should-not (chat-execution-request-read-roots request))
    (should-not (chat-execution-request-write-roots request))))

(ert-deftest chat-execution-isolation-networked-build-needs-one-use-approval ()
  "Network is authorized by the shared approval path and consumed once."
  (skip-unless (eq system-type 'darwin))
  (chat-test-with-temp-dir
   (chat-execution-isolation-test--with-runtime
     (let* ((project (expand-file-name "project/" temp-dir))
            (session (make-chat-session :id "isolation-session"))
            (request
             (chat-execution-isolation-test--request
              project
              '("/usr/bin/python3" "-c"
                "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); s.close()")
              'networked-build))
            approved record)
       (make-directory project)
       (setf (chat-execution-request-session-id request) nil)
       (should-error (chat-execution-start request)
                     :type 'chat-execution-network-authorization-required)
       (cl-letf (((symbol-function 'chat-approval-authorize-async)
                  (lambda (_tool _call _session _observer callback)
                    (funcall callback 'guard nil))))
         (chat-execution-authorize-network
          request session (lambda (consent _reason) (setq approved consent))))
       (should (eq approved 'guard))
       (should (equal "isolation-session"
                      (chat-execution-request-session-id request)))
       (setq record (chat-execution-start request))
       (chat-execution-isolation-test--wait record)
       (should (eq 'completed (chat-execution-record-status record)))
       (should-error (chat-execution-retry record)
                     :type 'chat-execution-network-authorization-required)))))

(provide 'test-chat-execution-isolation)
;;; test-chat-execution-isolation.el ends here
