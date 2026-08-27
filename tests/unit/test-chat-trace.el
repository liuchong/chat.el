;;; test-chat-trace.el --- Tests for derived runtime traces -*- lexical-binding: t; -*-

(require 'ert)
(require 'test-helper)
(require 'chat-trace)

(defmacro chat-trace-test-with-wire (&rest body)
  "Run BODY with an isolated session event directory."
  `(chat-test-with-temp-dir
    (let ((chat-session-wire--sequences (make-hash-table :test 'equal))
          (chat-session-wire--sizes (make-hash-table :test 'equal))
          (chat-session-wire-enabled t))
      ,@body)))

(defun chat-trace-test--record
    (session seq stamp kind &optional turn-id task-id parent-id payload file)
  "Append one deterministic trace fixture record."
  (let ((target (or file (chat-session-wire-file session))))
    (make-directory (file-name-directory target) t)
    (write-region
     (concat
      (json-encode
       (delq nil
             (list (cons 'schema_version 1)
                   (cons 'seq seq)
                   (cons 'timestamp_ms stamp)
                   (cons 'session_id session)
                   (cons 'kind kind)
                   (and turn-id (cons 'turn_id turn-id))
                   (and task-id (cons 'task_id task-id))
                   (and parent-id (cons 'parent_id parent-id))
                   (cons 'payload payload))))
      "\n")
     nil target t 'silent)))

(defun chat-trace-test--complete-fixture ()
  "Write and return a session ID with two correlated tasks."
  (let ((session "trace-session"))
    (chat-trace-test--record session 1 1000 "agent-start")
    (chat-trace-test--record session 2 1100 "turn-start" 1)
    (chat-trace-test--record
     session 3 1150 "model-usage" 1 nil nil
     '((input_tokens . 10) (output_tokens . 4) (total_tokens . 14)
       (cache_read_tokens . 3) (cache_write_tokens . 2)))
    (chat-trace-test--record session 4 1200 "stream-reasoning" 1)
    (chat-trace-test--record session 5 1220 "tool-batch-start" 1 nil nil
                             '((count . 2)))
    (chat-trace-test--record session 6 1230 "permission-requested" 1 "call-1")
    (chat-trace-test--record session 7 1240 "task-started" 1 "parent" nil
                             '((kind . "agent") (status . "running")))
    (chat-trace-test--record session 8 1250 "task-started" 1 "child" "parent"
                             '((kind . "process") (status . "running")))
    (chat-trace-test--record session 9 1300 "task-ended" 1 "child" "parent"
                             '((kind . "process") (status . "completed")))
    (chat-trace-test--record session 10 1320 "subagent-started" 1 "sub-1" nil
                             '((kind . "embedded") (status . "running")))
    (chat-trace-test--record session 11 1340 "checkpoint-created" 1)
    (chat-trace-test--record session 12 1360 "execution-started" 1 "child" "parent")
    (chat-trace-test--record session 13 1400 "compaction")
    (chat-trace-test--record session 14 1500 "turn-ended" 1 nil nil
                             '((status . "completed")))
    (chat-trace-test--record session 15 1600 "agent-end" nil nil nil
                             '((status . "completed")))
    session))

(ert-deftest chat-trace-reconstructs-turn-timing-tokens-and-counts ()
  "Trace derives measurements without a second persistence path."
  (chat-trace-test-with-wire
   (let* ((trace (chat-trace-reconstruct
                  (chat-trace-test--complete-fixture)))
          (turn (car (chat-trace-turns trace))))
     (should (eq 'completed (chat-trace-status trace)))
     (should (= 600 (chat-trace-duration-ms trace)))
     (should (= 100 (chat-trace-turn-first-output-ms turn)))
     (should (= 400 (chat-trace-turn-duration-ms turn)))
     (should (= 10 (alist-get 'input_tokens (chat-trace-tokens trace))))
     (should (= 3 (alist-get 'cache_read_tokens (chat-trace-tokens trace))))
     (should (= 2 (alist-get 'tools (chat-trace-counts trace))))
     (should (= 1 (alist-get 'approvals (chat-trace-counts trace))))
     (should (= 1 (alist-get 'subagents (chat-trace-counts trace))))
     (should (= 1 (alist-get 'compactions (chat-trace-counts trace))))
     (should (= 1 (alist-get 'checkpoints (chat-trace-counts trace))))
     (should (= 1 (alist-get 'executions (chat-trace-counts trace)))))))

(ert-deftest chat-trace-retains-recorded-task-parentage ()
  "Nested work remains linked by stable task and parent IDs."
  (chat-trace-test-with-wire
   (let* ((trace (chat-trace-reconstruct
                  (chat-trace-test--complete-fixture)))
          (parent (seq-find
                   (lambda (task)
                     (equal "parent" (chat-trace-task-id task)))
                   (chat-trace-tasks trace)))
          (child (seq-find
                  (lambda (task)
                    (equal "child" (chat-trace-task-id task)))
                  (chat-trace-tasks trace))))
     (should parent)
     (should child)
     (should (equal "parent" (chat-trace-task-parent-id child)))
     (should (equal '("child") (chat-trace-task-children parent)))
     (should (eq 'completed (chat-trace-task-status child))))))

(ert-deftest chat-trace-reconstructs-through-archived-wire-files ()
  "Trace consumes archived and current records as one ordered stream."
  (chat-trace-test-with-wire
   (let ((archive (chat-session-wire--archive-file "s1" 1)))
     (chat-trace-test--record "s1" 1 100 "turn-start" 1 nil nil nil archive)
     (chat-trace-test--record "s1" 2 150 "stream-chunk" 1 nil nil nil archive)
     (chat-trace-test--record "s1" 3 200 "turn-ended" 1 nil nil
                              '((status . "completed")))
     (let ((trace (chat-trace-reconstruct "s1")))
       (should (= 3 (chat-trace-record-count trace)))
       (should (= 50 (chat-trace-first-output-ms trace)))
       (should (= 100 (chat-trace-duration-ms trace)))))))

(ert-deftest chat-trace-reports-gaps-duplicates-unknowns-and-missing-parents ()
  "Damaged or newer histories stay readable and explicitly diagnostic."
  (chat-trace-test-with-wire
   (chat-trace-test--record "s1" 1 100 "turn-start" 1)
   (chat-trace-test--record "s1" 2 110 "task-started" 1 "child" "absent"
                            '((kind . "agent") (status . "running")))
   (chat-trace-test--record "s1" 2 120 "task-ended" 1 "child" "absent"
                            '((kind . "agent") (status . "completed")))
   (chat-trace-test--record "s1" 4 130 "future-event" 1)
   (let ((diagnostics (chat-trace-diagnostics
                       (chat-trace-reconstruct "s1"))))
     (should (= 1 (alist-get 'duplicate_sequences diagnostics)))
     (should (= 1 (alist-get 'missing_sequences diagnostics)))
     (should (= 1 (alist-get 'unknown_kinds diagnostics)))
     (should (= 1 (alist-get 'missing_parents diagnostics))))))

(ert-deftest chat-trace-export-never-copies-message-content ()
  "Bounded exports contain metrics rather than transcript bodies."
  (chat-trace-test-with-wire
   (chat-trace-test--record
    "s1" 1 100 "message-appended" nil nil nil
    '((message_id . "m1") (content . "DO-NOT-EXPORT")))
   (let ((json (chat-trace-export-json (chat-trace-reconstruct "s1"))))
     (should-not (string-match-p "DO-NOT-EXPORT" json))
     (should (string-match-p "recordCount" json)))))

(ert-deftest chat-trace-comparison-reports-token-and-duration-deltas ()
  "Two reconstructed runs can be compared by stable counters."
  (chat-trace-test-with-wire
   (chat-trace-test--record "left" 1 100 "turn-start" 1)
   (chat-trace-test--record "left" 2 200 "model-usage" 1 nil nil
                            '((total_tokens . 10)))
   (chat-trace-test--record "left" 3 300 "turn-ended" 1 nil nil
                            '((status . "completed")))
   (chat-trace-test--record "right" 1 100 "turn-start" 1)
   (chat-trace-test--record "right" 2 250 "model-usage" 1 nil nil
                            '((total_tokens . 16)))
   (chat-trace-test--record "right" 3 400 "turn-ended" 1 nil nil
                            '((status . "completed")))
   (let ((comparison
          (chat-trace-compare (chat-trace-reconstruct "left")
                              (chat-trace-reconstruct "right"))))
     (should (= 100 (alist-get 'durationDeltaMs comparison)))
     (should (= 6 (alist-get 'total_tokens
                             (alist-get 'tokens comparison)))))))

(provide 'test-chat-trace)
;;; test-chat-trace.el ends here
