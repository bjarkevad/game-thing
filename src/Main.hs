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
import           Control.Lens                   ((.~), (^.))
import           Control.Lens.TH                (makeLenses)
import           Data.Conduit                   (Consumer, Producer, Sink,
                                                 Source, addCleanup, await,
                                                 passthroughSink, runConduit,
                                                 yield, (.|))
import qualified Data.Conduit.Combinators       as C
import           Data.Conduit.Network           (AppData, ClientSettings,
                                                 appSink, appSource,
                                                 clientSettings, runTCPClient)
import           Protocol                       (Production (..),
                                                 ServerMessage (..), decodeC,
                                                 encodeC)

type Name = Text

data AppState n = AppState { _showConnectionClosed :: Bool
                           , _serverChannel        :: BChan ServerMessage
                           }
makeLenses ''AppState

drawUI :: AppState Name -> [Widget Text]
drawUI AppState {_showConnectionClosed} =
  [ withBorderStyle unicode $
    borderWithLabel (str "Hello!") $
    (vLimit 10 (hLimit 30 $ factoryInfoUI "factory-stats-2")) <+>
    (vLimit 10 (hLimit 30 $ factoryInfoUI "factory-stats-1")) <=>
    if _showConnectionClosed
    then (center (str "Connection closed"))
    else emptyWidget
  ]

data FactoryStat = ResourcesPerSecond Int

factoryInfoUI :: Text -> Widget Text
factoryInfoUI name = withAttr factoryListAttr $ border $ L.renderList renderSingle True statsList
  where statsList = L.list name stats 1
        renderSingle b (ResourcesPerSecond n) = str "Stat" <+> str (show n)
        stats = [ ResourcesPerSecond 42
                , ResourcesPerSecond 13
                , ResourcesPerSecond 1337
                , ResourcesPerSecond 123
                , ResourcesPerSecond 7
                ]

initialState :: BChan ServerMessage -> AppState Name
initialState = AppState False

appEvent :: AppState Name -> T.BrickEvent Text ServerMessage -> T.EventM Name (T.Next (AppState Name))
appEvent p (T.AppEvent Close) = M.continue $ p & showConnectionClosed .~ True
appEvent p (T.AppEvent _) = M.continue p
appEvent p (T.VtyEvent e) =
  case e of
    V.EvKey (V.KChar 'a') [] -> do
      send p $ ProductionMessage CreateAuction
      M.continue p

    V.EvKey (V.KChar 'q') [] ->
      M.halt p

    _                        ->
      M.continue p

send :: AppState n -> ServerMessage -> T.EventM n ()
send p msg = liftIO $ writeBChan (p^.serverChannel) (Data "client message")

baseAttr, factoryListAttr :: A.AttrName
baseAttr = "base"
factoryListAttr = baseAttr <> "factory"

attributeMap :: A.AttrMap
attributeMap = A.attrMap V.defAttr [ (baseAttr, bg V.blue)
                                   , (factoryListAttr, V.magenta `on` V.yellow)]

app :: M.App (AppState Name) ServerMessage Text
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
  forkIO $ connectToServer inChan outChan
  void $ M.customMain (V.mkVty V.defaultConfig) (pure inChan) app (initialState outChan)

connectToServer :: BChan ServerMessage -> BChan ServerMessage -> IO ()
connectToServer inChan outChan = do
  let s = clientSettings 9090 "localhost"
  runTCPClient s (handler inChan outChan)

handler :: BChan ServerMessage -> BChan ServerMessage -> AppData -> IO ()
handler inChan outChan ad = do
  forkIO . runConduit . addCleanup (const $ print "Connection closed")
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
    .| bchanSink inChan

bchanSink :: MonadIO m => BChan a -> Consumer a m ()
bchanSink chan = C.mapM_ $ liftIO . writeBChan chan

bchanSource :: MonadIO m => BChan a -> Producer m a
bchanSource chan = C.repeatM $ liftIO $ readBChan chan
