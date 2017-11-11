{-# LANGUAGE DeriveGeneric #-}
module Protocol ( ClientId
                , ServerProtocol(..)
                , ClientProtocol(..)
                , Auction(..)
                , decodeC
                , encodeC
                ) where

import           Data.Binary              (Binary, decodeOrFail, encode)
import           Data.Conduit             (ConduitM, await, awaitForever, yield)
import qualified Data.Conduit.Combinators as C
import           Protolude

type ClientId = ByteString

data Auction = Auction Text
  deriving (Show, Generic)
instance Binary Auction

data ServerProtocol
  = Authenticate ClientId
  | AuctionCreated Auction
  | Close
  deriving (Show, Generic)
instance Binary ServerProtocol

data ClientProtocol
  = CreateAuction Auction
  | MakeBid
  deriving (Show, Generic)
instance Binary ClientProtocol

decodeC :: (Binary a, MonadIO m) => ConduitM ByteString a m ()
decodeC = awaitForever $ \bs ->
    case decode' $ strConv Strict bs of
      Right msg -> yield msg
      Left err  -> print err
  where
    decode' :: (Binary b) => LByteString -> Either Text b
    decode' = bimap (\(_,_,e) -> strConv Strict e) (\(_,_,v) -> v) . decodeOrFail

encodeC :: (MonadIO m, Binary b) => ConduitM b ByteString m ()
encodeC = awaitForever $ yield . strConv Strict . encode
