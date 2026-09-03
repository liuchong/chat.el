;;; test-chat-stream-net.el --- Tests for the in-process transport -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for chat-stream-net, the in-process HTTP/1.1 streaming
;; transport.  The server side is an Emacs in-process TCP server, so no
;; test here touches the network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'test-helper)
(require 'chat-stream-net)

;; ------------------------------------------------------------------
;; Test server
;; ------------------------------------------------------------------

(defun test-chat-stream-net--server (responder)
  "Start a TCP server on 127.0.0.1:0 and return (SERVER . PORT).

RESPONDER is called with the client process once a full request has
arrived (headers plus Content-Length body bytes)."
  (let ((requests (make-hash-table)))
    (letrec
        ((server
          (make-network-process
           :name "test-chat-stream-net-server"
           :server t :host "127.0.0.1" :service 0 :family 'ipv4
           :noquery t
           :filter
           (lambda (proc chunk)
             (puthash proc (concat (gethash proc requests) chunk) requests)
             (let ((text (gethash proc requests)))
               (when (and (string-match "\r\n\r\n" text)
                          (let* ((headers (substring text 0 (match-beginning 0)))
                                 (length (if (string-match
                                              "[Cc]ontent-[Ll]ength: \\([0-9]+\\)"
                                              headers)
                                             (string-to-number
                                              (match-string 1 headers))
                                           0)))
                            (>= (length text)
                                (+ (match-end 0) length))))
                 (funcall responder proc)))))))
      (cons server (cadr (process-contact server))))))

(defun test-chat-stream-net--await (predicate)
  "Wait until PREDICATE is non-nil, failing after five seconds."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05 nil t)
      (sleep-for 0.05))
    (funcall predicate)))

(defmacro test-chat-stream-net--with-server (responder &rest body)
  "Run BODY with a scripted server; `port' is bound to its port."
  (declare (indent 1))
  `(let ((server+port (test-chat-stream-net--server ,responder)))
     (unwind-protect
         (let ((port (cdr server+port)))
           (chat-stream-net-endpoint-health-clear)
           ,@body)
       (delete-process (car server+port))
       (chat-stream-net-endpoint-health-clear))))

;; ------------------------------------------------------------------
;; Transport scenarios
;; ------------------------------------------------------------------

(ert-deftest chat-stream-net-complete-chunked-stream-is-ok ()
  "A chunked body closed by its terminal chunk settles as ok."
  (test-chat-stream-net--with-server
   (lambda (proc)
     (process-send-string
      proc
      (concat "HTTP/1.1 200 OK\r\n"
              "Content-Type: text/event-stream\r\n"
              "Transfer-Encoding: chunked\r\n\r\n"))
     (dolist (sse '("data: {\"a\":1}\n" "data: {\"b\":2}\n"))
       (process-send-string
        proc (format "%x\r\n%s\r\n" (string-bytes sse) sse)))
     (process-send-string proc "0\r\n\r\n")
     ;; Close after a beat so the client reads first.
     (run-at-time 0.2 nil #'delete-process proc))
   (let (chunks terminal)
     (chat-stream-net-post
      (format "http://127.0.0.1:%d/v1/chat/completions" port)
      '(("Content-Type" . "application/json"))
      "{}"
      (lambda (_proc chunk) (push chunk chunks))
      (lambda (_proc term) (setq terminal term)))
     (should (test-chat-stream-net--await (lambda () terminal)))
     (should (eq (plist-get terminal :status) 'ok))
     (should (equal (nreverse chunks)
                    '("data: {\"a\":1}\n" "data: {\"b\":2}\n"))))))

(ert-deftest chat-stream-net-mid-stream-close-is-classified ()
  "EOF before the terminal chunk, with data received, is mid-stream-close."
  (test-chat-stream-net--with-server
   (lambda (proc)
     (process-send-string
      proc
      (concat "HTTP/1.1 200 OK\r\n"
              "Content-Type: text/event-stream\r\n"
              "Transfer-Encoding: chunked\r\n\r\n"))
     (let ((sse "data: {\"a\":1}\n"))
       (process-send-string
        proc (format "%x\r\n%s\r\n" (string-bytes sse) sse)))
     ;; Cut the connection without the terminal chunk.
     (run-at-time 0.2 nil #'delete-process proc))
   (let (chunks terminal)
     (chat-stream-net-post
      (format "http://127.0.0.1:%d/v1/chat/completions" port)
      nil "{}"
      (lambda (_proc chunk) (push chunk chunks))
      (lambda (_proc term) (setq terminal term)))
     (should (test-chat-stream-net--await (lambda () terminal)))
     (should (eq (plist-get terminal :status) 'error))
     (should (eq (plist-get terminal :class) 'mid-stream-close))
     (should (string-match-p "closed mid-stream"
                             (plist-get terminal :message)))
     ;; What arrived before the cut was delivered, not lost.
     (should (equal (nreverse chunks) '("data: {\"a\":1}\n"))))))

(ert-deftest chat-stream-net-http-error-body-carries-its-message ()
  "A non-2xx response surfaces the provider's error message."
  (test-chat-stream-net--with-server
   (lambda (proc)
     (process-send-string
      proc
      (concat "HTTP/1.1 429 Too Many Requests\r\n"
              "Content-Type: application/json\r\n\r\n"
              "{\"error\":{\"message\":\"slow down\"}}"))
     (run-at-time 0.2 nil #'delete-process proc))
   (let (terminal)
     (chat-stream-net-post
      (format "http://127.0.0.1:%d/v1/chat/completions" port)
      nil "{}"
      #'ignore
      (lambda (_proc term) (setq terminal term)))
     (should (test-chat-stream-net--await (lambda () terminal)))
     (should (eq (plist-get terminal :class) 'http))
     (should (equal (plist-get terminal :message) "slow down")))))

(ert-deftest chat-stream-net-stall-is-classified ()
  "A connection that never sends a byte is declared stalled."
  (test-chat-stream-net--with-server
   (lambda (_proc)
     ;; Accept the request and then say nothing, ever.
     )
   (let ((chat-stream-stall-timeout 0.5)
         (chat-stream-stall-check-interval 0.2)
         terminal)
     (chat-stream-net-post
      (format "http://127.0.0.1:%d/v1/chat/completions" port)
      nil "{}"
      #'ignore
      (lambda (_proc term) (setq terminal term)))
     (should (test-chat-stream-net--await (lambda () terminal)))
     (should (eq (plist-get terminal :class) 'stall))
     (should (string-match-p "stalled" (plist-get terminal :message))))))

(ert-deftest chat-stream-net-multibyte-arrives-unsplit ()
  "A multibyte character split across chunks is delivered whole.

The delivery is line-aligned, so a UTF-8 sequence is never cut at a
chunk boundary."
  (test-chat-stream-net--with-server
   (lambda (proc)
     (let* ((text (encode-coding-string "中文内容\n" 'utf-8))
            (first (substring text 0 3))
            (second (substring text 3)))
       (process-send-string
        proc
        (format
         "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: %d\r\n\r\n"
         (length text)))
       (process-send-string proc first)
       (run-at-time 0.1 nil
                    (lambda ()
                      (process-send-string proc second)
                      (run-at-time 0.2 nil #'delete-process proc)))))
   (let ((received nil) terminal)
     (chat-stream-net-post
      (format "http://127.0.0.1:%d/" port)
      nil "{}"
      (lambda (_proc chunk)
        (push (decode-coding-string chunk 'utf-8) received))
      (lambda (_proc term) (setq terminal term)))
     (should (test-chat-stream-net--await (lambda () terminal)))
     (should (equal (nreverse received) '("中文内容\n"))))))

;; ------------------------------------------------------------------
;; Endpoint health
;; ------------------------------------------------------------------

(ert-deftest chat-stream-net-endpoint-cools-down-after-repeated-failures ()
  "Consecutive failures past the threshold cool an endpoint down."
  (chat-stream-net-endpoint-health-clear)
  (let ((chat-stream-endpoint-failure-threshold 3)
        (chat-stream-endpoint-cooldown-seconds 60))
    (dotimes (_ 2)
      (chat-stream-net-endpoint-record-failure "a:443" 'connect))
    (should (chat-stream-net-endpoint-available-p "a:443"))
    (chat-stream-net-endpoint-record-failure "a:443" 'connect)
    (should-not (chat-stream-net-endpoint-available-p "a:443"))
    ;; The cooldown expiry is the half-open trial: available again.
    (should (chat-stream-net-endpoint-available-p
             "a:443" (+ (float-time) 120))))
  (chat-stream-net-endpoint-health-clear))

(ert-deftest chat-stream-net-endpoint-success-clears-the-record ()
  "A clean completion resets consecutive failure counting."
  (chat-stream-net-endpoint-health-clear)
  (let ((chat-stream-endpoint-failure-threshold 3))
    (dotimes (_ 4)
      (chat-stream-net-endpoint-record-failure "b:443" 'stall))
    (should-not (chat-stream-net-endpoint-available-p "b:443"))
    (chat-stream-net-endpoint-record-success "b:443")
    (should (chat-stream-net-endpoint-available-p "b:443"))
    (should (null (gethash "b:443"
                           chat-stream-net--endpoint-health))))
  (chat-stream-net-endpoint-health-clear))

(ert-deftest chat-stream-net-choose-skips-a-cooling-endpoint ()
  "The first available base URL wins; a cooling one is skipped."
  (chat-stream-net-endpoint-health-clear)
  (let ((chat-stream-endpoint-failure-threshold 2))
    (dotimes (_ 2)
      (chat-stream-net-endpoint-record-failure "hot:443" 'connect))
    (should (equal (chat-stream-net-choose-base-url
                    '("https://hot/v1" "https://cold/v1"))
                   "https://cold/v1"))
    ;; When everything is cooling, the earliest cooldown wins the
    ;; half-open trial rather than the request failing outright.
    (dotimes (_ 2)
      (chat-stream-net-endpoint-record-failure "cold:443" 'connect))
    (should (member (chat-stream-net-choose-base-url
                     '("https://hot/v1" "https://cold/v1"))
                    '("https://hot/v1" "https://cold/v1"))))
  (chat-stream-net-endpoint-health-clear))

(ert-deftest chat-stream-net-cooldown-doubles-with-failures ()
  "Each failure past the threshold doubles the cooldown, capped."
  (chat-stream-net-endpoint-health-clear)
  (let ((chat-stream-endpoint-failure-threshold 1)
        (chat-stream-endpoint-cooldown-seconds 60)
        (chat-stream-endpoint-cooldown-max-seconds 1800))
    (chat-stream-net-endpoint-record-failure "c:443" 'connect)
    (let ((first (plist-get (gethash "c:443" chat-stream-net--endpoint-health)
                            :cooldown-until)))
      (chat-stream-net-endpoint-record-failure "c:443" 'connect)
      (let ((second
             (plist-get (gethash "c:443" chat-stream-net--endpoint-health)
                        :cooldown-until)))
        (should (> (- second (float-time)) 90))
        (should (> (- second (float-time)) (- first (float-time)))))))
  (chat-stream-net-endpoint-health-clear))

(provide 'test-chat-stream-net)
;;; test-chat-stream-net.el ends here
