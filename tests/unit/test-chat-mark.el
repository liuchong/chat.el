;;; test-chat-mark.el --- Tests for mode and provider marks -*- lexical-binding: t -*-

;;; Commentary:

;; A mark is worth having only if it is read faster than the word it
;; replaces.  These tests hold the properties that make that true: one
;; column wide whatever the font, recolourable by face rather than by the
;; font, and never drawn at all when the frame cannot show it.

;;; Code:

(require 'ert)
(require 'chat-mark)

;; ------------------------------------------------------------------
;; What the glyphs have to be
;; ------------------------------------------------------------------

(defun test-chat-mark--every-glyph ()
  "Return every glyph the tables can produce."
  (append (mapcar (lambda (entry) (car (cdr entry))) chat-mark-mode-marks)
          (mapcar #'cdr chat-mark-provider-marks)
          (list chat-mark-assistant-glyph)))

(ert-deftest chat-mark-every-glyph-is-one-column-wide ()
  "The reason for refusing emoji, stated as the property it buys.

A double-width glyph puts the prompt half a column out of step with every
other line in a monospaced buffer, and no amount of care elsewhere gets
that back."
  (dolist (glyph (test-chat-mark--every-glyph))
    (should (= 1 (string-width glyph)))))

(ert-deftest chat-mark-every-glyph-is-in-the-basic-plane ()
  "Emoji live above it, and so does everything that needs a colour font."
  (dolist (glyph (test-chat-mark--every-glyph))
    (should (= 1 (length glyph)))
    (should (< (aref glyph 0) #x10000))))

(ert-deftest chat-mark-an-undisplayable-glyph-is-refused ()
  "The frame decides, and a hollow box is not an answer."
  (should (chat-mark-displayable-p "K"))
  (should-not (chat-mark-displayable-p nil))
  (should-not (chat-mark-displayable-p ""))
  (cl-letf (((symbol-function 'char-displayable-p) (lambda (_c) nil)))
    (should-not (chat-mark-displayable-p "\u2726"))))

;; ------------------------------------------------------------------
;; Mode marks
;; ------------------------------------------------------------------

(ert-deftest chat-mark-the-modes-that-can-hold-input-have-marks ()
  "Shell and queue can hold plain input, so both are named."
  (should (equal '("\u276F" . chat-mark-shell) (chat-mark-for-mode "cmd")))
  (should (equal '("\u2261" . chat-mark-queue) (chat-mark-for-mode "queue"))))

(ert-deftest chat-mark-an-unmarked-mode-says-so-rather-than-guessing ()
  "A command with no mark gets the prompt as it was before marks existed."
  (should-not (chat-mark-for-mode "queue-that-does-not-exist"))
  ;; The assistant is deliberately absent: its provider's mark stands there.
  (should-not (chat-mark-for-mode "send")))

;; ------------------------------------------------------------------
;; Provider marks
;; ------------------------------------------------------------------

(ert-deftest chat-mark-a-provider-whose-logo-has-a-character-uses-it ()
  "Four providers, four characters that genuinely resemble the mark."
  (should (equal "\u2733" (car (chat-mark-for-provider 'claude "Claude"))))
  (should (equal "\u274B" (car (chat-mark-for-provider 'openai "OpenAI"))))
  (should (equal "\u2715" (car (chat-mark-for-provider 'grok "Grok"))))
  (should (equal "\u2727" (car (chat-mark-for-provider 'gemini "Gemini")))))

(ert-deftest chat-mark-any-other-provider-uses-its-initial ()
  "An initial is honest; a symbol invented to fill the row is not."
  (should (equal "K" (car (chat-mark-for-provider 'kimi "Kimi"))))
  (should (equal "D" (car (chat-mark-for-provider 'deepseek "DeepSeek"))))
  (should (equal "M" (car (chat-mark-for-provider 'minimax "MiniMax")))))

(ert-deftest chat-mark-a-provider-with-no-name-falls-back-to-the-star ()
  "Nothing to read means nothing to abbreviate."
  (should (equal chat-mark-assistant-glyph
                 (car (chat-mark-for-provider nil nil))))
  (should (equal chat-mark-assistant-glyph
                 (car (chat-mark-for-provider 'unregistered "  ")))))

(ert-deftest chat-mark-the-generic-star-carries-the-platform-accent ()
  "It is our mark, not anyone's brand, so it is coloured like ours."
  (should (eq 'chat-mark-assistant (cdr (chat-mark-for-provider nil nil))))
  ;; And a provider we simply have no colour for inherits instead.
  (should-not (cdr (chat-mark-for-provider 'qwen "Qwen"))))

(ert-deftest chat-mark-a-known-brand-colour-is-given-for-both-backgrounds ()
  "A brand colour unreadable on a dark theme is worse than no colour."
  (dolist (face '(chat-mark-brand-kimi
                  chat-mark-brand-claude
                  chat-mark-brand-deepseek))
    (let ((spec (get face 'face-defface-spec)))
      (should spec)
      (dolist (background '(light dark))
        (let ((entry (seq-find (lambda (entry)
                                 (equal (car entry)
                                        `((background ,background))))
                               spec)))
          (should entry)
          (should (plist-get (cdr entry) :foreground)))))))

(ert-deftest chat-mark-a-brand-colour-is-never-borrowed ()
  "A trademark colour used for our own interface would be claiming it.

Static, because the mistake is a reference somewhere else in the tree and
no runtime test would visit it."
  (let ((offenders nil))
    (dolist (file (directory-files-recursively
                   (expand-file-name "lisp" chat-test-root-dir)
                   "\\.el\\'"))
      (unless (equal (file-name-nondirectory file) "chat-mark.el")
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (re-search-forward "chat-mark-brand-" nil t)
            (push (file-name-nondirectory file) offenders)))))
    (should-not offenders)))

;;; test-chat-mark.el ends here
