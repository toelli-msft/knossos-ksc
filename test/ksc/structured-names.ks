(def f Float (t : Tuple Float Integer) 0.0)

(gdef fwd [f (Tuple Float Integer)])
(gdef rev [f (Tuple Float Integer)])

(def main Integer ()
     (let (f1     (f 0.0 0))
     (let (f2     ([f (Tuple Float Integer)] 0.0 0))
     (let (fwd$f_ ([fwd [f (Tuple Float Integer)]] (tuple 0.0 0) (tuple 1.0 (tuple))))
     (let (fwd$f_ ([fwd f] (tuple 0.0 0) (tuple 1.0 (tuple))))
     (let (rev$f_ ([rev f] (tuple 0.0 0) 1.0))
     (let (rev$f_ ([rev [f (Tuple Float Integer)]] (tuple 0.0 0) 1.0))
       1)))))))
