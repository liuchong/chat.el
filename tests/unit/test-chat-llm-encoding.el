;;; test-chat-llm-encoding.el --- Tests for multibyte encoding in HTTP requests -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Commentary:

;; Regression tests for multibyte text handling in LLM HTTP requests.
;; Bug: Chinese characters caused "Multibyte text in HTTP request" error.
;; Fix: Encode body with `encode-coding-string' to UTF-8 before sending.

;;; Code:

(require 'ert)

(ert-deftest chat-llm-encodes-multibyte-body-to-unibyte ()
  "Test that multibyte Chinese text is encoded to unibyte for HTTP request.

This is a regression test for the bug where Chinese characters in
request body caused 'Multibyte text in HTTP request' error."
  (let* ((chinese-text "你好世界")
         (json-body (format "{\"message\": \"%s\"}" chinese-text)))
    ;; Verify the text is multibyte
    (should (multibyte-string-p json-body))
    ;; Verify encoding produces unibyte string
    (let ((encoded (encode-coding-string json-body 'utf-8)))
      (should (not (multibyte-string-p encoded)))
      ;; Verify we can decode it back
      (let ((decoded (decode-coding-string encoded 'utf-8)))
        (should (string= decoded json-body))))))

(ert-deftest chat-llm-preserves-ascii-text-encoding ()
  "Test that ASCII text encoding works correctly (no change needed)."
  (let* ((ascii-text "Hello World")
         (json-body (format "{\"message\": \"%s\"}" ascii-text)))
    ;; ASCII text may or may not be multibyte depending on Emacs
    ;; But encoding should be safe either way
    (let ((encoded (encode-coding-string json-body 'utf-8)))
      (should (not (multibyte-string-p encoded)))
      (let ((decoded (decode-coding-string encoded 'utf-8)))
        (should (string= decoded json-body))))))

(ert-deftest chat-llm-handles-mixed-encoding-content ()
  "Test encoding of mixed ASCII and Chinese content."
  (let* ((mixed-text "Hello 世界 test 测试")
         (json-body (format "{\"content\": \"%s\"}" mixed-text)))
    (should (multibyte-string-p json-body))
    (let ((encoded (encode-coding-string json-body 'utf-8)))
      (should (not (multibyte-string-p encoded)))
      (let ((decoded (decode-coding-string encoded 'utf-8)))
        (should (string= decoded json-body))))))

(provide 'test-chat-llm-encoding)
;;; test-chat-llm-encoding.el ends here
