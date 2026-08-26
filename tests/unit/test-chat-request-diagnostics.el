;;; test-chat-request-diagnostics.el --- Tests for request diagnostics -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-request-diagnostics)

(ert-deftest chat-request-diagnostics-records-events-and-snapshots ()
  "Test diagnostics traces record lifecycle data."
  (let* ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
         (id (chat-request-diagnostics-create 'chat 'kimi-code 'kimi-code)))
    (chat-request-diagnostics-record
     id
     'request-dispatched
     :transport 'async
     :timeout 30
     :summary "Dispatch")
    (chat-request-diagnostics-record id 'stream-chunk :summary "Chunk")
    (let ((snapshot (chat-request-diagnostics-snapshot id)))
      (should (equal (plist-get snapshot :phase) 'streaming))
      (should (equal (plist-get snapshot :transport) 'async))
      (should (= (plist-get snapshot :timeout) 30))
      (should (= (plist-get snapshot :stream-chunk-count) 1)))))

(ert-deftest chat-request-diagnostics-stall-message-reflects-phase ()
  "Test stall messages distinguish waiting and streaming states."
  (let* ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
         (chat-request-diagnostics-stall-threshold 0)
         (id (chat-request-diagnostics-create 'chat 'kimi-code 'kimi-code)))
    (chat-request-diagnostics-record id 'request-dispatched :summary "Waiting")
    (sleep-for 0.01)
    (should (string-match-p
             "Still waiting"
             (chat-request-diagnostics-stall-message id)))
    (chat-request-diagnostics-record id 'stream-started :summary "Stream")
    (sleep-for 0.01)
    (should (string-match-p
             "no chunks"
             (chat-request-diagnostics-stall-message id)))))

(ert-deftest chat-request-diagnostics-notifies-subscribed-observers ()
  "Test request diagnostics observers receive recorded events."
  (let* ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
         (chat-request-diagnostics--observers (make-hash-table :test 'equal))
         (id (chat-request-diagnostics-create 'chat 'kimi-code 'kimi-code))
         captured)
    (chat-request-diagnostics-subscribe
     id
     (lambda (request-id _trace event)
       (setq captured (list request-id (plist-get event :type)))))
    (chat-request-diagnostics-record id 'stream-chunk :summary "Chunk")
    (should (equal captured (list id 'stream-chunk)))))

(ert-deftest chat-request-diagnostics-live-detail-prefers-approval-context ()
  "Test live detail surfaces pending approvals before generic phases."
  (should (string=
           (chat-request-diagnostics-live-detail
            '(:phase tool-loop)
            '((:type approval-pending :tool "files_write")))
           "Approval pending for files_write")))

(ert-deftest chat-request-diagnostics-live-detail-summarizes-streaming ()
  "Test live detail summarizes streaming chunk progress."
  (let ((detail (chat-request-diagnostics-live-detail
                 (list :phase 'streaming
                       :stream-chunk-count 4
                       :last-chunk-at (current-time)))))
    (should (string-match-p "Receiving response (4 chunks" detail))))

(ert-deftest chat-request-diagnostics-caps-retained-events ()
  "Test old events are dropped once the per trace limit is exceeded."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        (chat-request-diagnostics-max-events 5))
    (let ((id (chat-request-diagnostics-create 'chat 'kimi 'kimi nil)))
      (dotimes (index 10)
        (chat-request-diagnostics-record id 'custom :n index))
      (let ((events (plist-get (chat-request-diagnostics-snapshot id) :events)))
        (should (= (length events) 5))
        ;; Snapshot order stays chronological, newest retained.
        (should (= (plist-get (car events) :n) 5))
        (should (= (plist-get (car (last events)) :n) 9))))))

;; ------------------------------------------------------------------
;; Reasoning is arriving data
;; ------------------------------------------------------------------

(ert-deftest chat-request-diagnostics-counts-reasoning-chunks ()
  "Reasoning was recorded nowhere, so thinking read as having produced nothing."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal)))
    (let ((id (chat-request-diagnostics-create 'chat 'kimi 'kimi nil)))
      (chat-request-diagnostics-record id 'stream-reasoning :chars 10)
      (chat-request-diagnostics-record id 'stream-reasoning :chars 15)
      (let ((snapshot (chat-request-diagnostics-snapshot id)))
        (should (= (plist-get snapshot :reasoning-count) 2))
        ;; The delta accumulates; assigning it would report 15 as the total.
        (should (= (plist-get snapshot :reasoning-chars) 25))))))

(ert-deftest chat-request-diagnostics-reasoning-keeps-a-request-alive ()
  "A reasoning chunk counts as progress, so the stall clock restarts."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal)))
    (let ((id (chat-request-diagnostics-create 'chat 'kimi 'kimi nil)))
      (chat-request-diagnostics-record id 'stream-reasoning :chars 10)
      (should (plist-get (chat-request-diagnostics-snapshot id) :last-chunk-at)))))

(ert-deftest chat-request-diagnostics-says-thinking-while-reasoning-arrives ()
  "Naming the work is what stops a reader assuming a hang."
  (let ((detail (chat-request-diagnostics-live-detail
                 (list :phase 'streaming
                       :stream-chunk-count 0
                       :reasoning-count 3
                       :reasoning-chars 420
                       :started-at (current-time)))))
    (should (string-match-p "Thinking (420 chars" detail))))

(ert-deftest chat-request-diagnostics-counts-the-wait-for-a-first-token ()
  "A number that moves is the difference between waiting and giving up.

A large prompt can be twenty seconds from its first token, and the message
before this said only that the stream had started."
  (let ((detail (chat-request-diagnostics-live-detail
                 (list :phase 'streaming
                       :stream-chunk-count 0
                       :reasoning-count 0
                       :started-at (time-subtract (current-time) 7)))))
    (should (string-match-p "Waiting for the first token (7s)" detail))))

(ert-deftest chat-request-diagnostics-stall-tells-reasoning-from-nothing ()
  "Saying no chunks arrived while reasoning arrived is simply untrue."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        (chat-request-diagnostics-stall-threshold 0))
    (let ((id (chat-request-diagnostics-create 'chat 'kimi 'kimi nil)))
      (chat-request-diagnostics-record id 'stream-started)
      (should (string-match-p
               "no chunks have arrived"
               (chat-request-diagnostics-stall-message id)))
      (chat-request-diagnostics-record id 'stream-reasoning :chars 10)
      (should (string-match-p
               "Reasoning has stalled"
               (chat-request-diagnostics-stall-message id))))))

;; ------------------------------------------------------------------
;; A running tool is not a stalled stream
;; ------------------------------------------------------------------

(ert-deftest chat-request-diagnostics-a-running-tool-is-not-a-stall ()
  "Silence with a known cause is not reported as a failure.

This was the worst message in the interface.  A subagent worked for two
and a half minutes; the main request, waiting on it, was reported as
\"Stream has stalled without a new chunk\".  The stream had finished
normally -- what was in progress was something the stream had asked for --
so the notice named the wrong component and implied a failure that had
not happened, and was read as one."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        (chat-request-diagnostics-stall-threshold 0))
    (let ((id (chat-request-diagnostics-create 'chat 'kimi 'kimi nil)))
      (chat-request-diagnostics-record id 'stream-chunk)
      ;; Before the tool starts, silence has no known cause and is a stall.
      (should (chat-request-diagnostics-stall-message id))
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-call :tool "work_task_start"))
      (should-not (chat-request-diagnostics-stall-message id))
      ;; And once the tool is done, silence is unexplained again.
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-result :tool "work_task_start"))
      (should (chat-request-diagnostics-stall-message id)))))

(ert-deftest chat-request-diagnostics-tools-in-flight-are-counted ()
  "Counted, not flagged, because one step can call several tools.

A flag cleared by the first result would report the tools still running
as silence, which is the bug this replaces in a smaller form."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        (chat-request-diagnostics-stall-threshold 0))
    (let ((id (chat-request-diagnostics-create 'chat 'kimi 'kimi nil)))
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-call :tool "files_read"))
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-call :tool "files_grep"))
      (should (= 2 (plist-get (chat-request-diagnostics-snapshot id)
                              :tools-in-flight)))
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-result :tool "files_read"))
      (should-not (chat-request-diagnostics-stall-message id))
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-result :tool "files_grep"))
      (should (zerop (plist-get (chat-request-diagnostics-snapshot id)
                                :tools-in-flight)))
      (should (chat-request-diagnostics-stall-message id)))))

(ert-deftest chat-request-diagnostics-a-failed-tool-also-ends-its-silence ()
  "A tool that errors has stopped running, whatever its result was."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal))
        (chat-request-diagnostics-stall-threshold 0))
    (let ((id (chat-request-diagnostics-create 'chat 'kimi 'kimi nil)))
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-call :tool "shell_execute"))
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-error :tool "shell_execute"))
      (should (zerop (plist-get (chat-request-diagnostics-snapshot id)
                                :tools-in-flight)))
      (should (chat-request-diagnostics-stall-message id)))))

(ert-deftest chat-request-diagnostics-a-running-tool-is-reported-with-seconds ()
  "Not flagging a stall is not enough; the wait has to be explained.

The reader's question during a long tool call is whether anything is
still happening, and only a number that moves answers it."
  (let ((detail (chat-request-diagnostics-live-detail
                 (list :phase 'tool-loop
                       :running-tool "work_task_start"
                       :tool-started-at (time-subtract (current-time) 42)))))
    (should (string-match-p "Running work_task_start (42s)" detail))))

(ert-deftest chat-request-diagnostics-a-tool-call-puts-the-request-in-its-loop ()
  "The phase follows what the request is doing.

It stayed on `streaming' through the whole tool call, which is what let
the stall notice describe a finished stream as a stalled one."
  (let ((chat-request-diagnostics--traces (make-hash-table :test 'equal)))
    (let ((id (chat-request-diagnostics-create 'chat 'kimi 'kimi nil)))
      (chat-request-diagnostics-record id 'stream-chunk)
      (should (eq 'streaming
                  (plist-get (chat-request-diagnostics-snapshot id) :phase)))
      (chat-request-diagnostics-record-tool-event
       id '(:type tool-call :tool "files_read"))
      (should (eq 'tool-loop
                  (plist-get (chat-request-diagnostics-snapshot id) :phase)))
      (should (equal "files_read"
                     (plist-get (chat-request-diagnostics-snapshot id)
                                :running-tool))))))

(provide 'test-chat-request-diagnostics)
