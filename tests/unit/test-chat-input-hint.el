;;; test-chat-input-hint.el --- Passive input hint tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'chat-input-hint)

(defun chat-input-hint-test--candidate (name &optional frequency)
  "Return a test candidate named NAME with FREQUENCY."
  (make-chat-input-hint-candidate
   :key name :completion name :display (concat "/" name)
   :annotation "" :frequency frequency))

(ert-deftest chat-input-hint-filters-sorts-and-bounds-candidates ()
  (let* ((chat-input-hint-sort-order 'alphabetical)
         (model (make-chat-input-hint-model
                 :prefix "s"
                 :candidates
                 (list (chat-input-hint-test--candidate "stage")
                       (chat-input-hint-test--candidate "help")
                       (chat-input-hint-test--candidate "send")
                       (chat-input-hint-test--candidate "save"))))
         (visible (chat-input-hint-visible-candidates model 2)))
    (should (equal (mapcar #'chat-input-hint-candidate-display visible)
                   '("/save" "/send")))))

(ert-deftest chat-input-hint-frequency-ties-fall-back-to-lexical-order ()
  (let* ((chat-input-hint-sort-order 'frequency)
         (model (make-chat-input-hint-model
                 :prefix ""
                 :candidates
                 (list (chat-input-hint-test--candidate "stage" 2)
                       (chat-input-hint-test--candidate "send" 5)
                       (chat-input-hint-test--candidate "save" 2)
                       (chat-input-hint-test--candidate "help" 0))))
         (visible (chat-input-hint-visible-candidates model)))
    (should (equal (mapcar #'chat-input-hint-candidate-display visible)
                   '("/send" "/save" "/stage" "/help")))))

(ert-deftest chat-input-hint-limit-is-hard-capped-at-ten ()
  (let* ((model (make-chat-input-hint-model
                 :prefix ""
                 :candidates
                 (mapcar (lambda (number)
                           (chat-input-hint-test--candidate
                            (format "command-%02d" number)))
                         (number-sequence 1 20)))))
    (should (= 10 (length (chat-input-hint-visible-candidates model 99))))))

(ert-deftest chat-input-hint-placement-prefers-below-then-above ()
  (should (equal (chat-input-hint-placement 4 5 9) '(below . 4)))
  (should (equal (chat-input-hint-placement 4 2 8) '(above . 4)))
  (should (equal (chat-input-hint-placement 8 3 2) '(below . 3)))
  (should (equal (chat-input-hint-placement 8 1 3) '(above . 3))))

(ert-deftest chat-input-hint-overlay-is-display-only-and-focus-free ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *chat-input-hint-test*")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (insert "/s")
            (goto-char (point-max))
            (let ((before (buffer-string))
                  (before-point (point))
                  (before-start (window-start)))
              (setq-local
               chat-input-hint-providers
               (list
                (lambda ()
                  (make-chat-input-hint-model
                   :source 'test :prefix "s"
                   :anchor-start (point-min) :anchor-end (point-max)
                   :candidates
                   (list (chat-input-hint-test--candidate "send")
                         (chat-input-hint-test--candidate "stage"))))))
              (chat-input-hint-refresh)
              (should (overlayp chat-input-hint--overlay))
              (should-not (overlay-get chat-input-hint--overlay 'keymap))
              (should-not (overlay-get chat-input-hint--overlay 'mouse-face))
              (should (equal before (buffer-string)))
              (should (= before-point (point)))
              (should (= before-start (window-start)))
              (chat-input-hint-clear)
              (should-not chat-input-hint--overlay)))
        (kill-buffer buffer)))))

;;; test-chat-input-hint.el ends here
