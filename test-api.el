#!/usr/bin/env emacs -Q --script
;;; test-api.el --- Standalone API test for chat.el

;; Load required libraries
(require 'url)
(require 'json)

;; Configuration
(defvar test-api-key nil "API key for testing")
(defvar test-base-url "https://api.moonshot.cn/v1")
(defvar test-model "moonshot-v1-8k")

;; Read API key from config file if exists
(let ((config-file (expand-file-name "chat-config.local.el")))
  (when (file-exists-p config-file)
    (load config-file nil t)))

(setq test-api-key (or chat-llm-kimi-api-key
                       (getenv "KIMI_API_KEY")
                       (error "No API key found. Set chat-llm-kimi-api-key or KIMI_API_KEY")))

(message "=== API Test Started ===")
(message "Base URL: %s" test-base-url)
(message "Model: %s" test-model)
(message "API Key: %s..." (substring test-api-key 0 (min 10 (length test-api-key))))

;; Test 1: Direct url-retrieve-synchronously
(message "\n=== Test 1: Synchronous HTTP Request ===")
(let* ((url-request-method "POST")
       (url-request-extra-headers
        `(("Content-Type" . "application/json")
          ("Authorization" . ,(format "Bearer %s" test-api-key))))
       (url-request-data
        (json-encode
         `((model . ,test-model)
           (messages . [((role . "user") (content . "Hello, this is a test"))])
           (temperature . 0.7))))
       (start-time (float-time))
       response-buffer)
  (message "Request body: %s" url-request-data)
  (condition-case err
      (progn
        (setq response-buffer
              (with-timeout (30 (error "Request timeout"))
                (url-retrieve-synchronously 
                 (concat test-base-url "/chat/completions")
                 nil t 30)))
        (message "Request completed in %.2f seconds" (- (float-time) start-time))
        (when response-buffer
          (unwind-protect
              (with-current-buffer response-buffer
                (goto-char (point-min))
                (message "Raw response header:\n%s" 
                         (buffer-substring (point) (min (point-max) (+ (point) 500))))
                (if (re-search-forward "\n\n" nil t)
                    (let ((body (buffer-substring (point) (point-max))))
                      (message "Response body: %s" body)
                      (let ((json (json-read-from-string body)))
                        (message "Parsed JSON: %S" json)
                        (if-let ((err-obj (cdr (assoc 'error json))))
                            (message "API ERROR: %S" err-obj)
                          (let* ((choices (cdr (assoc 'choices json)))
                                 (first (aref choices 0))
                                 (msg (cdr (assoc 'message first)))
                                 (content (cdr (assoc 'content msg))))
                            (message "SUCCESS! Content: %s" content)))))
                  (message "ERROR: Could not find response body")))
            (kill-buffer response-buffer))))
    (error
     (message "ERROR: %s" (error-message-string err)))))

;; Test 2: Test in thread context
(message "\n=== Test 2: Request inside make-thread ===")
(let ((thread-result nil)
      (thread-error nil)
      (thread-done nil))
  (make-thread
   (lambda ()
     (message "[Thread] Starting request...")
     (condition-case err
         (let* ((url-request-method "POST")
                (url-request-extra-headers
                 `(("Content-Type" . "application/json")
                   ("Authorization" . ,(format "Bearer %s" test-api-key))))
                (url-request-data
                 (json-encode
                  `((model . ,test-model)
                    (messages . [((role . "user") (content . "Test from thread"))])
                    (temperature . 0.7))))
                (start-time (float-time))
                (response-buffer (with-timeout (30 (error "Timeout"))
                                   (url-retrieve-synchronously 
                                    (concat test-base-url "/chat/completions")
                                    nil t 30))))
           (message "[Thread] Request completed in %.2f seconds" 
                    (- (float-time) start-time))
           (when response-buffer
             (with-current-buffer response-buffer
               (goto-char (point-min))
               (re-search-forward "\n\n" nil t)
               (setq thread-result (buffer-substring (point) (point-max))))
             (kill-buffer response-buffer))
           (setq thread-done t))
       (error
        (setq thread-error (error-message-string err))
        (setq thread-done t)))))
  
  (message "Main: Waiting for thread...")
  (with-timeout (35 (message "Main: Thread wait timeout"))
    (while (not thread-done)
      (sleep-for 0.1)))
  
  (if thread-error
      (message "Thread ERROR: %s" thread-error)
    (message "Thread SUCCESS: %s" 
             (if thread-result 
                 (substring thread-result 0 (min 100 (length thread-result)))
               "no result"))))

(message "\n=== API Test Complete ===")
