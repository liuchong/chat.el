;;; chat-command.el --- Chat input command parsing -*- lexical-binding: t -*-

;;; Commentary:
;; Parses a line of chat input into a command description.  Input methods
;; that produce fullwidth characters must reach the same commands as
;; ASCII, so fullwidth forms are accepted wherever command syntax appears
;; -- letters and digits as well as punctuation, because an input method
;; left in fullwidth mode turns a typed `/help' into `／ｈｅｌｐ' and the
;; name is as affected as the slash.
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

(defconst chat-command--fullwidth-offset #xFEE0
  "Distance from a fullwidth form to the ASCII character it stands for.
The Halfwidth and Fullwidth Forms block lays U+FF01 to U+FF5E out in the
same order as ASCII #x21 to #x7E, so one subtraction covers the whole
range.")

(defun chat-command--fullwidth-ascii (char)
  "Return the ASCII character CHAR is the fullwidth form of, or nil.

Letters and digits are included, not only punctuation.  An input method
left in fullwidth mode produces `／ｈｅｌｐ' for a typed `/help', and
listing punctuation alone got the slash but left the name unreadable, so
the command was not found and the line was sent to the model as text.

Deliberately limited to this one block: CJK ideographs are outside it, so
a command named in Chinese is not touched."
  (cond
   ((eq char ?\u3000) ?\s)
   ((and (>= char ?\uFF01) (<= char ?\uFF5E))
    (- char chat-command--fullwidth-offset))))

(defun chat-command-trim (text)
  "Return TEXT without surrounding whitespace.
Trims the ideographic space as well as ASCII whitespace."
  (let ((pattern (concat chat-command--whitespace-regexp "+")))
    (string-trim (or text "") pattern pattern)))

(defun chat-command-fold-char (char)
  "Return the ASCII character CHAR stands for in command syntax."
  (or (chat-command--fullwidth-ascii char) char))

(defun chat-command-fold-syntax (text)
  "Return TEXT with fullwidth punctuation folded to ASCII.
Only call this on text the parser owns, never on a shell body or prompt."
  (apply #'string (mapcar #'chat-command-fold-char (string-to-list (or text "")))))

(defun chat-command-fold-name (text)
  "Return TEXT folded to ASCII, for an argument read as a name.

For the arguments a command interprets rather than passes on: the command
name after `/auto', the keyword after `/drop', a model id, a help topic.
The parser cannot fold these itself, because the same position in another
command holds a shell body or a prompt, where a fullwidth character may be
exactly what was meant.  So the parser folds syntax and a handler folds an
argument it is going to compare against a fixed name.

Case is left alone; callers that match case-insensitively already
`downcase' on top of this."
  (chat-command-fold-syntax (chat-command-trim text)))

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

`:text' always holds the trimmed input, which a caller needs when it
decides to treat an unrecognized command as ordinary text.

Arguments are returned as typed.  Only prefixes and slash command names
are folded to ASCII."
  (let ((text (chat-command-trim input)))
    (append
     (if (string-empty-p text)
         (list :kind 'empty)
       (let ((lead (chat-command-fold-char (aref text 0)))
             (rest (substring text 1)))
         (cond
          ((eq lead ?\\) (list :kind 'literal :arg rest))
          ((eq lead ?!) (chat-command--parse-bang rest))
          ((eq lead ??) (list :kind 'query :arg (chat-command-trim rest)))
          ((eq lead ?/) (chat-command--parse-slash rest))
          (t (list :kind 'note :arg text)))))
     (list :text text))))

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
