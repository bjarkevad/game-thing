module Lenses where
import qualified Data.Vector                    as V
import Control.Lens (ASetter, over)

vecCons :: ASetter s t (V.Vector a) (V.Vector a) -> a -> s -> t
vecCons v n = over v (V.cons n)
{-# INLINE vecCons #-}
