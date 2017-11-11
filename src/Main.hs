{-# LANGUAGE NamedFieldPuns  #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RankNTypes      #-}
{-# LANGUAGE TemplateHaskell #-}
module Main where

import           Protolude                      hiding (on, (<>))

import qualified Graphics.Vty                   as V

import           Brick                          (emptyWidget, str,
                                                 withBorderStyle, (<+>), (<=>))
import qualified Brick.AttrMap                  as A
import qualified Brick.Main                     as M
import           Brick.Types                    (Widget)
import qualified Brick.Types                    as T
import           Brick.Util                     (bg, fg, on)
import           Brick.Widgets.Border           (border, borderWithLabel,
                                                 hBorder, vBorder)
import           Brick.Widgets.Border.Style     (unicode)
import           Brick.Widgets.Center           (center)
import           Brick.Widgets.Core             (hLimit, vLimit, withAttr)
import qualified Brick.Widgets.List             as L
import           Data.Monoid                    ((<>))

import           Brick.BChan                    (BChan, newBChan, readBChan,
                                                 writeBChan)
import           Control.Concurrent             (forkIO)
import           Control.Concurrent.STM.TBQueue (TBQueue, newTBQueue,
                                                 readTBQueue, writeTBQueue)
import           Control.Lens                   ((.~), (<>=), (<>~), (^.))
import           Control.Lens.TH                (makeLenses)
import           Data.Conduit                   (awaitForever, ConduitM, Consumer, Producer, Sink,
                                                 Source, addCleanup, await,
                                                 passthroughSink, runConduit,
                                                 yield, (.|))
import qualified Data.Conduit.Combinators       as C
import           Data.Conduit.Network           (AppData, ClientSettings,
                                                 appSink, appSource,
                                                 clientSettings, runTCPClient)
import           Data.Vector                    (Vector)
import           Protocol                       (Auction (..), ClientProtocol(..),
                                                 ServerProtocol (..), decodeC,
                                                 encodeC)

import System.Posix.Signals (installHandler, Handler(Catch), sigINT, sigTERM)

type Name = Text

data AppState n = AppState { _showConnectionClosed :: Bool
                           , _serverChannel        :: BChan ClientProtocol
                           , _auctions             :: Vector Auction
                           }

data AppEvent
  = ServerEvent ServerProtocol
  | Signal
  deriving (Show)

makeLenses ''AppState

drawUI :: AppState Name -> [Widget Text]
drawUI AppState {_showConnectionClosed, _auctions} =
  [ withBorderStyle unicode $
    borderWithLabel (str "Client") $
    vLimit 20 (hLimit 30 $ auctionListW "auction-list-1" _auctions)
    <=>
    if _showConnectionClosed
    then center (str "Connection closed")
    else emptyWidget
  ]

data FactoryStat = ResourcesPerSecond Int

factoryInfoUI :: Text -> Widget Name
factoryInfoUI name = withAttr factoryListAttr $ border $ L.renderList renderSingle True statsList
  where statsList = L.list name stats 1
        renderSingle b (ResourcesPerSecond n) = str "Stat" <+> str (show n)
        stats = [ ResourcesPerSecond 42
                , ResourcesPerSecond 13
                , ResourcesPerSecond 1337
                , ResourcesPerSecond 123
                , ResourcesPerSecond 7
                ]

auctionListW :: Name -> Vector Auction -> Widget Name
auctionListW name auctions = withAttr auctionListAttr $ border $ L.renderList renderSingle True auctionsList
  where
    auctionsList = L.list name auctions 1
    renderSingle b auction = str (show auction)

initialState :: BChan ClientProtocol -> AppState Name
initialState chan = AppState False chan [Auction "test auction"]

appEvent :: AppState Name -> T.BrickEvent Text AppEvent -> T.EventM Name (T.Next (AppState Name))
appEvent p (T.AppEvent (ServerEvent m)) = case m of
  Close -> M.continue $ p & showConnectionClosed .~ True
  AuctionCreated newAuction -> M.continue $ p & auctions <>~ [newAuction]
  _ -> M.continue p
appEvent p (T.AppEvent Signal) = print "sig INT" >> M.continue p
appEvent p (T.VtyEvent e) =
  case e of
    V.EvKey (V.KChar 'a') [] -> do
      send p $ CreateAuction (Auction "New auction")
      M.continue p

    V.EvKey (V.KChar 'q') [] ->
      M.halt p

    _                        ->
      M.continue p

send :: AppState n -> ClientProtocol -> T.EventM n ()
send p msg = liftIO $ writeBChan (p^.serverChannel) msg

baseAttr, factoryListAttr, auctionListAttr :: A.AttrName
baseAttr = "base"
factoryListAttr = baseAttr <> "factory"
auctionListAttr = baseAttr <> "auction-list"

attributeMap :: A.AttrMap
attributeMap = A.attrMap V.defAttr [ (baseAttr, bg V.blue)
                                   , (factoryListAttr, V.magenta `on` V.yellow)]

app :: M.App (AppState Name) AppEvent Text
app = M.App { M.appDraw = drawUI
            , M.appChooseCursor = M.showFirstCursor
            , M.appHandleEvent = appEvent
            , M.appStartEvent = pure
            , M.appAttrMap = const attributeMap
            }

main :: IO ()
main = do
  inChan <- newBChan 100
  outChan <- newBChan 100
  signalHandler inChan
  forkIO $ connectToServer inChan outChan
  void $ M.customMain (V.mkVty V.defaultConfig) (pure inChan) app (initialState outChan)

signalHandler :: BChan AppEvent -> IO ()
signalHandler chan = void $ installHandler sigINT (Catch (writeBChan chan Signal)) Nothing

connectToServer :: BChan AppEvent -> BChan ClientProtocol -> IO ()
connectToServer inChan outChan = do
  let s = clientSettings 9090 "localhost"
  runTCPClient s (handler inChan outChan)

handler :: BChan AppEvent -> BChan ClientProtocol -> AppData -> IO ()
handler inChan outChan ad = do
  forkIO . runConduit . addCleanup (const $ writeBChan inChan (ServerEvent Close))
     $ bchanSource outChan
    .| encodeC
    .| appSink ad
  runConduit
     $ yield (Authenticate "client_id")
    .| encodeC
    .| appSink ad
  runConduit
     $ appSource ad
    .| decodeC
    .| toAppEvent
    .| bchanSink inChan

toAppEvent :: MonadIO m => ConduitM ServerProtocol AppEvent m ()
toAppEvent = C.map ServerEvent

bchanSink :: MonadIO m => BChan a -> Consumer a m ()
bchanSink chan = C.mapM_ $ liftIO . writeBChan chan

bchanSource :: MonadIO m => BChan a -> Producer m a
bchanSource chan = C.repeatM $ liftIO $ readBChan chan
