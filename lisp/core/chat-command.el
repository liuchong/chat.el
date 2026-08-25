;;; chat-command.el --- Chat input command parsing -*- lexical-binding: t -*-

;;; Commentary:
;; Parses a line of chat input into a command description.  Input methods
;; that produce CJK punctuation must reach the same commands as ASCII, so
;; fullwidth punctuation is accepted wherever command syntax appears.
;;
;; Folding is limited to syntax positions: the leading prefix, the slash
;; command name, and the whitespace that separates a name from its
;; argument.  Shell bodies, AI prompts, literal text and command
;; arguments keep their original characters, so a shell command that
;; contains real CJK punctuation still runs as typed.

;;; Code:

(require 'subr-x)

(defconst chat-command--whitespace-regexp "[ \t\n\r\u3000]"
  "Whitespace that can separate a command name from its argument.")

(defconst chat-command--fullwidth-punctuation
  (let ((table (make-hash-table :test #'eq))
        ;; Aligned pairs: each fullwidth character stands for the ASCII
        ;; character directly below it.  The last pair is U+3000.
        (fullwidth "！？／＼～：，；（）［］｛｝＂＇　")
        (ascii     "!?/\\~:,;()[]{}\"' "))
    (dotimes (i (length fullwidth))
      (puthash (aref fullwidth i) (aref ascii i) table))
    table)
  "Fullwidth punctuation accepted in command syntax positions.")

(defun chat-command-trim (text)
  "Return TEXT without surrounding whitespace.
Trims the ideographic space as well as ASCII whitespace."
  (let ((pattern (concat chat-command--whitespace-regexp "+")))
    (string-trim (or text "") pattern pattern)))

(defun chat-command-fold-char (char)
  "Return the ASCII character CHAR stands for in command syntax."
  (or (gethash char chat-command--fullwidth-punctuation) char))

(defun chat-command-fold-syntax (text)
  "Return TEXT with fullwidth punctuation folded to ASCII.
Only call this on text the parser owns, never on a shell body or prompt."
  (apply #'string (mapcar #'chat-command-fold-char (string-to-list (or text "")))))

(defun chat-command-fold-path (path)
  "Return PATH with fullwidth slash and tilde folded to ASCII.
Other fullwidth characters stay, because a directory name may contain
them."
  (replace-regexp-in-string
   "～" "~" (replace-regexp-in-string "／" "/" (or path ""))))

(defun chat-command-parse (input)
  "Parse INPUT into a plist describing the requested command.

The plist always carries `:kind', one of these symbols:

`empty'         nothing to send
`literal'       `:arg' must be sent verbatim, with no interpretation
`shell-repeat'  run the previous shell command again
`shell'         run `:arg' as a shell command
`query'         ask the AI `:arg' without recording it in the session
`slash'         run the command named `:name' with `:arg'
`note'          ordinary message text in `:arg'

Arguments are returned as typed.  Only prefixes and slash command names
are folded to ASCII."
  (let ((text (chat-command-trim input)))
    (if (string-empty-p text)
        (list :kind 'empty)
      (let ((lead (chat-command-fold-char (aref text 0)))
            (rest (substring text 1)))
        (cond
         ((eq lead ?\\) (list :kind 'literal :arg rest))
         ((eq lead ?!) (chat-command--parse-bang rest))
         ((eq lead ??) (list :kind 'query :arg (chat-command-trim rest)))
         ((eq lead ?/) (chat-command--parse-slash rest))
         (t (list :kind 'note :arg text)))))))

(defun chat-command--parse-bang (rest)
  "Parse REST, the input that followed a leading bang."
  (if (and (not (string-empty-p rest))
           (eq (chat-command-fold-char (aref rest 0)) ?!)
           ;; Only a bare doubled bang repeats history; `!!foo' stays a
           ;; shell body so it fails in the shell instead of silently
           ;; running something else.
           (string-empty-p (chat-command-trim (substring rest 1))))
      (list :kind 'shell-repeat)
    (list :kind 'shell :arg (chat-command-trim rest))))

(defun chat-command--parse-slash (rest)
  "Parse REST, the input that followed a leading slash."
  (let* ((split (or (string-match chat-command--whitespace-regexp rest)
                    (length rest)))
         (name (downcase (chat-command-fold-syntax (substring rest 0 split)))))
    (list :kind 'slash
          :name name
          :arg (chat-command-trim (substring rest split)))))

(provide 'chat-command)
;;; chat-command.el ends here
