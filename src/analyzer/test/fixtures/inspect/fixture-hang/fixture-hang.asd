(in-package :asdf-user)

(defsystem :fixture-hang
  :description "Never returns. What `timeout' is for (REQ-0018 R7)."
  :serial t
  :components ((:file "fixture-hang")))
