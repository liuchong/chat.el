;;; test-chat-observability-view.el --- Tests for runtime views -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-observability-view)

(defmacro chat-observability-test-with-store (&rest body)
  "Run BODY with isolated Memory, Trace and evaluation stores."
  `(chat-test-with-temp-dir
    (let ((chat-memory-file (expand-file-name "memory.md" temp-dir))
          (chat-memory-directory (expand-file-name "memory/" temp-dir))
          (chat-eval-directory (expand-file-name "evals/" temp-dir))
          (chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (chat-session-wire-enabled t))
      ,@body)))

(defun chat-observability-test--wire-record
    (session seq stamp kind &optional turn-id payload)
  "Append a bounded test record to SESSION."
  (let ((target (chat-session-wire-file session)))
    (make-directory (file-name-directory target) t)
    (write-region
     (concat
      (json-encode
       (delq nil
             (list (cons 'schema_version 1)
                   (cons 'seq seq)
                   (cons 'timestamp_ms stamp)
                   (cons 'session_id session)
                   (cons 'kind kind)
                   (and turn-id (cons 'turn_id turn-id))
                   (cons 'payload payload))))
      "\n")
     nil target t 'silent)))

(ert-deftest chat-observability-exports-all-three-native-views ()
  "M7 inspection commands are public and backed by dedicated modes."
  (dolist (command '(chat-memory-view-open
                     chat-trace-view-open
                     chat-eval-view-open
                     chat-eval-view-export))
    (should (commandp command)))
  (dolist (mode '(chat-memory-view-mode
                  chat-trace-view-mode
                  chat-eval-view-mode))
    (should (fboundp mode))))

(ert-deftest chat-memory-view-row-exposes-provenance-and-policy-state ()
  "Memory rows expose the fields needed for review and tuning."
  (chat-observability-test-with-store
   (let* ((item (chat-memory-add
                 "Keep edits reversible."
                 :id "reviewed-rule"
                 :scope 'project :scope-id temp-dir
                 :confidence 0.85
                 :source-kind 'user :source-id "message:m1"))
          (columns (cadr (chat-memory-view--row item))))
     (should (equal "project" (aref columns 1)))
     (should (equal "0.85" (aref columns 2)))
     (should (equal "user:message:m1"
                    (substring-no-properties (aref columns 5))))
     (should (equal "active"
                    (substring-no-properties (aref columns 4)))))))

(ert-deftest chat-trace-view-reconstructs-wire-records-into-turn-rows ()
  "The Trace view remains a projection over the canonical wire history."
  (chat-observability-test-with-store
   (chat-observability-test--wire-record "view-session" 1 100
                                         "turn-start" 1)
   (chat-observability-test--wire-record
    "view-session" 2 140 "model-usage" 1 '((total_tokens . 9)))
   (chat-observability-test--wire-record
    "view-session" 3 180 "turn-ended" 1 '((status . "completed")))
   (let (opened)
     (cl-letf (((symbol-function 'pop-to-buffer)
                (lambda (buffer &rest _args) (setq opened buffer))))
       (chat-trace-view-open "view-session"))
     (unwind-protect
         (with-current-buffer opened
           (should (derived-mode-p 'chat-trace-view-mode))
           (should (= 1 (length tabulated-list-entries)))
           (let ((columns (cadr (car tabulated-list-entries))))
             (should (equal "completed"
                            (substring-no-properties (aref columns 1))))
             (should (equal "80" (aref columns 2)))
             (should (equal "9" (aref columns 4)))))
       (when (buffer-live-p opened) (kill-buffer opened))))))

(ert-deftest chat-eval-view-run-all-keeps-live-scenarios-opt-in ()
  "The default UI suite cannot silently execute provider-backed checks."
  (chat-observability-test-with-store
   (let ((chat-eval--registry (make-hash-table :test 'equal))
         (chat-eval-auto-save nil)
         (offline-runs 0)
         (live-runs 0))
     (chat-eval-register
      (chat-eval-scenario-create-record
       :schema-version 1 :id "offline" :revision 1 :category "ui"
       :description "offline" :fixture-id "offline-fixture" :fixture nil
       :tags '("offline") :live-p nil
       :function (lambda (_fixture)
                   (setq offline-runs (1+ offline-runs))
                   (list (chat-eval-check "offline" t t t)))))
     (chat-eval-register
      (chat-eval-scenario-create-record
       :schema-version 1 :id "live" :revision 1 :category "ui"
       :description "live" :fixture-id "live-fixture" :fixture nil
       :tags '("live") :live-p t
       :function (lambda (_fixture)
                   (setq live-runs (1+ live-runs))
                   (list (chat-eval-check "live" t t t)))))
     (with-temp-buffer
       (chat-eval-view-mode)
       (chat-test-silently (chat-eval-view-run-all)))
     (should (= 1 offline-runs))
     (should (= 0 live-runs)))))

(provide 'test-chat-observability-view)
;;; test-chat-observability-view.el ends here
