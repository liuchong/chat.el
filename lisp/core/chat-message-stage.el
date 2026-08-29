;;; chat-message-stage.el --- Structured message staging -*- lexical-binding: t; -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;; Author: chat.el contributors
;; Keywords: chat, message, queue

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A staged message is durable input that has not become a conversation
;; turn yet.  Its stable identity, creation order and attachments survive
;; display reordering and session serialization.  The UI is deliberately
;; kept out of this module so other chat surfaces can reuse the model.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'chat-content)

(defconst chat-message-stage-schema-version 1
  "Current structured staged-message schema.")

(define-error 'chat-message-stage-error "Invalid staged message")
(define-error 'chat-message-stage-position-error
  "Invalid staged-message position"
  'chat-message-stage-error)

(cl-defstruct
    (chat-message-stage-item
     (:constructor chat-message-stage-item-create-record))
  "One durable input item that has not opened a model turn yet."
  schema-version id original-order created-at updated-at text content-parts source)

(defun chat-message-stage-timestamp-ms ()
  "Return the current Unix time in milliseconds."
  (round (* 1000 (float-time))))

(defun chat-message-stage-new-id ()
  "Return a new staged-message identifier."
  (format "stage-%s-%06x"
          (format-time-string "%Y%m%dT%H%M%S%N" nil t)
          (random #x1000000)))

(defun chat-message-stage-create (text original-order &optional content-parts source)
  "Create a staged item for TEXT at ORIGINAL-ORDER.
CONTENT-PARTS are typed attachments and SOURCE names the creating surface."
  (let ((now (chat-message-stage-timestamp-ms)))
    (chat-message-stage-validate
     (chat-message-stage-item-create-record
      :schema-version chat-message-stage-schema-version
      :id (chat-message-stage-new-id)
      :original-order original-order
      :created-at now
      :updated-at now
      :text (or text "")
      :content-parts (chat-content-parts-normalize nil content-parts)
      :source (or source 'chat-ui)))))

(defun chat-message-stage-validate (item)
  "Return ITEM after validating its durable fields."
  (unless (chat-message-stage-item-p item)
    (signal 'chat-message-stage-error (list "Not a staged-message item" item)))
  (unless (= (or (chat-message-stage-item-schema-version item) 0)
             chat-message-stage-schema-version)
    (signal 'chat-message-stage-error
            (list "Unsupported staged-message schema"
                  (chat-message-stage-item-schema-version item))))
  (unless (and (stringp (chat-message-stage-item-id item))
               (not (string-empty-p (chat-message-stage-item-id item))))
    (signal 'chat-message-stage-error (list "Missing staged-message ID")))
  (unless (and (integerp (chat-message-stage-item-original-order item))
               (> (chat-message-stage-item-original-order item) 0))
    (signal 'chat-message-stage-error
            (list "Original order must be a positive integer")))
  (unless (and (integerp (chat-message-stage-item-created-at item))
               (>= (chat-message-stage-item-created-at item) 0)
               (integerp (chat-message-stage-item-updated-at item))
               (>= (chat-message-stage-item-updated-at item) 0))
    (signal 'chat-message-stage-error (list "Invalid staged-message timestamp")))
  (unless (stringp (chat-message-stage-item-text item))
    (signal 'chat-message-stage-error (list "Staged text must be a string")))
  (setf (chat-message-stage-item-content-parts item)
        (chat-content-parts-normalize
         nil (chat-message-stage-item-content-parts item)))
  item)

(defun chat-message-stage-item-to-json (item)
  "Return JSON-friendly data for staged ITEM."
  (setq item (chat-message-stage-validate item))
  `((schemaVersion . ,(chat-message-stage-item-schema-version item))
    (id . ,(chat-message-stage-item-id item))
    (originalOrder . ,(chat-message-stage-item-original-order item))
    (createdAt . ,(chat-message-stage-item-created-at item))
    (updatedAt . ,(chat-message-stage-item-updated-at item))
    (text . ,(chat-message-stage-item-text item))
    (contentParts . ,(mapcar #'chat-content-part-to-json
                             (chat-message-stage-item-content-parts item)))
    (source . ,(format "%s" (chat-message-stage-item-source item)))))

(defun chat-message-stage-item-from-json (data)
  "Decode current-schema DATA into a staged item."
  (cond
   ((chat-message-stage-item-p data)
    (chat-message-stage-validate data))
   ((listp data)
    (chat-message-stage-validate
     (chat-message-stage-item-create-record
      :schema-version (or (alist-get 'schemaVersion data) 0)
      :id (alist-get 'id data)
      :original-order (alist-get 'originalOrder data)
      :created-at (or (alist-get 'createdAt data) 0)
      :updated-at (or (alist-get 'updatedAt data) 0)
      :text (or (alist-get 'text data) "")
      :content-parts (mapcar #'chat-content-part-from-json
                             (append (alist-get 'contentParts data) nil))
      :source (let ((source (alist-get 'source data)))
                (if (and (stringp source) (not (string-empty-p source)))
                    (intern source)
                  'chat-ui)))))
   (t
    (signal 'chat-message-stage-error
            (list "Unsupported staged-message representation" data)))))

(defun chat-message-stage-items-from-json (stored)
  "Decode current-schema staged records from list or vector STORED."
  (mapcar #'chat-message-stage-item-from-json (append stored nil)))

(defun chat-message-stage-items-to-json (items)
  "Return JSON-friendly records for ITEMS."
  (mapcar #'chat-message-stage-item-to-json items))

(defun chat-message-stage-next-original-order (items)
  "Return the next never-reused original order after ITEMS."
  (1+ (seq-reduce
       #'max
       (mapcar #'chat-message-stage-item-original-order items)
       0)))

(defun chat-message-stage--position-index (items position &optional insertion)
  "Return zero-based index for one-based POSITION in ITEMS.
When INSERTION is non-nil, a position just after the last item is valid."
  (let ((limit (+ (length items) (if insertion 1 0))))
    (unless (and (integerp position) (> position 0) (<= position limit))
      (signal 'chat-message-stage-position-error
              (list position (length items))))
    (1- position)))

(defun chat-message-stage-edit (items position text)
  "Return ITEMS with the item at POSITION changed to TEXT."
  (let* ((copy (copy-sequence items))
         (index (chat-message-stage--position-index copy position))
         (item (copy-chat-message-stage-item (nth index copy))))
    (setf (chat-message-stage-item-text item) text
          (chat-message-stage-item-updated-at item)
          (chat-message-stage-timestamp-ms))
    (setf (nth index copy) (chat-message-stage-validate item))
    copy))

(defun chat-message-stage-remove (items position)
  "Return (REMOVED . REMAINING) for POSITION in ITEMS."
  (let* ((index (chat-message-stage--position-index items position))
         (removed (nth index items)))
    (cons removed
          (append (seq-take items index) (seq-drop items (1+ index))))))

(defun chat-message-stage-move (items from-position to-position)
  "Move the item at FROM-POSITION to TO-POSITION in ITEMS."
  (chat-message-stage--position-index items from-position)
  (chat-message-stage--position-index items to-position)
  (let* ((removed (chat-message-stage-remove items from-position))
         (item (car removed))
         (remaining (cdr removed))
         (target (1- to-position)))
    (append (seq-take remaining target)
            (list item)
            (seq-drop remaining target))))

(defun chat-message-stage-texts (items)
  "Return the text projection of ITEMS."
  (mapcar #'chat-message-stage-item-text items))

(defun chat-message-stage-joined-text (items)
  "Return ITEMS as one provider-portable user message."
  (let ((texts (chat-message-stage-texts items)))
    (if (cdr texts)
        (string-join
         (seq-map-indexed (lambda (text index)
                            (format "%d. %s" (1+ index) text))
                          texts)
         "\n\n")
      (car texts))))

(defun chat-message-stage-content-parts (items)
  "Return all non-text content parts attached to ITEMS, in display order."
  (apply #'append
         (mapcar (lambda (item)
                   (copy-sequence
                    (chat-message-stage-item-content-parts item)))
                 items)))

(defun chat-message-stage-batch-metadata (items)
  "Return message metadata preserving the staged provenance of ITEMS."
  (list :staged-message-schema-version chat-message-stage-schema-version
        :staged-message-count (length items)
        :staged-message-ids
        (vconcat (mapcar #'chat-message-stage-item-id items))
        :staged-message-original-orders
        (vconcat (mapcar #'chat-message-stage-item-original-order items))
        :staged-message-created-at-ms
        (vconcat (mapcar #'chat-message-stage-item-created-at items))))

(provide 'chat-message-stage)
;;; chat-message-stage.el ends here
