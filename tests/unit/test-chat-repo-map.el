;;; test-chat-repo-map.el --- Incremental repo map tests -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-repo-map)

(defun chat-test-repo-map--refresh (root &optional timeout)
  "Refresh ROOT and wait up to TIMEOUT seconds for the result."
  (let ((deadline (+ (float-time) (or timeout 5.0)))
        result)
    (chat-repo-map-refresh-async root (lambda (value) (setq result value)))
    (while (and (null result) (< (float-time) deadline))
      (accept-process-output nil 0.005))
    result))

(ert-deftest chat-repo-map-refreshes-only-changed-files-and-keeps-cjk-paths ()
  "Refreshes reuse unchanged entries and retain canonical CJK paths."
  (chat-test-with-temp-dir
   (let* ((chat-repo-map--cache (make-hash-table :test 'equal))
          (chat-repo-map-max-file-size 100)
          (source (expand-file-name "src/核心.py" temp-dir))
          (test-file (expand-file-name "tests/核心_test.py" temp-dir))
          (large (expand-file-name "src/large.py" temp-dir))
          first second third map old-entry)
     (make-directory (file-name-directory source) t)
     (make-directory (file-name-directory test-file) t)
     (with-temp-file source (insert "def target():\n    return 1\n"))
     (with-temp-file test-file (insert "from src import target\ndef check(): return target()\n"))
     (with-temp-file large (insert (make-string 200 ?x)))
     (setq first (chat-test-repo-map--refresh temp-dir))
     (should (eq (plist-get first :status) 'ok))
     (setq map (chat-repo-map-get temp-dir)
           old-entry (gethash (file-truename source) (chat-repo-map-entries map)))
     (should old-entry)
     (should (eq (chat-repo-map-entry-skipped-reason
                  (gethash (file-truename large) (chat-repo-map-entries map)))
                 'large-file))
     (setq second (chat-test-repo-map--refresh temp-dir))
     (should (= (plist-get second :changed) 0))
     (should (= (plist-get second :edges-rebuilt) 0))
     (should (eq old-entry
                 (gethash (file-truename source) (chat-repo-map-entries map))))
     (with-temp-file source (insert "def target():\n    return 2\n"))
     (setq third (chat-test-repo-map--refresh temp-dir))
     (should (= (plist-get third :changed) 1))
     (should (< (plist-get third :edges-rebuilt)
                (plist-get third :files)))
     (should-not (eq old-entry
                     (gethash (file-truename source)
                              (chat-repo-map-entries map)))))))

(ert-deftest chat-repo-map-query-is-ranked-deduplicated-and-budgeted ()
  "Warm queries use explicit relations and deterministic token budgets."
  (chat-test-with-temp-dir
   (let* ((chat-repo-map--cache (make-hash-table :test 'equal))
          (source (expand-file-name "src/payment.py" temp-dir))
          (test-file (expand-file-name "tests/payment_test.py" temp-dir))
          (other (expand-file-name "src/unrelated.py" temp-dir))
          request first second)
     (make-directory (file-name-directory source) t)
     (make-directory (file-name-directory test-file) t)
     (with-temp-file source (insert "def charge():\n    return True\n"))
     (with-temp-file test-file (insert "from payment import charge\ndef check(): return charge()\n"))
     (with-temp-file other (insert "def unrelated():\n    return False\n"))
     (should (chat-test-repo-map--refresh temp-dir))
     (setq request (list :focus-file source :query "charge payment"
                         :token-budget 1000 :limit 5)
           first (chat-repo-map-query temp-dir request)
           second (chat-repo-map-query temp-dir request))
     (should (eq (plist-get first :status) 'ok))
     (should (equal first second))
     (should (string= (plist-get (car (plist-get first :items)) :path)
                      (file-truename source)))
     (should (member (file-truename test-file)
                     (mapcar (lambda (item) (plist-get item :path))
                             (plist-get first :items))))
     (should (= (length (delete-dups
                         (mapcar (lambda (item) (plist-get item :path))
                                 (plist-get first :items))))
                (length (plist-get first :items)))))))

(ert-deftest chat-repo-map-fixed-queries-exceed-top-five-hit-target ()
  "Fixed related-file queries achieve at least 90 percent Top-5 hits."
  (chat-test-with-temp-dir
   (let ((chat-repo-map--cache (make-hash-table :test 'equal))
         (hits 0))
     (make-directory (expand-file-name "src" temp-dir) t)
     (make-directory (expand-file-name "tests" temp-dir) t)
     (dotimes (index 10)
       (with-temp-file (expand-file-name (format "src/domain_%02d.py" index) temp-dir)
         (insert (format "def operation_%02d(): return %d\n" index index)))
       (with-temp-file (expand-file-name (format "tests/domain_%02d_test.py" index) temp-dir)
         (insert (format "from domain_%02d import operation_%02d\n" index index))))
     (should (chat-test-repo-map--refresh temp-dir))
     (dotimes (index 10)
       (let* ((expected (file-truename
                         (expand-file-name (format "src/domain_%02d.py" index) temp-dir)))
              (result (chat-repo-map-query
                       temp-dir
                       (list :query (format "operation_%02d" index)
                             :focus-file
                             (expand-file-name
                              (format "tests/domain_%02d_test.py" index) temp-dir)
                             :token-budget 2000 :limit 5))))
         (when (member expected
                       (mapcar (lambda (item) (plist-get item :path))
                               (plist-get result :items)))
           (cl-incf hits))))
     (should (>= (/ (float hits) 10) 0.90)))))

(ert-deftest chat-repo-map-ten-thousand-file-slices-and-warm-query-meet-budget ()
  "A 10k fixture yields frequently and serves warm queries within M11 limits."
  (chat-test-with-temp-dir
   (let ((chat-repo-map--cache (make-hash-table :test 'equal))
         (chat-repo-map-slice-milliseconds 10)
         result timings)
     (dotimes (directory 100)
       (let ((path (expand-file-name (format "src/%03d" directory) temp-dir)))
         (make-directory path t)
         (dotimes (file 100)
           (with-temp-file (expand-file-name (format "f%03d.py" file) path)
             (insert (format "def symbol_%03d_%03d(): return 1\n" directory file))))))
     (setq result (chat-test-repo-map--refresh temp-dir 30.0))
     (should result)
     (should (= (plist-get result :files) 10000))
     (should (<= (plist-get result :max-slice-ms) 50.0))
     (dotimes (_ 20)
       (let ((started (float-time)))
         (chat-repo-map-query
          temp-dir (list :query "symbol_099_099" :token-budget 2000 :limit 5))
         (push (* 1000.0 (- (float-time) started)) timings)))
     (setq timings (sort timings #'<))
     (should (<= (nth 18 timings) 200.0)))))

(provide 'test-chat-repo-map)
;;; test-chat-repo-map.el ends here
