; Copyright (c) Microsoft Corporation.
; Licensed under the MIT license.


(def d Float ((x : Float))
     (let ((p (mul 7.0 x)))
       p))

(def e Float ((x : Float))
     (let ((p (mul 7.0 x))
           (q (mul (mul p x) 5.0)))
       q))

(def e1 Float ((x : Float))
     (let ((p (mul 7.0 x))
           (q (mul p x)))
       q))

(def e2 Float ((x : Float))
     (let ((p (add 7.0 x))
           (q (add p x)))
       q))

(def f Float ((x : Float) (y : Float))
     (let ((p (mul 7.0 x))
           (r (div 11.0 y))
           (q (mul (mul p x) 5.0))
           (v (add (mul (mul 2.0 p) q) (mul 3.0 r))))
       v))

(def main Integer ()
     (print "13238.25 = " 13238.25 "\n"
            "f 3.0 4.0 = " (f 3.0 4.0) "\n"
            "revl$f 3.0 4.0 1.0 = " (revl$f 3.0 4.0 1.0) "\n"
            "rev$f 3.0 4.0 1.0 = " (rev$f 3.0 4.0 1.0) "\n"
            "e 3.0 = " (e 3.0) "\n"
            "revl$e 3.0 1.0 = " (revl$e 3.0 1.0) "\n"
            "rev$e 3.0 1.0 = " (rev$e 3.0 1.0) "\n"
            "e1 3.0 = " (e1 3.0) "\n"
            "revl$e1 3.0 1.0 = " (revl$e1 3.0 1.0) "\n"
            "rev$e1 3.0 1.0 = " (rev$e1 3.0 1.0) "\n"
            "e2 3.0 = " (e2 3.0) "\n"
            "revl$e2 3.0 1.0 = " (revl$e2 3.0 1.0) "\n"
            "rev$e2 3.0 1.0 = " (rev$e2 3.0 1.0) "\n"
            "d 3.0 = " (d 3.0) "\n"
            "revl$d 3.0 1.0 = " (revl$d 3.0 1.0) "\n"
            "rev$d 3.0 1.0 = " (rev$d 3.0 1.0) "\n"))
