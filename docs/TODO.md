Lisp parsing. Need to add defmethod, defgeneric, defclass, and defmacro. For defmacro any new operation that is defined needs to be expanded after applying the macro to see what additional code must be parsed since LISP is self-defining

describe apply-transaction still shows one caller. 

Calls made from inside (test ...) macro bodies aren't attributed because defmacro is not expanded
