{-# LANGUAGE DeriveGeneric #-}
module Protocol ( ClientId
                , ServerMessage(..)
                , Production(..)
                , decodeC
                , encodeC
                ) where

import Protolude
import Data.Binary (Binary, encode, decodeOrFail)
import Data.Conduit (ConduitM, await, yield, awaitForever)
import qualified Data.Conduit.Combinators as C

type ClientId = ByteString

data Production
  = CreateAuction
  | MakeBid
  deriving (Show, Generic)
instance Binary Production

data ServerMessage
  = Authenticate ClientId
  | Data ByteString
  | ProductionMessage Production
  | Close
  deriving (Show, Generic)
instance Binary ServerMessage

decodeC :: MonadIO m => ConduitM ByteString ServerMessage m ()
decodeC = awaitForever $ \bs ->
    case decode' $ strConv Strict bs of
      Right msg -> yield msg
      Left err -> print err
  where
    decode' :: (Binary b) => LByteString -> Either Text b
    decode' = bimap (\(_,_,e) -> strConv Strict e) (\(_,_,v) -> v) . decodeOrFail

encodeC :: (MonadIO m, Binary b) => ConduitM b ByteString m ()
encodeC = awaitForever $ yield . strConv Strict . encode
