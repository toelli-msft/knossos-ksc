; Copyright (c) Microsoft Corporation.
; Licensed under the MIT license.
(def main Integer () (print true false))

(def g Bool () true)

(gdef fwd [g (Tuple)])
(gdef rev [g (Tuple)])
