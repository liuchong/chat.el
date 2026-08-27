;;; test-session-wire.el --- The session event stream -*- lexical-binding: t; -*-

;;; Commentary:

;; What the stream must hold, and what it must refuse to hold.
;;
;; The refusals matter more than the contents here.  The file this replaces
;; grew to 119MB because one clause printed a structure that reaches the
;; whole session, so the tests that earn their place are the ones that fail
;; if that becomes possible again: a cap on one record, a cap on the file, a
;; projection for every event type with no fallback to catch the ones nobody
;; thought about.

;;; Code:

(require 'ert)
(require 'chat-session-wire)
(require 'chat-agent-wire)

(defmacro chat-test-with-wire (&rest body)
  "Run BODY with a session directory and stream counters of its own."
  `(chat-test-with-temp-dir
    (let ((chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (chat-session-wire-enabled t))
      ,@body)))

;; ------------------------------------------------------------------
;; The envelope
;; ------------------------------------------------------------------

(ert-deftest chat-wire-a-record-carries-its-session-and-kind ()
  "Every record says which session and which kind it belongs to.
The file it replaces said neither, which is why no question could be
asked of it."
  (chat-test-with-wire
   (chat-session-wire-record "s1" 'turn-start '((step . 2)))
   (let ((record (car (chat-session-wire-read "s1"))))
     (should (equal "s1" (alist-get 'session_id record)))
     (should (equal "turn-start" (alist-get 'kind record)))
     (should (equal chat-session-wire-schema-version
                    (alist-get 'schema_version record)))
     (should (integerp (alist-get 'timestamp_ms record))))))

(ert-deftest chat-wire-sequence-numbers-do-not-repeat-or-skip ()
  "Records are numbered in order, one apiece."
  (chat-test-with-wire
   (dotimes (i 5) (chat-session-wire-record "s1" 'turn-start nil))
   (should (equal '(1 2 3 4 5)
                  (mapcar (lambda (r) (alist-get 'seq r))
                          (chat-session-wire-read "s1"))))))

(ert-deftest chat-wire-a-reopened-stream-keeps-counting ()
  "Numbering continues from the file, not from one.
Restarting Emacs mid-session must not produce two records that claim the
same position."
  (chat-test-with-wire
   (dotimes (i 3) (chat-session-wire-record "s1" 'turn-start nil))
   (chat-session-wire-forget "s1")
   (chat-session-wire-record "s1" 'turn-start nil)
   (should (equal '(1 2 3 4)
                  (mapcar (lambda (r) (alist-get 'seq r))
                          (chat-session-wire-read "s1"))))))

(ert-deftest chat-wire-grouping-lives-in-the-envelope ()
  "A turn and a step are readable without knowing the kind's shape."
  (chat-test-with-wire
   (chat-session-wire-record "s1" 'stream-chunk '((chars . 10))
                             '((turn_id . 4) (step . 2)))
   (let ((record (car (chat-session-wire-read "s1"))))
     (should (equal 4 (alist-get 'turn_id record)))
     (should (equal 2 (alist-get 'step record))))))

(ert-deftest chat-wire-a-torn-last-line-does-not-lose-the-rest ()
  "A crash mid-append costs the last line, not the history.
An append-only file can end anywhere, and refusing to read one that does
would mean losing a session to a power cut."
  (chat-test-with-wire
   (chat-session-wire-record "s1" 'turn-start nil)
   (chat-session-wire-record "s1" 'agent-end '((status . "completed")))
   (let ((file (chat-session-wire-file "s1")))
     (write-region "{\"seq\":3,\"kind\":\"tru" nil file t 'silent))
   (should (equal 2 (length (chat-session-wire-read "s1"))))))

;; ------------------------------------------------------------------
;; The caps
;; ------------------------------------------------------------------

(ert-deftest chat-wire-an-oversized-payload-becomes-a-note ()
  "A record too large to keep is replaced, not dropped.
Dropping it would leave a gap in the sequence, which reads as a lost
event rather than an oversized one."
  (chat-test-with-wire
   (let ((chat-session-wire-max-record-bytes 512))
     (chat-session-wire-record "s1" 'response
                               (list (cons 'oops (make-string 4096 ?x)))))
   (let* ((record (car (chat-session-wire-read "s1")))
          (payload (alist-get 'payload record)))
     (should (equal 1 (alist-get 'seq record)))
     (should (eq t (alist-get 'truncated payload)))
     (should (> (alist-get 'original_bytes payload) 4096))
     (should (< (length (json-encode record)) 1024)))))

(ert-deftest chat-wire-a-full-stream-is-archived-not-grown ()
  "The stream starts over once it reaches its cap, keeping the old part."
  (chat-test-with-wire
   (let ((chat-session-wire-max-bytes 400))
     (dotimes (i 20)
       (chat-session-wire-record "s1" 'turn-start (list (cons 'i i)))))
   (should (file-exists-p (chat-session-wire--archive-file "s1" 1)))
   (let ((kinds (mapcar (lambda (r) (alist-get 'kind r))
                        (chat-session-wire-read "s1"))))
     (should (member "wire-archived" kinds)))))

(ert-deftest chat-wire-recording-off-writes-nothing ()
  "Turning it off leaves no file, not an empty one."
  (chat-test-with-wire
   (let ((chat-session-wire-enabled nil))
     (chat-session-wire-record "s1" 'turn-start nil))
   (should-not (file-exists-p (chat-session-wire-file "s1")))))

(ert-deftest chat-wire-lives-clear-of-the-session-files ()
  "The stream is not where `chat-session-list' looks for sessions.
Globbing `*.jsonl' in the session directory and taking the base name
would offer every stream to `chat-session-load' as a session."
  (chat-test-with-wire
   (chat-session-wire-record "s1" 'turn-start nil)
   (should-not (equal (file-name-directory (chat-session-wire-file "s1"))
                      (file-name-as-directory
                       (expand-file-name chat-session-directory))))))

;; ------------------------------------------------------------------
;; The projection
;; ------------------------------------------------------------------

(defun chat-test-wire--emitted-types ()
  "Return every event type `chat-agent--emit' is called with."
  (let ((types nil))
    (dolist (file (list "lisp/agent/chat-agent-loop.el"
                        "lisp/agent/chat-agent.el"))
      (let ((path (expand-file-name file chat-test-root-dir)))
        (when (file-exists-p path)
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (while (re-search-forward
                    "chat-agent--emit[ \t\n]+[a-z-]+[ \t\n]+'\\([a-z-]+\\)"
                    nil t)
              (cl-pushnew (intern (match-string 1)) types))))))
    types))

(ert-deftest chat-wire-every-emitted-event-has-a-projection ()
  "No event type reaches the stream without one.
There is no fallback clause on purpose: a new event type should fail here
rather than be recorded as whatever shape it happened to have, which is
how a structure holding the whole session came to be written to a file.

Every type is also projected with nothing filled in, which is how an
observer that raises on a shape it did not expect is caught here rather
than in the middle of somebody's run."
  (let ((missing nil)
        (raised nil))
    (dolist (type (chat-test-wire--emitted-types))
      (condition-case err
          (when (eq 'unprojected
                    (chat-agent-wire-payload (list :type type :run nil)))
            (push type missing))
        (error (push (cons type (error-message-string err)) raised))))
    (should-not missing)
    (should-not raised)))

(ert-deftest chat-wire-a-projection-never-carries-the-run ()
  "The run is not in the payload, at any depth.
It holds the session, so one event printed whole was 1.4MB, and 77 of
them were 90% of a 119MB file."
  (let* ((message (make-chat-message :id "m1" :role :assistant
                                     :content (make-string 5000 ?x)))
         (event (list :type 'message-appended :message message
                      :run 'pretend-run))
         (payload (chat-agent-wire-payload event)))
    (should (equal "m1" (alist-get 'message_id payload)))
    (should (equal 5000 (alist-get 'chars payload)))
    (should-not (cl-find-if (lambda (pair)
                              (and (stringp (cdr pair))
                                   (> (length (cdr pair)) 500)))
                            payload))))

(ert-deftest chat-wire-steering-records-which-inputs-went-in ()
  "Steering says how many inputs it took and which ones.
The question a steered run raises is where four messages went when one
answer came back."
  (let* ((messages (list (make-chat-message :id "m1" :role :user
                                            :content "first")
                         (make-chat-message :id "m2" :role :user
                                            :content "second")))
         (payload (chat-agent-wire-payload
                   (list :type 'steering :messages messages :run nil))))
    (should (equal 2 (alist-get 'count payload)))
    (should (equal '("m1" "m2") (alist-get 'message_ids payload)))))

(ert-deftest chat-wire-a-tool-result-is-measured-not-copied ()
  "A tool event records the size of its result, not the result."
  (let* ((summary (make-string 40000 ?y))
         (payload (chat-agent-wire-payload
                   (list :type 'tool-event
                         :event (list :type 'tool-end :tool "read_file"
                                      :result-summary summary)
                         :run nil))))
    (should (equal 40000 (alist-get 'summary_chars payload)))
    (should (equal chat-agent-wire-text-limit
                   (length (alist-get 'summary payload))))))

;; ------------------------------------------------------------------
;; A whole run
;; ------------------------------------------------------------------

(ert-deftest chat-wire-a-run-leaves-a-readable-account-of-itself ()
  "A run that used a tool can be told from one that did not, afterwards.
Which is the whole point: the question asked of a finished session is
\"why did that take three rounds\", and until now nothing on disk could
answer it."
  (chat-test-with-wire
   (let* ((session (chat-session-create "wire run"))
          (chat-agent-event-functions (list #'chat-agent-wire-observe))
          (chat-tool-forge--registry (make-hash-table :test 'eq))
          (exec-counter (list 0))
          (calls (list nil)))
     (chat-agent-test--register-demo-tool exec-counter)
     (cl-letf (((symbol-function 'chat-llm-request-async)
                (chat-agent-test--stub-transport
                 (list (list :content chat-agent-test--tool-call-json)
                       '(:content "done"))
                 calls)))
       (chat-agent-start
        (list :model 'kimi
              :session session
              :messages (list (chat-agent-test--user-message)))))
     (let ((kinds (mapcar (lambda (r) (alist-get 'kind r))
                          (chat-session-wire-read
                           (chat-session-id session)))))
       (should (member "agent-start" kinds))
       (should (member "turn-start" kinds))
       (should (member "turn-ended" kinds))
       (should (member "tool-event" kinds))
       (should (member "agent-end" kinds))
       ;; Two turns, because the tool result had to go back.
       (should (= 2 (cl-count "turn-start" kinds :test #'equal)))
       (should (= 2 (cl-count "turn-ended" kinds :test #'equal)))
       (should-not (member "turn-failed" kinds)))
     (dolist (record (chat-session-wire-read (chat-session-id session)))
       (when (member (alist-get 'kind record) '("turn-start" "turn-ended"))
         (should (equal chat-event-schema-version
                        (alist-get 'event_schema_version record)))
         (should (equal "agent" (alist-get 'source record)))))
     ;; And nothing in it is anywhere near the size of a conversation.
     (let ((size (file-attribute-size
                  (file-attributes (chat-session-wire-file
                                    (chat-session-id session))))))
       (should (< size 8192))))))

(ert-deftest chat-wire-records-say-which-turn-they-belong-to ()
  "Events carry the turn, so a run's rounds can be told apart."
  (chat-test-with-wire
   (let* ((session (chat-session-create "turns"))
          (chat-agent-event-functions (list #'chat-agent-wire-observe))
          (calls (list nil)))
     (cl-letf (((symbol-function 'chat-llm-request-async)
                (chat-agent-test--stub-transport
                 '((:content "answer")) calls)))
       (chat-agent-start
        (list :model 'kimi
              :session session
              :messages (list (chat-agent-test--user-message)))))
     (let ((turns (delq nil
                        (mapcar (lambda (r) (alist-get 'turn_id r))
                                (chat-session-wire-read
                                 (chat-session-id session))))))
       (should turns)
       (should (cl-every #'integerp turns))))))

(ert-deftest chat-wire-a-failed-turn-closes-once-with-its-reason ()
  "A transport failure leaves one terminal turn record before agent end."
  (chat-test-with-wire
   (let* ((session (chat-session-create "failed turn"))
          (chat-agent-event-functions (list #'chat-agent-wire-observe)))
     (cl-letf (((symbol-function 'chat-llm-request-async)
                (lambda (_model _messages _success error _options)
                  (funcall error "transport unavailable")
                  'stub-handle)))
       (chat-agent-start
        (list :model 'kimi
              :session session
              :messages (list (chat-agent-test--user-message)))))
     (let* ((records (chat-session-wire-read (chat-session-id session)))
            (failed (seq-filter
                     (lambda (record)
                       (equal (alist-get 'kind record) "turn-failed"))
                     records)))
       (should (= 1 (length failed)))
       (should (equal "transport unavailable"
                      (alist-get 'reason (alist-get 'payload (car failed)))))
       (should (< (alist-get 'seq (car failed))
                  (alist-get 'seq (car (last records)))))))))

(ert-deftest chat-wire-a-cancelled-turn-closes-once ()
  "Cancelling an active request writes one terminal turn before agent end."
  (chat-test-with-wire
   (let* ((session (chat-session-create "cancelled turn"))
          (chat-agent-event-functions (list #'chat-agent-wire-observe))
          run)
     (cl-letf (((symbol-function 'chat-llm-request-async)
                (lambda (&rest _args) 'stub-handle)))
       (setq run
             (chat-agent-start
              (list :model 'kimi
                    :session session
                    :messages (list (chat-agent-test--user-message))))))
     (should (chat-agent-cancel run))
     (let* ((records (chat-session-wire-read (chat-session-id session)))
            (ended (seq-filter
                    (lambda (record)
                      (equal (alist-get 'kind record) "turn-ended"))
                    records)))
       (should (= 1 (length ended)))
       (should (equal "cancelled"
                      (alist-get 'status (alist-get 'payload (car ended)))))
       (should (equal "agent-end" (alist-get 'kind (car (last records)))))))))

(provide 'test-session-wire)
;;; test-session-wire.el ends here
