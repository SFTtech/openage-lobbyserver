{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Copyright 2016-2016 the openage authors. See copying.md for legal info.
-- Module: Main
--
-- Main entry file for the openage masterserver
-- this server will listen on a tcp socket
-- and provide a funny API for gameservers and clients
-- to start communicating with each other.

-----------------------------------------------------------------------------
module Main where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Exception.Base (finally)
import Control.Monad
import Crypto.BCrypt
import Data.Aeson
import Data.ByteString as B
import Data.ByteString.Lazy as BL
import Data.ByteString.Char8 as BC
import Data.List as L
import Data.Map.Strict as Map
import Data.Maybe
import Data.Text as T
import Data.Version (makeVersion)
import Database.Persist
import Network.Socket hiding (Broadcast)
import Text.Printf
import System.IO as S

import Masterserver.Config
import Masterserver.Database
import Masterserver.Protocol as P
import Masterserver.Server

extractIP :: SockAddr -> String
extractIP (SockAddrInet _ host) =
  let (a, b, c, d) = hostAddressToTuple host
  in  show a <> "." <> show b <> "." <> show c <> "." <> show d
extractIP (SockAddrInet6 _ _ host _) = show host
extractIP x                          = show x

main :: IO ()
main = createDB *> go
  where
    go = withSocketsDo $ do
      port <- getPort
      server <- newServer
      let hints = defaultHints { addrSocketType = Stream }
      addr:_ <- getAddrInfo (Just hints) (Just "0.0.0.0") (Just $ show port)
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      bind sock  (addrAddress addr)
      listen sock 1024
      printf "Listening on port %d\n" port
      forever $ do
          (clientSock, host) <- accept sock
          handle <- socketToHandle clientSock ReadWriteMode
          let clientIP = extractIP host
          printf "Accepted connection from %s\n" clientIP
          forkFinally (talk handle server clientIP) (\e -> do
            print e
            printf "Connection from %s closed\n" clientIP >> hClose handle)

talk :: Handle -> Server -> HostName -> IO()
talk handle server hostname = do
  S.hSetNewlineMode handle universalNewlineMode
  S.hSetBuffering handle LineBuffering
  checkVersion handle
  mayClient <- checkAddClient handle server hostname
  case mayClient of
    Just client@Client{..} -> do
      sendMessage handle "Login success."
      runClient server client
        `finally` removeClientLeave server clientName
    Nothing ->
      sendError handle "Login failed."

-- | Compare Version to own
checkVersion :: S.Handle -> IO ()
checkVersion handle = do
  verJson <- B.hGetLine handle
  myVersion <- getVersion
  if ( peerProtocolVersion
     . fromJust
     . decode
     . BL.fromStrict) verJson == makeVersion myVersion
    then
      sendMessage handle "Version accepted."
    else do
      sendError handle "Incompatible Version."
      thread <- myThreadId
      killThread thread

-- | Get login credentials from handle, add client to servers
-- clientmap and return Client
checkAddClient :: Handle -> Server -> HostName -> IO(Maybe Client)
checkAddClient handle server@Server{..} hostname = do
  loginJson <- B.hGetLine handle
  case (decode . BL.fromStrict) loginJson of
    Just Login{..} -> do
      let toBs = BC.pack . T.unpack
      Just (Entity _ Player{..}) <- getPlayer loginName
      if validatePassword playerPassword (toBs loginPassword)
        then do
          clientMap <- readTVarIO clients
          client <- newClient playerUsername hostname handle
          if member playerUsername clientMap
            then do
              sendChannel (clientMap!playerUsername) Logout
              atomically $ addClient server client
              return $ Just client
            else do
              atomically $ addClient server client
              return $ Just client
        else return Nothing
    Just AddPlayer{..} -> do
      hash <- hashPw pw
      res <- addPlayer name hash
      maybe (sendError handle "Name taken."
             >> checkAddClient handle server hostname)
        (\_ -> sendMessage handle "Player successfully added."
               >> checkAddClient handle server hostname) res
    _ -> do
      sendError handle "Unknown Format."
      return Nothing

-- | Uses BCrypt to hash pw before writing it to db
hashPw :: Text             -- ^ Password sent by client
       -> IO BC.ByteString -- ^ salted password hash
hashPw pw = do
  let toBs = BC.pack . T.unpack
  mayHash <- hashPasswordUsingPolicy slowerBcryptHashingPolicy $ toBs pw
  maybe (error "Hashing failed") return mayHash

-- | Runs individual Client
runClient :: Server -> Client -> IO ()
runClient server@Server{..} client@Client{..} = do
  _ <- race internalReceive $ mainLoop server client
  return ()
    where
      internalReceive = forever $ do
        msg <- B.hGetLine clientHandle
        maybe (sendError clientHandle "Could not read message.")
          (sendChannel client) $ (decode . BL.fromStrict) msg

-- | Main Lobby loop with ClientMessage Handler functions
mainLoop :: Server -> Client -> IO ()
mainLoop server@Server{..} client@Client{..} = do
  msg <- atomically $ readTChan clientChan
  case msg of
    GameQuery -> do
      gameLis <- atomically $ getGameList server
      sendGameQueryAnswer clientHandle gameLis
      mainLoop server client
    GameInit{..} -> do
      -- | check if name not taken, return game if successful
      maybeGame <- atomically $ checkAddGame server clientName msg
      maybe
        -- | send Error and return to mainLoop if failed
        (sendError clientHandle "Failed adding game."
             >> mainLoop server client)
        -- | Add game to client, client to game and go to gameLoop
        (\ Game{..} ->
          atomically (joinGame server clientName gameName True)
          >> sendMessage clientHandle "Added game."
          >> gameLoop server client gameInitName) maybeGame
    GameJoin{..} -> do
      gameLis <- readTVarIO games
      case member gameId gameLis of
        True
          | Game{..} <- gameLis!gameId
          , Map.size gamePlayers < numPlayers -> do
              atomically $ joinGame server clientName gameId False
              sendMessage clientHandle "Joined Game."
              gameLoop server client gameName
          | otherwise -> do
              sendError clientHandle "Game is full."
              mainLoop server client
        _ -> do
          sendError clientHandle "Game does not exist."
          mainLoop server client
    Logout ->
      sendMessage clientHandle "You have been logged out."
    _ -> do
      sendError clientHandle "Unknown Message."
      mainLoop server client

-- | Gamestate loop
gameLoop :: Server -> Client -> GameName -> IO ()
gameLoop server@Server{..} client@Client{..} game= do
  msg <- atomically $ readTChan clientChan
  gameLis <- readTVarIO games
  let isHost = clientName == gameHost (gameLis!game)
      thisPlayers = gamePlayers $ gameLis!game
  case msg of
    ChatFromClient{..} -> do
      broadcastGame server game
        $ ChatFromThread clientName chatFromCContent
      gameLoop server client game
    ChatFromThread{..} -> do
      sendEncoded clientHandle
        $ ChatOut chatFromTOrign chatFromTContent
      gameLoop server client game
    GameStart
      | isHost && L.all parReady thisPlayers -> do
          clientLis <- readTVarIO clients
          broadcastGame server game GameStartedByHost
          sendEncoded clientHandle
            $ GameStartAnswer $ convMap clientLis (keys thisPlayers)
          gameLoop server client game
      | isHost -> do
          sendError clientHandle "Players not ready."
          gameLoop server client game
      | otherwise -> do
          sendError clientHandle "Only the host can start the game."
          gameLoop server client game
    GameInfo -> do
      sendEncoded clientHandle $ GameInfoAnswer (gameLis!game)
      gameLoop server client game
    GameConfig{..}
      | isHost &&
        gameConfPlayerNum >= (Map.size . gamePlayers) (gameLis!game)-> do
          atomically $ do
            gamesMap <- readTVar games
            writeTVar games
              $ Map.adjust (updateGame gameConfMap gameConfMode
                            gameConfPlayerNum) game gamesMap
          gameLoop server client game
      | isHost -> do
          sendError clientHandle "Can't choose less Players."
          gameLoop server client game
      | otherwise -> do
          sendError clientHandle "Unknown Message."
          inGameLoop server client game
    GameClosedByHost -> do
      atomically $ leaveGame server clientName game
      sendMessage clientHandle "Game was closed by Host."
      mainLoop server client
    GameLeave -> do
      gameLeaveHandler server client game
      gameLoop server client game
    GameStartedByHost -> do
      sendMessage clientHandle "Game started..."
      inGameLoop server client game
    PlayerConfig{..} -> do
      atomically $ do
        gamesMap <- readTVar games
        writeTVar games
          $ Map.adjust (updatePlayer clientName playerCiv playerTeam
                        playerReady) game gamesMap
      gameLoop server client game
    Logout ->
      sendMessage clientHandle "You have been logged out."
    _ -> do
      sendError clientHandle "Unknown Message."
      gameLoop server client game

-- | Loop for Host in running Game
inGameLoop :: Server -> Client -> GameName -> IO ()
inGameLoop server@Server{..} client@Client{..} game = do
  msg <- atomically $ readTChan clientChan
  gameLis <- readTVarIO games
  let isHost = clientName == gameHost (gameLis!game)
  case msg of
    Broadcast{..} -> do
      sendMessage clientHandle content
      inGameLoop server client game
    ChatFromClient{..} -> do
      broadcastGame server game
        $ ChatFromThread clientName chatFromCContent
      inGameLoop server client game
    ChatFromThread{..} -> do
      sendEncoded clientHandle
        $ ChatOut chatFromTOrign chatFromTContent
      inGameLoop server client game
    GameClosedByHost -> do
      atomically $ leaveGame server clientName game
      sendMessage clientHandle "Game was closed by Host."
      mainLoop server client
    GameLeave -> do
      gameLeaveHandler server client game
      gameLoop server client game
    GameOver
      | isHost -> do
          broadcastGame server game $ Broadcast "Game Over."
          gameLeaveHandler server client game
          inGameLoop server client game
      | otherwise -> do
          sendError clientHandle "Unknown Message."
          inGameLoop server client game
    Logout ->
      sendMessage clientHandle "You have been logged out."
    _ -> do
      sendError clientHandle "Unknown Message."
      inGameLoop server client game

