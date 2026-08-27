;;; chat-mdp-view.el --- Two visible readings of an MDP payload -*- lexical-binding: t; -*-

;;; Commentary:

;; MDP is readable Markdown and structured data at the same time.  Looking
;; at only one side misses the point: the document view says what a person
;; sees, while the machine view says what a program actually extracted.
;;
;; The codec stays in core and knows nothing about buffers.  This UI module
;; owns the one interactive command that puts both readings beside each
;; other.

;;; Code:

(require 'chat-markdown)
(require 'chat-mdp)

(defface chat-mdp-view-machine
  '((((background light)) :inherit fixed-pitch :background "gray95"
     :extend t)
    (((background dark)) :inherit fixed-pitch :background "gray15"
     :extend t)
    (t :inherit fixed-pitch :extend t))
  "The parsed, typed reading of an MDP payload."
  :group 'chat)

(defconst chat-mdp-view-buffer-name "*Chat MDP Preview*"
  "Buffer used by `chat-mdp-preview-region'.")

(defvar-local chat-mdp-view-source-buffer nil
  "Buffer from which the MDP preview was made.")

(define-derived-mode chat-mdp-view-mode special-mode "Chat-MDP"
  "Major mode for comparing the two readings of an MDP payload."
  (chat-markdown-setup-buffer)
  (setq-local truncate-lines nil))

(defun chat-mdp-view--heading (title)
  "Return TITLE as a rendered section heading."
  (chat-markdown-render (concat "## " title)))

(defun chat-mdp-view--machine (value)
  "Return VALUE's machine view with a stable fixed-pitch metric."
  (let ((view (chat-mdp-machine-view value)))
    (when (> (length view) 0)
      (add-face-text-property 0 (length view) 'chat-mdp-view-machine t view))
    view))

(defun chat-mdp-view-render (source)
  "Return SOURCE as an MDP document view followed by its machine view.

Parse failures keep the document visible and show the MDP error code and
line in place of the machine view."
  (let ((value (chat-mdp-parse source)))
    (concat
     (chat-mdp-view--heading "MDP Document View")
     "\n\n"
     (chat-markdown-render source)
     "\n\n"
     (chat-mdp-view--heading
      (if (chat-mdp-error-p value) "MDP Parse Error" "MDP Machine View"))
     "\n\n"
     (if (chat-mdp-error-p value)
         (propertize (chat-mdp-error-message value) 'face 'error)
       (chat-mdp-view--machine value))
     "\n")))

;;;###autoload
(defun chat-mdp-preview-region (begin end)
  "Preview the MDP payload between BEGIN and END in two readings.

The region is required because a chat buffer contains role labels,
prompts and several messages that are not one payload."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (user-error "Select one MDP payload before previewing it")))
  (let ((source (buffer-substring-no-properties begin end))
        (origin (current-buffer))
        (preview (get-buffer-create chat-mdp-view-buffer-name)))
    (with-current-buffer preview
      (chat-mdp-view-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (chat-mdp-view-render source))
        (goto-char (point-min)))
      (setq-local chat-mdp-view-source-buffer origin))
    (pop-to-buffer preview)))

(provide 'chat-mdp-view)
;;; chat-mdp-view.el ends here
