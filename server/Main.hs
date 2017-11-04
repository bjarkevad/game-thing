{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables   #-}

module Main where
import           Protolude

import           Control.Concurrent             (ThreadId, forkIO, threadDelay)
import           Control.Concurrent.STM         (atomically)
import           Control.Concurrent.STM.TBQueue (TBQueue, newTBQueue,
                                                 readTBQueue, writeTBQueue)
import           Control.Concurrent.STM.TVar    (TVar, modifyTVar, newTVar,
                                                 readTVar, readTVarIO)
import           Control.Exception              (catch)
import           Data.Binary                    (Binary, decodeOrFail, encode)
import           Data.Conduit                   (ConduitM, Source, addCleanup,
                                                 await, awaitForever, catchC,
                                                 passthroughSink, runConduit,
                                                 sequenceConduits, yield, (.|))
import qualified Data.Conduit.Combinators       as C
import           Data.Conduit.Network           (AppData, ServerSettings,
                                                 appLocalAddr, appSink,
                                                 appSockAddr, appSource,
                                                 runGeneralTCPServer,
                                                 serverSettings)
import           Data.HashMap.Strict            (HashMap)
import qualified Data.HashMap.Strict            as M
import qualified Dhall                          as D
import           GHC.Generics
import           Protocol                       (ClientId, ServerMessage (..),
                                                 decodeC, encodeC)

data ServerState = ServerState
  { connections :: TVar (HashMap ClientId (TBQueue ServerMessage))
  }

type ServerM = ReaderT ServerState IO

data Config = Config
  { bindPort              :: Integer
  , clientQueueBufferSize :: Integer
  } deriving (Generic, Show)
instance D.Interpret Config

main :: IO ()
main = do
  print "Starting server"
  conf <- loadConfig
  c <- atomically $ newTVar M.empty
  runReaderT (runGeneralTCPServer (settings conf) (handler conf)) (ServerState c)

loadConfig :: IO Config
loadConfig = D.input D.auto "./config/server"

settings :: Config -> ServerSettings
settings Config{bindPort} = serverSettings (fromIntegral bindPort) "0.0.0.0"

handler :: Config -> AppData -> ServerM ()
handler Config{clientQueueBufferSize} ad = do
  print $ appSockAddr ad
  maybeClientId <- runConduit
     $ appSource ad
    .| decodeC
    .| authenticate
  case maybeClientId of
    Just clientId -> do
      q <- newTBQueue (fromIntegral clientQueueBufferSize)
        & atomically
        & liftIO
      registerClient clientId q
      writer q
        & forkIO
        & liftIO
      reader clientId
    Nothing -> pure ()
  where
    authenticate :: ConduitM ServerMessage o ServerM (Maybe ClientId)
    authenticate = do
      m <- await
      case m of
        Just (Authenticate clientId) -> pure $ Just clientId
        Just msg ->
          print ("Not authentication: " <> (show msg :: Text))
          >> authenticate
        _ -> pure Nothing
    writer :: TBQueue ServerMessage -> IO ()
    writer q = runConduit
       $ queueSource q
      .| encodeC
      .| appSink ad
    reader :: ClientId -> ServerM ()
    reader c = runConduit
       . addCleanup (const $ disconnect c)
       $ appSource ad
      .| decodeC
      .| passthroughSink C.print (const $ pure ())
      .| encodeC
      .| appSink ad

broadcast :: ServerMessage -> ServerM ()
broadcast msg = do
  ServerState{connections} <- ask
  readTVar connections
    >>= traverse (`writeTBQueue` msg)
    & atomically
    & liftIO
    & void

disconnect :: ClientId -> ServerM ()
disconnect c = do
      ServerState{connections} <- ask
      modifyTVar connections (M.delete c)
        & atomically
        & liftIO
      print $ "Removed connection for client: " <> c

registerClient :: ClientId -> TBQueue ServerMessage -> ServerM ()
registerClient c q = do
  print $ "Registering: " <> (show c :: Text)
  ServerState{connections} <- ask
  connectionCount <- liftIO . atomically $ do
    cs <- readTVar connections
    for_ (M.lookup c cs) (`writeTBQueue` Close)
    modifyTVar connections $ M.insert c q
    pure $ M.size cs
  print connectionCount

queueSource :: MonadIO m => TBQueue a -> Source m a
queueSource = C.repeatM . liftIO . atomically . readTBQueue

pingSource :: MonadIO m => Source m ()
pingSource =
  C.repeatM
  $ threadDelay (1 * 1000 * 1000)
  & liftIO
