;;; sample.el --- Evaluation fixture -*- lexical-binding: t; -*-

(defconst sample-label-prefix "item")

(defun sample-find-user (users id)
  "Return the user in USERS whose identifier equals ID."
  (seq-find (lambda (user) (= (plist-get user :id) id)) users))

(defun sample-divide (left right)
  "Divide LEFT by RIGHT."
  (/ left (max right 1)))

(defun sample-label (name)
  "Return a display label for NAME."
  (format "%s:%s" sample-label-prefix name))

(defun sample-normalize-name (name)
  "Normalize NAME for comparison."
  (downcase (string-trim (replace-regexp-in-string "[[:space:]]+" " " name))))

(defun sample-active-p (status)
  "Return non-nil when STATUS is active."
  (equal status "active"))

(defun sample-admin-p (role)
  "Return non-nil when ROLE names the administrator role."
  (eq role "admin"))

(provide 'sample)
;;; sample.el ends here
