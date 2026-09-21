{-# LANGUAGE OverloadedStrings #-}

-- | pi-json-span-processor
--
-- Reads the JSON-lines event stream emitted by @pi --mode json@ on stdin and
-- aggregates it into another stream of JSON values (one per line) representing
-- spans.
--
-- The complete behavioural specification (span hierarchy, output fields, and
-- content accumulation rules) lives in @SPEC.md@; see that file for details.
--
-- Message spans additionally carry the full structured content of the message
-- in @contentBlocks@: an ordered list of @text@, @thinking@ and @toolCall@
-- blocks.  Blocks are accumulated from intermediate @message_update@
-- @assistantMessageEvent@ markers (@text_start@, @text_delta@, @text_end@,
-- @thinking_start@, @thinking_delta@, @thinking_end@, @toolcall_start@,
-- @toolcall_delta@, @toolcall_end@) keyed by @contentIndex@; partial
-- @toolcall@ argument JSON fragments are decoded into the parsed
-- @arguments@ object.  When @message_end@ carries the authoritative
-- @message.content@ array it is passed through verbatim.
module Main (main) where

import           Data.Aeson                 (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.Key            as Key
import qualified Data.Aeson.KeyMap          as KM
import qualified Data.ByteString.Char8      as BS8
import qualified Data.ByteString.Lazy.Char8 as BL8
import           Data.Char                  (isSpace)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (fromMaybe)
import           Data.Scientific            (toRealFloat)
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import           Data.Time.Clock            (getCurrentTime)
import           Data.Time.Format           (defaultTimeLocale, formatTime)
import           Data.Vector                (toList)
import           System.Exit                (exitFailure)
import           System.IO                  (hFlush, hPutStrLn, isEOF, stderr, stdout)

-- ---------------------------------------------------------------------------
-- JSON access helpers
-- ---------------------------------------------------------------------------

get :: Text -> Value -> Maybe Value
get k (Object o) = KM.lookup (Key.fromText k) o
get _ _          = Nothing

getText :: Text -> Value -> Maybe Text
getText k v = case get k v of
  Just (String s) -> Just s
  _               -> Nothing

getNumber :: Text -> Value -> Maybe Double
getNumber k v = case get k v of
  Just (Number n) -> Just (toRealFloat n)
  _               -> Nothing

getBool :: Text -> Value -> Maybe Bool
getBool k v = case get k v of
  Just (Bool b) -> Just b
  _             -> Nothing

getArray :: Text -> Value -> Maybe [Value]
getArray k v = case get k v of
  Just (Array a) -> Just (toList a)
  _              -> Nothing

getInt :: Text -> Value -> Maybe Int
getInt k v = case get k v of
  Just (Number n) -> Just (round (toRealFloat n :: Double))
  _               -> Nothing

-- ---------------------------------------------------------------------------
-- Usage
-- ---------------------------------------------------------------------------

data Usage = Usage
  { uInput       :: Double
  , uOutput      :: Double
  , uCacheRead   :: Double
  , uCacheWrite  :: Double
  , uReasoning   :: Maybe Double
  , uTotalTokens :: Double
  , uCost        :: Maybe Value
  } deriving (Show)

zeroUsage :: Usage
zeroUsage = Usage 0 0 0 0 Nothing 0 Nothing

-- | Usage objects may omit fields (e.g. \"reasoning\"); parse leniently.
parseUsage :: Value -> Usage
parseUsage v = Usage
  { uInput       = fromMaybe 0 (getNumber "input" v)
  , uOutput      = fromMaybe 0 (getNumber "output" v)
  , uCacheRead   = fromMaybe 0 (getNumber "cacheRead" v)
  , uCacheWrite  = fromMaybe 0 (getNumber "cacheWrite" v)
  , uReasoning   = getNumber "reasoning" v
  , uTotalTokens = fromMaybe 0 (getNumber "totalTokens" v)
  , uCost        = get "cost" v
  }

usageObject :: Usage -> Value
usageObject u = object $
  [ "input"       .= uInput u
  , "output"      .= uOutput u
  , "cacheRead"   .= uCacheRead u
  , "cacheWrite"  .= uCacheWrite u
  , "totalTokens" .= uTotalTokens u
  ] ++
  maybe [] (\r -> ["reasoning" .= r]) (uReasoning u) ++
  maybe [] (\c -> ["cost" .= c]) (uCost u)

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

data OpenSpan = OpenSpan
  { osId       :: Text         -- ^ generated unique span id
  , osStart    :: Text         -- ^ ISO-8601 start timestamp
  , osParentId :: Maybe Text   -- ^ id of the parent span
  , osUsage    :: Usage        -- ^ latest cumulative usage seen in-span
  , osToolName :: Maybe Text   -- ^ tool_execution spans only
  } deriving (Show)

data State = State
  { stAgent        :: Maybe OpenSpan
  , stTurn         :: Maybe OpenSpan
  , stMessage      :: Maybe OpenSpan
  , stToolExecs    :: Map.Map Text (OpenSpan, Text)  -- ^ open tool executions keyed by toolCallId
  , stMsgContent   :: Text            -- ^ accumulated message_update deltas
  , stMsgBlocks    :: Map.Map Int BlockAcc  -- ^ structured content block accumulators keyed by contentIndex
  , stCounter      :: Int             -- ^ unique span id generator
  } deriving (Show)

initialState :: State
initialState = State Nothing Nothing Nothing Map.empty "" Map.empty 0

freshId :: State -> (Text, State)
freshId st =
  let n   = stCounter st + 1
      sid = "span-" <> T.pack (show n)
  in (sid, st { stCounter = n })

-- ---------------------------------------------------------------------------
-- Content extraction helpers
-- ---------------------------------------------------------------------------

-- | Delta payload of a streaming @assistantMessageEvent@.  Only the
-- @*_delta@ variants carry incremental text; start\/end markers are ignored
-- because deltas already cover the same content.
deltaText :: Value -> Text
deltaText ame = case getText "type" ame of
  Just t | t `elem` ["text_delta", "thinking_delta", "toolcall_delta"]
             -> fromMaybe "" (getText "delta" ame)
  _          -> ""

-- | Concatenated text blocks of a message object (from @message_end@).
messageText :: Value -> Maybe Text
messageText msg = case get "content" msg of
  Just (String s) -> Just s
  Just (Array _)  -> T.concat . map blockText <$> getArray "content" msg
  _               -> Nothing
  where
    blockText b = fromMaybe "" (getText "text" b)

-- | Concatenated text blocks of a tool result object
-- (@{content:[{type:"text",text:...},...]})@.
-- | Concatenated text blocks of a tool result object
-- (@{content:[{type:"text",text:...},...]})@.
resultText :: Value -> Maybe Text
resultText = messageText

-- ---------------------------------------------------------------------------
-- Structured content blocks (full message content)
-- ---------------------------------------------------------------------------

-- | Accumulator for one structured content block of an assistant message,
-- keyed by the @contentIndex@ of the @assistantMessageEvent@ that carries it.
data BlockAcc = BlockAcc
  { baType     :: Text        -- ^ "text", "thinking" or "toolCall"
  , baText     :: Text        -- ^ accumulated delta text (text/thinking blocks)
  , baCallId   :: Maybe Text  -- ^ toolcall block: @id@ from toolcall_start
  , baToolName :: Maybe Text  -- ^ toolcall block: @toolName@ from toolcall_start
  , baArgsRaw  :: Text        -- ^ toolcall block: concatenated partial-JSON argument fragments
  , baFinal    :: Maybe Value -- ^ authoritative block from a *_end marker, if any
  } deriving (Show)

emptyBlock :: Text -> BlockAcc
emptyBlock t = BlockAcc t "" Nothing Nothing "" Nothing

-- | New toolcall block accumulator seeded from a @toolcall_start@
-- (or @toolcall_delta@) @assistantMessageEvent@.
emptyToolCall :: Value -> BlockAcc
emptyToolCall ame = BlockAcc "toolCall" "" (getText "id" ame) (getText "toolName" ame) "" Nothing

-- | Apply one @assistantMessageEvent@ to the open block accumulators.
applyAme :: Map.Map Int BlockAcc -> Value -> Map.Map Int BlockAcc
applyAme m ame = case (getText "type" ame, getInt "contentIndex" ame) of
  (Just t, Just i) -> apply t i m
  _                -> m
  where
    delta = fromMaybe "" (getText "delta" ame)
    apply t i = case t of
      "text_start"      -> Map.insert i (emptyBlock "text")
      "thinking_start"  -> Map.insert i (emptyBlock "thinking")
      "toolcall_start"  -> Map.insert i (emptyToolCall ame)
      "text_delta"      -> Map.alter (Just . appendText delta . fromMaybe (emptyBlock "text")) i
      "thinking_delta"  -> Map.alter (Just . appendText delta . fromMaybe (emptyBlock "thinking")) i
      "toolcall_delta"  -> Map.alter (Just . appendArgs delta . fromMaybe (emptyToolCall ame)) i
      "text_end"        -> Map.alter (fmap . setFinalText $ getText "content" ame) i
      "thinking_end"    -> Map.alter (fmap . setFinalText $ getText "content" ame) i
      "toolcall_end"    -> Map.alter (fmap . setFinal $ get "toolCall" ame) i
      _                 -> id
    appendText d b = b { baText = baText b <> d }
    appendArgs d b = b { baArgsRaw = baArgsRaw b <> d }
    setFinalText (Just c) b = b { baText = c }
    setFinalText Nothing  b = b
    setFinal (Just v) b = b { baFinal = Just v }
    setFinal Nothing  b = b

-- | Construct the structured block value of one accumulator.  A block with an
-- authoritative @*_end@ payload is used verbatim; a toolcall block's partial
-- JSON argument fragments are decoded into the parsed @arguments@ object
-- (falling back to @argumentsRaw@ if they do not form valid JSON).
blockValue :: BlockAcc -> Value
blockValue b = case baFinal b of
  Just v  -> v
  Nothing -> case baType b of
    "toolCall" ->
      let args = decode (BL8.fromStrict (TE.encodeUtf8 (baArgsRaw b))) :: Maybe Value
      in object $
           [ "type" .= ("toolCall" :: Text) ]
           ++ maybe [] (\i -> ["id" .= i]) (baCallId b)
           ++ maybe [] (\n -> ["name" .= n]) (baToolName b)
           ++ maybe ["argumentsRaw" .= baArgsRaw b] (\v -> ["arguments" .= v]) args
    "thinking" -> object [ "type" .= ("thinking" :: Text), "thinking" .= baText b ]
    _          -> object [ "type" .= ("text" :: Text), "text" .= baText b ]

-- | Ordered (by @contentIndex@) structured content blocks.
buildContentBlocks :: Map.Map Int BlockAcc -> [Value]
buildContentBlocks = map blockValue . Map.elems

-- | Merge a cumulative @partialResult@ snapshot into the accumulated text.
-- pi sends full snapshots, so the merged result is the latest snapshot when
-- it extends what we already have, otherwise plain concatenation.
appendCumulative :: Text -> Text -> Text
appendCumulative acc curr
  | T.null curr            = acc
  | curr == acc            = acc
  | curr `T.isPrefixOf` acc = acc          -- stale snapshot, ignore
  | acc `T.isPrefixOf` curr = curr         -- cumulative snapshot
  | otherwise              = acc <> curr   -- genuine delta

-- ---------------------------------------------------------------------------
-- Timestamps
-- ---------------------------------------------------------------------------

isoNow :: IO Text
isoNow = do
  t <- getCurrentTime
  pure (T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%03QZ" t))

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("pi-json-span-processor: error: " ++ msg)
  exitFailure

require :: Maybe a -> String -> IO a
require Nothing msg = die msg
require (Just x) _  = pure x

-- | Process one non-session, non-agent_settled event.
handleEvent :: Text -> Value -> State -> IO State
handleEvent ty obj st = case ty of
  "agent_start"           -> agentStart
  "agent_end"             -> agentEnd
  "turn_start"            -> turnStart
  "turn_end"              -> turnEnd
  "message_start"         -> messageStart
  "message_update"        -> messageUpdate
  "message_end"           -> messageEnd
  "tool_execution_start"  -> toolStart
  "tool_execution_update" -> toolUpdate
  "tool_execution_end"    -> toolEnd
  other                   -> die ("unknown event type: " ++ T.unpack other)
  where
    agentStart = do
      now <- isoNow
      let (sid, st1) = freshId st
          sp = OpenSpan sid now Nothing zeroUsage Nothing
      pure st1 { stAgent = Just sp }

    agentEnd = do
      now <- isoNow
      sp  <- require (stAgent st) "agent_end without matching agent_start"
      emit $ object
        [ "span"  .= ("agent" :: Text)
        , "id"    .= osId sp
        , "start" .= osStart sp
        , "end"   .= now
        ]
      pure st { stAgent = Nothing }

    turnStart = do
      now <- isoNow
      agentSp <- require (stAgent st) "turn_start without open agent span"
      let (sid, st1) = freshId st
          sp = OpenSpan sid now (Just (osId agentSp)) zeroUsage Nothing
      pure st1 { stTurn = Just sp }

    turnEnd = do
      now <- isoNow
      sp  <- require (stTurn st) "turn_end without matching turn_start"
      emit $ object
        [ "span"     .= ("turn" :: Text)
        , "id"       .= osId sp
        , "start"    .= osStart sp
        , "end"      .= now
        , "parentId" .= osParentId sp
        ]
      pure st { stTurn = Nothing }

    messageStart = do
      now <- isoNow
      turnSp <- require (stTurn st) "message_start without open turn span"
      let (sid, st1) = freshId st
          sp = OpenSpan sid now (Just (osId turnSp)) zeroUsage Nothing
      pure st1 { stMessage = Just sp, stMsgContent = "" }

    messageUpdate = do
      sp <- require (stMessage st) "message_update without open message span"
      let usage  = maybe zeroUsage parseUsage (get "usage" obj)
          delta  = maybe "" deltaText (get "assistantMessageEvent" obj)
          blocks = maybe (stMsgBlocks st) (applyAme (stMsgBlocks st))
                         (get "assistantMessageEvent" obj)
      pure st { stMessage   = Just sp { osUsage = usage }
              , stMsgContent = stMsgContent st <> delta
              , stMsgBlocks  = blocks
              }

    messageEnd = do
      now <- isoNow
      sp  <- require (stMessage st) "message_end without matching message_start"
      let finalUsage = do
            msg <- get "message" obj
            u   <- get "usage" msg
            pure (parseUsage u)
          content = case messageText =<< get "message" obj of
            Just t | not (T.null t) -> t
            _                       -> stMsgContent st
          endBlocks = case get "message" obj of
            Just msg -> case get "content" msg of
              Just (Array _) -> case getArray "content" msg of
                Just bs | not (null bs) -> Just bs
                _                       -> Nothing
              Just (String s) -> Just [object ["type" .= ("text" :: Text), "text" .= s]]
              _               -> Nothing
            Nothing -> Nothing
          contentBlocks = fromMaybe
            (buildContentBlocks (stMsgBlocks st))
            endBlocks
      emit $ object
        [ "span"     .= ("message" :: Text)
        , "id"       .= osId sp
        , "start"    .= osStart sp
        , "end"      .= now
        , "parentId" .= osParentId sp
        , "content"  .= content
        , "contentBlocks" .= contentBlocks
        , "usage"    .= usageObject (fromMaybe (osUsage sp) finalUsage)
        ]
      pure st { stMessage = Nothing, stMsgContent = "", stMsgBlocks = Map.empty }

    toolStart = do
      now <- isoNow
      turnSp <- require (stTurn st) "tool_execution_start without open turn span"
      callId <- require (getText "toolCallId" obj)
                  "tool_execution_start without toolCallId"
      toolName <- require (getText "toolName" obj)
                    "tool_execution_start without toolName"
      let (sid, st1) = freshId st
          sp = OpenSpan sid now (Just (osId turnSp)) zeroUsage (Just toolName)
      pure st1 { stToolExecs = Map.insert callId (sp, "") (stToolExecs st1) }

    toolUpdate = do
      callId <- require (getText "toolCallId" obj)
                  "tool_execution_update without toolCallId"
      (sp, acc) <- require (Map.lookup callId (stToolExecs st))
                     ("tool_execution_update without open tool_execution span for toolCallId "
                      ++ T.unpack callId)
      let partial = fromMaybe "" (get "partialResult" obj >>= resultText)
      pure st { stToolExecs = Map.insert callId (sp, appendCumulative acc partial)
                                (stToolExecs st) }

    toolEnd = do
      now <- isoNow
      callId <- require (getText "toolCallId" obj)
                  "tool_execution_end without toolCallId"
      (sp, acc) <- require (Map.lookup callId (stToolExecs st))
                     ("tool_execution_end without matching tool_execution_start for toolCallId "
                      ++ T.unpack callId)
      let isError = fromMaybe False (getBool "isError" obj)
          content = case get "result" obj >>= resultText of
            Just t | not (T.null t) -> t
            _                       -> acc
      emit $ object
        [ "span"     .= ("tool_execution" :: Text)
        , "id"       .= osId sp
        , "start"    .= osStart sp
        , "end"      .= now
        , "parentId" .= osParentId sp
        , "toolName" .= osToolName sp
        , "isError"  .= isError
        , "content"  .= content
        , "usage"    .= usageObject (osUsage sp)
        ]
      pure st { stToolExecs = Map.delete callId (stToolExecs st) }

    emit v = do
      BL8.putStrLn (encode v)
      hFlush stdout

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

decodeValue :: BS8.ByteString -> Maybe Value
decodeValue = decode . BL8.fromStrict

main :: IO ()
main = loop initialState
  where
    loop :: State -> IO ()
    loop st = do
      eof <- isEOF
      if eof
        then pure ()
        else do
          line <- BS8.getLine
          if BS8.all isSpace line
            then loop st
            else case decodeValue line of
              Nothing -> die ("invalid JSON line: " ++ T.unpack (TE.decodeUtf8 line))
              Just v  -> case getText "type" v of
                Nothing -> die ("event without a string \"type\" field: "
                                ++ T.unpack (TE.decodeUtf8 line))
                Just "session" -> do
                  -- pass through unmodified
                  BS8.putStrLn line
                  hFlush stdout
                  loop st
                Just "agent_settled" -> loop st   -- discarded
                Just ty              -> do
                  st' <- handleEvent ty v st
                  loop st'
