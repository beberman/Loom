(in-package :asdf-user)

(defsystem :fixture-hog
  :description "Allocates past any sane heap cap. RULE-0004 with a measured instance."
  :serial t
  :components ((:file "fixture-hog")))
