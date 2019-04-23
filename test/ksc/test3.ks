(def f Float ((x : Vec 2 Float) (y : Vec n Float))
    (if (< 2 3) (index 1 x) 7.0)
)

(def mul_R_VecR (Vec n Float) ((r : Float) (a : Vec n Float))
    (build n (lam (i : Integer) (* r (index i a)))))

(def mkvec (Vec n Float) (n : Integer)
    (build n (lam (j : Integer) (to_float j))))

(def sqnorm Float (v : Vec n Float)
  (sum (build n (lam (i : Integer) (let (vi (index i v)) (* vi vi))))))

#|

(def g1 (gamma : Float)
    (let (ls     (build 10 (lam (i : Integer) (mkvec 3 gamma))))
         (sqnorm (index 0 ls))))
|#

(def g Float (gamma : Float)
    (let (v     (mul_R_VecR gamma (mkvec 3)))
         (sqnorm v)))

#|
(def main Integer ()
    (let (v1 (build 4 (lam (i : Integer) 3.0)))
        (pr 1
            ; (D$f v1 v1)
            ; (D$g 1.1)
            (fwd$g 1.1 0.001)
            (rev$g 1.1 0.001)
            (- (g 1.1001) (g 1.1))
            )))
|#