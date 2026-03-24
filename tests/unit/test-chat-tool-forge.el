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
                 :source-code "(defun my-tool () t)")))
       (chat-tool-forge-register tool)
       (should (chat-tool-forge-get 'my-tool))))))

(ert-deftest chat-tool-forge-unload-removes-tool ()
  "Test unloading a tool removes it from registry."
  (chat-test-with-temp-dir
   (let ((chat-tool-forge-directory temp-dir))
     (let ((tool (make-chat-forged-tool
                 :id 'temp-tool
                 :name "Temp"
                 :language 'elisp
                 :source-code "(defun temp () t)")))
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
