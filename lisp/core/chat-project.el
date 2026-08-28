;;; chat-project.el --- Project instruction discovery -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, project, agents.md

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Project instruction discovery following the pi resource-loader
;; design: an optional global file first, then AGENTS.md files from
;; the filesystem root down to the start directory, root-most first.
;; Content is merged with source annotations and capped in size.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'chat-context-resident)
(require 'chat-work-context)

(defcustom chat-project-agents-file-names '("AGENTS.md" "AGENTS.MD" "agents.md")
  "File names considered project instruction files, in priority order."
  :type '(repeat string)
  :group 'chat)

(defcustom chat-project-global-agents-file (expand-file-name "AGENTS.md" "~/.chat/")
  "Optional global project instructions file included before local ones."
  :type 'file
  :group 'chat)

(defcustom chat-project-instructions-max-chars 32768
  "Maximum characters of merged project instructions."
  :type 'integer
  :group 'chat)

(defcustom chat-project-instruction-max-depth 8
  "Maximum explicit instruction dependency depth."
  :type 'integer :group 'chat)

(defcustom chat-project-instruction-max-files 64
  "Maximum instruction graph source files."
  :type 'integer :group 'chat)

(defcustom chat-project-instruction-max-bytes (* 256 1024)
  "Maximum source bytes read for one instruction graph."
  :type 'integer :group 'chat)

(defun chat-project--agents-file-in (directory)
  "Return the first existing project instruction file in DIRECTORY, or nil."
  (seq-find (lambda (path) (file-exists-p path))
            (mapcar (lambda (name) (expand-file-name name directory))
                    chat-project-agents-file-names)))

(defun chat-project-collect-agents-files (start-directory)
  "Collect project instruction files above START-DIRECTORY.
Walks from START-DIRECTORY up to the filesystem root and returns
paths root-most first, without duplicates."
  (let ((dir (file-truename start-directory))
        (files nil))
    (while dir
      (when-let ((found (chat-project--agents-file-in dir)))
        (unless (member found files)
          (push found files)))
      (let ((parent (file-name-directory (directory-file-name dir))))
        (setq dir (and parent
                       (not (equal parent dir))
                       parent))))
    files))

(defun chat-project--instruction-files (start-directory)
  "Return the instruction files that apply to START-DIRECTORY."
  (delete-dups
   (append
    (when (file-exists-p chat-project-global-agents-file)
      (list chat-project-global-agents-file))
    (chat-project-collect-agents-files start-directory))))

(defun chat-project--merge-files (files)
  "Return FILES read and joined with a source annotation each, or nil."
  (when files
    (string-join
     (mapcar
      (lambda (file)
        (format ";; Project instructions from %s:\n%s"
                file
                (string-trim-right
                 (with-temp-buffer
                   (insert-file-contents file)
                   (buffer-string)))))
      files)
     "\n\n")))

(defun chat-project--merged-text (start-directory)
  "Return the merged instruction files for START-DIRECTORY, or nil."
  (chat-project--merge-files
   (chat-project--instruction-files start-directory)))

;; ------------------------------------------------------------------
;; Caching
;; ------------------------------------------------------------------
;;
;; Instructions are asked for once per request, and every request used to
;; read every applicable AGENTS.md off disk and run the resident-span
;; partition over the result.  On this machine that is two files totalling
;; some 20KB to 30KB, which measured at a handful of milliseconds -- small
;; on its own, but repeated work either way, and the garbage it produces is
;; the kind that buys a collection pause somewhere in the send path.
;;
;; The walk that finds the files is not cached, only their contents: it is
;; under a millisecond, and skipping it would miss an AGENTS.md newly added
;; in an intermediate directory.  So a hit still notices a new file, a
;; removed one, and a changed one, and only saves the reading and the
;; parsing.

(defvar chat-project--cache (make-hash-table :test 'equal)
  "Cache of parsed instructions, keyed by start directory.

Each value is a list of (STAMPS . RESULT), where STAMPS identifies the
files that were read and their modification times.")

(defvar chat-project--graph-cache (make-hash-table :test 'equal)
  "Instruction graphs keyed by canonical target directory.")

(defun chat-project--graph-config-identity ()
  "Return configuration fields that change instruction graph semantics."
  (list chat-project-agents-file-names chat-project-global-agents-file
        chat-project-instruction-max-depth chat-project-instruction-max-files
        chat-project-instruction-max-bytes))

(defun chat-project--stamps (files)
  "Return an identity for FILES that changes when any of them does."
  (mapcar (lambda (file)
            (cons file
                  (file-attribute-modification-time
                   (file-attributes file))))
          files))

(defun chat-project-cache-clear ()
  "Forget cached project instructions.

Rarely needed: a changed, added or removed file is noticed on its own.
This exists for a file whose modification time does not move, which a
coarse filesystem clock can produce for two writes in the same second."
  (interactive)
  (clrhash chat-project--cache)
  (clrhash chat-project--graph-cache))

(defun chat-project--stamps-current-p (stamps)
  "Return non-nil when every path in STAMPS still has the recorded time."
  (and stamps
       (seq-every-p
        (lambda (entry)
          (and (file-exists-p (car entry))
               (equal (cdr entry)
                      (file-attribute-modification-time
                       (file-attributes (car entry))))))
        stamps)))

(defun chat-project--root (directory files)
  "Return the trusted project root for DIRECTORY and primary FILES."
  (file-name-as-directory
   (file-truename
    (or (locate-dominating-file directory ".git")
        (when-let* ((local
                     (seq-find
                      (lambda (file)
                        (not (equal file chat-project-global-agents-file)))
                      files)))
          (file-name-directory local))
        directory))))

(defun chat-project--directive-includes (content)
  "Return explicit dependency paths and diagnostics parsed from CONTENT."
  (let ((start 0) includes diagnostics)
    (while (string-match
            "<!-- chat-agents:[[:space:]]*\\({[^\n]*}\\)[[:space:]]*-->"
            content start)
      (setq start (match-end 0))
      (condition-case err
          (let* ((data (json-parse-string (match-string 1 content)
                                          :object-type 'alist
                                          :array-type 'list
                                          :null-object nil :false-object nil))
                 (paths (alist-get 'include data)))
            (if (and (listp paths) (seq-every-p #'stringp paths))
                (setq includes (append includes paths))
              (push '(:type malformed-include :reason "include must be strings")
                    diagnostics)))
        (error
         (push (list :type 'malformed-include
                     :reason (error-message-string err)) diagnostics))))
    (list :includes includes :diagnostics (nreverse diagnostics))))

(defun chat-project--resolve-include (declaring path project-root)
  "Resolve PATH from DECLARING inside PROJECT-ROOT, or return nil."
  (let* ((candidate
          (if (string-prefix-p "/" path)
              (expand-file-name (substring path 1) project-root)
            (expand-file-name path (file-name-directory declaring))))
         (resolved (and (file-exists-p candidate) (file-truename candidate))))
    (when (and resolved (file-regular-p resolved)
               (file-in-directory-p resolved project-root))
      resolved)))

(defun chat-project--source-fragments
    (file content scope scope-id authority priority metadata)
  "Return independently attributable context fragments for FILE and CONTENT."
  (let* ((parts (chat-context-resident-partition content))
         (digest (secure-hash 'sha256 file))
         fragments)
    (dolist (entry `((protected . ,(plist-get parts :resident))
                     (compactable . ,(plist-get parts :compactable))))
      (when-let ((payload (cdr entry)))
        (push
         (chat-context-fragment-validate
          (chat-context-fragment-create
           :id (format "instruction:%s:%s" digest (car entry))
           :kind 'instruction :authority authority
           :source-kind 'agents-file :source-id file :source-path file
           :scope scope :scope-id scope-id :priority priority
           :residency (car entry)
           :budget-policy (if (eq (car entry) 'protected) 'preserve 'compact)
           :payload payload :status 'active
           :metadata (append metadata `((region . ,(car entry))))))
         fragments)))
    (nreverse fragments)))

(defun chat-project--build-instruction-graph (start-directory primary-files)
  "Build a bounded instruction graph for START-DIRECTORY and PRIMARY-FILES."
  (let* ((root (chat-project--root start-directory primary-files))
         (queue
          (mapcar
           (lambda (file)
             (let ((global (equal file chat-project-global-agents-file)))
               (list :file (file-truename file) :parent nil :depth 0
                     :global global
                     :scope (if global 'global 'directory)
                     :scope-id (unless global (file-name-directory file))
                     :authority (if global 'user 'project))))
           primary-files))
         (seen (make-hash-table :test 'equal))
         fragments edges diagnostics source-files
         (bytes 0) (order 0))
    (while queue
      (let* ((entry (pop queue))
             (file (plist-get entry :file))
             (parent (plist-get entry :parent))
             (depth (plist-get entry :depth))
             (global (plist-get entry :global))
             (scope (plist-get entry :scope))
             (scope-id (plist-get entry :scope-id))
             (authority (plist-get entry :authority)))
        (cond
         ((gethash file seen)
          (when parent (push (cons parent file) edges)))
         ((>= (hash-table-count seen) chat-project-instruction-max-files)
          (push (list :type 'file-limit :path file) diagnostics))
         ((> depth chat-project-instruction-max-depth)
          (push (list :type 'depth-limit :path file :parent parent) diagnostics))
         (t
          (puthash file t seen)
          (let ((size (file-attribute-size (file-attributes file))))
            (if (> (+ bytes size) chat-project-instruction-max-bytes)
                (push (list :type 'byte-limit :path file) diagnostics)
              (setq bytes (+ bytes size) order (1+ order))
              (let* ((content (with-temp-buffer
                                (insert-file-contents file)
                                (buffer-string)))
                     (parsed (chat-project--directive-includes content)))
                (push file source-files)
                (when parent (push (cons parent file) edges))
                (dolist (fragment
                         (reverse
                          (chat-project--source-fragments
                           file content scope scope-id authority order
                           `((depth . ,depth) (parent . ,parent)
                             (projectRoot . ,root)))))
                  (push fragment fragments))
                (dolist (diagnostic (plist-get parsed :diagnostics))
                  (push (append diagnostic (list :path file)) diagnostics))
                (dolist (include (plist-get parsed :includes))
                  (let ((resolved
                         (and (not global)
                              (chat-project--resolve-include file include root))))
                    (cond
                     ((null resolved)
                      (push (list :type 'include-refused :path include
                                  :parent file) diagnostics))
                     ((gethash resolved seen)
                      (push (cons file resolved) edges)
                      (push (list :type 'include-cycle-or-duplicate
                                  :path resolved :parent file) diagnostics))
                     (t
                      (setq queue
                            (append queue
                                    (list (list :file resolved :parent file
                                                :depth (1+ depth)
                                                :global nil :scope scope
                                                :scope-id scope-id
                                                :authority authority)))))))))))))))
    (list :schema-version 1 :project-root root
          :fragments (nreverse fragments) :edges (nreverse edges)
          :diagnostics (nreverse diagnostics) :source-files (nreverse source-files)
          :source-bytes bytes)))

(defun chat-project-instruction-graph (start-directory)
  "Return the cached scoped instruction graph for START-DIRECTORY."
  (let* ((target (file-name-as-directory (file-truename start-directory)))
         (primary (chat-project--instruction-files target))
         (primary-stamps (and primary (chat-project--stamps primary)))
         (config (chat-project--graph-config-identity))
         (entry (gethash target chat-project--graph-cache)))
    (if (and entry
             (equal config (plist-get entry :config))
             (equal primary-stamps (plist-get entry :primary-stamps))
             (chat-project--stamps-current-p (plist-get entry :source-stamps)))
        (plist-get entry :graph)
      (when primary
        (let* ((graph (chat-project--build-instruction-graph target primary))
               (sources (plist-get graph :source-files)))
          (puthash target
                   (list :config config :primary-stamps primary-stamps
                         :source-stamps (chat-project--stamps sources)
                         :graph graph)
                   chat-project--graph-cache)
          graph)))))

(defun chat-project--graph-merged-text (graph)
  "Return compatibility text rendered from GRAPH fragments."
  (when graph
    (string-join
     (mapcar
      (lambda (fragment)
        (format ";; Project instructions from %s:\n%s"
                (chat-context-fragment-source-path fragment)
                (string-trim-right
                 (chat-context-fragment-payload fragment))))
      (plist-get graph :fragments))
     "\n\n")))

(defun chat-project--render-fragments (fragments)
  "Render FRAGMENTS with source annotations, preserving source identity."
  (when fragments
    (string-join
     (mapcar
      (lambda (fragment)
        (format ";; Project instructions from %s:\n%s"
                (chat-context-fragment-source-path fragment)
                (string-trim-right
                 (chat-context-fragment-payload fragment))))
      fragments)
     "\n\n")))

(defun chat-project--cached (start-directory compute)
  "Return instructions for START-DIRECTORY, calling COMPUTE on a miss."
  (let* ((files (chat-project--instruction-files start-directory))
         (stamps (chat-project--stamps files))
         ;; The cap is part of the answer, and unlike the file set it
         ;; leaves no trace in the stamps, so a changed cap would
         ;; otherwise be served the old truncation.
         (key (cons start-directory chat-project-instructions-max-chars))
         (entry (gethash key chat-project--cache)))
    (if (and entry (equal (car entry) stamps))
        (cdr entry)
      (let ((result (funcall compute files)))
        (puthash key (cons stamps result) chat-project--cache)
        result))))

(defun chat-project-instructions-partitioned (start-directory)
  "Return instructions for START-DIRECTORY split by declared residency.

The result is a plist of `:resident' and `:compactable', either of which
may be nil.  A file marks the spans it needs kept verbatim; see
`chat-context-resident-parse' for the syntax.

The size cap applies to the compactable part alone.  Truncating the
merged text by character count, as this once did, cuts whatever happens
to sit at the end -- so a long instructions file lost its last rules
without saying so, which is a worse outcome than summarizing them."
  (when-let* ((graph (chat-project-instruction-graph start-directory))
              (fragments (plist-get graph :fragments)))
    (let* ((resident
            (chat-project--render-fragments
             (seq-filter
              (lambda (fragment)
                (eq (chat-context-fragment-residency fragment) 'protected))
              fragments)))
           (compactable
            (chat-project--render-fragments
             (seq-remove
              (lambda (fragment)
                (eq (chat-context-fragment-residency fragment) 'protected))
              fragments))))
      (list :resident resident
            :compactable
            (if (and compactable
                     (> (length compactable)
                        chat-project-instructions-max-chars))
                (concat (substring compactable
                                   0 chat-project-instructions-max-chars)
                        "\n... [project instructions truncated]")
              compactable)
            :fragments (plist-get graph :fragments)
            :diagnostics (plist-get graph :diagnostics)))))

(defun chat-project-instructions (start-directory)
  "Return merged project instructions for START-DIRECTORY, or nil.
The global instructions file comes first, then local files from the
filesystem root down to START-DIRECTORY, each with a source annotation.

Declared resident spans come first and are exempt from the
`chat-project-instructions-max-chars' cap, so a file that asks for a
rule to be kept verbatim does not lose it to a size limit.  Callers that
can route the two parts differently should use
`chat-project-instructions-partitioned' instead."
  (when-let ((parts (chat-project-instructions-partitioned start-directory)))
    (let ((pieces (delq nil (list (plist-get parts :resident)
                                  (plist-get parts :compactable)))))
      (and pieces (string-join pieces "\n\n")))))

(provide 'chat-project)
;;; chat-project.el ends here
