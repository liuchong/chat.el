;;; test-chat-model-capabilities.el --- Model capability tests -*- lexical-binding: t -*-

;; Copyright (C) 2026 chat.el contributors

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'chat-llm)
(require 'chat-model-capabilities)

(defmacro test-chat-model-capabilities--isolated (&rest body)
  "Evaluate BODY with private provider and capability state."
  (declare (indent 0))
  `(let ((chat-llm-providers nil)
         (chat-llm-enabled-providers nil)
         (chat-model-capabilities--registry nil)
         (chat-model-discovery--cache (make-hash-table :test 'eq))
         (chat-model-discovery--loaded t)
         (chat-model-discovery-cache-file nil))
     ,@body))

(ert-deftest chat-model-capabilities-preserve-unknown-as-a-fact ()
  "Missing declarations remain unknown rather than becoming false."
  (test-chat-model-capabilities--isolated
    (chat-llm-register-provider 'caps-unknown :model "m")
    (let ((caps (chat-model-capabilities-resolve 'caps-unknown "m")))
      (should (eq (chat-model-capabilities-stream caps) 'unknown))
      (should (eq (chat-model-capabilities-tools caps) 'unknown)))))

(ert-deftest chat-model-capabilities-resolve-source-priority ()
  "User facts outrank discovery, model static facts and fallback facts."
  (test-chat-model-capabilities--isolated
    (chat-llm-register-provider
     'caps-priority :model "m" :capabilities '(:tools nil))
    (chat-model-capabilities-register
     'caps-priority "m" '(:tools t) 'static)
    (chat-model-capabilities-register
     'caps-priority "m" '(:tools nil) 'discovered)
    (chat-model-capabilities-register
     'caps-priority "m" '(:tools t) 'user)
    ;; Provider refreshes must not erase explicit user declarations.
    (chat-model-capabilities-register-provider
     'caps-priority '(:model "m" :capabilities (:tools nil)))
    (let ((caps (chat-model-capabilities-resolve 'caps-priority "m")))
      (should (eq (chat-model-capabilities-tools caps) t))
      (should (eq (chat-model-capabilities-source caps) 'user)))))

(ert-deftest chat-model-capabilities-reject-known-incompatibilities ()
  "Known unsupported request features fail before transport dispatch."
  (test-chat-model-capabilities--isolated
    (chat-llm-register-provider
     'caps-strict :model "m"
     :capabilities
     '(:stream nil :tools nil :tool-choice nil :reasoning nil
       :input-modalities (text) :structured-output nil
       :max-output-tokens 100))
    (dolist (options
             '((:stream t)
               (:tools [((type . "function"))])
               (:tool-choice "auto")
               (:reasoning t)
               (:modalities (text image))
               (:response-format json-object)
               (:max-tokens 101)))
      (should-error
       (chat-model-capabilities-prepare-options
        'caps-strict "m" options)))))

(ert-deftest chat-model-capabilities-remove-ignored-sampling-controls ()
  "A provider declaration can remove controls it is known to ignore."
  (test-chat-model-capabilities--isolated
    (chat-llm-register-provider
     'caps-options :model "m"
     :capabilities '(:supported-options (:max-tokens)))
    (let ((prepared
           (chat-model-capabilities-prepare-options
            'caps-options "m"
            '(:temperature 0 :top-p 0.5 :frequency-penalty 1
              :max-tokens 20))))
      (should-not (plist-member prepared :temperature))
      (should-not (plist-member prepared :top-p))
      (should-not (plist-member prepared :frequency-penalty))
      (should (= (plist-get prepared :max-tokens) 20)))))

(ert-deftest chat-model-discovery-round-trips-versioned-cache ()
  "Discovered model facts survive a cache write and reload."
  (test-chat-model-capabilities--isolated
    (let ((file (make-temp-file "chat-model-cache-")))
      (unwind-protect
          (let ((chat-model-discovery-cache-file file))
            (chat-model-discovery-update
             'caps-cache
             '((:id "dynamic-model" :capabilities (:tools t)))
             600)
            (setq chat-model-capabilities--registry nil
                  chat-model-discovery--cache (make-hash-table :test 'eq)
                  chat-model-discovery--loaded nil)
            (chat-model-discovery-load-cache)
            (should (equal (chat-model-discovery-models 'caps-cache)
                           '("dynamic-model")))
            (should
             (eq t
                 (chat-model-capabilities-tools
                  (chat-model-capabilities-resolve
                   'caps-cache "dynamic-model")))))
        (delete-file file)))))

(ert-deftest chat-model-discovery-rejects-future-cache-schema ()
  "A newer cache schema is rejected without changing live state."
  (test-chat-model-capabilities--isolated
    (let ((file (make-temp-file "chat-model-future-")))
      (unwind-protect
          (let ((chat-model-discovery-cache-file file)
                (chat-model-discovery--loaded nil))
            (with-temp-file file
              (insert "{\"schemaVersion\":999,\"entries\":[]}"))
            (should-error (chat-model-discovery-load-cache)
                          :type 'chat-model-discovery-unsupported-schema)
            (should-not chat-model-discovery--loaded)
            (should (= (hash-table-count chat-model-discovery--cache) 0)))
        (delete-file file)))))

(ert-deftest chat-model-discovery-uses-provider-hook-and-cache ()
  "Dynamic discovery stores provider results behind the stable API."
  (test-chat-model-capabilities--isolated
    (let (answer)
      (chat-llm-register-provider
       'caps-discovery :models '("static")
       :discover-models-fn
       (lambda (_provider success _error)
         (funcall success
                  '((:id "live" :capabilities (:reasoning t))) 600)))
      (chat-model-discovery-request
       'caps-discovery
       (lambda (models source) (setq answer (list models source))))
      (should (eq (cadr answer) 'discovered))
      (should (equal (plist-get (car (car answer)) :id) "live"))
      (should (equal (chat-model-discovery-models 'caps-discovery)
                     '("live"))))))

(provide 'test-chat-model-capabilities)
;;; test-chat-model-capabilities.el ends here
