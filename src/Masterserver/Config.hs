{-# LANGUAGE OverloadedStrings #-}
------------------------------------------------------------------------------
-- |
-- Copyright 2016-2016 the openage authors. See copying.md for legal info.
-- Module: Masterserver.Config
--
-- This Module defines the masterservers config parser.

------------------------------------------------------------------------------
module Masterserver.Config (

  -- * loads config
  loadConf,
  -- ** get Values from config
  loadCfgStr, getPort, getVersion

  )where

import Prelude hiding (concat, lookup, putStrLn)
import Data.ByteString
import Control.Concurrent
import Data.Configurator
import Data.Configurator.Types

loadConf :: IO (Config, ThreadId)
loadConf = autoReload autoConfig [Required "etc/openage/masterserver.cfg"]

loadCfgStr :: Config -> IO ByteString
loadCfgStr config = do
  host <- require config "database.host"
  dbname <- require config "database.dbname"
  user <- require config "database.user"
  password <- require config "database.password"
  port <- require config "database.port"
  return $ concat ["host=", host,
                   " dbname=", dbname,
                   " user=", user,
                   " password=", password,
                   " port=", port]

getPort :: Config -> IO Int
getPort config = require config "port"

getVersion :: Config -> IO [Int]
getVersion config = require config "acceptedVersion"