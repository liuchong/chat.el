;;; test-chat-content.el --- Typed content and attachment tests -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-content)

(ert-deftest chat-content-old-text-normalizes-to-one-typed-part ()
  "Legacy string content gains a text projection without migration code."
  (let ((parts (chat-content-parts-normalize "hello" nil)))
    (should (= (length parts) 1))
    (should (eq (chat-content-part-type (car parts)) 'text))
    (should (equal (chat-content-parts-text parts) "hello"))))

(ert-deftest chat-content-part-json-round-trip-keeps-versioned-fields ()
  "Typed parts preserve their contract across JSON-shaped data."
  (let* ((part (chat-content-text-part "hello" '((language . "en"))))
         (loaded (chat-content-part-from-json
                  (chat-content-part-to-json part))))
    (should (= (chat-content-part-schema-version loaded) 1))
    (should (eq (chat-content-part-type loaded) 'text))
    (should (equal (chat-content-part-text loaded) "hello"))
    (should (equal (chat-content-part-metadata loaded)
                   '((language . "en"))))))

(ert-deftest chat-content-part-refuses-a-future-schema ()
  "A newer content part is not guessed into the current contract."
  (should-error
   (chat-content-part-from-json
    '((schemaVersion . 999) (type . "text") (text . "future")))
   :type 'chat-content-unsupported-schema))

(ert-deftest chat-content-attachment-store-is-durable-and-deduplicated ()
  "Equal attachment bytes resolve to one content-addressed payload."
  (chat-test-with-temp-dir
   (let* ((chat-attachment-directory (expand-file-name "attachments/" temp-dir))
          (source-a (expand-file-name "a.txt" temp-dir))
          (source-b (expand-file-name "b.txt" temp-dir)))
     (with-temp-file source-a (insert "same bytes"))
     (with-temp-file source-b (insert "same bytes"))
     (let ((left (chat-content-attach-file source-a))
           (right (chat-content-attach-file source-b)))
       (should (eq (chat-content-part-type left) 'file))
       (should (equal (chat-content-part-attachment-id left)
                      (chat-content-part-attachment-id right)))
       (should (file-regular-p (chat-content-part-file left)))
       (should (equal (chat-content-part-file-text left) "same bytes"))))))

(ert-deftest chat-content-attachment-limit-fails-before-copying ()
  "Oversized input is rejected before it enters durable storage."
  (chat-test-with-temp-dir
   (let* ((chat-attachment-directory (expand-file-name "attachments/" temp-dir))
          (chat-attachment-max-bytes 3)
          (source (expand-file-name "large.txt" temp-dir)))
     (with-temp-file source (insert "four"))
     (should-error (chat-content-attach-file source)
                   :type 'chat-content-attachment-too-large)
     (should-not (file-directory-p chat-attachment-directory)))))

(ert-deftest chat-content-attachment-id-cannot-escape-the-store ()
  "A session cannot turn an attachment reference into an arbitrary file read."
  (should-error
   (chat-content-part-validate
    (chat-content-part-create
     :type 'file :attachment-id "../../etc/passwd" :name "passwd"
     :mime-type "text/plain" :size 1 :sha256 "../../etc/passwd"))
   :type 'chat-content-invalid-part))

(ert-deftest chat-content-resolve-rejects-a-size-mismatch ()
  "A changed or forged payload is rejected before request encoding reads it."
  (chat-test-with-temp-dir
   (let* ((chat-attachment-directory (expand-file-name "attachments/" temp-dir))
          (source (expand-file-name "stable.txt" temp-dir)))
     (with-temp-file source (insert "stable"))
     (let ((part (chat-content-attach-file source)))
       (setf (chat-content-part-size part) 999)
       (should-error (chat-content-part-file part)
                     :type 'chat-content-invalid-part)))))

(ert-deftest chat-content-resolve-rejects-an-equal-size-digest-mismatch ()
  "Content-addressed payloads reject equal-size tampering before encoding."
  (chat-test-with-temp-dir
   (let* ((chat-attachment-directory (expand-file-name "attachments/" temp-dir))
          (source (expand-file-name "stable.txt" temp-dir)))
     (with-temp-file source (insert "stable"))
     (let* ((part (chat-content-attach-file source))
            (stored (chat-content-attachment-path
                     (chat-content-part-attachment-id part))))
       (with-temp-file stored (insert "forged"))
       (should (= (chat-content-part-size part)
                  (chat-content--file-size stored)))
       (should-error (chat-content-part-file part)
                     :type 'chat-content-invalid-part)))))

(provide 'test-chat-content)
;;; test-chat-content.el ends here
