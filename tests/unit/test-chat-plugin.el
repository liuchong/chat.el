;;; test-chat-plugin.el --- Tests for the plugin host -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-plugin)
(require 'chat-plugin-emacs)
(require 'chat-tool-forge)

(defvar chat-plugin-test-unlisted-loaded nil)

(ert-deftest chat-plugin-waits-for-missing-inject ()
  "Test plugins do not start until inject requirements exist."
  (let ((chat-plugin--registry (make-hash-table :test 'eq))
        (chat-plugin--services (make-hash-table :test 'eq))
        (chat-plugin--started nil)
        started)
    (chat-plugin-define 'demo
                        :inject '(session)
                        :setup (lambda (_ctx) (setq started t)))
    (should-not (chat-plugin-start 'demo))
    (should-not started)
    (chat-plugin-provide 'session t)
    (should (chat-plugin-start 'demo))
    (should started)
    (chat-plugin-stop 'demo)))

(ert-deftest chat-plugin-retries-dependents-after-setup-provides-service ()
  "Test services provided during setup activate waiting plugins."
  (let ((chat-plugin--registry (make-hash-table :test 'eq))
        (chat-plugin--services (make-hash-table :test 'eq))
        (chat-plugin--started nil)
        (chat-plugin-enabled '(provider consumer))
        consumer-started)
    (chat-plugin-define
     'consumer
     :inject '(late-service)
     :setup (lambda (_ctx) (setq consumer-started t)))
    (chat-plugin-define
     'provider
     :setup (lambda (_ctx) (chat-plugin-provide 'late-service t)))
    (should-not (chat-plugin-start 'consumer))
    (should (chat-plugin-start 'provider))
    (should consumer-started)
    (should (eq (chat-plugin-state (chat-plugin-get 'consumer)) 'active))))

(ert-deftest chat-plugin-loads-only-explicitly-enabled-user-files ()
  "Test user plugin loading never evaluates unlisted Lisp files."
  (chat-test-with-temp-dir
   (let ((chat-plugin-directory temp-dir)
         (chat-plugin-load-user-directory t)
         (chat-plugin-enabled '(allowed))
         (chat-plugin--registry (make-hash-table :test 'eq))
         chat-plugin-test-unlisted-loaded)
     (with-temp-file (expand-file-name "allowed.el" temp-dir)
       (insert "(chat-plugin-define 'allowed :setup (lambda (_ctx) t))\n"))
     (with-temp-file (expand-file-name "unlisted.el" temp-dir)
       (insert "(setq chat-plugin-test-unlisted-loaded t)\n"))
     (chat-plugin-load-user-files)
     (should (chat-plugin-get 'allowed))
     (should-not chat-plugin-test-unlisted-loaded))))

(ert-deftest chat-plugin-tracks-lifecycle-states ()
  "Test plugin state moves through pending active failed and disposed."
  (let ((chat-plugin--registry (make-hash-table :test 'eq))
        (chat-plugin--services (make-hash-table :test 'eq))
        (chat-plugin--started nil)
        (chat-plugin-enabled '(pending-demo)))
    (chat-plugin-define 'pending-demo
                        :inject '(missing-service)
                        :setup (lambda (_ctx) t))
    (should-not (chat-plugin-start 'pending-demo))
    (should (eq (chat-plugin-state (chat-plugin-get 'pending-demo)) 'pending))
    (chat-plugin-provide 'missing-service t)
    (should (eq (chat-plugin-state (chat-plugin-get 'pending-demo)) 'active))
    (chat-plugin-stop 'pending-demo)
    (should (eq (chat-plugin-state (chat-plugin-get 'pending-demo)) 'disposed))
    (chat-plugin-define 'failed-demo
                        :setup (lambda (_ctx) (error "boom")))
    (should-not (chat-plugin-start 'failed-demo))
    (should (eq (chat-plugin-state (chat-plugin-get 'failed-demo)) 'failed))
    (should (string= (chat-plugin-error (chat-plugin-get 'failed-demo))
                     "boom"))))

(ert-deftest chat-plugin-rolls-back-owned-tools-hooks-and-services ()
  "Test owner-scoped resources are removed on stop."
  (let ((chat-plugin--registry (make-hash-table :test 'eq))
        (chat-plugin--services (make-hash-table :test 'eq))
        (chat-plugin--started nil)
        (chat-tool-forge--registry (make-hash-table :test 'eq))
        (chat-plugin-post-turn-functions nil)
        called)
    (chat-plugin-define
     'owned-demo
     :setup
     (lambda (_ctx)
       (chat-plugin-provide 'owned-service t)
       (chat-plugin-add-hook
        'chat-plugin-post-turn-functions
        (lambda (&rest _args) (setq called t)))
       (chat-plugin-register-tool
        (make-chat-forged-tool
         :id 'owned-tool
         :name "Owned Tool"
         :description "Owned"
         :language 'elisp
         :compiled-function (lambda (&rest _) "ok")
         :sensitivity 'project
         :effects '(read)
         :is-active t
         :usage-count 0))))
    (should (chat-plugin-start 'owned-demo))
    (should (chat-plugin-service 'owned-service))
    (should (chat-tool-forge-get 'owned-tool))
    (should (eq (chat-forged-tool-owner (chat-tool-forge-get 'owned-tool))
                'owned-demo))
    (run-hooks 'chat-plugin-post-turn-functions)
    (should called)
    (chat-plugin-stop 'owned-demo)
    (should-not (chat-plugin-service 'owned-service))
    (should-not (chat-tool-forge-get 'owned-tool))
    (setq called nil)
    (run-hooks 'chat-plugin-post-turn-functions)
    (should-not called)))

(ert-deftest chat-plugin-emacs-reads-buffer-line-range ()
  "Test emacs_read_buffer accepts integer line bounds."
  (with-temp-buffer
    (rename-buffer "chat-plugin-emacs-test" t)
    (insert "one\ntwo\nthree\n")
    (let ((text (chat-plugin-emacs--read-buffer (buffer-name) 2 2)))
      (should (string-match-p "two" text))
      (should-not (string-match-p "one" text))
      (should-not (string-match-p "three" text)))))

(ert-deftest chat-plugin-emacs-lists-live-buffers ()
  "Test emacs_buffers includes the current named buffer."
  (with-temp-buffer
    (rename-buffer "chat-plugin-emacs-buffers" t)
    (insert "hello")
    (let ((listing (chat-plugin-emacs--buffers)))
      (should (string-match-p "chat-plugin-emacs-buffers" listing)))))

(ert-deftest chat-plugin-emacs-denies-sensitive-buffers ()
  "Test Emacs buffer tools hard-deny sensitive buffers."
  (with-temp-buffer
    (rename-buffer ".env" t)
    (insert "TOKEN=value")
    (should-error (chat-plugin-emacs--read-buffer (buffer-name)))))

(ert-deftest chat-plugin-emacs-hides-buffers-outside-project ()
  "Test Emacs buffer listing is scoped to the current project."
  (chat-test-with-temp-dir
   (let* ((project-root (expand-file-name "project/" temp-dir))
          (inside-file (expand-file-name "inside.txt" project-root))
          (outside-file (expand-file-name "outside.txt" temp-dir))
          inside-buffer
          outside-buffer)
     (make-directory project-root t)
     (with-temp-file inside-file (insert "inside"))
     (with-temp-file outside-file (insert "outside"))
     (setq inside-buffer (find-file-noselect inside-file))
     (setq outside-buffer (find-file-noselect outside-file))
     (unwind-protect
         (cl-letf (((symbol-function 'chat-plugin-emacs--project-root)
                    (lambda () (file-truename project-root))))
           (with-current-buffer inside-buffer
             (let ((listing (chat-plugin-emacs--buffers)))
               (should (string-match-p "inside.txt" listing))
               (should-not (string-match-p "outside.txt" listing))))
           (should-error
            (chat-plugin-emacs--read-buffer (buffer-name outside-buffer))))
       (when (buffer-live-p inside-buffer)
         (kill-buffer inside-buffer))
       (when (buffer-live-p outside-buffer)
         (kill-buffer outside-buffer))))))

(ert-deftest chat-plugin-emacs-requires-approval-for-opted-in-outside-buffers ()
  "Test allow-all buffer access still requires explicit approval."
  (chat-test-with-temp-dir
   (let* ((project-root (expand-file-name "project/" temp-dir))
          (outside-file (expand-file-name "outside.txt" temp-dir))
          (chat-plugin-emacs-allow-all-buffers t)
          outside-buffer)
     (make-directory project-root t)
     (with-temp-file outside-file (insert "personal"))
     (setq outside-buffer (find-file-noselect outside-file))
     (unwind-protect
         (cl-letf (((symbol-function 'chat-plugin-emacs--project-root)
                    (lambda () (file-truename project-root))))
           (should
            (chat-plugin-emacs--buffer-call-needs-approval-p
             `(:arguments (("name" . ,(buffer-name outside-buffer)))))))
       (when (buffer-live-p outside-buffer)
         (kill-buffer outside-buffer))))))

(ert-deftest chat-plugin-emacs-registers-tools-on-setup ()
  "Test the emacs plugin registers read-only tools."
  (let ((chat-tool-forge--registry (make-hash-table :test 'eq))
        (chat-plugin--services (make-hash-table :test 'eq)))
    (chat-plugin-emacs-setup nil)
    (should (chat-tool-forge-get 'emacs_buffers))
    (should (chat-tool-forge-get 'emacs_read_buffer))
    (should (chat-tool-forge-get 'emacs_imenu))
    (should (chat-tool-forge-get 'emacs_xref))
    (should (chat-tool-forge-get 'emacs_project))
    (chat-plugin-emacs-teardown nil)
    (should-not (chat-forged-tool-is-active (chat-tool-forge-get 'emacs_buffers)))))

(provide 'test-chat-plugin)
;;; test-chat-plugin.el ends here
