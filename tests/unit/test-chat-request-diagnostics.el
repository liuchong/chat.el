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

(provide 'test-chat-request-diagnostics)
