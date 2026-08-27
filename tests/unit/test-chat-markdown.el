;;; test-chat-markdown.el --- Markdown shown as a document -*- lexical-binding: t; -*-

;;; Commentary:

;; The tests that matter are the ones about the constraint rather than the
;; appearance: markers are hidden and not removed, so what you copy is what
;; the model wrote; the renderer is a function of its input, so the streaming
;; and redraw paths cannot drift; and a construct the prompt asked the model
;; not to use still comes out as itself.
;;
;; Spec 005.

;;; Code:

(require 'ert)
(require 'chat-align)
(require 'chat-markdown)

(defun test-markdown--visible (rendered)
  "Return what RENDERED shows, dropping what is marked invisible."
  (let ((out nil)
        (pos 0)
        (length (length rendered)))
    (while (< pos length)
      (let ((next (or (next-single-property-change pos 'invisible rendered)
                      length)))
        (unless (get-text-property pos 'invisible rendered)
          (push (substring-no-properties rendered pos next) out))
        (setq pos next)))
    (apply #'concat (nreverse out))))

(defun test-markdown--screen (rendered)
  "Return what RENDERED puts on screen.

Invisible spans dropped and `display' strings substituted, which is the
only measure that means anything for alignment: a separator row's dashes
are wider than its column and are never seen, and a bullet is one
character of text showing as another."
  (let ((out nil)
        (pos 0)
        (length (length rendered)))
    (while (< pos length)
      (let* ((next (min (or (next-single-property-change pos 'invisible
                                                        rendered)
                            length)
                        (or (next-single-property-change pos 'display
                                                        rendered)
                            length)))
             (display (get-text-property pos 'display rendered)))
        (unless (get-text-property pos 'invisible rendered)
          (push (if (stringp display)
                    display
                  (substring-no-properties rendered pos next))
                out))
        (setq pos next)))
    (apply #'concat (nreverse out))))

(defun test-markdown--faces-at (rendered string)
  "Return the faces RENDERED carries where STRING begins."
  (let ((at (string-match (regexp-quote string) rendered)))
    (should at)
    (let ((face (get-text-property at 'face rendered)))
      (if (listp face) face (list face)))))

;; ------------------------------------------------------------------
;; A rendering is a view, never the document
;; ------------------------------------------------------------------

(ert-deftest chat-markdown-text-survives-rendering ()
  "Every character of the source is still there afterwards.
This is the whole reason markers are hidden with `invisible' rather than
deleted or displayed away: kill-region and a mouse selection give back the
original Markdown."
  (dolist (source '("A **bold** word."
                    "Some `code` here."
                    "## A heading"
                    "- an item\n- another"
                    "> quoted\n> more"
                    "A [link](http://example.com) inline."
                    "~~struck~~ and *slanted*"
                    "1. first\n2. second"
                    "- [ ] todo\n- [x] done"))
    (should (equal source
                   (substring-no-properties
                    (chat-markdown-render source))))))

(ert-deftest chat-markdown-is-a-function-of-its-input ()
  "Two calls on the same source give the same thing, properties included.
Which is what lets the streaming path and the redraw path produce
identical styling without having to remember to agree: they do not agree,
they have one input."
  (let ((source "## Head\n\nA **bold** thing and `code`.\n\n- one\n- two\n"))
    (should (equal-including-properties
             (chat-markdown-render source)
             (chat-markdown-render source)))))

(ert-deftest chat-markdown-a-channel-face-is-added-to-not-replaced ()
  "Structure inside a channel keeps the channel.
An interim note is italic and the code inside it has to be both."
  (let* ((rendered (chat-markdown-render "see `x` now" 'italic))
         (faces (test-markdown--faces-at rendered "x")))
    (should (memq 'italic faces))
    (should (memq 'chat-markdown-code faces))))

;; ------------------------------------------------------------------
;; Markers
;; ------------------------------------------------------------------

(ert-deftest chat-markdown-emphasis-markers-are-hidden ()
  "Stars and backticks are not on screen; their contents are."
  (should (equal "bold" (test-markdown--visible
                         (chat-markdown-render "**bold**"))))
  (should (equal "code" (test-markdown--visible
                         (chat-markdown-render "`code`"))))
  (should (equal "both" (test-markdown--visible
                         (chat-markdown-render "***both***"))))
  (should (equal "gone" (test-markdown--visible
                         (chat-markdown-render "~~gone~~")))))

(ert-deftest chat-markdown-emphasis-is-emphasised ()
  "The face matches the marker that was hidden."
  (should (memq 'bold (test-markdown--faces-at
                       (chat-markdown-render "**b**") "b")))
  (should (memq 'italic (test-markdown--faces-at
                         (chat-markdown-render "*i*") "i")))
  (should (memq 'chat-markdown-strike
                (test-markdown--faces-at
                 (chat-markdown-render "~~s~~") "s"))))

(ert-deftest chat-markdown-a-heading-loses-its-hashes ()
  "Including the space after them, or the line sits one column in."
  (should (equal "Title" (test-markdown--visible
                          (chat-markdown-render "## Title"))))
  (should (memq 'chat-markdown-heading-1
                (test-markdown--faces-at
                 (chat-markdown-render "## Title") "Title"))))

(ert-deftest chat-markdown-a-link-shows-its-text-only ()
  "The address is hidden but still in the buffer, and reachable."
  (let ((rendered (chat-markdown-render "see [docs](http://example.com) x")))
    (should (equal "see docs x" (test-markdown--visible rendered)))
    (should (equal "http://example.com"
                   (get-text-property (string-match "docs" rendered)
                                      'chat-markdown-url rendered)))))

(ert-deftest chat-markdown-an-underscore-inside-a-word-is-not-emphasis ()
  "Or every snake_case identifier would come out slanted and truncated."
  (let ((rendered (chat-markdown-render "call chat_do_thing now")))
    (should (equal "call chat_do_thing now"
                   (test-markdown--visible rendered)))))

(ert-deftest chat-markdown-a-marker-inside-code-is-a-character ()
  "Backticks stop the inline scan; they do not delimit a region to scan."
  (let ((rendered (chat-markdown-render "`a **b** c`")))
    (should (equal "a **b** c" (test-markdown--visible rendered)))))

;; ------------------------------------------------------------------
;; Lists
;; ------------------------------------------------------------------

(ert-deftest chat-markdown-a-bullet-is-displayed-not-replaced ()
  "The dash is still the text; a round bullet is what shows."
  (let* ((rendered (chat-markdown-render "- item"))
         (at (string-match "-" rendered)))
    (should (equal "•" (get-text-property at 'display rendered)))
    (should (equal "- item" (substring-no-properties rendered)))))

(ert-deftest chat-markdown-nesting-changes-the-bullet ()
  "Depth is read from the indent, so two levels are told apart."
  (let* ((rendered (chat-markdown-render "- top\n  - under")))
    (should (equal "•" (get-text-property (string-match "- top" rendered)
                                          'display rendered)))
    (should (equal "◦" (get-text-property (string-match "- under" rendered)
                                          'display rendered)))))

(ert-deftest chat-markdown-a-checkbox-becomes-a-box ()
  (let ((rendered (chat-markdown-render "- [ ] todo\n- [x] done")))
    (should (equal "☐" (get-text-property (string-match "\\[ \\]" rendered)
                                          'display rendered)))
    (should (equal "☑" (get-text-property (string-match "\\[x\\]" rendered)
                                          'display rendered)))))

(ert-deftest chat-markdown-a-continuation-lines-up-with-the-text ()
  "Hanging indent by `wrap-prefix', which needs no extra package."
  (let* ((rendered (chat-markdown-render "- item text"))
         (at (string-match "item" rendered)))
    (should (equal "  " (get-text-property at 'wrap-prefix rendered)))))

;; ------------------------------------------------------------------
;; Tables
;; ------------------------------------------------------------------

(ert-deftest chat-markdown-a-chinese-table-lines-up ()
  "Columns measured by `string-width', never by `length'.
Counting characters puts every table containing Chinese out by the number
of Chinese characters in its widest cell."
  (let* ((source "| name | v |\n| --- | --- |\n| 中文名 | 1 |")
         (lines (split-string (test-markdown--screen
                               (chat-markdown-render source))
                              "\n"))
         (widths (mapcar #'string-width lines)))
    (should (= 3 (length lines)))
    (should (apply #'= widths))))

(ert-deftest chat-markdown-a-padded-table-is-still-markdown ()
  "Padding is the one thing here that changes text, and it is allowed
only because what it produces is a valid, equivalent table.  So the
separator row has to stay dashes: the rule is a `display' property over
them, not text written in their place."
  (let* ((source "| a | b |\n| :-- | --: |\n| 中文 | y |")
         (lines (split-string (substring-no-properties
                               (chat-markdown-render source))
                              "\n")))
    (dolist (line lines)
      (should (string-prefix-p "|" line))
      (should (string-suffix-p "|" line)))
    ;; Dashes, and the alignment colons still where they were, since
    ;; dropping those changes what the copied table means.
    (should (string-match-p "\\`| :-+ | -+: |\\'" (nth 1 lines)))))

(ert-deftest chat-markdown-a-separator-row-shows-as-a-rule ()
  (let* ((rendered (chat-markdown-render "| a |\n| --- |\n| 1 |"))
         (at (string-match "-" rendered)))
    (should (string-match-p "\\`├─+┤\\'"
                            (get-text-property at 'display rendered)))))

(ert-deftest chat-markdown-a-table-uses-one-font-metric ()
  "Bold headers and inline code must not move a column boundary.

The arithmetic is in character columns, so every visible table row has
to be fixed-pitch.  Otherwise a logically aligned table still drifts by
pixels as soon as a header is bold or a cell contains inline code."
  (let* ((rendered (chat-markdown-render
                    "| field | value |\n| --- | --- |\n| 中文 | `code` |"))
         (header-faces (test-markdown--faces-at rendered "field"))
         (body-faces (test-markdown--faces-at rendered "中文")))
    (should (memq 'chat-markdown-table-header header-faces))
    (should (memq 'chat-markdown-table body-faces))))

(ert-deftest chat-markdown-table-width-ignores-hidden-inline-markers ()
  "Backticks and link destinations must not pull a border to the left."
  (let* ((source "| kind | value |\n| --- | --- |\n| code | `main` |\n| link | [docs](https://example.com) |")
         (lines (split-string (test-markdown--screen
                               (chat-markdown-render source))
                              "\n"))
         (widths (mapcar #'string-width lines)))
    (should (apply #'= widths))))

(ert-deftest chat-markdown-table-truncation-keeps-inline-markers-paired ()
  "A narrow cell remains valid Markdown after visible-width truncation."
  (let ((chat-markdown-table-max-width 12))
    (let ((source (substring-no-properties
                   (chat-markdown-render
                    "| a |\n| --- |\n| `abcdefghijk` |"))))
      (should (string-match-p "`[^`]+…`" source)))))

(ert-deftest chat-markdown-table-pipes-display-as-box-borders ()
  "The view gets quiet Unicode borders while the source keeps pipes."
  (let* ((rendered (chat-markdown-render "| a | b |\n| - | - |\n| 1 | 2 |"))
         (first-pipe (string-match "|" rendered))
         (inner-pipe (string-match "|" rendered (1+ first-pipe))))
    (should (equal "│ " (get-text-property first-pipe 'display rendered)))
    (should (equal " │ " (get-text-property inner-pipe 'display rendered)))
    (should (string-match-p "| a +| b +|"
                            (substring-no-properties rendered)))))

(ert-deftest chat-markdown-a-wide-table-does-not-run-off-the-side ()
  "It is narrowed to the limit rather than left to overflow unseen."
  (let* ((cell (make-string 60 ?x))
         (source (format "| %s | %s |\n| --- | --- |\n| %s | %s |"
                         cell cell cell cell))
         (screen (test-markdown--screen (chat-markdown-render source))))
    (dolist (line (split-string screen "\n"))
      (should (<= (string-width line) chat-markdown-table-max-width)))))

;; ------------------------------------------------------------------
;; Code blocks
;; ------------------------------------------------------------------

(ert-deftest chat-markdown-a-closed-block-gets-its-language ()
  "Keywords, strings and comments each take their own face."
  (let* ((source "```elisp\n(defun f () \"s\") ; c\n```")
         (rendered (chat-markdown-render source))
         (defun-faces (test-markdown--faces-at rendered "defun"))
         (string-faces (test-markdown--faces-at rendered "\"s\""))
         (comment-faces (test-markdown--faces-at rendered ";")))
    ;; The block face is underneath, so the block keeps its pitch and
    ;; background while the mode's faces sit on top.
    (should (memq 'chat-code-block-face defun-faces))
    (should (memq 'font-lock-keyword-face defun-faces))
    (should (memq 'font-lock-doc-face string-faces))
    (should (memq 'font-lock-comment-delimiter-face comment-faces))))

(ert-deftest chat-markdown-an-open-block-is-not-coloured ()
  "What is arriving is incomplete code: font-lock over it would both fail
and be wasted, since it is about to change."
  (let* ((rendered (chat-markdown-render "```elisp\n(defun f ("))
         (faces (test-markdown--faces-at rendered "defun")))
    (should (memq 'chat-code-block-face faces))
    (should-not (memq 'font-lock-keyword-face faces))))

(ert-deftest chat-markdown-a-fence-becomes-a-labelled-code-rail ()
  "Backticks remain copyable but no longer dominate the document view."
  (let* ((source "```elisp\n(message \"hi\")\n```")
         (rendered (chat-markdown-render source))
         (open (string-match "```elisp" rendered))
         (body (string-match "(message" rendered))
         (close (string-match "```" rendered (1+ open))))
    (should (equal "┌ elisp" (get-text-property open 'display rendered)))
    (should (equal "│ " (substring-no-properties
                          (get-text-property body 'line-prefix rendered))))
    (should (equal "└" (get-text-property close 'display rendered)))
    (should (equal source (substring-no-properties rendered)))))

(ert-deftest chat-markdown-a-blockquote-keeps-a-visible-rail ()
  (let* ((source "> quoted")
         (rendered (chat-markdown-render source))
         (marker (string-match "> " rendered)))
    (should (equal "▎ " (get-text-property marker 'display rendered)))
    (should (equal source (substring-no-properties rendered)))))

(ert-deftest chat-markdown-an-unknown-language-loads-nothing ()
  "A code block must not be able to decide which package gets loaded."
  (should-not (chat-markdown--code-mode "definitely-not-a-language"))
  (should-not (chat-markdown--code-mode ""))
  ;; And a tag in the table resolves without interning whatever was written.
  (should (eq 'emacs-lisp-mode (chat-markdown--code-mode "elisp"))))

(ert-deftest chat-markdown-a-mode-that-fails-loses-only-its-block ()
  "One bad block takes the plain face; the rest of the answer is drawn."
  ;; Failing inside the colouring, not instead of it: what is being tested
  ;; is the `condition-case' that wraps it.
  (cl-letf (((symbol-function 'font-lock-ensure)
             (lambda (&rest _) (error "this mode cannot"))))
    (clrhash chat-markdown--fontify-cache)
    (let ((rendered (chat-markdown-render
                     "```elisp\n(f)\n```\n\nAfter **it**.")))
      (should (memq 'chat-code-block-face
                    (test-markdown--faces-at rendered "(f)")))
      (should (memq 'bold (test-markdown--faces-at rendered "it"))))))

(ert-deftest chat-markdown-a-block-is-coloured-once-however-often-drawn ()
  "A block is re-rendered on every piece that arrives, and font-lock is
the expensive part of doing so."
  (clrhash chat-markdown--fontify-cache)
  (let ((runs 0))
    (cl-letf* ((original (symbol-function 'chat-markdown--fontify-with))
               ((symbol-function 'chat-markdown--fontify-with)
                (lambda (&rest args)
                  (setq runs (1+ runs))
                  (apply original args))))
      (dotimes (_ 5)
        (chat-markdown-render "```elisp\n(defun f ())\n```"))
      (should (= 1 runs)))))

;; ------------------------------------------------------------------
;; Outside the subset
;; ------------------------------------------------------------------

(ert-deftest chat-markdown-what-is-not-rendered-is-still-shown ()
  "The prompt narrows the subset to improve display; it is not a premise
the renderer relies on.  Anything outside it lands as itself."
  (dolist (source '("<div class=\"x\">raw</div>"
                    "$x^2 + y$"
                    "###### deep heading"
                    "Text[^1] with a footnote."
                    "Underlined\n=========="))
    (let ((rendered (chat-markdown-render source)))
      (should (equal source (substring-no-properties rendered)))
      (should (stringp rendered)))))

(ert-deftest chat-markdown-a-lone-marker-does-not-eat-the-rest ()
  "An unclosed construct must not take the text after it with it."
  (dolist (source '("an ** unclosed"
                    "a ` dangling tick"
                    "a [broken](link"
                    "~~ half"))
    (should (equal source
                   (substring-no-properties
                    (chat-markdown-render source))))))

;; ------------------------------------------------------------------
;; Streaming
;; ------------------------------------------------------------------

(ert-deftest chat-markdown-a-stable-prefix-ends-at-the-last-finished-block ()
  "What is stable is re-rendered once; what is not is re-rendered as it
changes, which is what keeps a piece's cost proportional to the tail."
  ;; A paragraph followed by a blank line is done; the one after is not.
  (let ((source "done paragraph\n\nstill going"))
    (should (= (length "done paragraph\n\n")
               (chat-markdown-stable-prefix-length source))))
  ;; An open fence is never stable, however much is inside it.
  (let ((source "text\n\n```elisp\n(a)\n(b)\n"))
    (should (= (length "text\n\n")
               (chat-markdown-stable-prefix-length source))))
  ;; Closed, it is.
  (let ((source "```elisp\n(a)\n```\nafter"))
    (should (= (length "```elisp\n(a)\n```\n")
               (chat-markdown-stable-prefix-length source)))))

(ert-deftest chat-markdown-nothing-finished-means-no-stable-prefix ()
  (should (= 0 (chat-markdown-stable-prefix-length "first words")))
  (should (= 0 (chat-markdown-stable-prefix-length ""))))

(ert-deftest chat-markdown-a-stable-prefix-never-exceeds-its-source ()
  "It indexes the source, so it has to be a valid index into it."
  (dolist (source '("" "a" "a\n" "\n\n" "```\n" "- x\n\n" "| a |\n"))
    (let ((stable (chat-markdown-stable-prefix-length source)))
      (should (<= 0 stable (length source)))
      (should (stringp (substring source 0 stable))))))

;; ------------------------------------------------------------------
;; Where it sits, and what it may call
;; ------------------------------------------------------------------

(defun test-markdown--source (relative)
  "Return the text of RELATIVE within the repository."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name
      relative
      (locate-dominating-file
       (or load-file-name buffer-file-name default-directory)
       "chat.el")))
    (buffer-string)))

(ert-deftest chat-markdown-lives-in-core-and-stays-there ()
  "It computes styling without touching a buffer or a window, which is
why it can be in core -- and it has to be, because the MDP codec needs
its column alignment and a protocol module depending on the display
layer would point the dependency the wrong way."
  (let ((source (test-markdown--source "lisp/core/chat-markdown.el")))
    (should (string-match-p "(require 'chat-align)" source))
    (should-not (string-match-p "(require 'chat-ui" source))
    (should-not (string-match-p "(require 'chat-transcript)" source))))

(ert-deftest chat-markdown-nothing-on-the-render-path-blocks ()
  "The renderer runs in the main loop, so it must not stop it.
Spec 004's constraint, still applying here."
  (let ((source (test-markdown--source "lisp/core/chat-markdown.el")))
    (dolist (call '("sit-for" "sleep-for" "accept-process-output"
                    "call-process" "start-process" "url-retrieve"))
      (should-not (string-match-p (concat "(" (regexp-quote call) "[ )]")
                                  source)))))

(ert-deftest chat-markdown-hiding-is-never-deletion ()
  "Asserted about the source as well as the behaviour, because this is
the constraint the whole module rests on and there is no way to notice
its loss except by losing text."
  (let ((source (test-markdown--source "lisp/core/chat-markdown.el")))
    (should-not (string-match-p "delete-region" source))
    (should-not (string-match-p "'display \"\"" source))))

;; ------------------------------------------------------------------
;; Alignment, the shared one
;; ------------------------------------------------------------------

(ert-deftest chat-align-columns-are-measured-on-screen ()
  (should (equal '(6 1) (chat-align-column-widths
                         '(("name" "v") ("中文名" "1")))))
  (should (equal "中文  " (chat-align-pad "中文" 6)))
  (should (equal "  中文" (chat-align-pad "中文" 6 'right))))

(ert-deftest chat-align-padding-never-shortens ()
  "A cell over its column is a column that is too narrow, not a cell to
truncate: padding must not lose data to make a table pretty."
  (should (equal "long" (chat-align-pad "long" 2))))

(ert-deftest chat-align-truncation-counts-columns-not-characters ()
  "A cut counted in characters lands a column over when the last one
taken is double width."
  (should (equal "中…" (chat-align-truncate "中文名字" 4)))
  (should (<= (string-width (chat-align-truncate "中文名字" 5)) 5))
  (should (equal "abc" (chat-align-truncate "abc" 5))))

(ert-deftest chat-align-a-ragged-row-does-not-constrain-what-it-lacks ()
  "So that a malformed table is laid out rather than refused."
  (should (equal '(3 2) (chat-align-column-widths '(("abc") ("a" "bc"))))))

(provide 'test-chat-markdown)
;;; test-chat-markdown.el ends here
