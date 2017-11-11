{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedLists       #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}

module Main where
import           Protolude

import           Control.Concurrent             (ThreadId, forkIO, threadDelay)
import           Control.Concurrent.STM         (atomically)
import           Control.Concurrent.STM.TBQueue (TBQueue, newTBQueue,
                                                 readTBQueue, writeTBQueue)
import           Control.Concurrent.STM.TVar    (TVar, modifyTVar, newTVar,
                                                 readTVar, readTVarIO)
import           Control.Exception              (catch, try)
import           Control.Lens                   (makeLenses, (<>~), (^.), (.~))
import           Data.Binary                    (Binary, decodeFile,
                                                 decodeFileOrFail, decodeOrFail,
                                                 encode, encodeFile)
import           Data.Conduit                   (ConduitM, Sink, Source,
                                                 addCleanup, await,
                                                 awaitForever, catchC,
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
import           Data.Vector                    (Vector)
import qualified Data.Vector                    as V
import           Data.Vector.Binary             ()
import qualified Dhall                          as D
import           GHC.Generics
import           Protocol                       (Auction (..), ClientId,
                                                 ClientProtocol (..),
                                                 ServerProtocol (..), decodeC,
                                                 encodeC)
import Lenses (vecCons)

data Config = Config
  { bindPort              :: Integer
  , clientQueueBufferSize :: Integer
  , saveFile              :: Text
  } deriving (Generic, Show)
instance D.Interpret Config

data GameState = GameState { _auctions :: Vector Auction}
  deriving (Show, Generic)
makeLenses ''GameState

instance Binary GameState

data ServerState = ServerState
  { _connections :: TVar (HashMap ClientId (TBQueue ServerProtocol))
  , _game        :: TVar GameState
  , _config      :: Config
  }
makeLenses ''ServerState

type ServerM = ReaderT ServerState IO

main :: IO ()
main = do
  print "Starting server"
  conf <- loadConfig
  c <- atomically $ newTVar M.empty
  g <- loadGameState $ strConv Strict (saveFile conf)
  g' <- atomically $ newTVar g
  runReaderT (runGeneralTCPServer (settings conf) (handler conf)) (ServerState c g' conf)

emptyGameState :: IO GameState
emptyGameState = pure $ GameState []

loadGameState :: FilePath -> IO GameState
loadGameState fp = do
  gs <- try (decodeFile fp)
  case gs of
    Left (err :: SomeException) -> do
      print $ "failed to load game state: " <> (show err :: Text)
      emptyGameState
    Right gs -> do
      print "Loaded game"
      pure gs

saveGame :: ServerM ()
saveGame = do
  f <- saveFile <$> asks _config
  g <- readTVar <$> asks _game
  g' <- liftIO $ atomically g
  liftIO $ encodeFile (strConv Strict f) g'

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
    authenticate :: ConduitM ServerProtocol o ServerM (Maybe ClientId)
    authenticate = do
      m <- await
      case m of
        Just (Authenticate clientId) -> pure $ Just clientId
        Just msg ->
          print ("Not authentication: " <> (show msg :: Text))
          >> authenticate
        _ -> pure Nothing
    writer :: TBQueue ServerProtocol -> IO ()
    writer q = runConduit
       $ queueSource q
      .| encodeC
      .| appSink ad
    reader :: ClientId -> ServerM ()
    reader c = runConduit
       . addCleanup (const $ disconnect c)
       $ appSource ad
      .| decodeC
      .| clientMessageC

clientMessageC :: Sink ClientProtocol ServerM ()
clientMessageC = awaitForever $ \case
  CreateAuction newAuction -> do
    modifyGameState $ auctions `vecCons` newAuction
    broadcast $ AuctionCreated newAuction

modifyGameState :: (MonadIO m, MonadReader ServerState m) => (GameState -> GameState) -> m ()
modifyGameState f = do
  gv <- asks _game
  liftIO . atomically $ modifyTVar gv f
  s <- asks _game
  s' <- liftIO . atomically $ readTVar s
  print s'

broadcast :: (MonadIO m, MonadReader ServerState m) => ServerProtocol -> m ()
broadcast msg = do
  ServerState{_connections} <- ask
  readTVar _connections
    >>= traverse (`writeTBQueue` msg)
    & atomically
    & liftIO
    & void

disconnect :: ClientId -> ServerM ()
disconnect c = do
      ServerState{_connections} <- ask
      modifyTVar _connections (M.delete c)
        & atomically
        & liftIO
      print $ "Removed connection for client: " <> c

registerClient :: ClientId -> TBQueue ServerProtocol -> ServerM ()
registerClient c q = do
  print $ "Registering: " <> (show c :: Text)
  ServerState{_connections} <- ask
  connectionCount <- liftIO . atomically $ do
    cs <- readTVar _connections
    -- for_ (M.lookup c cs) (`writeTBQueue` Close)
    modifyTVar _connections $ M.insert c q
    pure $ M.size cs
  print connectionCount

queueSource :: MonadIO m => TBQueue a -> Source m a
queueSource = C.repeatM . liftIO . atomically . readTBQueue

pingSource :: MonadIO m => Source m ()
pingSource =
  C.repeatM
  $ threadDelay (1 * 1000 * 1000)
  & liftIO
