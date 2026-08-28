;;; sample-test.el --- Evaluation fixture tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'sample)

(ert-deftest sample-test-divide ()
  (should (= 2.5 (sample-divide 5.0 2.0)))
  (should-error (sample-divide 1 0)))

(ert-deftest sample-test-label ()
  (should (equal "entry:alpha" (sample-label "alpha"))))

(ert-deftest sample-test-normalize ()
  (should (equal "alpha beta" (sample-normalize-name "  Alpha   BETA "))))

(ert-deftest sample-test-active ()
  (should (sample-active-p 'active))
  (should-not (sample-active-p 'paused)))

;;; sample-test.el ends here
