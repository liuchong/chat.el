;;; chat-session-log.el --- Session self-knowledge and transcript lookup -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A run keeps losing the early part of its own conversation: history is
;; summarized to fit the window, and what the summary left out is gone as
;; far as the run can tell.  It is not gone from disk.  The session file
;; holds every turn in full, including the parts no request carries.
;;
;; What closes that gap is not more context but knowing the record exists.
;; A run told where its transcript lives, what shape the entries have, and
;; how to filter them can go and look, which is cheaper than being given
;; everything on the chance it turns out to matter.
;;
;; The filters follow the structure the transcript already stamps, so
;; nothing new has to be written to make the file searchable.  Grouping by
;; turn is the one that matters: a question and the steps that answered it
;; belong together, and a list of messages ordered by time interleaves them
;; with whatever else happened.  A run asking "what did I conclude about
;; X" wants the turn, not the timestamp.
;;
;; Reads go through `chat-session-load' rather than parsing lines here, so
;; format handling, legacy migration and recovery metadata stay in one
;; place.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'chat-session)
(require 'chat-transcript)

;; The tool forge lives a layer up and requires core modules, so it is
;; declared rather than required: registration is guarded by `fboundp' and
;; happens after both layers are loaded.
(declare-function chat-tool-forge-register "chat-tool-forge" (tool))
(declare-function make-chat-forged-tool "chat-tool-forge" (&rest slots))

(defcustom chat-session-log-default-limit 40
  "How many entries a transcript lookup returns when no limit is given.

A lookup exists to avoid pulling the whole file into context, so it has
to have a ceiling of its own."
  :type 'integer
  :group 'chat-session)

(defcustom chat-session-log-content-max-chars 600
  "Longest content excerpt one looked-up entry may carry.

Tool results and file reads can be enormous, and a lookup that returns
them whole would spend more context than it saves."
  :type 'integer
  :group 'chat-session)

;; ------------------------------------------------------------------
;; Locating the record
;; ------------------------------------------------------------------

(defun chat-session-log-path (session)
  "Return the transcript file path for SESSION, or nil."
  (when session
    (expand-file-name (format "%s.jsonl" (chat-session-id session))
                      chat-session-directory)))

(defun chat-session-log--time-string (time)
  "Return TIME as a readable stamp, or nil."
  (when time
    (format-time-string "%Y-%m-%dT%H:%M:%S" time)))

(defun chat-session-log-self-description (session &optional terse)
  "Return the prompt block describing SESSION and its transcript.

Names the file rather than describing it in the abstract: a run that has
to guess a path will not look, and one that guesses wrong reports the
transcript as missing.

With TERSE, keep the path and the tool name and drop the explanation.
Small windows cannot afford the reasoning, and the path is the part
without which nothing else in the block can be acted on."
  (when session
    (let ((path (chat-session-log-path session)))
      (if terse
          (format (concat "Session %s (%s). Full transcript: %s -- "
                          "read it with session_log when you are missing "
                          "something from earlier.")
                  (or (chat-session-name session) "untitled")
                  (chat-session-id session)
                  path)
      (concat
       (format "Session: %s (id %s)"
               (or (chat-session-name session) "untitled")
               (chat-session-id session))
       (when-let ((created (chat-session-log--time-string
                            (chat-session-created-at session))))
         (format ", started %s" created))
       (when-let ((model (chat-session-model-id session)))
         (format ", model %s" model))
       ".\n"
       (format "Full transcript: %s\n" path)
       "\n"
       "That file is the complete record, including turns that were "
       "summarized out of the context you can see and work that was never "
       "sent to you at all. If you find you are missing something from "
       "earlier -- what was decided, what a tool returned, what you already "
       "tried -- read it rather than asking again or guessing.\n"
       "\n"
       "It is JSONL, one entry per line. Message entries carry role, "
       "content, timestamp, toolCalls, toolResults and a metadata object "
       "holding turn, step, category and work. Use the session_log tool to "
       "filter it by turn, category, work or time; it groups a question "
       "with the steps that answered it, which reading the file by hand "
       "does not.")))))

;; ------------------------------------------------------------------
;; Filtering
;; ------------------------------------------------------------------

(defun chat-session-log--normalize-time (value)
  "Return VALUE as an Emacs time value, or nil.

Accepts a time value or an ISO-like string, since a caller may hand over
either a parsed timestamp or the text a model typed."
  (cond
   ((null value) nil)
   ((consp value) value)
   ((stringp value)
    (ignore-errors
      (encode-time (parse-time-string value))))
   (t nil)))

(defun chat-session-log--symbol (value)
  "Return VALUE as a symbol, or nil."
  (cond
   ((null value) nil)
   ((symbolp value) value)
   ((stringp value) (intern value))
   (t nil)))

(defun chat-session-log-match-p (message filters)
  "Return non-nil when MESSAGE satisfies FILTERS.

FILTERS is a plist of `:turn', `:category', `:work', `:role', `:since',
`:until' and `:text'."
  (let ((turn (plist-get filters :turn))
        (category (chat-session-log--symbol (plist-get filters :category)))
        (work (chat-session-log--symbol (plist-get filters :work)))
        (role (chat-session-log--symbol (plist-get filters :role)))
        (since (chat-session-log--normalize-time (plist-get filters :since)))
        (until (chat-session-log--normalize-time (plist-get filters :until)))
        (text (plist-get filters :text))
        (stamp (chat-message-timestamp message)))
    (and (or (null turn) (equal turn (chat-transcript-turn message)))
         (or (null category) (eq category (chat-transcript-category message)))
         (or (null work) (eq work (chat-transcript-work message)))
         (or (null role) (eq role (chat-message-role message)))
         (or (null since) (null stamp) (time-less-p since stamp))
         (or (null until) (null stamp) (time-less-p stamp until))
         (or (null text)
             (string-empty-p text)
             (string-match-p (regexp-quote text)
                             (or (chat-message-content message) ""))))))

(defun chat-session-log-filter (messages filters)
  "Return the entries of MESSAGES matching FILTERS."
  (cl-remove-if-not
   (lambda (message)
     (and (chat-message-p message)
          (chat-session-log-match-p message filters)))
   messages))

;; ------------------------------------------------------------------
;; Rendering
;; ------------------------------------------------------------------

(defun chat-session-log--excerpt (text)
  "Return TEXT shortened to one readable excerpt."
  (let ((clean (string-trim (replace-regexp-in-string
                             "[\n\r\t ]+" " " (or text "")))))
    (if (> (length clean) chat-session-log-content-max-chars)
        (concat (substring clean 0 chat-session-log-content-max-chars)
                " ...[truncated]")
      clean)))

(defun chat-session-log--render-message (message)
  "Return one line describing MESSAGE."
  (let ((step (chat-transcript-step message))
        (category (chat-transcript-category message))
        (work (chat-transcript-work message))
        (stamp (chat-session-log--time-string
                (chat-message-timestamp message))))
    (concat
     (format "  %s%s%s"
             (if step (format "step %s " step) "")
             (or work category)
             (if stamp (format " @%s" stamp) ""))
     "\n"
     (when-let ((reasoning (chat-transcript-reasoning message)))
       (format "    thinking: %s\n" (chat-session-log--excerpt reasoning)))
     (when-let ((content (chat-message-content message)))
       (unless (string-blank-p content)
         (format "    %s\n" (chat-session-log--excerpt content))))
     (mapconcat
      (lambda (call)
        (format "    call: %s\n" (chat-transcript-tool-call-label call)))
      (chat-message-tool-calls message) "")
     (mapconcat
      (lambda (result)
        (format "    result: %s\n" (chat-session-log--excerpt result)))
      (chat-message-tool-results message) ""))))

(defun chat-session-log-render-turns (turns)
  "Return TURNS as text, one block per turn.

A turn is kept whole on purpose.  The question, the steps and the answer
are one unit of meaning, and splitting them into a time-ordered list is
what makes a transcript unreadable."
  (mapconcat
   (lambda (turn)
     (concat
      (format "=== turn %s ===\n" (or (plist-get turn :turn) "?"))
      (when-let ((question (plist-get turn :question)))
        (format "question: %s\n"
                (chat-session-log--excerpt
                 (chat-message-content question))))
      ;; A step record holds its own message list, so the steps are
      ;; walked rather than flattened blindly: the step number is part of
      ;; what makes the block readable.
      (mapconcat
       (lambda (step)
         (mapconcat #'chat-session-log--render-message
                    (plist-get step :messages) ""))
       (plist-get turn :steps) "")
      (when-let ((answer (plist-get turn :answer)))
        (format "answer: %s\n"
                (chat-session-log--excerpt
                 (chat-message-content answer))))))
   turns "\n"))

;; ------------------------------------------------------------------
;; Lookup
;; ------------------------------------------------------------------

(defun chat-session-log-lookup (args)
  "Read this session's transcript from disk under ARGS.

ARGS is a plist accepting `:session-id', the filters understood by
`chat-session-log-match-p', `:limit', and `:grouped'.  Grouping is the
default because a question and its steps are one unit."
  (let* ((session-id (or (plist-get args :session-id)
                         (and (boundp 'chat--current-session)
                              chat--current-session
                              (chat-session-id chat--current-session))))
         (session (and session-id (chat-session-load session-id))))
    (cond
     ((null session-id) "No session id given and no current session.")
     ((null session) (format "No transcript found for session %s."
                             session-id))
     (t
      (let* ((limit (or (plist-get args :limit)
                        chat-session-log-default-limit))
             (matched (chat-session-log-filter
                       (chat-session-messages session) args))
             (trimmed (if (> (length matched) limit)
                          (last matched limit)
                        matched)))
        (cond
         ((null trimmed) "No entries matched.")
         ((eq (plist-get args :grouped) :false)
          (mapconcat #'chat-session-log--render-message trimmed ""))
         (t
          (concat
           (format "%d of %d entries matched%s.\n\n"
                   (length trimmed) (length matched)
                   (if (> (length matched) limit)
                       (format " (showing the last %d)" limit)
                     ""))
           (chat-session-log-render-turns
            (chat-transcript-turns trimmed))))))))))

(defun chat-session-log-tool
    (&optional turn category work role since until text limit session-id)
  "Tool entry point for reading this session's transcript.

The arguments are positional and their order matches the `:parameters'
declared below, because the caller converts a tool call's arguments into
an argv list in that order."
  (chat-session-log-lookup
   (list :turn turn :category category :work work :role role
         :since since :until until :text text :limit limit
         :session-id session-id)))

;;;###autoload
(defun chat-session-log-register-tools ()
  "Register the transcript lookup tool."
  (when (fboundp 'chat-tool-forge-register)
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id 'session_log
      :name "Session Log"
      :description
      (concat "Read this session's own transcript from disk, including "
              "turns that were summarized out of the current context. "
              "Filter by turn, category (user, ai-progress, ai-final, "
              "command-reply, shell-output, system-detail), work "
              "(thinking, tool-call, tool-result, message), role, a time "
              "range, or a literal text match. Results are grouped by "
              "turn so a question stays with the steps that answered it.")
      :language 'elisp
      :parameters
      '((:name "turn" :type "integer" :required nil)
        (:name "category" :type "string" :required nil)
        (:name "work" :type "string" :required nil)
        (:name "role" :type "string" :required nil)
        (:name "since" :type "string" :required nil)
        (:name "until" :type "string" :required nil)
        (:name "text" :type "string" :required nil)
        (:name "limit" :type "integer" :required nil)
        (:name "session_id" :type "string" :required nil))
      :owner 'session-log
      :sensitivity 'project
      :effects '(read)
      :compiled-function #'chat-session-log-tool
      :is-active t
      :usage-count 0))))

(provide 'chat-session-log)
;;; chat-session-log.el ends here
