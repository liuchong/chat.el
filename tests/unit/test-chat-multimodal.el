;;; test-chat-multimodal.el --- Multimodal provider fixtures -*- lexical-binding: t -*-

(require 'ert)
(require 'test-helper)
(require 'chat-session)
(require 'chat-llm)
(require 'chat-llm-claude)
(require 'chat-llm-gemini)

(defmacro chat-multimodal-test--with-message (binding &rest body)
  "Bind BINDING to a text-and-image message while running BODY."
  (declare (indent 1))
  `(chat-test-with-temp-dir
    (let* ((chat-attachment-directory
            (expand-file-name "attachments/" temp-dir))
           (image-file (expand-file-name "fixture.png" temp-dir)))
      (with-temp-file image-file
        (set-buffer-multibyte nil)
        (insert "fixture-image"))
      (let ((,binding
             (make-chat-message
              :id "multimodal-user"
              :role :user
              :content "Describe it"
              :content-parts
              (list (chat-content-text-part "Describe it")
                    (chat-content-attach-file image-file 'image)))))
        ,@body))))

(ert-deftest chat-multimodal-openai-uses-image-url-content-part ()
  "OpenAI-compatible chat receives a base64 data URL beside text."
  (chat-multimodal-test--with-message message
    (let* ((wire (chat-llm--format-one-message message))
           (content (alist-get 'content wire))
           (image (aref content 1))
           (image-url (alist-get 'image_url image)))
      (should (vectorp content))
      (should (equal (alist-get 'type (aref content 0)) "text"))
      (should (equal (alist-get 'type image) "image_url"))
      (should (string-prefix-p "data:image/png;base64,"
                               (alist-get 'url image-url))))))

(ert-deftest chat-multimodal-anthropic-uses-base64-image-source ()
  "Anthropic-compatible messages receive an image source block."
  (chat-multimodal-test--with-message message
    (let* ((content (chat-llm-claude--content-for message))
           (image (aref content 1))
           (source (alist-get 'source image)))
      (should (equal (alist-get 'type image) "image"))
      (should (equal (alist-get 'type source) "base64"))
      (should (equal (alist-get 'media_type source) "image/png"))
      (should (stringp (alist-get 'data source))))))

(ert-deftest chat-multimodal-gemini-uses-inline-data-part ()
  "Gemini receives MIME-labelled inline bytes beside text."
  (chat-multimodal-test--with-message message
    (let* ((request (chat-llm-gemini--build-request (list message) nil))
           (contents (plist-get request :contents))
           (parts (alist-get 'parts (aref contents 0)))
           (inline (alist-get 'inlineData (aref parts 1))))
      (should (equal (alist-get 'mimeType inline) "image/png"))
      (should (stringp (alist-get 'data inline))))))

(ert-deftest chat-multimodal-text-file-degrades-to-named-text ()
  "Plain files remain usable on text-only chat protocols."
  (chat-test-with-temp-dir
   (let* ((chat-attachment-directory
           (expand-file-name "attachments/" temp-dir))
          (file (expand-file-name "notes.txt" temp-dir)))
     (with-temp-file file (insert "important"))
     (let* ((message
             (make-chat-message
              :id "file-user" :role :user :content "Review"
              :content-parts
              (list (chat-content-text-part "Review")
                    (chat-content-attach-file file))))
            (wire (chat-llm--format-one-message message))
            (content (alist-get 'content wire)))
       (should (equal (alist-get 'type (aref content 1)) "text"))
       (should (string-match-p "Attachment: notes.txt"
                               (alist-get 'text (aref content 1))))))))

(ert-deftest chat-multimodal-capability-check-fails-before-dispatch ()
  "Image input is refused when the selected model declares text only."
  (chat-multimodal-test--with-message message
    (let ((chat-model-capabilities--registry nil)
          (chat-model-discovery--cache (make-hash-table :test 'eq))
          (chat-model-discovery--loaded t))
      (chat-model-capabilities-register
       'fixture "text-only" '(:input-modalities (text)) 'user)
      (should-error
       (chat-model-capabilities-validate-messages
        'fixture "text-only" (list message))
       :type 'error))))

(provide 'test-chat-multimodal)
;;; test-chat-multimodal.el ends here
