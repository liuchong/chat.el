;;; test-chat-plugin.el --- Tests for the plugin host -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-plugin)
(require 'chat-plugin-emacs)
(require 'chat-tool-forge)

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
