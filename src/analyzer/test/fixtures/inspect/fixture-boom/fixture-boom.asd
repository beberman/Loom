(in-package :asdf-user)

(defsystem :fixture-boom
  :description "Signals at load time. One unit's failure must be that unit's gap (REQ-0018 R4)."
  :serial t
  :components ((:file "fixture-boom")))
