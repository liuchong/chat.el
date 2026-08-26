;;; chat-context.el --- Context window management -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:
;; Manages conversation context window for long conversations.

;;; Code:

(require 'cl-lib)
(require 'chat-session)
(require 'json)
(require 'subr-x)

(defcustom chat-context-max-tokens 8000
  "Maximum tokens to send in a request."
  :type 'integer
  :group 'chat)

(defcustom chat-context-summary-max-chars 600
  "Maximum characters kept in generated context summaries."
  :type 'integer
  :group 'chat)

(defcustom chat-context-durable-summary-max-chars 2400
  "Maximum characters kept in a durable session summary."
  :type 'integer
  :group 'chat)

(defcustom chat-context-auto-compact t
  "When non-nil, persist a summary before an over-budget agent step."
  :type 'boolean
  :group 'chat)

(defun chat-context-count-tokens (text)
  "Estimate token count for TEXT (rough approximation)."
  (if (string-blank-p text)
      0
    (ceiling (/ (length text) 4.0))))

(defun chat-context--tool-calls-snippet (msg)
  "Return a short snippet of tool calls from MSG."
  (when-let ((tool-calls (chat-message-tool-calls msg)))
    (chat-context--message-snippet
     (mapconcat (lambda (call)
                  ;; Each piece is cut to snippet length before being
                  ;; joined, so one tool call carrying a file does not
                  ;; get copied whole to contribute a few words.
                  (format "%s %s"
                          (plist-get call :name)
                          (chat-context--snippet-head
                           (format "%s" (or (plist-get call :arguments) "")))))
                tool-calls
                " | "))))

(defun chat-context--argument-tokens (arguments)
  "Estimate tokens for tool call ARGUMENTS as the request will encode them.
Mirrors `chat-llm--tool-call-payload': a string goes out as itself, and
anything else is JSON on the wire."
  (cond
   ((stringp arguments) (chat-context-count-tokens arguments))
   ((null arguments) 0)
   (t (chat-context-count-tokens (json-encode arguments)))))

(defun chat-context-message-tokens (msg)
  "Estimate token count for MSG as the request will carry it.

Counted from the fields that go on the wire, not from the snippets a
summary would show.  Those snippets are capped at 120 characters, so a
100KB tool result -- which the request carries in full and which is some
25,000 tokens -- was counted as 30.  Measured on a 41-message coding
session, that under-counted the context by 8.4x, which is how a budget
comes to believe it has room the provider will refuse.

Counting by `length' also stops the estimate from building the strings it
was throwing away: the snippets concatenated every tool result and ran a
regexp over the whole thing to keep a preview, and this runs for every
message on every send."
  (+ 4
     (chat-context-count-tokens (or (chat-message-content msg) ""))
     (cl-loop for call in (chat-message-tool-calls msg)
              sum (+ (chat-context-count-tokens (or (plist-get call :name) ""))
                     (chat-context--argument-tokens
                      (plist-get call :arguments))))
     (cl-loop for result in (chat-message-tool-results msg)
              sum (chat-context-count-tokens (or result "")))))

(defun chat-context-total-tokens (msgs)
  "Calculate total token count for MSGS."
  (if msgs
      (apply #'+ (mapcar #'chat-context-message-tokens msgs))
    0))

(defun chat-context--message-role-name (msg)
  "Return a readable role name for MSG."
  (string-remove-prefix ":" (symbol-name (chat-message-role msg))))

(defconst chat-context--snippet-columns 120
  "Display columns a snippet is allowed.")

(defun chat-context--snippet-head (text)
  "Return enough of TEXT for a snippet, and no more.

The cap is in columns and the input can be a whole file, so the head is
taken first: collapsing whitespace across 100KB to keep 120 characters of
it allocates the 100KB twice over.  Four characters per column covers
whitespace runs collapsing and leaves the truncation below to do the
exact work.  Zero-width and combining characters can defeat the bound, so
this is a cheap head rather than a promise."
  (let ((text (or text "")))
    (if (<= (length text) (* 4 chat-context--snippet-columns))
        text
      (substring text 0 (* 4 chat-context--snippet-columns)))))

(defun chat-context--message-snippet (text)
  "Return a short snippet for TEXT."
  (let* ((head (chat-context--snippet-head text))
         (clean (replace-regexp-in-string "[\n\r\t ]+" " " head))
         (trimmed (string-trim clean)))
    (truncate-string-to-width trimmed chat-context--snippet-columns nil nil t)))

(defun chat-context--tool-results-snippet (msg)
  "Return a short snippet of tool results from MSG."
  (when-let ((tool-results (chat-message-tool-results msg)))
    (chat-context--message-snippet
     (mapconcat #'chat-context--snippet-head tool-results " | "))))

(defun chat-context--summarize-message (msg)
  "Return a one line summary for MSG."
  (let* ((role (chat-context--message-role-name msg))
         (content (chat-context--message-snippet (chat-message-content msg)))
         (tool-calls (chat-context--tool-calls-snippet msg))
         (tool-results (chat-context--tool-results-snippet msg)))
    (string-trim
     (mapconcat #'identity
                (delq nil
                      (list role
                            (unless (string-blank-p content) content)
                            (when tool-calls
                              (format "tool-calls %s" tool-calls))
                            (when tool-results
                              (format "tool-results %s" tool-results))))
                ": "))))

(defun chat-context--summary-message (msgs)
  "Build a synthetic system summary for MSGS."
  (let* ((lines (mapcar #'chat-context--summarize-message msgs))
         (body (truncate-string-to-width
                (mapconcat #'identity lines "\n")
                chat-context-summary-max-chars nil nil t)))
    (make-chat-message
     :id "context-summary"
     :role :system
     :content (concat "Earlier conversation summary:\n" body)
     :timestamp (current-time))))

(defun chat-context--summary-metadata (entry)
  "Return metadata alist from summary ENTRY."
  (cdr (assoc 'metadata entry)))

(defun chat-context--summary-through-id (entry)
  "Return the covered message id from summary ENTRY."
  (when entry
    (let ((metadata (chat-context--summary-metadata entry)))
      (or (cdr (assoc 'throughMessageId metadata))
          (cdr (assoc "throughMessageId" metadata))))))

(defun chat-context--latest-session-summary (session)
  "Return the latest durable summary for SESSION."
  (car (last (chat-session-summaries session))))

(defun chat-context--summary-covered-index (session entry)
  "Return the message index covered by summary ENTRY in SESSION."
  (when-let ((id (chat-context--summary-through-id entry)))
    (cl-position id (chat-session-messages session)
                 :key #'chat-message-id
                 :test #'equal)))

(defun chat-context--leading-system-count (messages)
  "Return the number of leading system MESSAGES."
  (length (car (chat-context--partition-system-messages messages))))

(defun chat-context--compaction-plan (session max-tokens)
  "Return a safe compaction plan for SESSION under MAX-TOKENS."
  (let* ((messages (chat-session-messages session))
         (latest (chat-context--latest-session-summary session))
         (covered (chat-context--summary-covered-index session latest))
         (start (max (chat-context--leading-system-count messages)
                     (if covered (1+ covered) 0)))
         (keep-budget (max 1 (floor (* max-tokens 0.55))))
         (tokens 0)
         (keep-start (length messages)))
    (cl-loop for index downfrom (1- (length messages)) to start
             for message = (nth index messages)
             for cost = (chat-context-message-tokens message)
             while (<= (+ tokens cost) keep-budget)
             do (setq tokens (+ tokens cost)
                      keep-start index))
    (let* ((max-cut (- keep-start 1))
           (safe-cut (and (>= max-cut start)
                          (chat-session-tool-pair-safe-cut-index
                           session max-cut))))
      (when (and safe-cut (>= safe-cut start))
        (list :start start
              :cut safe-cut
              :messages (cl-subseq messages start (1+ safe-cut))
              :previous latest)))))

(defun chat-context--durable-summary-text (previous messages)
  "Build a deterministic durable summary from PREVIOUS and MESSAGES."
  (let* ((previous-text (and previous (cdr (assoc 'summary previous))))
         (lines
          (append
           (when (and previous-text (not (string-blank-p previous-text)))
             (list (format "Previous summary: %s" previous-text)))
           (mapcar #'chat-context--summarize-message messages))))
    (truncate-string-to-width
     (mapconcat #'identity lines "\n")
     chat-context-durable-summary-max-chars nil nil t)))

(defun chat-context--persist-compaction
    (session plan summary kind)
  "Persist SUMMARY for SESSION according to PLAN and KIND."
  (let* ((cut (plist-get plan :cut))
         (through (nth cut (chat-session-messages session))))
    (chat-session-add-summary
     session summary
     `((throughMessageId . ,(chat-message-id through))
       (messageCount . ,(1+ cut))
       (kind . ,kind)))))

(defun chat-context-compact-session (session max-tokens &optional summary kind)
  "Compact one safe prefix of SESSION for MAX-TOKENS.
When SUMMARY is nil, use the deterministic fallback. KIND labels the
durable record and defaults to \"automatic\"."
  (when-let ((plan (chat-context--compaction-plan session max-tokens)))
    (chat-context--persist-compaction
     session
     plan
     (or summary
         (chat-context--durable-summary-text
          (plist-get plan :previous)
          (plist-get plan :messages)))
     (or kind "automatic"))))

(defun chat-context--apply-session-summary (messages session)
  "Replace the covered prefix of MESSAGES with SESSION's latest summary."
  (let* ((entry (chat-context--latest-session-summary session))
         (through-id (chat-context--summary-through-id entry)))
    (if (not through-id)
        messages
      (pcase-let* ((`(,systems ,conversation)
                    (chat-context--partition-system-messages messages))
                   (index (cl-position through-id conversation
                                       :key #'chat-message-id
                                       :test #'equal)))
        (if (null index)
            messages
          (append
           systems
           (list
            (make-chat-message
             :id (format "durable-summary-%s"
                         (or (cdr (assoc 'id entry)) through-id))
             :role :system
             :content (concat "Earlier conversation summary:\n"
                              (or (cdr (assoc 'summary entry)) ""))
             :timestamp (current-time)
             :metadata (list :durable-summary t
                             :through-message-id through-id)))
           (nthcdr (1+ index) conversation)))))))

(defun chat-context-compact-session-with-llm
    (session callback error-callback &optional max-tokens)
  "Summarize one SESSION prefix with its model, then invoke CALLBACK.
ERROR-CALLBACK receives transport errors."
  (let* ((max (or max-tokens chat-context-max-tokens))
         (plan (chat-context--compaction-plan session max)))
    (unless plan
      (error "No safe session prefix is available for compaction"))
    (require 'chat-llm)
    (let* ((previous (plist-get plan :previous))
           (source (chat-context--durable-summary-text
                    previous (plist-get plan :messages)))
           (messages
            (list
             (make-chat-message
              :id (chat-session-new-message-id "compact-system")
              :role :system
              :content
              "Summarize the conversation faithfully. Preserve decisions, constraints, unresolved tasks, and tool outcomes. Do not add facts."
              :timestamp (current-time))
             (make-chat-message
              :id (chat-session-new-message-id "compact-user")
              :role :user
              :content source
              :timestamp (current-time)))))
      (chat-llm-request-async
       (chat-session-model-id session)
       messages
       (lambda (result)
         (let ((summary (string-trim (or (plist-get result :content) ""))))
           (if (string-empty-p summary)
               (funcall error-callback "Compaction returned an empty summary")
             (funcall
              callback
              (chat-context--persist-compaction
               session plan summary "llm")))))
       error-callback
       (list :temperature 0.1)))))

;;;###autoload
(defun chat-context-compact-current-session ()
  "Run durable LLM compaction for the active session.

There is one place to look: a coding session is an ordinary chat session
carrying code capability, so it is in the same variable as any other."
  (interactive)
  (let ((session (bound-and-true-p chat--current-session)))
    (unless session
      (user-error "No active session"))
    (chat-context-compact-session-with-llm
     session
     (lambda (_entry) (message "Session compaction completed"))
     (lambda (error-message)
       (message "Session compaction failed: %s" error-message)))))

(defun chat-context--partition-system-messages (msgs)
  "Split MSGS into leading system messages and the remaining messages."
  (let ((systems nil)
        (rest msgs)
        done)
    (while (and rest (not done))
      (if (eq (chat-message-role (car rest)) :system)
          (progn
            (push (car rest) systems)
            (setq rest (cdr rest)))
        (setq done t)))
    (list (nreverse systems) rest)))

(defun chat-context-sliding-window (msgs max-tokens)
  "Keep most recent MSGS that fit within MAX-TOKENS."
  (let ((result nil)
        (current 0))
    ;; Add from end until limit
    (dolist (msg (reverse msgs))
      (let ((tokens (chat-context-message-tokens msg)))
        (if (<= (+ current tokens) max-tokens)
            (progn (push msg result)
                   (setq current (+ current tokens)))
          nil)))
    result))

(defun chat-context--recent-window-with-summary (msgs max-tokens)
  "Keep leading system messages plus a recent window under MAX-TOKENS."
  (pcase-let* ((`(,system-messages ,conversation)
                (chat-context--partition-system-messages msgs))
               (system-tokens (chat-context-total-tokens system-messages))
               (summary-template (chat-context--summary-message conversation))
               (summary-tokens (chat-context-message-tokens summary-template))
               (latest-message (car (last conversation)))
               (latest-tokens (if latest-message
                                  (chat-context-message-tokens latest-message)
                                0))
               (older-messages (if latest-message
                                   (butlast conversation)
                                 nil))
               (budget-with-summary (max 0 (- max-tokens system-tokens summary-tokens latest-tokens)))
               (recent-older (chat-context-sliding-window older-messages budget-with-summary))
               (recent (append recent-older
                               (if latest-message
                                   (list latest-message)
                                 nil)))
               (omitted-count (- (length conversation) (length recent))))
    (if (<= omitted-count 0)
        (append system-messages recent)
      (append system-messages
              (list (chat-context--summary-message
                     (cl-subseq conversation 0 omitted-count)))
              recent))))

;;;###autoload
(defun chat-context-prepare-messages
    (msgs &optional max-tokens session)
  "Prepare MSGS for API request, optionally using durable SESSION state."
  (unless (cl-every #'chat-message-p msgs)
    (cl-return-from chat-context-prepare-messages msgs))
  (let ((max (or max-tokens chat-context-max-tokens)))
    (when (and session
               chat-context-auto-compact
               (> (chat-context-total-tokens
                   (chat-context--apply-session-summary msgs session))
                  max))
      (let ((attempts 0)
            compacted)
        (while (and (< attempts 8)
                    (> (chat-context-total-tokens
                        (chat-context--apply-session-summary msgs session))
                       max)
                    (setq compacted
                          (chat-context-compact-session session max)))
          (setq attempts (1+ attempts)))))
    (let ((prepared (if session
                        (chat-context--apply-session-summary msgs session)
                      msgs)))
      (if (<= (chat-context-total-tokens prepared) max)
          prepared
        (chat-context--recent-window-with-summary prepared max)))))

(provide 'chat-context)
;;; chat-context.el ends here
