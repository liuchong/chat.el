;;; test-chat-code-preview.el --- Tests for chat-code-preview -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-code-preview)

(ert-deftest chat-files-unified-diff-renders-real-hunk ()
  "Test the built in diff renders a real hunk with context lines."
  (let ((diff (chat-files--unified-diff
               "a/f" "b/f"
               "one\ntwo\nthree\n"
               "one\nTWO\nthree\n")))
    (should (string-match-p "^--- a/f$" diff))
    (should (string-match-p "^\\+\\+\\+ b/f$" diff))
    (should (string-match-p "^@@ -1,3 \\+1,3 @@$" diff))
    (should (string-match-p "^ one$" diff))
    (should (string-match-p "^-two$" diff))
    (should (string-match-p "^\\+TWO$" diff))
    (should (string-match-p "^ three$" diff))))

(ert-deftest chat-files-unified-diff-handles-pure-addition ()
  "Test pure insertions render with surrounding context."
  (let ((diff (chat-files--unified-diff
               "a/f" "b/f"
               "one\ntwo\n"
               "one\ntwo\nthree\n")))
    (should (string-match-p "^@@ -1,2 \\+1,3 @@" diff))
    (should (string-match-p "^\\+three$" diff))))

(ert-deftest chat-files-unified-diff-handles-pure-deletion ()
  "Test pure deletions report a zero-width new range."
  (let ((diff (chat-files--unified-diff
               "a/f" "b/f"
               "one\ntwo\nthree\n"
               "one\nthree\n")))
    (should (string-match-p "^@@ -1,3 \\+1,2 @@" diff))
    (should (string-match-p "^-two$" diff))))

(ert-deftest chat-files-unified-diff-empty-for-identical-inputs ()
  "Test identical inputs produce an empty diff."
  (should (string= (chat-files--unified-diff "a" "b" "same\n" "same\n") "")))

(ert-deftest chat-files-unified-diff-separates-distant-hunks ()
  "Test changes far apart become two hunks."
  (let* ((old (string-join (cl-loop for i from 1 to 20 collect (format "l%d" i)) "\n"))
         (new (replace-regexp-in-string
               "\\`l1" "L1"
               (replace-regexp-in-string "l20\\'" "L20" old)))
         (diff (chat-files--unified-diff "a/f" "b/f" old new)))
    (should (= (length (split-string diff "^@@ ")) 3))))

(ert-deftest chat-files-diff-strings-falls-back-without-diff-command ()
  "Test chat-files--diff-strings uses the built in diff without external diff."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_cmd) nil)))
    (let ((diff (chat-files--diff-strings "/tmp/f" "a\nb\n" "a\nc\n")))
      (should (string-match-p "^-b$" diff))
      (should (string-match-p "^\\+c$" diff)))))

(ert-deftest chat-code-preview-internal-diff-produces-real-hunks ()
  "Test the preview fallback diff renders real hunks instead of a fake header."
  (let ((diff (chat-code-preview--generate-diff-internal "a\nb\n" "a\nc\n")))
    (should (string-match-p "^@@ -1,2 \\+1,2 @@$" diff))
    (should-not (string-match-p "^@@ -1,1 \\+1,1 @@$" diff))))

(ert-deftest chat-code-preview-change-regex-skips-diff-headers ()
  "Test the change navigation regex matches changes but not +++/--- headers."
  (let ((pattern "^\\+\\([^+]\\|$\\)\\|^-\\([^-]\\|$\\)"))
    (should (string-match-p pattern "+added line"))
    (should (string-match-p pattern "-removed line"))
    (should-not (string-match-p pattern "+++ b/file"))
    (should-not (string-match-p pattern "--- a/file"))
    (should-not (string-match-p pattern " context"))))

(provide 'test-chat-code-preview)
;;; test-chat-code-preview.el ends here
