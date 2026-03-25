;;; test-chat-tool-forge.el --- Tests for tool forge -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;; Author: chat.el contributors
;; Keywords: tests

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Unit tests for tool forging functionality.

;;; Code:

(require 'ert)
(require 'test-helper)
(require 'chat-tool-forge)

;; ------------------------------------------------------------------
;; Tool Structure
;; ------------------------------------------------------------------

(ert-deftest chat-forged-tool-structure-works ()
  "Test that forged tool struct can be created."
  (let ((tool (make-chat-forged-tool
               :id 'test-tool
               :name "Test Tool"
               :description "A test tool"
               :language 'elisp
               :source-code "(defun test () \"hello\")")))
    (should (chat-forged-tool-p tool))
    (should (eq (chat-forged-tool-id tool) 'test-tool))
    (should (string= (chat-forged-tool-name tool) "Test Tool"))
    (should (eq (chat-forged-tool-language tool) 'elisp))))

;; ------------------------------------------------------------------
;; Tool Registry
;; ------------------------------------------------------------------

(ert-deftest chat-tool-forge-register-adds-tool ()
  "Test registering a tool adds it to registry."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir))
     (let ((tool (make-chat-forged-tool
                 :id 'my-tool
                 :name "My Tool"
                 :language 'elisp
                 :source-code "(lambda () t)")))
       (chat-tool-forge-register tool)
       (should (chat-tool-forge-get 'my-tool))))))

(ert-deftest chat-tool-forge-does-not-save-tool-without-source ()
  "Test registering a built in tool does not write an empty file."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir))
     (chat-tool-forge-register
      (make-chat-forged-tool
       :id 'built-in-tool
       :name "Built In Tool"
       :language 'elisp
       :compiled-function (lambda () "ok")
       :is-active t
       :usage-count 0))
     (should-not (file-exists-p (expand-file-name "built-in-tool.el" temp-dir))))))

(ert-deftest chat-tool-forge-loads-tool-with-empty-source ()
  "Test loading a saved tool that has no source body."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (chat-tool-forge--registry (make-hash-table :test 'eq)))
     (with-temp-file (expand-file-name "empty-tool.el" temp-dir)
       (insert ";;; chat-tool: empty-tool\n")
       (insert ";;; name: Empty Tool\n")
       (insert ";;; description: Empty tool\n")
       (insert ";;; language: elisp\n")
       (insert ";;; version: 1.0.0\n")
       (insert ";;; created: 2026-03-25T00:00:00\n"))
     (chat-tool-forge-load-all)
     (let ((tool (chat-tool-forge-get 'empty-tool)))
       (should tool)
       (should (null (chat-forged-tool-source-code tool)))))))

(ert-deftest chat-tool-forge-unload-removes-tool ()
  "Test unloading a tool removes it from registry."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir))
     (let ((tool (make-chat-forged-tool
                 :id 'temp-tool
                 :name "Temp"
                 :language 'elisp
                 :source-code "(lambda () t)")))
       (chat-tool-forge-register tool)
       (should (chat-tool-forge-get 'temp-tool))
       (chat-tool-forge-unload 'temp-tool)
       (should-not (chat-tool-forge-get 'temp-tool))))))

;; ------------------------------------------------------------------
;; Tool Execution
;; ------------------------------------------------------------------

(ert-deftest chat-tool-forge-execute-elisp-tool ()
  "Test executing an Emacs Lisp tool."
  ;; Test the execution path directly
  (let* ((func (lambda (a b) (+ a b)))
         (tool (make-chat-forged-tool
                :id 'test-add
                :name "Test Add"
                :language 'elisp
                :compiled-function func
                :is-active t
                :usage-count 0)))
    ;; Register without saving to avoid temp dir issues
    (puthash 'test-add tool chat-tool-forge--registry)
    ;; Execute
    (let ((result (chat-tool-forge-execute 'test-add '(1 2))))
      (should (= result 3))
      (should (= (chat-forged-tool-usage-count tool) 1)))
    ;; Cleanup
    (remhash 'test-add chat-tool-forge--registry)))

(ert-deftest chat-tool-forge-compile-rejects-non-lambda-form ()
  "Test tool compilation rejects forms other than a single lambda."
  (let ((tool (make-chat-forged-tool
               :id 'bad-tool
               :name "Bad Tool"
               :language 'elisp
               :source-code "(progn (message \"side effect\") (lambda () t))")))
    (should-error (chat-tool-forge--compile-elisp tool))))

(ert-deftest chat-tool-forge-compile-rejects-multiple-top-level-forms ()
  "Test tool compilation rejects multiple top level forms."
  (let ((tool (make-chat-forged-tool
               :id 'bad-tool
               :name "Bad Tool"
               :language 'elisp
               :source-code "(lambda () t)\n(lambda () nil)")))
    (should-error (chat-tool-forge--compile-elisp tool))))

;; ------------------------------------------------------------------
;; Tool Discovery
;; ------------------------------------------------------------------

(ert-deftest chat-tool-forge-list-returns-tools ()
  "Test listing registered tools."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir)
         (tool-a (make-chat-forged-tool
                 :id 'tool-a :name "A" :language 'elisp
                 :source-code "(lambda () t)"))
         (tool-b (make-chat-forged-tool
                 :id 'tool-b :name "B" :language 'elisp
                 :source-code "(lambda () t)")))
     (chat-tool-forge-register tool-a)
     (chat-tool-forge-register tool-b)
     (let ((tools (chat-tool-forge-list)))
       (should (>= (length tools) 2))
       (should (cl-find 'tool-a tools :key #'chat-forged-tool-id))
       (should (cl-find 'tool-b tools :key #'chat-forged-tool-id))))))

(provide 'test-chat-tool-forge)
;;; test-chat-tool-forge.el ends here
