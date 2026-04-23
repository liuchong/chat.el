;;; chat-session.el --- Session management for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, session, conversation

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This module provides session management for chat.el.
;; A session represents a single conversation with context,
;; messages, and configuration.

;;; Code:

(require 'cl-lib)
(require 'json)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat-session nil
  "Session management for chat.el."
  :group 'chat)

(defcustom chat-session-directory
  (expand-file-name "~/.chat/sessions/")
  "Directory where session files are stored."
  :type 'directory
  :group 'chat-session)

(defcustom chat-session-auto-save t
  "Whether to automatically save sessions after modifications."
  :type 'boolean
  :group 'chat-session)

;; ------------------------------------------------------------------
;; Data Structures
;; ------------------------------------------------------------------

(cl-defstruct chat-session
  id                    ; Unique identifier string
  name                  ; Display name
  created-at            ; Creation timestamp
  updated-at            ; Last update timestamp
  model-id              ; LLM model symbol
  messages              ; List of chat-message structs
  prompt-stack          ; Multi-level prompt stack
  context-window        ; Context window settings
  tool-config           ; Tool configuration
  auto-approve          ; nil, t, or 'inherit (inherit from global)
  metadata)             ; Additional metadata plist

(cl-defstruct chat-message
  id                    ; Unique identifier
  role                  ; :user :assistant :system :tool
  content               ; Message content string
  timestamp             ; Message timestamp
  parent-id             ; Parent message ID for branching
  branch-ids            ; List of branch message IDs
  metadata              ; Additional metadata
  tool-calls            ; Tool call requests
  tool-results          ; Tool execution results
  raw-request           ; Raw API request JSON (for user messages)
  raw-response)         ; Raw API response JSON (for assistant messages)

;; ------------------------------------------------------------------
;; Session Lifecycle
;; ------------------------------------------------------------------

(defun chat-session--generate-id ()
  "Generate a unique session ID."
  (format "%s-%s"
          (format-time-string "%Y%m%d%H%M%S")
          (random 10000)))

(defun chat-session--ensure-directory ()
  "Ensure session directory exists."
  (unless (file-directory-p chat-session-directory)
    (make-directory chat-session-directory t)))

(defun chat-session-create (name &optional model-id)
  "Create a new chat session with NAME and optional MODEL-ID.

NAME is a string identifying the session.
MODEL-ID is a symbol specifying the LLM model, defaults to
chat-default-model if nil.

Returns the newly created chat-session struct."
  (chat-session--ensure-directory)
  (let* ((id (chat-session--generate-id))
         (now (current-time))
         (session (make-chat-session
                   :id id
                   :name name
                   :created-at now
                   :updated-at now
                   :model-id (or model-id (bound-and-true-p chat-default-model) 'kimi)
                   :messages nil
                   :prompt-stack nil
                   :metadata nil)))
    (when chat-session-auto-save
      (chat-session-save session))
    session))

(defun chat-session-save (session)
  "Save SESSION to disk.

SESSION is a chat-session struct.
Returns t on success, nil on failure."
  (chat-session--ensure-directory)
  (let* ((id (chat-session-id session))
         (filename (expand-file-name
                    (format "%s.json" id)
                    chat-session-directory))
         (data (chat-session--serialize session)))
    (with-temp-file filename
      (insert (json-encode data)))
    t))

(defun chat-session-load (session-id)
  "Load session with SESSION-ID from disk.

SESSION-ID is a string identifying the session.
Returns the chat-session struct, or nil if not found."
  (let ((filename (expand-file-name
                   (format "%s.json" session-id)
                   chat-session-directory)))
    (when (file-exists-p filename)
      (with-temp-buffer
        (insert-file-contents filename)
        (chat-session--deserialize
         (json-read-from-string
          (buffer-string)))))))

(defun chat-session-delete (session-id)
  "Delete session with SESSION-ID from disk.

Returns t if deleted, nil if file did not exist."
  (let ((filename (expand-file-name
                   (format "%s.json" session-id)
                   chat-session-directory)))
    (when (file-exists-p filename)
      (delete-file filename)
      t)))

(defun chat-session-rename (session-id new-name)
  "Rename session with SESSION-ID to NEW-NAME."
  (let ((session (chat-session-load session-id)))
    (when session
      (setf (chat-session-name session) new-name)
      (setf (chat-session-updated-at session) (current-time))
      (chat-session-save session)
      t)))

;; ------------------------------------------------------------------
;; Session Listing
;; ------------------------------------------------------------------

(defun chat-session-list ()
  "Return a list of all saved sessions.

Returns a list of chat-session structs, sorted by updated-at
descending."
  (chat-session--ensure-directory)
  (let (sessions)
    (dolist (file (directory-files
                   chat-session-directory
                   t
                   "\\.json$"))
      (condition-case nil
          (push (chat-session-load
                 (file-name-base file))
                sessions)
        (error nil)))
    (sort sessions
          (lambda (a b)
            (time-less-p
             (chat-session-updated-at b)
             (chat-session-updated-at a))))))

;; ------------------------------------------------------------------
;; Message Management
;; ------------------------------------------------------------------

(defun chat-session-add-message (session message)
  "Add MESSAGE to SESSION.

SESSION is a chat-session struct.
MESSAGE is a chat-message struct."
  (setf (chat-session-messages session)
        (append (chat-session-messages session)
                (list message)))
  (setf (chat-session-updated-at session)
        (current-time))
  (when chat-session-auto-save
    (chat-session-save session)))

(defun chat-session-get-messages (session &optional limit)
  "Get messages from SESSION, optionally limited to LIMIT most recent.

Returns a list of chat-message structs."
  (let ((messages (chat-session-messages session)))
    (if limit
        (last messages limit)
      messages)))

(defun chat-session-clear-messages (session)
  "Clear all messages from SESSION."
  (setf (chat-session-messages session) nil)
  (setf (chat-session-updated-at session)
        (current-time))
  (when chat-session-auto-save
    (chat-session-save session)))

(defun chat-session-find-last-message (session &optional predicate)
  "Return the last message in SESSION matching PREDICATE."
  (let ((messages (reverse (chat-session-messages session)))
        found)
    (while (and messages (not found))
      (when (or (null predicate)
                (funcall predicate (car messages)))
        (setq found (car messages)))
      (setq messages (cdr messages)))
    found))

(defun chat-session-find-last-message-by-role (session role)
  "Return the last message in SESSION whose role is ROLE."
  (chat-session-find-last-message
   session
   (lambda (message)
     (eq (chat-message-role message) role))))

(defun chat-session-truncate-after-message (session message-id &optional include-message)
  "Truncate SESSION after MESSAGE-ID.
When INCLUDE-MESSAGE is non nil, also remove the matching message."
  (let* ((messages (chat-session-messages session))
         (index (cl-position message-id
                             messages
                             :key #'chat-message-id
                             :test #'equal)))
    (when index
      (setf (chat-session-messages session)
            (cl-subseq messages 0 (if include-message index (1+ index))))
      (setf (chat-session-updated-at session) (current-time))
      (when chat-session-auto-save
        (chat-session-save session))
      t)))

(defun chat-session-replace-message-content (session message-id new-content)
  "Replace SESSION message MESSAGE-ID content with NEW-CONTENT."
  (let ((message (cl-find message-id
                          (chat-session-messages session)
                          :key #'chat-message-id
                          :test #'equal)))
    (when message
      (setf (chat-message-content message) new-content)
      (setf (chat-session-updated-at session) (current-time))
      (when chat-session-auto-save
        (chat-session-save session))
      message)))

;; ------------------------------------------------------------------
;; Serialization
;; ------------------------------------------------------------------

(defun chat-session--serialize (session)
  "Convert SESSION struct to JSON-serializable alist."
  `((id . ,(chat-session-id session))
    (name . ,(chat-session-name session))
    (createdAt . ,(format-time-string
                   "%Y-%m-%dT%H:%M:%S"
                   (chat-session-created-at session)))
    (updatedAt . ,(format-time-string
                   "%Y-%m-%dT%H:%M:%S"
                   (chat-session-updated-at session)))
    (modelId . ,(symbol-name (chat-session-model-id session)))
    (messages . ,(mapcar #'chat-message--serialize
                         (chat-session-messages session)))
    (autoApprove . ,(let ((aa (chat-session-auto-approve session)))
                      (cond ((eq aa t) t)
                            ((eq aa nil) :json-false)
                            (t 'inherit))))
    (metadata . ,(or (chat-session-metadata session) nil))))

(defun chat-message--serialize (message)
  "Convert MESSAGE struct to JSON-serializable alist."
  `((id . ,(chat-message-id message))
    (role . ,(symbol-name (chat-message-role message)))
    (content . ,(chat-message-content message))
    (timestamp . ,(format-time-string
                   "%Y-%m-%dT%H:%M:%S"
                   (or (chat-message-timestamp message)
                       (current-time))))
    (metadata . ,(or (chat-message-metadata message) nil))
    (toolCalls . ,(mapcar #'chat-session--serialize-tool-call
                          (or (chat-message-tool-calls message) nil)))
    (toolResults . ,(or (chat-message-tool-results message) nil))
    (rawRequest . ,(chat-message-raw-request message))
    (rawResponse . ,(chat-message-raw-response message))))

(defun chat-session--alist-get (alist key)
  "Get value for KEY from ALIST."
  (cdr (assoc key alist)))

(defun chat-session--serialize-tool-call (call)
  "Convert tool CALL plist to an alist."
  (list (cons 'name (plist-get call :name))
        (cons 'arguments (plist-get call :arguments))))

(defun chat-session--normalize-tool-call (call)
  "Normalize decoded JSON CALL into a plist."
  (cond
   ((and (consp call) (keywordp (car call)))
    call)
   ((listp call)
    (list :name (or (cdr (assoc 'name call))
                    (cdr (assoc "name" call)))
          :arguments (chat-session--normalize-tool-arguments
                      (or (cdr (assoc 'arguments call))
                          (cdr (assoc "arguments" call))))))
   (t
    call)))

(defun chat-session--normalize-tool-calls (calls)
  "Normalize decoded JSON CALLS list."
  (mapcar #'chat-session--normalize-tool-call calls))

(defun chat-session--normalize-tool-arguments (arguments)
  "Normalize tool ARGUMENTS keys to strings."
  (mapcar (lambda (entry)
            (cons (if (symbolp (car entry))
                      (symbol-name (car entry))
                    (car entry))
                  (cdr entry)))
          arguments))

(defun chat-session--normalize-list (value)
  "Convert VALUE vectors to lists."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   ((null value) nil)
   (t (list value))))

(defun chat-session--deserialize (data)
  "Convert JSON-parsed DATA to chat-session struct."
  (let ((auto-approve-val (chat-session--alist-get data 'autoApprove)))
    (make-chat-session
     :id (chat-session--alist-get data 'id)
     :name (chat-session--alist-get data 'name)
     :created-at (decode-time
                  (parse-time-string
                   (chat-session--alist-get data 'createdAt)))
     :updated-at (decode-time
                  (parse-time-string
                   (chat-session--alist-get data 'updatedAt)))
     :model-id (intern (chat-session--alist-get data 'modelId))
     :messages (mapcar #'chat-message--deserialize
                       (chat-session--alist-get data 'messages))
     :auto-approve (cond ((eq auto-approve-val t) t)
                         ((eq auto-approve-val :json-false) nil)
                         ((eq auto-approve-val 'inherit) 'inherit)
                         (t nil))  ; default to nil (follow global)
     :metadata (chat-session--alist-get data 'metadata))))

(defun chat-message--deserialize (data)
  "Convert JSON-parsed DATA to chat-message struct."
  (make-chat-message
   :id (chat-session--alist-get data 'id)
   :role (intern (chat-session--alist-get data 'role))
   :content (chat-session--alist-get data 'content)
   :timestamp (decode-time
               (parse-time-string
                (chat-session--alist-get data 'timestamp)))
   :metadata (chat-session--alist-get data 'metadata)
   :tool-calls (chat-session--normalize-tool-calls
                (chat-session--alist-get data 'toolCalls))
   :tool-results (chat-session--normalize-list
                  (chat-session--alist-get data 'toolResults))
   :raw-request (chat-session--alist-get data 'rawRequest)
   :raw-response (chat-session--alist-get data 'rawResponse)))

;; ------------------------------------------------------------------
;; Utility Functions
;; ------------------------------------------------------------------

(defun chat-session-get (session-id)
  "Get session by SESSION-ID, loading from disk if necessary.

Returns the chat-session struct, or nil if not found."
  (chat-session-load session-id))

(defun chat-session-exists-p (session-id)
  "Check if session with SESSION-ID exists on disk."
  (file-exists-p
   (expand-file-name
    (format "%s.json" session-id)
    chat-session-directory)))

;; ------------------------------------------------------------------
;; Auto-Approval
;; ------------------------------------------------------------------

(defun chat-session-auto-approve-p (session)
  "Return non-nil when SESSION has auto-approve enabled.
Returns nil if explicitly disabled, t if explicitly enabled,
and follows global setting if `inherit' or nil."
  (let ((setting (chat-session-auto-approve session)))
    (cond
     ((eq setting t) t)
     ((eq setting nil)
      ;; Check if explicitly set to nil or just default
      (and (boundp 'chat-approval-auto-approve-global)
           chat-approval-auto-approve-global))
     (t
      ;; 'inherit or any other value - use global
      (and (boundp 'chat-approval-auto-approve-global)
           chat-approval-auto-approve-global)))))

(defun chat-session-set-auto-approve (session value)
  "Set SESSION's auto-approve setting to VALUE.
VALUE should be t, nil, or `inherit'."
  (setf (chat-session-auto-approve session) value)
  (setf (chat-session-updated-at session) (current-time))
  (when chat-session-auto-save
    (chat-session-save session)))

(provide 'chat-session)
;;; chat-session.el ends here
