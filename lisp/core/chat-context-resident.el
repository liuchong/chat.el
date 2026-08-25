;;; chat-context-resident.el --- Declared resident context -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Instruction files routinely ask for part of themselves to stay in view:
;; a rule that says rules must not be thinned out, a suite declared
;; resident, a demand to reread the originals rather than a paraphrase.
;; Those requests are addressed to a mechanism that usually does not
;; exist, so they are honoured only as long as the agent happens to
;; remember them -- which is exactly what they were written to prevent.
;;
;; This module gives the request somewhere to land.  An instructions file
;; marks the spans that must survive verbatim, and everything downstream
;; treats those spans as fixed while summarizing the rest.
;;
;; The marker is an HTML comment, chosen for three properties that all
;; have to hold at once.  Markdown hides it, so the file still reads
;; cleanly for people.  A tool that does not implement this scheme sees an
;; ordinary comment and behaves exactly as before, so marking a shared
;; file breaks nothing.  And it is line-oriented, so parsing needs no
;; Markdown reader and cannot be confused by prose that talks about the
;; syntax.
;;
;; The syntax is fixed rather than configurable.  A declaration that only
;; works under one client's settings is not a guarantee, and a file that
;; has to be re-marked per tool will drift out of date.
;;
;;   <!-- chat:resident -->        opens a block; closed by chat:end
;;   <!-- chat:end -->             closes it
;;   ## Heading <!-- chat:resident -->
;;                                 makes that section resident, through
;;                                 to the next heading of the same or a
;;                                 higher level
;;   - text <!-- chat:resident --> marks that one line
;;
;; A heading whose text matches `chat-context-resident-headings' is
;; resident without any marker, for files nobody wants to annotate.  That
;; is still an exact match on a configured name, not an attempt to read
;; intent from prose: a scheme that guesses is a scheme that silently
;; stops guaranteeing things.
;;
;; A declaration is a request, not a command.  Resident text is honoured
;; in document order up to the cap in `chat-context-budget', and the
;; excess is demoted to compactable rather than dropped, because a file
;; that declared more than the window can hold must not be able to leave
;; a session with no room to work in.  Document order decides what
;; survives, so the most important rules go first.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-context-budget)

(defconst chat-context-resident-open-regexp
  "\\`[ \t]*<!--[ \t]*chat:resident[ \t]*-->[ \t]*\\'"
  "A line that opens a resident block and carries nothing else.")

(defconst chat-context-resident-close-regexp
  "\\`[ \t]*<!--[ \t]*chat:end[ \t]*-->[ \t]*\\'"
  "A line that closes a resident block.")

(defconst chat-context-resident-trailing-regexp
  "[ \t]*<!--[ \t]*chat:resident[ \t]*-->[ \t]*\\'"
  "A marker at the end of a line that carries content of its own.")

(defconst chat-context-resident-heading-regexp
  "\\`[ \t]*\\(#+\\)[ \t]+\\(.*?\\)[ \t]*\\'"
  "A Markdown ATX heading, capturing its level and its text.")

(defcustom chat-context-resident-headings
  '("Resident Rules"
    "Resident Context"
    "Non-Negotiables"
    "常驻规则"
    "常驻上下文")
  "Heading texts that make a section resident without a marker.

Compared case-insensitively against the heading text with any trailing
marker removed.  This is an exact name match by design; inferring
residency from prose would make the guarantee depend on wording."
  :type '(repeat string)
  :group 'chat-context-budget)

;; ------------------------------------------------------------------
;; Parsing
;; ------------------------------------------------------------------

(defun chat-context-resident--strip-marker (line)
  "Return LINE without a trailing resident marker."
  (replace-regexp-in-string chat-context-resident-trailing-regexp "" line))

(defun chat-context-resident--marked-p (line)
  "Return non-nil when LINE carries content plus a trailing marker."
  (and (string-match-p chat-context-resident-trailing-regexp line)
       (not (string-match-p chat-context-resident-open-regexp line))
       (not (string-blank-p (chat-context-resident--strip-marker line)))))

(defun chat-context-resident--heading (line)
  "Return the level and text of LINE as a heading, or nil."
  (when (string-match chat-context-resident-heading-regexp line)
    (cons (length (match-string 1 line))
          (string-trim (chat-context-resident--strip-marker
                        (match-string 2 line))))))

(defun chat-context-resident--heading-declared-p (line heading)
  "Return non-nil when LINE or HEADING text declares a resident section."
  (or (chat-context-resident--marked-p line)
      (cl-member (cdr heading) chat-context-resident-headings
                 :test #'cl-equalp)))

(defun chat-context-resident-parse (text)
  "Split TEXT into segments, each a plist of `:resident' and `:text'.

Adjacent lines of the same kind are merged, so the result is the
alternating structure a caller wants rather than one entry per line."
  (let ((in-block nil)
        (section-level nil)
        (segments nil))
    (dolist (line (split-string (or text "") "\n"))
      (cond
       ((string-match-p chat-context-resident-open-regexp line)
        (setq in-block t))
       ((string-match-p chat-context-resident-close-regexp line)
        (setq in-block nil))
       (t
        (let* ((heading (chat-context-resident--heading line))
               (resident
                (cond
                 (heading
                  ;; A heading at the same or a higher level ends the
                  ;; section that was open, whether or not it opens one.
                  (when (and section-level (<= (car heading) section-level))
                    (setq section-level nil))
                  (if (chat-context-resident--heading-declared-p line heading)
                      (setq section-level (car heading))
                    (or in-block (and section-level t))))
                 (t (or in-block
                        (and section-level t)
                        (chat-context-resident--marked-p line)))))
               (clean (chat-context-resident--strip-marker line))
               (head (car segments)))
          (if (and head (eq (plist-get head :resident) (and resident t)))
              (setf (plist-get head :text)
                    (concat (plist-get head :text) "\n" clean))
            (push (list :resident (and resident t) :text clean) segments))))))
    (nreverse segments)))

(defun chat-context-resident-partition (text)
  "Return TEXT split into `:resident' and `:compactable' strings.

Either may be nil.  Blank-only spans are dropped so that marking a
section does not carry the whitespace around it into the fixed region."
  (let (resident compactable)
    (dolist (segment (chat-context-resident-parse text))
      (let ((body (string-trim (plist-get segment :text))))
        (unless (string-empty-p body)
          (if (plist-get segment :resident)
              (push body resident)
            (push body compactable)))))
    (list :resident (and resident (string-join (nreverse resident) "\n\n"))
          :compactable (and compactable
                            (string-join (nreverse compactable) "\n\n")))))

(defun chat-context-resident-declared-p (text)
  "Return non-nil when TEXT declares any resident span."
  (and (plist-get (chat-context-resident-partition text) :resident) t))

;; ------------------------------------------------------------------
;; The cap
;; ------------------------------------------------------------------

(defun chat-context-resident-apply-cap (resident cap)
  "Fit RESIDENT text within CAP tokens, returning a plist.

Keys are `:resident', the span that fits, `:demoted', the excess that
must be compactable instead, and `:overflow', its cost in tokens.

Honouring an unbounded declaration would let one file fill the window
and leave a session unable to work, so the excess is demoted rather than
obeyed.  Document order decides: paragraphs are kept from the top until
the cap is reached, which makes the ordering of an instructions file the
ordering of its guarantees."
  (if (or (null resident) (string-empty-p resident))
      (list :resident nil :demoted nil :overflow 0)
    (let ((kept nil)
          (demoted nil)
          (used 0))
      (dolist (block (split-string resident "\n\n" t))
        (let ((cost (chat-context-count-tokens block)))
          (if (and (null demoted) (<= (+ used cost) cap))
              (setq kept (cons block kept)
                    used (+ used cost))
            ;; Once one block does not fit, later blocks are demoted too:
            ;; keeping a small tail after dropping a large middle would
            ;; leave the guarantee looking satisfied while a rule is gone.
            (push block demoted))))
      ;; Both strings are built before the plist so that the overflow is
      ;; measured from the same text that is returned.
      (let ((kept-text (and kept (string-join (nreverse kept) "\n\n")))
            (demoted-text (and demoted
                               (string-join (nreverse demoted) "\n\n"))))
        (list :resident kept-text
              :demoted demoted-text
              :overflow (if demoted-text
                            (chat-context-count-tokens demoted-text)
                          0))))))

(defun chat-context-resident-overflow-warning (overflow cap)
  "Return the warning for an OVERFLOW of tokens past CAP, or nil.

Addressed to whoever wrote the declaration: the run cannot shorten its
own instructions, and a guarantee that was silently reduced is worse
than one that was refused out loud."
  (when (and overflow (> overflow 0))
    (format
     (concat "Resident instructions exceed the fixed-context cap by %d "
             "tokens (cap %d). The excess past the cap is compactable, in "
             "document order, so later declarations are the ones that lose "
             "their guarantee. Shorten them or raise "
             "`chat-context-protected-max-ratio'.")
     overflow cap)))

(provide 'chat-context-resident)
;;; chat-context-resident.el ends here
