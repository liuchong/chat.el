;;; chat-mcp.el --- Minimal MCP JSON-RPC clients for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, mcp, json-rpc

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Optional stdio and Streamable HTTP JSON-RPC primitives.  The module
;; keeps lifecycle and request state small so real servers remain
;; optional and tests can use deterministic fakes.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'chat-session)

(cl-defstruct chat-mcp-client
  id
  transport
  endpoint
  command
  process
  status
  next-id
  buffer
  pending
  responses)

(defun chat-mcp-client-create (&rest plist)
  "Create an MCP client from PLIST."
  (make-chat-mcp-client
   :id (or (plist-get plist :id)
           (chat-session-new-message-id "mcp"))
   :transport (plist-get plist :transport)
   :endpoint (plist-get plist :endpoint)
   :command (plist-get plist :command)
   :status 'created
   :next-id 0
   :buffer ""
   :pending nil
   :responses (make-hash-table :test 'equal)))

(defun chat-mcp--next-id (client)
  "Return CLIENT's next JSON-RPC id."
  (setf (chat-mcp-client-next-id client)
        (1+ (chat-mcp-client-next-id client)))
  (number-to-string (chat-mcp-client-next-id client)))

(defun chat-mcp--request (client method &optional params)
  "Build a JSON-RPC request for CLIENT METHOD and PARAMS."
  `((jsonrpc . "2.0")
    (id . ,(chat-mcp--next-id client))
    (method . ,method)
    (params . ,(or params nil))))

(defun chat-mcp--notification (method &optional params)
  "Build a JSON-RPC notification for METHOD and PARAMS."
  `((jsonrpc . "2.0")
    (method . ,method)
    (params . ,(or params nil))))

(defun chat-mcp--decode-line (line)
  "Decode one JSON-RPC LINE."
  (let ((json-object-type 'alist)
        (json-array-type 'list))
    (json-read-from-string line)))

(defun chat-mcp--handle-message (client message)
  "Record JSON-RPC MESSAGE for CLIENT."
  (if-let ((id (cdr (assoc 'id message))))
      (puthash (format "%s" id) message (chat-mcp-client-responses client))
    (push message (chat-mcp-client-pending client)))
  message)

(defun chat-mcp--handle-line (client line)
  "Decode and record one JSON-RPC LINE for CLIENT."
  (chat-mcp--handle-message client (chat-mcp--decode-line line)))

(defun chat-mcp--filter (client _process chunk)
  "Accumulate stdio CHUNK for CLIENT."
  (setf (chat-mcp-client-buffer client)
        (concat (chat-mcp-client-buffer client) chunk))
  (let ((parts (split-string (chat-mcp-client-buffer client) "\n")))
    (setf (chat-mcp-client-buffer client) (car (last parts)))
    (dolist (line (butlast parts))
      (unless (string-empty-p (string-trim line))
        (chat-mcp--handle-line client line)))))

(defun chat-mcp-stdio-start (client)
  "Start stdio MCP CLIENT."
  (unless (chat-mcp-client-command client)
    (error "Missing stdio command"))
  (let ((proc nil))
    (setq proc
          (make-process
           :name (format "chat-mcp-%s" (chat-mcp-client-id client))
           :buffer nil
           :command (chat-mcp-client-command client)
           :connection-type 'pipe
           :noquery t
           :filter (lambda (proc chunk)
                     (chat-mcp--filter client proc chunk))
           :sentinel (lambda (_proc _event)
                       (unless (and (chat-mcp-client-process client)
                                    (process-live-p
                                     (chat-mcp-client-process client)))
                         (setf (chat-mcp-client-status client) 'stopped)))))
    (setf (chat-mcp-client-process client) proc
          (chat-mcp-client-status client) 'running)
    client))

(defun chat-mcp-stop (client)
  "Stop CLIENT and mark it stopped."
  (when-let ((proc (chat-mcp-client-process client)))
    (when (process-live-p proc)
      (delete-process proc)))
  (setf (chat-mcp-client-status client) 'stopped)
  client)

(defun chat-mcp-reconnect (client)
  "Reconnect a stopped stdio CLIENT."
  (chat-mcp-stop client)
  (clrhash (chat-mcp-client-responses client))
  (setf (chat-mcp-client-buffer client) "")
  (pcase (chat-mcp-client-transport client)
    ('stdio (chat-mcp-stdio-start client))
    (_ client)))

(defun chat-mcp-stdio-request (client method &optional params timeout)
  "Send METHOD with PARAMS to stdio CLIENT and wait for response."
  (unless (and (chat-mcp-client-process client)
               (process-live-p (chat-mcp-client-process client)))
    (error "MCP client is not running"))
  (let* ((request (chat-mcp--request client method params))
         (id (cdr (assoc 'id request)))
         (deadline (+ (float-time) (or timeout 5))))
    (process-send-string
     (chat-mcp-client-process client)
     (concat (json-encode request) "\n"))
    (while (and (not (gethash id (chat-mcp-client-responses client)))
                (< (float-time) deadline)
                (process-live-p (chat-mcp-client-process client)))
      (accept-process-output (chat-mcp-client-process client) 0.05))
    (or (gethash id (chat-mcp-client-responses client))
        (error "Timed out waiting for MCP response %s" id))))

(defun chat-mcp-http-request (endpoint method &optional params)
  "Send one JSON-RPC request to HTTP ENDPOINT."
  (let* ((client (chat-mcp-client-create :transport 'http))
         (url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/json")
            ("Accept" . "application/json")))
         (url-request-data (json-encode
                            (chat-mcp--request client method params)))
         (buffer (url-retrieve-synchronously endpoint t t 10)))
    (unless buffer
      (error "No response from MCP endpoint"))
    (unwind-protect
        (with-current-buffer buffer
          (goto-char (point-min))
          (re-search-forward "\r?\n\r?\n" nil t)
          (chat-mcp--decode-line
           (buffer-substring-no-properties (point) (point-max))))
      (kill-buffer buffer))))

(defun chat-mcp-initialize (client)
  "Send initialize to MCP CLIENT."
  (pcase (chat-mcp-client-transport client)
    ('stdio (chat-mcp-stdio-request client "initialize" '((protocolVersion . "2024-11-05"))))
    ('http (chat-mcp-http-request
            (chat-mcp-client-endpoint client)
            "initialize"
            '((protocolVersion . "2024-11-05"))))))

(defun chat-mcp-list-tools (client)
  "List tools for MCP CLIENT."
  (pcase (chat-mcp-client-transport client)
    ('stdio (chat-mcp-stdio-request client "tools/list"))
    ('http (chat-mcp-http-request (chat-mcp-client-endpoint client)
                                  "tools/list"))))

(defun chat-mcp-call-tool (client name &optional arguments)
  "Call MCP tool NAME with ARGUMENTS."
  (let ((params `((name . ,name) (arguments . ,(or arguments nil)))))
    (pcase (chat-mcp-client-transport client)
      ('stdio (chat-mcp-stdio-request client "tools/call" params))
      ('http (chat-mcp-http-request (chat-mcp-client-endpoint client)
                                    "tools/call" params)))))

(defun chat-mcp-cancel (client request-id)
  "Send a cancellation notification for REQUEST-ID."
  (let ((notification (chat-mcp--notification
                      "$/cancelRequest"
                      `((id . ,request-id)))))
    (when (and (chat-mcp-client-process client)
               (process-live-p (chat-mcp-client-process client)))
      (process-send-string
       (chat-mcp-client-process client)
       (concat (json-encode notification) "\n")))
    notification))

(provide 'chat-mcp)
;;; chat-mcp.el ends here
