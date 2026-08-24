;;; chat-mcp.el --- MCP clients and remote tools for chat.el -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, mcp, json-rpc

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Optional stdio and Streamable HTTP JSON-RPC clients.  Configured
;; servers are exposed through generic management tools; discovery also
;; registers each remote capability as a schema-aware forged tool.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'chat-session)
(require 'chat-tool-forge)

(defgroup chat-mcp nil
  "Model Context Protocol integration for chat.el."
  :group 'chat)

(defcustom chat-mcp-servers nil
  "Configured MCP servers.
Each entry is a plist with `:id', `:transport', and either `:command'
for stdio or `:endpoint' for HTTP.  Servers are not connected until the
user or agent invokes the connect tool."
  :type 'sexp
  :group 'chat-mcp)

(defcustom chat-mcp-request-timeout 30
  "Default timeout in seconds for MCP requests."
  :type 'number
  :group 'chat-mcp)

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
  responses
  remote-tools
  notifications
  session-id)

(defvar chat-mcp--clients (make-hash-table :test 'equal)
  "Configured MCP clients keyed by server id.")

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
   :pending (make-hash-table :test 'equal)
   :responses (make-hash-table :test 'equal)
   :remote-tools nil
   :notifications nil))

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

(defun chat-mcp--decode-http-body (body)
  "Decode JSON or SSE BODY into one JSON-RPC message."
  (let ((trimmed (string-trim body)))
    (if (string-prefix-p "event:" trimmed)
        (let (payload)
          (dolist (line (split-string trimmed "\n"))
            (when (string-prefix-p "data:" line)
              (setq payload
                    (string-trim (substring line (length "data:"))))))
          (unless payload
            (error "MCP SSE response has no data event"))
          (chat-mcp--decode-line payload))
      (chat-mcp--decode-line trimmed))))

(defun chat-mcp--http-response-body (client)
  "Read current HTTP response body and update CLIENT session id."
  (goto-char (point-min))
  (let ((case-fold-search t))
    (when (re-search-forward
           "^mcp-session-id:[ \t]*\\([^\r\n]+\\)" nil t)
      (setf (chat-mcp-client-session-id client)
            (string-trim (match-string 1)))))
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (error "Malformed MCP HTTP response"))
  (buffer-substring-no-properties (point) (point-max)))

(defun chat-mcp--http-headers (client)
  "Return Streamable HTTP headers for CLIENT."
  (append
   '(("Content-Type" . "application/json")
     ("Accept" . "application/json, text/event-stream")
     ("MCP-Protocol-Version" . "2024-11-05"))
   (when-let ((session-id (chat-mcp-client-session-id client)))
     `(("Mcp-Session-Id" . ,session-id)))))

(defun chat-mcp--handle-message (client message)
  "Record JSON-RPC MESSAGE for CLIENT."
  (if-let ((id (cdr (assoc 'id message))))
      (let* ((key (format "%s" id))
             (pending (gethash key (chat-mcp-client-pending client))))
        (puthash key message (chat-mcp-client-responses client))
        (when pending
          (remhash key (chat-mcp-client-pending client))
          (when-let ((timer (plist-get pending :timer)))
            (cancel-timer timer))
          (if-let ((rpc-error (cdr (assoc 'error message))))
              (funcall (plist-get pending :error)
                       (format "%s" rpc-error))
            (funcall (plist-get pending :success) message))))
    (push message (chat-mcp-client-notifications client)))
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
  (maphash
   (lambda (_id pending)
     (when-let ((timer (plist-get pending :timer)))
       (cancel-timer timer))
     (funcall (plist-get pending :error) "MCP client stopped"))
   (chat-mcp-client-pending client))
  (clrhash (chat-mcp-client-pending client))
  (when-let ((proc (chat-mcp-client-process client)))
    (when (process-live-p proc)
      (delete-process proc)))
  (setf (chat-mcp-client-status client) 'stopped)
  client)

(defun chat-mcp-reconnect (client)
  "Reconnect a stopped stdio CLIENT."
  (chat-mcp-stop client)
  (clrhash (chat-mcp-client-responses client))
  (clrhash (chat-mcp-client-pending client))
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

(defun chat-mcp--request-timeout (client id)
  "Fail pending CLIENT request ID after its timeout."
  (when-let ((pending (gethash id (chat-mcp-client-pending client))))
    (remhash id (chat-mcp-client-pending client))
    (funcall (plist-get pending :error)
             (format "Timed out waiting for MCP response %s" id))))

(defun chat-mcp-stdio-request-async
    (client method params success error-callback &optional timeout)
  "Send asynchronous stdio METHOD with PARAMS through CLIENT."
  (unless (and (chat-mcp-client-process client)
               (process-live-p (chat-mcp-client-process client)))
    (error "MCP client is not running"))
  (let* ((request (chat-mcp--request client method params))
         (id (cdr (assoc 'id request)))
         (timer (run-at-time
                 (or timeout chat-mcp-request-timeout) nil
                 #'chat-mcp--request-timeout client id)))
    (puthash id (list :success success :error error-callback :timer timer)
             (chat-mcp-client-pending client))
    (process-send-string
     (chat-mcp-client-process client)
     (concat (json-encode request) "\n"))
    (list
     :cancel
     (lambda ()
       (when-let ((pending (gethash id (chat-mcp-client-pending client))))
         (when-let ((pending-timer (plist-get pending :timer)))
           (cancel-timer pending-timer))
         (remhash id (chat-mcp-client-pending client))
         (chat-mcp-cancel client id))))))

(defun chat-mcp-http-client-request (client method &optional params)
  "Send one JSON-RPC METHOD through HTTP CLIENT."
  (let* ((endpoint (chat-mcp-client-endpoint client))
         (url-request-method "POST")
         (url-request-extra-headers (chat-mcp--http-headers client))
         (url-request-data (json-encode
                            (chat-mcp--request client method params)))
         (buffer (url-retrieve-synchronously endpoint t t 10)))
    (unless buffer
      (error "No response from MCP endpoint"))
    (unwind-protect
        (with-current-buffer buffer
          (chat-mcp--decode-http-body
           (chat-mcp--http-response-body client)))
      (kill-buffer buffer))))

(defun chat-mcp-http-request (endpoint method &optional params)
  "Send one JSON-RPC request to HTTP ENDPOINT."
  (chat-mcp-http-client-request
   (chat-mcp-client-create :transport 'http :endpoint endpoint)
   method params))

(defun chat-mcp-send-notification (client method &optional params)
  "Send JSON-RPC notification METHOD through CLIENT."
  (let ((payload (concat
                  (json-encode (chat-mcp--notification method params))
                  "\n")))
    (pcase (chat-mcp-client-transport client)
      ('stdio
       (unless (and (chat-mcp-client-process client)
                    (process-live-p (chat-mcp-client-process client)))
         (error "MCP client is not running"))
       (process-send-string (chat-mcp-client-process client) payload))
      ('http
       (let* ((url-request-method "POST")
              (url-request-extra-headers (chat-mcp--http-headers client))
              (url-request-data (string-trim-right payload))
              (buffer
               (url-retrieve-synchronously
                (chat-mcp-client-endpoint client) t t 10)))
         (when (buffer-live-p buffer)
           (kill-buffer buffer))))
      (_ (error "Unsupported MCP transport: %s"
                (chat-mcp-client-transport client)))))
  t)

(defun chat-mcp-http-request-async
    (client method params success error-callback &optional timeout)
  "Send asynchronous JSON-RPC METHOD through HTTP CLIENT."
  (let* ((endpoint (chat-mcp-client-endpoint client))
         (url-request-method "POST")
         (url-request-extra-headers (chat-mcp--http-headers client))
         (url-request-data
          (json-encode (chat-mcp--request client method params)))
         (done nil)
         buffer
         timer)
    (setq
     buffer
     (url-retrieve
      endpoint
      (lambda (status)
        (unless done
          (setq done t)
          (when (timerp timer)
            (cancel-timer timer))
          (unwind-protect
              (if-let ((failure (plist-get status :error)))
                  (funcall error-callback (format "%s" failure))
                (condition-case err
                    (progn
                      (goto-char (point-min))
                      (let ((message
                             (chat-mcp--decode-http-body
                              (chat-mcp--http-response-body client))))
                        (if-let ((rpc-error (cdr (assoc 'error message))))
                            (funcall error-callback (format "%s" rpc-error))
                          (funcall success message))))
                  (error
                   (funcall error-callback
                            (error-message-string err)))))
            (when (buffer-live-p (current-buffer))
              (kill-buffer (current-buffer))))))))
    (setq timer
          (run-at-time
           (or timeout chat-mcp-request-timeout) nil
           (lambda ()
             (unless done
               (setq done t)
               (when (buffer-live-p buffer)
                 (kill-buffer buffer))
               (funcall error-callback "Timed out waiting for MCP response")))))
    (list :cancel
          (lambda ()
            (unless done
              (setq done t)
              (when (timerp timer)
                (cancel-timer timer))
              (when (buffer-live-p buffer)
                (kill-buffer buffer)))))))

(defun chat-mcp-request-async
    (client method params success error-callback &optional timeout)
  "Send asynchronous METHOD with PARAMS through CLIENT."
  (pcase (chat-mcp-client-transport client)
    ('stdio
     (chat-mcp-stdio-request-async
      client method params success error-callback timeout))
    ('http
     (chat-mcp-http-request-async
      client method params success error-callback timeout))
    (_ (error "Unsupported MCP transport: %s"
              (chat-mcp-client-transport client)))))

(defun chat-mcp-initialize (client)
  "Send initialize to MCP CLIENT."
  (let ((response
         (pcase (chat-mcp-client-transport client)
           ('stdio
            (chat-mcp-stdio-request
             client "initialize" '((protocolVersion . "2024-11-05"))))
           ('http
            (chat-mcp-http-client-request
             client "initialize"
             '((protocolVersion . "2024-11-05")))))))
    (chat-mcp-send-notification client "notifications/initialized")
    response))

(defun chat-mcp-list-tools (client)
  "List tools for MCP CLIENT."
  (pcase (chat-mcp-client-transport client)
    ('stdio (chat-mcp-stdio-request client "tools/list"))
    ('http (chat-mcp-http-client-request client "tools/list"))))

(defun chat-mcp-call-tool (client name &optional arguments)
  "Call MCP tool NAME with ARGUMENTS."
  (let ((params `((name . ,name) (arguments . ,(or arguments nil)))))
    (pcase (chat-mcp-client-transport client)
      ('stdio (chat-mcp-stdio-request client "tools/call" params))
      ('http (chat-mcp-http-client-request client "tools/call" params)))))

(defun chat-mcp-call-tool-async
    (client name arguments success error-callback)
  "Call MCP tool NAME asynchronously with ARGUMENTS."
  (chat-mcp-request-async
   client "tools/call"
   `((name . ,name) (arguments . ,(or arguments nil)))
   success error-callback))

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

(defun chat-mcp-configure-servers ()
  "Create clients for `chat-mcp-servers' without connecting them."
  (clrhash chat-mcp--clients)
  (dolist (config chat-mcp-servers)
    (let* ((id (plist-get config :id))
           (client
            (chat-mcp-client-create
             :id id
             :transport (plist-get config :transport)
             :command (plist-get config :command)
             :endpoint (plist-get config :endpoint))))
      (unless (and (stringp id) (not (string-empty-p id)))
        (error "MCP server config requires a string :id"))
      (puthash id client chat-mcp--clients)))
  (hash-table-count chat-mcp--clients))

(defun chat-mcp-client-get (id)
  "Return configured MCP client ID."
  (or (gethash id chat-mcp--clients)
      (error "MCP server not configured: %s" id)))

(defun chat-mcp-server-list ()
  "Return configured MCP server summaries."
  (let (servers)
    (maphash
     (lambda (id client)
       (push `((id . ,id)
               (transport . ,(symbol-name
                              (chat-mcp-client-transport client)))
               (status . ,(symbol-name (chat-mcp-client-status client)))
               (tools . ,(length (chat-mcp-client-remote-tools client))))
             servers))
     chat-mcp--clients)
    (nreverse servers)))

(defun chat-mcp--response-result (response)
  "Return result from JSON-RPC RESPONSE or signal its error."
  (if-let ((rpc-error (cdr (assoc 'error response))))
      (error "MCP error: %s" rpc-error)
    (cdr (assoc 'result response))))

(defun chat-mcp--tool-id (server-id remote-name)
  "Return local tool id for SERVER-ID and REMOTE-NAME."
  (intern
   (concat
    "mcp_"
    (replace-regexp-in-string "[^[:alnum:]_]+" "_" server-id)
    "_"
    (replace-regexp-in-string "[^[:alnum:]_]+" "_" remote-name))))

(defun chat-mcp--schema-parameters (schema)
  "Convert MCP input SCHEMA into forged-tool parameters."
  (let* ((properties (or (cdr (assoc 'properties schema)) nil))
         (required (mapcar (lambda (item) (format "%s" item))
                           (or (cdr (assoc 'required schema)) nil))))
    (mapcar
     (lambda (property)
       (let* ((name (format "%s" (car property)))
              (definition (cdr property))
              (type (or (cdr (assoc 'type definition)) "string"))
              (enum (cdr (assoc 'enum definition))))
         (append
          (list :name name :type (format "%s" type)
                :required (not (null (member name required))))
          (when enum (list :enum (append enum nil))))))
     properties)))

(defun chat-mcp--arguments-from-argv (parameters argv)
  "Build MCP argument object from PARAMETERS and ARGV."
  (cl-loop for parameter in parameters
           for value in argv
           when (not (null value))
           collect (cons (plist-get parameter :name) value)))

(defun chat-mcp--remote-result-text (response)
  "Return stable text for remote tool RESPONSE."
  (let ((result (chat-mcp--response-result response)))
    (if (stringp result)
        result
      (json-encode result))))

(defun chat-mcp--register-remote-tool (client tool-definition)
  "Register TOOL-DEFINITION discovered from CLIENT."
  (let* ((server-id (chat-mcp-client-id client))
         (remote-name (format "%s"
                              (cdr (assoc 'name tool-definition))))
         (description (or (cdr (assoc 'description tool-definition))
                          "Remote MCP tool"))
         (schema (or (cdr (assoc 'inputSchema tool-definition))
                     '((type . "object") (properties))))
         (parameters (chat-mcp--schema-parameters schema))
         (annotations (cdr (assoc 'annotations tool-definition)))
         (destructive (eq (cdr (assoc 'destructiveHint annotations)) t))
         (read-only (eq (cdr (assoc 'readOnlyHint annotations)) t))
         (effects (cond (destructive '(destructive outbound))
                        (read-only '(read outbound))
                        (t '(write outbound))))
         (id (chat-mcp--tool-id server-id remote-name))
         (sync-fn
          (lambda (&rest argv)
            (chat-mcp--remote-result-text
             (chat-mcp-call-tool
              client remote-name
              (chat-mcp--arguments-from-argv parameters argv)))))
         (async-fn
          (lambda (argv success error-callback)
            (chat-mcp-call-tool-async
             client remote-name
             (chat-mcp--arguments-from-argv parameters argv)
             (lambda (response)
               (condition-case err
                   (funcall success
                            (chat-mcp--remote-result-text response))
                 (error
                  (funcall error-callback
                           (error-message-string err)))))
             error-callback))))
    (chat-tool-forge-register
     (make-chat-forged-tool
      :id id
      :name (format "MCP %s %s" server-id remote-name)
      :description description
      :language 'elisp
      :parameters parameters
      :owner (intern (format "mcp:%s" server-id))
      :sensitivity 'network
      :effects effects
      :compiled-function sync-fn
      :async-function async-fn
      :is-active t
      :usage-count 0))
    id))

(defun chat-mcp-register-discovered-tools (client response)
  "Register tools in list-tools RESPONSE for CLIENT."
  (let* ((result (chat-mcp--response-result response))
         (tools (or (cdr (assoc 'tools result)) nil))
         ids)
    (dolist (tool tools)
      (push (chat-mcp--register-remote-tool client tool) ids))
    (setf (chat-mcp-client-remote-tools client) (nreverse ids))
    (chat-mcp-client-remote-tools client)))

(defun chat-mcp-connect-server (server-id)
  "Connect configured SERVER-ID, initialize it, and register its tools."
  (let ((client (chat-mcp-client-get server-id)))
    (when (and (eq (chat-mcp-client-transport client) 'stdio)
               (not (and (chat-mcp-client-process client)
                         (process-live-p
                          (chat-mcp-client-process client)))))
      (chat-mcp-stdio-start client))
    (chat-mcp-initialize client)
    (let ((ids
           (chat-mcp-register-discovered-tools
            client (chat-mcp-list-tools client))))
      (setf (chat-mcp-client-status client) 'ready)
      `((serverId . ,server-id)
        (status . "ready")
        (tools . ,(mapcar #'symbol-name ids))))))

(defun chat-mcp-generic-call (server-id name arguments-json)
  "Call NAME on SERVER-ID with ARGUMENTS-JSON synchronously."
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'string))
    (chat-mcp--remote-result-text
     (chat-mcp-call-tool
      (chat-mcp-client-get server-id) name
      (json-read-from-string (or arguments-json "{}"))))))

(defun chat-mcp-generic-call-async (argv success error-callback)
  "Asynchronously invoke generic MCP call ARGV."
  (pcase-let ((`(,server-id ,name ,arguments-json) argv))
    (condition-case err
        (let ((json-object-type 'alist)
              (json-array-type 'list)
              (json-key-type 'string))
          (chat-mcp-call-tool-async
           (chat-mcp-client-get server-id) name
           (json-read-from-string (or arguments-json "{}"))
           (lambda (response)
             (condition-case inner
                 (funcall success
                          (chat-mcp--remote-result-text response))
               (error
                (funcall error-callback
                         (error-message-string inner)))))
           error-callback))
      (error
       (funcall error-callback (error-message-string err))))))

(defun chat-mcp--register-tool
    (id name description parameters fn effects &optional async-fn)
  "Register one MCP integration tool."
  (chat-tool-forge-register
   (make-chat-forged-tool
    :id id :name name :description description :language 'elisp
    :parameters parameters :owner 'mcp :sensitivity 'network
    :effects effects :compiled-function fn :async-function async-fn
    :is-active t :usage-count 0)))

(defun chat-mcp-register-tools ()
  "Register MCP lifecycle and generic call tools."
  (chat-mcp--register-tool
   'mcp_server_list "MCP Server List"
   "List MCP servers configured by the user."
   nil #'chat-mcp-server-list '(read))
  (chat-mcp--register-tool
   'mcp_connect "MCP Connect"
   "Connect one configured MCP server and discover schema-aware tools."
   '((:name "server_id" :type "string" :required t))
   #'chat-mcp-connect-server '(execute outbound))
  (chat-mcp--register-tool
   'mcp_call "MCP Call"
   "Call a tool on a connected MCP server using JSON arguments."
   '((:name "server_id" :type "string" :required t)
     (:name "name" :type "string" :required t)
     (:name "arguments_json" :type "string" :required t))
   #'chat-mcp-generic-call '(write outbound)
   #'chat-mcp-generic-call-async))

(provide 'chat-mcp)
;;; chat-mcp.el ends here
