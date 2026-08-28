;;; chat.el --- AI chat executor for Emacs -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: chat, ai, llm, tools
;; Version: 0.1.0
;; License: 1PL (One Public License)
;; License URL: https://license.pub/1pl/

;; This file is not part of GNU Emacs.

;; This project is licensed under the One Public License (1PL).
;; See the LICENSE file in the project root or visit
;; https://license.pub/1pl/ for the full license text.

;;; Commentary:

;; Chat.el is a pure Emacs AI executor and work platform.
;; It provides conversation management, tool forging, file operations,
;; and integration with various LLM providers.

;; Usage:
;;   M-x chat              Start or resume a chat session
;;   M-x chat-new-session  Create a new chat session
;;   M-x chat-list-sessions List all saved sessions

;;; Code:

(require 'cl-lib)
(require 'seq)

;; Prefer newer source files over stale byte-compiled artifacts.
(setq load-prefer-newer t)

;; Add runtime module directories to `load-path`.
(defconst chat-root-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Repository root directory for the current chat.el checkout.")

(let* ((chat-root chat-root-directory)
       (module-dirs '("lisp/core"
                      "lisp/llm"
                      "lisp/tools"
                      "lisp/ui"
                      "lisp/code"
                      "lisp/wiki"
                      "lisp/agent"
                      "lisp/plugin")))
  (dolist (dir module-dirs)
    (add-to-list 'load-path (expand-file-name dir chat-root))))

;; ------------------------------------------------------------------
;; Version
;; ------------------------------------------------------------------

(defconst chat-version "0.1.0"
  "Current version of chat.el.")

(defun chat-version ()
  "Return chat.el version string."
  chat-version)

;; ------------------------------------------------------------------
;; Configuration Loading
;; ------------------------------------------------------------------

(defun chat--config-file-candidates (&optional root-directory)
  "Return config file candidates for ROOT-DIRECTORY.
Later files override earlier ones."
  (list (expand-file-name "~/.chat.el")
        (expand-file-name "~/.chat/config.el")
        (expand-file-name "chat-config.local.el"
                          (or root-directory chat-root-directory))))

(defun chat-load-config-files (&optional root-directory)
  "Load chat config files for ROOT-DIRECTORY.
Returns the list of files that were loaded."
  (let (loaded-files)
    (dolist (file (chat--config-file-candidates root-directory))
      (when (file-exists-p file)
        (load file nil t)
        (push file loaded-files)))
    (nreverse loaded-files)))

;; ------------------------------------------------------------------
;; Dependencies Loading
;; ------------------------------------------------------------------

;; Load core modules.
(require 'chat-i18n)
(require 'chat-i18n-zh-cn)
(require 'chat-log)
(require 'chat-request-diagnostics)
(require 'chat-command)
(require 'chat-content)
(require 'chat-session)
(require 'chat-session-wire)
(require 'chat-event)
(require 'chat-trace)
(require 'chat-eval)
(require 'chat-execution)
(require 'chat-checkpoint)
(require 'chat-workspace)
(require 'chat-task)
(require 'chat-extension-trust)
(require 'chat-runtime-hook)
(require 'chat-session-index)
(chat-session-index-install)
(require 'chat-session-tree)
(require 'chat-transcript)
(require 'chat-align)
(require 'chat-markdown)
(require 'chat-mdp)
(require 'chat-memory)
(require 'chat-project)
(require 'chat-stream)
(require 'chat-context)
(require 'chat-context-budget)
(require 'chat-context-resident)
(require 'chat-session-log)
(require 'chat-scratch)
(require 'chat-knowledge)
(require 'chat-files)
(require 'chat-reading)
(require 'chat-approval-grants)
(require 'chat-approval)
(require 'chat-approval-guard)
(require 'chat-wiki)

;; Load LLM providers.
(require 'chat-llm)
(require 'chat-llm-kimi)
(require 'chat-llm-kimi-code)
(require 'chat-llm-openai)
(require 'chat-llm-compatible-providers)
(require 'chat-llm-claude)
(require 'chat-llm-gemini)
(require 'chat-llm-ark)
(require 'chat-model-runtime)

;; Load declarative agent extensions before built-in profiles.
(require 'chat-skill)
(require 'chat-agent-profile)

;; Load tool modules.
(require 'chat-command-gate)
(require 'chat-tool-forge)
(require 'chat-tool-forge-ai)
(require 'chat-tool-caller)
(require 'chat-tool-shell)
(require 'chat-work)
(require 'chat-mcp)
(require 'chat-subagent)
(require 'chat-capability-packs)

;; Load the agent kernel after transports and tooling.
(require 'chat-agent)
(require 'chat-agent-wire)
(chat-agent-wire-install)
(require 'chat-coding-eval)

;; Plugin host: Emacs-native tools and optional user plugins.
(require 'chat-plugin)
(require 'chat-plugin-emacs)

;; Load configuration before persisted tools or plugins are started, so
;; local policy can tighten capability exposure on first registration.
(chat-load-config-files chat-root-directory)

(chat-execution-initialize)
(chat-checkpoint-install)

(chat-tool-forge-load-all)
(chat-files-register-built-in-tools)
(chat-work-load-tasks)
(chat-work-register-tools)
(chat-mcp-configure-servers)
(chat-mcp-register-tools)
(chat-subagent-register-tools)
(chat-capability-register-tools)
(chat-session-log-register-tools)
(chat-knowledge-register-tools)
(chat-wiki-register-tools)
(chat-plugin-provide 'tools t)
(chat-plugin-load-user-files)
(chat-plugin-start-enabled)

;; Load UI after tooling has been registered.
(require 'chat-request-panel)
(require 'chat-mdp-view)
(require 'chat-task-view)
(require 'chat-observability-view)
(require 'chat-ui)

;; Load code capability (optional)
(when (locate-library "chat-code")
  (require 'chat-context-code)
  (require 'chat-edit)
  (require 'chat-code-preview)
  (require 'chat-code-intel)
  (require 'chat-code-intelligence)
  (require 'chat-repo-map)
  (require 'chat-code-lsp)
  (require 'chat-code-verify)
  (require 'chat-code-refactor)
  (require 'chat-code-test)
  (require 'chat-code-git)
  (require 'chat-code-perf)
  (require 'chat-code))

(require 'chat-eval-scenarios)

(chat-workspace-initialize)

;; ------------------------------------------------------------------
;; Customization
;; ------------------------------------------------------------------

(defgroup chat nil
  "AI chat executor for Emacs."
  :group 'applications
  :prefix "chat-")

(defcustom chat-default-model 'kimi
  "Default LLM model to use for new sessions."
  :type 'symbol
  :group 'chat)

(defcustom chat-auto-save t
  "Whether to automatically save sessions after each message."
  :type 'boolean
  :group 'chat)

(defcustom chat-commands-help
  "Talking to the Model:
  /send <message>       - Send and record it; the model may use tools and
                          take several steps. Same as typing with no prefix.
  /send                 - Send whatever /queue has collected
  /quick <question>     - Ask once, without recording it or using tools.
                          Also /? and the shorthand ?<question>
  /queue <note>         - Collect a note to go out with the next /flush
  /queue                - List what is queued
  /flush [note]         - Send the queue as one message
  /drop [all]           - Discard the last queued note, or all of them
  /cancel               - Cancel current AI request
  /help [topic]         - This help, or only the lines mentioning topic
  /model <name>         - Switch this session's model (C-c C-m, no name prompts)

/send and /quick are the two ways of asking, and the difference is what
is kept: /send is the conversation, written down and answered by a run
that can read files and work in steps. /quick is a question asked beside
the conversation -- nothing is recorded and no tools are used, which is
what makes it cheap and what makes it forgettable.

Sessions:
  /new                  - Create new session
  /list                 - List all sessions
  /save                 - Save current session
  /clear                - Discard this conversation, keeping the session
  M-x chat-session-tree-open - Browse saved sessions as a tree
  M-x chat-ui-checkpoint-list - Inspect recoverable session checkpoints
  M-x chat-ui-checkpoint-create - Create an explicit checkpoint
  M-x chat-ui-checkpoint-rollback-code - Restore runtime-owned files
  M-x chat-ui-checkpoint-rollback-conversation - Branch conversation history
  M-x chat-ui-checkpoint-rollback-both - Restore files, then branch history

Quick Shell (Hybrid Mode):
  !<cmd>                - Execute shell command directly
  /cmd <cmd>            - Same as !<cmd>. Also /!
  !!                    - Repeat the last shell command
  !cd <dir>             - Change working directory (bare cd goes home)
  /cd [dir]             - Change working directory (no dir prompts)
  /pwd                  - Show the working directory
  \\<text>               - Send text as is, even if it starts with ! or /

The working directory belongs to the session, so it is restored when the
session is reopened, and the AI tools run there too.
  M-x chat-ui-workspace-enable - Move this session into an owned worktree
  M-x chat-ui-workspace-status - Inspect and reconcile workspace ownership
  M-x chat-ui-workspace-release - Return to the source checkout

Fullwidth punctuation works wherever command syntax appears, so ！ ？ ／
and an ideographic space all reach the same commands.  A command argument
is never rewritten, so a shell body or question keeps its own
punctuation.

Keys:
  RET                   - Send
  S-RET                 - New line without sending
  C-g                   - Cancel the current request
  C-c C-n / C-c C-l     - New session / list sessions
  C-c C-m               - Switch model
  C-c C-e / C-c C-g     - Edit last message / regenerate last response
  C-c C-s / C-c C-p     - Request status / request panel
  C-c C-o / C-c C-y     - Attach a file / paste a clipboard image
  C-c C-x                - Remove a staged attachment
  C-c C-t               - Toggle auto-approval for this session
  C-c C-q / C-c C-SPC   - Quote active region / ask about it
  C-c C-d               - Show or fold all detail
  C-c C-u               - Show or hide the Markdown markers
  M-p / M-n             - Recall earlier / later input
  C-a                   - Go to the start of what you typed
  TAB                   - Complete: slash commands after /, paths otherwise
  C-c C-h               - This help

Auto (Default Command):
  Plain input runs through one command, and by default that command is
  /send. Work that comes in runs claims it: `!ls' makes /cmd the default
  so the next line is another shell command, and /queue does the same for
  notes. Anything that asks the model hands it back to /send, so a
  question always gets you out of shell mode.
  /auto            - Say what plain input currently runs through
  /auto cmd        - Send plain input to the shell
  /auto off        - Send plain input back to the model
  \\<text>          - One line straight to the model, whatever auto says
  While it is not /send, the input prompt says which command holds it and
  the status line says `auto: /cmd'. An explicit /command always means
  itself, and while a response is running plain input steers that run
  rather than the default command.

Approval (who decides whether a tool call runs):
  /approve            - Say which mode is in force, and where it was set
  /approve manual     - Granted calls run, everything else asks (default)
  /approve guarded    - A guard model decides and nothing asks; a denial
                        goes back to the assistant, which may take another
                        route. Accepts the old name `auto'.
  /approve dangerous  - Everything runs, command gate off; asks to confirm
  When asked, you can allow once, allow for this session, or allow from now
  on. The last two are remembered as grants: M-x chat-approval-list-grants
  shows all of them with their source, and
  M-x chat-approval-clear-runtime-grants drops the ones chat.el recorded
  while leaving your own configuration alone.

Language:
  Set `chat-language' for the interface, or leave it at `auto' to follow
  the Emacs language environment. Command names have translations: /auto
  and /自动 are the same command, and completion offers the names of the
  language in use. Names from any language are always accepted.
  `chat-reply-language' is what the model is told to answer in, and
  `chat-prompt-language' is the language of the instructions it is sent.
  Both follow `chat-language' unless set. Pin `chat-prompt-language' to
  `en' if a translated prompt starts behaving worse than the English one.

Reading a Reply:
  A run reasons, calls tools, reads results and only then answers, and
  all of it is kept.  Reasoning and tool work start folded behind a
  summary row; press RET or click it to open that group.  Prose the run
  produced on the way to its answer shows in italics, so it can be read
  without being mistaken for the answer.  C-c C-d opens or folds
  everything at once.

Coding Sessions:
  M-x chat-code-start        - Start a session with project context
  M-x chat-code-from-chat    - Give this session code capability
  C-c C-a / C-c C-k          - Accept / reject a proposed edit
  C-c C-v                    - View the proposed edit as a diff
  C-c C-f                    - Focus a file
  C-c C-r                    - Rebuild project context

Code capability is a property of the session, not a separate buffer: it
adds project context, coding rules and edit proposals to the same chat.
The edit and context keys do nothing in a session without it.

Working Notes:
  - Quote commands fill the input area so you can refine the question;
    ask commands send immediately.
  - The request panel shows execution detail without filling the
    transcript with it.
  - Preview an edit in *chat-preview* before accepting it.
  - A file write approval can also allow one directory subtree.
  - Typing a path-like token in the input area completes file names.
  - For long documents, work section by section rather than asking for
    one giant response; use targeted edits on existing files and whole
    writes only for new ones.

Reading Workflow:
  M-x chat-quote-region       - Quote active region into chat
  M-x chat-quote-defun        - Quote defun at point into chat
  M-x chat-quote-near-point   - Quote nearby context into chat
  M-x chat-quote-current-file - Quote current file into chat
  M-x chat-ask-region         - Ask about active region
  M-x chat-ask-defun          - Ask about defun at point
  M-x chat-ask-near-point     - Ask about nearby context
  M-x chat-ask-current-file   - Ask about current file

Wiki (/wiki <subcommand>):
  /wiki index             - Open the generated index
  /wiki log               - Open the operation log
  /wiki lint              - Report orphans, broken links, empty pages
  /wiki search <text>     - List pages matching text
  /wiki find              - Pick a page to open
  /wiki new <type> <name> - Create a page
  /wiki ingest <file>     - Add a document and have it summarized
  /wiki ask <question>    - Answer using the wiki

In the chat buffer, type a message and press RET to send it."
  "Help text displayed for chat commands.

This is the English text and the reference every translation is checked
against.  `chat-help-text' is what the surface actually shows; it returns
the catalog entry for the current language and falls back to this."
  :type 'string
  :group 'chat)

(defun chat-help-text ()
  "Return the help text in the language the user reads.

Someone who cannot tell what the surface does will not go reading the
source to find out, so this is the one string worth translating before
any other."
  (chat-i18n 'help-text chat-commands-help))

;; ------------------------------------------------------------------
;; Main Entry Points
;; ------------------------------------------------------------------

;;;###autoload
(defun chat ()
  "Start or resume a chat session.

If there are existing sessions, prompts to select one.
Otherwise, creates a new session."
  (interactive)
  (let ((sessions (chat-session-list)))
    (if sessions
        (chat--select-or-create-session sessions)
      (chat-new-session))))

;;;###autoload
(defun chat-new-session (&optional name model)
  "Create a new chat session.

NAME is an optional session name, prompts if not provided.
MODEL is an optional model identifier, uses chat-default-model if not provided."
  (interactive)
  (let* ((session-name (or name
                           (read-string "Session name: "
                                        (format "Chat %s"
                                                (format-time-string "%Y-%m-%d %H:%M")))))
         (model-id (or model chat-default-model))
         (session (chat-session-create session-name model-id)))
    (chat--open-session session)))

;;;###autoload
(defun chat-list-sessions ()
  "Display a list of all saved sessions."
  (interactive)
  (let ((sessions (chat-session-list)))
    (with-current-buffer (get-buffer-create "*Chat Sessions*")
      (erase-buffer)
      (insert "Chat Sessions\n")
      (insert "============\n\n")
      (if sessions
          (dolist (session sessions)
            (insert (format "• %s\n" (chat-session-name session)))
            (insert (format "  ID: %s\n" (chat-session-id session)))
            (insert (format "  Model: %s\n" (chat-session-model-id session)))
            (insert (format "  Updated: %s\n\n"
                           (format-time-string "%Y-%m-%d %H:%M"
                                              (chat-session-updated-at session))))))
        (insert "No sessions found.\n")
        (insert "Create one with M-x chat-new-session\n"))
      (goto-char (point-min))
      (pop-to-buffer (current-buffer))))

;; ------------------------------------------------------------------
;; Internal Functions
;; ------------------------------------------------------------------

(defun chat--select-or-create-session (sessions)
  "Prompt user to select from SESSIONS or create new."
  (let* ((names (mapcar #'chat-session-name sessions))
         (choice (completing-read "Select session (or type new name): "
                                  names
                                  nil
                                  nil)))
    (if (member choice names)
        (let ((session (cl-find choice sessions
                               :key #'chat-session-name
                               :test #'string=)))
          (chat--open-session session))
      (chat-new-session choice))))

(defun chat--open-session (session)
  "Open SESSION in a chat buffer.

SESSION is a chat-session struct.  There is one surface: code capability
changes what the session carries into a request and which commands apply,
not how the conversation is drawn.  Two surfaces meant two of everything
underneath, and the two copies drifted -- a code session never read the
project's own instructions, a plain one reformatted code blocks
incorrectly mid-stream -- so each fix only ever landed on one side."
  (chat--open-chat-session session))

(defvar-local chat--session-event-open nil
  "Session id whose open lifecycle event belongs to this buffer.")

(defun chat--record-session-ended ()
  "Record that this buffer no longer presents its current session."
  (when (and chat--session-event-open chat--current-session)
    (chat-event-emit
     'session-ended
     :session-id chat--session-event-open
     :source 'ui
     :subject chat--current-session
     :payload
     (list (cons 'reason "buffer-closed")
           (cons 'name (chat-session-name chat--current-session))))
    (setq chat--session-event-open nil)))

(defun chat--record-session-started (session)
  "Record that this buffer now presents SESSION."
  (setq chat--session-event-open (chat-session-id session))
  (chat-event-emit
   'session-started
   :session-id chat--session-event-open
   :source 'ui
   :subject session
   :payload
   (delq nil
         (list (cons 'reason "buffer-opened")
               (cons 'name (chat-session-name session))
               (when-let* ((model (chat-session-model-id session)))
                 (cons 'model (format "%s" model))))))
  (add-hook 'kill-buffer-hook #'chat--record-session-ended nil t)
  (add-hook 'change-major-mode-hook #'chat--record-session-ended nil t))

(defun chat-prepare-session-buffer (session)
  "Apply the session-level setup every chat surface needs to SESSION.

Called from both surfaces so neither can drift out of the other's
behaviour.  Everything here is a property of the session rather than of
how it is drawn, which is why it does not belong in either display."
  (setq-local chat--current-session session)
  (chat--record-session-started session)
  ;; Without this the buffer would inherit the directory of whatever
  ;; buffer happened to be current, discarding the directory this
  ;; session was pointed at.
  (when-let ((directory (chat-session-working-directory session)))
    (setq-local default-directory directory))
  ;; Scratch space is created here rather than on first write so that
  ;; the path named in the system prompt exists by the time the model
  ;; is told about it.  Pruning rides along because this is the moment
  ;; nothing is mid-write, and it spares the session being opened.
  (chat-scratch-session-directory session t)
  (chat-scratch-prune (chat-session-id session))
  (setq chat--last-session-id (chat-session-id session)))

(defun chat--open-chat-session (session)
  "Open SESSION on the plain chat surface."
  (let* ((buffer-name (chat--buffer-name session))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (chat-mode)
      (chat-prepare-session-buffer session)
      (chat-ui-setup-buffer session))
    (pop-to-buffer buffer)))

(defun chat--buffer-name (session)
  "Return the chat buffer name for SESSION."
  (format "*chat:%s*" (chat-session-name session)))

;; ------------------------------------------------------------------
;; Chat Mode
;; ------------------------------------------------------------------

(defvar chat--current-session nil
  "Current session in this chat buffer.")

(defvar chat--last-session-id nil
  "Most recently opened chat session id.")

(defun chat-show-help ()
  "Display the chat help buffer.

The help ends with a line about the chat buffer, and this is not the chat
buffer: RET here scrolls, because `view-mode' owns it.  So the footer
says what the keys do where the reader actually is.  Advice that is true
somewhere else is the same as advice that is wrong."
  (interactive)
  (with-current-buffer (get-buffer-create "*Chat Help*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (chat-help-text))
      (insert "\n\n")
      (insert (chat-i18n
               'help-buffer-footer
               "This is the help buffer: SPC and DEL scroll it, q closes it."))
      (insert "\n")
      (goto-char (point-min))
      (view-mode 1))
    (pop-to-buffer (current-buffer))))

(defvar chat-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Composing and sending.
    (define-key map (kbd "RET") 'chat-ui-send-message)
    ;; `<S-return>' is the GUI key; `S-RET' is what a terminal sends, and
    ;; they are genuinely different events.  Binding only the first left
    ;; terminal users with no way to type a second line.  `C-j' is there
    ;; because many terminals cannot send either one.
    (define-key map (kbd "<S-return>") 'chat-ui-insert-newline)
    (define-key map (kbd "S-RET") 'chat-ui-insert-newline)
    (define-key map (kbd "C-j") 'chat-ui-insert-newline)
    (define-key map (kbd "C-g") 'chat-ui-cancel-response)
    ;; Completion is the point of the command and path tables; without a
    ;; key it was reachable only through `M-x'.
    (define-key map (kbd "TAB") 'completion-at-point)
    ;; Sessions.
    (define-key map (kbd "C-c C-n") 'chat-new-session)
    (define-key map (kbd "C-c C-l") 'chat-list-sessions)
    (define-key map (kbd "C-c C-m") 'chat-set-model)
    (define-key map (kbd "C-c C-h") 'chat-show-help)
    ;; Revising the conversation.
    (define-key map (kbd "C-c C-e") 'chat-ui-edit-last-user-message)
    (define-key map (kbd "C-c C-g") 'chat-ui-regenerate-last-response)
    ;; Watching a run.
    (define-key map (kbd "C-c C-s") 'chat-show-current-request-status)
    (define-key map (kbd "C-c C-p") 'chat-ui-toggle-request-panel)
    ;; Typed attachments stay beside the draft until a recorded send owns
    ;; them.  Preview remains an M-x command because it prompts for any
    ;; staged or recorded attachment rather than acting on point.
    (define-key map (kbd "C-c C-o") 'chat-ui-attach-file)
    (define-key map (kbd "C-c C-y") 'chat-ui-paste-image)
    (define-key map (kbd "C-c C-x") 'chat-ui-remove-attachment)
    ;; Approval.  Auto-approve moves off C-c C-a, which the code surface
    ;; used for accepting an edit; on one keymap only one of them could
    ;; keep it, and accepting an edit is the riskier thing to fire by
    ;; muscle memory from the other surface.
    (define-key map (kbd "C-c C-t") 'chat-toggle-auto-approve-session)
    ;; Proposed edits.  Inert in a session without code capability.
    (define-key map (kbd "C-c C-a") 'chat-code-accept-last-edit)
    (define-key map (kbd "C-c C-k") 'chat-code-reject-last-edit)
    (define-key map (kbd "C-c C-v") 'chat-code-view-preview)
    ;; Project context.
    (define-key map (kbd "C-c C-f") 'chat-code-focus-file)
    (define-key map (kbd "C-c C-r") 'chat-code-refresh-context)
    ;; Quoting the buffer you came from.
    (define-key map (kbd "C-c C-q") 'chat-quote-region)
    (define-key map (kbd "C-c C-SPC") 'chat-ask-region)
    ;; Detail.  A fold row carries its own RET and TAB, so these are for
    ;; reaching the detail without first finding a row to stand on.
    (define-key map (kbd "C-c C-d") 'chat-ui-toggle-all-folds)
    ;; The Markdown source, for when the source is what you want to read.
    ;; Hiding a marker never removed it, so this is one line of display
    ;; state and nothing is redrawn.
    (define-key map (kbd "C-c C-u") 'chat-markdown-toggle-markers)
    ;; Input recall, where every shell and REPL in Emacs puts it.
    (define-key map (kbd "M-p") 'chat-ui-previous-input)
    (define-key map (kbd "M-n") 'chat-ui-next-input)
    ;; The prompt is buffer text, so the line begins before it.  Land on
    ;; what you typed instead.
    (define-key map (kbd "C-a") 'chat-ui-beginning-of-input)
    (define-key map (kbd "<home>") 'chat-ui-beginning-of-input)
    map)
  "Keymap for chat mode buffers.

One table for every chat buffer.  Commands that need code capability are
bound unconditionally and refuse politely without it, so a key does not
appear and disappear depending on which session is in front of you.")

(defun chat--reading-session-name (&optional file)
  "Return a default session name for reading workflow commands."
  (let* ((path (or file default-directory))
         (normalized (directory-file-name path))
         (name (file-name-nondirectory normalized)))
    (when (string-empty-p name)
      (setq name normalized))
    (format "Read: %s" name)))

(defun chat--resolve-last-session ()
  "Return the most recently opened chat session when it still exists."
  (when (and chat--last-session-id
             (chat-session-exists-p chat--last-session-id))
    (chat-session-load chat--last-session-id)))

(defun chat--ensure-reading-session (&optional file)
  "Return a chat session suitable for reading workflow commands."
  (or (and (derived-mode-p 'chat-mode)
           chat--current-session)
      (chat--resolve-last-session)
      (chat-session-create (chat--reading-session-name file) chat-default-model)))

(defun chat--quote-capture (capture)
  "Insert CAPTURE into a chat session input area."
  (let ((session (chat--ensure-reading-session (plist-get capture :file)))
        (prompt (chat-reading-format-question capture)))
    (chat--open-session session)
    (with-current-buffer (chat--buffer-name session)
      (delete-region (marker-position chat-ui--input-overlay) (point-max))
      (goto-char (marker-position chat-ui--input-overlay))
      (insert prompt))))

(defun chat--ask-capture (capture question)
  "Send QUESTION about CAPTURE in a chat session."
  (let ((session (chat--ensure-reading-session (plist-get capture :file)))
        (prompt (chat-reading-format-question capture question)))
    (chat--open-session session)
    (with-current-buffer (chat--buffer-name session)
      (delete-region (marker-position chat-ui--input-overlay) (point-max))
      (goto-char (marker-position chat-ui--input-overlay))
      (insert prompt)
      (chat-ui-send-message))))

(defun chat-quote-region ()
  "Quote the active region into a chat session."
  (interactive)
  (chat--quote-capture (chat-reading-capture-region)))

(defun chat-ask-region (question)
  "Ask QUESTION about the active region in a chat session."
  (interactive "sQuestion: ")
  (chat--ask-capture (chat-reading-capture-region) question))

(defun chat-quote-defun ()
  "Quote the defun at point into a chat session."
  (interactive)
  (chat--quote-capture (chat-reading-capture-defun)))

(defun chat-ask-defun (question)
  "Ask QUESTION about the defun at point in a chat session."
  (interactive "sQuestion: ")
  (chat--ask-capture (chat-reading-capture-defun) question))

(defun chat-quote-near-point ()
  "Quote nearby context around point into a chat session."
  (interactive)
  (chat--quote-capture (chat-reading-capture-near-point)))

(defun chat-ask-near-point (question)
  "Ask QUESTION about nearby context around point in a chat session."
  (interactive "sQuestion: ")
  (chat--ask-capture (chat-reading-capture-near-point) question))

(defun chat-quote-current-file ()
  "Quote the current file into a chat session."
  (interactive)
  (chat--quote-capture (chat-reading-capture-current-file)))

(defun chat-ask-current-file (question)
  "Ask QUESTION about the current file in a chat session."
  (interactive "sQuestion: ")
  (chat--ask-capture (chat-reading-capture-current-file) question))

(define-derived-mode chat-mode fundamental-mode "Chat"
  "Major mode for chat sessions.

The only chat surface.  Whether a session carries project context,
coding rules and edit proposals is a property of the session, visible in
the header and in which commands do anything."
  :group 'chat
  (setq buffer-read-only nil)
  (setq truncate-lines nil)
  ;; A live reply inserts above the input point.  Once that point leaves
  ;; the window, Emacs normally recenters it; the resulting jump makes a
  ;; stationary prompt appear halfway up the frame.  Values above 100
  ;; keep the point visible by the smallest possible scroll instead.
  (setq-local scroll-conservatively 101)
  ;; Wrapping at word boundaries, and Markdown markers hidden.  Not
  ;; `visual-line-mode', which would rebind C-a away from
  ;; `chat-ui-beginning-of-input'.
  (chat-markdown-setup-buffer)
  (setq-local completion-at-point-functions
              '(chat-ui--command-completion-at-point
                chat-ui--path-completion-at-point))
  (add-hook 'post-self-insert-hook
            #'chat-ui--maybe-complete-path-after-insert
            nil t)
  ;; The prompt is read-only text, so re-running the mode over a buffer
  ;; that already has one has to be allowed to clear it.
  (let ((inhibit-read-only t))
    (erase-buffer)))

(defun chat--refresh-buffer ()
  "Refresh current chat buffer with session content."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (when chat--current-session
      (insert (format "Session: %s\n" (chat-session-name chat--current-session)))
      (insert (format "Model: %s\n\n" (chat-session-model-id chat--current-session)))
      (dolist (msg (chat-session-messages chat--current-session))
        (insert (format "%s: %s\n\n"
                       (upcase (symbol-name (chat-message-role msg)))
                       (chat-message-content msg))))
      (insert "\n> "))))

;; ------------------------------------------------------------------
;; Auto-Approval Commands
;; ------------------------------------------------------------------

(defun chat-set-approval-mode (mode)
  "Set the approval MODE for the current session."
  (interactive
   (list (intern (completing-read
                  "Approval mode: "
                  (mapcar #'symbol-name chat-approval-modes)
                  nil t))))
  (let ((session (and (boundp 'chat--current-session) chat--current-session)))
    (chat-approval-set-mode mode session)
    (message "%s" (chat-approval-mode-report session))))

(defun chat-toggle-auto-approve-global ()
  "Switch the global approval mode between `guarded' and `manual'.

Sets the mode rather than a separate flag.  Two settings that both mean
\"stop asking\" can disagree, and then neither the status line nor the
user can say which one is in force."
  (interactive)
  (chat-approval-set-mode
   (if (eq (chat-approval-normalize-mode chat-approval-mode) 'guarded)
       'manual
     'guarded))
  (message "%s" (chat-approval-mode-report nil)))

(defun chat-toggle-auto-approve-session ()
  "Switch this session's approval mode between `guarded' and `manual'."
  (interactive)
  (if (and (boundp 'chat--current-session) chat--current-session)
      (let* ((session chat--current-session)
             (mode (if (eq (chat-approval-effective-mode session) 'guarded)
                       'manual
                     'guarded)))
        (chat-approval-set-mode mode session)
        (message "Session '%s': %s"
                 (chat-session-name session)
                 (chat-approval-mode-report session)))
    (message "No active session")))

(defun chat-add-to-shell-whitelist (pattern)
  "Add PATTERN to shell command whitelist."
  (interactive "sCommand pattern to whitelist (e.g., 'ls ' or 'git status'): ")
  (require 'chat-tool-shell)
  (chat-tool-shell-whitelist-add pattern))

(defun chat-remove-from-shell-whitelist (pattern)
  "Remove PATTERN from shell command whitelist."
  (interactive)
  (require 'chat-tool-shell)
  (if (and (boundp 'chat-tool-shell-whitelist) chat-tool-shell-whitelist)
      (chat-tool-shell-whitelist-remove
       (completing-read "Remove pattern: " chat-tool-shell-whitelist nil t))
    (message "Shell whitelist is empty")))

(defun chat-show-shell-whitelist ()
  "Display current shell command whitelist."
  (interactive)
  (require 'chat-tool-shell)
  (if (and (boundp 'chat-tool-shell-whitelist) chat-tool-shell-whitelist)
      (message "Shell whitelist: %s"
               (mapconcat #'identity chat-tool-shell-whitelist ", "))
    (message "Shell whitelist is empty")))

;; ------------------------------------------------------------------
;; Provide
;; ------------------------------------------------------------------

(provide 'chat)
;;; chat.el ends here
