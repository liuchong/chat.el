;;; fake-mcp-server.el --- Tiny JSONL MCP fixture -*- lexical-binding: t -*-

;; This fixture is intentionally small and deterministic.  It reads
;; JSON-RPC requests from stdin and writes one JSON response per line.

(require 'json)
(require 'subr-x)

(defun chat-test-fake-mcp--read-line ()
  "Read one line from stdin in batch mode."
  (condition-case nil
      (read-string "")
    (end-of-file nil)))

(defun chat-test-fake-mcp--response (request)
  "Return a fake MCP response for REQUEST."
  (let ((id (cdr (assoc 'id request)))
        (method (cdr (assoc 'method request))))
    `((jsonrpc . "2.0")
      (id . ,id)
      (result . ,(pcase method
                   ("initialize" '((protocolVersion . "2024-11-05")))
                   ("tools/list" '((tools . [])))
                   ("tools/call" '((content . [((type . "text")
                                                (text . "ok"))])))
                   (_ '((ok . t))))))))

(let ((json-object-type 'alist)
      (json-array-type 'list)
      line)
  (while (setq line (chat-test-fake-mcp--read-line))
    (unless (string-empty-p line)
      (princ (json-encode
              (chat-test-fake-mcp--response
               (json-read-from-string line))))
      (princ "\n"))))

;;; fake-mcp-server.el ends here
