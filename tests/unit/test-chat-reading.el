(require 'ert)
(require 'test-helper)
(require 'chat-reading)

(ert-deftest chat-reading-capture-region-returns-structured-capture ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun demo ()\n  (message \"hi\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message")
             (set-mark (line-beginning-position))
             (goto-char (line-end-position))
             (activate-mark)
             (let ((capture (chat-reading-capture-region)))
               (should (eq (plist-get capture :kind) 'region))
               (should (string-match-p "demo.el" (plist-get capture :file)))
               (should (= (plist-get capture :start-line) 2))
               (should (= (plist-get capture :end-line) 2))
               (should (string-match-p "message" (plist-get capture :code)))
               (should (eq (plist-get capture :language) 'emacs-lisp))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-region-excludes-next-line-when-region-ends-at-line-start ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (forward-line 1)
             (set-mark (line-beginning-position))
             (forward-line 1)
             (activate-mark)
             (let ((capture (chat-reading-capture-region)))
               (should (= (plist-get capture :start-line) 2))
               (should (= (plist-get capture :end-line) 2))
               (should (string= (plist-get capture :code) "line2\n"))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-region-requires-active-region ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(message \"hi\")\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-reading-capture-region) :type 'user-error)
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-region-requires-file-buffer ()
  (with-temp-buffer
    (insert "hello")
    (set-mark (point-min))
    (goto-char (point-max))
    (activate-mark)
    (should-error (chat-reading-capture-region) :type 'user-error)))

(ert-deftest chat-reading-current-file-errors-without-file-buffer ()
  (with-temp-buffer
    (should-error (chat-reading--current-file) :type 'user-error)))

(ert-deftest chat-reading-capture-defun-returns-structured-capture ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n\n(defun beta ()\n  (message \"b\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward "message \"b\"")
             (let ((capture (chat-reading-capture-defun)))
               (should (eq (plist-get capture :kind) 'defun))
               (should (= (plist-get capture :start-line) 4))
               (should (= (plist-get capture :end-line) 5))
               (should (string-match-p "defun beta" (plist-get capture :code)))
               (should-not (string-match-p "defun alpha" (plist-get capture :code)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-defun-errors-without-defun ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "plain.txt" temp-dir)))
     (with-temp-file source-file
       (insert "just text\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-reading-capture-defun) :type 'user-error)
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-near-point-uses-radius ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\nline4\nline5\nline6\nline7\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (forward-line 3)
             (let ((capture (chat-reading-capture-near-point 1)))
               (should (eq (plist-get capture :kind) 'near-point))
               (should (= (plist-get capture :start-line) 3))
               (should (= (plist-get capture :end-line) 5))
               (should (string-match-p "line3" (plist-get capture :code)))
               (should (string-match-p "line5" (plist-get capture :code)))
               (should-not (string-match-p "line2\nline3\nline4\nline5\nline6" (plist-get capture :code)))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-near-point-clamps-to-buffer-edges ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (let ((capture (chat-reading-capture-near-point 5)))
               (should (= (plist-get capture :start-line) 1))
               (should (= (plist-get capture :end-line) 3))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-near-point-uses-default-radius ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir))
         (chat-reading-near-point-radius 2))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\nline4\nline5\nline6\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (forward-line 3)
             (let ((capture (chat-reading-capture-near-point)))
               (should (= (plist-get capture :start-line) 2))
               (should (= (plist-get capture :end-line) 6))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-current-file-returns-full-file ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "(defun alpha ()\n  (message \"a\"))\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (let ((capture (chat-reading-capture-current-file 10)))
             (should (eq (plist-get capture :kind) 'current-file))
             (should (= (plist-get capture :start-line) 1))
             (should (= (plist-get capture :end-line) 2))
             (should (string-match-p "defun alpha" (plist-get capture :code))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-current-file-rejects-oversized-files ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-reading-capture-current-file 2) :type 'user-error)
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-current-file-uses-default-limit ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir))
         (chat-reading-current-file-max-lines 2))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (should-error (chat-reading-capture-current-file) :type 'user-error)
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-format-question-includes-visible-metadata ()
  (let ((text (chat-reading-format-question
               '(:kind defun
                 :file "/tmp/demo.el"
                 :start-line 10
                 :end-line 12
                 :code "(message \"hi\")"
                 :language emacs-lisp)
               "Why?")))
    (should (string-match-p "Question about this code:" text))
    (should (string-match-p "File: /tmp/demo.el" text))
    (should (string-match-p "Lines: 10-12" text))
    (should (string-match-p "Kind: defun" text))
    (should (string-match-p "```emacs-lisp" text))
    (should (string-match-p "Question:\nWhy\\?" text))))

(ert-deftest chat-reading-format-question-adds-trailing-newline-before-fence-end ()
  (let ((text (chat-reading-format-question
               '(:kind region
                 :file "/tmp/demo.el"
                 :start-line 1
                 :end-line 1
                 :code "(message \"hi\")"
                 :language emacs-lisp)
               nil)))
    (should (string-match-p "(message \"hi\")\n```" text))
    (should (string-match-p "Question:\n\\'" text))))

(ert-deftest chat-reading-language-falls-back-to-major-mode ()
  (with-temp-buffer
    (text-mode)
    (should (eq (chat-reading--language "/tmp/demo.unknown") 'text-mode))))

(ert-deftest chat-reading-language-prefers-configured-filetype-map ()
  (let ((chat-reading-filetype-map '(("\\.foo\\'" . custom-lang))))
    (with-temp-buffer
      (text-mode)
      (should (eq (chat-reading--language "/tmp/demo.foo") 'custom-lang)))))

(ert-deftest chat-reading-capture-current-file-single-line-keeps-line-one ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "hello"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (let ((capture (chat-reading-capture-current-file 10)))
             (should (= (plist-get capture :start-line) 1))
             (should (= (plist-get capture :end-line) 1)))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-capture-near-point-zero-radius-captures-current-line ()
  (chat-test-with-temp-dir
   (let ((source-file (expand-file-name "demo.el" temp-dir)))
     (with-temp-file source-file
       (insert "line1\nline2\nline3\n"))
     (with-current-buffer (find-file-noselect source-file)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (forward-line 1)
             (let ((capture (chat-reading-capture-near-point 0)))
               (should (= (plist-get capture :start-line) 2))
               (should (= (plist-get capture :end-line) 2))
               (should (string= (plist-get capture :code) "line2"))))
         (kill-buffer (current-buffer)))))))

(ert-deftest chat-reading-format-question-keeps-empty-question-header-visible ()
  (let ((text (chat-reading-format-question
               '(:kind current-file
                 :file "/tmp/demo.el"
                 :start-line 1
                 :end-line 2
                 :code "line1\nline2\n"
                 :language text-mode)
               "")))
    (should (string-match-p "Kind: current-file" text))
    (should (string-match-p "Question:\n\\'" text))))

(ert-deftest chat-reading-format-question-renders-custom-language-fence ()
  (let ((text (chat-reading-format-question
               '(:kind region
                 :file "/tmp/demo.foo"
                 :start-line 3
                 :end-line 4
                 :code "alpha\nbeta"
                 :language custom-lang)
               "Explain it")))
    (should (string-match-p "```custom-lang" text))
    (should (string-match-p "Explain it\\'" text))))
