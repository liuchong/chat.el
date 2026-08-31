;;; test-chat-code-intelligence.el --- Unified code intelligence tests -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-code-intelligence)
(require 'chat-code-intel)
(require 'chat-code-lsp)

(ert-deftest chat-code-intel-detects-the-complete-evaluation-language-set ()
  "Source detection covers every core and extended qualification language."
  (dolist (case '(("sample.el" . emacs-lisp)
                  ("sample.py" . python)
                  ("sample.js" . javascript)
                  ("sample.go" . go)
                  ("sample.rs" . rust)
                  ("sample.zig" . zig)
                  ("sample.clj" . clojure)
                  ("Sample.java" . java)
                  ("sample.ts" . typescript)
                  ("sample.c" . c)
                  ("sample.cpp" . cpp)
                  ("sample.sql" . sql)))
    (should (eq (cdr case)
                (chat-code-intel-detect-language (car case))))))

(defun chat-test-code-intelligence--await (starter &optional timeout)
  "Run STARTER with a callback and wait up to TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 2.0)))
        result)
    (funcall starter (lambda (value) (setq result value)))
    (while (and (null result) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    result))

(defmacro chat-test-code-intelligence--with-backends (backends &rest body)
  "Run BODY with only BACKENDS registered."
  (declare (indent 1))
  `(let ((saved chat-code-intelligence--backends))
     (unwind-protect
         (progn
           (setq chat-code-intelligence--backends nil)
           (dolist (backend ,backends)
             (chat-code-intelligence-register-backend backend))
           ,@body)
       (setq chat-code-intelligence--backends saved))))

(defun chat-test-code-intelligence--backend (name priority status &optional items)
  "Return a fake NAME backend at PRIORITY yielding STATUS and ITEMS."
  (make-chat-code-intelligence-backend
   :name name :priority priority :operations '(definition)
   :available (lambda (_request _operation) t)
   :query (lambda (_request _operation callback)
            (funcall callback
                     (list :status status :revision "fixture" :items items)))))

(ert-deftest chat-code-intelligence-distinguishes-unavailable-empty-and-timeout ()
  "Typed terminal states must not collapse into one empty result."
  (chat-test-with-temp-dir
   (let ((request (list :project-root temp-dir)))
     (chat-test-code-intelligence--with-backends
         (list (chat-test-code-intelligence--backend 'none 10 'unavailable))
       (should
        (eq (plist-get
             (chat-test-code-intelligence--await
              (lambda (callback)
                (chat-code-intelligence-query-async
                 'definition request callback 0.1)))
             :status)
            'unavailable)))
     (chat-test-code-intelligence--with-backends
         (list (chat-test-code-intelligence--backend 'empty 10 'empty))
       (should
        (eq (plist-get
             (chat-test-code-intelligence--await
              (lambda (callback)
                (chat-code-intelligence-query-async
                 'definition request callback 0.1)))
             :status)
            'empty)))
     (chat-test-code-intelligence--with-backends
         (list
          (make-chat-code-intelligence-backend
           :name 'slow :priority 10 :operations '(definition)
           :available (lambda (_request _operation) t)
           :query (lambda (_request _operation _callback) nil)))
       (should
        (eq (plist-get
             (chat-test-code-intelligence--await
              (lambda (callback)
                (chat-code-intelligence-query-async
                 'definition request callback 0.02)))
             :status)
            'timeout))))))

(ert-deftest chat-code-intelligence-falls-back-and-sorts-deterministically ()
  "A lower backend may answer, with stable normalized ordering."
  (chat-test-with-temp-dir
   (let* ((a (expand-file-name "a.py" temp-dir))
          (b (expand-file-name "b.py" temp-dir))
          (outside (make-temp-file "chat-outside-"))
          (request (list :project-root temp-dir :symbol "target"))
          result)
     (unwind-protect
         (progn
           (with-temp-file a (insert "def target(): pass\n"))
           (with-temp-file b (insert "def target(): pass\n"))
           (chat-test-code-intelligence--with-backends
               (list
                (chat-test-code-intelligence--backend 'first 10 'empty)
                (chat-test-code-intelligence--backend
                 'second 20 'ok
                 (list (list :path b :line 5 :name "target" :confidence 0.8)
                       (list :path outside :line 1 :name "target" :confidence 1.0)
                       (list :path a :line 9 :name "target" :confidence 0.8))))
             (setq result
                   (chat-test-code-intelligence--await
                    (lambda (callback)
                      (chat-code-intelligence-query-async
                       'definition request callback 0.2)))))
           (should (eq (plist-get result :status) 'ok))
           (should (eq (plist-get result :backend) 'second))
           (should (equal (mapcar (lambda (item) (plist-get item :path))
                                  (plist-get result :items))
                          (list (file-truename a) (file-truename b))))
           (should (equal (mapcar (lambda (attempt) (plist-get attempt :status))
                                  (plist-get result :attempts))
                          '(empty ok))))
       (delete-file outside)))))

(ert-deftest chat-code-intelligence-index-fixture-meets-definition-and-reference-targets ()
  "The five-language fallback fixture exceeds M11 accuracy thresholds."
  (chat-test-with-temp-dir
   (let* ((files
           `(("a.py" . "def alpha():\n    return 1\ndef caller():\n    return alpha()\n")
             ("b.ts" . "function beta() { return 1; }\nexport const caller = beta;\n")
             ("c.el" . "(defun gamma () 1)\n(defun caller () (gamma))\n")
             ("d.go" . "package sample\nfunc Delta() int { return 1 }\nfunc Caller() int { return Delta() }\n")
             ("e.rs" . "fn epsilon() -> i32 { 1 }\nfn caller() -> i32 { epsilon() }\n")))
          (names '("alpha" "beta" "gamma" "Delta" "epsilon"))
          (chat-code-intel--active-indexes (make-hash-table :test 'equal))
          index
          (definition-hits 0)
          (reference-true 0)
          (reference-returned 0))
     (dolist (fixture files)
       (with-temp-file (expand-file-name (car fixture) temp-dir)
         (insert (cdr fixture))))
     (chat-test-silently
      (setq index (chat-code-intel-index-project temp-dir)))
     (dolist (name names)
       (when (= (length (chat-code-intel-find-definition index name)) 1)
         (cl-incf definition-hits))
       (let ((references (chat-code-intel-find-references index name)))
         (cl-incf reference-returned (length references))
         (cl-incf reference-true
                  (cl-count-if
                   (lambda (reference)
                     (> (chat-code-reference-line reference) 1))
                   references))))
     (should (>= (/ (float definition-hits) (length names)) 0.98))
     (should (> reference-returned 0))
     (should (>= (/ (float reference-true) reference-returned) 0.95))
     (should (>= (/ (float reference-true) (length names)) 0.90)))))

(ert-deftest chat-code-intelligence-five-language-adversarial-corpus-is-searchable ()
  "Fallback indexing handles the complete M11 adversarial corpus shape."
  (chat-test-with-temp-dir
   (let* ((fixtures
           `(("python/实现.py" .
              "class Contract_py:\n    pass\nclass Impl_py(Contract_py):\n    pass\ndef duplicate_py(): return 1\ndef outer_py():\n    def nested_py(): return duplicate_py()\n    return nested_py()\n@@ invalid\n")
             ("python/use.py" .
              "def duplicate_py(): return 2\ndef caller_py(): return duplicate_py()\n")
             ("typescript/实现.ts" .
              "interface Contract_ts {}\nclass Impl_ts implements Contract_ts {}\nfunction duplicate_ts() { return 1; }\nfunction outer_ts() { function nested_ts() { return duplicate_ts(); } return nested_ts(); }\n@@ invalid\n")
             ("typescript/use.ts" .
              "function duplicate_ts() { return 2; }\nconst caller_ts = duplicate_ts;\n")
             ("elisp/实现.el" .
              "(cl-defgeneric contract_el (value))\n(cl-defmethod contract_el ((value integer)) value)\n(defun duplicate_el () 1)\n(defun outer_el () (defun nested_el () (duplicate_el)) (nested_el))\n@@ invalid\n")
             ("elisp/use.el" .
              "(defun duplicate_el () 2)\n(defun caller_el () (duplicate_el))\n")
             ("go/实现.go" .
              "package fixture\ntype Contract_go interface { Run() int }\ntype Impl_go struct {}\nfunc duplicate_go() int { return 1 }\nfunc outer_go() int {\n  func nested_go() int { return duplicate_go() }\n  return nested_go()\n}\n@@ invalid\n")
             ("go/use.go" .
              "package fixture\nfunc duplicate_go() int { return 2 }\nfunc caller_go() int { return duplicate_go() }\n")
             ("rust/实现.rs" .
              "trait Contract_rs { fn run(&self) -> i32; }\nstruct Impl_rs;\nimpl Contract_rs for Impl_rs { fn run(&self) -> i32 { 1 } }\nfn duplicate_rs() -> i32 { 1 }\nfn outer_rs() -> i32 {\n  fn nested_rs() -> i32 { duplicate_rs() }\n  nested_rs()\n}\n@@ invalid\n")
             ("rust/use.rs" .
              "fn duplicate_rs() -> i32 { 2 }\nfn caller_rs() -> i32 { duplicate_rs() }\n")))
          (expectations
           '(("duplicate_py" "nested_py" "Contract_py" "Impl_py")
             ("duplicate_ts" "nested_ts" "Contract_ts" "Impl_ts")
             ("duplicate_el" "nested_el" "contract_el" "contract_el")
             ("duplicate_go" "nested_go" "Contract_go" "Impl_go")
             ("duplicate_rs" "nested_rs" "Contract_rs" "Impl_rs")))
          (chat-code-intel--active-indexes (make-hash-table :test 'equal))
          index)
     (dolist (fixture fixtures)
       (let ((path (expand-file-name (car fixture) temp-dir)))
         (make-directory (file-name-directory path) t)
         (with-temp-file path (insert (cdr fixture)))))
     (chat-test-silently
      (setq index (chat-code-intel-index-project temp-dir)))
     (dolist (expected expectations)
       (let ((duplicate (nth 0 expected))
             (nested (nth 1 expected))
             (interface (nth 2 expected))
             (implementation (nth 3 expected)))
         (should (= (length (chat-code-intel-find-definition index duplicate)) 2))
         (should (chat-code-intel-find-definition index nested))
         (should (chat-code-intel-find-definition index interface))
         (should (chat-code-intel-find-definition index implementation))
         (should (>= (length (chat-code-intel-find-references index duplicate)) 2)))))))

(ert-deftest chat-code-lsp-adapter-does-not-reference-client-internals ()
  "The semantic adapter remains independent of client private APIs."
  (let ((source (locate-library "chat-code-lsp")))
    (with-temp-buffer
      (insert-file-contents source)
      (should-not
       (re-search-forward "[(['[:space:]]\\(?:eglot\\|lsp\\)--" nil t)))))

(ert-deftest chat-code-context-projects-source-revision-and-truncation-diagnostics ()
  "Code context evidence is attached to the existing request trace."
  (chat-test-with-temp-dir
   (let* ((chat-repo-map--cache (make-hash-table :test 'equal))
          (source (expand-file-name "main.py" temp-dir))
          (session (chat-code-session-create "Diagnostics" temp-dir source))
          (request-id (chat-request-diagnostics-create 'agent 'fixture "model"))
          trace event refreshed)
     (with-temp-file source (insert "def main(): return 1\n"))
     (chat-repo-map-refresh-async temp-dir (lambda (result) (setq refreshed result)))
     (while (null refreshed) (accept-process-output nil 0.005))
     (with-temp-buffer
       (setq-local chat-ui--current-request-id request-id)
       (should (chat-ui--code-context session)))
     (setq trace (chat-request-diagnostics-get request-id)
           event (seq-find
                  (lambda (candidate)
                    (eq (plist-get candidate :type) 'code-context-built))
                  (chat-request-trace-events trace)))
     (should event)
     (should (seq-some
              (lambda (diagnostic)
                (and (plist-get diagnostic :source)
                     (plist-member diagnostic :revision)
                     (plist-member diagnostic :status)))
              (plist-get event :diagnostics)))
     (should (seq-some
              (lambda (diagnostic)
                (and (eq (plist-get diagnostic :source) 'repo-map)
                     (assq 'truncation-reason
                           (plist-get diagnostic :details))))
              (plist-get event :diagnostics)))
     (chat-request-diagnostics-clear request-id))))

(ert-deftest chat-code-context-does-not-activate-for-ordinary-chat-session ()
  "The coding context path leaves ordinary sessions unchanged."
  (chat-test-with-temp-dir
   (let ((chat-repo-map--cache (make-hash-table :test 'equal))
         (session (chat-session-create "Plain" 'fixture)))
     (should-not (chat-ui--code-capability-prompt session))
     (should (= (hash-table-count chat-repo-map--cache) 0)))))

(provide 'test-chat-code-intelligence)
;;; test-chat-code-intelligence.el ends here
