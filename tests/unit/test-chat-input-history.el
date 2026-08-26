;;; test-chat-input-history.el --- Tests for input recall -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:

;; The chat surface had no input history at all: `M-p' was unbound and
;; `chat-ui-previous-message' printed "not yet implemented".  These cover
;; the ring, its persistence, and the two things that separate usable
;; recall from annoying recall -- a draft that survives entering the ring,
;; and a position that is per buffer rather than global.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-input-history)

(defmacro test-history--with-store (&rest body)
  "Run BODY against an empty history kept in a temporary file."
  `(chat-test-with-temp-dir
    (let ((chat-input-history nil)
          (chat-input-history--loaded t)
          (chat-input-history-max 200)
          (chat-input-history-file
           (expand-file-name "input-history.eld" temp-dir)))
      ,@body)))

;; ------------------------------------------------------------------
;; The ring
;; ------------------------------------------------------------------

(ert-deftest chat-input-history-remembers-what-was-sent ()
  "Newest first, which is the order recall walks."
  (test-history--with-store
   (chat-input-history-add "first")
   (chat-input-history-add "second")
   (should (equal (chat-input-history-entries) '("second" "first")))))

(ert-deftest chat-input-history-ignores-blank-input ()
  "Whitespace is not a question anyone wants back."
  (test-history--with-store
   (chat-input-history-add "   ")
   (chat-input-history-add "")
   (should (null (chat-input-history-entries)))))

(ert-deftest chat-input-history-collapses-an-immediate-repeat ()
  "Sending the same line twice should not cost two slots."
  (test-history--with-store
   (chat-input-history-add "same")
   (chat-input-history-add "same")
   (should (equal (chat-input-history-entries) '("same")))))

(ert-deftest chat-input-history-keeps-a-repeat-that-is-not-adjacent ()
  "Coming back to a question later is a real entry."
  (test-history--with-store
   (chat-input-history-add "a")
   (chat-input-history-add "b")
   (chat-input-history-add "a")
   (should (equal (chat-input-history-entries) '("a" "b" "a")))))

(ert-deftest chat-input-history-stops-growing-at-the-limit ()
  "A ring with no ceiling is a file that grows forever."
  (test-history--with-store
   (let ((chat-input-history-max 3))
     (dolist (text '("1" "2" "3" "4" "5"))
       (chat-input-history-add text))
     (should (equal (chat-input-history-entries) '("5" "4" "3"))))))

(ert-deftest chat-input-history-trims-what-it-stores ()
  "Trailing newlines from the input area are not part of the question."
  (test-history--with-store
   (chat-input-history-add "  ask this  ")
   (should (equal (chat-input-history-entries) '("ask this")))))

;; ------------------------------------------------------------------
;; Persistence
;; ------------------------------------------------------------------

(ert-deftest chat-input-history-survives-a-restart ()
  "The point of a file is to still be there next time."
  (test-history--with-store
   (chat-input-history-add "remembered")
   (let ((chat-input-history nil)
         (chat-input-history--loaded nil))
     (should (equal (chat-input-history-entries) '("remembered"))))))

(ert-deftest chat-input-history-survives-a-corrupt-file ()
  "An unreadable history costs a recall; signalling costs the session."
  (test-history--with-store
   (with-temp-file chat-input-history-file
     (insert "(this is not . a well formed"))
   (let ((chat-input-history nil)
         (chat-input-history--loaded nil))
     (should (null (chat-input-history-entries))))))

(ert-deftest chat-input-history-rejects-a-file-of-the-wrong-shape ()
  "A list of non-strings is not a history, however well formed."
  (test-history--with-store
   (with-temp-file chat-input-history-file
     (insert "(1 2 3)"))
   (let ((chat-input-history nil)
         (chat-input-history--loaded nil))
     (should (null (chat-input-history-entries))))))

;; ------------------------------------------------------------------
;; Walking it
;; ------------------------------------------------------------------

(defun test-history--walker ()
  "Return a getter and setter over one string, as the input area would be."
  (let ((text ""))
    (list (lambda () text)
          (lambda (new) (setq text (or new "")))
          (lambda () text))))

(ert-deftest chat-input-history-walks-back-and-forth ()
  "M-p goes older, M-n goes newer, repeatedly."
  (test-history--with-store
   (dolist (text '("oldest" "middle" "newest"))
     (chat-input-history-add text))
   (with-temp-buffer
     (let* ((w (test-history--walker))
            (get (nth 0 w)) (set (nth 1 w)) (peek (nth 2 w)))
       (chat-input-history-walk 1 get set)
       (should (equal (funcall peek) "newest"))
       (chat-input-history-walk 1 get set)
       (should (equal (funcall peek) "middle"))
       (chat-input-history-walk 1 get set)
       (should (equal (funcall peek) "oldest"))
       (chat-input-history-walk -1 get set)
       (should (equal (funcall peek) "middle"))))))

(ert-deftest chat-input-history-stops-at-the-oldest-entry ()
  "Walking past the end stays put rather than wrapping to the newest."
  (test-history--with-store
   (chat-input-history-add "only")
   (with-temp-buffer
     (let* ((w (test-history--walker))
            (get (nth 0 w)) (set (nth 1 w)) (peek (nth 2 w)))
       (chat-input-history-walk 1 get set)
       (chat-input-history-walk 1 get set)
       (chat-input-history-walk 1 get set)
       (should (equal (funcall peek) "only"))))))

(ert-deftest chat-input-history-gives-the-draft-back ()
  "A half-written line is not lost to a stray M-p.

Walking out of the ring past the newest entry restores whatever was being
typed when the walk began."
  (test-history--with-store
   (chat-input-history-add "sent earlier")
   (with-temp-buffer
     (let* ((text "half written thought")
            (get (lambda () text))
            (set (lambda (new) (setq text (or new "")))))
       (chat-input-history-walk 1 get set)
       (should (equal text "sent earlier"))
       (chat-input-history-walk -1 get set)
       (should (equal text "half written thought"))))))

(ert-deftest chat-input-history-position-is-per-buffer ()
  "Walking history in one session must not move another's cursor."
  (test-history--with-store
   (chat-input-history-add "a")
   (chat-input-history-add "b")
   (let ((one (generate-new-buffer " *one*"))
         (two (generate-new-buffer " *two*")))
     (unwind-protect
         (let* ((w (test-history--walker))
                (get (nth 0 w)) (set (nth 1 w)))
           (with-current-buffer one
             (chat-input-history-walk 1 get set)
             (chat-input-history-walk 1 get set)
             (should (= chat-input-history--position 1)))
           (with-current-buffer two
             (should-not chat-input-history--position)))
       (kill-buffer one)
       (kill-buffer two)))))

(ert-deftest chat-input-history-walking-an-empty-ring-does-nothing ()
  "Nothing to recall is not an error."
  (test-history--with-store
   (with-temp-buffer
     (let* ((w (test-history--walker))
            (get (nth 0 w)) (set (nth 1 w)) (peek (nth 2 w)))
       (should-not (chat-input-history-walk 1 get set))
       (should (equal (funcall peek) ""))))))

(provide 'test-chat-input-history)
;;; test-chat-input-history.el ends here
