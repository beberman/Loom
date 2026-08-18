;;;
;;; Tests for src/serve/json.lisp.
;;;
;;; Every assertion here is against a literal JSON string rather than a decode
;;; round-trip, and that is the point of the file. cl-json camelCases a keyword
;;; key on its own, so a test that encoded and then decoded with the same
;;; library would agree with itself whatever spelling went over the wire. The
;;; one round-trip in this file is the last test, and it is an integration
;;; check rather than an encoder check.
;;;

(in-package :loom-serve-test)

(def-suite json
  :in all-tests
  :description "The recursive walker, the key vocabulary, and the known hole.")

(in-suite json)

(test a-nested-plist-is-an-object-not-an-array
  ;; The witness for the walker existing at all. Measured, cl-json's own plist
  ;; encoder produces {"outer":["inner",1],"n":2} for this input: it is one
  ;; level deep, and every nested plist in DESCRIBE-ENTITY's result would reach
  ;; a client as an array of alternating keys and values.
  (is (equal "{\"outer\":{\"inner\":1},\"n\":2}"
             (encode-result '(:outer (:inner 1) :n 2)))))

(test a-key-keeps-the-name-it-has-in-lisp
  ;; (json:encode-json-to-string :full-tokens) is "fullTokens". A vocabulary
  ;; nobody wrote down and nobody can predict from the console is worse than a
  ;; verbose one.
  (let ((text (encode-result '(:full-tokens 12 :rel-type :calls))))
    (is (search "\"full-tokens\"" text) "~a" text)
    (is-false (search "fullTokens" text))
    (is (search "\"rel-type\"" text) "~a" text)
    ;; A keyword *value* is a string, and it keeps its own name too.
    (is (search "\"calls\"" text))))

(test a-key-written-in-mixed-case-keeps-it
  ;; The reader upcases :full-tokens, so downcasing is right for it. A keyword
  ;; written with escapes was written that way on purpose, and the only reason
  ;; to do that is a protocol that requires the spelling -- MCP's tool schema
  ;; keys are camelCase and are not this system's to rename.
  (is (equal "{\"inputSchema\":{\"type\":\"object\"}}"
             (encode-result '(:|inputSchema| (:|type| "object"))))))

(test a-list-of-keywords-is-an-array-and-a-two-element-one-is-the-known-hole
  ;; The first is the real case: a rule's :check property carries
  ;; (:calls :imports :depends-on) under :rel-types.
  (is (equal "[\"calls\",\"imports\",\"depends-on\"]"
             (encode-result '(:calls :imports :depends-on))))
  ;; The second is a recorded misencoding, asserted on purpose. A two-element
  ;; list of keywords satisfies PLIST-SHAPED-P and cannot be told from a plist
  ;; by looking at it. No such value exists in the tree today; this test is
  ;; here so that the day one does, it is a failing assertion in a file that
  ;; explains itself rather than a puzzling client bug.
  (is (equal "{\"anything\":{\"calls\":\"contains\"}}"
             (encode-result '(:anything (:calls :contains)))))
  ;; And the escape hatch: the same value under a key in *ARRAY-VALUED-KEYS*.
  (is (equal "{\"rel-types\":[\"calls\",\"contains\"]}"
             (encode-result '(:rel-types (:calls :contains))))))

(test an-empty-impact-set-is-an-empty-array
  ;; NIL is one Lisp value and two JSON ones. Without *ARRAY-VALUED-KEYS* a
  ;; caller cannot tell "nothing was impacted" from "this answer has no
  ;; impacted field".
  (is (equal "{\"impacted\":[]}" (encode-result '(:impacted nil))))
  (is (equal "{\"stale\":null}" (encode-result '(:stale nil)))))

(test t-is-true-and-a-number-is-a-number
  (is (equal "{\"truncated\":true,\"count\":3}"
             (encode-result '(:truncated t :count 3)))))

(test a-string-is-escaped-by-the-library-rather-than-by-hand
  ;; The one part of encoding worth not writing: cl-json escapes the scalar,
  ;; and the emitter here only writes the punctuation around it.
  (is (equal "{\"detail\":\"a \\\"quoted\\\" word\"}"
             (encode-result '(:detail "a \"quoted\" word")))))

(test object-members-keep-the-order-the-plist-wrote-them-in
  ;; The reason the emitter writes its own braces instead of handing cl-json a
  ;; hash table: MAPHASH order is implementation-defined, and a JSON answer
  ;; whose key order changes between runs of the same request is a diff nobody
  ;; can read.
  (is (equal "{\"a\":1,\"b\":2,\"c\":3}" (encode-result '(:a 1 :b 2 :c 3))))
  (is (equal "{\"c\":3,\"b\":2,\"a\":1}" (encode-result '(:c 3 :b 2 :a 1)))))

(test a-real-describe-result-encodes
  ;; The only round-trip in the file, and an integration check rather than an
  ;; encoder check: the shape loom-knowledge actually returns has to survive
  ;; the walker, not just the shapes chosen to exercise it.
  (with-operations-fixture (repository)
    (let* ((detail (invoke-operation (find-operation :describe) '(:read)
                                     (list :repository (repository-name repository)
                                           :term "alpha-twice")))
           (text (encode-result detail))
           (decoded (json:decode-json-from-string text)))
      (dolist (key '(:entity :properties :neighbors))
        (is (not (null (assoc key decoded)))
            "~a is missing from the encoded answer" key))
      (is (search "\"neighbors\":[" text)
          "the neighbour groups encoded as something other than an array"))))

(test the-json-false-marker-encodes-as-false-and-nil-still-encodes-as-null
  ;; BUG-0028. NIL is this encoder's third overloaded value -- false, empty
  ;; list, absent -- and until *JSON-FALSE* existed there was no way to write
  ;; the JSON literal `false' at all. MCP's isError is typed boolean, so null
  ;; failed client-side schema validation on every successful call.
  ;;
  ;; Both halves asserted together: the marker must encode as false AND a bare
  ;; NIL must go on encoding as null, because a fix that quietly turned every
  ;; NIL into false would change every absent field in every REST answer.
  (is (equal "{\"flag\":false}" (encode-result (list :flag *json-false*))))
  (is (equal "{\"flag\":null}" (encode-result (list :flag nil))))
  (is (equal "{\"flag\":true}" (encode-result (list :flag t))))
  ;; And it survives nesting, since a tools/call result carries it one level
  ;; down inside the result object rather than at the top.
  (is (equal "{\"outer\":{\"flag\":false}}"
             (encode-result (list :outer (list :flag *json-false*)))))
  ;; An empty array-valued key is still [], not false: the two NIL cases stay
  ;; separate from each other as well as from null.
  (is (equal "{\"impacted\":[]}" (encode-result (list :impacted nil)))))
