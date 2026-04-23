(require 'seq)
(require 'subr-x)
(require 'thingatpt)

(defgroup chat-reading nil
  "Shared reading workflow helpers for chat.el."
  :group 'chat
  :prefix "chat-reading-")

(defcustom chat-reading-near-point-radius 5
  "Number of surrounding lines to capture around point."
  :type 'integer
  :group 'chat-reading)

(defcustom chat-reading-current-file-max-lines 400
  "Maximum number of lines allowed for current-file capture."
  :type 'integer
  :group 'chat-reading)

(defcustom chat-reading-filetype-map
  '(("\\.py$" . python)
    ("\\.js$" . javascript)
    ("\\.ts$" . typescript)
    ("\\.jsx$" . jsx)
    ("\\.tsx$" . tsx)
    ("\\.el$" . emacs-lisp)
    ("\\.go$" . go)
    ("\\.rs$" . rust)
    ("\\.rb$" . ruby)
    ("\\.java$" . java)
    ("\\.c$" . c)
    ("\\.cpp$" . cpp)
    ("\\.h$" . c)
    ("\\.hpp$" . cpp)
    ("\\.sh$" . shell)
    ("\\.md$" . markdown))
  "File extensions to language mapping for reading captures."
  :type '(repeat (cons string symbol))
  :group 'chat-reading)

(defun chat-reading--current-file ()
  "Return the current file for reading capture commands."
  (or (buffer-file-name)
      (user-error "Current buffer is not visiting a file")))

(defun chat-reading--language (file)
  "Return the language symbol for FILE."
  (or (cdr (seq-find
            (lambda (entry)
              (string-match-p (car entry) file))
            chat-reading-filetype-map))
      major-mode))

(defun chat-reading--make-capture (kind file start-line end-line code)
  "Build a normalized reading capture."
  (list :kind kind
        :file file
        :start-line start-line
        :end-line end-line
        :code code
        :language (chat-reading--language file)))

(defun chat-reading--ensure-nonempty-code (code)
  "Return CODE or signal a user error when it is empty."
  (unless (and code (> (length code) 0))
    (user-error "Current file does not contain readable code to quote"))
  code)

(defun chat-reading--region-line-range ()
  "Return the active region line range as a cons."
  (when (region-active-p)
    (let* ((start (region-beginning))
           (end (region-end))
           (adjusted-end (if (and (> end start)
                                  (save-excursion
                                    (goto-char end)
                                    (= end (line-beginning-position))))
                             (1- end)
                           end)))
      (cons (line-number-at-pos start)
            (line-number-at-pos adjusted-end)))))

(defun chat-reading-capture-region ()
  "Capture the active region for the reading workflow."
  (let* ((file (chat-reading--current-file))
         (start (and (region-active-p) (region-beginning)))
         (end (and (region-active-p) (region-end)))
         (code (and start
                    end
                    (> end start)
                    (buffer-substring-no-properties start end)))
         (line-range (and code (chat-reading--region-line-range))))
    (unless line-range
      (user-error "No active region to quote"))
    (chat-reading--make-capture
     'region
     file
     (car line-range)
     (cdr line-range)
     code)))

(defun chat-reading--defun-bounds ()
  "Return the start and end positions of the defun at point."
  (bounds-of-thing-at-point 'defun))

(defun chat-reading-capture-defun ()
  "Capture the defun at point for the reading workflow."
  (unless (derived-mode-p 'prog-mode)
    (user-error "No defun at point to quote"))
  (let* ((file (chat-reading--current-file))
         (bounds (or (chat-reading--defun-bounds)
                     (user-error "No defun at point to quote")))
         (start (car bounds))
         (end (cdr bounds))
         (end-line-pos (if (> end start) (1- end) end)))
    (chat-reading--make-capture
     'defun
     file
     (line-number-at-pos start)
     (line-number-at-pos end-line-pos)
     (buffer-substring-no-properties start end))))

(defun chat-reading-capture-near-point (&optional radius)
  "Capture nearby context around point for the reading workflow."
  (let* ((file (chat-reading--current-file))
         (radius (max 0 (or radius chat-reading-near-point-radius)))
         (start (save-excursion
                  (forward-line (- radius))
                  (line-beginning-position)))
         (end (save-excursion
                (forward-line radius)
                (line-end-position)))
         (end-line-pos (if (> end start) (1- end) end))
         (code (chat-reading--ensure-nonempty-code
                (buffer-substring-no-properties start end))))
    (chat-reading--make-capture
     'near-point
     file
     (line-number-at-pos start)
     (line-number-at-pos end-line-pos)
     code)))

(defun chat-reading-capture-current-file (&optional max-lines)
  "Capture the current file for the reading workflow."
  (let* ((file (chat-reading--current-file))
         (start (point-min))
         (end (point-max))
         (end-line-pos (if (> end start) (1- end) end))
         (line-count (count-lines start end))
         (limit (or max-lines chat-reading-current-file-max-lines))
         (code (chat-reading--ensure-nonempty-code
                (buffer-substring-no-properties start end))))
    (when (> line-count limit)
      (user-error "Current file is too large to quote directly; use region, defun, or near-point"))
    (chat-reading--make-capture
     'current-file
     file
     1
     (max 1 (line-number-at-pos end-line-pos))
     code)))

(defun chat-reading-format-question (capture &optional question)
  "Format CAPTURE and QUESTION as a visible reading workflow prompt."
  (let ((code (plist-get capture :code)))
    (concat
     "Question about this code:\n\n"
     (format "File: %s\n" (plist-get capture :file))
     (format "Lines: %d-%d\n"
             (plist-get capture :start-line)
             (plist-get capture :end-line))
     (format "Kind: %s\n\n" (plist-get capture :kind))
     (format "```%s\n" (symbol-name (plist-get capture :language)))
     code
     (unless (string-suffix-p "\n" code)
       "\n")
     "```\n\n"
     "Question:\n"
     (or question ""))))

(provide 'chat-reading)
