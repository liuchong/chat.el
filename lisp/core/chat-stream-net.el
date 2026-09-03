;;; chat-stream-net.el --- In-process HTTP/1.1 streaming transport -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: llm, http, sse, transport

;; This file is not part of GNU Emacs.

;;; Commentary:

;; In-process streaming HTTP transport for LLM providers.
;;
;; The streaming path used to shell out to curl.  That worked, but every
;; failure arrived as a bare process exit code ("exited abnormally with
;; code 18"), credentials had to pass through a temporary config file, and
;; mid-stream truncation was indistinguishable from a finished response.
;; This module owns the whole request lifecycle in Emacs: TLS via GnuTLS,
;; HTTP/1.1 with `Connection: close', incremental chunked decoding, and
;; line-aligned delivery so a multibyte character is never split across a
;; decoding boundary.
;;
;; Failures are classified here, not at call sites: dns, connect, tls,
;; http and mid-stream-close.  Slowness while the connection stays
;; alive is only ever noticed, never cancelled.  Per-endpoint health records turn
;; repeated transport failures into a temporary cooldown so a provider
;; with several base URLs falls to the next line while the broken one
;; recovers; a half-open trial after cooldown restores it on success.
;; That adjustment is temporary and per endpoint -- it never reorders the
;; user's models or rewrites a registration.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'chat-log)

(defgroup chat-stream-net nil
  "In-process streaming transport configuration."
  :group 'chat)

(defcustom chat-stream-slow-notice-seconds 120
  "Idle seconds after which a live request is noted as slower than expected.

A notice is all this ever is: while the connection is alive the request
keeps waiting.  A slow first token (a reasoning model prefilling a large
context) or a slow stretch mid-stream is a common, legitimate thing; the
reader deserves to know it is slow, not to have it killed."
  :type 'number
  :group 'chat-stream-net)

(defcustom chat-stream-slow-check-interval 15
  "Seconds between slowness checks on a live stream."
  :type 'number
  :group 'chat-stream-net)

(defcustom chat-stream-connect-timeout 30
  "Seconds to establish a connection before failing the request.

This bounds only the phase where no connection exists at all; once the
endpoint has answered, nothing here cancels a slow response."
  :type 'number
  :group 'chat-stream-net)

(defcustom chat-stream-connect-timeout 30
  "Seconds to establish a connection before failing the request."
  :type 'number
  :group 'chat-stream-net)

(defcustom chat-stream-endpoint-failure-threshold 3
  "Consecutive transport failures before an endpoint is cooled down."
  :type 'integer
  :group 'chat-stream-net)

(defcustom chat-stream-endpoint-cooldown-seconds 60
  "Base cooldown seconds for a failing endpoint; doubles per failure."
  :type 'number
  :group 'chat-stream-net)

(defcustom chat-stream-endpoint-cooldown-max-seconds 1800
  "Upper bound for one endpoint cooldown."
  :type 'number
  :group 'chat-stream-net)

;; ------------------------------------------------------------------
;; Endpoint health
;; ------------------------------------------------------------------

(defvar chat-stream-net--endpoint-health (make-hash-table :test 'equal)
  "In-memory endpoint health records keyed by \"host:port\".

Each value is a plist of :failures (consecutive transport failures),
:cooldown-until (a float time or nil) and :last-class.  Nothing here is
persisted: a restarted Emacs starts with no opinions.")

(defun chat-stream-net--endpoint-key (host port)
  "Return the health-record key for HOST and PORT."
  (format "%s:%s" host port))

(defun chat-stream-net-endpoint-record-success (key)
  "Clear any health record for endpoint KEY after a clean completion."
  (remhash key chat-stream-net--endpoint-health))

(defun chat-stream-net-endpoint-record-failure (key class)
  "Record a transport failure of CLASS for endpoint KEY.

Once consecutive failures reach
`chat-stream-endpoint-failure-threshold', the endpoint is cooled down:
`chat-stream-net-endpoint-available-p' answers nil until the cooldown
expires.  The cooldown doubles per further failure, bounded by
`chat-stream-endpoint-cooldown-max-seconds'."
  (let* ((entry (gethash key chat-stream-net--endpoint-health))
         (failures (1+ (or (plist-get entry :failures) 0)))
         (cooldown
          (and (>= failures chat-stream-endpoint-failure-threshold)
               (+ (float-time)
                  (min (* chat-stream-endpoint-cooldown-seconds
                          (ash 1 (min 10
                                      (- failures
                                         chat-stream-endpoint-failure-threshold))))
                       chat-stream-endpoint-cooldown-max-seconds)))))
    (puthash key
             (list :failures failures
                   :cooldown-until (or cooldown
                                       (plist-get entry :cooldown-until))
                   :last-class class)
             chat-stream-net--endpoint-health)
    (chat-log "[STREAM-NET] endpoint %s failure %s (%d consecutive%s)"
              key class failures
              (if cooldown ", cooling down" ""))
    failures))

(defun chat-stream-net-endpoint-available-p (key &optional now)
  "Return non-nil when endpoint KEY may take a request at time NOW.
A cooling endpoint answers nil until its cooldown expires; the expired
cooldown is the half-open trial that either clears the record or
re-cools the endpoint."
  (let ((until (plist-get (gethash key chat-stream-net--endpoint-health)
                          :cooldown-until)))
    (or (null until) (<= until (or now (float-time))))))

(defun chat-stream-net--url-endpoint-key (url)
  "Return the health-record key for URL, or nil when unparseable."
  (when-let* ((parsed (and (stringp url) (url-generic-parse-url url)))
              (host (url-host parsed)))
    (let ((scheme (downcase (or (url-type parsed) "https"))))
      (chat-stream-net--endpoint-key
       host (or (url-port parsed)
                (if (string= scheme "https") 443 80))))))

(defun chat-stream-net-choose-base-url (base-urls)
  "Choose the first available endpoint from BASE-URLS.

When every endpoint is cooling down, the one whose cooldown ends
soonest is returned -- that request is the half-open trial.  With no
parseable URL at all, the first entry is returned as-is so the error
surfaces at connection time rather than here."
  (let ((parsed
         (delq nil
               (mapcar (lambda (url)
                         (when-let ((key (chat-stream-net--url-endpoint-key url)))
                           (list url key)))
                       (or base-urls nil)))))
    (if (null parsed)
        (car base-urls)
      (or (car (seq-find (lambda (entry)
                           (chat-stream-net-endpoint-available-p
                            (cadr entry)))
                         parsed))
          (car (car (sort (copy-sequence parsed)
                          (lambda (left right)
                            (< (or (plist-get
                                    (gethash (cadr left)
                                             chat-stream-net--endpoint-health)
                                    :cooldown-until)
                                   0)
                               (or (plist-get
                                    (gethash (cadr right)
                                             chat-stream-net--endpoint-health)
                                    :cooldown-until)
                                   0))))))))))

;; ------------------------------------------------------------------
;; Request construction
;; ------------------------------------------------------------------

(defun chat-stream-net--build-request (host port path headers body)
  "Build an unibyte HTTP/1.1 request for PATH on HOST:PORT.

HEADERS is an alist of (NAME . VALUE); BODY is already unibyte.  The
request asks for `identity' encoding and a closed connection, which is
what makes end-of-body decidable without content-length."
  (let ((header-lines
         (mapconcat
          (lambda (header)
            (format "%s: %s" (car header) (cdr header)))
          headers
          "\r\n")))
    (concat
     (format "POST %s HTTP/1.1\r\n" path)
     (format "Host: %s\r\n" (if (memq port '(80 443))
                                host
                              (format "%s:%s" host port)))
     header-lines "\r\n"
     "Accept-Encoding: identity\r\n"
     (format "Content-Length: %d\r\n" (length body))
     "Connection: close\r\n"
     "\r\n"
     body)))

;; ------------------------------------------------------------------
;; Response parsing
;; ------------------------------------------------------------------
;;
;; State lives on process properties: the process outlives its buffer
;; (the runtime inspects it after EOF), while the buffer is where the
;; bytes arrive.  The buffer is unibyte so positions equal byte counts.

(defun chat-stream-net--buffer-of (proc)
  "Return PROC's byte buffer."
  (process-get proc 'chat-stream-net-buffer))

(defun chat-stream-net--reset-slow-watch (proc)
  "Re-arm the slowness watch for PROC on every sign of life."
  (process-put proc 'chat-stream-net-last-byte (float-time)))

(defun chat-stream-net--parse-headers (proc text)
  "Parse the header block TEXT for PROC, returning non-nil when handled."
  (let* ((lines (split-string text "\r\n"))
         (status-line (car lines)))
    (unless (and status-line
                 (string-match "^HTTP/[0-9.]+ \\([0-9]+\\)" status-line))
      (error "Malformed HTTP response: %s" status-line))
    (let ((status (string-to-number (match-string 1 status-line)))
          (headers nil))
      (dolist (line (cdr lines))
        (when (string-match "^\\([^:]+\\):[ \t]*\\(.*\\)$" line)
          (push (cons (downcase (match-string 1 line))
                      (match-string 2 line))
                headers)))
      (process-put proc 'chat-stream-net-status status)
      (process-put proc 'chat-stream-net-headers-done t)
      (process-put proc 'chat-stream-net-chunked
                   (string-match-p
                    "chunked"
                    (downcase
                     (or (cdr (assoc "transfer-encoding" headers)) ""))))
      (process-put proc 'chat-stream-net-content-length
                   (and (cdr (assoc "content-length" headers))
                        (string-to-number
                         (cdr (assoc "content-length" headers)))))
      (when (and status (or (< status 200) (>= status 300)))
        ;; Error bodies are read to EOF and parsed there; they are not
        ;; delivered as stream data.
        (process-put proc 'chat-stream-net-error-body t)))))

(defun chat-stream-net--deliver (proc text)
  "Deliver response body TEXT to PROC's data callback, line-aligned.

A chunk boundary may split a multibyte character, but a newline never
appears inside one, so the callback only ever receives whole lines
(plus at EOF whatever partial line remains).  This is what makes the
per-chunk UTF-8 decoding in the SSE layer safe."
  (let ((carry (process-get proc 'chat-stream-net-line-carry)))
    (setq text (concat carry text))
    (let ((newline-pos nil)
          (deliverable ""))
      (while (setq newline-pos (string-match "\n" text))
        (setq deliverable
              (concat deliverable (substring text 0 (1+ newline-pos))))
        (setq text (substring text (1+ newline-pos))))
      (process-put proc 'chat-stream-net-line-carry text)
      (unless (string-empty-p deliverable)
        (process-put proc 'chat-stream-net-body-bytes
                     (+ (or (process-get proc 'chat-stream-net-body-bytes) 0)
                        (length deliverable)))
        (funcall (process-get proc 'chat-stream-net-on-data)
                 proc deliverable)))))

(defun chat-stream-net--parse-chunked (proc)
  "Consume as much chunked body as the buffer of PROC currently holds."
  (with-current-buffer (chat-stream-net--buffer-of proc)
    (let ((done nil))
      (while (not done)
        (cond
         ;; Awaiting a chunk-size line.
         ((null (process-get proc 'chat-stream-net-chunk-left))
          (let ((crlf (search-forward "\r\n" nil t)))
            (if (null crlf)
                (setq done t)
              (let* ((line (buffer-substring
                            (save-excursion (forward-line -1) (point))
                            (- crlf 2)))
                     (size (string-to-number
                            (car (split-string line ";")) 16)))
                (delete-region (save-excursion (forward-line -1) (point))
                               crlf)
                (if (zerop size)
                    (progn
                      (process-put proc 'chat-stream-net-complete t)
                      (setq done t))
                  (process-put proc 'chat-stream-net-chunk-left size))))))
         ;; Awaiting the chunk body plus its trailing CRLF.
         ((>= (point-max)
              (+ (point) (process-get proc 'chat-stream-net-chunk-left) 2))
          (let* ((size (process-get proc 'chat-stream-net-chunk-left))
                 (text (buffer-substring (point) (+ (point) size))))
            (delete-region (point) (+ (point) size 2))
            (process-put proc 'chat-stream-net-chunk-left nil)
            (chat-stream-net--deliver proc text)))
         (t (setq done t)))))))

(defun chat-stream-net--parse-available (proc)
  "Consume everything currently decodable from PROC's buffer."
  (with-current-buffer (chat-stream-net--buffer-of proc)
    (goto-char (point-min))
    (when (and (not (process-get proc 'chat-stream-net-headers-done))
               (search-forward "\r\n\r\n" nil t))
      (let ((header-text (buffer-substring (point-min) (- (point) 4))))
        (delete-region (point-min) (point))
        (chat-stream-net--parse-headers proc header-text)))
    (when (process-get proc 'chat-stream-net-headers-done)
      (cond
       ((process-get proc 'chat-stream-net-error-body)
        ;; Read to EOF; parsed in the finalizer.
        nil)
       ((process-get proc 'chat-stream-net-chunked)
        (chat-stream-net--parse-chunked proc))
       (t
        (let ((text (buffer-substring (point-min) (point-max))))
          (unless (string-empty-p text)
            (delete-region (point-min) (point-max))
            (chat-stream-net--deliver proc text))
          (when-let* ((length (process-get proc
                                           'chat-stream-net-content-length))
                      (received
                       (or (process-get proc 'chat-stream-net-body-bytes) 0)))
            (when (>= received length)
              (process-put proc 'chat-stream-net-complete t)))))))))

;; ------------------------------------------------------------------
;; Classification and finalization
;; ------------------------------------------------------------------

(defun chat-stream-net--error-body-message (proc)
  "Extract a provider error message from PROC's buffered error body."
  (let ((body (with-current-buffer (chat-stream-net--buffer-of proc)
                (buffer-string))))
    (or (condition-case nil
            (cdr (assoc 'message
                        (cdr (assoc 'error
                                    (json-read-from-string
                                     (decode-coding-string body 'utf-8))))))
          (error nil))
        (and (string-match-p "\\S" body)
             (truncate-string-to-width
              (decode-coding-string body 'utf-8) 256 nil nil t))
        (format "HTTP %s" (process-get proc 'chat-stream-net-status)))))

(defun chat-stream-net--classify-connect-failure (event)
  "Classify a connection failure from its sentinel EVENT string."
  (cond
   ((string-match-p "resolve\\|name\\|host" (downcase event)) 'dns)
   ((string-match-p "tls\\|certificate\\|gnutls" (downcase event)) 'tls)
   (t 'connect)))

(defun chat-stream-net--message (class host detail)
  "Return the user-facing message for failure CLASS on HOST with DETAIL."
  (pcase class
    ('dns
     (format "Cannot resolve %s: %s. Network is down or DNS is broken; check the connection and retry."
             host detail))
    ('connect
     (format "Cannot connect to %s: %s. The endpoint is unreachable from here; retry, or switch the line if it persists."
             host detail))
    ('tls
     (format "TLS negotiation with %s failed: %s. Check the local network for interception and retry."
             host detail))
    ('slow
     (format "No data from %s for %s seconds: slower than expected (the model may still be prefilling or thinking). The connection is alive; keep waiting, or C-g to cancel."
             host detail))
    ('mid-stream-close
     (format "Connection to %s closed mid-stream%s: the relay or upstream link is unstable. Retry with C-c C-g."
             host detail))
    (_ detail)))

(defun chat-stream-net--finalize (proc &optional deleted-locally)
  "Settle PROC's terminal state exactly once, then release its buffer."
  (unless (process-get proc 'chat-stream-net-finished)
    (process-put proc 'chat-stream-net-finished t)
    (when-let ((timer (process-get proc 'chat-stream-net-watchdog)))
      (cancel-timer timer))
    (when-let ((timer (process-get proc 'chat-stream-net-connect-timer)))
      (cancel-timer timer))
    (let* ((host (process-get proc 'chat-stream-net-host))
           (key (process-get proc 'chat-stream-net-endpoint-key))
           (status (process-get proc 'chat-stream-net-status))
           (body-bytes (or (process-get proc 'chat-stream-net-body-bytes) 0))
           (elapsed (and (process-get proc 'chat-stream-net-started-at)
                         (format " after %.1fs"
                                 (- (float-time)
                                    (process-get proc
                                                 'chat-stream-net-started-at))))))
      (cond
       (deleted-locally
        ;; Cancel teardown already reported; nothing to add.
        nil)
       ((process-get proc 'chat-stream-terminal)
        ;; A classifier (connect timer, parse error,
        ;; connect failure) has already named this failure.  The
        ;; EOF-time recomputation below must not overwrite it with its
        ;; blunter guess.
        nil)
       ((process-get proc 'chat-stream-net-error-body)
        (let ((message (chat-stream-net--error-body-message proc)))
          (when (and status (>= status 500))
            (chat-stream-net-endpoint-record-failure key 'http-5xx))
          (process-put proc 'chat-stream-terminal
                       (list :status 'error :class 'http
                             :message message))))
       ((or (process-get proc 'chat-stream-net-complete)
            (process-get proc 'chat-stream-net-saw-done))
        (chat-stream-net-endpoint-record-success key)
        (process-put proc 'chat-stream-terminal (list :status 'ok)))
       ((zerop body-bytes)
        (let ((class (if status 'mid-stream-close 'connect))
              (detail (if status
                          "the response carried no body at all"
                        "the connection closed before any response")))
          (chat-stream-net-endpoint-record-failure key class)
          (process-put proc 'chat-stream-terminal
                       (list :status 'error :class class
                             :message
                             (chat-stream-net--message class host detail)))))
       (t
        (chat-stream-net-endpoint-record-failure key 'mid-stream-close)
        (process-put proc 'chat-stream-terminal
                     (list :status 'error :class 'mid-stream-close
                           :message
                           (chat-stream-net--message
                            'mid-stream-close host
                            (or elapsed "")))))))
    (when-let ((terminal (process-get proc 'chat-stream-terminal)))
      (funcall (process-get proc 'chat-stream-net-on-terminal)
               proc terminal))
    (let ((buffer (chat-stream-net--buffer-of proc)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

;; ------------------------------------------------------------------
;; Process plumbing
;; ------------------------------------------------------------------

(defun chat-stream-net--filter (proc chunk)
  "Accumulate CHUNK from PROC and parse whatever is complete."
  (chat-stream-net--reset-slow-watch proc)
  (condition-case err
      (let ((buffer (chat-stream-net--buffer-of proc)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert chunk))
          (chat-stream-net--parse-available proc)))
    (error
     (chat-log "[STREAM-NET] parse error: %s" (error-message-string err))
     (process-put proc 'chat-stream-terminal
                  (list :status 'error :class 'protocol
                        :message (format "Malformed response from %s: %s"
                                         (process-get proc
                                                      'chat-stream-net-host)
                                         (error-message-string err))))
     (chat-stream-net--finalize proc))))

(defun chat-stream-net--sentinel (proc event)
  "Drive PROC's lifecycle from network EVENT strings."
  (chat-log "[STREAM-NET] event: %s" (string-trim event))
  (cond
   ((string-prefix-p "open" event)
    (process-put proc 'chat-stream-net-started-at (float-time))
    (chat-stream-net--reset-slow-watch proc)
    (condition-case err
        (process-send-string proc (process-get proc 'chat-stream-net-request))
      (error
       (process-put proc 'chat-stream-terminal
                    (list :status 'error :class 'connect
                          :message (error-message-string err)))
       (chat-stream-net--finalize proc))))
   ((string-match-p "connection broken\\|finished\\|closed" event)
    ;; Remote EOF.  Flush any partial line, then settle.
    (when-let ((carry (process-get proc 'chat-stream-net-line-carry)))
      (unless (string-empty-p carry)
        (process-put proc 'chat-stream-net-line-carry nil)
        (process-put proc 'chat-stream-net-body-bytes
                     (+ (or (process-get proc 'chat-stream-net-body-bytes) 0)
                        (length carry)))
        (condition-case nil
            (funcall (process-get proc 'chat-stream-net-on-data)
                     proc carry)
          (error nil))))
    (chat-stream-net--finalize proc))
   ((string-match-p "failed\\|broken pipe\\|deleted" event)
    (if (string-match-p "deleted" event)
        ;; Local teardown (cancel) already settled.
        (chat-stream-net--finalize proc t)
      (let ((class (chat-stream-net--classify-connect-failure event)))
        (chat-stream-net-endpoint-record-failure
         (process-get proc 'chat-stream-net-endpoint-key) class)
        (process-put proc 'chat-stream-terminal
                     (list :status 'error :class class
                           :message
                           (chat-stream-net--message
                            class (process-get proc 'chat-stream-net-host)
                            (string-trim event))))
        (chat-stream-net--finalize proc))))))

(defun chat-stream-net--start-watchdog (proc)
  "Arm the slowness watcher for PROC.

The watcher notices and never cancels: a request whose connection is
alive keeps waiting.  Its only output is a diagnostics record the live
status surfaces, so a slow stretch reads as slow instead of stuck."
  (process-put
   proc 'chat-stream-net-watchdog
   (run-at-time
    chat-stream-slow-check-interval chat-stream-slow-check-interval
    (lambda (process)
      (when (and (process-live-p process)
                 (process-get process 'chat-stream-net-started-at)
                 (not (process-get process 'chat-stream-net-slow-noticed)))
        (let ((idle (- (float-time)
                       (or (process-get process
                                        'chat-stream-net-last-byte)
                           (float-time)))))
          (when (> idle chat-stream-slow-notice-seconds)
            (process-put process 'chat-stream-net-slow-noticed t)
            (when-let ((request-id (process-get process 'chat-request-id)))
              (chat-request-diagnostics-record
               request-id 'stream-slow
               :summary
               (chat-stream-net--message
                'slow
                (process-get process 'chat-stream-net-host)
                (format "%s" chat-stream-slow-notice-seconds))))))))
   proc)))

;; ------------------------------------------------------------------
;; Entry point
;; ------------------------------------------------------------------

(defun chat-stream-net-post (url headers body on-data on-terminal)
  "POST BODY to URL with HEADERS, streaming the response.

HEADERS is an alist of (NAME . VALUE).  BODY may be multibyte and is
sent as UTF-8.  ON-DATA is called as (PROC CHUNK) with unibyte CHUNKs
cut on line boundaries.  ON-TERMINAL is called exactly once as
\(PROC TERMINAL) where TERMINAL is a plist with :status ok or :status
error plus :class and :message.

The returned network process carries the terminal plist on its
`chat-stream-terminal' property, so a wrapping sentinel can settle
without parsing event strings."
  (let* ((parsed (url-generic-parse-url url))
         (scheme (downcase (or (url-type parsed) "https")))
         (host (or (url-host parsed) (error "No host in %s" url)))
         (port (or (url-port parsed)
                   (if (string= scheme "https") 443 80)))
         (path (or (car (url-path-and-query parsed)) "/"))
         (body-bin (if (multibyte-string-p body)
                       (encode-coding-string body 'utf-8)
                     body))
         (buffer (generate-new-buffer " *chat-stream-net*"))
         (key (chat-stream-net--endpoint-key host port))
         proc)
    (with-current-buffer buffer
      (set-buffer-multibyte nil))
    (condition-case err
        (progn
          (setq proc
                (open-network-stream
                 "chat-stream-net" nil host port
                 :type (if (string= scheme "https") 'tls 'plain)
                 :nowait t))
          (process-put proc 'chat-stream-net-buffer buffer)
          (process-put proc 'chat-stream-net-host host)
          (process-put proc 'chat-stream-net-endpoint-key key)
          (process-put proc 'chat-stream-net-on-data on-data)
          (process-put proc 'chat-stream-net-on-terminal on-terminal)
          (process-put
           proc 'chat-stream-net-request
           (chat-stream-net--build-request host port path headers body-bin))
          (set-process-coding-system proc 'binary 'binary)
          (set-process-filter proc #'chat-stream-net--filter)
          (set-process-sentinel proc #'chat-stream-net--sentinel)
          (set-process-query-on-exit-flag proc nil)
          (process-put
           proc 'chat-stream-net-connect-timer
           (run-at-time
            chat-stream-connect-timeout nil
            (lambda (process)
              (when (and (process-live-p process)
                         (null (process-get process
                                            'chat-stream-net-started-at)))
                (process-put
                 process 'chat-stream-terminal
                 (list :status 'error :class 'connect
                       :message
                       (chat-stream-net--message
                        'connect
                        (process-get process 'chat-stream-net-host)
                        (format "no connection after %s seconds"
                                chat-stream-connect-timeout))))
                (chat-stream-net-endpoint-record-failure
                 (process-get process 'chat-stream-net-endpoint-key)
                 'connect)
                (delete-process process)
                (chat-stream-net--finalize process t)))
            ;; The timer fires with the process in hand: a lambda that
            ;; declared it but never received it turned the timeout path
            ;; itself into the error.
            proc))
          (chat-stream-net--start-watchdog proc)
          proc)
      (error
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (chat-stream-net-endpoint-record-failure
        key (chat-stream-net--classify-connect-failure
             (error-message-string err)))
       (signal (car err) (cdr err))))))

(defun chat-stream-net-endpoint-health-clear ()
  "Forget every endpoint health record."
  (clrhash chat-stream-net--endpoint-health))

(provide 'chat-stream-net)
;;; chat-stream-net.el ends here
