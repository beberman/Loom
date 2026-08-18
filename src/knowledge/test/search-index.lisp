;;;; The tokenised postings index and BM25 -- DES-0026 D4, PLAN-0032 S4.

(in-package :loom-knowledge-test)

(in-suite context)

(test one-tokeniser-handles-every-compound-that-has-broken-something
  ;; PLAN-0032's named risk for this step: a postings map that tokenises
  ;; differently from the query path silently returns nothing for terms that
  ;; should match, and the symptom is a smaller bundle rather than an error.
  ;; There is one function, and these are the spellings that have cost this
  ;; project something before.
  (flet ((toks (s) (sort (copy-list (index-tokens s)) #'string<)))
    (is (equal '("data" "data-handler" "handler") (toks "data-handler"))
        "REQ-0016's query, and the fragment that took five seeds")
    (is (equal '("editor" "layer" "layereditor") (toks "LayerEditor"))
        "the case boundary is what makes a React tree searchable at all")
    (is (equal '("emit" "emitpartition" "partition") (toks "emitPartition")))
    ;; CEIL and CEILE are STEM-VARIANTS on "ceiling", which ends in -ing. They
    ;; are listed rather than tolerated: the assertion stays exact so that an
    ;; unexpected extra term fails this test, which is what it is for.
    (is (equal '("*call-site-ceiling*" "call" "ceil" "ceile" "ceiling" "site")
               (toks "*call-site-ceiling*"))
        "the stars are separators and the whole spelling is still a term")
    (is (equal '("dhandler" "dhandler-get" "get") (toks "DHANDLER-GET")))
    ;; Recorded rather than fixed: an all-caps run has no lower-to-upper
    ;; boundary to split on, so URLParser is one term. It costs a query saying
    ;; "url parser" that entity, and the alternative -- splitting before the
    ;; last capital of a run -- would break DHANDLER-GET into D and HANDLER-GET
    ;; on some inputs. The narrower miss is the one to keep.
    (is (equal '("urlparser") (toks "URLParser"))
        "an all-caps prefix does not split, and that is the known edge")))

(test document-frequency-is-a-postings-list-length
  ;; The number every hand-tuned constant in SEED-SCORE was standing in for, and
  ;; the first time anything in this system could ask for it.
  (let* ((g (graph-of (k-def 'function-entity "alpha-handler" "src/a.lisp")
                      (k-def 'function-entity "beta-handler" "src/b.lisp")
                      (k-def 'function-entity "gamma" "src/c.lisp")))
         (sx (build-search-index g)))
    (is (= 2 (document-frequency sx "handler")) "two of the three carry it")
    (is (= 1 (document-frequency sx "alpha")))
    (is (= 0 (document-frequency sx "nonexistent")))
    (is (> (inverse-document-frequency sx "alpha")
           (inverse-document-frequency sx "handler"))
        "the rarer term is worth more, measured rather than listed")))

(test a-term-in-every-document-still-scores-above-zero
  ;; This asserted exactly 0.0 while the floored Robertson-Sparck-Jones form was
  ;; in use, on the argument that a term in every document says nothing. The
  ;; argument is right and the consequence was not: with most terms of a small
  ;; repository above half the corpus, every match scored 0, no entity was a
  ;; candidate, and the seeder returned nothing. Nine seeding tests failed that
  ;; way on fixtures of three to nine entities.
  ;;
  ;; The Lucene form is always positive. A common term now costs a candidate its
  ;; lead rather than its existence, which is CON-0006's asymmetry applied to a
  ;; scoring function.
  (let* ((g (apply #'graph-of
                   (loop for i from 1 to 10
                         collect (k-def 'function-entity (format nil "common-~d" i)
                                        "src/a.lisp"))))
         (sx (build-search-index g)))
    (is (= 10 (document-frequency sx "common")))
    (is (plusp (inverse-document-frequency sx "common"))
        "in every document, and still worth more than nothing")
    (is (> (inverse-document-frequency sx "common-1")
           (inverse-document-frequency sx "common"))
        "and rarity still dominates")))

(defun filler (n)
  "N entities carrying none of the terms a test is about.

Needed because IDF is meaningless on a tiny corpus, which the first draft of the
two tests below learned the hard way: with two documents, a term in both has
df = n and the floored IDF is exactly 0, so every score was 0 and the
comparisons were between two zeroes. That is the floor working correctly -- a
term in every document distinguishes nothing -- and it means a BM25 test needs a
corpus to be rare *in*."
  (loop for i from 1 to n
        collect (k-def 'function-entity (format nil "filler-~d" i) "src/filler.lisp")))

(test bm25-normalises-a-long-field-against-that-field-s-own-average
  ;; DES-0028 D6 declined to hand-normalise a 5,639-character docstring against
  ;; a 12-character name, on the grounds that BM25 would bring one. This is that
  ;; obligation discharged: the same single term in a short docstring outscores
  ;; it buried in a long one.
  (let* ((short (k-def 'function-entity "alpha" "src/a.lisp"
                       :documentation "widget"))
         (long (k-def 'function-entity "beta" "src/b.lisp"
                      :documentation
                      (format nil "widget ~{~a ~}" (loop for i from 1 to 200
                                                         collect (format nil "w~d" i)))))
         (g (apply #'graph-of short long (filler 20)))
         (sx (build-search-index g)))
    (is (> (bm25-score sx short '("widget"))
           (bm25-score sx long '("widget")))
        "one mention in a sentence beats one mention in an essay")))

(test the-name-field-outweighs-the-path
  ;; An identifier is chosen; a path is where a file happens to sit. The path is
  ;; weighted rather than dropped, which is D1's inventory turning SEED-MATCHES'
  ;; rank-3 discard into a weight -- under CON-0006 a weak signal belongs at the
  ;; bottom of the index tier rather than in the bin.
  (let* ((named (k-def 'function-entity "overlay" "src/a.lisp"))
         (pathed (k-def 'function-entity "unrelated" "src/overlay/thing.lisp"))
         (sx (build-search-index (apply #'graph-of named pathed (filler 20)))))
    (is (> (bm25-score sx named '("overlay"))
           (bm25-score sx pathed '("overlay"))))
    (is (plusp (bm25-score sx pathed '("overlay")))
        "and the path match is still worth something rather than nothing")))

(test candidates-come-from-the-postings-rather-than-a-scan
  (let* ((g (graph-of (k-def 'function-entity "alpha-handler" "src/a.lisp")
                      (k-def 'function-entity "beta-handler" "src/b.lisp")
                      (k-def 'function-entity "gamma" "src/c.lisp")))
         (sx (build-search-index g))
         (names (mapcar #'name (search-candidates sx '("handler")))))
    (is (= 2 (length names)))
    (is (null (search-candidates sx '("nothing-carries-this")))
        "a term nothing carries costs no walk at all")))

(test stemming-reaches-a-definition-named-for-the-task
  ;; The third of the three misses in the front-end set. "saving a piece design"
  ;; tokenises to SAVING and SAVEDESIGN tokenises to SAVE, so the entity named
  ;; after the task matched none of the query.
  (let ((q (index-tokens "saving a piece design"))
        (e (index-tokens "SaveDesign")))
    (is (member "save" q :test #'string=) "the query reaches the uninflected form")
    (is (member "save" e :test #'string=))
    (is (intersection q e :test #'string=) "so the two now share a term"))
  (is (member "edit" (index-tokens "editing colours") :test #'string=))
  (is (member "layer" (index-tokens "edited layers") :test #'string=))
  (is (member "change" (index-tokens "changing the type") :test #'string=))
  (is (member "report" (index-tokens "reporting rejections") :test #'string=)))

(test a-stem-is-added-and-never-substituted
  ;; A wrong guess can then cost nothing: a stem corresponding to no real term
  ;; simply never matches, where a substitution would have lost the word.
  (let ((toks (index-tokens "saving")))
    (is (member "saving" toks :test #'string=) "the word itself survives")
    (is (member "sav" toks :test #'string=) "dropping -ing, which matches nothing")
    (is (member "save" toks :test #'string=) "and the -e restoration, which does")))

(test the-minimum-lengths-keep-short-identifiers-whole
  ;; A full stemmer would fold identifiers this index depends on keeping apart.
  (is (not (member "clas" (index-tokens "class") :test #'string=))
      "a double s is refused, so CLASS survives")
  (is (not (member "addres" (index-tokens "address") :test #'string=)))
  (is (not (member "r" (index-tokens "ring") :test #'string=))
      "-ing needs six characters, so RING survives")
  (is (member "type" (index-tokens "types") :test #'string=)
      "and an ordinary plural still folds"))
