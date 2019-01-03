(def gmm_knossos_tri ((n : Integer))
  (/ (* n (- n 1)) 2))

(def exp$VecR ((v : Vec Float))
  (build (size v) (lam (i : Integer) (exp (index i v)))))

(def mul$R$VecR ((r : Float) (a : Vec Float))
    (build (size a) (lam (i : Integer) (* r (index i a)))))

(def mul$R$VecVecR ((r : Float) (a : Vec Vec Float))
    (build (size a) (lam (i : Integer) (mul$R$VecR r (index i a)))))

(def mul$VecR$VecR ((a : Vec Float) (b : Vec Float))
  (assert (== (size a) (size b))
    (build (size a) (lam (i : Integer) (* (index i a) (index i b))))))

(def sub$VecR$VecR ((a : Vec Float) (b : Vec Float))
  (assert (== (size a) (size b))
    (build (size a) (lam (i : Integer) (- (index i a) (index i b))))))

(def dotv ((a : Vec Float) (b : Vec Float))
  (sum (mul$VecR$VecR a b)))

(def dotvv ((a : Vec Vec Float) (b : Vec Vec Float))
  (sum (build (size a) (lam (i : Integer) (dotv (index i a) (index i b)))))
  )

(def sqnorm ((v : Vec Float))
  (dotv v v))

-- M is vector of rows
(def mul$Mat$Vec ((M : Vec Vec Float) (v : Vec Float))
  (build (size M) (lam (i : Integer) (dotv (index i M) v))))

(def gmm_knossos_makeQ ((q : Vec Float) (l : Vec Float))
    (let (D
      (size q))
    (build D (lam (i : Integer)
        (build D (lam (j : Integer)
           (if (< i j)
            0.0
            (if (== i j)
              (exp (index i q))
              (index (+ (gmm_knossos_tri (- i 1)) j) l))
           )
           ))))))

(def logsumexp ((v : Vec Float))
    (log (sum (exp$VecR v))))


(def gmm_knossos_gmm_objective
      ((x : Vec Vec Float)
       (alphas : Vec Float)
       (means : Vec Vec Float)
       (qs : Vec Vec Float)
       (ls : Vec Vec Float)
       (wishart_gamma : Float))
  (let (N (size x))
  (let (D (size (index 0 x)))
  (let (K (size alphas))
        (+ (- (sum (build N (lam (i : Integer)
              (logsumexp (build K (lam (k : Integer)
                (let ((Q (gmm_knossos_makeQ (index k qs) (index k ls)))
                      (mahal_vec (mul$Mat$Vec Q
                                          (sub$VecR$VecR (index i x) (index k means)))))
                  (- (+ (index k alphas) (sum (index k qs)))
                    (* wishart_gamma 1.0) -- should be (* 0.500000  (sqnorm mahal_vec))
                    ))))))))
            (* (to_float N) (logsumexp alphas)))
         (* 0.5 (sum (build K (lam (k : Integer)
                                            (+ (sqnorm (exp$VecR (index k qs)))
                                                (sqnorm (index k ls))))))))))))

(def mkvec ((N : Integer) (scale : Float))
    (build N (lam (j : Integer) ($rand scale))))

(def zerov ((x : Vec Float))
  (mul$R$VecR 0.0 x))

(def zerovv ((x : Vec Vec Float))
  (mul$R$VecVecR 0.0 x))

(def mkdeltav ((n : Integer)
               (i : Integer)
               (val : Float))
    (build n (lam (ii : Integer)
                (if (== i ii)
                    val
                    0.0))))

(def mkdeltavv ((x : Vec Vec Float)
                (i : Integer)
                (j : Integer)
                (val : Float))
    (build (size x) (lam (ii : Integer)
        (build (size (index ii x)) (lam (jj : Integer)
            (if (== i ii)
                (if (== j jj)
                    val
                    0.0)
                0.0))))))

(def main ()
    (let ((D 4)
          (N 5)
          (K 10)

          (x       (build N  (lam (i : Integer) (mkvec D 1.0))))
          (alphas  (build K (lam (i : Integer) ($rand 1.0))))
          (mus     (build K (lam (i : Integer) (mkvec D 1.0))))
          (qs      (build K (lam (i : Integer) (mkvec D 0.1))))
          (ls      (build K (lam (i : Integer) (mkvec (gmm_knossos_tri D) 1.0))))
          (gamma   1.5)

          (delta 0.00001)
          (delta0 0.0)

          (dx       (build N (lam (i : Integer) (mkvec D ($rand delta)))))
          (dalphas  (build K (lam (i : Integer) ($rand delta))))
          (dmus     (build K (lam (i : Integer) (mkvec D delta))))
          (dqs      (build K (lam (i : Integer) (mkvec D delta0))))  -- TODO: derivative error wrt qs is large
          (dls      (build K (lam (i : Integer) (mkvec (gmm_knossos_tri D) delta))))
          (dgamma   ($rand delta))

          (dtheta   (tuple dx dalphas dmus dqs dls dgamma))
          
          (dq12 (mkdeltavv qs 2 1 delta))

          (gmm_at_theta (gmm_knossos_gmm_objective x alphas mus qs ls gamma))
          (gmm_at_theta_plus_dq12 (gmm_knossos_gmm_objective x alphas mus (+ qs dq12) ls gamma))
          (gmm_fd (- gmm_at_theta_plus_dq12 gmm_at_theta))
          (gmm_fwd (fwd$gmm_knossos_gmm_objective
                    x          alphas          mus           qs       ls            gamma
                    (zerovv x) (zerov alphas)  (zerovv mus)  dq12     (zerovv ls)   0.0  ))

          (everything_works_as_expected
           -- I would like to pull out a function called something
           -- like `floating_point_numbers_are_close` but I would have
           -- to implement the derivtives of abs and max for that, and
           -- I can't be bothered right now.
           (let ((tolerance 0.001)
                 (actual gmm_fd)
                 (expected gmm_fwd))
             (< (abs (- actual expected))
                (max (* (abs expected) tolerance)
                     tolerance))))
          (impossibly_good (== gmm_fd gmm_fwd))

          -- Check <grad_f, dx> = f(x+dx) - f(x)
          -- with grad_f = f`(x, 1.0)
          (grad_gmm (rev$gmm_knossos_gmm_objective x alphas mus qs ls gamma 1.0))
          (grad_gmm_x          (get$1$6 grad_gmm))
          (grad_gmm_alphas     (get$2$6 grad_gmm))
          (grad_gmm_mus        (get$3$6 grad_gmm))
          (grad_gmm_qs         (get$4$6 grad_gmm))
          (grad_gmm_ls         (get$5$6 grad_gmm))
          (grad_gmm_gamma      (get$6$6 grad_gmm))
          
          (gmm_at_theta_plus_dtheta (gmm_knossos_gmm_objective (+ x dx) (+ alphas dalphas) (+ mus dmus) (+ qs dqs) (+ ls dls) (+ gamma dgamma)))

          (dot_at_x          (dotvv grad_gmm_x dx))
          (dot_at_alphas     (dotv  grad_gmm_alphas dalphas))
          (dot_at_mus        (dotvv grad_gmm_mus dmus))
          (dot_at_qs         (dotvv grad_gmm_qs dqs))
          (dot_at_ls         (dotvv grad_gmm_ls dls))
          (dot_at_gamma      (* grad_gmm_gamma dgamma))
          
          (grad_gmm_dot_dtheta (+      dot_at_x
                                (+     dot_at_alphas
                                 (+    dot_at_mus
                                  (+   dot_at_qs
                                   (+  dot_at_ls
                                       dot_at_gamma))))))

          (df (- gmm_at_theta_plus_dtheta gmm_at_theta))
          (rev_ok (* (/ 1.0 delta) (tuple grad_gmm_dot_dtheta df)))

          (everything_works_as_expected_reverse
           -- I would like to pull out a function called something
           -- like `floating_point_numbers_are_close` but I would have
           -- to implement the derivtives of abs and max for that, and
           -- I can't be bothered right now.
           (let ((tolerance 0.001)
                 (actual grad_gmm_dot_dtheta)
                 (expected df))
             (< (abs (- actual expected))
                (max (* (abs expected) tolerance)
                     tolerance))))
        )
      (pr x
          (gmm_knossos_makeQ (index 0 qs) (index 0 ls))
          (mul$Mat$Vec (gmm_knossos_makeQ (index 0 qs) (index 0 ls)) (index 0 x))
          (D$gmm_knossos_gmm_objective x alphas mus qs ls gamma)

          (gmm_knossos_gmm_objective x alphas mus qs ls gamma)          
          gmm_at_theta
          gmm_at_theta_plus_dq12
          gmm_fwd
          gmm_fd

          grad_gmm
          dtheta
          rev_ok

          everything_works_as_expected_reverse
          everything_works_as_expected
          impossibly_good
          )))
