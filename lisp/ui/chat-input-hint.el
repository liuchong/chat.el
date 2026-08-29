;;; chat-input-hint.el --- Passive hints for chat input -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/licenses/1pl/

;; Author: chat.el contributors
;; Keywords: chat, convenience

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Passive input hints are display-only text.  They never own focus, a
;; keymap, a selected candidate, or any part of the buffer's contents.
;; Providers are deliberately small synchronous functions so ordinary
;; typing cannot start I/O or model work.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup chat-input-hint nil
  "Passive hints beside the chat input area."
  :group 'chat
  :prefix "chat-input-hint-")

(defcustom chat-input-hint-limit 8
  "Maximum passive hint rows to display.

The accepted input contract bounds this value to 1 through 10 so hints
cannot take over the conversation window."
  :type '(integer :tag "Rows")
  :safe (lambda (value) (and (integerp value) (<= 1 value 10)))
  :set (lambda (symbol value)
         (set-default symbol (max 1 (min 10 value))))
  :group 'chat-input-hint)

(defcustom chat-input-hint-sort-order 'alphabetical
  "How passive hint candidates are ordered.

`alphabetical' is stable and is the default.  `frequency' puts higher
provider-supplied usage counts first, then uses the same lexical order."
  :type '(choice (const alphabetical) (const frequency))
  :group 'chat-input-hint)

(defface chat-input-hint-face
  '((t :inherit shadow))
  "Face for passive input hints."
  :group 'chat-input-hint)

(cl-defstruct chat-input-hint-candidate
  "One passive candidate supplied from bounded in-memory state."
  key completion display annotation frequency)

(cl-defstruct chat-input-hint-model
  "A provider's passive hint model at one input position."
  source prefix anchor-start anchor-end candidates)

(defvar-local chat-input-hint-providers nil
  "Ordered provider functions for the current buffer.")

(defvar-local chat-input-hint--overlay nil
  "Zero-width overlay displaying the current passive hint.")

(defvar-local chat-input-hint--last-model nil
  "Last rendered hint model, including direction and visible candidates.")

(defun chat-input-hint-register-provider (provider &optional append)
  "Register buffer-local PROVIDER, placing it first unless APPEND is non-nil.

PROVIDER takes no arguments and returns a `chat-input-hint-model' or nil."
  (setq-local chat-input-hint-providers
              (delete provider chat-input-hint-providers))
  (setq chat-input-hint-providers
        (if append
            (append chat-input-hint-providers (list provider))
          (cons provider chat-input-hint-providers))))

(defun chat-input-hint-clear ()
  "Remove the passive hint from the current buffer."
  (when (overlayp chat-input-hint--overlay)
    (delete-overlay chat-input-hint--overlay))
  (setq chat-input-hint--overlay nil
        chat-input-hint--last-model nil))

(defun chat-input-hint--lexical-less-p (left right)
  "Return non-nil when candidate LEFT sorts before RIGHT lexically."
  (let* ((left-name (chat-input-hint-candidate-display left))
         (right-name (chat-input-hint-candidate-display right))
         (left-folded (downcase left-name))
         (right-folded (downcase right-name)))
    (if (string= left-folded right-folded)
        (string-lessp left-name right-name)
      (string-lessp left-folded right-folded))))

(defun chat-input-hint--candidate-less-p (left right)
  "Return non-nil when candidate LEFT should precede RIGHT."
  (let ((left-frequency (or (chat-input-hint-candidate-frequency left) 0))
        (right-frequency (or (chat-input-hint-candidate-frequency right) 0)))
    (if (and (eq chat-input-hint-sort-order 'frequency)
             (/= left-frequency right-frequency))
        (> left-frequency right-frequency)
      (chat-input-hint--lexical-less-p left right))))

(defun chat-input-hint-visible-candidates (model &optional limit)
  "Return MODEL candidates matching its prefix, sorted and bounded by LIMIT."
  (let* ((prefix (downcase (or (chat-input-hint-model-prefix model) "")))
         (maximum (max 1 (min 10 (or limit chat-input-hint-limit))))
         (matching
          (seq-filter
           (lambda (candidate)
             (string-prefix-p
              prefix
              (downcase (chat-input-hint-candidate-completion candidate))))
           (chat-input-hint-model-candidates model))))
    (seq-take (sort (copy-sequence matching)
                    #'chat-input-hint--candidate-less-p)
              maximum)))

(defun chat-input-hint--window-rows (window position)
  "Return available (BELOW . ABOVE) rows around POSITION in WINDOW."
  (let* ((height (max 1 (window-body-height window)))
         (row (max 0 (count-screen-lines
                      (window-start window) position nil window)))
         (above (min height row))
         (below (max 0 (- height above 1))))
    (cons below above)))

(defun chat-input-hint-placement (wanted below above)
  "Return (DIRECTION . COUNT) for WANTED rows and available BELOW/ABOVE."
  (cond
   ((<= wanted below) (cons 'below wanted))
   ((<= wanted above) (cons 'above wanted))
   ((>= below above) (cons 'below (min wanted below)))
   (t (cons 'above (min wanted above)))))

(defun chat-input-hint--candidate-line (candidate)
  "Return one restrained display line for CANDIDATE."
  (let ((annotation (or (chat-input-hint-candidate-annotation candidate) "")))
    (propertize
     (concat "  " (chat-input-hint-candidate-display candidate) annotation)
     'face 'chat-input-hint-face)))

(defun chat-input-hint--display-string (candidates direction)
  "Return overlay text for CANDIDATES rendered in DIRECTION."
  (let ((body (string-join
               (mapcar #'chat-input-hint--candidate-line candidates)
               "\n")))
    (if (eq direction 'above)
        (concat body "\n")
      (concat "\n" body))))

(defun chat-input-hint--first-model ()
  "Return the first applicable provider model in the current buffer."
  (run-hook-with-args-until-success 'chat-input-hint-providers))

(defun chat-input-hint-refresh ()
  "Refresh the passive hint without changing input, point or window start."
  (chat-input-hint-clear)
  (unless (minibufferp)
    (when-let* ((model (chat-input-hint--first-model))
                (window (get-buffer-window (current-buffer) t))
                (all (chat-input-hint-visible-candidates model))
                ((consp all)))
      (let* ((starts (mapcar (lambda (candidate)
                               (chat-input-hint-candidate-display candidate))
                             all))
             (rows (chat-input-hint--window-rows
                    window (chat-input-hint-model-anchor-end model)))
             (placement (chat-input-hint-placement
                         (length all) (car rows) (cdr rows)))
             (direction (car placement))
             (visible (seq-take all (cdr placement))))
        (when visible
          (let* ((saved-start (window-start window))
                 (position (if (eq direction 'above)
                               (save-excursion
                                 (goto-char
                                  (chat-input-hint-model-anchor-start model))
                                 (line-beginning-position))
                             (chat-input-hint-model-anchor-end model)))
                 (overlay (make-overlay position position nil t nil))
                 (text (chat-input-hint--display-string visible direction)))
            (overlay-put overlay
                         (if (eq direction 'above) 'before-string 'after-string)
                         text)
            (overlay-put overlay 'evaporate t)
            (setq chat-input-hint--overlay overlay
                  chat-input-hint--last-model
                  (list :source (chat-input-hint-model-source model)
                        :prefix (chat-input-hint-model-prefix model)
                        :direction direction
                        :candidates starts
                        :visible-candidates
                        (mapcar #'chat-input-hint-candidate-display visible)))
            (set-window-start window saved-start t)))))))

(provide 'chat-input-hint)
;;; chat-input-hint.el ends here
