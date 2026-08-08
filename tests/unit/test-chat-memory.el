;;; test-chat-memory.el --- Tests for chat-memory -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-memory)
(require 'chat-tool-caller)

(ert-deftest chat-memory-snippet-nil-when-missing ()
  "Test no memory section is produced without a memory file."
  (let ((chat-memory-file (expand-file-name "no-such-memory.md" "/tmp")))
    (should-not (chat-memory-snippet))))

(ert-deftest chat-memory-snippet-reads-and-injects-content ()
  "Test memory content appears in the system prompt."
  (chat-test-with-temp-dir
   (let ((chat-memory-file (expand-file-name "memory.md" temp-dir)))
     (with-temp-file chat-memory-file
       (insert "User prefers concise answers."))
     (let ((snippet (chat-memory-snippet)))
       (should (string-match-p "concise answers" snippet)))
     (let ((prompt (chat-tool-caller-build-system-prompt "Base.")))
       (should (string-match-p "Long term memory" prompt))
       (should (string-match-p "concise answers" prompt))))))

(ert-deftest chat-memory-snippet-truncates-oversized-memory ()
  "Test oversized memory files are truncated with a marker."
  (chat-test-with-temp-dir
   (let ((chat-memory-file (expand-file-name "memory.md" temp-dir))
         (chat-memory-max-chars 20))
     (with-temp-file chat-memory-file
       (insert (make-string 100 ?m)))
     (let ((snippet (chat-memory-snippet)))
       (should (string-match-p "memory truncated" snippet))))))

(ert-deftest chat-memory-empty-file-produces-no-snippet ()
  "Test an empty or blank memory file is ignored."
  (chat-test-with-temp-dir
   (let ((chat-memory-file (expand-file-name "memory.md" temp-dir)))
     (with-temp-file chat-memory-file
       (insert "  \n  "))
     (should-not (chat-memory-snippet)))))

(provide 'test-chat-memory)
;;; test-chat-memory.el ends here
