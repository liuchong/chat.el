;;; test-chat-mdp.el --- Reading and writing MDP -*- lexical-binding: t; -*-

;;; Commentary:

;; The test that matters most is the one about fenced blocks: a payload has
;; to be able to contain an example of itself, because that is what lets a
;; model paste a sample into a reply without the sample becoming data.
;;
;; The second is the round trip, which is where representing `false', `[]',
;; `null' and `{}' all as `nil' would show up -- the reason those are four
;; distinct values here and not one.
;;
;; Spec 006, against the protocol specification's own worked example.

;;; Code:

(require 'ert)
(require 'chat-mdp)

(defconst test-mdp--flat-payload
  "- mdp: \"1.0\"
- type: response
- id: task-20260721-001
- status: success

# User

本次任务的用户主数据。**注意：Agent 收到后需先校验 region。**

- name: 张三
- age: 28
- region: cn-hangzhou
- vip: true
- balance: 128.5
- avatar: null
- nickname: \"123\"

## Address

收货地址，仅当需要物流时使用。

- province: 浙江
- city: 杭州

# Orders

近 30 天订单，按创建时间倒序。amount 单位为分。

| order_id | amount | status | created_at |
| -------- | ------ | ------ | ---------- |
| A-1001   | 9900   | paid   | 2026-07-01 |
| A-1002   | 300    | refund | 2026-07-03 |

# OrderSummary

- total: 2
- refunded: 1
"
  "The worked example from the protocol specification, §9.1.")

;; ------------------------------------------------------------------
;; The whole of it
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-the-specifications-own-example-parses ()
  "Field order is kept, prose is ignored, and types come out as declared."
  (let ((value (chat-mdp-parse test-mdp--flat-payload)))
    (should-not (chat-mdp-error-p value))
    (should (equal '("mdp" "type" "id" "status" "User" "Orders"
                     "OrderSummary")
                   (mapcar #'car value)))
    (should (equal "1.0" (cdr (assoc "mdp" value))))
    (let ((user (cdr (assoc "User" value))))
      (should (equal "张三" (cdr (assoc "name" user))))
      (should (equal 28 (cdr (assoc "age" user))))
      (should (eq t (cdr (assoc "vip" user))))
      (should (equal 128.5 (cdr (assoc "balance" user))))
      (should (eq :null (cdr (assoc "avatar" user))))
      ;; Quoted, so a string that looks like a number stays a string.
      (should (equal "123" (cdr (assoc "nickname" user))))
      ;; A second-level heading is a field of the section it sits in.
      (should (equal '(("province" . "浙江") ("city" . "杭州"))
                     (cdr (assoc "Address" user)))))
    (should (equal '((("order_id" . "A-1001") ("amount" . 9900)
                      ("status" . "paid") ("created_at" . "2026-07-01"))
                     (("order_id" . "A-1002") ("amount" . 300)
                      ("status" . "refund") ("created_at" . "2026-07-03")))
                   (cdr (assoc "Orders" value))))))

;; ------------------------------------------------------------------
;; Comments
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-a-fenced-block-is-skipped-whole ()
  "Even when it contains whitelist syntax.
This is the rule that decides whether a model can paste an example of a
payload into a payload."
  (let ((value (chat-mdp-parse "- real: 1

```markdown
- fake: 2

# NotASection

| a | b |
| - | - |
| 1 | 2 |
```

- also-real: 3")))
    (should (equal '(("real" . 1) ("also-real" . 3)) value))))

(ert-deftest chat-mdp-a-tilde-fence-is-skipped-too ()
  (should (equal '(("a" . 1))
                 (chat-mdp-parse "- a: 1\n~~~\n- b: 2\n~~~"))))

(ert-deftest chat-mdp-prose-cannot-affect-the-result ()
  "Which is the whole reason for preferring this to JSON: the apology a
model puts in front of its answer is allowed to be there."
  (let ((with-prose "Sure, here is what you asked for.

### Some notes

I checked the *thing* and it looked `fine`. See [docs](http://x).

> A quoted aside.

1. an ordered item
* a starred item
- a plain remark
- key:value

---

<!-- an html comment -->

- a: 1
"))
    (should (equal '(("a" . 1)) (chat-mdp-parse with-prose)))))

(ert-deftest chat-mdp-comments-do-not-break-a-nesting ()
  "Blank lines and prose between nested fields leave the nesting alone."
  (should (equal '(("outer" . (("inner" . 1) ("other" . 2))))
                 (chat-mdp-parse "- outer:

  Some prose in the middle.

  - inner: 1

  ### A heading that is a comment

  - other: 2"))))

;; ------------------------------------------------------------------
;; Types
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-the-type-ladder-is-in-order ()
  (should (equal "001" (chat-mdp--infer "\"001\"")))
  (should (equal 42 (chat-mdp--infer "42")))
  (should (equal -3.14 (chat-mdp--infer "-3.14")))
  (should (eq t (chat-mdp--infer "true")))
  (should (eq :false (chat-mdp--infer "false")))
  (should (eq :null (chat-mdp--infer "null")))
  (should (eq :null (chat-mdp--infer "")))
  (should (eq :empty-object (chat-mdp--infer "{}")))
  (should (eq nil (chat-mdp--infer "[]")))
  (should (equal "2026-07-21" (chat-mdp--infer "2026-07-21"))))

(ert-deftest chat-mdp-a-literal-is-only-a-literal-in-lowercase ()
  "Or `NULL', a perfectly good identifier, would become an absent value."
  (should (equal "True" (chat-mdp--infer "True")))
  (should (equal "NULL" (chat-mdp--infer "NULL")))
  (should (equal "FALSE" (chat-mdp--infer "FALSE"))))

(ert-deftest chat-mdp-what-does-not-match-the-number-grammar-is-a-string ()
  "So a zero-padded identifier stays an identifier."
  (dolist (text '("001" "+5" ".5" "1." "1e" "0x10"))
    (should (equal text (chat-mdp--infer text)))))

(ert-deftest chat-mdp-an-unclosed-quote-is-its-own-text ()
  "The only reading that loses nothing."
  (should (equal "\"abc" (chat-mdp--infer "\"abc"))))

(ert-deftest chat-mdp-the-five-escapes-resolve-and-the-rest-do-not ()
  (should (equal "a\"b" (chat-mdp--infer "\"a\\\"b\"")))
  (should (equal "a\nb" (chat-mdp--infer "\"a\\nb\"")))
  (should (equal "a\tb" (chat-mdp--infer "\"a\\tb\"")))
  (should (equal "a\\b" (chat-mdp--infer "\"a\\\\b\"")))
  ;; Anything else keeps both characters: refusing it would be brittle
  ;; over a Windows path and resolving it would invent an escape.
  (should (equal "C:\\dir" (chat-mdp--infer "\"C:\\dir\""))))

(ert-deftest chat-mdp-a-quoted-string-keeps-its-spaces ()
  (should (equal "  padded  " (chat-mdp--infer "\"  padded  \""))))

;; ------------------------------------------------------------------
;; Tables
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-a-single-column-table-is-an-array-of-scalars ()
  "The header names the column; it is not data."
  (should (equal '(("Section" . (("tags" . ("a" "b" 3)))))
                 (chat-mdp-parse "# Section

- tags:
  | tag |
  | --- |
  | a   |
  | b   |
  | 3   |"))))

(ert-deftest chat-mdp-an-empty-cell-means-the-key-is-absent ()
  "Not that its value is null: `null' has to be written."
  (let* ((value (chat-mdp-parse "# S

| a | b |
| - | - |
| 1 |   |
| 2 | null |"))
         (rows (cdr (assoc "S" value))))
    (should (equal '(("a" . 1)) (nth 0 rows)))
    (should (equal '(("a" . 2) ("b" . :null)) (nth 1 rows)))))

(ert-deftest chat-mdp-a-cell-is-not-interpreted-as-markdown ()
  (let* ((value (chat-mdp-parse "# S

| a |
| - |
| `x` |"))
         (rows (cdr (assoc "S" value))))
    (should (equal '("`x`") rows))))

(ert-deftest chat-mdp-an-escaped-pipe-is-a-pipe ()
  (should (equal '("a|b") (cdr (assoc "S" (chat-mdp-parse "# S

| x |
| - |
| a\\|b |"))))))

(ert-deftest chat-mdp-a-table-with-no-rows-is-an-empty-array ()
  (should (equal '(("S" . nil))
                 (chat-mdp-parse "# S\n\n| a | b |\n| - | - |"))))

;; ------------------------------------------------------------------
;; Element markers
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-element-markers-make-an-array-of-objects ()
  (should (equal '(("methods" . ((("name" . "searchRooms"))
                                 (("name" . "makeReservation")))))
                 (chat-mdp-parse "# methods

- :
  - name: searchRooms
- :
  - name: makeReservation"))))

(ert-deftest chat-mdp-an-inline-element-is-a-scalar ()
  "Scalars and objects mixing in one sequence is the only way the format
has of expressing a heterogeneous array."
  (let ((value (chat-mdp-parse "# items

- : 1
- :
  - k: v
- : \"two\"")))
    (should (equal '(1 (("k" . "v")) "two") (cdr (assoc "items" value))))))

(ert-deftest chat-mdp-one-element-marker-is-an-array-of-one ()
  "Distinguishable from a single object, which is the point of having it."
  (should (equal '(("a" . ((("k" . 1)))))
                 (chat-mdp-parse "# a\n\n- :\n  - k: 1"))))

;; ------------------------------------------------------------------
;; Containers
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-a-container-with-nothing-under-it-is-null ()
  (should (equal '(("a" . :null) ("b" . 1))
                 (chat-mdp-parse "- a:\n- b: 1")))
  (should (equal '(("a" . :null)) (chat-mdp-parse "- a:"))))

(ert-deftest chat-mdp-a-section-with-nothing-in-it-is-an-empty-object ()
  "Where a container with nothing is null.  The difference is in the
specification, and it is why an empty object needs a keyword of its own:
an empty alist is `nil' too."
  (should (equal '(("S" . :empty-object)) (chat-mdp-parse "# S"))))

(ert-deftest chat-mdp-nesting-goes-as-deep-as-it-is-written ()
  (should (equal '(("a" . (("b" . (("c" . 1))))))
                 (chat-mdp-parse "- a:\n  - b:\n    - c: 1"))))

;; ------------------------------------------------------------------
;; Errors
;; ------------------------------------------------------------------

(defun test-mdp--code (text)
  "Return the error code parsing TEXT reports, or nil."
  (let ((value (chat-mdp-parse text)))
    (and (chat-mdp-error-p value) (chat-mdp-error-code value))))

(defun test-mdp--line (text)
  "Return the line parsing TEXT blames."
  (chat-mdp-error-line (chat-mdp-parse text)))

(ert-deftest chat-mdp-every-illegal-construction-has-a-code ()
  "And a line number, because what a rejection is for is telling the
model which line to correct."
  ;; A level-two heading before any level-one heading.
  (should (eq 'MDP-E001 (test-mdp--code "## Orphan")))
  ;; Object content and a table in the same place.
  (should (eq 'MDP-E002 (test-mdp--code "# S\n\n- a: 1\n\n| x |\n| - |")))
  ;; The same key twice in one object.
  (should (eq 'MDP-E003 (test-mdp--code "- a: 1\n- a: 2")))
  ;; A row with the wrong number of cells.
  (should (eq 'MDP-E004 (test-mdp--code "# S\n\n| a | b |\n| - | - |\n| 1 |")))
  ;; An empty or repeated header cell.
  (should (eq 'MDP-E005 (test-mdp--code "# S\n\n| a | a |\n| - | - |")))
  (should (eq 'MDP-E005 (test-mdp--code "# S\n\n| a |  |\n| - | - |")))
  ;; A bare table in the preamble has no section to be the value of.
  (should (eq 'MDP-E006 (test-mdp--code "| a |\n| - |\n| 1 |")))
  ;; An element marker at the root has neither a section nor a container.
  (should (eq 'MDP-E006 (test-mdp--code "- :\n  - a: 1")))
  ;; An empty heading.
  (should (eq 'MDP-E007 (test-mdp--code "#")))
  (should (eq 'MDP-E007 (test-mdp--code "##   ")))
  ;; A tab indent, a skipped level, and depth under a leaf.
  (should (eq 'MDP-E009 (test-mdp--code "- a:\n\t- b: 1")))
  (should (eq 'MDP-E009 (test-mdp--code "- a:\n    - b: 1")))
  (should (eq 'MDP-E009 (test-mdp--code "- a: 1\n  - b: 2"))))

(ert-deftest chat-mdp-an-error-blames-the-right-line ()
  (should (= 4 (test-mdp--line "- a: 1\n\nprose\n- a: 2")))
  (should (= 1 (test-mdp--line "## Orphan"))))

(ert-deftest chat-mdp-an-error-says-what-it-means ()
  (let ((message (chat-mdp-error-message (chat-mdp-parse "## Orphan"))))
    (should (string-match-p "MDP-E001" message))
    (should (string-match-p "line 1" message))
    (should (string-match-p "level-one" message))))

(ert-deftest chat-mdp-rejects-input-beyond-its-character-budget ()
  "Model output cannot turn one parse into an unbounded allocation."
  (let ((chat-mdp-max-input-chars 8))
    (should (eq 'MDP-E010 (test-mdp--code "- a: 1234")))
    (should (= 1 (test-mdp--line "- a: 1234")))))

(ert-deftest chat-mdp-rejects-nesting-beyond-its-depth-budget ()
  (let ((chat-mdp-max-depth 1)
        (text "- a:\n  - b:\n    - c: 1"))
    (should (eq 'MDP-E010 (test-mdp--code text)))
    (should (= 3 (test-mdp--line text)))))

(ert-deftest chat-mdp-many-distinct-fields-keep-their-order ()
  "Duplicate detection stays linear as the object grows."
  (let* ((count 1500)
         (text (mapconcat (lambda (index)
                            (format "- key-%04d: %d" index index))
                          (number-sequence 0 (1- count)) "\n"))
         (value (chat-mdp-parse text)))
    (should-not (chat-mdp-error-p value))
    (should (= count (length value)))
    (should (equal "key-0000" (caar value)))
    (should (equal "key-1499" (car (car (last value)))))))

;; ------------------------------------------------------------------
;; Round trip
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-encoding-then-parsing-gives-the-value-back ()
  "Where representing `false', `[]', `null' and `{}' as `nil' would show
up: the encoder would not know which of the four to write."
  (dolist (value '((("a" . 1))
                   (("a" . "text"))
                   (("a" . t) ("b" . :false))
                   (("a" . :null) ("b" . :empty-object) ("c" . nil))
                   (("a" . (("b" . (("c" . 1))))))
                   (("a" . (1 2 3)))
                   (("a" . ((("k" . 1)) (("k" . 2)))))
                   (("a" . (1 (("k" . "v")) "two")))
                   (("n" . 128.5) ("m" . -3))
                   (("quoted" . "123") ("literal" . "true"))
                   (("padded" . "  spaces  ") ("empty" . ""))
                   (("multi" . "a\nb") ("tabbed" . "a\tb"))
                   (("cjk" . "张三"))))
    (let ((text (chat-mdp-encode value)))
      (should (equal value (chat-mdp-parse text))))))

(ert-deftest chat-mdp-a-round-trip-of-the-worked-example-holds ()
  "Values, not text: comments are dropped when parsing and no encoder
can put them back."
  (let ((value (chat-mdp-parse test-mdp--flat-payload)))
    (should (equal value (chat-mdp-parse (chat-mdp-encode value))))))

(ert-deftest chat-mdp-the-canonical-form-is-what-is-written ()
  "One space after the dash and after the colon, two spaces per level,
and a container line ending at its colon."
  (should (equal "- a: 1\n- b:\n  - c: 2\n"
                 (chat-mdp-encode '(("a" . 1) ("b" . (("c" . 2)))))))
  (should (equal "- a:\n  - : 1\n  - : 2\n"
                 (chat-mdp-encode '(("a" . (1 2)))))))

(ert-deftest chat-mdp-a-string-is-quoted-only-when-it-has-to-be ()
  "A payload where every string is quoted is harder to read, and being
easy to read is the entire point of the format."
  (should (equal "- a: hello world\n"
                 (chat-mdp-encode '(("a" . "hello world")))))
  (should (equal "- a: \"123\"\n" (chat-mdp-encode '(("a" . "123")))))
  (should (equal "- a: \"true\"\n" (chat-mdp-encode '(("a" . "true")))))
  (should (equal "- a: \"\"\n" (chat-mdp-encode '(("a" . ""))))))

(ert-deftest chat-mdp-a-document-is-an-object ()
  (should-error (chat-mdp-encode '(1 2 3)))
  (should-error (chat-mdp-encode "text")))

(ert-deftest chat-mdp-structured-tool-results-normalize-to-canonical-mdp ()
  "Elisp tool values become the same bounded representation models parse."
  (let* ((encoded
          (chat-mdp-encode-tool-result
           '(:status opened
             :path "src/main.el"
             :location (:line 7 :column 3)
             :edits ((:path "a.el" :changed t)
                     (:path "b.el" :changed :json-false)))))
         (parsed (chat-mdp-parse encoded)))
    (should encoded)
    (should
     (equal
      '(("status" . "opened")
        ("path" . "src/main.el")
        ("location" . (("line" . 7) ("column" . 3)))
        ("edits" . ((("path" . "a.el") ("changed" . t))
                     (("path" . "b.el") ("changed" . :false)))))
      parsed))
    (should (equal encoded (chat-mdp-encode parsed)))))

(ert-deftest chat-mdp-structured-tool-result-rejects-duplicate-object-keys ()
  (should-not
   (chat-mdp-encode-tool-result
    '(("status" . "first") ("status" . "second")))))

(ert-deftest chat-mdp-structured-tool-result-keeps-symbol-lists-as-arrays ()
  (should
   (equal '(("result" . ("pending" "complete")))
          (chat-mdp-parse
           (chat-mdp-encode-tool-result '(pending complete))))))

(ert-deftest chat-mdp-structured-tool-result-hash-order-is-deterministic ()
  (let ((left (make-hash-table :test 'equal))
        (right (make-hash-table :test 'equal)))
    (puthash "z" 1 left)
    (puthash "a" 2 left)
    (puthash "a" 2 right)
    (puthash "z" 1 right)
    (should (equal (chat-mdp-encode-tool-result left)
                   (chat-mdp-encode-tool-result right)))
    (should (equal '("a" "z")
                   (mapcar #'car
                           (chat-mdp-parse
                            (chat-mdp-encode-tool-result left)))))))

(ert-deftest chat-mdp-tool-result-encoding-is-bounded-and-structured-only ()
  (should-not (chat-mdp-encode-tool-result "plain text"))
  (let ((cycle (list :status "loop")))
    (setq cycle (nconc cycle (list :self cycle)))
    (should-not (chat-mdp-encode-tool-result cycle))))

;; ------------------------------------------------------------------
;; The machine view
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-the-machine-view-shows-what-was-extracted ()
  "Rendered from the parsed value, so it shows what a program will read.
A payload that reads correctly to a person while parsing one field short
has no other symptom."
  (let ((view (chat-mdp-machine-view
               (chat-mdp-parse "- a: 28\n- b: \"28\"\n- c: true"))))
    ;; The one thing a document renderer cannot show: which 28 is a number.
    (should (string-match-p "a: number 28" view))
    (should (string-match-p "b: string \"28\"" view))
    (should (string-match-p "c: boolean true" view))))

(ert-deftest chat-mdp-a-uniform-array-is-shown-as-an-aligned-table ()
  "Aligned by `chat-align', the same one the document view uses."
  (let* ((value (chat-mdp-parse "# S

| name | n |
| ---- | - |
| 中文名  | 1 |
| ab   | 22 |"))
         (view (chat-mdp-machine-view value))
         (rows (seq-filter (lambda (line) (string-prefix-p "  |" line))
                           (split-string view "\n"))))
    (should (= 3 (length rows)))
    (should (apply #'= (mapcar #'string-width rows)))))

(ert-deftest chat-mdp-a-wide-machine-table-fits-its-display-budget ()
  "Long tool payloads stay inspectable beside the chat transcript."
  (let* ((chat-mdp-machine-table-max-width 36)
         (value '(("S" . ((("name" . "a very long display name")
                            ("result" . "a result that is also long"))))))
         (view (chat-mdp-machine-view value))
         (rows (seq-filter (lambda (line) (string-prefix-p "  |" line))
                           (split-string view "\n"))))
    (should (= 2 (length rows)))
    (should (seq-every-p
             (lambda (row)
               (<= (string-width row) chat-mdp-machine-table-max-width))
             rows))
    (should (seq-some (lambda (row) (string-match-p "…" row)) rows))))

(ert-deftest chat-mdp-a-heterogeneous-array-is-shown-element-by-element ()
  "Rather than forced into columns it does not have."
  (let ((view (chat-mdp-machine-view
               (chat-mdp-parse "# items\n\n- : 1\n- :\n  - k: v"))))
    (should (string-match-p "\\[0\\]: number 1" view))
    (should (string-match-p "\\[1\\]:" view))))

(ert-deftest chat-mdp-annotating-plays-down-what-was-skipped ()
  "The other half of what a document renderer cannot do without a parse
result: it sees Markdown syntax and cannot tell structure from prose."
  (let* ((text "Some prose.\n- a: 1")
         (annotated (chat-mdp-annotate text)))
    (should (equal 'chat-mdp-comment
                   (get-text-property 0 'face annotated)))
    (should-not (get-text-property (string-match "- a" annotated)
                                   'face annotated))))

(ert-deftest chat-mdp-annotating-many-lines-keeps-structural-lines-clear ()
  (let* ((prose (mapconcat (lambda (index) (format "note %d" index))
                            (number-sequence 1 1200) "\n"))
         (text (concat prose "\n- answer: 42"))
         (annotated (chat-mdp-annotate text))
         (answer (string-match "- answer" annotated)))
    (should (eq 'chat-mdp-comment (get-text-property 0 'face annotated)))
    (should-not (get-text-property answer 'face annotated))))

;; ------------------------------------------------------------------
;; Independence
;; ------------------------------------------------------------------

(ert-deftest chat-mdp-does-not-depend-on-the-renderer ()
  "Asserted about the source, since by the time a whole suite has run
everything is loaded.  A protocol module whose usability depends on a
display layer being loaded goes blind in batch mode, and the dependency
points the wrong way besides."
  (let ((source (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name
                    "lisp/core/chat-mdp.el"
                    (locate-dominating-file
                     (or load-file-name buffer-file-name default-directory)
                     "chat.el")))
                  (buffer-string))))
    (should (string-match-p "(require 'chat-align)" source))
    (should-not (string-match-p "(require 'chat-markdown)" source))
    (should-not (string-match-p "(require 'chat-ui" source))))

(ert-deftest chat-mdp-parses-with-nothing-else-loaded ()
  (should (equal '(("a" . 1)) (chat-mdp-parse "- a: 1"))))

;; ------------------------------------------------------------------
;; Tool calls
;; ------------------------------------------------------------------

(require 'chat-tool-caller)

(ert-deftest chat-mdp-a-tool-call-can-arrive-as-mdp ()
  "With the explanation the model wanted to give, which is a comment."
  (let* ((chat-tool-caller-format-counts nil)
         (calls (chat-tool-caller-parse "I will check the directory first.

- tool_call:
  - name: shell_execute
  - arguments:
    - command: pwd")))
    (should (= 1 (length calls)))
    (should (equal "shell_execute" (plist-get (car calls) :name)))
    (should (equal '(("command" . "pwd"))
                   (plist-get (car calls) :arguments)))
    (should (equal '((mdp . 1)) chat-tool-caller-format-counts))))

(ert-deftest chat-mdp-a-json-tool-call-still-arrives ()
  "Both formats during the changeover, and not out of habit: models
differ in how closely they follow a prompt, so accepting one only would
take tool calling away from whichever did not comply."
  (let* ((chat-tool-caller-format-counts nil)
         (calls (chat-tool-caller-parse
                 "{\"function_call\": {\"name\": \"shell_execute\", \"arguments\": {\"command\": \"pwd\"}}}")))
    (should (= 1 (length calls)))
    (should (equal "shell_execute" (plist-get (car calls) :name)))
    (should (equal '((json . 1)) chat-tool-caller-format-counts))))

(ert-deftest chat-mdp-a-tool-calls-array-carries-several ()
  (let ((calls (chat-tool-caller-parse "# tool_calls

- :
  - name: a
  - arguments:
    - x: 1
- :
  - name: b
  - arguments: {}")))
    (should (equal '("a" "b") (mapcar (lambda (c) (plist-get c :name))
                                      calls)))
    (should (equal '(("x" . 1)) (plist-get (car calls) :arguments)))
    (should-not (plist-get (cadr calls) :arguments))))

(ert-deftest chat-mdp-a-reply-mentioning-nothing-yields-no-call ()
  "A payload that declares a call has said so; prose has not."
  (should-not (chat-tool-caller-parse "Here is a summary of the changes."))
  (should-not (chat-tool-caller-parse "- note: this is not a call")))

(ert-deftest chat-mdp-the-json-conventions-are-translated-not-assumed ()
  "MDP keeps `false', `null', `[]' and `{}' apart, and the tool layer
inherited json.el's conventions for them."
  (should (eq :json-false (chat-tool-caller--mdp-to-json :false)))
  (should-not (chat-tool-caller--mdp-to-json :null))
  (should-not (chat-tool-caller--mdp-to-json :empty-object))
  (should (equal '(("a" . :json-false))
                 (chat-tool-caller--mdp-to-json '(("a" . :false))))))

(ert-deftest chat-mdp-a-call-in-a-fenced-example-is-not-a-call ()
  "The comment rule again, and here it is a safety property: a reply
explaining how to call a tool must not call it."
  (should-not (chat-tool-caller--calls-from-mdp "To do that, write:

```markdown
- tool_call:
  - name: shell_execute
  - arguments:
    - command: rm -rf /
```

But I will not run it.")))

(provide 'test-chat-mdp)
;;; test-chat-mdp.el ends here
