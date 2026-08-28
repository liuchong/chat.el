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
  '((t :inherit (font-lock-function-name-face bold) :height 1.20
       :extend t))
  "A second-level Markdown heading, the highest the prompt asks for."
  :group 'chat-markdown)

(defface chat-markdown-heading-2
  '((t :inherit (font-lock-function-name-face bold) :height 1.10
       :extend t))
  "A third-level Markdown heading."
  :group 'chat-markdown)

(defface chat-markdown-heading-3
  '((t :inherit (font-lock-function-name-face bold) :extend t))
  "A fourth-level Markdown heading."
  :group 'chat-markdown)

(defface chat-markdown-heading-4
  '((t :inherit (shadow bold)))
  "A Markdown heading deeper than the prompt asks for."
  :group 'chat-markdown)

(defface chat-markdown-code
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Code inside a paragraph."
  :group 'chat-markdown)

(defface chat-code-block-face
  '((t :inherit fixed-pitch))
  "A fenced code block.

One face where there were two.  `chat-ui-code-block-face' was identical
and used by the finalize path while this one was used by the insert path,
so the same visual surface was split in half and could drift."
  :group 'chat-markdown)

(defface chat-markdown-fence
  '((t :inherit (fixed-pitch font-lock-comment-face)))
  "The ``` line of a fenced block, kept visible so its language shows."
  :group 'chat-markdown)

(defface chat-markdown-list-marker
  '((t :inherit font-lock-builtin-face :weight bold))
  "The bullet or number introducing a list item."
  :group 'chat-markdown)

(defface chat-markdown-blockquote
  '((t :inherit (font-lock-doc-face italic)))
  "Quoted text."
  :group 'chat-markdown)

(defface chat-markdown-blockquote-border
  '((t :inherit font-lock-comment-face :weight bold))
  "The visible rail beside a blockquote."
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
  '((t :inherit (fixed-pitch shadow)))
  "The dashed row under a table's header."
  :group 'chat-markdown)

(defface chat-markdown-table
  '((t :inherit fixed-pitch))
  "A Markdown table, kept fixed-pitch so columns share one metric."
  :group 'chat-markdown)

(defface chat-markdown-table-header
  '((t :inherit (chat-markdown-table bold)))
  "The header row of a Markdown table."
  :group 'chat-markdown)

(defface chat-markdown-table-border
  '((t :inherit (chat-markdown-table shadow)))
  "Unicode borders displayed over a Markdown table's pipe characters."
  :group 'chat-markdown)

(defface chat-markdown-html
  '((t :inherit shadow))
  "Raw HTML, shown as written and played down."
  :group 'chat-markdown)

(defface chat-markdown-strike
  '((t :strike-through t))
  "Struck-out text."
  :group 'chat-markdown)

(defface chat-markdown-resource
  '((t :inherit (link fixed-pitch)))
  "A linked image or other resource named by Markdown."
  :group 'chat-markdown)

(defface chat-markdown-kbd
  '((t :inherit (fixed-pitch bold) :underline t))
  "Keyboard input carried by a safe HTML tag."
  :group 'chat-markdown)

(defface chat-markdown-mark
  '((t :inherit bold :underline t))
  "Text emphasized by a safe HTML mark tag."
  :group 'chat-markdown)

(defface chat-markdown-footnote
  '((t :inherit link :height 0.8 :raise 0.25))
  "A compact Markdown footnote reference."
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

(defvar chat-markdown-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'chat-markdown-open-link)
    (define-key map [mouse-1] #'chat-markdown-open-link-at-mouse)
    map)
  "Keymap carried by rendered Markdown links and resources.")

(defun chat-markdown--url-at-point ()
  "Return the rendered Markdown URL at point or immediately before it."
  (or (get-text-property (point) 'chat-markdown-url)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) 'chat-markdown-url))))

;;;###autoload
(defun chat-markdown-open-link ()
  "Open the rendered Markdown link at point."
  (interactive)
  (if-let* ((url (chat-markdown--url-at-point)))
      (browse-url url)
    (user-error "No Markdown link at point")))

;;;###autoload
(defun chat-markdown-open-link-at-mouse (event)
  "Open the rendered Markdown link clicked by mouse EVENT."
  (interactive "e")
  (posn-set-point (event-end event))
  (chat-markdown-open-link))

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

(defconst chat-markdown--setext-regexp
  "^[ \t]*\\(=+\\|-+\\)[ \t]*$"
  "The underline completing a setext heading.")

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
    ("_\\([^_\n]+\\)_" italic-underscore))
  "Inline markers, as (REGEXP KIND), tried in order at each position.")

(defconst chat-markdown--inline-start-regexp
  (regexp-opt '("\\" "!" "[" "`" "*" "_" "~" "<"
                "http://" "https://" "ftp://"))
  "Text that can begin an inline construct.")

(defconst chat-markdown--escape-regexp
  "\\\\\\([^[:alnum:][:space:]]\\)"
  "A backslash escape for Markdown punctuation: 1 the literal character.")

(defconst chat-markdown--image-regexp
  "!\\[\\([^]\n]*\\)\\](\\([^)\n]*\\))"
  "An image: 1 the alt text, 2 the address.")

(defconst chat-markdown--link-regexp
  "\\[\\([^]\n]*\\)\\](\\([^)\n]*\\))"
  "A link: 1 the text, 2 the address.")

(defconst chat-markdown--url-regexp
  "\\(?:https?\\|ftp\\)://[^ \t\n<>\"'()]+"
  "A bare URL.")

(defconst chat-markdown--autolink-regexp
  "<\\(\\(?:https?\\|ftp\\)://[^ \t\n<>]+\\)>"
  "A URL autolink: 1 the address.")

(defconst chat-markdown--footnote-regexp
  "\\[\\^\\([^]\n]+\\)\\]"
  "A footnote reference: 1 its label.")

(defconst chat-markdown--html-pair-regexp
  (concat
   "<\\(strong\\|b\\|em\\|i\\|code\\|kbd\\|mark\\|del\\|s\\|sub\\|sup"
   "\\|summary\\)\\(?:[ \t]+[^>\n]*\\)?>\\(.*?\\)</\\1[ \t]*>")
  "A safe paired HTML tag: 1 the tag, 2 its body.")

(defconst chat-markdown--html-break-regexp
  "<br\\(?:[ \t]+[^>\n]*\\)?/?>"
  "A safe HTML line break.")

(defconst chat-markdown--html-link-regexp
  "<a\\(?:[ \t]+[^>\n]*\\)?>\\(.*?\\)</a[ \t]*>"
  "A safe HTML link: 1 its body; attributes are read separately.")

(defconst chat-markdown--html-image-regexp
  "<img\\(?:[ \t]+[^>\n]*\\)?/?>"
  "A safe HTML image resource.")

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
      (let ((start (string-match chat-markdown--inline-start-regexp text pos)))
        (if (null start)
            (progn
              (push (chat-markdown--plain (substring text pos) base) pieces)
              (setq pos length))
          (when (> start pos)
            (push (chat-markdown--plain (substring text pos start) base)
                  pieces))
          (let ((best (chat-markdown--match-candidate text start)))
            (if best
                (progn
                  (push (chat-markdown--render-inline best base) pieces)
                  (setq pos (max (plist-get best :end) (1+ start))))
              (push (chat-markdown--plain (substring text start (1+ start))
                                          base)
                    pieces)
              (setq pos (1+ start)))))))
    (apply #'concat (nreverse pieces))))

(defun chat-markdown--plain (text base)
  "Return TEXT carrying only BASE."
  (if base (propertize text 'face base) text))

(defun chat-markdown--match (regexp text pos kind)
  "Return REGEXP's match at POS in TEXT as a plist, or nil."
  (save-match-data
    (when (eq pos (string-match regexp text pos))
      (list :kind kind
            :start (match-beginning 0)
            :end (match-end 0)
            :whole (match-string 0 text)
            :one (match-string 1 text)
            :two (match-string 2 text)
            :one-start (match-beginning 1)
            :two-start (match-beginning 2)
            :two-end (match-end 2)))))

(defun chat-markdown--prefix-at-p (prefix text pos &optional fold-case)
  "Return non-nil when PREFIX occurs in TEXT at POS.

FOLD-CASE makes the small comparison case-insensitive."
  (let ((end (+ pos (length prefix))))
    (and (<= end (length text))
         (string-equal (if fold-case (downcase prefix) prefix)
                       (if fold-case
                           (downcase (substring text pos end))
                         (substring text pos end))))))

(defun chat-markdown--match-candidate (text pos)
  "Return the inline construct that can begin at POS in TEXT, or nil.

Dispatching from the opening bytes avoids searching every regexp through the
remaining line after every match."
  (let ((char (aref text pos)))
    (pcase char
      (?\\ (chat-markdown--match chat-markdown--escape-regexp
                                  text pos 'escape))
      (?! (and (chat-markdown--prefix-at-p "![" text pos)
               (chat-markdown--match chat-markdown--image-regexp
                                     text pos 'image)))
      (?\[ (if (chat-markdown--prefix-at-p "[^" text pos)
              (chat-markdown--match chat-markdown--footnote-regexp
                                    text pos 'footnote)
            (chat-markdown--match chat-markdown--link-regexp
                                  text pos 'link)))
      (?` (chat-markdown--match (caar chat-markdown--inline-rules)
                                text pos 'code))
      (?* (cond
           ((chat-markdown--prefix-at-p "***" text pos)
            (chat-markdown--match (car (nth 1 chat-markdown--inline-rules))
                                  text pos 'bold-italic))
           ((chat-markdown--prefix-at-p "**" text pos)
            (chat-markdown--match (car (nth 3 chat-markdown--inline-rules))
                                  text pos 'bold))
           (t (chat-markdown--match
               (car (nth 6 chat-markdown--inline-rules)) text pos 'italic))))
      (?_ (cond
           ((chat-markdown--prefix-at-p "___" text pos)
            (chat-markdown--match (car (nth 2 chat-markdown--inline-rules))
                                  text pos 'bold-italic))
           ((chat-markdown--prefix-at-p "__" text pos)
            (chat-markdown--match (car (nth 4 chat-markdown--inline-rules))
                                  text pos 'bold))
           ((chat-markdown--underscore-open-p text pos)
            (chat-markdown--match (car (nth 7 chat-markdown--inline-rules))
                                  text pos 'italic-underscore))))
      (?~ (and (chat-markdown--prefix-at-p "~~" text pos)
               (chat-markdown--match (car (nth 5 chat-markdown--inline-rules))
                                     text pos 'strike)))
      (?< (cond
           ((or (chat-markdown--prefix-at-p "<http" text pos t)
                (chat-markdown--prefix-at-p "<ftp" text pos t))
            (chat-markdown--match chat-markdown--autolink-regexp
                                  text pos 'autolink))
           ((chat-markdown--prefix-at-p "<a" text pos t)
            (chat-markdown--match chat-markdown--html-link-regexp
                                  text pos 'html-link))
           ((chat-markdown--prefix-at-p "<img" text pos t)
            (chat-markdown--match chat-markdown--html-image-regexp
                                  text pos 'html-image))
           ((chat-markdown--prefix-at-p "<br" text pos t)
            (chat-markdown--match chat-markdown--html-break-regexp
                                  text pos 'html-break))
           (t (chat-markdown--match chat-markdown--html-pair-regexp
                                    text pos 'html-pair))))
      ((or ?h ?H ?f ?F)
       (and (or (chat-markdown--prefix-at-p "http://" text pos t)
                (chat-markdown--prefix-at-p "https://" text pos t)
                (chat-markdown--prefix-at-p "ftp://" text pos t))
            (chat-markdown--match chat-markdown--url-regexp text pos 'url))))))

(defun chat-markdown--underscore-open-p (text pos)
  "Return non-nil when an underscore at POS may open emphasis in TEXT."
  (or (zerop pos)
      (not (string-match-p "[[:alnum:]_]"
                           (string (aref text (1- pos)))))))

(defun chat-markdown--html-attribute (tag name)
  "Return NAME's value from the single HTML TAG, or nil.

Only quoted and unquoted scalar attributes are recognized.  This is not an
HTML parser: it is the deliberately small boundary used by the safe `a' and
`img' mappings, while every other tag remains inert text."
  (let ((case-fold-search t)
        (regexp (concat "\\(?:\\`\\|[ \t]\\)" (regexp-quote name)
                        "[ \t]*=[ \t]*\\(?:\"\\([^\"]*\\)\""
                        "\\|'\\([^']*\\)'\\|\\([^ \t>]+\\)\\)")))
    (when (string-match regexp tag)
      (or (match-string 1 tag)
          (match-string 2 tag)
          (match-string 3 tag)))))

(defun chat-markdown--render-resource (source label url base syntax)
  "Render SOURCE as an actionable resource named LABEL at URL.

SYNTAX records which source notation supplied it.  The descriptor lets a UI
materialize a preview later without giving this pure renderer I/O work."
  (let* ((label (if (string-empty-p (or label ""))
                    (or url "image")
                  label))
         (shown (format "▧ %s" label)))
    (chat-markdown--put
     source 'chat-markdown-resource base
     'display shown
     'chat-markdown-url url
     'chat-markdown-resource
     (list :kind 'image :source url :label label :syntax syntax)
     'keymap chat-markdown-link-map
     'mouse-face 'highlight
     'help-echo (or url ""))))

(defun chat-markdown--render-inline (match base)
  "Return the rendering of MATCH over BASE."
  (let ((kind (plist-get match :kind))
        (whole (plist-get match :whole))
        (one (plist-get match :one))
        (two (plist-get match :two)))
    (pcase kind
      ('escape
       (concat (chat-markdown--hidden "\\")
               (chat-markdown--plain (or one "") base)))
      ('image
       ;; The core renderer never fetches or decodes a resource.  It exposes
       ;; a compact, actionable node that a UI may materialize later without
       ;; putting network or image work on the streaming render path.
       (chat-markdown--render-resource whole one two base 'markdown))
      ('link
       (concat (chat-markdown--hidden (concat "[" ))
               (chat-markdown--put (or one "") 'chat-markdown-link base
                                   'chat-markdown-url two
                                   'keymap chat-markdown-link-map
                                   'mouse-face 'highlight
                                   'help-echo (or two ""))
               (chat-markdown--hidden (concat "](" (or two "") ")"))))
      ('autolink
       (concat (chat-markdown--hidden "<")
               (chat-markdown--put (or one "") 'chat-markdown-link base
                                   'chat-markdown-url one
                                   'keymap chat-markdown-link-map
                                   'mouse-face 'highlight
                                   'help-echo (or one ""))
               (chat-markdown--hidden ">")))
      ('url
       (chat-markdown--put whole 'chat-markdown-link base
                           'chat-markdown-url whole
                           'keymap chat-markdown-link-map
                           'mouse-face 'highlight
                           'help-echo whole))
      ('footnote
       (concat (chat-markdown--hidden "[^")
               (chat-markdown--put (or one "") 'chat-markdown-footnote base
                                   'chat-markdown-footnote one)
               (chat-markdown--hidden "]")))
      ('html-break
       (chat-markdown--put whole 'chat-markdown-html base 'display "\n"))
      ('html-image
       (let ((url (chat-markdown--html-attribute whole "src")))
         (if url
             (chat-markdown--render-resource
              whole (chat-markdown--html-attribute whole "alt")
              url base 'html)
           (chat-markdown--put whole 'chat-markdown-html base))))
      ('html-link
       (let ((url (chat-markdown--html-attribute whole "href")))
         (if (not url)
             (chat-markdown--put whole 'chat-markdown-html base)
           (let* ((start (plist-get match :start))
                  (body-start (- (plist-get match :one-start) start))
                  (body-end (+ body-start (length (or one ""))))
                  (body (chat-markdown--add-face
                         (chat-markdown--inline (or one "") base)
                         'chat-markdown-link)))
             (when (> (length body) 0)
               (add-text-properties
                0 (length body)
                `(chat-markdown-url ,url
                  keymap ,chat-markdown-link-map
                  mouse-face highlight
                  help-echo ,url)
                body))
             (concat
              (chat-markdown--hidden (substring whole 0 body-start))
              body
              (chat-markdown--hidden (substring whole body-end)))))))
      ('html-pair
       (let* ((start (plist-get match :start))
              (body-start (- (plist-get match :two-start) start))
              (body-end (- (plist-get match :two-end) start))
              (face (chat-markdown--html-inline-face one)))
         (concat (chat-markdown--hidden (substring whole 0 body-start))
                 (chat-markdown--inline-body (or two "") face base)
                 (chat-markdown--hidden (substring whole body-end)))))
      (_
       (let* ((marker-length (/ (- (length whole) (length (or one ""))) 2))
              (marker (substring whole 0 marker-length)))
         (concat (chat-markdown--hidden marker)
                 (chat-markdown--inline-body
                  (or one "") (chat-markdown--inline-face kind) base)
                 (chat-markdown--hidden marker)))))))

(defun chat-markdown--html-inline-face (tag)
  "Return the Markdown display face for safe HTML TAG."
  (pcase (downcase (or tag ""))
    ((or "strong" "b" "summary") 'bold)
    ((or "em" "i") 'italic)
    ("code" 'chat-markdown-code)
    ("kbd" 'chat-markdown-kbd)
    ("mark" 'chat-markdown-mark)
    ((or "del" "s") 'chat-markdown-strike)
    ((or "sub" "sup") 'chat-markdown-footnote)
    (_ 'chat-markdown-html)))

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
  "Return the cells of table LINE without splitting escaped or code pipes."
  (let* ((trimmed (string-trim line))
         (inner (string-trim trimmed "^|" "|$"))
         (cells nil)
         (current nil)
         (code-run nil)
         (index 0)
         (length (length inner)))
    (while (< index length)
      (let ((char (aref inner index)))
        (cond
         ;; Keep escapes in the source cell.  The inline renderer hides the
         ;; slash later, while the splitter only needs to know this pipe is
         ;; data rather than a column boundary.
         ((and (eq char ?\\) (< (1+ index) length))
          (push (substring inner index (+ index 2)) current)
          (setq index (+ index 2)))
         ((eq char ?`)
          (let ((end index))
            (while (and (< end length) (eq (aref inner end) ?`))
              (setq end (1+ end)))
            (let ((run (substring inner index end)))
              (push run current)
              (cond ((null code-run) (setq code-run run))
                    ((equal run code-run) (setq code-run nil)))
              (setq index end))))
         ((and (eq char ?|) (null code-run))
          (push (string-trim (apply #'concat (nreverse current))) cells)
          (setq current nil
                index (1+ index)))
         (t
          (push (string char) current)
          (setq index (1+ index))))))
    (push (string-trim (apply #'concat (nreverse current))) cells)
    (nreverse cells)))

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
         ;; Width belongs to what reaches the screen, not to the source.
         ;; `main` is six source columns including its hidden backticks but
         ;; four visible columns; measuring the source moves every border
         ;; on that row two columns to the left.
         (visible-data
          (mapcar (lambda (row)
                    (mapcar (lambda (cell)
                              (chat-markdown--screen-text
                               (chat-markdown--inline cell base)))
                            row))
                  data))
         (widths (chat-align-column-widths visible-data))
         (widths (chat-markdown--fit-widths widths))
         (output nil))
    (cl-loop for row in rows
             for index from 0
             do (push
                 (if (eql index separator-index)
                     (chat-markdown--render-separator row widths base)
                   (chat-markdown--render-table-row
                    row widths alignments base
                    (and separator-index (< index separator-index))))
                 output))
    (mapconcat #'identity (nreverse output) "\n")))

(defun chat-markdown--table-border (source shown base)
  "Return SOURCE displayed as table border SHOWN over BASE."
  (propertize source
              'display shown
              'face (chat-markdown--face 'chat-markdown-table-border base)))

(defun chat-markdown--table-aligned-border (source shown column base)
  "Return SOURCE with SHOWN placed at absolute table COLUMN over BASE.

SOURCE begins with one padding space followed by its Markdown pipe.
The space stretches to COLUMN in units of the table face's character
width, so the pipe no longer depends on the pixel widths of the cell's
glyphs or their fallback fonts."
  (let ((result (copy-sequence source))
        (face (chat-markdown--face 'chat-markdown-table-border base)))
    (add-text-properties
     0 1 `(display (space :align-to (,column . width)) face ,face) result)
    (add-text-properties 1 2 `(display ,shown face ,face) result)
    result))

(defun chat-markdown--add-face (text face)
  "Return TEXT with FACE before its existing faces.

FACE owns structural metrics such as a table's fixed-pitch family, so it
must outrank channel and inline faces.  Attributes it does not specify,
such as foreground colour, still fall through to those existing faces."
  (let ((result (copy-sequence text)))
    (when (> (length result) 0)
      (add-face-text-property 0 (length result) face nil result))
    result))

(defun chat-markdown--render-table-row
    (cells widths alignments base header-p)
  "Return CELLS as one fixed-pitch table row.

WIDTHS and ALIGNMENTS lay out the cells.  BASE carries the transcript
channel and HEADER-P adds the table-header face.  The pipe characters
stay in the string while `display' shows box-drawing borders, so copying
the row still gives valid Markdown."
  (let ((parts (list (chat-markdown--table-border "| " "│ " base)))
        ;; The first cell begins after the leading pipe and one space.
        (screen-column 2)
        (count (length cells)))
    (cl-loop for cell in cells
             for width in widths
             for alignment in alignments
             for index from 0
             do
             (push (chat-markdown--pad-visible
                    (chat-markdown--table-cell cell width base)
                    width alignment)
                   parts)
             ;; Leave one visual column before the pipe.  `:align-to'
             ;; makes this an absolute destination rather than a guess
             ;; expressed as ordinary spaces.
             (setq screen-column (+ screen-column width 1))
             (push (chat-markdown--table-aligned-border
                    (if (= index (1- count)) " |" " | ")
                    "│" screen-column base)
                   parts)
             ;; The pipe itself and the following source space occupy
             ;; two columns before the next cell begins.
             (setq screen-column (+ screen-column 2)))
    (chat-markdown--add-face
     (apply #'concat (nreverse parts))
     (if header-p 'chat-markdown-table-header 'chat-markdown-table))))

(defun chat-markdown--table-cell (cell width base)
  "Return CELL rendered for a column of WIDTH over BASE."
  (chat-markdown--truncate-visible
   (chat-markdown--inline cell base) width))

(defun chat-markdown--screen-text (text)
  "Return the text TEXT contributes to the screen.

Invisible Markdown markers contribute nothing and string-valued
`display' properties contribute their replacement."
  (let ((pieces nil)
        (position 0)
        (length (length text)))
    (while (< position length)
      (let* ((next (min (or (next-single-property-change
                             position 'invisible text) length)
                        (or (next-single-property-change
                             position 'display text) length)))
             (display (get-text-property position 'display text)))
        (unless (get-text-property position 'invisible text)
          (push (if (stringp display)
                    display
                  (substring-no-properties text position next))
                pieces))
        (setq position next)))
    (apply #'concat (nreverse pieces))))

(defun chat-markdown--visible-width (text)
  "Return the display width of propertized TEXT."
  (string-width (chat-markdown--screen-text text)))

(defun chat-markdown--pad-visible (text width alignment)
  "Return TEXT padded to visible WIDTH according to ALIGNMENT."
  (let ((short (- width (chat-markdown--visible-width text))))
    (if (<= short 0)
        text
      (pcase alignment
        ('right (concat (make-string short ?\s) text))
        ('center (let ((left (/ short 2)))
                   (concat (make-string left ?\s) text
                           (make-string (- short left) ?\s))))
        (_ (concat text (make-string short ?\s)))))))

(defun chat-markdown--align-visible-row
    (cells widths alignments separator)
  "Return CELLS aligned by visible WIDTHS and joined by SEPARATOR."
  (let ((index -1))
    (mapconcat
     (lambda (cell)
       (setq index (1+ index))
       (chat-markdown--pad-visible cell (or (nth index widths) 0)
                                   (nth index alignments)))
     cells separator)))

(defun chat-markdown--truncate-visible (text width)
  "Return TEXT cut to visible WIDTH without losing hidden markers.

When inline code or a link is shortened, its closing marker still has to
survive or the copied table stops being valid Markdown."
  (if (<= (chat-markdown--visible-width text) width)
      text
    (let ((room (max 0 (1- width)))
          (taken 0)
          (position 0)
          (length (length text))
          (cut nil)
          (pieces nil))
      (while (< position length)
        (let* ((next (min (or (next-single-property-change
                               position 'invisible text) length)
                          (or (next-single-property-change
                               position 'display text) length)))
               (invisible (get-text-property position 'invisible text))
               (display (get-text-property position 'display text)))
          (cond
           (invisible
            (push (substring text position next) pieces))
           (cut nil)
           ((stringp display)
            (let ((display-width (string-width display)))
              (if (<= (+ taken display-width) room)
                  (progn
                    (push (substring text position next) pieces)
                    (setq taken (+ taken display-width)))
                (push "…" pieces)
                (setq cut t))))
           (t
            (while (and (< position next) (not cut))
              (let ((char-width (char-width (aref text position))))
                (if (<= (+ taken char-width) room)
                    (progn
                      (push (substring text position (1+ position)) pieces)
                      (setq taken (+ taken char-width)))
                  (push "…" pieces)
                  (setq cut t))
                (setq position (1+ position))))))
          (setq position next)))
      (apply #'concat (nreverse pieces)))))

(defun chat-markdown--fit-widths (widths)
  "Return WIDTHS reduced to fit `chat-markdown-table-max-width'.

Narrowed proportionally rather than by dropping columns: a table missing
its last two columns looks like a table that had three."
  (let ((fixed (+ 4 (* 3 (max 0 (1- (length widths)))))))
    (chat-align-fit-widths widths chat-markdown-table-max-width fixed)))

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
         (source (concat "| " (mapconcat #'identity dashes " | ") " |"))
         (rule (concat
                "├─"
                (mapconcat (lambda (width)
                             (make-string (max 1 width) ?─))
                           (seq-take widths (length cells))
                           "─┼─")
                "─┤")))
    (propertize source
                'display rule
                'face (chat-markdown--face
                       'chat-markdown-table-separator base))))

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
           (raw (match-string 2 line))
           (content-start (match-beginning 2))
           (closing-at (and (string-match "[ \t]+#+[ \t]*\\'" raw)
                            (match-beginning 0)))
           (text (if closing-at (substring raw 0 closing-at) raw))
           (closing (and closing-at (substring raw closing-at)))
           (level (length hashes))
           (face (pcase level
                   ((or 1 2) 'chat-markdown-heading-1)
                   (3 'chat-markdown-heading-2)
                   (4 'chat-markdown-heading-3)
                   (_ 'chat-markdown-heading-4))))
      ;; The space after the hashes goes too, or the heading sits one
      ;; column in from everything else.
      (concat (chat-markdown--hidden
               (substring line 0 content-start))
              (chat-markdown--inline
               text (chat-markdown--face face base))
              (and closing (chat-markdown--hidden closing))))))

(defun chat-markdown--render-setext (lines base)
  "Return two-line setext heading LINES rendered over BASE."
  (let* ((title (car lines))
         (underline (cadr lines))
         (face (if (string-match-p "=" underline)
                   'chat-markdown-heading-1
                 'chat-markdown-heading-2)))
    (concat (chat-markdown--inline title (chat-markdown--face face base))
            (chat-markdown--hidden (concat "\n" underline)))))

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
                   (propertize
                    marker
                    'display "▎ "
                    'face (chat-markdown--face
                           'chat-markdown-blockquote-border base))
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
     ;; The source fence stays in the string; a labelled rail is the view.
     ;; That keeps the language visible without making raw backticks the
     ;; strongest visual feature of a code block.
     (chat-markdown--put
      open 'chat-markdown-fence base
      'display (concat "┌ " (if (string-empty-p (or language ""))
                                "code"
                              language)))
     (when body-lines "\n")
     (if coloured
         (chat-markdown--over-code coloured base)
       (chat-markdown--code-rail
        (chat-markdown--put body 'chat-code-block-face base) base))
     (when closed
       (concat (if body-lines "\n" "")
               (chat-markdown--put
                (car (last lines)) 'chat-markdown-fence base
                'display "└"))))))

(defun chat-markdown--code-rail (text base)
  "Return code TEXT with a visible left rail over BASE."
  (let* ((rail (propertize "│ " 'face
                           (chat-markdown--face 'chat-markdown-fence base)))
         (result (copy-sequence text)))
    (when (> (length result) 0)
      (add-text-properties 0 (length result)
                           (list 'line-prefix rail 'wrap-prefix rail)
                           result))
    result))

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
    (chat-markdown--code-rail result base)))

;; ------------------------------------------------------------------
;; The renderer
;; ------------------------------------------------------------------

(defun chat-markdown--block-at (lines index)
  "Return (KIND . END) for the block starting at INDEX of LINES.

END is one past the block's last line."
  (let* ((line (nth index lines))
         (count (length lines))
         (next (and (< (1+ index) count) (nth (1+ index) lines))))
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
     ((and next
           (string-match-p chat-markdown--setext-regexp next)
           (not (or (string-match-p chat-markdown--fence-regexp line)
                    (string-match-p chat-markdown--heading-regexp line)
                    (string-match-p chat-markdown--rule-regexp line)
                    (string-match-p chat-markdown--bullet-regexp line)
                    (string-match-p chat-markdown--ordered-regexp line)
                    (string-match-p chat-markdown--quote-regexp line)
                    (string-match-p chat-markdown--table-row-regexp line)
                    (string-match-p chat-markdown--html-regexp line))))
      (cons 'setext (+ index 2)))
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
           ('setext (chat-markdown--render-setext block-lines base-face))
           ('bullet (chat-markdown--render-bullet (car block-lines)
                                                  base-face))
           ('ordered (chat-markdown--render-ordered (car block-lines)
                                                    base-face))
           ('rule (chat-markdown--render-rule (car block-lines) base-face))
           ('html (chat-markdown--render-html-line (car block-lines)
                                                   base-face))
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

(defun chat-markdown--render-html-line (line base)
  "Render safe semantics in HTML LINE and dim everything else."
  (let ((trimmed (string-trim line)))
    (cond
     ((string-match-p "\\`<details\\(?:[ \t]+[^>]*\\)?>\\'" trimmed)
      (chat-markdown--put line 'chat-markdown-html base
                          'display "▾ Details"))
     ((string-match-p "\\`</details[ \t]*>\\'" trimmed)
      (chat-markdown--hidden line))
     ((or (string-match-p chat-markdown--html-pair-regexp line)
          (string-match-p chat-markdown--html-link-regexp line)
          (string-match-p chat-markdown--html-image-regexp line)
          (string-match-p chat-markdown--html-break-regexp line)
          (string-match-p chat-markdown--autolink-regexp line))
      (chat-markdown--inline line base))
     (t (chat-markdown--put line 'chat-markdown-html base)))))

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
  "Return TAIL rendered over BASE-FACE with bounded streaming detail.

For the streaming path, which redraws the unfinished block each time
something arrives.  A long unfinished block skips block layout but keeps
the linear inline renderer, so emphasis such as **status** does not turn
back into raw source while the model is still answering.  The complete
block receives full layout once it finishes."
  (if (> (length tail) chat-markdown-streaming-tail-max-chars)
      (chat-markdown--inline tail base-face)
    (chat-markdown-render tail base-face)))

(defun chat-markdown--block-finished-p (kind lines end count)
  "Return non-nil when the block of KIND ending at END is complete."
  (pcase kind
    ('blank t)
    ('heading t)
    ('setext t)
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
