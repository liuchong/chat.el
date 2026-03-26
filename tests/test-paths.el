;;; test-paths.el --- Shared load-path setup for tests -*- lexical-binding: t -*-
;;; Code:
(defconst chat-test-root-dir
  (expand-file-name ".." (file-name-directory load-file-name))
  "Project root for test helpers and scripts.")
(add-to-list 'load-path chat-test-root-dir)
(dolist (dir '("lisp/core"
               "lisp/llm"
               "lisp/tools"
               "lisp/ui"
               "lisp/code"))
  (add-to-list 'load-path (expand-file-name dir chat-test-root-dir)))
(provide 'test-paths)
;;; test-paths.el ends here
