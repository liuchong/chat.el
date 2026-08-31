;;; chat-repo-map.el --- Incremental repository context map -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; A repo map is a disposable, run-independent cache used to rank context.
;; Refreshes traverse and parse in bounded timer slices.  Request assembly
;; only reads the last complete revision and therefore never waits for a
;; repository scan.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-code-intel)

(defgroup chat-repo-map nil
  "Incremental repository maps for coding context."
  :group 'chat-code
  :prefix "chat-repo-map-")

(defcustom chat-repo-map-slice-milliseconds 20
  "Target maximum work time for one refresh timer slice."
  :type 'integer
  :group 'chat-repo-map)

(defcustom chat-repo-map-max-items-per-slice 32
  "Maximum traversal or graph items processed in one timer slice."
  :type 'integer
  :group 'chat-repo-map)

(defcustom chat-repo-map-max-file-size (* 500 1024)
  "Maximum file size parsed into a repo map."
  :type 'integer
  :group 'chat-repo-map)

(defcustom chat-repo-map-refresh-minimum-interval 2.0
  "Minimum seconds between automatic refreshes of a warm map."
  :type 'number
  :group 'chat-repo-map)

(defcustom chat-repo-map-query-cache-size 64
  "Maximum warm query results retained for one repository revision."
  :type 'integer
  :group 'chat-repo-map)

(defcustom chat-repo-map-score-weights
  '((query-path . 80)
    (query-symbol . 120)
    (focus . 300)
    (focus-adjacent . 100)
    (changed . 180)
    (diagnostic . 220)
    (test-relation . 90)
    (token-kib . -1))
  "Explicit scoring weights used by `chat-repo-map-query'."
  :type '(alist :key-type symbol :value-type integer)
  :group 'chat-repo-map)

(defconst chat-repo-map--source-pattern
  "\\.\\(py\\|js\\|mjs\\|cjs\\|ts\\|mts\\|cts\\|jsx\\|tsx\\|el\\|go\\|rs\\|zig\\|clj\\|cljc\\|cljs\\|rb\\|java\\|c\\|h\\|cc\\|cpp\\|cxx\\|hh\\|hpp\\|hxx\\|sql\\)\\'"
  "File name pattern admitted to the repo map.")

(defconst chat-repo-map--ignored-directories
  '(".git" "node_modules" "__pycache__" ".venv" "target" "dist" "build")
  "Directories omitted from traversal.")

(cl-defstruct chat-repo-map-entry
  path digest size language symbols imports test-p skipped-reason updated-at)

(cl-defstruct chat-repo-map
  root revision entries adjacency stems importers query-cache state callbacks
  last-result timer)

(defvar chat-repo-map--cache (make-hash-table :test 'equal))

(defun chat-repo-map--canonical-root (root)
  "Return canonical directory form of ROOT."
  (file-name-as-directory (file-truename root)))

(defun chat-repo-map-get (root)
  "Return the warm repo map for ROOT, or nil."
  (gethash (chat-repo-map--canonical-root root) chat-repo-map--cache))

(defun chat-repo-map--get-or-create (root)
  "Return a repo map for ROOT, creating an empty cache if needed."
  (let* ((root (chat-repo-map--canonical-root root))
         (map (gethash root chat-repo-map--cache)))
    (or map
        (let ((created
               (make-chat-repo-map
                :root root :revision "empty"
                :entries (make-hash-table :test 'equal)
                :adjacency (make-hash-table :test 'equal)
                :stems (make-hash-table :test 'equal)
                :importers (make-hash-table :test 'equal)
                :query-cache (make-hash-table :test 'equal)
                :state 'cold :callbacks nil)))
          (puthash root created chat-repo-map--cache)
          created))))

(defun chat-repo-map--ignored-path-p (path)
  "Return non-nil when PATH is an ignored directory."
  (member (file-name-nondirectory (directory-file-name path))
          chat-repo-map--ignored-directories))

(defun chat-repo-map--source-file-p (path)
  "Return non-nil when PATH is a supported source file."
  (and (string-match-p chat-repo-map--source-pattern path)
       (file-regular-p path)))

(defun chat-repo-map--extract-buffer-imports ()
  "Return lightweight import targets from the current buffer."
  (let (imports)
    (goto-char (point-min))
    (while
        (re-search-forward
         "^[[:space:]]*\\(?:import\\|from\\|require\\|use\\|mod\\|#include\\|package\\)[[:space:]('\"<]*\\([^[:space:]'\">;,)]+\\)"
         nil t)
      (push (match-string-no-properties 1) imports))
    (sort (delete-dups imports) #'string<)))

(defun chat-repo-map--read-file-summary (path language)
  "Read PATH once and return digest, symbols, and imports for LANGUAGE."
  (with-temp-buffer
    (insert-file-contents path)
    (let ((digest (secure-hash 'sha256 (current-buffer)))
          (symbols (chat-code-intel-extract-buffer-symbols language))
          (imports (chat-repo-map--extract-buffer-imports)))
      (dolist (symbol symbols)
        (setf (chat-code-symbol-file symbol) path))
      (list digest symbols imports))))

(defun chat-repo-map--test-file-p (path)
  "Return non-nil when PATH has a conventional test name."
  (string-match-p
   "\\(?:^\\|/\\)\\(?:test[s]?/\\|[^/]*\\(?:_test\\|test_\\|\\.test\\|\\.spec\\)[^/]*\\)"
   path))

(defun chat-repo-map--entry-for-file (path old-entry)
  "Return an updated entry for PATH, reusing OLD-ENTRY when unchanged."
  (let* ((attributes (file-attributes path 'string))
         (size (file-attribute-size attributes))
         (modified-at (float-time (file-attribute-modification-time attributes))))
    (if (> size chat-repo-map-max-file-size)
        (if (and old-entry
                 (eq (chat-repo-map-entry-skipped-reason old-entry) 'large-file)
                 (= size (chat-repo-map-entry-size old-entry))
                 (= modified-at (chat-repo-map-entry-updated-at old-entry)))
            old-entry
          (make-chat-repo-map-entry
           :path path :digest nil :size size
           :language (chat-code-intel-detect-language path)
           :symbols nil :imports nil
           :test-p (chat-repo-map--test-file-p path)
           :skipped-reason 'large-file :updated-at modified-at))
      (let* ((language (chat-code-intel-detect-language path))
             (summary (chat-repo-map--read-file-summary path language))
             (digest (nth 0 summary)))
        (if (and old-entry
                 (equal digest (chat-repo-map-entry-digest old-entry)))
            old-entry
          (make-chat-repo-map-entry
           :path path :digest digest :size size
           :language language
           :symbols (nth 1 summary)
           :imports (nth 2 summary)
           :test-p (chat-repo-map--test-file-p path)
           :skipped-reason nil :updated-at modified-at))))))

(defun chat-repo-map--stem (path)
  "Return a normalized relation stem for PATH."
  (let ((name (file-name-base path)))
    (setq name (replace-regexp-in-string "\\(?:_test\\|test_\\|\\.test\\|\\.spec\\)" "" name))
    (downcase name)))

(defun chat-repo-map--revision (entries)
  "Return a deterministic revision for ENTRIES."
  (let (parts)
    (maphash
     (lambda (path entry)
       (push (format "%s\0%s\0%s"
                     path
                     (or (chat-repo-map-entry-digest entry) "skipped")
                     (or (chat-repo-map-entry-skipped-reason entry) "indexed"))
             parts))
     entries)
    (secure-hash 'sha256 (mapconcat #'identity (sort parts #'string<) "\0"))))

(defun chat-repo-map-refresh-async (root callback)
  "Refresh ROOT in timer slices and call CALLBACK with a result plist.

If ROOT is already refreshing, CALLBACK joins that refresh.  The returned
function removes CALLBACK from the waiter list."
  (let* ((map (chat-repo-map--get-or-create root))
         (root (chat-repo-map-root map)))
    (if (memq (chat-repo-map-state map) '(building updating))
        (progn
          (push callback (chat-repo-map-callbacks map))
          (lambda ()
            (setf (chat-repo-map-callbacks map)
                  (delq callback (chat-repo-map-callbacks map)))))
      (setf (chat-repo-map-state map) 'building
            (chat-repo-map-callbacks map) (list callback))
      (let ((queue (list root))
            (phase 'scan)
            (seen (make-hash-table :test 'equal))
            (entries (copy-hash-table (chat-repo-map-entries map)))
            (stems (make-hash-table :test 'equal))
            (importers (make-hash-table :test 'equal))
            (adjacency (copy-hash-table (chat-repo-map-adjacency map)))
            (changed-paths (make-hash-table :test 'equal))
            (removed-paths (make-hash-table :test 'equal))
            (changed-stems (make-hash-table :test 'equal))
            (phase-queue nil)
            (changed 0)
            (skipped 0)
            (removed 0)
            (edges-rebuilt 0)
            (slice-count 0)
            (max-slice-ms 0.0)
            (max-slice-wall-ms 0.0)
            (max-slice-gc-ms 0.0)
            max-slice-phase
            timer)
        (cl-labels
            ((finish ()
               (setf (chat-repo-map-timer map) nil)
               (when-let ((cache (chat-repo-map-query-cache map)))
                 (clrhash cache))
               (setf (chat-repo-map-entries map) entries
                     (chat-repo-map-adjacency map) adjacency
                     (chat-repo-map-stems map) stems
                     (chat-repo-map-importers map) importers
                     (chat-repo-map-revision map) (chat-repo-map--revision entries)
                     (chat-repo-map-state map) 'warm)
               (let ((result
                      (list :status 'ok
                            :revision (chat-repo-map-revision map)
                            :files (hash-table-count entries)
                            :changed changed :removed removed :skipped skipped
                            :edges-rebuilt edges-rebuilt
                            :slices slice-count :max-slice-ms max-slice-ms
                            :max-slice-wall-ms max-slice-wall-ms
                            :max-slice-gc-ms max-slice-gc-ms
                            :max-slice-phase max-slice-phase)))
                 (setf (chat-repo-map-last-result map)
                       (plist-put result :completed-at (float-time)))
                 (let ((callbacks (nreverse (chat-repo-map-callbacks map))))
                   (setf (chat-repo-map-callbacks map) nil)
                   (dolist (waiter callbacks) (funcall waiter result)))))
             (prune-removed ()
               (maphash
                (lambda (path _entry)
                  (unless (gethash path seen)
                    (remhash path entries)
                    (remhash path adjacency)
                    (puthash path t removed-paths)
                    (cl-incf removed)))
                (copy-hash-table entries)))
             (scan-item (path)
               (condition-case nil
                   (cond
                    ((and (file-directory-p path)
                          (not (file-symlink-p path))
                          (not (chat-repo-map--ignored-path-p path)))
                     (setq queue
                           (nconc (sort (directory-files path t directory-files-no-dot-files-regexp t)
                                       #'string<)
                                  queue)))
                    ((chat-repo-map--source-file-p path)
                     (let* ((path (file-truename path))
                            (old (gethash path entries))
                            (entry (chat-repo-map--entry-for-file path old)))
                       (puthash path t seen)
                       (puthash path entry entries)
                       (when (chat-repo-map-entry-skipped-reason entry) (cl-incf skipped))
                       (unless (eq entry old)
                         (puthash path t changed-paths)
                         (cl-incf changed))))
                    (t nil))
                 (file-error nil)))
             (build-stem (path)
               (let* ((entry (gethash path entries))
                      (stem (chat-repo-map--stem path)))
                 (puthash stem (cons path (gethash stem stems)) stems)
                 (dolist (target (chat-repo-map-entry-imports entry))
                   (let ((target-stem (chat-repo-map--stem target)))
                     (puthash target-stem
                              (cons path (gethash target-stem importers))
                              importers)))))
             (resolve-edges (path)
               (cl-incf edges-rebuilt)
               (let* ((entry (gethash path entries))
                      (related (copy-sequence
                                (gethash (chat-repo-map--stem path) stems))))
                 (dolist (target (chat-repo-map-entry-imports entry))
                   (setq related
                         (nconc (copy-sequence
                                 (gethash (chat-repo-map--stem target) stems))
                                related)))
                 (puthash path (sort (delete path (delete-dups related)) #'string<)
                          adjacency)))
             (affected-path-p (path entry)
               (or (gethash path changed-paths)
                   (gethash (chat-repo-map--stem path) changed-stems)
                   (seq-some (lambda (neighbor)
                               (or (gethash neighbor changed-paths)
                                   (gethash neighbor removed-paths)))
                             (gethash path adjacency))
                   (seq-some (lambda (target)
                               (gethash (chat-repo-map--stem target) changed-stems))
                             (chat-repo-map-entry-imports entry))))
             (advance-phase ()
               (pcase phase
                 ('scan
                  (prune-removed)
                  (setq phase 'stems
                        phase-queue nil)
                  (maphash (lambda (path _entry) (push path phase-queue)) entries)
                  (setq phase-queue (sort phase-queue #'string<)))
                 ('stems
                  (setq phase 'edges
                        phase-queue nil)
                  (if (= changed (hash-table-count entries))
                      ;; A cold build changed every entry, so every edge is
                      ;; affected.  Scanning all entries again to prove that
                      ;; made the phase-transition slice exceed its UI budget.
                      (setq phase-queue (hash-table-keys entries))
                    (maphash (lambda (path _)
                               (puthash (chat-repo-map--stem path) t changed-stems))
                             changed-paths)
                    (maphash (lambda (path _)
                               (puthash (chat-repo-map--stem path) t changed-stems))
                             removed-paths)
                    (maphash (lambda (path entry)
                               (when (affected-path-p path entry)
                                 (push path phase-queue)))
                             entries)
                    (setq phase-queue (sort phase-queue #'string<))))
                 ('edges (setq phase 'done))))
             (step ()
               (let* ((started (float-time))
                      (cpu-started (float-time (current-cpu-time)))
                      (gc-started (float-time gc-elapsed))
                      (slice-phase phase)
                      (deadline (+ started (/ chat-repo-map-slice-milliseconds 1000.0)))
                      (processed 0)
                      cpu-ms gc-ms)
                 (cl-incf slice-count)
                 (while (and (< (float-time) deadline)
                             (< processed chat-repo-map-max-items-per-slice)
                             (not (eq phase 'done)))
                   (cl-incf processed)
                   (pcase phase
                     ('scan
                      (if queue (scan-item (pop queue)) (advance-phase)))
                     ('stems
                      (if phase-queue (build-stem (pop phase-queue)) (advance-phase)))
                     ('edges
                      (if phase-queue (resolve-edges (pop phase-queue)) (advance-phase)))))
                 (setq gc-ms (* 1000.0 (- (float-time gc-elapsed) gc-started))
                       cpu-ms
                       (max 0.0
                            (- (* 1000.0
                                  (- (float-time (current-cpu-time))
                                     cpu-started))
                               gc-ms))
                       max-slice-gc-ms (max max-slice-gc-ms gc-ms))
                 (when (> cpu-ms max-slice-ms)
                   (setq max-slice-ms cpu-ms
                         max-slice-phase slice-phase))
                 (setq
                       max-slice-wall-ms
                       (max max-slice-wall-ms
                            (* 1000.0 (- (float-time) started))))
                 (if (eq phase 'done)
                     (finish)
                   (setq timer (run-at-time 0 nil #'step))
                   (setf (chat-repo-map-timer map) timer)))))
          (setq timer (run-at-time 0 nil #'step))
          (setf (chat-repo-map-timer map) timer)
          (lambda ()
            (setf (chat-repo-map-callbacks map)
                  (delq callback (chat-repo-map-callbacks map)))))))))

(defun chat-repo-map--table-list-add (table key value)
  "Add VALUE once to the list stored at KEY in TABLE."
  (puthash key (cons value (delete value (gethash key table))) table))

(defun chat-repo-map--table-list-remove (table key value)
  "Remove VALUE from the list stored at KEY in TABLE."
  (let ((remaining (delete value (gethash key table))))
    (if remaining
        (puthash key remaining table)
      (remhash key table))))

(defun chat-repo-map--incremental-revision (previous entries paths)
  "Return a revision derived from PREVIOUS after updating PATHS in ENTRIES."
  (secure-hash
   'sha256
   (concat
    previous "\0"
    (mapconcat
     (lambda (path)
       (let ((entry (gethash path entries)))
         (format "%s\0%s"
                 path
                 (if entry
                     (or (chat-repo-map-entry-digest entry) "skipped")
                   "removed"))))
     (sort (copy-sequence paths) #'string<)
     "\0"))))

(defun chat-repo-map-update-paths-async (root paths callback)
  "Incrementally update known PATHS below ROOT and call CALLBACK.

This path is for editor-observed writes and removals.  It avoids discovering
changes by rescanning ROOT, while preserving the full refresh API for unknown
external changes.  The returned function cancels delivery to CALLBACK."
  (unless (functionp callback)
    (error "Repo map update requires a callback"))
  (let* ((map (chat-repo-map--get-or-create root))
         (root (chat-repo-map-root map))
         (paths
          (sort
           (delete-dups
            (delq
             nil
             (mapcar
              (lambda (path)
                (let ((canonical
                       (condition-case nil
                           (file-truename path)
                         (file-error (expand-file-name path root)))))
                  (when (file-in-directory-p canonical root) canonical)))
              paths)))
           #'string<))
         timer)
    (if (not (eq (chat-repo-map-state map) 'warm))
        (let (cancelled refresh-cancel update-cancel)
          (setq
           refresh-cancel
           (chat-repo-map-refresh-async
            root
            (lambda (_result)
              (unless cancelled
                (setq update-cancel
                      (chat-repo-map-update-paths-async
                       root paths callback))))))
          (lambda ()
            (setq cancelled t)
            (when (functionp refresh-cancel) (funcall refresh-cancel))
            (when (functionp update-cancel) (funcall update-cancel))))
      (let ((cancelled nil))
        (setf (chat-repo-map-state map) 'updating
              (chat-repo-map-callbacks map) (list callback))
        (setq
         timer
         (run-at-time
          0 nil
          (lambda ()
            (unless cancelled
              (let* ((started (float-time))
                     (cpu-started (float-time (current-cpu-time)))
                     (gc-started (float-time gc-elapsed)))
                (condition-case error-data
                    (let ((entries (copy-hash-table
                                    (chat-repo-map-entries map)))
                          (adjacency (copy-hash-table
                                      (chat-repo-map-adjacency map)))
                          (stems (copy-hash-table
                                  (chat-repo-map-stems map)))
                          (importers (copy-hash-table
                                      (chat-repo-map-importers map)))
                          (affected-stems (make-hash-table :test 'equal))
                          (affected-paths (make-hash-table :test 'equal))
                          (changed 0)
                          (removed 0)
                          (edges-rebuilt 0))
                      (dolist (path paths)
                        (let* ((old (gethash path entries))
                               (old-stem (and old (chat-repo-map--stem path))))
                          (puthash path t affected-paths)
                          (dolist (neighbor (gethash path adjacency))
                            (puthash neighbor t affected-paths))
                          (when old
                            (puthash old-stem t affected-stems)
                            (chat-repo-map--table-list-remove
                             stems old-stem path)
                            (dolist (target (chat-repo-map-entry-imports old))
                              (chat-repo-map--table-list-remove
                               importers (chat-repo-map--stem target) path)))
                          (if (chat-repo-map--source-file-p path)
                              (let* ((entry
                                      (chat-repo-map--entry-for-file path old))
                                     (stem (chat-repo-map--stem path)))
                                (puthash path entry entries)
                                (puthash stem t affected-stems)
                                (chat-repo-map--table-list-add stems stem path)
                                (dolist (target
                                         (chat-repo-map-entry-imports entry))
                                  (chat-repo-map--table-list-add
                                   importers (chat-repo-map--stem target) path))
                                (unless (eq entry old) (cl-incf changed)))
                            (when old
                              (remhash path entries)
                              (remhash path adjacency)
                              (cl-incf removed)))))
                      (maphash
                       (lambda (stem _)
                         (dolist (path (append (gethash stem stems)
                                              (gethash stem importers)))
                           (puthash path t affected-paths)))
                       affected-stems)
                      (maphash
                       (lambda (path _)
                         (let ((entry (gethash path entries)))
                           (if (null entry)
                               (remhash path adjacency)
                             (cl-incf edges-rebuilt)
                             (let ((related
                                    (copy-sequence
                                     (gethash (chat-repo-map--stem path)
                                              stems))))
                               (dolist (target
                                        (chat-repo-map-entry-imports entry))
                                 (setq related
                                       (nconc
                                        (copy-sequence
                                         (gethash (chat-repo-map--stem target)
                                                  stems))
                                        related)))
                               (puthash
                                path
                                (sort (delete path (delete-dups related))
                                      #'string<)
                                adjacency)))))
                       affected-paths)
                      (when-let ((cache (chat-repo-map-query-cache map)))
                        (clrhash cache))
                      (let* ((wall-ms
                              (* 1000.0 (- (float-time) started)))
                             (gc-ms
                              (* 1000.0
                                 (- (float-time gc-elapsed) gc-started)))
                             (cpu-ms
                              (max
                               0.0
                               (- (* 1000.0
                                     (- (float-time (current-cpu-time))
                                        cpu-started))
                                  gc-ms)))
                             (result
                              (list
                               :status 'ok
                               :revision
                               (chat-repo-map--incremental-revision
                                (chat-repo-map-revision map) entries paths)
                               :files (hash-table-count entries)
                               :changed changed :removed removed :skipped 0
                               :edges-rebuilt edges-rebuilt :slices 1
                               :max-slice-ms cpu-ms
                               :max-slice-wall-ms wall-ms
                               :max-slice-gc-ms gc-ms
                               :max-slice-phase 'incremental
                               :completed-at (float-time))))
                        (setf (chat-repo-map-entries map) entries
                              (chat-repo-map-adjacency map) adjacency
                              (chat-repo-map-stems map) stems
                              (chat-repo-map-importers map) importers
                              (chat-repo-map-revision map)
                              (plist-get result :revision)
                              (chat-repo-map-state map) 'warm
                              (chat-repo-map-last-result map) result
                              (chat-repo-map-timer map) nil)
                        (let ((callbacks
                               (nreverse (chat-repo-map-callbacks map))))
                          (setf (chat-repo-map-callbacks map) nil)
                          (dolist (waiter callbacks)
                            (funcall waiter result)))))
                  (error
                   (setf (chat-repo-map-state map) 'warm
                         (chat-repo-map-timer map) nil)
                   (let ((callbacks
                          (nreverse (chat-repo-map-callbacks map))))
                     (setf (chat-repo-map-callbacks map) nil)
                     (dolist (waiter callbacks)
                       (funcall
                        waiter
                        (list :status 'failed
                              :error (error-message-string error-data)))))))))))))
        (setf (chat-repo-map-timer map) timer)
        (lambda ()
          (setq cancelled t)
          (when (timerp timer) (cancel-timer timer))
          (setf (chat-repo-map-timer map) nil)
          (setf (chat-repo-map-callbacks map)
                (delq callback (chat-repo-map-callbacks map)))
          (when (eq (chat-repo-map-state map) 'updating)
            (setf (chat-repo-map-state map) 'warm))))))

(defun chat-repo-map-discard (root)
  "Cancel and remove the cached repo map owned for ROOT."
  (let* ((canonical (chat-repo-map--canonical-root root))
         (map (gethash canonical chat-repo-map--cache)))
    (when map
      (when (timerp (chat-repo-map-timer map))
        (cancel-timer (chat-repo-map-timer map)))
      (setf (chat-repo-map-timer map) nil
            (chat-repo-map-callbacks map) nil
            (chat-repo-map-state map) 'discarded)
      (remhash canonical chat-repo-map--cache)
      t)))

(defun chat-repo-map--call-arguments (call)
  "Return CALL arguments as a string-keyed alist."
  (let ((arguments (plist-get call :arguments)))
    (cond
     ((hash-table-p arguments)
      (let (alist)
        (maphash (lambda (key value)
                   (push (cons (format "%s" key) value) alist))
                 arguments)
        (nreverse alist)))
     ((listp arguments) arguments)
     (t nil))))

(defun chat-repo-map-update-tool-call (root call)
  "Update a warm ROOT map after successful precise file CALL.

Return the asynchronous cancel function, or nil when CALL has no exact file
targets or ROOT has no warm map."
  (let* ((map (chat-repo-map-get root))
         (tool-id (intern (format "%s" (plist-get call :name)))))
    (when (and map
               (eq (chat-repo-map-state map) 'warm)
               (memq tool-id
                     '(files_write files_replace files_patch apply_patch))
               (fboundp 'chat-files--tool-target-paths))
      (let ((default-directory (chat-repo-map-root map))
            (paths
             (chat-files--tool-target-paths
              tool-id (chat-repo-map--call-arguments call))))
        (when paths
          (chat-repo-map-update-paths-async root paths #'ignore))))))

(defun chat-repo-map-schedule-refresh (root)
  "Schedule a non-blocking refresh for ROOT unless one is running."
  (let* ((map (chat-repo-map--get-or-create root))
         (last (chat-repo-map-last-result map))
         (completed-at (plist-get last :completed-at)))
    (unless (or (memq (chat-repo-map-state map) '(building updating))
                (and completed-at
                     (< (- (float-time) completed-at)
                        chat-repo-map-refresh-minimum-interval)))
      (chat-repo-map-refresh-async root #'ignore))))

(defun chat-repo-map--canonical-candidate (path)
  "Return a stable absolute form for candidate PATH."
  (when path
    (condition-case nil
        (file-truename path)
      (file-error (expand-file-name path)))))

(defun chat-repo-map--weight (component)
  "Return configured score weight for COMPONENT."
  (or (alist-get component chat-repo-map-score-weights) 0))

(defun chat-repo-map--query-terms (query)
  "Return normalized lexical terms from QUERY."
  (sort (delete-dups
         (seq-filter
          (lambda (term) (> (length term) 1))
          (split-string (downcase (or query "")) "[^[:alnum:]_]+" t)))
        #'string<))

(defun chat-repo-map--canonical-set (paths)
  "Return a canonical-path set for PATHS."
  (let ((set (make-hash-table :test 'equal)))
    (dolist (path paths set)
      (when-let ((canonical (chat-repo-map--canonical-candidate path)))
        (puthash canonical t set)))))

(defun chat-repo-map--prepare-request (request)
  "Return REQUEST with query-wide ranking inputs computed once."
  (let* ((prepared (copy-sequence request))
         (focus (chat-repo-map--canonical-candidate
                 (plist-get request :focus-file))))
    (setq prepared
          (plist-put prepared :prepared-query-terms
                     (chat-repo-map--query-terms
                      (plist-get request :query))))
    (setq prepared (plist-put prepared :prepared-focus focus))
    (setq prepared
          (plist-put prepared :prepared-focus-stem
                     (and focus (chat-repo-map--stem focus))))
    (setq prepared
          (plist-put prepared :prepared-changed
                     (chat-repo-map--canonical-set
                      (or (plist-get request :changed-files) nil))))
    (plist-put prepared :prepared-diagnostics
               (chat-repo-map--canonical-set
                (or (plist-get request :diagnostic-paths) nil)))))

(defun chat-repo-map--score-entry (map entry request)
  "Return score and reasons for ENTRY in MAP under REQUEST."
  (let* ((path (chat-repo-map-entry-path entry))
         (path-text (downcase path))
         (symbol-text
          (downcase
           (mapconcat #'chat-code-symbol-name
                      (chat-repo-map-entry-symbols entry) " ")))
         (terms (plist-get request :prepared-query-terms))
         (focus (plist-get request :prepared-focus))
         (focus-stem (plist-get request :prepared-focus-stem))
         (changed (plist-get request :prepared-changed))
         (diagnostics (plist-get request :prepared-diagnostics))
         (score 0)
         reasons)
    (dolist (term terms)
      (when (string-match-p (regexp-quote term) path-text)
        (cl-incf score (chat-repo-map--weight 'query-path))
        (push 'query-path reasons))
      (when (string-match-p (regexp-quote term) symbol-text)
        (cl-incf score (chat-repo-map--weight 'query-symbol))
        (push 'query-symbol reasons)))
    (when (and focus (string= path focus))
      (cl-incf score (chat-repo-map--weight 'focus))
      (push 'focus reasons))
    (when (and focus (member path (gethash focus (chat-repo-map-adjacency map))))
      (cl-incf score (chat-repo-map--weight 'focus-adjacent))
      (push 'focus-adjacent reasons))
    (when (gethash path changed)
      (cl-incf score (chat-repo-map--weight 'changed))
      (push 'changed reasons))
    (when (gethash path diagnostics)
      (cl-incf score (chat-repo-map--weight 'diagnostic))
      (push 'diagnostic reasons))
    (when (and focus
               (not (string= path focus))
               (string= (chat-repo-map--stem path) focus-stem)
               (or (chat-repo-map-entry-test-p entry)
                   (chat-repo-map--test-file-p focus)))
      (cl-incf score (chat-repo-map--weight 'test-relation))
      (push 'test-relation reasons))
    (cl-incf score (* (chat-repo-map--weight 'token-kib)
                      (/ (chat-repo-map-entry-size entry) 1024)))
    (cons score (sort (delete-dups reasons)
                      (lambda (a b) (string< (symbol-name a) (symbol-name b)))))))

(defun chat-repo-map--query-uncached (map request)
  "Rank MAP entries according to prepared REQUEST."
  (let ((candidates nil)
        (prepared-request (chat-repo-map--prepare-request request))
        (budget (or (plist-get request :token-budget) 4000))
        (limit (or (plist-get request :limit) 10))
        (used 0)
        (selected nil)
        (excluded 0)
        (seen (make-hash-table :test 'equal)))
    (maphash
     (lambda (_path entry)
       (unless (chat-repo-map-entry-skipped-reason entry)
         (let ((score (chat-repo-map--score-entry
                       map entry prepared-request)))
           (push (list :path (chat-repo-map-entry-path entry)
                       :score (car score)
                       :reasons (cdr score)
                       :token-cost (max 1 (/ (chat-repo-map-entry-size entry) 4))
                       :language (chat-repo-map-entry-language entry)
                       :symbols (mapcar #'chat-code-symbol-name
                                        (chat-repo-map-entry-symbols entry)))
                 candidates))))
     (chat-repo-map-entries map))
    (setq candidates
          (sort candidates
                (lambda (a b)
                  (if (= (plist-get a :score) (plist-get b :score))
                      (string< (plist-get a :path) (plist-get b :path))
                    (> (plist-get a :score) (plist-get b :score))))))
    (dolist (item candidates)
      (let ((path (plist-get item :path))
            (cost (plist-get item :token-cost)))
        (if (or (>= (length selected) limit)
                (gethash path seen)
                (> (+ used cost) budget))
            (cl-incf excluded)
          (puthash path t seen)
          (cl-incf used cost)
          (push item selected))))
    (list :status (if selected 'ok 'empty)
          :revision (chat-repo-map-revision map)
          :items (nreverse selected)
          :diagnostics `((state . ,(chat-repo-map-state map))
                         (token-budget . ,budget)
                         (token-used . ,used)
                         (excluded . ,excluded)
                         (truncation-reason . ,(and (> excluded 0)
                                                   'budget-or-limit))))))

(defun chat-repo-map-query (root request)
  "Rank warm repo map entries for ROOT according to REQUEST.

REQUEST accepts `:query', `:focus-file', `:changed-files',
`:diagnostic-paths', `:limit' and `:token-budget'."
  (let ((map (chat-repo-map-get root)))
    (if (or (null map) (eq (chat-repo-map-state map) 'cold))
        (list :status 'unavailable :revision "none" :items nil
              :diagnostics '((reason . cold-cache)))
      (let* ((cache (or (chat-repo-map-query-cache map)
                        (setf (chat-repo-map-query-cache map)
                              (make-hash-table :test 'equal))))
             (key (secure-hash
                   'sha256
                   (prin1-to-string
                    (list (chat-repo-map-revision map) request))))
             (cached (gethash key cache)))
        (if cached
            (copy-tree cached)
          (when (>= (hash-table-count cache) chat-repo-map-query-cache-size)
            (clrhash cache))
          (let ((result (chat-repo-map--query-uncached map request)))
            (puthash key (copy-tree result) cache)
            result))))))

(provide 'chat-repo-map)
;;; chat-repo-map.el ends here
