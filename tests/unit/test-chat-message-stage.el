;;; test-chat-message-stage.el --- Structured message staging tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'chat-message-stage)

(ert-deftest chat-message-stage-round-trip-preserves-identity-and-order ()
  "Serialization does not turn display order into durable identity."
  (let* ((left (chat-message-stage-create "left" 7))
         (right (chat-message-stage-create "right" 8))
         (loaded (chat-message-stage-items-from-json
                  (chat-message-stage-items-to-json (list left right)))))
    (should (equal (mapcar #'chat-message-stage-item-id loaded)
                   (mapcar #'chat-message-stage-item-id (list left right))))
    (should (equal (mapcar #'chat-message-stage-item-original-order loaded)
                   '(7 8)))
    (should (equal (chat-message-stage-texts loaded) '("left" "right")))))

(ert-deftest chat-message-stage-round-trip-preserves-typed-attachments ()
  (let* ((digest (make-string 64 ?a))
         (part (chat-content-part-create
                :type 'image :attachment-id digest :name "screen.png"
                :mime-type "image/png" :size 12 :sha256 digest))
         (item (chat-message-stage-create "inspect" 1 (list part)))
         (loaded (car (chat-message-stage-items-from-json
                       (chat-message-stage-items-to-json (list item)))))
         (loaded-part (car (chat-message-stage-item-content-parts loaded))))
    (should (eq (chat-content-part-type loaded-part) 'image))
    (should (equal (chat-content-part-attachment-id loaded-part) digest))))

(ert-deftest chat-message-stage-refuses-unstructured-string-records ()
  "The stage has one current schema and no format guessing."
  (should-error (chat-message-stage-items-from-json ["one" "two"])
                :type 'chat-message-stage-error))

(ert-deftest chat-message-stage-edit-and-move-preserve-stable-fields ()
  "Editing and display reordering do not impersonate new input."
  (let* ((left (chat-message-stage-create "left" 11))
         (right (chat-message-stage-create "right" 12))
         (left-id (chat-message-stage-item-id left))
         (edited (chat-message-stage-edit (list left right) 1 "changed"))
         (moved (chat-message-stage-move edited 1 2)))
    (should (equal (chat-message-stage-texts moved) '("right" "changed")))
    (should (equal (chat-message-stage-item-id (cadr moved)) left-id))
    (should (= (chat-message-stage-item-original-order (cadr moved)) 11))))

(ert-deftest chat-message-stage-removes-an-arbitrary-display-position ()
  (let* ((items (list (chat-message-stage-create "one" 1)
                      (chat-message-stage-create "two" 2)
                      (chat-message-stage-create "three" 3)))
         (removed (chat-message-stage-remove items 2)))
    (should (equal (chat-message-stage-item-text (car removed)) "two"))
    (should (equal (chat-message-stage-texts (cdr removed)) '("one" "three")))))

(ert-deftest chat-message-stage-refuses-an-unknown-future-schema ()
  (should-error
   (chat-message-stage-item-from-json
    '((schemaVersion . 999)
      (id . "future")
      (originalOrder . 1)
      (createdAt . 1)
      (updatedAt . 1)
      (text . "future")))
   :type 'chat-message-stage-error))

;;; test-chat-message-stage.el ends here
