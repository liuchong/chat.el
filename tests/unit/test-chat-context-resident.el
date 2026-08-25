;;; test-chat-context-resident.el --- Tests for declared resident context -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the resident-context declaration: the three marker
;; forms, the heading-name fallback, graceful degradation for tools that
;; ignore the marker, and the cap that keeps a declaration from filling
;; the window.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-context-resident)

(defun test-resident--resident (text)
  "Return the resident span of TEXT."
  (plist-get (chat-context-resident-partition text) :resident))

(defun test-resident--compactable (text)
  "Return the compactable span of TEXT."
  (plist-get (chat-context-resident-partition text) :compactable))

;; ------------------------------------------------------------------
;; Block form
;; ------------------------------------------------------------------

(ert-deftest chat-context-resident-keeps-a-fenced-block ()
  "A fenced block is resident and the surrounding prose is not."
  (let ((text (string-join
               '("Intro paragraph."
                 "<!-- chat:resident -->"
                 "- RULE-01 never thin out rules"
                 "<!-- chat:end -->"
                 "Closing paragraph.")
               "\n")))
    (should (equal (test-resident--resident text)
                   "- RULE-01 never thin out rules"))
    (should (string-match-p "Intro paragraph" (test-resident--compactable text)))
    (should (string-match-p "Closing paragraph"
                            (test-resident--compactable text)))))

(ert-deftest chat-context-resident-drops-the-markers-themselves ()
  "The marker lines never reach the model."
  (let* ((text "<!-- chat:resident -->\nrule\n<!-- chat:end -->")
         (partition (chat-context-resident-partition text)))
    (should-not (string-match-p "chat:resident"
                                (or (plist-get partition :resident) "")))
    (should-not (string-match-p "chat:end"
                                (or (plist-get partition :resident) "")))))

(ert-deftest chat-context-resident-block-runs-to-the-end-when-unclosed ()
  "An unclosed block still protects what follows it.

Failing open would silently drop the guarantee the author asked for,
which is the failure this whole mechanism exists to prevent."
  (let ((text "<!-- chat:resident -->\nrule one\nrule two"))
    (should (equal (test-resident--resident text) "rule one\nrule two"))
    (should-not (test-resident--compactable text))))

;; ------------------------------------------------------------------
;; Section form
;; ------------------------------------------------------------------

(ert-deftest chat-context-resident-marks-a-whole-section ()
  "A marked heading protects its section without a closing marker."
  (let ((text (string-join
               '("## Rules <!-- chat:resident -->"
                 "- one"
                 "- two"
                 "## Notes"
                 "chatter")
               "\n")))
    (let ((resident (test-resident--resident text)))
      (should (string-match-p "## Rules" resident))
      (should (string-match-p "- one" resident))
      (should (string-match-p "- two" resident))
      (should-not (string-match-p "chatter" resident)))
    (should (string-match-p "chatter" (test-resident--compactable text)))))

(ert-deftest chat-context-resident-section-survives-a-deeper-heading ()
  "A subsection of a resident section is resident too."
  (let ((text (string-join
               '("## Rules <!-- chat:resident -->"
                 "- one"
                 "### Detail"
                 "- two"
                 "## Notes"
                 "chatter")
               "\n")))
    (let ((resident (test-resident--resident text)))
      (should (string-match-p "### Detail" resident))
      (should (string-match-p "- two" resident)))
    (should-not (string-match-p "chatter" (test-resident--resident text)))))

(ert-deftest chat-context-resident-section-ends-at-a-higher-heading ()
  "A heading above the marked level closes the section."
  (let ((text (string-join
               '("### Rules <!-- chat:resident -->"
                 "- one"
                 "## Later"
                 "chatter")
               "\n")))
    (should-not (string-match-p "chatter" (test-resident--resident text)))
    (should (string-match-p "chatter" (test-resident--compactable text)))))

(ert-deftest chat-context-resident-recognizes-a-configured-heading ()
  "A named heading is resident with no marker at all.

Files shared with other tools can then declare residency without being
annotated for this one."
  (let ((text (string-join
               '("## Resident Rules"
                 "- one"
                 "## Other"
                 "chatter")
               "\n")))
    (should (string-match-p "- one" (test-resident--resident text)))
    (should-not (string-match-p "chatter" (test-resident--resident text)))))

(ert-deftest chat-context-resident-heading-match-ignores-case ()
  "The heading name match is not case sensitive."
  (should (test-resident--resident "## RESIDENT RULES\n- one")))

;; ------------------------------------------------------------------
;; Line form
;; ------------------------------------------------------------------

(ert-deftest chat-context-resident-marks-a-single-line ()
  "A trailing marker protects only its own line."
  (let ((text (string-join
               '("- ordinary guidance"
                 "- RULE-02 never thin out rules <!-- chat:resident -->"
                 "- more guidance")
               "\n")))
    (should (equal (test-resident--resident text)
                   "- RULE-02 never thin out rules"))
    (should (string-match-p "ordinary guidance"
                            (test-resident--compactable text)))
    (should (string-match-p "more guidance"
                            (test-resident--compactable text)))))

;; ------------------------------------------------------------------
;; Degradation
;; ------------------------------------------------------------------

(ert-deftest chat-context-resident-unmarked-text-declares-nothing ()
  "A file with no markers keeps its current behaviour.

The scheme has to be additive: an existing instructions file must not
change meaning because this module was added."
  (let ((text "## Rules\n- one\n- two"))
    (should-not (chat-context-resident-declared-p text))
    (should-not (test-resident--resident text))
    (should (string-match-p "- one" (test-resident--compactable text)))))

(ert-deftest chat-context-resident-ignores-a-foreign-comment ()
  "An HTML comment that is not this marker is ordinary text."
  (let ((text "<!-- other:tool -->\n- one"))
    (should-not (chat-context-resident-declared-p text))))

(ert-deftest chat-context-resident-partition-tolerates-empty-input ()
  "Nil and empty text produce nothing rather than failing."
  (dolist (input (list nil "" "\n\n"))
    (let ((partition (chat-context-resident-partition input)))
      (should-not (plist-get partition :resident))
      (should-not (plist-get partition :compactable)))))

;; ------------------------------------------------------------------
;; The cap
;; ------------------------------------------------------------------

(ert-deftest chat-context-resident-cap-keeps-what-fits ()
  "A declaration inside the cap is honoured whole."
  (let ((result (chat-context-resident-apply-cap "short rule" 1000)))
    (should (equal (plist-get result :resident) "short rule"))
    (should-not (plist-get result :demoted))
    (should (equal (plist-get result :overflow) 0))))

(ert-deftest chat-context-resident-cap-demotes-the-excess ()
  "Past the cap the excess becomes compactable instead of resident.

An unbounded declaration would otherwise fill the window and leave the
session unable to do anything but recite its instructions."
  (let* ((block (make-string 400 ?x))
         (text (string-join (list block block block) "\n\n"))
         (result (chat-context-resident-apply-cap text 150)))
    (should (plist-get result :resident))
    (should (plist-get result :demoted))
    (should (> (plist-get result :overflow) 0))
    (should (< (length (plist-get result :resident)) (length text)))
    ;; The reported overflow must describe the text that was actually
    ;; demoted.  Asserting only that it is positive hid a stale count.
    (should (equal (plist-get result :overflow)
                   (chat-context-count-tokens
                    (plist-get result :demoted))))))

(ert-deftest chat-context-resident-cap-overflow-counts-every-demoted-block ()
  "Overflow covers the whole demoted span, not just part of it.

A count taken from a partly consumed list under-reports the problem, so
a file far over the cap would look almost within it."
  (let* ((block (make-string 800 ?y))
         (text (string-join (make-list 12 block) "\n\n"))
         (result (chat-context-resident-apply-cap text 250))
         (total (chat-context-count-tokens text)))
    (should (> (plist-get result :overflow) (/ total 2)))
    (should (equal (plist-get result :overflow)
                   (chat-context-count-tokens
                    (plist-get result :demoted))))))

(ert-deftest chat-context-resident-cap-keeps-document-order ()
  "The blocks that survive are the ones written first.

Document order makes the ordering of an instructions file the ordering
of its guarantees, which is a rule an author can act on."
  (let* ((text (string-join
                (list (concat "first " (make-string 300 ?a))
                      (concat "second " (make-string 300 ?b)))
                "\n\n"))
         (result (chat-context-resident-apply-cap text 90)))
    (should (string-match-p "first" (plist-get result :resident)))
    (should-not (string-match-p "second" (plist-get result :resident)))
    (should (string-match-p "second" (plist-get result :demoted)))))

(ert-deftest chat-context-resident-cap-demotes-everything-after-a-miss ()
  "A later small block does not sneak in after a large one was demoted.

Keeping a tail after dropping a middle would leave the guarantee looking
satisfied while a rule in the middle is gone."
  (let* ((text (string-join
                (list (concat "big " (make-string 800 ?a))
                      "tiny")
                "\n\n"))
         (result (chat-context-resident-apply-cap text 50)))
    (should-not (string-match-p "tiny" (or (plist-get result :resident) "")))
    (should (string-match-p "tiny" (plist-get result :demoted)))))

(ert-deftest chat-context-resident-cap-warning-names-the-remedy ()
  "The overflow warning tells the author what to change."
  (let ((warning (chat-context-resident-overflow-warning 500 1000)))
    (should (string-match-p "500" warning))
    (should (string-match-p "document order" warning))
    (should (string-match-p "chat-context-protected-max-ratio" warning)))
  (should-not (chat-context-resident-overflow-warning 0 1000)))

(provide 'test-chat-context-resident)
;;; test-chat-context-resident.el ends here
