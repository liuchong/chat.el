;;; chat-repl.el --- Persistent isolated REPL runtime -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Language adapters provide framing only.  Durable identity, bounded output,
;; task serialization, execution isolation and restart reconciliation live here.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'chat-event)
(require 'chat-execution)
(require 'chat-session)
(require 'chat-task)

(declare-function chat-approval-dangerous-mode-p "chat-approval" (&optional session))

(defgroup chat-repl nil
  "Persistent REPL processes owned by chat sessions."
  :group 'chat)

(defconst chat-repl-schema-version 1
  "Current durable REPL schema version.")

(defconst chat-repl-statuses
  '(starting idle busy interrupted failed closed)
  "Valid REPL lifecycle states.")

(defcustom chat-repl-directory
  (expand-file-name "repl/" (expand-file-name "~/.chat/"))
  "Directory containing durable REPL records."
  :type 'directory
  :group 'chat-repl)

(defcustom chat-repl-code-limit 16384
  "Maximum input characters retained per transaction."
  :type 'integer
  :group 'chat-repl)

(defcustom chat-repl-output-limit 65536
  "Maximum output characters retained per transaction."
  :type 'integer
  :group 'chat-repl)

(defcustom chat-repl-history-limit 50
  "Maximum transactions retained for one REPL."
  :type 'integer
  :group 'chat-repl)

(defcustom chat-repl-event-chunk-limit 1024
  "Maximum output characters included in one runtime event."
  :type 'integer
  :group 'chat-repl)

(define-error 'chat-repl-error "REPL runtime error")
(define-error 'chat-repl-adapter-unavailable "REPL adapter is unavailable"
  'chat-repl-error)
(define-error 'chat-repl-state-error "REPL state does not permit the operation"
  'chat-repl-error)

(cl-defstruct
    (chat-repl-adapter (:constructor chat-repl-adapter-create))
  "One language-specific process and framing adapter."
  id label availability-function command-function submit-function)

(cl-defstruct
    (chat-repl-transaction (:constructor chat-repl-transaction-create))
  "One bounded evaluation record plus transient completion callbacks."
  id task-id code code-truncated-p output output-truncated-p status exit-status
  created-at started-at ended-at
  ;; Live fields are never serialized.
  done-function fail-function parser-state parser-buffer diagnostic wire-code)

(cl-defstruct
    (chat-repl-session (:constructor chat-repl-session-create))
  "One durable REPL identity plus transient process state."
  id chat-session-id adapter-id directory generation status execution-id
  created-at updated-at transactions
  ;; Live fields are never serialized.
  token active-transaction expected-stop-p)

(defvar chat-repl--adapters (make-hash-table :test 'eq)
  "Registered adapters keyed by stable symbol ID.")

(defvar chat-repl--sessions (make-hash-table :test 'equal)
  "Durable REPL sessions keyed by stable ID.")

(defvar chat-repl--selected (make-hash-table :test 'equal)
  "Selected non-closed REPL ID keyed by owning chat session ID.")

(defvar chat-repl--id-sequence 0
  "Process-local suffix used to disambiguate generated IDs.")

(defun chat-repl--timestamp-ms ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-repl--new-id (prefix)
  "Return a fresh ID beginning with PREFIX."
  (format "%s-%d-%d" prefix (chat-repl--timestamp-ms)
          (cl-incf chat-repl--id-sequence)))

(defun chat-repl--new-token ()
  "Return an unguessable process framing token."
  (secure-hash 'sha256
               (format "%s:%s:%s:%s"
                       (chat-repl--timestamp-ms) (random) (emacs-pid)
                       (chat-repl--new-id "token"))))

(defun chat-repl-register-adapter (adapter)
  "Register ADAPTER after validating its complete contract."
  (unless (and (chat-repl-adapter-p adapter)
               (symbolp (chat-repl-adapter-id adapter))
               (stringp (chat-repl-adapter-label adapter))
               (functionp (chat-repl-adapter-availability-function adapter))
               (functionp (chat-repl-adapter-command-function adapter))
               (functionp (chat-repl-adapter-submit-function adapter)))
    (signal 'chat-repl-error (list "invalid adapter" adapter)))
  (puthash (chat-repl-adapter-id adapter) adapter chat-repl--adapters)
  adapter)

(defun chat-repl-adapter (id)
  "Return registered adapter ID, or signal an explicit error."
  (or (gethash id chat-repl--adapters)
      (signal 'chat-repl-error (list "unknown adapter" id))))

(defun chat-repl-adapter-ids ()
  "Return available adapter IDs in canonical order."
  (let (ids)
    (maphash
     (lambda (id adapter)
       (when (funcall (chat-repl-adapter-availability-function adapter))
         (push id ids)))
     chat-repl--adapters)
    (sort ids (lambda (left right)
                (string< (symbol-name left) (symbol-name right))))))

(defun chat-repl--state-file ()
  "Return the durable REPL state path."
  (expand-file-name "sessions.json" chat-repl-directory))

(defun chat-repl--bounded-tail (text limit)
  "Return (VALUE . TRUNCATED) for TEXT constrained to LIMIT characters."
  (let ((text (or text "")))
    (if (> (length text) limit)
        (cons (substring text (- (length text) limit)) t)
      (cons text nil))))

(defun chat-repl--transaction-json (transaction)
  "Return durable JSON data for TRANSACTION."
  `((id . ,(chat-repl-transaction-id transaction))
    (taskId . ,(chat-repl-transaction-task-id transaction))
    (code . ,(chat-repl-transaction-code transaction))
    (codeTruncated . ,(and (chat-repl-transaction-code-truncated-p transaction) t))
    (output . ,(or (chat-repl-transaction-output transaction) ""))
    (outputTruncated . ,(and (chat-repl-transaction-output-truncated-p transaction) t))
    (status . ,(symbol-name (chat-repl-transaction-status transaction)))
    (exitStatus . ,(chat-repl-transaction-exit-status transaction))
    (createdAt . ,(chat-repl-transaction-created-at transaction))
    (startedAt . ,(chat-repl-transaction-started-at transaction))
    (endedAt . ,(chat-repl-transaction-ended-at transaction))))

(defun chat-repl--transaction-from-json (data)
  "Decode one transaction from DATA without restoring live callbacks."
  (chat-repl-transaction-create
   :id (alist-get 'id data)
   :task-id (alist-get 'taskId data)
   :code (or (alist-get 'code data) "")
   :code-truncated-p (and (alist-get 'codeTruncated data) t)
   :output (or (alist-get 'output data) "")
   :output-truncated-p (and (alist-get 'outputTruncated data) t)
   :status (intern (or (alist-get 'status data) "interrupted"))
   :exit-status (alist-get 'exitStatus data)
   :created-at (alist-get 'createdAt data)
   :started-at (alist-get 'startedAt data)
   :ended-at (alist-get 'endedAt data)))

(defun chat-repl--session-json (session)
  "Return durable JSON data for SESSION."
  `((schemaVersion . ,chat-repl-schema-version)
    (id . ,(chat-repl-session-id session))
    (chatSessionId . ,(chat-repl-session-chat-session-id session))
    (adapterId . ,(symbol-name (chat-repl-session-adapter-id session)))
    (directory . ,(chat-repl-session-directory session))
    (generation . ,(chat-repl-session-generation session))
    (status . ,(symbol-name (chat-repl-session-status session)))
    (executionId . ,(chat-repl-session-execution-id session))
    (createdAt . ,(chat-repl-session-created-at session))
    (updatedAt . ,(chat-repl-session-updated-at session))
    (transactions . ,(mapcar #'chat-repl--transaction-json
                             (chat-repl-session-transactions session)))))

(defun chat-repl--session-from-json (data)
  "Decode one REPL session from DATA without restoring a process."
  (unless (= (or (alist-get 'schemaVersion data) 0) chat-repl-schema-version)
    (signal 'chat-repl-error
            (list "unsupported REPL schema" (alist-get 'schemaVersion data))))
  (chat-repl-session-create
   :id (alist-get 'id data)
   :chat-session-id (alist-get 'chatSessionId data)
   :adapter-id (intern (alist-get 'adapterId data))
   :directory (alist-get 'directory data)
   :generation (or (alist-get 'generation data) 1)
   :status (intern (or (alist-get 'status data) "interrupted"))
   :execution-id (alist-get 'executionId data)
   :created-at (alist-get 'createdAt data)
   :updated-at (alist-get 'updatedAt data)
   :transactions (mapcar #'chat-repl--transaction-from-json
                         (alist-get 'transactions data))))

(defun chat-repl-save ()
  "Atomically persist bounded REPL records."
  (make-directory chat-repl-directory t)
  (set-file-modes chat-repl-directory #o700)
  (let ((target (chat-repl--state-file))
        (temp (make-temp-file (expand-file-name ".repl-" chat-repl-directory)))
        sessions)
    (unwind-protect
        (progn
          (maphash (lambda (_id session) (push session sessions))
                   chat-repl--sessions)
          (setq sessions
                (sort sessions
                      (lambda (left right)
                        (string< (chat-repl-session-id left)
                                 (chat-repl-session-id right)))))
          (with-temp-file temp
            (insert (json-encode
                     `((schemaVersion . ,chat-repl-schema-version)
                       (sessions . ,(mapcar #'chat-repl--session-json
                                           sessions))))))
          (set-file-modes temp #o600)
          (rename-file temp target t))
      (when (file-exists-p temp) (delete-file temp))))
  t)

(defun chat-repl--emit (session type &optional transaction payload)
  "Emit session-scoped TYPE for SESSION, TRANSACTION and bounded PAYLOAD."
  (chat-event-emit
   type
   :session-id (chat-repl-session-chat-session-id session)
   :task-id (and transaction (chat-repl-transaction-task-id transaction))
   :source 'repl
   :payload
   (append
    `((repl_id . ,(chat-repl-session-id session))
      (adapter . ,(symbol-name (chat-repl-session-adapter-id session)))
      (generation . ,(chat-repl-session-generation session))
      (status . ,(symbol-name (chat-repl-session-status session))))
    (and transaction
         `((transaction_id . ,(chat-repl-transaction-id transaction))))
    payload)))

(defun chat-repl-load ()
  "Load REPL records, marking stale active state interrupted without replay."
  (clrhash chat-repl--sessions)
  (clrhash chat-repl--selected)
  (let ((file (chat-repl--state-file))
        changed)
    (when (file-exists-p file)
      (let* ((json-array-type 'list)
             (data (with-temp-buffer
                     (insert-file-contents file)
                     (json-read-from-string (buffer-string)))))
        (unless (= (or (alist-get 'schemaVersion data) 0)
                   chat-repl-schema-version)
          (signal 'chat-repl-error
                  (list "unsupported REPL state schema"
                        (alist-get 'schemaVersion data))))
        (dolist (entry (alist-get 'sessions data))
          (let ((session (chat-repl--session-from-json entry)))
            (when (memq (chat-repl-session-status session)
                        '(starting idle busy))
              (setf (chat-repl-session-status session) 'interrupted
                    (chat-repl-session-updated-at session)
                    (chat-repl--timestamp-ms))
              (dolist (transaction (chat-repl-session-transactions session))
                (when (memq (chat-repl-transaction-status transaction)
                            '(queued running))
                  (setf (chat-repl-transaction-status transaction) 'interrupted
                        (chat-repl-transaction-ended-at transaction)
                        (chat-repl--timestamp-ms))))
              (setq changed t))
            (puthash (chat-repl-session-id session) session chat-repl--sessions)
            (unless (eq (chat-repl-session-status session) 'closed)
              (puthash (chat-repl-session-chat-session-id session)
                       (chat-repl-session-id session) chat-repl--selected)))))
      (when changed (chat-repl-save))))
  (hash-table-count chat-repl--sessions))

(defun chat-repl-get (id)
  "Return REPL ID, or nil."
  (gethash id chat-repl--sessions))

(defun chat-repl-for-chat-session (chat-session-or-id)
  "Return the selected REPL for CHAT-SESSION-OR-ID, or nil."
  (let* ((chat-id (if (stringp chat-session-or-id)
                      chat-session-or-id
                    (and chat-session-or-id
                         (chat-session-id chat-session-or-id))))
         (id (and chat-id (gethash chat-id chat-repl--selected))))
    (and id (chat-repl-get id))))

(defun chat-repl-list (&optional chat-session-or-id)
  "Return REPL records, optionally scoped to CHAT-SESSION-OR-ID."
  (let ((chat-id (cond ((null chat-session-or-id) nil)
                       ((stringp chat-session-or-id) chat-session-or-id)
                       (t (chat-session-id chat-session-or-id))))
        result)
    (maphash
     (lambda (_id session)
       (when (or (null chat-id)
                 (equal chat-id (chat-repl-session-chat-session-id session)))
         (push session result)))
     chat-repl--sessions)
    (sort result (lambda (left right)
                   (< (or (chat-repl-session-created-at left) 0)
                      (or (chat-repl-session-created-at right) 0))))))

(defun chat-repl--shell-command (_token)
  "Return the persistent shell command."
  (list "/bin/sh" "-s"))

(defun chat-repl--shell-submit (session transaction code)
  "Return framed shell input for SESSION, TRANSACTION and CODE."
  (let ((token (chat-repl-session-token session))
        (tx (chat-repl-transaction-id transaction))
        (payload (base64-encode-string code t)))
    (format
     (concat "printf '\\036%s:B:%s\\037\\n'; "
             "eval \"$(printf %%s '%s' | /usr/bin/base64 -D)\"; "
             "__chat_repl_status=$?; "
             "printf '\\n\\036%s:E:%s:%%s\\037\\n' \"$__chat_repl_status\"\n")
     token tx payload token tx)))

(defun chat-repl--clojure-program (token)
  "Return the official CLI loop program framed by TOKEN."
  (format
   (concat
    "(do (require '[clojure.string :as str]) "
    "(import '[java.util Base64]) "
    "(let [decoder (Base64/getDecoder) reader (java.io.BufferedReader. *in*)] "
    "(doseq [line (line-seq reader)] "
    "(let [[tx payload] (str/split line #\"\\t\" 2)] "
    "(println (str \"\\u001e%s:B:\" tx \"\\u001f\")) "
    "(try (let [value (load-string (String. (.decode decoder payload) \"UTF-8\"))] "
    "(prn value) (println (str \"\\u001e%s:E:\" tx \":0\\u001f\"))) "
    "(catch Throwable error (.printStackTrace error *out*) "
    "(println (str \"\\u001e%s:E:\" tx \":1\\u001f\")))) "
    "(flush)))))")
   token token token))

(defun chat-repl--clojure-tools-jar (program)
  "Return PROGRAM's single bundled Clojure tools jar without resolving deps."
  (with-temp-buffer
    (let ((status (process-file program nil t nil "-Sdescribe")))
      (unless (zerop status)
        (signal 'chat-repl-adapter-unavailable
                (list 'clojure "-Sdescribe failed" status)))
      (goto-char (point-min))
      (unless (re-search-forward
               ":install-dir[[:space:]]+\"\\([^\"]+\\)\"" nil t)
        (signal 'chat-repl-adapter-unavailable
                (list 'clojure "install directory is missing")))
      (let* ((directory (match-string 1))
             (jars (directory-files
                    (expand-file-name "libexec" directory) t
                    "\\`clojure-tools-.*\\.jar\\'")))
        (unless (= (length jars) 1)
          (signal 'chat-repl-adapter-unavailable
                  (list 'clojure "expected one bundled tools jar" jars)))
        (car jars)))))

(defun chat-repl--clojure-command (token)
  "Return an official Clojure CLI command using TOKEN."
  (let ((program (executable-find "clojure")))
    (unless program
      (signal 'chat-repl-adapter-unavailable (list 'clojure)))
    (let ((jar (chat-repl--clojure-tools-jar program)))
      (list program "-Srepro"
            "-Sdeps"
            (format "{:deps {org.clojure/clojure {:local/root %S}}}" jar)
            "-M" "-e" (chat-repl--clojure-program token)))))

(defun chat-repl--clojure-submit (_session transaction code)
  "Return one line of official CLI input for TRANSACTION and CODE."
  (format "%s\t%s\n" (chat-repl-transaction-id transaction)
          (base64-encode-string code t)))

(defun chat-repl-install-default-adapters ()
  "Install canonical shell and official Clojure CLI adapters."
  (chat-repl-register-adapter
   (chat-repl-adapter-create
    :id 'shell :label "Shell"
    :availability-function (lambda () (file-executable-p "/bin/sh"))
    :command-function #'chat-repl--shell-command
    :submit-function #'chat-repl--shell-submit))
  (chat-repl-register-adapter
   (chat-repl-adapter-create
    :id 'clojure :label "Clojure"
    :availability-function (lambda () (and (executable-find "clojure") t))
    :command-function #'chat-repl--clojure-command
    :submit-function #'chat-repl--clojure-submit)))

(defun chat-repl--active-process (session)
  "Return SESSION's live native process, or nil."
  (let ((record (and (chat-repl-session-execution-id session)
                     (chat-execution-get
                      (chat-repl-session-execution-id session)))))
    (and record (chat-execution-live-p record)
         (chat-execution-native-handle record))))

(defun chat-repl--append-output (session transaction chunk)
  "Append bounded CHUNK to TRANSACTION and emit an output event."
  (unless (string-empty-p chunk)
    (pcase-let ((`(,value . ,truncated)
                 (chat-repl--bounded-tail
                  (concat (or (chat-repl-transaction-output transaction) "")
                          chunk)
                  chat-repl-output-limit)))
      (setf (chat-repl-transaction-output transaction) value
            (chat-repl-transaction-output-truncated-p transaction)
            (or truncated
                (chat-repl-transaction-output-truncated-p transaction)))
      (chat-repl--emit
       session 'repl-output transaction
       `((chunk . ,(car (chat-repl--bounded-tail
                         chunk chat-repl-event-chunk-limit)))
         (truncated . ,(and (chat-repl-transaction-output-truncated-p
                             transaction) t)))))))

(defun chat-repl--trim-history (session)
  "Bound SESSION's durable transaction history."
  (let ((transactions (chat-repl-session-transactions session)))
    (when (> (length transactions) chat-repl-history-limit)
      (setf (chat-repl-session-transactions session)
            (last transactions chat-repl-history-limit)))))

(defun chat-repl--finish-transaction (session transaction exit-status)
  "Finish TRANSACTION for SESSION with EXIT-STATUS exactly once."
  (when (eq (chat-repl-transaction-status transaction) 'running)
    (let ((success (zerop exit-status))
          (done (chat-repl-transaction-done-function transaction))
          (fail (chat-repl-transaction-fail-function transaction)))
      (setf (chat-repl-transaction-status transaction)
            (if success 'completed 'failed)
            (chat-repl-transaction-exit-status transaction) exit-status
            (chat-repl-transaction-ended-at transaction) (chat-repl--timestamp-ms)
            (chat-repl-transaction-done-function transaction) nil
            (chat-repl-transaction-fail-function transaction) nil
            (chat-repl-session-active-transaction session) nil
            (chat-repl-session-status session) 'idle
            (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
      (chat-repl--trim-history session)
      (chat-repl-save)
      (chat-repl--emit session
                       (if success 'repl-eval-completed 'repl-eval-failed)
                       transaction `((exit_status . ,exit-status)))
      (if success
          (when done (funcall done (chat-repl-transaction-output transaction)))
        (when fail
          (funcall fail
                   (format "REPL input failed with status %d" exit-status)))))))

(defun chat-repl--parse-output (session chunk)
  "Consume framed process CHUNK for SESSION without prompt heuristics."
  (when-let ((transaction (chat-repl-session-active-transaction session)))
    (let* ((token (chat-repl-session-token session))
           (tx (chat-repl-transaction-id transaction))
           (begin (format "\x1e%s:B:%s\x1f" token tx))
           (end-prefix (format "\x1e%s:E:%s:" token tx))
           (buffer (concat (or (chat-repl-transaction-parser-buffer transaction) "")
                           chunk)))
      (when (eq (chat-repl-transaction-parser-state transaction) 'waiting-begin)
        (if-let ((position (string-match (regexp-quote begin) buffer)))
            (progn
              (unless (zerop position)
                (setf (chat-repl-transaction-diagnostic transaction)
                      (car (chat-repl--bounded-tail
                            (concat (or (chat-repl-transaction-diagnostic
                                         transaction) "")
                                    (substring buffer 0 position))
                            8192))))
              (setq buffer (substring buffer (+ position (length begin))))
              (when (string-prefix-p "\n" buffer)
                (setq buffer (substring buffer 1)))
              (setf (chat-repl-transaction-parser-state transaction) 'capturing))
          (let ((flush (max 0 (- (length buffer) (length begin)))))
            (when (> flush 0)
              (setf (chat-repl-transaction-diagnostic transaction)
                    (car (chat-repl--bounded-tail
                          (concat (or (chat-repl-transaction-diagnostic
                                       transaction) "")
                                  (substring buffer 0 flush))
                          8192)))
              (setq buffer (substring buffer flush))))))
      (if (not (eq (chat-repl-transaction-parser-state transaction) 'capturing))
          (let ((keep (min (length buffer) (length begin))))
            (setf (chat-repl-transaction-parser-buffer transaction)
                  (substring buffer (- (length buffer) keep))))
        (let ((regexp (concat (regexp-quote end-prefix)
                              "\\([0-9]+\\)\x1f")))
          (if-let ((position (string-match regexp buffer)))
              (let ((output (substring buffer 0 position))
                    (exit-status (string-to-number (match-string 1 buffer))))
                (when (string-suffix-p "\n" output)
                  (setq output (substring output 0 -1)))
                (chat-repl--append-output session transaction output)
                (setf (chat-repl-transaction-parser-buffer transaction)
                      (substring buffer (match-end 0)))
                (chat-repl--finish-transaction session transaction exit-status))
            (let* ((keep (+ (length end-prefix) 24))
                   (flush (max 0 (- (length buffer) keep))))
              (when (> flush 0)
                (chat-repl--append-output session transaction
                                          (substring buffer 0 flush))
                (setq buffer (substring buffer flush)))
              (setf (chat-repl-transaction-parser-buffer transaction) buffer))))))))

(defun chat-repl--process-ended (session process event)
  "Reconcile SESSION after PROCESS terminates with EVENT."
  (let ((record (and (chat-repl-session-execution-id session)
                     (chat-execution-get
                      (chat-repl-session-execution-id session)))))
    (unless (or (eq (chat-repl-session-status session) 'closed)
                (chat-repl-session-expected-stop-p session)
                ;; `chat-execution--finish' clears the native handle before
                ;; invoking this user sentinel.  The process retains its
                ;; owning record, which also distinguishes an old generation
                ;; exiting after reset from the current process.
                (not (eq (process-get process 'chat-execution-record) record)))
      (when-let ((transaction (chat-repl-session-active-transaction session)))
        (let* ((fail (chat-repl-transaction-fail-function transaction))
               (diagnostic
                (string-trim
                 (concat (or (chat-repl-transaction-diagnostic transaction) "")
                         (or (chat-repl-transaction-parser-buffer transaction) ""))))
               (reason
                (concat
                 (format "REPL process ended: %s" (string-trim event))
                 (if (string-empty-p diagnostic)
                     ""
                   (format "\n%s"
                           (car (chat-repl--bounded-tail diagnostic 2048)))))))
          (setf (chat-repl-transaction-status transaction) 'interrupted
                (chat-repl-transaction-ended-at transaction)
                (chat-repl--timestamp-ms)
                (chat-repl-transaction-done-function transaction) nil
                (chat-repl-transaction-fail-function transaction) nil)
          (when fail (funcall fail reason))))
      (setf (chat-repl-session-active-transaction session) nil
            (chat-repl-session-status session)
            (if (and (processp process) (zerop (process-exit-status process)))
                'interrupted 'failed)
            (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
      (chat-repl-save)
      (chat-repl--emit session 'repl-process-ended nil
                       `((reason . ,(truncate-string-to-width
                                     (string-trim event) 256 nil nil t)))))))

(defun chat-repl--execution-boundary (session)
  "Return (BACKEND . POLICY) for REPL SESSION under the current approval mode.

Dangerous mode uses unrestricted local execution; every other mode keeps
the build sandbox required by the REPL isolation contract."
  (let* ((chat-id (chat-repl-session-chat-session-id session))
         (chat-session
          (or (and (boundp 'chat-tool-caller-current-session)
                   chat-tool-caller-current-session)
              (and (boundp 'chat--current-session)
                   chat--current-session)
              (and chat-id (ignore-errors (chat-session-get chat-id)))))
         (dangerous
          (and (fboundp 'chat-approval-dangerous-mode-p)
               (chat-approval-dangerous-mode-p chat-session))))
    (if dangerous
        (cons 'local 'local)
      (cons (chat-execution-backend-for-policy 'build) 'build))))

(defun chat-repl--start-process (session)
  "Start SESSION through a capability-proven execution backend."
  (let* ((adapter (chat-repl-adapter (chat-repl-session-adapter-id session)))
         (available
          (funcall (chat-repl-adapter-availability-function adapter))))
    (unless available
      (signal 'chat-repl-adapter-unavailable
              (list (chat-repl-session-adapter-id session))))
    (let* ((token (chat-repl--new-token))
           (command (funcall (chat-repl-adapter-command-function adapter) token))
           (directory (chat-repl-session-directory session))
           (execution-id (chat-execution-new-id))
           (boundary (chat-repl--execution-boundary session))
           (backend (car boundary))
           (policy (cdr boundary))
           (request
            (if (eq policy 'local)
                (chat-execution-request-from-context
                 command
                 :id execution-id
                 :backend backend
                 :directory directory
                 :environment process-environment
                 :session-id (chat-repl-session-chat-session-id session)
                 :idempotency 'non-idempotent
                 :policy 'local
                 :metadata `((kind . "repl")
                             (replId . ,(chat-repl-session-id session))
                             (adapter . ,(symbol-name
                                          (chat-repl-session-adapter-id
                                           session)))))
              (chat-execution-request-from-context
               command
               :id execution-id
               :backend backend
               :directory directory
               :environment process-environment
               :session-id (chat-repl-session-chat-session-id session)
               :idempotency 'non-idempotent
               :policy 'build
               :read-roots (list directory)
               :write-roots (list directory)
               :network nil
               :require-process-tree-cleanup t
               :metadata `((kind . "repl")
                           (replId . ,(chat-repl-session-id session))
                           (adapter . ,(symbol-name
                                        (chat-repl-session-adapter-id
                                         session))))))))
      (setf (chat-repl-session-token session) token
            (chat-repl-session-execution-id session) execution-id
            (chat-repl-session-status session) 'starting
            (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
      (condition-case err
          (progn
            (chat-execution-start
             request
             :name (format "chat-repl-%s" (chat-repl-session-id session))
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :filter (lambda (_process chunk)
                       (chat-repl--parse-output session chunk))
             :sentinel (lambda (process event)
                         (unless (process-live-p process)
                           (chat-repl--process-ended session process event))))
            (setf (chat-repl-session-status session) 'idle
                  (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
            (chat-repl-save)
            (chat-repl--emit session 'repl-started)
            session)
        (error
         (setf (chat-repl-session-status session) 'failed
               (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
         (chat-repl-save)
         (signal (car err) (cdr err)))))))

(cl-defun chat-repl-start (chat-session-or-id adapter-id directory)
  "Start ADAPTER-ID for CHAT-SESSION-OR-ID in canonical DIRECTORY."
  (let* ((chat-id (if (stringp chat-session-or-id)
                      chat-session-or-id
                    (chat-session-id chat-session-or-id)))
         (existing (chat-repl-for-chat-session chat-id))
         (directory (file-name-as-directory
                     (file-truename (expand-file-name directory)))))
    (when (and existing
               (not (eq (chat-repl-session-status existing) 'closed)))
      (signal 'chat-repl-state-error
              (list "chat session already owns a REPL"
                    (chat-repl-session-id existing))))
    (let* ((now (chat-repl--timestamp-ms))
           (session
            (chat-repl-session-create
             :id (chat-repl--new-id "repl")
             :chat-session-id chat-id
             :adapter-id adapter-id
             :directory directory
             :generation 1
             :status 'starting
             :created-at now :updated-at now :transactions nil)))
      ;; Prove adapter and backend availability before selecting durable state.
      (let ((adapter (chat-repl-adapter adapter-id))
            (chat-session
             (or (and (boundp 'chat-tool-caller-current-session)
                      chat-tool-caller-current-session)
                 (and (boundp 'chat--current-session)
                      chat--current-session)
                 (ignore-errors (chat-session-get chat-id)))))
        (unless (funcall (chat-repl-adapter-availability-function adapter))
          (signal 'chat-repl-adapter-unavailable (list adapter-id)))
        (if (and (fboundp 'chat-approval-dangerous-mode-p)
                 (chat-approval-dangerous-mode-p chat-session))
            (chat-execution-get-backend 'local)
          (chat-execution-backend-for-policy 'build)))
      (puthash (chat-repl-session-id session) session chat-repl--sessions)
      (puthash chat-id (chat-repl-session-id session) chat-repl--selected)
      (condition-case err
          (progn
            (chat-repl--start-process session)
            (chat-repl--emit session 'repl-created)
            session)
        (error
         (remhash (chat-repl-session-id session) chat-repl--sessions)
         (remhash chat-id chat-repl--selected)
         (signal (car err) (cdr err)))))))

(defun chat-repl--begin-transaction (session transaction done fail)
  "Start TRANSACTION for SESSION, wiring task callbacks DONE and FAIL."
  (unless (eq (chat-repl-session-status session) 'idle)
    (signal 'chat-repl-state-error
            (list "REPL is not idle" (chat-repl-session-status session))))
  (let ((process (chat-repl--active-process session)))
    (unless process
      (signal 'chat-repl-state-error (list "REPL process is not live")))
    (setf (chat-repl-transaction-status transaction) 'running
          (chat-repl-transaction-started-at transaction) (chat-repl--timestamp-ms)
          (chat-repl-transaction-done-function transaction) done
          (chat-repl-transaction-fail-function transaction) fail
          (chat-repl-transaction-parser-state transaction) 'waiting-begin
          (chat-repl-transaction-parser-buffer transaction) ""
          (chat-repl-transaction-diagnostic transaction) ""
          (chat-repl-session-active-transaction session) transaction
          (chat-repl-session-status session) 'busy
          (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
    (chat-repl-save)
    (chat-repl--emit session 'repl-eval-started transaction)
    (condition-case err
        (let* ((adapter
                (chat-repl-adapter (chat-repl-session-adapter-id session)))
               (wire (funcall (chat-repl-adapter-submit-function adapter)
                              session transaction
                              (or (chat-repl-transaction-wire-code transaction)
                                  (chat-repl-transaction-code transaction)))))
          (process-send-string process wire)
          (setf (chat-repl-transaction-wire-code transaction) nil))
      (error
       (let ((message (error-message-string err)))
         (setf (chat-repl-transaction-status transaction) 'failed
               (chat-repl-transaction-ended-at transaction)
               (chat-repl--timestamp-ms)
               (chat-repl-transaction-done-function transaction) nil
               (chat-repl-transaction-fail-function transaction) nil
               (chat-repl-transaction-wire-code transaction) nil
               (chat-repl-session-active-transaction session) nil
               (chat-repl-session-status session) 'failed
               (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
         (chat-repl-save)
         (chat-repl--emit session 'repl-eval-failed transaction
                          `((reason . ,message)))
         (funcall fail message))))
    :async))

(defun chat-repl-eval (session-or-id code &optional observer)
  "Queue CODE for SESSION-OR-ID and return its durable task.

When OBSERVER is non-nil, call it with STATUS, VALUE and the durable
transaction after task completion."
  (let* ((session (if (chat-repl-session-p session-or-id)
                      session-or-id
                    (or (chat-repl-get session-or-id)
                        (signal 'chat-repl-error
                                (list "unknown REPL" session-or-id)))))
         (bounded (chat-repl--bounded-tail code chat-repl-code-limit))
         (transaction-id (chat-repl--new-id "repl-tx"))
         (task-id (chat-repl--new-id "repl-task"))
         (now (chat-repl--timestamp-ms))
         (transaction
          (chat-repl-transaction-create
           :id transaction-id :task-id task-id
           :code (car bounded) :code-truncated-p (cdr bounded)
           :wire-code code
           :output "" :status 'queued :created-at now))
         (task
          (chat-task-create
           :id task-id :kind 'repl-eval
           :title (format "%s REPL input"
                          (chat-repl-session-adapter-id session))
           :session-id (chat-repl-session-chat-session-id session)
           :source 'repl
           :resources
           (list (list :key (concat "repl:" (chat-repl-session-id session))
                       :mode 'write))
           :payload `((replId . ,(chat-repl-session-id session))
                      (transactionId . ,transaction-id)))))
    (when (memq (chat-repl-session-status session) '(closed failed interrupted))
      (signal 'chat-repl-state-error
              (list "REPL requires reset" (chat-repl-session-status session))))
    (when (>= (seq-count
               (lambda (transaction)
                 (memq (chat-repl-transaction-status transaction)
                       '(queued running)))
               (chat-repl-session-transactions session))
              (max 1 chat-repl-history-limit))
      (signal 'chat-repl-state-error
              (list "REPL input queue is full" chat-repl-history-limit)))
    (setf (chat-repl-session-transactions session)
          (append (chat-repl-session-transactions session) (list transaction))
          (chat-repl-session-updated-at session) now)
    (chat-repl--trim-history session)
    (chat-repl-save)
    (chat-repl--emit session 'repl-eval-queued transaction)
    (chat-task-submit
     task
     (lambda (_task done fail _needs-attention)
       (chat-repl--begin-transaction
        session transaction
        (lambda (result)
          (funcall done result)
          (when observer (funcall observer 'completed result transaction)))
        (lambda (error)
          (funcall fail error)
          (when observer (funcall observer 'failed error transaction)))))
     (lambda (_task reason)
       (chat-repl--cancel-transaction session transaction reason)))
    task))

(defun chat-repl--cancel-transaction (session transaction reason)
  "Cancel TRANSACTION in SESSION without racing its durable task terminal state."
  (when (memq (chat-repl-transaction-status transaction) '(queued running))
    (let ((running (eq (chat-repl-transaction-status transaction) 'running)))
      (setf (chat-repl-transaction-status transaction) 'interrupted
            (chat-repl-transaction-ended-at transaction) (chat-repl--timestamp-ms)
            (chat-repl-transaction-done-function transaction) nil
            (chat-repl-transaction-fail-function transaction) nil
            (chat-repl-transaction-wire-code transaction) nil)
      (when (and running
                 (eq transaction
                     (chat-repl-session-active-transaction session)))
        (when-let ((process (chat-repl--active-process session)))
          (interrupt-process process t))
        (setf (chat-repl-session-active-transaction session) nil
              (chat-repl-session-status session) 'interrupted))
      (setf (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
      (chat-repl-save)
      (chat-repl--emit session 'repl-eval-interrupted transaction
                       `((reason . ,(or reason "interrupted"))))))
  transaction)

(defun chat-repl-interrupt (session-or-id &optional reason)
  "Interrupt active work for SESSION-OR-ID with optional REASON."
  (let* ((session (if (chat-repl-session-p session-or-id)
                      session-or-id
                    (or (chat-repl-get session-or-id)
                        (signal 'chat-repl-error
                                (list "unknown REPL" session-or-id)))))
         (transaction (chat-repl-session-active-transaction session)))
    (unless transaction
      (signal 'chat-repl-state-error (list "REPL has no active input")))
    (let ((task (chat-task-get (chat-repl-transaction-task-id transaction))))
      (if (and task (not (chat-task-terminal-p task)))
          (chat-task-cancel (chat-task-id task)
                            (or reason "REPL input interrupted"))
        (chat-repl--cancel-transaction session transaction reason)))
    session))

(defun chat-repl--cancel-pending-transactions (session reason)
  "Cancel every queued or running transaction in SESSION for REASON."
  ;; Reverse order keeps the active task holding the serialization resource
  ;; until every queued successor has become terminal.
  (dolist (transaction (reverse
                        (copy-sequence
                         (chat-repl-session-transactions session))))
    (when (memq (chat-repl-transaction-status transaction) '(queued running))
      (let ((task (chat-task-get (chat-repl-transaction-task-id transaction))))
        (if (and task (not (chat-task-terminal-p task)))
            (chat-task-cancel (chat-task-id task) reason)
          (chat-repl--cancel-transaction session transaction reason))))))

(defun chat-repl--stop-process (session reason)
  "Stop SESSION's complete execution tree for REASON."
  (setf (chat-repl-session-expected-stop-p session) t)
  (unwind-protect
      (when-let ((record (and (chat-repl-session-execution-id session)
                              (chat-execution-get
                               (chat-repl-session-execution-id session)))))
        (when (chat-execution-live-p record)
          (chat-execution-cancel record reason)))
    (setf (chat-repl-session-expected-stop-p session) nil
          (chat-repl-session-token session) nil
          (chat-repl-session-active-transaction session) nil)))

(defun chat-repl-reset (session-or-id)
  "Replace SESSION-OR-ID's process with a fresh isolated generation."
  (let ((session (if (chat-repl-session-p session-or-id)
                     session-or-id
                   (or (chat-repl-get session-or-id)
                       (signal 'chat-repl-error
                               (list "unknown REPL" session-or-id))))))
    (when (eq (chat-repl-session-status session) 'closed)
      (signal 'chat-repl-state-error (list "closed REPL cannot reset")))
    (chat-repl--cancel-pending-transactions session "REPL reset")
    (setf (chat-repl-session-status session) 'starting)
    (chat-repl--stop-process session "REPL reset")
    (cl-incf (chat-repl-session-generation session))
    (setf (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
    (chat-repl--start-process session)
    (chat-repl--emit session 'repl-reset)
    session))

(defun chat-repl-close (session-or-id)
  "Close SESSION-OR-ID and terminate its complete process tree."
  (let ((session (if (chat-repl-session-p session-or-id)
                     session-or-id
                   (or (chat-repl-get session-or-id)
                       (signal 'chat-repl-error
                               (list "unknown REPL" session-or-id))))))
    (unless (eq (chat-repl-session-status session) 'closed)
      (chat-repl--cancel-pending-transactions session "REPL closed")
      (setf (chat-repl-session-status session) 'closed)
      (chat-repl--stop-process session "REPL closed")
      (setf (chat-repl-session-updated-at session) (chat-repl--timestamp-ms))
      (remhash (chat-repl-session-chat-session-id session) chat-repl--selected)
      (chat-repl-save)
      (chat-repl--emit session 'repl-closed))
    session))

(defun chat-repl-ui-projection (chat-session-or-id)
  "Return a bounded work-shelf projection for CHAT-SESSION-OR-ID."
  (when-let ((session (chat-repl-for-chat-session chat-session-or-id)))
    (unless (eq (chat-repl-session-status session) 'closed)
      (let* ((transactions (chat-repl-session-transactions session))
             (recent (last transactions (min 5 (length transactions))))
             (active (chat-repl-session-active-transaction session)))
        (list :id (chat-repl-session-id session)
              :adapter (chat-repl-session-adapter-id session)
              :directory (chat-repl-session-directory session)
              :generation (chat-repl-session-generation session)
              :status (chat-repl-session-status session)
              :active-transaction (and active
                                       (chat-repl-transaction-id active))
              :transactions recent)))))

(defun chat-repl-initialize ()
  "Install adapters and reconcile durable state without starting processes."
  (chat-repl-install-default-adapters)
  (chat-repl-load))

(provide 'chat-repl)
;;; chat-repl.el ends here
