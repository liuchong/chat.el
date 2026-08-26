;;; chat-markdown.el --- Markdown as a document, in the buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; What models write is Markdown.  Nobody here chose that; the ecosystem did,
;; and prompting against the training distribution to get anything else does
;; not hold.  So the format is settled and the question is display.
;;
;; Emacs has never had its own Markdown engine.  The usual approach is to
;; shell out to `pandoc' or a browser component and open the result in a
;; second window as a "preview", which gives up what Emacs is good at -- the
;; buffer *is* the text, text properties *are* the styling, everything is
;; foldable, searchable, killable -- in order to imitate what a browser is
;; good at.
;;
;; Org-mode does not do that.  The document stays plain text and becomes
;; presentable in place: the stars vanish, headings take levels, source
;; blocks get their real major mode, tables line up.  All of it with text
;; properties, no external renderer, no graphical widget.  That is the target
;; here, with Markdown's syntax instead of Org's.
;;
;; The constraint that shapes everything: a rendering is a view of the
;; document, never the document.  Anything that needs the content -- redraw,
;; copy, the next request, the session file -- reads the original Markdown.
;; Which is why markers are hidden with `invisible' and never deleted, and
;; why the entry point is a pure function of its input.
;;
;; This is in core rather than ui because it computes styling without
;; touching a buffer or a window -- `chat-transcript.el' sets the precedent,
;; defining faces from core for the same reason -- and because the MDP codec
;; needs the column alignment and must not depend on the display layer.
;; Spec 005.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-align)

;; ------------------------------------------------------------------
;; Faces
;; ------------------------------------------------------------------

(defgroup chat-markdown nil
  "Displaying Markdown as a document."
  :group 'chat)

(defface chat-markdown-heading-1
  '((t :inherit bold :height 1.15))
  "A second-level Markdown heading, the highest the prompt asks for."
  :group 'chat-markdown)

(defface chat-markdown-heading-2
  '((t :inherit bold))
  "A third-level Markdown heading."
  :group 'chat-markdown)

(defface chat-markdown-heading-3
  '((t :inherit bold :slant italic))
  "A fourth-level Markdown heading."
  :group 'chat-markdown)

(defface chat-markdown-heading-4
  '((t :inherit (shadow bold)))
  "A Markdown heading deeper than the prompt asks for."
  :group 'chat-markdown)

(defface chat-markdown-code
  '((t :inherit (fixed-pitch shadow)))
  "Code inside a paragraph."
  :group 'chat-markdown)

(defface chat-code-block-face
  '((t :inherit fixed-pitch :extend t))
  "A fenced code block.

One face where there were two.  `chat-ui-code-block-face' was identical
and used by the finalize path while this one was used by the insert path,
so the same visual surface was split in half and could drift."
  :group 'chat-markdown)

(defface chat-markdown-fence
  '((t :inherit shadow))
  "The ``` line of a fenced block, kept visible so its language shows."
  :group 'chat-markdown)

(defface chat-markdown-list-marker
  '((t :inherit shadow))
  "The bullet or number introducing a list item."
  :group 'chat-markdown)

(defface chat-markdown-blockquote
  '((t :inherit (shadow italic)))
  "Quoted text."
  :group 'chat-markdown)

(defface chat-markdown-link
  '((t :inherit link))
  "The visible text of a link."
  :group 'chat-markdown)

(defface chat-markdown-rule
  '((t :inherit shadow))
  "A horizontal rule."
  :group 'chat-markdown)

(defface chat-markdown-table-separator
  '((t :inherit shadow))
  "The dashed row under a table's header."
  :group 'chat-markdown)

(defface chat-markdown-html
  '((t :inherit shadow))
  "Raw HTML, shown as written and played down."
  :group 'chat-markdown)

(defface chat-markdown-strike
  '((t :strike-through t))
  "Struck-out text."
  :group 'chat-markdown)

(define-obsolete-face-alias 'chat-ui-code-block-face 'chat-code-block-face
  "2026-08-27")

;; ------------------------------------------------------------------
;; Hiding, reversibly
;; ------------------------------------------------------------------

(defconst chat-markdown-invisible-symbol 'chat-markdown
  "The `invisible' value used for every marker this module hides.

One symbol for all of them, so that showing the source is one entry in
`buffer-invisibility-spec' rather than a walk over the buffer.")

(defcustom chat-markdown-hide-markers t
  "Whether Markdown markers are hidden by default in new chat buffers."
  :type 'boolean
  :group 'chat-markdown)

(defun chat-markdown--hidden (text)
  "Return TEXT marked as a hidden marker.

`invisible', never `display' with an empty string and never deletion.
The reason is copying: an invisible character is still in the buffer, so
`kill-region' and a mouse selection yield the original Markdown.  Deleted
or displayed-away, it could not be recovered."
  (propertize text 'invisible chat-markdown-invisible-symbol))

;; ------------------------------------------------------------------
;; Faces that add rather than replace
;; ------------------------------------------------------------------

(defun chat-markdown--face (face base)
  "Return FACE applied over BASE.

Spec 004 owns the channel -- reasoning, tool, interim, answer -- and this
module owns structure inside it, so the two stack.  Inline code inside an
interim note has to be both italic and code, which means a list, not a
choice."
  (cond ((null base) face)
        ((null face) base)
        (t (append (if (listp face) face (list face))
                   (if (listp base) base (list base))))))

(defun chat-markdown--put (text face base &rest properties)
  "Return TEXT in FACE over BASE, carrying PROPERTIES."
  (apply #'propertize text
         'face (chat-markdown--face face base)
         properties))

;; ------------------------------------------------------------------
;; Line shapes
;; ------------------------------------------------------------------

(defconst chat-markdown--fence-regexp
  "^[ \t]*\\(```+\\|~~~+\\)[ \t]*\\([^ \t\n]*\\)[ \t]*$"
  "A fence opening or closing a code block: 1 the run, 2 the language.")

(defconst chat-markdown--heading-regexp
  "^\\(#\\{1,6\\}\\)[ \t]+\\(.*\\)$"
  "An ATX heading: 1 the hashes, 2 the text.")

(defconst chat-markdown--rule-regexp
  "^[ \t]*\\(-[ \t]*-[ \t]*-[- \t]*\\|\\*[ \t]*\\*[ \t]*\\*[* \t]*\\|_[ \t]*_[ \t]*_[_ \t]*\\)$"
  "A horizontal rule.")

(defconst chat-markdown--bullet-regexp
  "^\\([ \t]*\\)\\([-*+]\\)[ \t]+\\(\\[[ xX]\\][ \t]+\\)?"
  "An unordered list item: 1 indent, 2 bullet, 3 an optional checkbox.")

(defconst chat-markdown--ordered-regexp
  "^\\([ \t]*\\)\\([0-9]+[.)]\\)[ \t]+"
  "An ordered list item: 1 indent, 2 the number and its punctuation.")

(defconst chat-markdown--quote-regexp
  "^\\([ \t]*\\)\\(>[ \t]?\\)"
  "A blockquote line: 1 indent, 2 the marker.")

(defconst chat-markdown--table-row-regexp
  "^[ \t]*|.*|[ \t]*$"
  "A table row.")

(defconst chat-markdown--table-separator-regexp
  "^[ \t]*|[ \t:|-]+|[ \t]*$"
  "The dashed row under a table's header.")

(defconst chat-markdown--html-regexp
  "^[ \t]*</?[a-zA-Z!][^>]*>"
  "A line opening a raw HTML block.")

(defconst chat-markdown--bullets ["•" "◦" "▪"]
  "Bullets by nesting depth, cycling for anything deeper.")

(defun chat-markdown--indent-depth (indent)
  "Return the nesting depth INDENT represents."
  (/ (chat-align-width (or indent "")) 2))

(defun chat-markdown--bullet-for (depth)
  "Return the bullet to display at DEPTH."
  (aref chat-markdown--bullets
        (mod depth (length chat-markdown--bullets))))

;; ------------------------------------------------------------------
;; Inline constructs
;; ------------------------------------------------------------------

(defconst chat-markdown--inline-rules
  ;; Order matters: the longest marker first, or `**bold**' is read as an
  ;; italic containing an italic.  Inline code comes before everything
  ;; because a marker inside backticks is not a marker.
  '(("`\\([^`\n]+\\)`" code)
    ("\\*\\*\\*\\([^*\n]+\\)\\*\\*\\*" bold-italic)
    ("___\\([^_\n]+\\)___" bold-italic)
    ("\\*\\*\\([^*\n]+\\)\\*\\*" bold)
    ("__\\([^_\n]+\\)__" bold)
    ("~~\\([^~\n]+\\)~~" strike)
    ("\\*\\([^*\n]+\\)\\*" italic)
    ("\\(?:^\\|[^A-Za-z0-9_]\\)\\(_\\([^_\n]+\\)_\\)" italic-underscore))
  "Inline markers, as (REGEXP KIND), tried in order at each position.")

(defconst chat-markdown--image-regexp
  "!\\[\\([^]\n]*\\)\\](\\([^)\n]*\\))"
  "An image: 1 the alt text, 2 the address.")

(defconst chat-markdown--link-regexp
  "\\[\\([^]\n]*\\)\\](\\([^)\n]*\\))"
  "A link: 1 the text, 2 the address.")

(defconst chat-markdown--url-regexp
  "\\(?:https?\\|ftp\\)://[^ \t\n<>\"'()]+"
  "A bare URL.")

(defun chat-markdown--inline-face (kind)
  "Return the face for inline KIND."
  (pcase kind
    ('code 'chat-markdown-code)
    ('bold 'bold)
    ('italic 'italic)
    ('italic-underscore 'italic)
    ('bold-italic '(bold italic))
    ('strike 'chat-markdown-strike)))

(defun chat-markdown--inline (text base)
  "Return TEXT with its inline markers hidden and its spans faced.

Scanned once from the front, taking the earliest match of any rule, so a
construct cannot be reinterpreted by a later pass.  Anything unmatched is
passed through, which is how a construct outside the prompt's subset ends
up as itself rather than as a crash."
  (let ((pieces nil)
        (pos 0)
        (length (length text)))
    (while (< pos length)
      (let ((best nil))
        ;; Images before links: the link pattern matches an image too, and
        ;; would leave the `!' behind as text.
        (dolist (candidate
                 (list (chat-markdown--match chat-markdown--image-regexp
                                             text pos 'image)
                       (chat-markdown--match chat-markdown--link-regexp
                                             text pos 'link)
                       (chat-markdown--match chat-markdown--url-regexp
                                             text pos 'url)))
          (setq best (chat-markdown--earlier best candidate)))
        (dolist (rule chat-markdown--inline-rules)
          (setq best (chat-markdown--earlier
                      best (chat-markdown--match (car rule) text pos
                                                 (cadr rule)))))
        (if (not best)
            (progn (push (chat-markdown--plain (substring text pos) base)
                         pieces)
                   (setq pos length))
          (let ((start (plist-get best :start))
                (end (plist-get best :end)))
            (when (> start pos)
              (push (chat-markdown--plain (substring text pos start) base)
                    pieces))
            (push (chat-markdown--render-inline best base) pieces)
            ;; Guaranteed progress: a rule that matched an empty span would
            ;; otherwise spin here forever.
            (setq pos (max end (1+ start)))))))
    (apply #'concat (nreverse pieces))))

(defun chat-markdown--plain (text base)
  "Return TEXT carrying only BASE."
  (if base (propertize text 'face base) text))

(defun chat-markdown--match (regexp text pos kind)
  "Return where REGEXP matches TEXT at or after POS, as a plist, or nil."
  (save-match-data
    (when (string-match regexp text pos)
      (list :kind kind
            :start (match-beginning 0)
            :end (match-end 0)
            :whole (match-string 0 text)
            :one (match-string 1 text)
            :two (match-string 2 text)
            :one-start (match-beginning 1)))))

(defun chat-markdown--earlier (a b)
  "Return whichever of A and B starts first, preferring A when equal."
  (cond ((null a) b)
        ((null b) a)
        ((<= (plist-get a :start) (plist-get b :start)) a)
        (t b)))

(defun chat-markdown--render-inline (match base)
  "Return the rendering of MATCH over BASE."
  (let ((kind (plist-get match :kind))
        (whole (plist-get match :whole))
        (one (plist-get match :one))
        (two (plist-get match :two)))
    (pcase kind
      ('image
       ;; A placeholder, not the image: inlining images is a non-goal, and
       ;; a line saying what it is can at least be opened.
       (concat (chat-markdown--hidden whole)
               (chat-markdown--put (format "[image: %s]"
                                           (if (string-empty-p (or one ""))
                                               (or two "")
                                             one))
                                   'chat-markdown-link base
                                   'chat-markdown-url two)))
      ('link
       (concat (chat-markdown--hidden (concat "[" ))
               (chat-markdown--put (or one "") 'chat-markdown-link base
                                   'chat-markdown-url two
                                   'mouse-face 'highlight
                                   'help-echo (or two ""))
               (chat-markdown--hidden (concat "](" (or two "") ")"))))
      ('url
       (chat-markdown--put whole 'chat-markdown-link base
                           'chat-markdown-url whole
                           'mouse-face 'highlight
                           'help-echo whole))
      ('italic-underscore
       ;; The rule matches a leading character it must not consume, so
       ;; that `snake_case_names' are left alone.
       (let* ((lead (substring whole 0 (- (length whole) (length one))))
              (inner (substring one 1 (1- (length one)))))
         (concat (chat-markdown--plain lead base)
                 (chat-markdown--hidden "_")
                 (chat-markdown--inline-body inner 'italic base)
                 (chat-markdown--hidden "_"))))
      (_
       (let* ((marker-length (/ (- (length whole) (length (or one ""))) 2))
              (marker (substring whole 0 marker-length)))
         (concat (chat-markdown--hidden marker)
                 (chat-markdown--inline-body
                  (or one "") (chat-markdown--inline-face kind) base)
                 (chat-markdown--hidden marker)))))))

(defun chat-markdown--inline-body (text face base)
  "Return TEXT in FACE over BASE, with nested markers handled.

Code is not recursed into: a marker inside backticks is text."
  (if (eq face 'chat-markdown-code)
      (chat-markdown--put text face base)
    (chat-markdown--inline text (chat-markdown--face face base))))

;; ------------------------------------------------------------------
;; Code blocks
;; ------------------------------------------------------------------

(defcustom chat-markdown-code-modes
  '(("elisp" . emacs-lisp-mode)
    ("emacs-lisp" . emacs-lisp-mode)
    ("lisp" . lisp-mode)
    ("clojure" . clojure-mode)
    ("scheme" . scheme-mode)
    ("c" . c-mode)
    ("c++" . c++-mode)
    ("cpp" . c++-mode)
    ("objc" . objc-mode)
    ("java" . java-mode)
    ("rust" . rust-mode)
    ("go" . go-mode)
    ("python" . python-mode)
    ("py" . python-mode)
    ("ruby" . ruby-mode)
    ("perl" . perl-mode)
    ("php" . php-mode)
    ("js" . js-mode)
    ("javascript" . js-mode)
    ("jsx" . js-mode)
    ("ts" . typescript-mode)
    ("typescript" . typescript-mode)
    ("tsx" . typescript-mode)
    ("html" . html-mode)
    ("xml" . xml-mode)
    ("css" . css-mode)
    ("scss" . css-mode)
    ("json" . js-mode)
    ("yaml" . yaml-mode)
    ("yml" . yaml-mode)
    ("toml" . conf-toml-mode)
    ("ini" . conf-mode)
    ("conf" . conf-mode)
    ("sh" . sh-mode)
    ("bash" . sh-mode)
    ("zsh" . sh-mode)
    ("shell" . sh-mode)
    ("fish" . sh-mode)
    ("sql" . sql-mode)
    ("diff" . diff-mode)
    ("patch" . diff-mode)
    ("makefile" . makefile-mode)
    ("dockerfile" . dockerfile-mode)
    ("nix" . nix-mode)
    ("haskell" . haskell-mode)
    ("swift" . swift-mode)
    ("kotlin" . kotlin-mode)
    ("scala" . scala-mode)
    ("lua" . lua-mode)
    ("r" . R-mode)
    ("tex" . latex-mode)
    ("latex" . latex-mode)
    ("org" . org-mode)
    ("markdown" . text-mode)
    ("md" . text-mode)
    ("text" . text-mode))
  "Language tags to the major mode that colours them.

An explicit table, never `(intern (concat lang \"-mode\"))'.  Interning
whatever the model wrote and calling it lets the model's output decide
which package gets loaded, which is a remote input choosing what code
runs."
  :type '(alist :key-type string :value-type symbol)
  :group 'chat-markdown)

(defcustom chat-markdown-code-fontify-max-chars 20000
  "Largest code block that gets syntax colouring.

Above this it takes the plain code face.  Running font-lock over a very
large block on the redraw path costs more than the colour is worth."
  :type 'integer
  :group 'chat-markdown)

(defvar chat-markdown--fontify-cache (make-hash-table :test 'equal)
  "Language and body to the coloured result.

A block is re-rendered on every piece that arrives during streaming, and
font-lock is the expensive part of doing so.")

(defcustom chat-markdown-fontify-cache-limit 200
  "How many coloured code blocks are remembered."
  :type 'integer
  :group 'chat-markdown)

(defun chat-markdown--code-mode (language)
  "Return the major mode to colour LANGUAGE with, or nil.

Outside the table, a `LANG-mode' symbol is used only when it is already
loaded -- defined and not still an autoload.  A code block must not be
able to pull in a package."
  (let ((tag (downcase (string-trim (or language "")))))
    (unless (string-empty-p tag)
      (or (cdr (assoc tag chat-markdown-code-modes))
          (let ((symbol (intern-soft (concat tag "-mode"))))
            (when (and symbol
                       (fboundp symbol)
                       (not (autoloadp (symbol-function symbol))))
              symbol))))))

(defun chat-markdown--fontify-code (body language)
  "Return BODY coloured as LANGUAGE, or nil when it cannot be."
  (when-let ((mode (and (<= (length body)
                            chat-markdown-code-fontify-max-chars)
                        (chat-markdown--code-mode language))))
    (let ((key (cons mode body)))
      (or (gethash key chat-markdown--fontify-cache)
          (let ((result (chat-markdown--fontify-with mode body)))
            (when result
              (when (> (hash-table-count chat-markdown--fontify-cache)
                       chat-markdown-fontify-cache-limit)
                (clrhash chat-markdown--fontify-cache))
              (puthash key result chat-markdown--fontify-cache))
            result)))))

(defun chat-markdown--fontify-with (mode body)
  "Return BODY coloured by MODE, or nil if MODE could not do it.

`delay-mode-hooks', because a user's mode hook may start a language
server, open a connection or spawn a process, and none of that belongs on
the path that draws a reply.  Wrapped in `condition-case' so that one bad
block loses its own colour and not the whole answer."
  (condition-case nil
      (with-temp-buffer
        (insert body)
        (delay-mode-hooks (funcall mode))
        (font-lock-ensure)
        (buffer-string))
    (error nil)))

;; ------------------------------------------------------------------
;; Tables
;; ------------------------------------------------------------------

(defcustom chat-markdown-table-max-width 100
  "Widest a laid-out table may be before its cells are cut.

A table wider than the window would otherwise run off to the right with
nothing on screen to say that it had."
  :type 'integer
  :group 'chat-markdown)

(defun chat-markdown--table-cells (line)
  "Return the cells of table LINE."
  (let* ((trimmed (string-trim line))
         (inner (string-trim trimmed "^|" "|$")))
    (mapcar #'string-trim (split-string inner "|"))))

(defun chat-markdown--table-alignments (separator)
  "Return the column alignments SEPARATOR asks for."
  (mapcar (lambda (cell)
            (cond ((and (string-prefix-p ":" cell)
                        (string-suffix-p ":" cell))
                   'center)
                  ((string-suffix-p ":" cell) 'right)
                  (t 'left)))
          (chat-markdown--table-cells separator)))

(defun chat-markdown--render-table (lines base)
  "Return LINES laid out as a table over BASE.

Padding is the one place this module changes buffer text, and it is
acceptable because a padded table is still valid, equivalent Markdown:
copied out, it works."
  (let* ((rows (mapcar #'chat-markdown--table-cells lines))
         (separator-index
          (cl-position-if (lambda (line)
                            (string-match-p
                             chat-markdown--table-separator-regexp line))
                          lines))
         (alignments (and separator-index
                          (chat-markdown--table-alignments
                           (nth separator-index lines))))
         (data (cl-loop for row in rows
                        for index from 0
                        unless (eql index separator-index)
                        collect row))
         (widths (chat-align-column-widths data))
         (widths (chat-markdown--fit-widths widths))
         (output nil))
    (cl-loop for row in rows
             for index from 0
             do (push
                 (if (eql index separator-index)
                     (chat-markdown--render-separator row widths base)
                   (concat "| "
                           (chat-align-row
                            (cl-loop for cell in row
                                     for column from 0
                                     collect
                                     (chat-markdown--table-cell
                                      cell (nth column widths) base))
                            widths alignments)
                           " |"))
                 output))
    (mapconcat #'identity (nreverse output) "\n")))

(defun chat-markdown--table-cell (cell width base)
  "Return CELL rendered for a column of WIDTH over BASE."
  (chat-markdown--inline (chat-align-truncate cell width) base))

(defun chat-markdown--fit-widths (widths)
  "Return WIDTHS reduced to fit `chat-markdown-table-max-width'.

Narrowed proportionally rather than by dropping columns: a table missing
its last two columns looks like a table that had three."
  (let* ((separators (* 3 (max 0 (1- (length widths)))))
         (total (+ 4 separators (apply #'+ (or widths '(0)))))
         (over (- total chat-markdown-table-max-width)))
    (if (or (null widths) (<= over 0))
        widths
      (let ((room (max 1 (- chat-markdown-table-max-width 4 separators))))
        (mapcar (lambda (width)
                  (max 3 (floor (* width (/ (float room)
                                            (apply #'+ widths))))))
                widths)))))

(defun chat-markdown--render-separator (cells widths base)
  "Return the dashed row of CELLS shown as a rule sized to WIDTHS.

The text stays dashes and the rule is a `display' property over it.
Writing the rule into the buffer instead would leave a copied table
without a valid separator row, so the table that came out of the buffer
would no longer be a table -- which is the one thing padding is allowed
because it does not do."
  (let* ((dashes (cl-loop for cell in cells
                          for column from 0
                          collect (chat-markdown--stretch-dashes
                                   cell (or (nth column widths) 3))))
         (rule (mapconcat (lambda (width) (make-string (max 1 width) ?─))
                          (seq-take widths (length cells))
                          " | ")))
    (concat "| "
            (propertize (mapconcat #'identity dashes " | ")
                        'display rule
                        'face (chat-markdown--face
                               'chat-markdown-table-separator base))
            " |")))

(defun chat-markdown--stretch-dashes (cell width)
  "Return separator CELL widened to WIDTH with more dashes.

Any alignment colons are kept where they were: dropping them would
change what the copied table means, not just how it looks."
  (let ((short (- width (length cell))))
    (cond
     ((<= short 0) cell)
     ((string-suffix-p ":" cell)
      (concat (substring cell 0 -1) (make-string short ?-) ":"))
     (t (concat cell (make-string short ?-))))))

;; ------------------------------------------------------------------
;; Blocks
;; ------------------------------------------------------------------

(defun chat-markdown--lines (source)
  "Return SOURCE split into lines, keeping empty ones."
  (split-string (or source "") "\n"))

(defun chat-markdown--render-heading (line base)
  "Return heading LINE rendered over BASE."
  (save-match-data
    (string-match chat-markdown--heading-regexp line)
    (let* ((hashes (match-string 1 line))
           (text (match-string 2 line))
           (level (length hashes))
           (face (pcase level
                   ((or 1 2) 'chat-markdown-heading-1)
                   (3 'chat-markdown-heading-2)
                   (4 'chat-markdown-heading-3)
                   (_ 'chat-markdown-heading-4))))
      ;; The space after the hashes goes too, or the heading sits one
      ;; column in from everything else.
      (concat (chat-markdown--hidden
               (substring line 0 (match-beginning 2)))
              (chat-markdown--inline
               text (chat-markdown--face face base))))))

(defun chat-markdown--render-bullet (line base)
  "Return unordered list item LINE rendered over BASE."
  (save-match-data
    (string-match chat-markdown--bullet-regexp line)
    (let* ((indent (match-string 1 line))
           (bullet (match-string 2 line))
           (checkbox (match-string 3 line))
           (depth (chat-markdown--indent-depth indent))
           ;; The whitespace between the bullet and whatever follows it is
           ;; carried through rather than reconstituted: assuming one space
           ;; is how the space before a checkbox got dropped, which changed
           ;; the buffer text and broke copying.
           (gap (substring line (match-end 2)
                           (or (match-beginning 3) (match-end 0))))
           (box (and checkbox (string-trim-right checkbox)))
           (rest (substring line (match-end 0)))
           (prefix-width (+ (chat-align-width indent)
                            (chat-align-width bullet)
                            (chat-align-width gap)
                            (if checkbox (chat-align-width checkbox) 0))))
      (concat
       indent
       ;; `display' rather than hiding and inserting: the bullet occupies
       ;; the same column either way, and the buffer still holds the `-'
       ;; that was written.
       (propertize bullet
                   'display (chat-markdown--bullet-for depth)
                   'face (chat-markdown--face 'chat-markdown-list-marker
                                              base))
       gap
       (when checkbox
         (concat
          (propertize box
                      'display (if (string-match-p "[xX]" box) "☑" "☐")
                      'face (chat-markdown--face
                             'chat-markdown-list-marker base))
          (substring checkbox (length box))))
       ;; Continuation lines line up with the text, not the bullet.
       (propertize (chat-markdown--inline rest base)
                   'wrap-prefix (make-string prefix-width ?\s))))))

(defun chat-markdown--render-ordered (line base)
  "Return ordered list item LINE rendered over BASE."
  (save-match-data
    (string-match chat-markdown--ordered-regexp line)
    (let* ((indent (match-string 1 line))
           (number (match-string 2 line))
           (rest (substring line (match-end 0)))
           (prefix-width (+ (chat-align-width indent)
                            (chat-align-width number) 1)))
      (concat indent
              (chat-markdown--put number 'chat-markdown-list-marker base)
              " "
              (propertize (chat-markdown--inline rest base)
                          'wrap-prefix (make-string prefix-width ?\s))))))

(defun chat-markdown--render-quote (lines base)
  "Return blockquote LINES rendered over BASE."
  (mapconcat
   (lambda (line)
     (save-match-data
       (if (not (string-match chat-markdown--quote-regexp line))
           (chat-markdown--inline line base)
         (let ((indent (match-string 1 line))
               (marker (match-string 2 line))
               (rest (substring line (match-end 0))))
           (concat indent
                   (chat-markdown--hidden marker)
                   (propertize
                    (chat-markdown--inline
                     rest (chat-markdown--face 'chat-markdown-blockquote
                                               base))
                    'wrap-prefix (make-string
                                  (+ (chat-align-width indent)
                                     (chat-align-width marker))
                                  ?\s)))))))
   lines "\n"))

(defun chat-markdown--render-fence (lines base)
  "Return fenced block LINES rendered over BASE.

An unclosed fence takes the plain code face only.  What is arriving is
incomplete code: running font-lock over it would both fail and be wasted,
since it is about to change."
  (let* ((open (car lines))
         (language (save-match-data
                     (and (string-match chat-markdown--fence-regexp open)
                          (match-string 2 open))))
         (closed (and (cdr lines)
                      (string-match-p chat-markdown--fence-regexp
                                      (car (last lines)))
                      (> (length lines) 1)))
         (body-lines (if closed
                         (butlast (cdr lines))
                       (cdr lines)))
         (body (mapconcat #'identity body-lines "\n"))
         (coloured (and closed (chat-markdown--fontify-code body language))))
    (concat
     ;; The fence line stays visible: it is how the reader sees which
     ;; language a block is in.
     (chat-markdown--put open 'chat-markdown-fence base)
     (when body-lines "\n")
     (if coloured
         (chat-markdown--over-code coloured base)
       (chat-markdown--put body 'chat-code-block-face base))
     (when closed
       (concat (if body-lines "\n" "")
               (chat-markdown--put (car (last lines))
                                   'chat-markdown-fence base))))))

(defun chat-markdown--over-code (coloured base)
  "Return COLOURED code with the block face and BASE underneath.

The mode's own faces stay on top; the block face gives the whole run its
background and its fixed pitch, which the mode does not set."
  (let ((result (copy-sequence coloured))
        (pos 0)
        (length (length coloured)))
    (while (< pos length)
      (let* ((next (or (next-single-property-change pos 'face coloured)
                       length))
             (own (get-text-property pos 'face coloured)))
        (put-text-property pos next 'face
                           (chat-markdown--face
                            own (chat-markdown--face 'chat-code-block-face
                                                     base))
                           result)
        (setq pos next)))
    result))

;; ------------------------------------------------------------------
;; The renderer
;; ------------------------------------------------------------------

(defun chat-markdown--block-at (lines index)
  "Return (KIND . END) for the block starting at INDEX of LINES.

END is one past the block's last line.  One pass, no lookbehind: setext
headings are not recognised, because deciding one needs the line after and
by then the line before has already been drawn."
  (let* ((line (nth index lines))
         (count (length lines)))
    (cond
     ((string-match-p chat-markdown--fence-regexp line)
      ;; To the closing fence, or to the end if it has not arrived.
      (let ((end (1+ index)))
        (while (and (< end count)
                    (not (string-match-p chat-markdown--fence-regexp
                                         (nth end lines))))
          (setq end (1+ end)))
        (cons 'fence (min count (1+ end)))))
     ((string-empty-p (string-trim line)) (cons 'blank (1+ index)))
     ((string-match-p chat-markdown--heading-regexp line)
      (cons 'heading (1+ index)))
     ((string-match-p chat-markdown--rule-regexp line)
      (cons 'rule (1+ index)))
     ((string-match-p chat-markdown--table-row-regexp line)
      (cons 'table (chat-markdown--run lines index
                                       chat-markdown--table-row-regexp)))
     ((string-match-p chat-markdown--quote-regexp line)
      (cons 'quote (chat-markdown--run lines index
                                       chat-markdown--quote-regexp)))
     ((string-match-p chat-markdown--bullet-regexp line)
      (cons 'bullet (1+ index)))
     ((string-match-p chat-markdown--ordered-regexp line)
      (cons 'ordered (1+ index)))
     ((string-match-p chat-markdown--html-regexp line)
      (cons 'html (1+ index)))
     (t (cons 'paragraph (1+ index))))))

(defun chat-markdown--run (lines index regexp)
  "Return one past the last consecutive line from INDEX matching REGEXP."
  (let ((end index)
        (count (length lines)))
    (while (and (< end count)
                (string-match-p regexp (nth end lines)))
      (setq end (1+ end)))
    end))

(defun chat-markdown-render (source &optional base-face)
  "Return SOURCE as Markdown rendered for display, over BASE-FACE.

Pure: the same SOURCE gives the same result, with no reference to a
buffer, a window's width or the time.  That is what makes one renderer
possible for the streaming path, the redraw path, the quick-answer path
and errors -- they are not four callers that must remember to agree, they
are four callers with one input."
  (let* ((lines (chat-markdown--lines source))
         (count (length lines))
         (index 0)
         (pieces nil))
    (while (< index count)
      (let* ((block (chat-markdown--block-at lines index))
             (kind (car block))
             (end (cdr block))
             (block-lines (cl-subseq lines index end)))
        (push
         (pcase kind
           ('fence (chat-markdown--render-fence block-lines base-face))
           ('table (chat-markdown--render-table block-lines base-face))
           ('quote (chat-markdown--render-quote block-lines base-face))
           ('heading (chat-markdown--render-heading (car block-lines)
                                                    base-face))
           ('bullet (chat-markdown--render-bullet (car block-lines)
                                                  base-face))
           ('ordered (chat-markdown--render-ordered (car block-lines)
                                                    base-face))
           ('rule (chat-markdown--render-rule (car block-lines) base-face))
           ('html (chat-markdown--put (car block-lines)
                                      'chat-markdown-html base-face))
           ('blank (chat-markdown--plain (car block-lines) base-face))
           (_ (chat-markdown--inline (car block-lines) base-face)))
         pieces)
        (setq index end)))
    (mapconcat #'identity (nreverse pieces) "\n")))

(defun chat-markdown--render-rule (line base)
  "Return horizontal rule LINE shown as a line, over BASE."
  (propertize line
              'display (make-string (min 40 (max 8 (length line))) ?─)
              'face (chat-markdown--face 'chat-markdown-rule base)))

;; ------------------------------------------------------------------
;; Streaming
;; ------------------------------------------------------------------

(defun chat-markdown-stable-prefix-length (source)
  "Return how much of SOURCE consists only of finished blocks.

Generalises the fence-counting the streaming path already did.  A block is
finished when what ends it has arrived: a closing fence, a blank line
after a paragraph or list, a non-table line after a table.  Everything
after that point is still changing and is re-rendered as it does, which is
what keeps the cost of a piece proportional to the tail rather than to the
whole reply."
  (let* ((lines (chat-markdown--lines source))
         (count (length lines))
         (index 0)
         (stable 0)
         (consumed 0))
    (while (< index count)
      (let* ((block (chat-markdown--block-at lines index))
             (kind (car block))
             (end (cdr block))
             ;; The line count each block occupies, plus the newlines
             ;; between them.
             (width (cl-loop for i from index below end
                             sum (1+ (length (nth i lines))))))
        (setq consumed (+ consumed width))
        (when (chat-markdown--block-finished-p kind lines end count)
          (setq stable consumed))
        (setq index end)))
    (min (length source) stable)))

(defcustom chat-markdown-streaming-tail-max-chars 8000
  "Longest unfinished block still rendered on every piece that arrives.

Beyond it the tail takes a plain face until it finishes.  What is stable
is drawn once, so the cost of a piece is the cost of the tail -- and a
single very long block still arriving, a large code block for instance,
is a tail that would be redrawn from the start on every piece."
  :type 'integer
  :group 'chat-markdown)

(defun chat-markdown-render-tail (tail &optional base-face)
  "Return TAIL rendered over BASE-FACE, or plainly faced when too long.

For the streaming path, which redraws the unfinished block each time
something arrives.  Degrading rather than rendering keeps that bounded;
the block is rendered properly once it finishes, which is when its
styling stops changing anyway."
  (if (> (length tail) chat-markdown-streaming-tail-max-chars)
      (if base-face (propertize tail 'face base-face) tail)
    (chat-markdown-render tail base-face)))

(defun chat-markdown--block-finished-p (kind lines end count)
  "Return non-nil when the block of KIND ending at END is complete."
  (pcase kind
    ('blank t)
    ('heading t)
    ('rule t)
    ('html t)
    ;; A fence is finished only when a closing one arrived, which is what
    ;; the block scan represents by ending before the last line.
    ('fence (and (< end count)
                 (string-match-p chat-markdown--fence-regexp
                                 (nth (1- end) lines))))
    (_ (< end count))))

;; ------------------------------------------------------------------
;; Showing the source
;; ------------------------------------------------------------------

;;;###autoload
(defun chat-markdown-toggle-markers ()
  "Show or hide the Markdown markers in this buffer.

For when the source is what you want to look at.  Hiding is only a
display decision -- the characters never left -- so this is a change to
`buffer-invisibility-spec' and nothing else."
  (interactive)
  (if (memq chat-markdown-invisible-symbol buffer-invisibility-spec)
      (progn (remove-from-invisibility-spec chat-markdown-invisible-symbol)
             (message "Markdown markers shown"))
    (add-to-invisibility-spec chat-markdown-invisible-symbol)
    (message "Markdown markers hidden")))

;;;###autoload
(defun chat-markdown-setup-buffer ()
  "Prepare the current buffer to show rendered Markdown.

Wrapping at word boundaries, and markers hidden if that is the setting.
Deliberately not `visual-line-mode': it rebinds \\`C-a' to
`beginning-of-visual-line', which would take over
`chat-ui-beginning-of-input'."
  (setq-local word-wrap t)
  (when chat-markdown-hide-markers
    (add-to-invisibility-spec chat-markdown-invisible-symbol)))

(provide 'chat-markdown)
;;; chat-markdown.el ends here
