{-# LANGUAGE ScopedTypeVariables #-}

module MainSpec where

import Protolude

import Test.Tasty
import Test.Tasty.Hspec

spec_prelude :: Spec
spec_prelude = do
  describe "Prelude.head" $ do
    it "returns the first element of a list" $ do
      head [23 ..] `shouldBe` (Just 23 :: Maybe Int)
