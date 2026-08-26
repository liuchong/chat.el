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

;; ------------------------------------------------------------------
;; Drawn marks
;; ------------------------------------------------------------------

(ert-deftest chat-mark-a-badge-is-sized-as-asked-and-scales-its-shape ()
  "The pixel size is on the element and the geometry is in the viewBox.

Authoring the shape in fixed units and scaling it once is what keeps a
badge the same badge at every font height.  Recomputing the corner radius
and the font size against the height instead would make each frame's
badge a slightly different drawing."
  (let ((svg (chat-mark-badge-svg "D" "#4D6BFE" 19)))
    (should (string-match-p "width=\"19\"" svg))
    (should (string-match-p "height=\"19\"" svg))
    (should (string-match-p "viewBox=\"0 0 32 32\"" svg))
    (should (string-match-p "fill=\"#4D6BFE\"" svg))
    (should (string-match-p ">D</text>" svg))))

(ert-deftest chat-mark-badge-text-is-legible-on-what-it-sits-on ()
  "White on a pale fill is an invisible letter, which is worse than a letter."
  (should (string-match-p "fill=\"#FFFFFF\""
                          (chat-mark-badge-svg "D" "#4D6BFE" 19)))
  (should (string-match-p "fill=\"#1A1A1A\""
                          (chat-mark-badge-svg "D" "#F5E663" 19))))

(ert-deftest chat-mark-a-badge-cannot-be-broken-by-its-glyph ()
  "The glyph reaches the badge from a provider's display name.

Nothing in that path is guaranteed to be XML, so a name beginning with an
ampersand would otherwise produce a document librsvg refuses, and the
mark would vanish rather than fall back."
  (let ((svg (chat-mark-badge-svg "&" "#4D6BFE" 19)))
    (should (string-match-p ">&amp;</text>" svg))
    (should-not (string-match-p ">&</text>" svg))))

(ert-deftest chat-mark-nothing-is-drawn-where-it-cannot-be ()
  "Every refusal is nil, because nil is the glyph and the glyph is fine.

Batch has no graphical frame, so this is the state the test suite runs
in, and also the state a terminal Emacs runs in permanently."
  (should-not (chat-mark-provider-image 'deepseek "D" 'chat-mark-brand-deepseek))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (let ((chat-mark-logo-enabled nil))
      (should-not
       (chat-mark-provider-image 'deepseek "D" 'chat-mark-brand-deepseek)))
    ;; No provider at all, and a provider with no brand colour: the second
    ;; is the case `chat-mark-provider-faces' deliberately leaves open, and
    ;; a badge filled with a guessed colour would close it wrongly.
    (should-not (chat-mark-provider-image nil "?" nil))
    (should-not (chat-mark-provider-image 'nonesuch "N" nil))))

(ert-deftest chat-mark-an-unmeasurable-frame-costs-a-badge-not-the-prompt ()
  "`default-font-height' signals when there is no frame font to ask about.

This runs on every send, from inside the prompt builder.  An exception
escaping here would take out the whole prompt to save one badge, and
there is nothing to save: no height means no image, and no image means
the glyph, which is a working prompt."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'default-font-height)
             (lambda (&rest _) (error "No font in this frame"))))
    (clrhash chat-mark--image-cache)
    (should-not (chat-mark--line-height))
    (should-not
     (chat-mark-provider-image 'deepseek "D" 'chat-mark-brand-deepseek))))

(ert-deftest chat-mark-a-glyph-that-already-resembles-the-logo-is-left-alone ()
  "A letter in a coloured box is an improvement on a letter, not on a mark.

The four listed glyphs were chosen because each looks like the logo it
stands for.  Boxing them for the sake of every provider having a picture
would replace a resemblance with a decoration."
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
    (dolist (provider (mapcar #'car chat-mark-provider-marks))
      (should-not
       (chat-mark-provider-image provider "\u2733" 'chat-mark-brand-claude)))))

(ert-deftest chat-mark-a-real-logo-file-wins-over-anything-generated ()
  "Including over a listed glyph: the file is the reader saying which mark."
  (skip-unless (image-type-available-p 'svg))
  (chat-test-with-temp-dir
   (let ((chat-mark-logo-directory (expand-file-name "logos/" temp-dir)))
     (make-directory chat-mark-logo-directory t)
     (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
               ((symbol-function 'default-font-height) (lambda (&rest _) 19)))
       (clrhash chat-mark--image-cache)
       (with-temp-file (expand-file-name "claude.svg" chat-mark-logo-directory)
         (insert "<svg xmlns=\"http://www.w3.org/2000/svg\""
                 " width=\"32\" height=\"32\"><rect width=\"32\""
                 " height=\"32\" fill=\"#000\"/></svg>"))
       (let ((image (chat-mark-provider-image
                     'claude "\u2733" 'chat-mark-brand-claude)))
         (should image)
         ;; A file, not the generated data: the reader's own asset.
         (should (plist-get (cdr image) :file))
         (should-not (plist-get (cdr image) :data)))))))

(ert-deftest chat-mark-an-image-is-built-once-per-appearance ()
  "The prompt is rebuilt on every send, and rasterising is not free.

The resolved colour is in the key rather than being read past it, so a
theme change lands on a new entry instead of needing anyone to remember
to clear the cache."
  (skip-unless (image-type-available-p 'svg))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'default-font-height) (lambda (&rest _) 19)))
    (clrhash chat-mark--image-cache)
    (let ((first (chat-mark-provider-image
                  'deepseek "D" 'chat-mark-brand-deepseek))
          (again (chat-mark-provider-image
                  'deepseek "D" 'chat-mark-brand-deepseek)))
      (should first)
      (should (eq first again))
      (should (= 1 (hash-table-count chat-mark--image-cache))))))

(ert-deftest chat-mark-the-cache-has-a-ceiling ()
  "A cache with no bound is a leak that happens slowly."
  (skip-unless (image-type-available-p 'svg))
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'default-font-height) (lambda (&rest _) 19)))
    (clrhash chat-mark--image-cache)
    (dotimes (index (* 3 chat-mark--image-cache-limit))
      (chat-mark-provider-image
       (intern (format "vendor-%d" index)) "V" 'chat-mark-brand-deepseek))
    (should (<= (hash-table-count chat-mark--image-cache)
                (1+ chat-mark--image-cache-limit)))))

;;; test-chat-mark.el ends here
