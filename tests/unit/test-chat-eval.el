;;; test-chat-eval.el --- Tests for deterministic evaluations -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-eval)

(defmacro chat-eval-test-with-runtime (&rest body)
  "Run BODY with isolated registry, result files, clock and IDs."
  `(chat-test-with-temp-dir
    (let ((chat-eval--registry (make-hash-table :test 'equal))
          (chat-eval-directory (expand-file-name "evals/" temp-dir))
          (chat-eval-auto-save t)
          (chat-eval-clock-function
           (let ((times '(100 125 200 240 300 350)))
             (lambda () (or (pop times) 999))))
          (chat-eval-id-function
           (let ((ids '("r1" "r2" "r3")))
             (lambda () (or (pop ids) "r-last")))))
      ,@body)))

(defun chat-eval-test--scenario (id function &optional revision live)
  "Return a test scenario."
  (chat-eval-scenario-create-record
   :schema-version chat-eval-scenario-schema-version
   :id id :revision (or revision 1) :category "runtime"
   :description id :fixture-id (concat id "-fixture")
   :fixture `((value . 7)) :tags '("offline")
   :live-p live :function function))

(ert-deftest chat-eval-registry-is-versioned-sorted-and-excludes-live ()
  "Offline listing is deterministic and live checks remain opt-in."
  (chat-eval-test-with-runtime
   (chat-eval-register
    (chat-eval-test--scenario "b" (lambda (_fixture) nil)))
   (chat-eval-register
    (chat-eval-test--scenario "a" (lambda (_fixture) nil)))
   (chat-eval-register
    (chat-eval-test--scenario "live" (lambda (_fixture) nil) 1 t))
   (should (equal '("a" "b")
                  (mapcar #'chat-eval-scenario-id
                          (chat-eval-scenarios))))
   (should (= 3 (length (chat-eval-scenarios t))))
   (should-error
    (chat-eval-register
     (chat-eval-test--scenario "a" (lambda (_fixture) nil))))
   (should-error
    (chat-eval-register
     (chat-eval-test--scenario "a" (lambda (_fixture) nil) 0)
     t))))

(ert-deftest chat-eval-run-persists-an-immutable-round-trip ()
  "A result identifies its fixture and cannot overwrite prior evidence."
  (chat-eval-test-with-runtime
   (chat-eval-register
    (chat-eval-test--scenario
     "pass"
     (lambda (fixture)
       (list (chat-eval-check
              "fixture-value" (= 7 (alist-get 'value fixture))
              7 (alist-get 'value fixture))))))
   (let* ((result (chat-eval-run "pass"))
          (loaded (chat-eval-load-result (chat-eval-result-id result))))
     (should (eq 'passed (chat-eval-result-status result)))
     (should (= 25 (chat-eval-result-duration-ms result)))
     (should (= 64 (length (chat-eval-result-fixture-digest result))))
     (should (equal (chat-eval-result-fixture-digest result)
                    (chat-eval-result-fixture-digest loaded)))
     (should-error (chat-eval-save-result result)))))

(ert-deftest chat-eval-scenario-errors-fail-one-result-not-the-suite ()
  "One broken scenario does not prevent later scenarios from running."
  (chat-eval-test-with-runtime
   (let ((chat-eval-auto-save nil))
     (chat-eval-register
      (chat-eval-test--scenario
       "broken" (lambda (_fixture) (error "fixture failed"))))
     (chat-eval-register
      (chat-eval-test--scenario
       "working"
       (lambda (_fixture)
         (list (chat-eval-check "works" t t t)))))
     (let ((results (chat-eval-run-all)))
       (should (= 2 (length results)))
       (should (eq 'failed (chat-eval-result-status (car results))))
       (should (eq 'passed (chat-eval-result-status (cadr results))))))))

(ert-deftest chat-eval-values-are-redacted-and-bounded-before-persistence ()
  "Credential-like and oversized actual values do not enter result files."
  (chat-eval-test-with-runtime
   (let ((chat-eval-max-value-bytes 80))
     (chat-eval-register
      (chat-eval-test--scenario
       "bounded"
       (lambda (_fixture)
         (list
          (chat-eval-check "secret" t nil "api_key=abcdefghijklmnop")
          (chat-eval-check "large" t nil (make-string 1000 ?x))))))
     (let* ((result (chat-eval-run "bounded"))
            (checks (chat-eval-result-checks result))
            (json (with-temp-buffer
                    (insert-file-contents
                     (chat-eval--result-file (chat-eval-result-id result)))
                    (buffer-string))))
       (should (equal "[redacted]" (chat-eval-check-actual (car checks))))
       (should (eq t (alist-get 'truncated
                                (chat-eval-check-actual (cadr checks)))))
       (should-not (string-match-p "abcdefghijklmnop" json))
       (should-not (string-match-p (make-string 100 ?x) json))))))

(ert-deftest chat-eval-export-is-public-bounded-and-redacted ()
  "Result export uses the same bounded privacy projection as persistence."
  (chat-eval-test-with-runtime
   (let ((chat-eval-auto-save nil)
         (chat-eval-max-value-bytes 80))
     (chat-eval-register
      (chat-eval-test--scenario
       "export"
       (lambda (_fixture)
         (list
          (chat-eval-check "secret" t nil "token=abcdefghijklmnop")
          (chat-eval-check "large" t nil (make-string 1000 ?x))))))
     (let ((json (chat-eval-export-json (chat-eval-run "export"))))
       (should (string-match-p "fixtureDigest" json))
       (should (string-match-p "redacted" json))
       (should (string-match-p "originalBytes" json))
       (should-not (string-match-p "abcdefghijklmnop" json))
       (should-not (string-match-p (make-string 100 ?x) json))))))

(ert-deftest chat-eval-comparison-requires-one-scenario-revision ()
  "Comparison reports changed checks and rejects revision mixing."
  (chat-eval-test-with-runtime
   (let ((chat-eval-auto-save nil)
         (value 1))
     (chat-eval-register
      (chat-eval-test--scenario
       "compare"
       (lambda (_fixture)
         (list (chat-eval-check "value" (= value 1) 1 value)))))
     (let ((left (chat-eval-run "compare")))
       (setq value 2)
       (let* ((right (chat-eval-run "compare"))
              (comparison (chat-eval-compare left right)))
         (should (eq t (alist-get 'statusChanged comparison)))
         (should (equal '("value")
                        (mapcar (lambda (entry) (alist-get 'name entry))
                                (alist-get 'changedChecks comparison))))
         (setf (chat-eval-result-scenario-revision right) 2)
         (should-error (chat-eval-compare left right)))))))

(ert-deftest chat-eval-built-in-scenarios-cover-the-five-runtime-contracts ()
  "The offline Agent suite is registered and passes without providers."
  (chat-eval-test-with-runtime
   (let ((chat-eval-auto-save nil))
     (chat-eval-register-built-ins)
     (should (equal
              '("compaction-resident-order"
                "editing-owned-file"
                "guard-permanent-floor"
                "provider-normalized-events"
                "recovery-external-drift")
              (mapcar #'chat-eval-scenario-id
                      (chat-eval-scenarios))))
     (let ((results (chat-eval-run-all)))
       (should (= 5 (length results)))
       (should (seq-every-p
                (lambda (result)
                  (eq 'passed (chat-eval-result-status result)))
                results))))))

(provide 'test-chat-eval)
;;; test-chat-eval.el ends here
