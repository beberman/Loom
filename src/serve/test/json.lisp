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

(in-package :synoptik-serve-test)

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
  ;; encoder check: the shape synoptik-knowledge actually returns has to survive
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

(test a-dotted-pair-is-rendered-rather-than-signalled-from-inside-the-encoder
  ;; BUG-0030 D2, and the reason the whole service went down rather than one
  ;; request. NOTE-ERROR recorded `(cons path message)`, REPOSITORY-STATUS put
  ;; that on :LAST-ERROR, and this walker reached it through its LISTP clause:
  ;; PLIST-SHAPED-P calls LENGTH and JSON-ARRAY calls MAP, and both signal
  ;; `The value <message> is not of type LIST` on an improper list. The entry
  ;; stayed on REPOSITORY-ERRORS, so every later /v1/status re-encoded the same
  ;; cons and re-signalled until the process was restarted.
  ;;
  ;; The producer is fixed and this is the guard that the next one costs an
  ;; ugly field rather than the service. The bottom clause's own comment is the
  ;; contract being kept: a shape this encoder was not supposed to receive is
  ;; made visible in the answer rather than signalled from inside an encoder.
  (is (search "last-error" (encode-result (list :last-error (cons "src/a.lisp" "boom")))))
  (is (equal "{\"n\":1}" (encode-result (list :n 1)))
      "and the ordinary case is untouched"))

(test the-improper-list-guard-does-not-catch-an-atom-or-a-vector
  ;; The guard's own failure mode, and it is not hypothetical: written without
  ;; its CONSP test the predicate fell through to its FINALLY clause and
  ;; reported every non-NIL atom as improper, which rendered the MCP tools list
  ;; -- a vector -- as one PRINC-TO-STRING string and failed tools/list.
  (is (equal "{\"items\":[1,2]}" (encode-result (list :items #(1 2)))))
  (is (equal "{\"n\":7}" (encode-result (list :n 7))))
  (is (equal "{\"impacted\":[{\"a\":1}]}"
             (encode-result (list :impacted (list (list :a 1)))))))

;;; The list predicates JSON-VALUE asks. They were the utils library's until
;;; REQ-0079 R1 (PLAN-0061 step 1) and are private to synoptik-serve now, so the
;;; tests reach them with a double colon. None of these calls the library.

(test improper-list-p-is-false-for-every-atom-and-proper-list-and-true-for-a-dotted-tail
  ;; Each atom is a case on purpose: the CONSP guard is the whole predicate for
  ;; them, and without it the FINALLY clause answers T for every non-NIL atom.
  (dolist (x (list 5 "s" #(1) nil '(1 2) :k))
    (is (null (synoptik-serve::improper-list-p x)) "~s is not an improper list" x))
  (is (synoptik-serve::improper-list-p (cons 1 2)))
  (is (synoptik-serve::improper-list-p (list* 1 2 3))
      "a list ending in a dotted tail is improper at its end, not its head"))

(test plistp-answers-for-the-empty-list-and-refuses-an-odd-length-or-a-dotted-tail
  (is (synoptik-serve::plistp nil) "the empty list is a plist; JSON-VALUE's NULL clause keeps NIL out")
  (is (synoptik-serve::plistp '(:a 1)))
  (is (null (synoptik-serve::plistp '(:a))) "odd length")
  (is (null (synoptik-serve::plistp '("a" 1))) "the default key test is SYMBOLP")
  (is (null (synoptik-serve::plistp (list* :a 1 2))) "a dotted tail is not a proper list")
  (is (synoptik-serve::plistp '(:a 1) :key-test #'keywordp))
  (is (null (synoptik-serve::plistp '(a 1) :key-test #'keywordp))))

(test json-value-renders-a-dotted-pair-as-its-printed-form-before-any-list-clause
  ;; BUG-0030 D2. The order is the contract: the improper-list clause precedes
  ;; the *ARRAY-VALUED-KEYS* clause, the PLISTP clause and the LISTP clause, each
  ;; of which assumes a proper list and signals on this one. Under an
  ;; array-valued key the pair would otherwise reach JSON-ARRAY, which MAPs it.
  (is (equal "(1 . 2)" (json-value (cons 1 2))))
  (is (equal "(1 . 2)" (json-value (cons 1 2) :impacted))
      "the array-valued key must not route a dotted pair to JSON-ARRAY")
  (is (equal "(A 1 . 2)" (json-value (list* :a 1 2)))
      "a plist with a dotted tail is not an object")
  (is (null (json-value nil)) "NIL is not an improper list")
  (is (equalp #() (json-value nil :impacted))))
