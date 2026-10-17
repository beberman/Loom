;;;; The id synoptik-docstore's NEXT-DOCUMENT-ID allocates for a directory, printed.
;;;;
;;;;   sbcl --script tools/test/next-id.lisp <category-directory> <prefix>
;;;;   sbcl --script tools/test/next-id.lisp /path/to/repo/docs/requirements/ REQ
;;;;
;;;; PLAN-0061 step 5, for tools/test/test-next-doc-id.py. DES-0056 R4 says
;;;; tools/next-doc-id.sh and NEXT-DOCUMENT-ID compute one floor, and BUG-0039 is
;;;; what two allocators that disagree cost. The test can run the script but
;;;; not the Lisp function, so this prints the function's answer and the test
;;;; compares the two.
;;;;
;;;; Prints the id alone on stdout, nothing else, so a caller reads the line.
;;;; Loads synoptik-docstore with no other Synoptik system: it depends on synoptik-utils
;;;; and UIOP only (RULE-0010).

(load (merge-pathnames "harness.lisp"
                       (make-pathname :name nil :type nil
                                      :defaults *load-truename*)))

(let ((arguments (rest sb-ext:*posix-argv*)))
  (unless (= 2 (length arguments))
    (format *error-output* "usage: next-id.lisp <category-directory> <prefix>~%")
    (sb-ext:exit :code 2)))

(synoptik-harness:load-systems "tools/test/next-id.lisp"
                           :systems '("utils/" "docstore/")
                           :load :synoptik-docstore)

(destructuring-bind (directory prefix) (rest sb-ext:*posix-argv*)
  (format t "~a~%"
          (funcall (find-symbol "NEXT-DOCUMENT-ID" "SYNOPTIK-DOCSTORE")
                   (uiop:ensure-directory-pathname directory) prefix)))
