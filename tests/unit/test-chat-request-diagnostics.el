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

(provide 'test-chat-request-diagnostics)
