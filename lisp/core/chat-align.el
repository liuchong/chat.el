;;; chat-align.el --- Laying out columns by display width -*- lexical-binding: t; -*-

;;; Commentary:

;; One implementation of "put these cells in columns", because there are
;; three callers and the wrong number of implementations is two.
;;
;; The callers are the document view of a Markdown table, the machine view of
;; a parsed MDP payload, and eventually the tab stops in captured shell
;; output.  A Chinese table that lines up in one view and not in the other is
;; harder to diagnose than one that lines up in neither, since the first
;; looks like a rendering bug and the second looks like a width bug.
;;
;; What makes this worth its own file rather than a helper inside the
;; renderer: the MDP codec must not depend on the display layer -- a protocol
;; module whose usability is tied to a renderer being loaded is a protocol
;; module that goes blind in batch mode -- and it needs this. So it lives
;; below both.
;;
;; Nothing here touches a buffer, a window or a face. It is arithmetic on
;; strings.

;;; Code:

(require 'cl-lib)

(defun chat-align-width (text)
  "Return how wide TEXT is on screen.

`string-width', never `length'.  CJK characters occupy two columns each, so
counting characters puts every table containing Chinese out by the number
of Chinese characters in its widest cell."
  (string-width (or text "")))

(defun chat-align-column-widths (rows)
  "Return the display width each column of ROWS needs.

ROWS is a list of lists of strings.  Ragged rows are allowed: a row with
fewer cells simply does not constrain the columns it lacks, which is what
lets a malformed table still be laid out rather than refused."
  (let ((widths nil))
    (dolist (row rows)
      (let ((index 0))
        (dolist (cell row)
          (let ((width (chat-align-width cell)))
            (if (< index (length widths))
                (setf (nth index widths) (max (nth index widths) width))
              (setq widths (append widths (list width)))))
          (setq index (1+ index)))))
    widths))

(defun chat-align-pad (text width &optional alignment)
  "Return TEXT padded with spaces to WIDTH columns.

ALIGNMENT is `left' (the default), `right' or `center'.  Text already at
or over WIDTH is returned unchanged: truncating here would lose data to
make a table pretty, and a cell that overflows its column is a table that
needs a different column, not a shorter cell."
  (let* ((text (or text ""))
         (short (- width (chat-align-width text))))
    (if (<= short 0)
        text
      (pcase alignment
        ('right (concat (make-string short ?\s) text))
        ('center (let ((left (/ short 2)))
                   (concat (make-string left ?\s) text
                           (make-string (- short left) ?\s))))
        (_ (concat text (make-string short ?\s)))))))

(defun chat-align-row (cells widths &optional alignments separator)
  "Return CELLS padded to WIDTHS and joined by SEPARATOR.

ALIGNMENTS is a list of per-column alignments as in `chat-align-pad',
short lists defaulting the rest to `left'.  SEPARATOR defaults to \" | \"."
  (let ((separator (or separator " | "))
        (index -1))
    (mapconcat
     (lambda (cell)
       (setq index (1+ index))
       (chat-align-pad cell (or (nth index widths) 0)
                       (nth index alignments)))
     cells
     separator)))

(defun chat-align-fit-widths (widths max-width fixed-width
                                     &optional minimum-width)
  "Reduce WIDTHS proportionally to fit MAX-WIDTH columns.

FIXED-WIDTH is the space consumed by indentation, borders and separators.
MINIMUM-WIDTH defaults to three columns, enough to retain one character and
an ellipsis.  Columns are never dropped: a clipped table remains structurally
honest about how many fields it contains."
  (let* ((minimum-width (or minimum-width 3))
         (content-width (apply #'+ (or widths '(0))))
         (total (+ fixed-width content-width)))
    (if (or (null widths) (<= total max-width) (zerop content-width))
        widths
      (let ((room (max 1 (- max-width fixed-width))))
        (let* ((fitted
                (mapcar (lambda (width)
                          (max minimum-width
                               (floor (* width
                                         (/ (float room) content-width)))))
                        widths))
               (excess (- (apply #'+ fitted) room)))
          ;; Clamping a very narrow column to MINIMUM-WIDTH can put the sum
          ;; back over budget.  Take that excess from the widest columns;
          ;; this only runs when all columns can still keep their minimum.
          (dolist (index (sort (number-sequence 0 (1- (length fitted)))
                               (lambda (left right)
                                 (> (nth left fitted) (nth right fitted)))))
            (when (> excess 0)
              (let ((cut (min excess
                              (max 0 (- (nth index fitted)
                                        minimum-width)))))
                (setf (nth index fitted) (- (nth index fitted) cut)
                      excess (- excess cut)))))
          fitted)))))

(defun chat-align-truncate (text width &optional marker)
  "Return TEXT cut to WIDTH columns, ending in MARKER when it was cut.

MARKER defaults to a single ellipsis character, and its own width is
counted, so the result is never wider than WIDTH.  Used where overflowing
is worse than losing the tail -- a table wider than the window, whose
right-hand columns would otherwise be off screen with nothing to say so."
  (let* ((text (or text ""))
         (marker (or marker "…")))
    (if (<= (chat-align-width text) width)
        text
      (let* ((room (max 0 (- width (chat-align-width marker))))
             (taken 0)
             (index 0)
             (length (length text)))
        ;; Character by character, because a cut counted in characters can
        ;; land one column over when the last one taken is double width.
        (while (and (< index length)
                    (<= (+ taken (char-width (aref text index))) room))
          (setq taken (+ taken (char-width (aref text index)))
                index (1+ index)))
        (concat (substring text 0 index) marker)))))

(provide 'chat-align)
;;; chat-align.el ends here
