;;; chat-tool-shell.el --- Shell command execution tool for chat.el -*- lexical-binding: t -*-

;;; Commentary:
;; This tool allows the AI to execute shell commands and get results.
;; Use with caution - only enable in trusted environments.

;;; Code:

(require 'chat-tool-forge)

(defcustom chat-tool-shell-enabled nil
  "Enable shell command execution tool.
WARNING: Only enable in trusted environments."
  :type 'boolean
  :group 'chat)

(defcustom chat-tool-shell-allowed-commands
  '("ls" "cat" "pwd" "echo" "head" "tail" "grep" "find" "wc" "which" "type"
    "du" "stat" "sort" "uniq" "cut" "sed" "awk" "tr")
  "List of allowed shell commands for safety."
  :type '(repeat string)
  :group 'chat)

(defcustom chat-tool-shell-whitelist '()
  "List of command patterns that can execute without approval.
Each pattern is matched against the command string:
- If pattern ends with space, matches any command starting with that pattern
- Otherwise, requires exact match
Examples:
  \"ls \" matches \"ls\", \"ls -l\", \"ls /path\"
  \"ls\" matches only \"ls\" exactly
  \"git status\" matches only \"git status\" exactly
  \"git \" matches \"git status\", \"git log\", etc."
  :type '(repeat string)
  :group 'chat)

(defconst chat-tool-shell--unsafe-pattern
  "[;&|><`$\n\r]"
  "Pattern for shell metacharacters that are not allowed.")

(defun chat-tool-shell--split-command (command)
  "Parse COMMAND into an argv list."
  (split-string-and-unquote command))

(defun chat-tool-shell-whitelist-match-p (command)
  "Return non-nil if COMMAND matches any pattern in whitelist.
Matching rules:
- If whitelist pattern ends with space, matches any command with that prefix
- Otherwise, requires exact match
- \"ls \" matches \"ls\", \"ls -l\", but not \"lsxxx\""
  (catch 'matched
    (dolist (pattern chat-tool-shell-whitelist)
      (when (and (> (length pattern) 0)
                 (if (= (aref pattern (1- (length pattern))) ? )
                     ;; Pattern ends with space: prefix match
                     (and (>= (length command) (1- (length pattern)))
                          (string-equal (substring command 0 (1- (length pattern)))
                                        (substring pattern 0 (1- (length pattern))))
                          ;; Ensure word boundary: either exact match or next char is space/special
                          (or (= (length command) (1- (length pattern)))
                              (= (aref command (1- (length pattern))) ? )))
                   ;; No trailing space: exact match only
                   (string-equal command pattern)))
        (throw 'matched t)))
    nil))

(defun chat-tool-shell-whitelist-add (pattern)
  "Add PATTERN to the shell command whitelist."
  (interactive "sCommand pattern to whitelist (e.g., 'ls ' or 'git status'): ")
  (unless (member pattern chat-tool-shell-whitelist)
    (push pattern chat-tool-shell-whitelist)
    (message "Added '%s' to shell whitelist" pattern)))

(defun chat-tool-shell-whitelist-remove (pattern)
  "Remove PATTERN from the shell command whitelist."
  (interactive
   (list (completing-read "Remove pattern: " chat-tool-shell-whitelist nil t)))
  (setq chat-tool-shell-whitelist (delete pattern chat-tool-shell-whitelist))
  (message "Removed '%s' from shell whitelist" pattern))

(defun chat-tool-shell-validate (command)
  "Check if COMMAND is in the allowed list."
  (let ((argv (chat-tool-shell--split-command command)))
    (and argv
         (not (string-match-p chat-tool-shell--unsafe-pattern command))
         (member (car argv) chat-tool-shell-allowed-commands))))

(defun chat-tool-shell-execute (command)
  "Execute shell COMMAND and return output."
  (if (not chat-tool-shell-enabled)
      "Error: Shell tool is disabled"
    (if (not (chat-tool-shell-validate command))
        (format "Error: Command not allowed: %s" command)
      (condition-case err
          (let ((argv (chat-tool-shell--split-command command)))
            (with-output-to-string
              (with-current-buffer standard-output
                (apply #'process-file (car argv) nil t nil (cdr argv)))))
        (error (format "Error executing command: %s" (error-message-string err)))))))

;; Register the tool
(chat-tool-forge-register
 (make-chat-forged-tool
  :id 'shell_execute
  :name "Shell Execute"
  :description "Execute a shell command and return the output. Available commands: ls, cat, pwd, echo, head, tail, grep, find, wc, which, type, du, stat, sort, uniq, cut, sed, awk, tr"
  :language 'elisp
  :parameters '((:name "command" :type "string" :required t))
  :compiled-function #'chat-tool-shell-execute
  :is-active t
  :usage-count 0
  :version "1.0.0"))

(provide 'chat-tool-shell)
;;; chat-tool-shell.el ends here
