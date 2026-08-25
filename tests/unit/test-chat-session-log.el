;;; test-chat-session-log.el --- Tests for session self-knowledge -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for the transcript lookup: the prompt block that tells a run
;; where its record is, the filters, and the turn grouping that keeps a
;; question with the steps that answered it.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-session-log)

(defun test-session-log--message (role content &rest metadata)
  "Build a message with ROLE, CONTENT and METADATA."
  (make-chat-message
   :id (chat-session-new-message-id)
   :role role
   :content content
   :timestamp (current-time)
   :metadata metadata))

(defun test-session-log--session ()
  "Build a session carrying two stamped turns."
  (make-chat-session
   :id "log-test"
   :name "Log Test"
   :model-id 'kimi
   :created-at (current-time)
   :updated-at (current-time)
   :messages
   (list (test-session-log--message :user "first question"
                                    :turn 1 :step 0 :category 'user)
         (test-session-log--message :assistant "looking"
                                    :turn 1 :step 1 :category 'ai-progress
                                    :work 'message :reasoning "hmm")
         (test-session-log--message :tool "tool said so"
                                    :turn 1 :step 1 :category 'ai-progress
                                    :work 'tool-result)
         (test-session-log--message :assistant "first answer"
                                    :turn 1 :step 2 :category 'ai-final)
         (test-session-log--message :user "second question"
                                    :turn 2 :step 0 :category 'user)
         (test-session-log--message :assistant "second answer"
                                    :turn 2 :step 1 :category 'ai-final))))

;; ------------------------------------------------------------------
;; Self description
;; ------------------------------------------------------------------

(ert-deftest chat-session-log-self-description-names-the-file ()
  "The prompt block gives the path, not a description of one.

A run that has to guess a path does not look, and one that guesses wrong
reports its own transcript as missing."
  (let* ((session (test-session-log--session))
         (text (chat-session-log-self-description session)))
    (should (string-match-p "log-test" text))
    (should (string-match-p "Log Test" text))
    (should (string-match-p "log-test\\.jsonl" text))
    (should (string-match-p "session_log" text))))

(ert-deftest chat-session-log-self-description-says-the-record-is-complete ()
  "The block states that compacted-away turns are still on disk.

That is the whole point: a run that believes the summary is all there is
will ask again instead of reading."
  (let ((text (chat-session-log-self-description (test-session-log--session))))
    (should (string-match-p "summarized out of the context" text))
    (should (string-match-p "turn, step, category and work" text))))

(ert-deftest chat-session-log-self-description-tolerates-no-session ()
  "Without a session the block is absent rather than malformed."
  (should-not (chat-session-log-self-description nil)))

(ert-deftest chat-session-log-terse-form-keeps-the-path ()
  "The short form drops the reasoning and keeps what can be acted on.

A block trimmed down to advice is worse than absent: the run still spends
tokens on it and still cannot find the file."
  (let* ((session (test-session-log--session))
         (terse (chat-session-log-self-description session t))
         (full (chat-session-log-self-description session)))
    (should (string-match-p "log-test\\.jsonl" terse))
    (should (string-match-p "session_log" terse))
    (should (< (length terse) (/ (length full) 2)))))

;; ------------------------------------------------------------------
;; Fitting the prompt share
;; ------------------------------------------------------------------

(ert-deftest chat-session-log-storage-note-fits-a-small-window ()
  "The storage block shortens itself rather than busting its share.

Measured, not assumed: the full block runs past the entire system prompt
share of an 8K window, so on a small window it would crowd out the
conversation it exists to help recover."
  (let ((session (test-session-log--session)))
    (cl-letf (((symbol-function 'chat-context-window-for-model)
               (lambda (&rest _) 8192)))
      (let ((note (chat-tool-caller--durable-storage-note session))
            (share (chat-context-allocation-tokens 'system-prompt 8192)))
        (should note)
        (should (<= (chat-context-count-tokens note) share))
        ;; Still usable: the paths survived the trim.
        (should (string-match-p "log-test\\.jsonl" note))))))

(ert-deftest chat-session-log-storage-note-stays-full-on-a-large-window ()
  "A large window keeps the explanation, since it costs nothing there."
  (let ((session (test-session-log--session)))
    (cl-letf (((symbol-function 'chat-context-window-for-model)
               (lambda (&rest _) 131072)))
      (let ((note (chat-tool-caller--durable-storage-note session)))
        (should (string-match-p "summarized out of the context" note))
        (should (<= (chat-context-count-tokens note)
                    (chat-context-allocation-tokens
                     'system-prompt 131072)))))))

(ert-deftest chat-session-log-storage-note-describes-all-three-places ()
  "Transcript, scratch and shared knowledge are introduced together.

Described separately, a run tends to put everything in whichever one it
noticed first."
  (let ((note (chat-tool-caller--durable-storage-note
               (test-session-log--session))))
    (should (string-match-p "transcript" note))
    (should (string-match-p "[Ss]cratch" note))
    (should (string-match-p "knowledge" note))))

;; ------------------------------------------------------------------
;; Filters
;; ------------------------------------------------------------------

(ert-deftest chat-session-log-filters-by-category ()
  "Only the requested category comes back."
  (let* ((messages (chat-session-messages (test-session-log--session)))
         (finals (chat-session-log-filter messages '(:category "ai-final"))))
    (should (equal (length finals) 2))
    (dolist (message finals)
      (should (eq (chat-transcript-category message) 'ai-final)))))

(ert-deftest chat-session-log-filters-by-work-kind ()
  "Work kind narrows within a category."
  (let* ((messages (chat-session-messages (test-session-log--session)))
         (results (chat-session-log-filter messages '(:work "tool-result"))))
    (should (equal (length results) 1))
    (should (string-match-p "tool said so"
                            (chat-message-content (car results))))))

(ert-deftest chat-session-log-filters-by-turn ()
  "A turn filter returns one exchange and nothing from the other."
  (let* ((messages (chat-session-messages (test-session-log--session)))
         (turn-2 (chat-session-log-filter messages '(:turn 2))))
    (should (equal (length turn-2) 2))
    (dolist (message turn-2)
      (should (equal (chat-transcript-turn message) 2)))))

(ert-deftest chat-session-log-filters-by-text ()
  "A literal text filter matches content."
  (let* ((messages (chat-session-messages (test-session-log--session)))
         (hits (chat-session-log-filter messages '(:text "second"))))
    (should (equal (length hits) 2))))

(ert-deftest chat-session-log-filters-by-time-range ()
  "A since filter excludes what came before it."
  (let* ((messages (chat-session-messages (test-session-log--session)))
         (future (format-time-string
                  "%Y-%m-%dT%H:%M:%S"
                  (time-add (current-time) 3600))))
    (should-not (chat-session-log-filter
                 messages (list :since future)))
    (should (chat-session-log-filter
             messages (list :until future)))))

(ert-deftest chat-session-log-filter-skips-non-messages ()
  "A stray entry is ignored rather than raising.

A lookup is a diagnostic path; it must not be the thing that fails."
  (let ((messages (cons 'junk
                        (chat-session-messages (test-session-log--session)))))
    (should (chat-session-log-filter messages '(:category "ai-final")))))

;; ------------------------------------------------------------------
;; Grouping
;; ------------------------------------------------------------------

(ert-deftest chat-session-log-render-keeps-a-turn-together ()
  "A question, its steps and its answer render as one block.

Interleaving them by timestamp is what makes a transcript unreadable,
and it is the specific thing this lookup exists to avoid."
  (let* ((messages (chat-session-messages (test-session-log--session)))
         (text (chat-session-log-render-turns
                (chat-transcript-turns messages))))
    (should (string-match-p "=== turn 1 ===" text))
    (should (string-match-p "=== turn 2 ===" text))
    ;; Everything belonging to turn 1 appears before turn 2 begins.
    (let ((turn-2 (string-match "=== turn 2 ===" text)))
      (should (< (string-match "first question" text) turn-2))
      (should (< (string-match "tool said so" text) turn-2))
      (should (< (string-match "first answer" text) turn-2))
      (should (> (string-match "second answer" text) turn-2)))))

(ert-deftest chat-session-log-render-includes-thinking ()
  "Reasoning recorded on a step is visible in a lookup.

It is filtered out of requests, so the record is the only place it can be
read back."
  (let* ((messages (chat-session-messages (test-session-log--session)))
         (text (chat-session-log-render-turns
                (chat-transcript-turns messages))))
    (should (string-match-p "thinking: hmm" text))))

(ert-deftest chat-session-log-render-truncates-a-long-excerpt ()
  "One enormous entry cannot flood a lookup."
  (let* ((chat-session-log-content-max-chars 50)
         (messages (list (test-session-log--message
                          :user (make-string 500 ?x)
                          :turn 1 :step 0 :category 'user)))
         (text (chat-session-log-render-turns
                (chat-transcript-turns messages))))
    (should (string-match-p "truncated" text))
    (should (< (length text) 300))))

;; ------------------------------------------------------------------
;; Lookup
;; ------------------------------------------------------------------

(ert-deftest chat-session-log-lookup-reads-a-saved-session ()
  "The lookup goes to disk, so it sees what the context no longer holds."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (test-session-log--session)))
     (chat-session-save session)
     (let ((text (chat-session-log-lookup
                  '(:session-id "log-test" :category "ai-final"))))
       (should (string-match-p "first answer" text))
       (should (string-match-p "second answer" text))))))

(ert-deftest chat-session-log-lookup-reports-a-missing-session ()
  "An unknown id gets an explanation, not an error."
  (chat-test-with-temp-dir
   (let ((chat-session-directory temp-dir))
     (should (string-match-p
              "No transcript"
              (chat-session-log-lookup '(:session-id "nope")))))))

(ert-deftest chat-session-log-lookup-honours-a-limit ()
  "A limit caps how much a lookup returns."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (test-session-log--session)))
     (chat-session-save session)
     (let ((text (chat-session-log-lookup
                  '(:session-id "log-test" :limit 1))))
       (should (string-match-p "showing the last 1" text))))))

(ert-deftest chat-session-log-tool-takes-positional-arguments ()
  "The tool entry point matches how the caller passes arguments.

Tool arguments are converted to an argv list in parameter order, so a
function expecting a plist silently receives values in the wrong slots."
  (chat-test-with-temp-dir
   (let* ((chat-session-directory temp-dir)
          (session (test-session-log--session)))
     (chat-session-save session)
     (let ((text (chat-session-log-tool nil "ai-final" nil nil nil nil
                                        nil nil "log-test")))
       (should (string-match-p "first answer" text))))))

(provide 'test-chat-session-log)
;;; test-chat-session-log.el ends here
