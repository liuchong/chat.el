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
  parent-session-id     ; Optional parent session for branch trees
  branch-id             ; Optional branch identifier
  leaf-message-id       ; Current leaf message ID for branch UIs
  summaries             ; Durable compaction or branch summary records
  recovery-state        ; Computed interrupted-run recovery metadata
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
                   :tool-config nil
                   :parent-session-id nil
                   :branch-id id
                   :leaf-message-id nil
                   :summaries nil
                   :recovery-state nil
                   :metadata nil)))
    (when chat-session-auto-save
      (chat-session-save session))
    session))

(defvar chat-session--message-counter 0
  "Monotonic counter for unique message identifiers.")

(defun chat-session-new-message-id (&optional prefix)
  "Return a message id that is unique within this Emacs process.
PREFIX defaults to \"msg\"."
  (format "%s-%s-%d"
          (or prefix "msg")
          (format-time-string "%Y%m%d%H%M%S")
          (cl-incf chat-session--message-counter)))

(defconst chat-session-format-version 1
  "Version of the JSONL session file format.")

(defun chat-session--file-name (session-id)
  "Return the JSONL session file name for SESSION-ID."
  (expand-file-name (format "%s.jsonl" session-id)
                    chat-session-directory))

(defun chat-session--legacy-file-name (session-id)
  "Return the legacy JSON session file name for SESSION-ID."
  (expand-file-name (format "%s.json" session-id)
                    chat-session-directory))

(defun chat-session--header-entry (session)
  "Return the JSONL header entry for SESSION."
  (list (cons 'type "header")
        (cons 'version chat-session-format-version)
        (cons 'id (chat-session-id session))
        (cons 'name (chat-session-name session))
        (cons 'createdAt (format-time-string
                          "%Y-%m-%dT%H:%M:%S"
                          (chat-session-created-at session)))
        (cons 'modelId (symbol-name (chat-session-model-id session)))))

(defun chat-session--state-entry (session)
  "Return the JSONL state entry for SESSION."
  (list (cons 'type "state")
        (cons 'name (chat-session-name session))
        (cons 'updatedAt (format-time-string
                          "%Y-%m-%dT%H:%M:%S"
                          (chat-session-updated-at session)))
        (cons 'autoApprove (let ((aa (chat-session-auto-approve session)))
                             (cond ((eq aa t) t)
                                   ((eq aa nil) :json-false)
                                   (t 'inherit))))
        (cons 'toolConfig (chat-session--plist-to-alist
                           (chat-session-tool-config session)))
        (cons 'parentSessionId (chat-session-parent-session-id session))
        (cons 'branchId (chat-session-branch-id session))
        (cons 'leafMessageId (chat-session-leaf-message-id session))
        (cons 'summaries (or (chat-session-summaries session) nil))
        (cons 'metadata (or (chat-session-metadata session) nil))))

(defun chat-session--message-entry (message)
  "Return the JSONL message entry for MESSAGE."
  (cons (cons 'type "message")
        (chat-message--serialize message)))

(defun chat-session-save (session)
  "Save SESSION to disk as a JSONL file.

The file holds a header entry, a state entry, and one entry per
message.  The write is atomic: content goes to a temporary file first
and is renamed over the target, so a crash mid-save cannot corrupt
the previous session file.
Returns t on success, nil on failure."
  (chat-session--ensure-directory)
  (let* ((filename (chat-session--file-name (chat-session-id session)))
         (temp-file (make-temp-file
                     (expand-file-name ".session-" chat-session-directory)
                     nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert (json-encode (chat-session--header-entry session)) "\n")
            (insert (json-encode (chat-session--state-entry session)) "\n")
            (dolist (message (chat-session-messages session))
              (insert (json-encode (chat-session--message-entry message)) "\n")))
          (rename-file temp-file filename t)
          t)
      (when (file-exists-p temp-file)
        (delete-file temp-file)))))

(defun chat-session--append-message (session message)
  "Append MESSAGE and a fresh state entry to the session JSONL file.
Falls back to a full save when the file is missing."
  (let ((filename (chat-session--file-name (chat-session-id session))))
    (if (not (file-exists-p filename))
        (chat-session-save session)
      (chat-session--ensure-jsonl-boundary filename)
      (write-region
       (concat (json-encode (chat-session--message-entry message)) "\n"
               (json-encode (chat-session--state-entry session)) "\n")
       nil
       filename
       'append
       'silent)
      t)))

(defun chat-session--ensure-jsonl-boundary (filename)
  "Ensure FILENAME ends at a JSONL record boundary before appending."
  (when (and (file-exists-p filename)
             (> (file-attribute-size (file-attributes filename)) 0))
    (with-temp-buffer
      (let ((size (file-attribute-size (file-attributes filename))))
        (insert-file-contents-literally filename nil (1- size) size)
        (unless (eq (char-before (point-max)) ?\n)
          (write-region "\n" nil filename 'append 'silent))))))

(defun chat-session--load-jsonl (filename)
  "Load a session from the JSONL file FILENAME.
Later state entries override earlier ones.  Corrupt lines are
skipped."
  (with-temp-buffer
    (insert-file-contents filename)
    (goto-char (point-min))
    (let (header state message-datas)
      (while (not (eobp))
        (let ((line (string-trim
                     (buffer-substring-no-properties
                      (line-beginning-position)
                      (line-end-position)))))
          (unless (string-empty-p line)
            (let ((entry (condition-case nil
                             (json-read-from-string line)
                           (error nil))))
              (when entry
                (pcase (cdr (assoc 'type entry))
                  ("header" (setq header entry))
                  ("state" (setq state entry))
                  ("message" (push entry message-datas)))))))
        (forward-line 1))
      (when header
        (chat-session--deserialize
         (list (cons 'id (cdr (assoc 'id header)))
               (cons 'name (or (and state (cdr (assoc 'name state)))
                               (cdr (assoc 'name header))))
               (cons 'createdAt (cdr (assoc 'createdAt header)))
               (cons 'updatedAt (or (and state (cdr (assoc 'updatedAt state)))
                                    (cdr (assoc 'createdAt header))))
               (cons 'modelId (cdr (assoc 'modelId header)))
               (cons 'messages (nreverse message-datas))
               (cons 'autoApprove (and state (cdr (assoc 'autoApprove state))))
               (cons 'toolConfig (and state
                                      (assoc 'toolConfig state)
                                      (cdr (assoc 'toolConfig state))))
               (cons 'parentSessionId (and state
                                           (cdr (assoc 'parentSessionId state))))
               (cons 'branchId (and state
                                    (cdr (assoc 'branchId state))))
               (cons 'leafMessageId (and state
                                         (cdr (assoc 'leafMessageId state))))
               (cons 'summaries (and state
                                     (assoc 'summaries state)
                                     (cdr (assoc 'summaries state))))
               (cons 'metadata (and state
                                    (assoc 'metadata state)
                                    (cdr (assoc 'metadata state))))))))))

(defun chat-session-load (session-id)
  "Load session with SESSION-ID from disk.

Reads the JSONL file when present.  A legacy JSON file is loaded and
migrated to JSONL transparently.
Returns the chat-session struct, or nil if not found or unreadable."
  (let ((filename (chat-session--file-name session-id))
        (legacy (chat-session--legacy-file-name session-id)))
    (cond
     ((file-exists-p filename)
      (condition-case nil
          (chat-session--load-jsonl filename)
        (error nil)))
     ((file-exists-p legacy)
      (let ((session (condition-case nil
                         (with-temp-buffer
                           (insert-file-contents legacy)
                           (chat-session--deserialize
                            (json-read-from-string (buffer-string))))
                       (error nil))))
        (when session
          (when (chat-session-save session)
            (delete-file legacy)))
        session)))))

(defun chat-session-delete (session-id)
  "Delete session with SESSION-ID from disk.

Returns t if deleted, nil if file did not exist."
  (let ((filename (chat-session--file-name session-id))
        (legacy (chat-session--legacy-file-name session-id))
        (deleted nil))
    (when (file-exists-p filename)
      (delete-file filename)
      (setq deleted t))
    (when (file-exists-p legacy)
      (delete-file legacy)
      (setq deleted t))
    deleted))

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

JSONL files take precedence over legacy JSON files for the same
session id.  Returns a list of chat-session structs, sorted by
updated-at descending."
  (chat-session--ensure-directory)
  (let (sessions
        (seen (make-hash-table :test 'equal)))
    (dolist (file (append
                   (directory-files
                    chat-session-directory
                    t
                    "\\.jsonl$")
                   (directory-files
                    chat-session-directory
                    t
                    "\\.json$")))
      (let ((id (file-name-base file)))
        (unless (gethash id seen)
          (puthash id t seen)
          (let ((session (condition-case nil
                             (chat-session-load id)
                           (error nil))))
            (when session
              (push session sessions))))))
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
  (setf (chat-session-leaf-message-id session)
        (chat-message-id message))
  (setf (chat-session-updated-at session)
        (current-time))
  (when chat-session-auto-save
    (chat-session--append-message session message)))

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
      (setf (chat-session-leaf-message-id session)
            (when-let ((last-message (car (last (chat-session-messages session)))))
              (chat-message-id last-message)))
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
    (toolConfig . ,(chat-session--plist-to-alist
                    (chat-session-tool-config session)))
    (parentSessionId . ,(chat-session-parent-session-id session))
    (branchId . ,(chat-session-branch-id session))
    (leafMessageId . ,(chat-session-leaf-message-id session))
    (summaries . ,(or (chat-session-summaries session) nil))
    (metadata . ,(or (chat-session-metadata session) nil))))

(defun chat-session--plist-to-alist (plist)
  "Convert keyword PLIST to a JSON-friendly alist."
  (when plist
    (let (items)
      (while plist
        (let ((key (pop plist))
              (value (pop plist)))
          (push (cons (if (keywordp key)
                          (substring (symbol-name key) 1)
                        (symbol-name key))
                      (cond
                       ((eq value nil) :json-false)
                       ((and (listp value)
                             (cl-every #'symbolp value))
                        (vconcat (mapcar #'symbol-name value)))
                       (t value)))
                items)))
      (nreverse items))))

(defun chat-session--alist-to-plist (alist)
  "Convert decoded ALIST to a keyword plist."
  (let (plist)
    (dolist (entry alist)
      (let ((key (let ((raw (car entry)))
                   (cond
                    ((keywordp raw) raw)
                    ((symbolp raw)
                     (intern (format ":%s" (symbol-name raw))))
                    (t
                     (intern (format ":%s" raw))))))
            (value (cdr entry)))
        (push key plist)
        (push (cond
               ((eq value :json-false) nil)
               ((vectorp value)
                (mapcar #'intern (append value nil)))
               ((and (listp value)
                     (cl-every #'stringp value))
                (mapcar #'intern value))
               (t value))
              plist)))
    (nreverse plist)))

(defun chat-message--serialize (message)
  "Convert MESSAGE struct to JSON-serializable alist."
  `((id . ,(chat-message-id message))
    (role . ,(symbol-name (chat-message-role message)))
    (content . ,(chat-message-content message))
    (timestamp . ,(format-time-string
                   "%Y-%m-%dT%H:%M:%S"
                   (or (chat-message-timestamp message)
                       (current-time))))
    (parentId . ,(chat-message-parent-id message))
    (branchIds . ,(or (chat-message-branch-ids message) nil))
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
  (append
   (when-let ((id (plist-get call :id)))
     (list (cons 'id id)))
   (list (cons 'name (plist-get call :name))
         (cons 'arguments (plist-get call :arguments)))))

(defun chat-session--normalize-tool-call (call)
  "Normalize decoded JSON CALL into a plist."
  (cond
   ((and (consp call) (keywordp (car call)))
    call)
   ((listp call)
    (append
     (when-let ((id (or (cdr (assoc 'id call))
                        (cdr (assoc "id" call)))))
       (list :id id))
     (list :name (or (cdr (assoc 'name call))
                     (cdr (assoc "name" call)))
           :arguments (chat-session--normalize-tool-arguments
                       (or (cdr (assoc 'arguments call))
                           (cdr (assoc "arguments" call)))))))
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
    (let ((session
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
            :tool-config (chat-session--alist-to-plist
                          (chat-session--alist-get data 'toolConfig))
            :parent-session-id (chat-session--alist-get data 'parentSessionId)
            :branch-id (or (chat-session--alist-get data 'branchId)
                           (chat-session--alist-get data 'id))
            :leaf-message-id (chat-session--alist-get data 'leafMessageId)
            :summaries (chat-session--normalize-list
                        (chat-session--alist-get data 'summaries))
            :auto-approve (cond ((eq auto-approve-val t) t)
                                ((eq auto-approve-val :json-false) nil)
                                ((eq auto-approve-val 'inherit) 'inherit)
                                (t nil))  ; default to nil (follow global)
            :metadata (chat-session--alist-get data 'metadata))))
      (unless (chat-session-leaf-message-id session)
        (setf (chat-session-leaf-message-id session)
              (when-let ((last-message (car (last (chat-session-messages session)))))
                (chat-message-id last-message))))
      (setf (chat-session-recovery-state session)
            (chat-session-detect-interrupted-run session))
      session)))

(defun chat-session-set-tool-config (session config)
  "Set SESSION tool CONFIG and persist the session state."
  (setf (chat-session-tool-config session) config)
  (setf (chat-session-updated-at session) (current-time))
  (when chat-session-auto-save
    (chat-session-save session))
  config)

(defun chat-session-tool-enabled-p (session tool-id)
  "Return non-nil when TOOL-ID is allowed by SESSION tool config."
  (let* ((config (and session (chat-session-tool-config session)))
         (enabled (plist-get config :enabled-tools))
         (disabled (plist-get config :disabled-tools)))
    (and (or (null enabled)
             (memq tool-id enabled))
         (not (memq tool-id disabled)))))

(defun chat-session-set-tree-info (session &rest plist)
  "Set SESSION tree metadata from PLIST.
Recognized keys are `:parent-session-id', `:branch-id', and
`:leaf-message-id'."
  (when (plist-member plist :parent-session-id)
    (setf (chat-session-parent-session-id session)
          (plist-get plist :parent-session-id)))
  (when (plist-member plist :branch-id)
    (setf (chat-session-branch-id session)
          (plist-get plist :branch-id)))
  (when (plist-member plist :leaf-message-id)
    (setf (chat-session-leaf-message-id session)
          (plist-get plist :leaf-message-id)))
  (setf (chat-session-updated-at session) (current-time))
  (when chat-session-auto-save
    (chat-session-save session))
  session)

(defun chat-session-add-summary (session summary &optional metadata)
  "Append durable SUMMARY with optional METADATA to SESSION."
  (let ((entry `((id . ,(chat-session-new-message-id "summary"))
                 (createdAt . ,(format-time-string
                                "%Y-%m-%dT%H:%M:%S"
                                (current-time)))
                 (leafMessageId . ,(chat-session-leaf-message-id session))
                 (summary . ,summary)
                 (metadata . ,(or metadata nil)))))
    (setf (chat-session-summaries session)
          (append (chat-session-summaries session) (list entry)))
    (setf (chat-session-updated-at session) (current-time))
    (when chat-session-auto-save
      (chat-session-save session))
    entry))

(defun chat-session--tool-call-ids (message)
  "Return tool call ids declared by assistant MESSAGE."
  (delq nil
        (mapcar (lambda (call)
                  (plist-get call :id))
                (or (chat-message-tool-calls message) nil))))

(defun chat-session--tool-result-id (message)
  "Return tool call id satisfied by tool MESSAGE."
  (plist-get (chat-message-metadata message) :tool-call-id))

(defun chat-session-detect-interrupted-run (session)
  "Return recovery metadata when SESSION ends with unfinished tool calls."
  (let ((pending nil)
        last-assistant-id)
    (dolist (message (chat-session-messages session))
      (pcase (chat-message-role message)
        (:assistant
         (let ((ids (chat-session--tool-call-ids message)))
           (when ids
             (setq pending ids
                   last-assistant-id (chat-message-id message)))))
        (:tool
         (when-let ((id (chat-session--tool-result-id message)))
           (setq pending (cl-remove id pending :test #'equal))))))
    (when pending
      (list :type 'interrupted-tool-run
            :assistant-message-id last-assistant-id
            :missing-tool-call-ids pending))))

(defun chat-session-tool-pair-safe-cut-index (session max-index)
  "Return the largest safe compaction cut index not above MAX-INDEX.
The returned index never cuts between an assistant tool call and its
matching `:tool' result."
  (let ((messages (chat-session-messages session))
        (index -1)
        (pending nil)
        safe-index)
    (dolist (message messages)
      (when (<= (cl-incf index) max-index)
        (pcase (chat-message-role message)
          (:assistant
           (setq pending
                 (append pending (chat-session--tool-call-ids message))))
          (:tool
           (when-let ((id (chat-session--tool-result-id message)))
             (setq pending (cl-remove id pending :test #'equal)))))
        (unless pending
          (setq safe-index index))))
    safe-index))

(defun chat-message--deserialize (data)
  "Convert JSON-parsed DATA to chat-message struct."
  (make-chat-message
   :id (chat-session--alist-get data 'id)
   :role (intern (chat-session--alist-get data 'role))
   :content (chat-session--alist-get data 'content)
   :timestamp (decode-time
               (parse-time-string
                (chat-session--alist-get data 'timestamp)))
   :parent-id (chat-session--alist-get data 'parentId)
   :branch-ids (chat-session--normalize-list
                (chat-session--alist-get data 'branchIds))
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
  (or (file-exists-p (chat-session--file-name session-id))
      (file-exists-p (chat-session--legacy-file-name session-id))))

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
