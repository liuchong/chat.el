;;; chat-content.el --- Typed message content and attachments -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors
;; License: 1PL (One Public License) - https://license.pub/1pl/

;;; Commentary:

;; Message text remains available as a compatibility projection, while this
;; module owns typed content parts and durable attachment references.  Binary
;; payloads live outside session JSONL files and are addressed by content hash.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'mailcap)
(require 'seq)
(require 'subr-x)

(defgroup chat-content nil
  "Typed message content and durable attachments."
  :group 'chat)

(defconst chat-content-part-schema-version 1
  "Current typed content part schema version.")

(defconst chat-content-part-types
  '(text image file reasoning tool-call tool-result)
  "Content part types understood by the runtime.")

(defcustom chat-attachment-directory
  (expand-file-name "attachments/" (expand-file-name "~/.chat/"))
  "Content-addressed attachment storage directory."
  :type 'directory
  :group 'chat-content)

(defcustom chat-attachment-max-bytes (* 25 1024 1024)
  "Largest file copied into the local attachment store."
  :type 'integer
  :group 'chat-content)

(define-error 'chat-content-unsupported-schema
  "Unsupported content part schema")
(define-error 'chat-content-invalid-part "Invalid content part")
(define-error 'chat-content-attachment-too-large "Attachment is too large")
(define-error 'chat-content-attachment-missing "Attachment payload is missing")

(cl-defstruct
    (chat-content-part
     (:constructor
      chat-content-part-create
      (&key (schema-version chat-content-part-schema-version)
            type text attachment-id name mime-type size sha256 metadata)))
  "One versioned message content part."
  schema-version type text attachment-id name mime-type size sha256 metadata)

(defun chat-content--symbol (value)
  "Return VALUE as a symbol when possible."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))))

(defun chat-content--safe-display-string-p (value)
  "Return non-nil when VALUE is a nonempty string without control bytes."
  (and (stringp value)
       (not (string-empty-p value))
       (cl-every (lambda (character)
                   (and (>= character 32) (/= character 127)))
                 value)))

(defun chat-content--safe-name (name)
  "Return NAME with control characters replaced for transcript display."
  (let ((safe (apply #'string
                     (mapcar (lambda (character)
                               (if (or (< character 32) (= character 127))
                                   ?_
                                 character))
                             (string-to-list name)))))
    (if (string-empty-p safe) "attachment" safe)))

(defun chat-content-part-validate (part)
  "Validate and return PART."
  (unless (chat-content-part-p part)
    (signal 'chat-content-invalid-part (list part)))
  (let ((version (chat-content-part-schema-version part))
        (type (chat-content--symbol (chat-content-part-type part))))
    (when (> version chat-content-part-schema-version)
      (signal 'chat-content-unsupported-schema (list version)))
    (unless (= version chat-content-part-schema-version)
      (signal 'chat-content-invalid-part (list "schemaVersion" version)))
    (unless (memq type chat-content-part-types)
      (signal 'chat-content-invalid-part (list "type" type)))
    (setf (chat-content-part-type part) type)
    (pcase type
      ((or 'text 'reasoning 'tool-result)
       (unless (stringp (chat-content-part-text part))
         (signal 'chat-content-invalid-part (list type "requires text"))))
      ((or 'image 'file)
       (let ((attachment-id (chat-content-part-attachment-id part)))
         (unless (and (stringp attachment-id)
                      (string-match-p "\\`[0-9a-f]\\{64\\}\\'" attachment-id)
                      (equal attachment-id (chat-content-part-sha256 part))
                      (chat-content--safe-display-string-p
                       (chat-content-part-name part))
                      (chat-content--safe-display-string-p
                       (chat-content-part-mime-type part))
                      (integerp (chat-content-part-size part))
                      (>= (chat-content-part-size part) 0))
           (signal 'chat-content-invalid-part
                   (list type "requires a content-addressed attachment")))))))
  part)

(defun chat-content-text-part (text &optional metadata)
  "Return a validated text part for TEXT and optional METADATA."
  (chat-content-part-validate
   (chat-content-part-create :type 'text :text text :metadata metadata)))

(defun chat-content-part-to-json (part)
  "Return JSON-friendly data for PART."
  (chat-content-part-validate part)
  `((schemaVersion . ,(chat-content-part-schema-version part))
    (type . ,(symbol-name (chat-content-part-type part)))
    (text . ,(chat-content-part-text part))
    (attachmentId . ,(chat-content-part-attachment-id part))
    (name . ,(chat-content-part-name part))
    (mimeType . ,(chat-content-part-mime-type part))
    (size . ,(chat-content-part-size part))
    (sha256 . ,(chat-content-part-sha256 part))
    (metadata . ,(chat-content-part-metadata part))))

(defun chat-content-part-from-json (data)
  "Return a validated content part decoded from DATA."
  (chat-content-part-validate
   (chat-content-part-create
    :schema-version (or (alist-get 'schemaVersion data) 0)
    :type (chat-content--symbol (alist-get 'type data))
    :text (alist-get 'text data)
    :attachment-id (alist-get 'attachmentId data)
    :name (alist-get 'name data)
    :mime-type (alist-get 'mimeType data)
    :size (alist-get 'size data)
    :sha256 (alist-get 'sha256 data)
    :metadata (alist-get 'metadata data))))

(defun chat-content-parts-normalize (content parts)
  "Return validated PARTS, falling back to text CONTENT."
  (let ((parts (cond ((vectorp parts) (append parts nil))
                     ((listp parts) parts)
                     ((null parts) nil)
                     (t (list parts)))))
    (if parts
        (mapcar (lambda (part)
                  (chat-content-part-validate
                   (if (chat-content-part-p part)
                       part
                     (chat-content-part-from-json part))))
                parts)
      (when (stringp content)
        (list (chat-content-text-part content))))))

(defun chat-content-parts-text (parts)
  "Return the ordinary text projection of PARTS."
  (mapconcat
   #'identity
   (delq nil
         (mapcar (lambda (part)
                   (when (eq (chat-content-part-type part) 'text)
                     (chat-content-part-text part)))
                 parts))
   ""))

(defun chat-content-parts-with-text (parts text)
  "Return PARTS with ordinary text parts replaced by TEXT."
  (let ((non-text
         (seq-remove (lambda (part)
                       (eq (chat-content-part-type part) 'text))
                     parts)))
    (if (string-empty-p (or text ""))
        non-text
      (cons (chat-content-text-part text) non-text))))

(defun chat-content-parts-modalities (parts)
  "Return the distinct input modalities required by PARTS."
  (delete-dups
   (mapcar (lambda (part)
             (pcase (chat-content-part-type part)
               ('image 'image)
               ('file 'file)
               (_ 'text)))
           parts)))

(defun chat-content--file-size (file)
  "Return FILE size in bytes, signaling when it is unavailable."
  (let ((attributes (file-attributes file 'string)))
    (unless (and attributes (not (eq t (car attributes))))
      (error "Attachment is not a regular file: %s" file))
    (file-attribute-size attributes)))

(defun chat-content--file-sha256 (file)
  "Return FILE's SHA-256 digest after its size has been bounded."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun chat-content--mime-type (file)
  "Return a best-effort MIME type for FILE."
  (or (and-let* ((extension (file-name-extension file)))
        (mailcap-extension-to-mime (downcase extension)))
      "application/octet-stream"))

(defun chat-content-attachment-path (attachment-id)
  "Return the local payload path for ATTACHMENT-ID."
  (expand-file-name "content"
                    (expand-file-name attachment-id
                                      chat-attachment-directory)))

(defun chat-content-part-file (part)
  "Return PART's local attachment path, signaling when it is absent."
  (chat-content-part-validate part)
  (let ((file (chat-content-attachment-path
               (chat-content-part-attachment-id part))))
    (unless (file-regular-p file)
      (signal 'chat-content-attachment-missing
              (list (chat-content-part-attachment-id part) file)))
    (let ((actual-size (chat-content--file-size file)))
      (unless (and (= actual-size (chat-content-part-size part))
                   (<= actual-size chat-attachment-max-bytes))
        (signal 'chat-content-invalid-part
                (list "attachment size mismatch"
                      (chat-content-part-size part) actual-size)))
      (let ((actual-sha256 (chat-content--file-sha256 file)))
        (unless (equal actual-sha256
                       (chat-content-part-attachment-id part))
          (signal 'chat-content-invalid-part
                  (list "attachment digest mismatch"
                        (chat-content-part-attachment-id part)
                        actual-sha256)))))
    file))

(defun chat-content-attach-file (file &optional type)
  "Copy FILE into durable storage and return an image or file part.

TYPE may be `image' or `file'.  When omitted it is inferred from MIME type."
  (let* ((file (expand-file-name file))
         (size (chat-content--file-size file)))
    (when (> size chat-attachment-max-bytes)
      (signal 'chat-content-attachment-too-large
              (list file size chat-attachment-max-bytes)))
    (let* ((mime-type (chat-content--mime-type file))
           (type (or type
                     (if (string-prefix-p "image/" mime-type)
                         'image
                       'file))))
      (unless (memq type '(image file))
        (signal 'chat-content-invalid-part (list "attachment type" type)))
      (make-directory chat-attachment-directory t)
      (let ((temp (make-temp-file
                   (expand-file-name ".attachment-"
                                     chat-attachment-directory))))
        (unwind-protect
            (progn
              ;; Address the copied snapshot, not a source that may change
              ;; between hashing and copying.
              (copy-file file temp t)
              (let ((stored-size (chat-content--file-size temp)))
                (when (> stored-size chat-attachment-max-bytes)
                  (signal 'chat-content-attachment-too-large
                          (list file stored-size chat-attachment-max-bytes)))
                (let* ((sha256 (chat-content--file-sha256 temp))
                       (target (chat-content-attachment-path sha256))
                       (part
                        (chat-content-part-validate
                         (chat-content-part-create
                          :type type
                          :attachment-id sha256
                          :name (chat-content--safe-name
                                 (file-name-nondirectory file))
                          :mime-type mime-type
                          :size stored-size
                          :sha256 sha256))))
                  (make-directory (file-name-directory target) t)
                  (unless (file-exists-p target)
                    (rename-file temp target t))
                  (chat-content-part-file part)
                  part)))
          (when (file-exists-p temp)
            (delete-file temp)))))))

(defun chat-content-part-base64 (part)
  "Return PART's attachment payload as unibyte base64 text."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally (chat-content-part-file part))
    (base64-encode-string (buffer-string) t)))

(defun chat-content-part-text-file-p (part)
  "Return non-nil when file PART can be represented as text."
  (and (eq (chat-content-part-type part) 'file)
       (let ((mime (chat-content-part-mime-type part)))
         (or (string-prefix-p "text/" mime)
             (member mime '("application/json"
                            "application/xml"
                            "application/javascript"))))))

(defun chat-content-part-file-text (part)
  "Return textual attachment PART as a decoded string."
  (unless (chat-content-part-text-file-p part)
    (error "Attachment is not a text file: %s"
           (chat-content-part-name part)))
  (with-temp-buffer
    (insert-file-contents (chat-content-part-file part))
    (buffer-string)))

(defun chat-content-part-file-prompt (part)
  "Return textual file PART as a named prompt block."
  (format "Attachment: %s\n\n%s"
          (chat-content-part-name part)
          (chat-content-part-file-text part)))

(defun chat-content-part-required-modality (part)
  "Return the model input modality required by PART."
  (pcase (chat-content-part-type part)
    ('image 'image)
    ('file (if (chat-content-part-text-file-p part) 'text 'file))
    (_ 'text)))

(provide 'chat-content)
;;; chat-content.el ends here
