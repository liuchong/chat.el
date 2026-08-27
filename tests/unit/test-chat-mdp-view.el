;;; test-chat-mdp-view.el --- Visible MDP readings -*- lexical-binding: t; -*-

;;; Commentary:

;; The codec is useful without a UI, but a person needs one command that
;; makes the human and machine readings comparable.

;;; Code:

(require 'ert)
(require 'chat-mdp-view)

(ert-deftest chat-mdp-view-shows-both-readings ()
  "A quoted number and a number must look different to the machine."
  (let ((view (chat-mdp-view-render
               "Some prose.\n\n- count: 28\n- label: \"28\"")))
    (should (string-match-p "MDP Document View" view))
    (should (string-match-p "Some prose" view))
    (should (string-match-p "MDP Machine View" view))
    (should (string-match-p "count: number 28" view))
    (should (string-match-p "label: string \"28\"" view))))

(ert-deftest chat-mdp-view-makes-parse-errors-visible ()
  (let ((view (chat-mdp-view-render "## Orphan")))
    (should (string-match-p "MDP Parse Error" view))
    (should (string-match-p "MDP-E001" view))
    (should (string-match-p "line 1" view))))

(ert-deftest chat-mdp-view-keeps-the-machine-reading-fixed-pitch ()
  (let* ((view (chat-mdp-view-render "- a: 1"))
         (at (string-match "a: number" view))
         (face (get-text-property at 'face view))
         (faces (if (listp face) face (list face))))
    (should (memq 'chat-mdp-view-machine faces))))

(ert-deftest chat-mdp-view-does-not-paint-a-background-panel ()
  (should (eq 'unspecified
              (face-attribute 'chat-mdp-view-machine :background nil nil))))

(ert-deftest chat-mdp-preview-is-an-interactive-command ()
  (should (commandp 'chat-mdp-preview-region)))

(provide 'test-chat-mdp-view)
;;; test-chat-mdp-view.el ends here
