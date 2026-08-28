;;; probe-execution-isolation.el --- Foreground M15 capability probe -*- lexical-binding: t -*-

(require 'json)
(require 'chat-execution)
(require 'chat-execution-darwin)

(let ((facts (chat-execution-darwin-probe)))
  (princ
   (json-encode
    `((platform . ,(symbol-name system-type))
      (filesystem . ,(symbol-name
                       (chat-execution-capabilities-filesystem facts)))
      (network . ,(symbol-name
                    (chat-execution-capabilities-network facts)))
      (environment . ,(symbol-name
                        (chat-execution-capabilities-environment facts)))
      (timeout . ,(and (chat-execution-capabilities-timeout facts) t))
      (processTreeCleanup .
                          ,(and (chat-execution-capabilities-process-tree-cleanup
                                 facts)
                                t))
      (availability . ,(chat-execution-capabilities-availability facts)))))
  (terpri))

;;; probe-execution-isolation.el ends here
