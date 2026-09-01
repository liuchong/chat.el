;;; chat-mdp.el --- Reading and writing MDP payloads -*- lexical-binding: t; -*-

;;; Commentary:

;; MDP is a data interchange format that happens to be Markdown: one text,
;; two readings.  A person reads a heading, a list of fields and a table; a
;; program reads an object, its keys and an array.  Everything outside a small
;; whitelist -- prose, `###' headings, emphasis, fenced blocks -- is a comment
;; and cannot affect what the program sees.
;;
;; That last property is why it is here.  A model asked for JSON produces
;; JSON with an apology in front of it, and the repair function that copes
;; with that is a pile of guesses about how models break.  A model asked for
;; MDP can put the apology in the payload, because the format says prose is a
;; comment.  The tolerance comes from the specification rather than from
;; experience of failures.
;;
;; This module is a codec first.  Displaying MDP is mostly free: a payload is
;; valid Markdown, so `chat-markdown.el' renders it as a document with no
;; knowledge of MDP at all.  What only this module can do is turn the text
;; into Elisp values -- and show what it actually extracted, which is the only
;; way to check that the two readings agree.  A payload that looks right and
;; parses one field short has no other symptom.
;;
;; It does not require the renderer.  A protocol module whose usability
;; depends on a display layer being loaded goes blind in batch mode, and the
;; dependency points the wrong way besides.  The one thing the two share is
;; column alignment, from `chat-align.el' below both, because a Chinese table
;; that lines up in one view and not the other is worse than one that lines up
;; in neither.
;;
;; Written from the protocol specification, not linked against its Rust
;; implementation.  Spec 006.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-align)

(defgroup chat-mdp nil
  "Reading, writing and inspecting bounded MDP payloads."
  :group 'chat)

(defcustom chat-mdp-max-input-chars (* 2 1024 1024)
  "Largest MDP payload accepted by `chat-mdp-parse'.

MDP enters through model output, so parsing needs a deterministic memory
boundary.  Two MiB is far above an ordinary tool payload while keeping a
malformed response from becoming an unbounded allocation."
  :type 'integer
  :group 'chat-mdp)

(defcustom chat-mdp-max-depth 128
  "Deepest container nesting accepted by `chat-mdp-parse'."
  :type 'integer
  :group 'chat-mdp)

(defcustom chat-mdp-machine-table-max-width 100
  "Maximum display width of a table in the MDP machine view.

The document view has its own independently configurable width.  This limit
keeps the diagnostic view readable beside a chat transcript without changing
the parsed value or the encoded payload."
  :type 'integer
  :group 'chat-mdp)

;; ------------------------------------------------------------------
;; The internal representation
;; ------------------------------------------------------------------

;; Objects are alists with string keys in document order.  Arrays are lists.
;; Strings and numbers are themselves.
;;
;; The rest needs keywords, because `nil' in Elisp is false, the empty list
;; and the empty value all at once, while MDP has `false', `[]', `null' and
;; `{}' as four distinct values.  Representing any of them as `nil' means
;; `encode' cannot tell which one to write, and the round trip stops being
;; lossless -- which is what makes this a set of decisions rather than a
;; matter of taste.

(defconst chat-mdp-true t
  "MDP `true'.")

(defconst chat-mdp-false :false
  "MDP `false', which cannot be `nil' because `nil' is also the empty list.")

(defconst chat-mdp-null :null
  "MDP `null', distinct from `false' and from an empty container.")

(defconst chat-mdp-empty-object :empty-object
  "MDP `{}', which cannot be `nil' because an empty alist is also `nil'.")

;; An empty array is `nil': there is nothing else it could be, and `{}'
;; having its own keyword is what keeps the two apart.

;; ------------------------------------------------------------------
;; Errors
;; ------------------------------------------------------------------

(defconst chat-mdp-error-codes
  '((MDP-E001 . "a level-two heading before any level-one heading")
    (MDP-E002 . "object content and a table in the same place")
    (MDP-E003 . "the same key twice in one object")
    (MDP-E004 . "a table row with the wrong number of cells")
    (MDP-E005 . "a table header cell that is empty or repeated")
    (MDP-E006 . "a table or element marker with nothing to belong to")
    (MDP-E007 . "an empty heading or key")
    (MDP-E009 . "a tab indent, a skipped level, or depth with no container")
    (MDP-E010 . "the payload exceeds its configured size or nesting budget"))
  "The illegal constructions, and what each one means.

Every one has to be detectable and has to carry a line number, because
what a rejection is for is telling the model which line was wrong.
\"Parse failed\" gives it nothing to correct.")

(defun chat-mdp-error-p (value)
  "Return non-nil when VALUE is a parse failure rather than a payload.

Unambiguous because a parsed value is a string, a number, one of the four
keywords, an alist or a list of those: none of them is a list beginning
with the symbol `error'."
  (and (consp value) (eq (car value) 'error)))

(defun chat-mdp-error-code (error)
  "Return the code of ERROR."
  (nth 1 error))

(defun chat-mdp-error-line (error)
  "Return the one-based line ERROR was found on."
  (nth 2 error))

(defun chat-mdp-error-message (error)
  "Return ERROR as a sentence naming the code and the line."
  (format "%s at line %s: %s"
          (chat-mdp-error-code error)
          (chat-mdp-error-line error)
          (or (cdr (assq (chat-mdp-error-code error)
                         chat-mdp-error-codes))
              "illegal construction")))

(defun chat-mdp--fail (code line)
  "Abandon the parse with CODE, found on LINE."
  (throw 'chat-mdp-error (list 'error code line)))

;; ------------------------------------------------------------------
;; Type inference
;; ------------------------------------------------------------------

(defconst chat-mdp--number-regexp
  "\\`-?\\(?:0\\|[1-9][0-9]*\\)\\(?:\\.[0-9]+\\)?\\(?:[eE][+-]?[0-9]+\\)?\\'"
  "JSON's number grammar, which is MDP's.

Deliberately not looser: `001', `+5', `.5' and `1.' are strings, so a
zero-padded identifier stays an identifier.")

(defun chat-mdp--infer (text)
  "Return the MDP value TEXT denotes.

The ladder from the specification, first match winning: a quoted string,
then a number, then the lowercase literals, then the two empty
containers, then the text itself.  `True' and `FALSE' are strings,
because case-insensitive literals would make `NULL' -- a perfectly good
identifier -- into an absent value."
  (let ((text (or text "")))
    (cond
     ;; An unclosed quote is not a quoted string; it falls through and ends
     ;; up as its own text, which is the only reading that loses nothing.
     ((and (>= (length text) 2)
           (string-prefix-p "\"" text)
           (string-suffix-p "\"" text))
      (chat-mdp--unescape (substring text 1 -1)))
     ((string-match-p chat-mdp--number-regexp text)
      (string-to-number text))
     ((equal text "true") chat-mdp-true)
     ((equal text "false") chat-mdp-false)
     ((or (equal text "null") (string-empty-p text)) chat-mdp-null)
     ((equal text "{}") chat-mdp-empty-object)
     ((equal text "[]") nil)
     (t text))))

(defun chat-mdp--unescape (text)
  "Return TEXT with the five escape sequences resolved.

Anything else after a backslash is kept as written, both characters:
refusing it would make the format brittle over a Windows path, and
resolving it would invent an escape the specification does not have."
  (let ((out nil)
        (index 0)
        (length (length text)))
    (while (< index length)
      (let ((char (aref text index)))
        (if (and (eq char ?\\) (< (1+ index) length))
            (let ((next (aref text (1+ index))))
              (push (pcase next
                      (?\" "\"")
                      (?\\ "\\")
                      (?n "\n")
                      (?t "\t")
                      (?r "\r")
                      (_ (string char next)))
                    out)
              (setq index (+ index 2)))
          (push (string char) out)
          (setq index (1+ index)))))
    (apply #'concat (nreverse out))))

(defun chat-mdp--escape (text)
  "Return TEXT with the five escape sequences applied."
  (let ((out nil))
    (dolist (char (string-to-list text))
      (push (pcase char
              (?\" "\\\"")
              (?\\ "\\\\")
              (?\n "\\n")
              (?\t "\\t")
              (?\r "\\r")
              (_ (string char)))
            out))
    (apply #'concat (nreverse out))))

;; ------------------------------------------------------------------
;; Classifying lines
;; ------------------------------------------------------------------

(defconst chat-mdp--fence-regexp "\\` \\{0,3\\}\\(```+\\|~~~+\\)"
  "A line opening or closing a fenced block.")

(defconst chat-mdp--heading-regexp
  "\\` \\{0,3\\}\\(#\\{1,6\\}\\)\\(?:[ \t]+\\(.*?\\)\\)?[ \t]*\\'"
  "An ATX heading: 1 the hashes, 2 the text with any closing hashes.")

(defconst chat-mdp--item-regexp "\\`\\([ \t]*\\)- \\(.*\\)\\'"
  "A dash list item: 1 the indent, 2 everything after the dash.

Tabs are matched here and refused afterwards.  Only spaces indent a
structure line, but excluding tabs from the pattern would make a
tab-indented field a comment, and silently ignoring a line the author
meant as data is worse than saying which line was wrong.")

(defconst chat-mdp--table-regexp "\\`\\([ \t]*\\)|.*|[ \t]*\\'"
  "A table row: 1 the indent, tabs matched and refused as above.")

(defconst chat-mdp--table-separator-regexp "\\`[ \t]*|[ \t:|-]+|[ \t]*\\'"
  "The dashed row under a table header.")

(defun chat-mdp--indent-level (indent)
  "Return the nesting level INDENT spaces denote: two spaces per level."
  (/ (length indent) 2))

(defun chat-mdp--tab-indented-p (line)
  "Return non-nil when LINE's leading whitespace contains a tab."
  (save-match-data
    (and (string-match "\\`[ \t]*" line)
         (string-match-p "\t" (match-string 0 line)))))

(defun chat-mdp--classify (lines)
  "Return the structural items among LINES, in order.

One pass.  Fenced blocks are skipped whole before anything else is
looked at, which is what lets a payload contain an example of itself --
the rule that decides whether a model can safely paste a sample into a
reply.  Everything that matches nothing is a comment, and a comment
cannot fail: outside the whitelist there is no third state between
structure and prose."
  (let ((items nil)
        (fence nil)
        (number 0))
    (dolist (line lines)
      (setq number (1+ number))
      (cond
       ;; Inside a fence, only its own closing run is looked at.
       (fence
        (when (and (string-match chat-mdp--fence-regexp line)
                   (string-prefix-p (substring fence 0 3)
                                    (match-string 1 line))
                   (>= (length (match-string 1 line)) (length fence)))
          (setq fence nil)))
       ((string-match chat-mdp--fence-regexp line)
        (setq fence (match-string 1 line)))
       ((string-match chat-mdp--heading-regexp line)
        (let ((hashes (match-string 1 line))
              (text (string-trim (or (match-string 2 line) ""))))
          ;; Trailing closing hashes are decoration and come off.
          (setq text (string-trim (replace-regexp-in-string
                                   "[ \t]*#+\\'" "" text)))
          (when (<= (length hashes) 2)
            (when (string-empty-p text)
              (chat-mdp--fail 'MDP-E007 number))
            (push (list :kind 'heading :level (length hashes)
                        :text text :line number)
                  items))))
       ((string-match chat-mdp--item-regexp line)
        (when-let ((item (chat-mdp--classify-item line number)))
          (push item items)))
       ((string-match chat-mdp--table-regexp line)
        (when (chat-mdp--tab-indented-p line)
          (chat-mdp--fail 'MDP-E009 number))
        (let ((level (chat-mdp--indent-level (match-string 1 line))))
          (when (> level chat-mdp-max-depth)
            (chat-mdp--fail 'MDP-E010 number))
          (push (list :kind 'table-row
                      :level level
                      :cells (chat-mdp--table-cells line)
                      :separator (string-match-p
                                  chat-mdp--table-separator-regexp line)
                      :line number)
                items)))))
    (nreverse items)))

(defun chat-mdp--classify-item (line number)
  "Return the item LINE at NUMBER denotes, or nil when it is a comment."
  (save-match-data
    (string-match chat-mdp--item-regexp line)
    (let* ((indent (match-string 1 line))
           (body (match-string 2 line))
           (level (chat-mdp--indent-level indent))
           (split (string-match ": " body))
           (key (cond (split (string-trim (substring body 0 split)))
                      ((string-suffix-p ":" body)
                       (string-trim (substring body 0 -1)))))
           (value (cond (split (string-trim (substring body (+ split 2))))
                        ((string-suffix-p ":" body) nil))))
      ;; No `: ' and no trailing colon means it does not match the field
      ;; grammar, and a list item that does not match is a comment rather
      ;; than an error.  `- key:value' lands here, as the specification
      ;; requires.
      (when key
        (when (chat-mdp--tab-indented-p line)
          (chat-mdp--fail 'MDP-E009 number))
        (when (> level chat-mdp-max-depth)
          (chat-mdp--fail 'MDP-E010 number))
        (if (string-empty-p key)
            ;; An empty key is an element marker, not a malformed field.
            (list :kind 'element :level level
                  :inline (and value (not (string-empty-p value)) value)
                  :line number)
          (list :kind 'field :level level :key key
                :value value
                :container (null value)
                :line number))))))

(defun chat-mdp--table-cells (line)
  "Return the cells of table LINE.

A cell's text is not interpreted as Markdown -- backticks and stars stay
-- and `\\|' is a literal pipe."
  (let* ((trimmed (string-trim line))
         (inner (substring trimmed 1 (1- (length trimmed))))
         (cells nil)
         (current nil)
         (index 0)
         (length (length inner)))
    (while (< index length)
      (let ((char (aref inner index)))
        (cond
         ((and (eq char ?\\) (< (1+ index) length)
               (eq (aref inner (1+ index)) ?|))
          (push "|" current)
          (setq index (+ index 2)))
         ((eq char ?|)
          (push (string-trim (apply #'concat (nreverse current))) cells)
          (setq current nil index (1+ index)))
         (t (push (string char) current)
            (setq index (1+ index))))))
    (push (string-trim (apply #'concat (nreverse current))) cells)
    (nreverse cells)))

;; ------------------------------------------------------------------
;; Blocks under construction
;; ------------------------------------------------------------------

(cl-defstruct (chat-mdp--block (:constructor chat-mdp--block-create)
                               (:copier nil))
  "A place a value is being assembled.

KIND decides what emptiness means: a section with no content is an empty
object, a container or an element with none is null."
  (kind 'section)
  (fields nil)                          ; reversed alist
  (keys (make-hash-table :test 'equal)) ; duplicate detection
  (table nil)
  (has-table nil)
  (elements nil)                        ; reversed list
  (line 0))

(defun chat-mdp--block-empty-p (block)
  "Return non-nil when nothing has been added to BLOCK."
  (and (null (chat-mdp--block-fields block))
       (null (chat-mdp--block-elements block))
       (not (chat-mdp--block-has-table block))))

(defun chat-mdp--add-field (block key value line)
  "Add KEY with VALUE to BLOCK, found on LINE."
  (when (chat-mdp--block-has-table block)
    (chat-mdp--fail 'MDP-E002 line))
  (when (chat-mdp--block-elements block)
    (chat-mdp--fail 'MDP-E002 line))
  (when (gethash key (chat-mdp--block-keys block))
    (chat-mdp--fail 'MDP-E003 line))
  (puthash key t (chat-mdp--block-keys block))
  (push (cons key value) (chat-mdp--block-fields block)))

(defun chat-mdp--set-table (block table line)
  "Make TABLE the value of BLOCK, found on LINE."
  (when (or (chat-mdp--block-has-table block)
            (chat-mdp--block-fields block)
            (chat-mdp--block-elements block))
    (chat-mdp--fail 'MDP-E002 line))
  (setf (chat-mdp--block-table block) table
        (chat-mdp--block-has-table block) t))

(defun chat-mdp--add-element (block element line)
  "Add ELEMENT to BLOCK, found on LINE."
  (when (or (chat-mdp--block-has-table block)
            (chat-mdp--block-fields block))
    (chat-mdp--fail 'MDP-E002 line))
  (push element (chat-mdp--block-elements block)))

(defun chat-mdp--finish (block)
  "Return the value BLOCK assembled."
  (cond
   ((chat-mdp--block-has-table block) (chat-mdp--block-table block))
   ((chat-mdp--block-elements block)
    (mapcar (lambda (element)
              (if (chat-mdp--block-p element)
                  (chat-mdp--finish element)
                element))
            (reverse (chat-mdp--block-elements block))))
   ((chat-mdp--block-fields block)
    (mapcar (lambda (field)
              (cons (car field)
                    (if (chat-mdp--block-p (cdr field))
                        (chat-mdp--finish (cdr field))
                      (cdr field))))
            (reverse (chat-mdp--block-fields block))))
   ((eq (chat-mdp--block-kind block) 'section) chat-mdp-empty-object)
   (t chat-mdp-null)))

;; ------------------------------------------------------------------
;; Parsing
;; ------------------------------------------------------------------

(defun chat-mdp-parse (text)
  "Return the value MDP TEXT denotes, or a parse failure.

A failure is `(error CODE LINE)'; `chat-mdp-error-p' tells them apart.
Nothing here repairs anything.  The tolerance MDP has is the tolerance
its comment rule gives it, and copying the empirical JSON repairs onto a
new format would bring the old format's illness along with them."
  (catch 'chat-mdp-error
    (when (> (length (or text "")) chat-mdp-max-input-chars)
      (chat-mdp--fail 'MDP-E010 1))
    (chat-mdp--assemble (chat-mdp--classify
                         (split-string (or text "") "\n")))))

(defun chat-mdp--assemble (items)
  "Return the value ITEMS assemble into."
  (let* ((root (chat-mdp--block-create :kind 'root))
         (level-1 nil)
         (target root)
         ;; Levels to the block accepting fields there, deepest first.
         ;; Contiguous from zero by construction, since a level is only
         ;; ever pushed one deeper than the one it came from.
         (stack (list (cons 0 root)))
         (rest items))
    (while rest
      (let* ((item (car rest))
             (kind (plist-get item :kind))
             (line (plist-get item :line))
             (advanced nil))
        (pcase kind
          ('heading
           (let* ((level (plist-get item :level))
                  (text (plist-get item :text))
                  (parent (if (= level 1) root level-1)))
             (when (and (= level 2) (null level-1))
               (chat-mdp--fail 'MDP-E001 line))
             (let ((block (chat-mdp--block-create :kind 'section
                                                  :line line)))
               (chat-mdp--add-field parent text block line)
               (when (= level 1) (setq level-1 block))
               (setq target block
                     stack (list (cons 0 block))))))
          ('field
           (let* ((level (plist-get item :level))
                  (parent (chat-mdp--accept stack level line)))
             (if (plist-get item :container)
                 (let ((block (chat-mdp--block-create :kind 'container
                                                      :line line)))
                   (chat-mdp--add-field parent (plist-get item :key)
                                        block line)
                   (setq stack (cons (cons (1+ level) block)
                                     (chat-mdp--trim-stack stack level))))
               (chat-mdp--add-field
                parent (plist-get item :key)
                (chat-mdp--infer (plist-get item :value)) line)
               ;; A leaf owns no deeper level, so anything indented under
               ;; it has no container to belong to.
               (setq stack (chat-mdp--trim-stack stack level)))))
          ('element
           (let* ((level (plist-get item :level))
                  (owner (chat-mdp--accept stack level line)))
             ;; An element marker has to sit in a section or a container.
             ;; At the root of the preamble there is neither.
             (when (and (eq owner root) (null level-1))
               (chat-mdp--fail 'MDP-E006 line))
             (if-let ((inline (plist-get item :inline)))
                 (progn
                   (chat-mdp--add-element owner (chat-mdp--infer inline)
                                          line)
                   (setq stack (chat-mdp--trim-stack stack level)))
               (let ((block (chat-mdp--block-create :kind 'element
                                                    :line line)))
                 (chat-mdp--add-element owner block line)
                 (setq stack (cons (cons (1+ level) block)
                                   (chat-mdp--trim-stack stack level)))))))
          ('table-row
           ;; Consecutive pipe lines are one table, however they are
           ;; indented: requiring the body to match the header would
           ;; reject a table a person would call well formed.
           (let* ((rows nil)
                  (level (plist-get item :level)))
             (while (and rest (eq (plist-get (car rest) :kind) 'table-row))
               (push (car rest) rows)
               (setq rest (cdr rest)))
             (setq rows (nreverse rows))
             (chat-mdp--attach-table rows level stack target root
                                     level-1 line)
             (setq advanced t))))
        (unless advanced
          (setq rest (cdr rest)))))
    (chat-mdp--finish root)))

(defun chat-mdp--trim-stack (stack level)
  "Return STACK with everything deeper than LEVEL removed."
  (seq-drop-while (lambda (entry) (> (car entry) level)) stack))

(defun chat-mdp--accept (stack level line)
  "Return the block in STACK accepting content at LEVEL, on LINE.

Failing when there is none, which is what a skipped indent level and
depth under a leaf both look like from here."
  (or (cdr (assq level stack))
      (chat-mdp--fail 'MDP-E009 line)))

(defun chat-mdp--attach-table (rows level stack target root level-1 line)
  "Attach the table of ROWS at LEVEL to whatever owns it.

Nearest empty container one level shallower first; failing that the
current section, but only for a table at the top level or one in from
it; failing that there is nothing it could belong to."
  (let* ((table (chat-mdp--parse-table rows))
         (top (car stack))
         (container (and top
                         (= (car top) level)
                         (memq (chat-mdp--block-kind (cdr top))
                               '(container element))
                         (chat-mdp--block-empty-p (cdr top))
                         (cdr top))))
    (cond
     (container (chat-mdp--set-table container table line))
     ((and (<= level 1) (not (and (eq target root) (null level-1))))
      (chat-mdp--set-table target table line))
     ;; A bare table in the preamble has no section to be the value of,
     ;; and a deeply indented one with no container above it has nothing
     ;; to hang from.
     (t (chat-mdp--fail 'MDP-E006 line)))))

(defun chat-mdp--parse-table (rows)
  "Return the array table ROWS denote."
  (let* ((header (car rows))
         (keys (plist-get header :cells))
         (line (plist-get header :line))
         (body (seq-remove (lambda (row) (plist-get row :separator))
                           (cdr rows))))
    (when (or (null keys)
              (seq-some #'string-empty-p keys)
              (/= (length keys) (length (seq-uniq keys))))
      (chat-mdp--fail 'MDP-E005 line))
    (if (= 1 (length keys))
        ;; One column is an array of scalars, and the header names the
        ;; column rather than carrying data.
        (mapcar (lambda (row)
                  (chat-mdp--infer (car (plist-get row :cells))))
                body)
      (mapcar
       (lambda (row)
         (let ((cells (plist-get row :cells)))
           (unless (= (length cells) (length keys))
             (chat-mdp--fail 'MDP-E004 (plist-get row :line)))
           ;; An empty cell means the key is absent from that row, not
           ;; that its value is null: `null' has to be written.
           (cl-loop for key in keys
                    for cell in cells
                    unless (string-empty-p cell)
                    collect (cons key (chat-mdp--infer cell)))))
       body))))

;; ------------------------------------------------------------------
;; Encoding
;; ------------------------------------------------------------------

(defun chat-mdp--object-p (value)
  "Return non-nil when VALUE is an MDP object."
  (or (eq value chat-mdp-empty-object)
      (and (consp value)
           (consp (car value))
           (stringp (caar value)))))

(defun chat-mdp--needs-quotes-p (text)
  "Return non-nil when TEXT would be read back as something else.

Quoted only when ambiguous, per the canonical form: a payload where
every string is quoted is harder to read, and being easy to read is the
entire point of the format."
  (or (string-empty-p text)
      (string-match-p chat-mdp--number-regexp text)
      (member text '("true" "false" "null" "{}" "[]"))
      (not (equal text (string-trim text)))
      (string-match-p "[\n\t\r]" text)
      (string-prefix-p "\"" text)))

(defun chat-mdp--scalar (value)
  "Return VALUE as an MDP scalar literal."
  (cond
   ((eq value chat-mdp-true) "true")
   ((eq value chat-mdp-false) "false")
   ((eq value chat-mdp-null) "null")
   ((eq value chat-mdp-empty-object) "{}")
   ((null value) "[]")
   ((numberp value) (chat-mdp--number value))
   ((stringp value)
    (if (chat-mdp--needs-quotes-p value)
        (concat "\"" (chat-mdp--escape value) "\"")
      value))
   (t (format "%s" value))))

(defun chat-mdp--number (value)
  "Return VALUE as a number literal without a trailing point."
  (if (and (floatp value) (= value (truncate value))
           (< (abs value) 1e15))
      (number-to-string (truncate value))
    (number-to-string value)))

(defun chat-mdp--tool-result-key (key)
  "Return structured tool result KEY as an MDP object key."
  (cond
   ((stringp key) key)
   ((keywordp key) (substring (symbol-name key) 1))
   ((symbolp key) (symbol-name key))
   (t (error "Unsupported structured tool result key: %S" key))))

(defun chat-mdp--tool-result-plist-p (value)
  "Return non-nil when VALUE is a proper keyword plist."
  (and (consp value)
       (proper-list-p value)
       (cl-evenp (length value))
       (cl-loop for tail on value by #'cddr
                always (keywordp (car tail)))))

(defun chat-mdp--tool-result-alist-p (value)
  "Return non-nil when VALUE is an object-like alist."
  (and (consp value)
       (proper-list-p value)
       (seq-every-p
        (lambda (entry)
          (and (consp entry)
               (or (stringp (car entry))
                   (symbolp (car entry)))))
        value)))

(defun chat-mdp--tool-result-object-container-p (value)
  "Return non-nil when VALUE is a structured object container."
  (or (hash-table-p value)
      (chat-mdp--tool-result-plist-p value)
      (chat-mdp--tool-result-alist-p value)))

(defun chat-mdp--tool-result-unique-fields (fields)
  "Return FIELDS unless their normalized keys repeat."
  (when (/= (length fields)
            (length (delete-dups (mapcar #'car fields))))
    (error "Duplicate structured tool result key"))
  fields)

(defun chat-mdp--normalize-tool-result (value depth seen)
  "Normalize structured tool VALUE to MDP at DEPTH, guarding with SEEN."
  (when (> depth chat-mdp-max-depth)
    (error "Structured tool result exceeds MDP depth"))
  (cond
   ((eq value t) chat-mdp-true)
   ((memq value '(:false :json-false)) chat-mdp-false)
   ((memq value '(:null :json-null)) chat-mdp-null)
   ((eq value :empty-object) chat-mdp-empty-object)
   ((null value) nil)
   ((or (stringp value) (numberp value)) value)
   ((symbolp value)
    (if (keywordp value)
        (substring (symbol-name value) 1)
      (symbol-name value)))
   ((or (hash-table-p value) (vectorp value) (consp value))
    (when (gethash value seen)
      (error "Circular structured tool result"))
    (puthash value t seen)
    (unwind-protect
        (cond
         ((hash-table-p value)
          (let (fields)
            (maphash
             (lambda (key item)
               (push (cons (chat-mdp--tool-result-key key)
                           (chat-mdp--normalize-tool-result
                            item (1+ depth) seen))
                     fields))
             value)
            (setq fields
                  (sort fields (lambda (left right)
                                 (string< (car left) (car right)))))
            (or (chat-mdp--tool-result-unique-fields fields)
                chat-mdp-empty-object)))
         ((vectorp value)
          (mapcar (lambda (item)
                    (chat-mdp--normalize-tool-result
                     item (1+ depth) seen))
                  (append value nil)))
         ((chat-mdp--tool-result-plist-p value)
          (chat-mdp--tool-result-unique-fields
           (cl-loop for (key item) on value by #'cddr
                    collect
                    (cons (chat-mdp--tool-result-key key)
                          (chat-mdp--normalize-tool-result
                           item (1+ depth) seen)))))
         ((and (proper-list-p value)
               (seq-every-p #'chat-mdp--tool-result-object-container-p
                            value))
          (mapcar (lambda (item)
                    (chat-mdp--normalize-tool-result
                     item (1+ depth) seen))
                  value))
         ((chat-mdp--tool-result-alist-p value)
          (chat-mdp--tool-result-unique-fields
           (mapcar
            (lambda (entry)
              (cons (chat-mdp--tool-result-key (car entry))
                    (chat-mdp--normalize-tool-result
                     (cdr entry) (1+ depth) seen)))
            value)))
         ((proper-list-p value)
          (mapcar (lambda (item)
                    (chat-mdp--normalize-tool-result
                     item (1+ depth) seen))
                  value))
         (t (error "Unsupported improper structured tool result")))
      (remhash value seen)))
   (t (error "Unsupported structured tool result value: %S" value))))

(defun chat-mdp-encode-tool-result (value)
  "Return structured tool VALUE as bounded canonical MDP, or nil.

Plain text is deliberately excluded.  Circular, over-deep and unsupported
values return nil so the tool layer can use its existing readable fallback."
  (when (or (hash-table-p value) (vectorp value) (consp value))
    (condition-case nil
        (let* ((normalized
                (chat-mdp--normalize-tool-result
                 value 0 (make-hash-table :test 'eq)))
               (document
                (if (chat-mdp--object-p normalized)
                    normalized
                  (list (cons "result" normalized))))
               (encoded (chat-mdp-encode document)))
          (and (<= (length encoded) chat-mdp-max-input-chars)
               encoded))
      (error nil))))

(defun chat-mdp-encode (value)
  "Return VALUE as an MDP document in the canonical form.

The round trip is lossless in the value, not in the text: comments are
dropped when parsing, and no encoder can put them back.  Keep the
original where the original matters.

Every root field is written as a preamble field rather than as a
heading.  Headings are the readable way to divide a large payload and
cost nothing to parse, but choosing which fields deserve one is an
editorial judgement, and an encoder that guessed would produce a
different shape for the same value depending on how large it was."
  (unless (chat-mdp--object-p value)
    (error "An MDP document is an object, not %s" (type-of value)))
  (let ((lines (if (eq value chat-mdp-empty-object)
                   nil
                 (chat-mdp--encode-fields value 0))))
    (concat (mapconcat #'identity lines "\n")
            (if lines "\n" ""))))

(defun chat-mdp--encode-fields (object level)
  "Return the lines writing OBJECT's fields at LEVEL."
  (let ((indent (make-string (* 2 level) ?\s))
        (lines nil))
    (dolist (field object)
      (let ((key (car field))
            (value (cdr field)))
        (cond
         ;; A non-empty object is a container, and its contents are two
         ;; spaces in.
         ((and (chat-mdp--object-p value)
               (not (eq value chat-mdp-empty-object)))
          (push (format "%s- %s:" indent key) lines)
          (setq lines (append (reverse (chat-mdp--encode-fields
                                        value (1+ level)))
                              lines)))
         ;; A non-empty array is a container of element markers.  Not a
         ;; table: a table can only carry flat, uniform records, so
         ;; choosing it would mean the encoder produced a different shape
         ;; depending on the data and could not round-trip the rest.
         ((and (consp value) (not (chat-mdp--object-p value)))
          (push (format "%s- %s:" indent key) lines)
          (setq lines (append (reverse (chat-mdp--encode-elements
                                        value (1+ level)))
                              lines)))
         (t (push (format "%s- %s: %s" indent key
                          (chat-mdp--scalar value))
                  lines)))))
    (nreverse lines)))

(defun chat-mdp--encode-elements (array level)
  "Return the lines writing ARRAY's elements at LEVEL."
  (let ((indent (make-string (* 2 level) ?\s))
        (lines nil))
    (dolist (element array)
      (cond
       ((and (chat-mdp--object-p element)
             (not (eq element chat-mdp-empty-object)))
        (push (format "%s- :" indent) lines)
        (setq lines (append (reverse (chat-mdp--encode-fields
                                      element (1+ level)))
                            lines)))
       ((and (consp element) (not (chat-mdp--object-p element)))
        (push (format "%s- :" indent) lines)
        (setq lines (append (reverse (chat-mdp--encode-elements
                                      element (1+ level)))
                            lines)))
       (t (push (format "%s- : %s" indent (chat-mdp--scalar element))
                lines))))
    (nreverse lines)))

;; ------------------------------------------------------------------
;; The machine view
;; ------------------------------------------------------------------

;; The document view -- hidden markers, coloured code, folded links -- is
;; `chat-markdown.el's, and this module must not compete with it: a second
;; implementation of the same thing is exactly what that module exists to
;; prevent.  What is left here is the half a document renderer structurally
;; cannot do, because it has no parse result: it sees Markdown syntax, and
;; cannot know that `- age: 28' holds the number 28 rather than the
;; characters "28", or which lines were comments.

(defface chat-mdp-key
  '((t :inherit font-lock-variable-name-face))
  "A key in the machine view."
  :group 'chat)

(defface chat-mdp-type
  '((t :inherit shadow))
  "A value's type in the machine view."
  :group 'chat)

(defface chat-mdp-comment
  '((t :inherit shadow))
  "A line the parser skipped."
  :group 'chat)

(defun chat-mdp--type-name (value)
  "Return the name of VALUE's MDP type."
  (cond ((eq value chat-mdp-true) "boolean")
        ((eq value chat-mdp-false) "boolean")
        ((eq value chat-mdp-null) "null")
        ((eq value chat-mdp-empty-object) "object")
        ((null value) "array")
        ((numberp value) "number")
        ((stringp value) "string")
        ((chat-mdp--object-p value) "object")
        ((consp value) "array")
        (t "unknown")))

(defun chat-mdp-machine-view (value)
  "Return what the parser extracted from a payload, as text.

Rendered from the parsed value, not from the Markdown it came from, so
what it shows is what a program will read.  Not a debugging extra: two
readings of one text can only be checked against each other if both are
visible, and a payload that reads correctly to a person while parsing
one field short has no other symptom."
  (mapconcat #'identity (chat-mdp--view value 0) "\n"))

(defun chat-mdp--view (value level)
  "Return the lines showing VALUE at indent LEVEL."
  (let ((indent (make-string (* 2 level) ?\s)))
    (cond
     ((eq value chat-mdp-empty-object) (list (concat indent "{}")))
     ((null value) (list (concat indent "[]")))
     ((chat-mdp--object-p value)
      (let ((lines nil))
        (dolist (field value)
          (let ((key (propertize (car field) 'face 'chat-mdp-key))
                (sub (cdr field)))
            (if (chat-mdp--branch-p sub)
                (progn
                  (push (format "%s%s: %s" indent key
                                (chat-mdp--type-label sub))
                        lines)
                  (setq lines (append (reverse (chat-mdp--view
                                                sub (1+ level)))
                                      lines)))
              (push (format "%s%s: %s %s" indent key
                            (chat-mdp--type-label sub)
                            (chat-mdp--scalar sub))
                    lines))))
        (nreverse lines)))
     ((consp value) (chat-mdp--view-array value level))
     (t (list (format "%s%s %s" indent (chat-mdp--type-label value)
                      (chat-mdp--scalar value)))))))

(defun chat-mdp--branch-p (value)
  "Return non-nil when VALUE has contents to show under it."
  (and (consp value) (not (null value))))

(defun chat-mdp--type-label (value)
  "Return VALUE's type, with a count where it has one."
  (propertize
   (if (and (consp value) (not (chat-mdp--object-p value)))
       (format "array[%d]" (length value))
     (chat-mdp--type-name value))
   'face 'chat-mdp-type))

(defun chat-mdp--view-array (array level)
  "Return the lines showing ARRAY at LEVEL.

Uniform records become an aligned table, since that is what they are.
The alignment is `chat-align's, the same one the document view uses: a
Chinese table lining up in one view and not the other would be harder to
diagnose than one that lined up in neither."
  (if-let ((keys (chat-mdp--uniform-keys array)))
      (let* ((rows (cons keys
                         (mapcar (lambda (record)
                                   (mapcar
                                    (lambda (key)
                                      (let ((cell (assoc key record)))
                                        (if cell
                                            (chat-mdp--scalar (cdr cell))
                                          "")))
                                    keys))
                                 array)))
             (indent (make-string (* 2 level) ?\s))
             (natural-widths (chat-align-column-widths rows))
             (fixed-width (+ (string-width indent) 4
                             (* 3 (max 0 (1- (length natural-widths))))))
             (widths (chat-align-fit-widths
                      natural-widths chat-mdp-machine-table-max-width
                      fixed-width)))
        (cons (concat indent "| "
                      (chat-align-row
                       (cl-mapcar
                        (lambda (key width)
                          (chat-align-truncate
                           (propertize key 'face 'chat-mdp-key) width))
                        keys widths)
                       widths)
                      " |")
              (mapcar (lambda (row)
                        (concat indent "| "
                                (chat-align-row
                                 (cl-mapcar #'chat-align-truncate row widths)
                                 widths)
                                " |"))
                      (cdr rows))))
    (let ((lines nil)
          (index -1))
      (dolist (element array)
        (setq index (1+ index))
        (if (chat-mdp--branch-p element)
            (progn
              (push (format "%s[%d]: %s" (make-string (* 2 level) ?\s)
                            index (chat-mdp--type-label element))
                    lines)
              (setq lines (append (reverse (chat-mdp--view
                                            element (1+ level)))
                                  lines)))
          (push (format "%s[%d]: %s %s" (make-string (* 2 level) ?\s)
                        index (chat-mdp--type-label element)
                        (chat-mdp--scalar element))
                lines)))
      (nreverse lines))))

(defun chat-mdp--uniform-keys (array)
  "Return the shared keys of ARRAY when it is a table of flat records.

Nil when it is not, so that a heterogeneous array is shown element by
element instead of being forced into columns it does not have."
  (when (and (consp array) (chat-mdp--object-p (car array)))
    (let ((keys (mapcar #'car (car array))))
      (when (and keys
                 (seq-every-p
                  (lambda (record)
                    (and (chat-mdp--object-p record)
                         (not (eq record chat-mdp-empty-object))
                         (equal keys (mapcar #'car record))
                         (seq-every-p (lambda (field)
                                        (not (chat-mdp--branch-p
                                              (cdr field))))
                                      record)))
                  array))
        keys))))

(defun chat-mdp-annotate (text)
  "Return TEXT with the lines the parser skipped played down.

The other half of what a document renderer cannot do without a parse
result.  Deliberately only this and the table alignment: hiding markers,
colouring code and folding links belong to `chat-markdown.el', and when
that is loaded the document view is entirely its business.  Where it is
not, MDP degrades to plain text by design, which is readable enough that
half a second renderer here would not earn its keep."
  (let* ((lines (split-string (or text "") "\n"))
         (classified (catch 'chat-mdp-error (chat-mdp--classify lines)))
         (structural (make-hash-table :test 'eql))
         (number 0))
    (unless (chat-mdp-error-p classified)
      (dolist (item classified)
        (puthash (plist-get item :line) t structural)))
    (mapconcat
     (lambda (line)
       (setq number (1+ number))
       (if (gethash number structural)
           line
         (propertize line 'face 'chat-mdp-comment)))
     lines "\n")))

(provide 'chat-mdp)
;;; chat-mdp.el ends here
