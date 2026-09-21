{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | honstarehand: a command line tool that manages runs of the pi microvm
-- (@run-pi-microvm@ from the frontArmToPlane flake) whose configuration
-- lives in the @runConfigs@ attribute set of a nix flake, tracking every
-- run in a postgresql @run@ table.
--
-- Subcommands:
--
--   * @run --config FILE <flakeref>#<name>@: validate the flake and its
--     @runConfigs.<name>@ entry, insert a run entry in the database, run
--     the microvm against a fresh @mktemp -d@ workdir, monitor its state
--     while it runs, and on success turn the workdir into a nix store
--     derivation whose path is stored in the entry and printed.
--
--   * @list --config FILE [-s STATUS]@: list @run@ table entries, by
--     default only the ones still ongoing or initializing; the @--status@
--     option takes a string of status letters (o d i t) filtering which
--     entries are displayed. The output is a nushell-friendly table:
--     whitespace-aligned columns with single-word headers, so a nushell
--     user can simply run @honstarehand list ... | detect columns@ to get a
--     proper structured table (timestamps are ISO-8601, space-free, so
--     they stay in one column).
--
--   * @config-guide@: print a description of how to properly write the
--     TOML configuration file consumed by the other subcommands.
--
-- The TOML config file states the /path/ of a file holding the openrouter
-- API key rather than the key itself: the key is never read into honstarehand's
-- memory, logged, or copied; only the path is ever passed on.
module Main (main) where

import           Control.Concurrent          (threadDelay)
import           Control.Exception           (SomeException, bracket, try)
import           Control.Monad               (forM_, unless, void, when)
import           Data.Aeson                  (Value (..))
import qualified Data.Aeson                  as Aeson
import qualified Data.Aeson.Key              as Key
import qualified Data.Aeson.Types            as Aeson
import qualified Data.ByteString.Char8       as BSC
import           Data.Char                   (isSpace)
import           Data.Foldable               (toList)
import qualified Data.Scientific             as Scientific
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import qualified Data.Text.IO                as TIO
import           Data.Time                   (UTCTime, formatTime,
                                              getCurrentTime)
import           Data.Time.Format            (defaultTimeLocale)
import           Database.PostgreSQL.Simple  (Connection, Only (..), close,
                                              connectPostgreSQL, execute,
                                              execute_, query)
import           Database.PostgreSQL.Simple.Types (Query (..))
import           Options.Applicative
import           System.Directory            (doesDirectoryExist,
                                              doesFileExist)
import           System.Environment          (lookupEnv)
import           System.Exit                 (ExitCode (..), exitWith)
import           System.FilePath             ((</>))
import           System.IO                   (IOMode (WriteMode), hClose,
                                              hPutStrLn, stderr, withFile)
import           System.Posix.Files          (fileMode, getFileStatus)
import           System.Posix.Types          (FileMode)
import           Data.Bits                   ((.&.), (.|.))
import           System.Process              (CreateProcess (..),
                                              StdStream (CreatePipe,
                                              UseHandle), createProcess,
                                              getProcessExitCode, proc,
                                              readProcess,
                                              readProcessWithExitCode)
import qualified Toml
import Toml ((.=))

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | The four statuses a run entry can have.
data RunStatus = Initializing | Ongoing | Done | Terminated
    deriving (Eq, Ord, Show, Enum, Bounded)

statusName :: RunStatus -> Text
statusName Initializing = "initializing"
statusName Ongoing      = "ongoing"
statusName Done         = "done"
statusName Terminated   = "terminated"

statusFromChar :: Char -> Maybe RunStatus
statusFromChar 'o' = Just Ongoing
statusFromChar 'd' = Just Done
statusFromChar 'i' = Just Initializing
statusFromChar 't' = Just Terminated
statusFromChar _   = Nothing

-- | The parsed TOML config file: a URL to the postgresql server and the
-- path of a file holding the openrouter API key handed to the VM.
data Config = Config
    { cfgDatabaseUrl         :: String
    , cfgOpenRouterApiKeyFile :: FilePath
    }

configCodec :: Toml.TomlCodec Config
configCodec =
    Config
        <$> (Toml.string "databaseUrl" .= cfgDatabaseUrl)
        <*> (Toml.string "openrouterApiKeyFile" .= cfgOpenRouterApiKeyFile)

-- | A validated @runConfigs.<name>@ element of the flake.
data RunConfig = RunConfig
    { rcRoDirs :: [FilePath]
    , rcRwDirs :: [FilePath]
    , rcDisk   :: Integer
    , rcRam    :: Integer
    , rcModel  :: Text
    , rcPrompt :: Text
    }

-- | CLI options.
data Options
    = OptRun
        { optConfigFile   :: FilePath
        , optRunPiMicrovm :: Maybe FilePath
        , optFlakeArg     :: String
        }
    | OptList
        { optConfigFile   :: FilePath
        , optStatusChars  :: Maybe String
        }
    | OptConfigGuide

-- ---------------------------------------------------------------------------
-- CLI parsing
-- ---------------------------------------------------------------------------

configOpt :: Parser FilePath
configOpt =
    strOption
        (  long "config"
        <> short 'c'
        <> metavar "FILE"
        <> help "path of the TOML config file (database URL + path of the \
                \openrouter API key file)"
        )

runPiMicrovmOpt :: Parser (Maybe FilePath)
runPiMicrovmOpt =
    optional
        ( strOption
            (  long "run-pi-microvm"
            <> metavar "PATH"
            <> help "path of the run-pi-microvm script (default: resolved \
                    \from $HONSTAREHAND_RUN_PI_MICROVM, then built from the \
                    \frontArmToPlane flake)"
            )
        )

flakeArg :: Parser String
flakeArg =
    strArgument
        (  metavar "<flakeref>#<runConfig>"
        <> help "flake ref plus the name of one of its runConfigs outputs"
        )

statusOpt :: Parser (Maybe String)
statusOpt =
    optional
        ( strOption
            (  long "status"
            <> short 's'
            <> metavar "STATUS"
            <> help "which entries to list, as a string of status letters: \
                    \o=ongoing, d=done, i=initializing, t=terminated, \
                    \e.g. --status it (default: oi, i.e. ongoing + initializing)"
            )
        )

runParser :: Parser Options
runParser = OptRun <$> configOpt <*> runPiMicrovmOpt <*> flakeArg

listParser :: Parser Options
listParser = OptList <$> configOpt <*> statusOpt

configGuideParser :: Parser Options
configGuideParser = pure OptConfigGuide

optionsParser :: Parser Options
optionsParser =
    hsubparser
        (  command "run"  (info runParser  (progDesc "run a flake runConfig in the pi microvm"))
        <> command "list" (info listParser (progDesc "list run entries in the database"))
        <> command "config-guide"
                   (info configGuideParser
                         (progDesc "print how to write the TOML config file"))
        )

main :: IO ()
main = do
    opts <- execParser (info (optionsParser <**> helper) fullDesc)
    case opts of
        OptRun{..}  -> runCommand optConfigFile optRunPiMicrovm optFlakeArg
        OptList{..} -> listCommand optConfigFile optStatusChars
        OptConfigGuide -> configGuideCommand

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

loadConfig :: FilePath -> IO Config
loadConfig path = do
    exists <- doesFileExist path
    unless exists $ fail ("config file not found: " ++ path)
    cfg <- Toml.decodeFile configCodec path
    let keyFile = cfgOpenRouterApiKeyFile cfg
    when (null keyFile) $
        fail "empty openrouterApiKeyFile in the config"
    keyExists <- doesFileExist keyFile
    unless keyExists $
        fail ("openrouterApiKeyFile does not exist: " ++ keyFile)
    -- The key file must be readable by the current user only: warn loudly
    -- about any other bit, and never print the key itself.
    st <- getFileStatus keyFile
    let mode = fileMode st
        groupOtherRead = 0o0040 .|. 0o0004 :: FileMode
    when (mode .&. groupOtherRead /= 0) $
        hPutStrLn stderr ("honstarehand: warning: " ++ keyFile ++
            " is readable by group or others; a mode-0600 key file is " ++
            "recommended")
    -- Check that the key file is not empty, without ever echoing its
    -- contents.
    key <- TIO.readFile keyFile
    when (T.null (T.strip key)) $
        fail ("openrouterApiKeyFile is empty: " ++ keyFile)
    pure cfg

withDb :: Config -> (Connection -> IO a) -> IO a
withDb cfg action = do
    conn <- connectPostgreSQL (BSC.pack (cfgDatabaseUrl cfg))
    bracket (pure conn) close action

ensureSchema :: Connection -> IO ()
ensureSchema conn = void (execute_ conn
    "CREATE TABLE IF NOT EXISTS run (\
        \ id SERIAL PRIMARY KEY\
        \, config TEXT NOT NULL\
        \, workdir TEXT NOT NULL\
        \, status TEXT NOT NULL CHECK (status = ANY (ARRAY['ongoing'::text, 'done'::text, 'initializing'::text, 'terminated'::text]))\
        \, \"startTime\" TIMESTAMPTZ NOT NULL\
        \, \"endTime\" TIMESTAMPTZ\
        \, output TEXT\
    \)")

-- Run a nix command, failing with a readable message when it exits nonzero.
runNix :: FilePath -> [String] -> IO String
runNix cmd args = do
    (exitCode, out, err) <- readProcessWithExitCode cmd args ""
    case exitCode of
        ExitSuccess   -> pure out
        ExitFailure _ -> fail (cmd ++ " " ++ unwords args ++ " failed:\n" ++ err)

trim :: String -> String
trim = f . f
  where
    f = reverse . dropWhile isSpace

-- ---------------------------------------------------------------------------
-- Flake validation
-- ---------------------------------------------------------------------------

-- | Split @<flakeref>#<name>@ into its two halves, requiring both.
splitFlakeArg :: String -> IO (String, String)
splitFlakeArg arg =
    case break (== '#') arg of
        (ref, '#' : name)
            | not (null ref), not (null name) -> pure (ref, name)
        _ ->
            fail ("invalid flake argument " ++ show arg ++
                  ": expected the form <flakeref>#<runConfig>")

-- Validate the flake ref itself (`nix flake metadata`).
validateFlakeRef :: String -> IO ()
validateFlakeRef ref = do
    (exitCode, _, err) <-
        readProcessWithExitCode "nix" ["flake", "metadata", "--json", ref] ""
    case exitCode of
        ExitSuccess   -> pure ()
        ExitFailure _ ->
            fail ("invalid flake ref " ++ show ref ++ ": " ++ err)

-- Fetch the store path of the flake (`nix flake prefetch`).
flakeStorePath :: String -> IO FilePath
flakeStorePath ref = do
    out <- runNix "nix" ["flake", "prefetch", "--json", ref]
    case Aeson.decodeStrict (BSC.pack out) :: Maybe Value of
        Nothing -> fail ("could not parse the nix flake prefetch output: " ++ out)
        Just v ->
            case Aeson.parseMaybe
                     (Aeson.withObject "prefetch" (Aeson..: "storePath")) v of
                Just p  -> pure (p :: FilePath)
                Nothing -> fail ("no storePath in the nix flake prefetch output: " ++ out)

-- Evaluate @runConfigs.<name>@ of the flake and validate its shape.
evalRunConfig :: String -> String -> IO RunConfig
evalRunConfig ref name = do
    out <- runNix "nix" ["eval", "--json", ref ++ "#runConfigs." ++ name]
    value <- case Aeson.decodeStrict (BSC.pack out) :: Maybe Value of
        Just v  -> pure v
        Nothing -> fail ("could not parse the runConfigs." ++ name ++
                         " evaluation output: " ++ out)
    case Aeson.parseEither runConfigParser value of
        Left err -> fail ("invalid runConfigs." ++ name ++ ": " ++ err)
        Right rc -> pure rc

runConfigParser :: Value -> Aeson.Parser RunConfig
runConfigParser = Aeson.withObject "runConfig" $ \obj -> do
    rcRoDirs <- pathList "roDirs" obj
    rcRwDirs <- pathList "rwDirs" obj
    rcDisk   <- positiveInt "disk" obj
    rcRam    <- positiveInt "ram" obj
    rcModel  <- stringField "model" obj
    rcPrompt <- stringField "prompt" obj
    pure RunConfig{..}
  where
    pathList key obj = do
        v <- obj Aeson..: Key.fromText key
        case v of
            Array items -> mapM asString (toListOfValues items)
            _           -> fail (T.unpack key ++ " must be a list of paths")
    asString (String t) = pure (T.unpack t)
    asString _          = fail "runConfig path lists must only contain strings"
    positiveInt key obj = do
        v <- obj Aeson..: Key.fromText key
        case v of
            Number sci ->
                case Scientific.floatingOrInteger sci :: Either Double Integer of
                    Right i | i > 0 -> pure i
                    _ -> fail (T.unpack key ++ " must be a positive integer")
            _ -> fail (T.unpack key ++ " must be a positive integer")
    stringField key obj = do
        v <- obj Aeson..: Key.fromText key
        case v of
            String t -> pure t
            _        -> fail (T.unpack key ++ " must be a string")

-- aeson's Array is Foldable, so it converts to a plain list of Values.
toListOfValues :: Aeson.Array -> [Value]
toListOfValues = toList

-- Validate that every shared path exists and is a directory.
validateDirs :: RunConfig -> IO ()
validateDirs RunConfig{..} = forM_ (rcRoDirs ++ rcRwDirs) $ \d -> do
    ok <- doesDirectoryExist d
    unless ok $ fail ("runConfig share path is not a directory: " ++ d)

-- ---------------------------------------------------------------------------
-- The `run' subcommand
-- ---------------------------------------------------------------------------

-- | Resolve the run-pi-microvm script: an explicit option wins, then the
-- HONSTAREHAND_RUN_PI_MICROVM environment variable, then the script is built
-- from the frontArmToPlane flake (whose ref the HONSTAREHAND_FRONT_ARM_TO_PLANE
-- environment variable can override).
resolveRunPiMicrovm :: Maybe FilePath -> IO FilePath
resolveRunPiMicrovm (Just path) = checkScript path
resolveRunPiMicrovm Nothing = do
    mEnv <- lookupEnv "HONSTAREHAND_RUN_PI_MICROVM"
    case mEnv of
        Just path -> checkScript path
        Nothing -> do
            flakeRef <- maybe defaultFrontArmToPlane id
                <$> lookupEnv "HONSTAREHAND_FRONT_ARM_TO_PLANE"
            out <- runNix "nix"
                [ "build", flakeRef ++ "#pi-vm.run-pi-microvm"
                , "--no-link", "--print-out-paths" ]
            case reverse (lines out) of
                (lastLine : _) -> checkScript
                    (trim lastLine </> "bin" </> "run-pi-microvm")
                [] -> fail "nix build printed no output path"

checkScript :: FilePath -> IO FilePath
checkScript path = do
    ok <- doesFileExist path
    unless ok $ fail ("run-pi-microvm script not found at " ++ path)
    pure path

-- The frontArmToPlane flake work tree used on this machine.
defaultFrontArmToPlane :: String
defaultFrontArmToPlane =
    "/home/sieyes/baghdadPlane/flakes/newFrontArmToPlane.honstarehand"

-- Create a fresh temporary workdir with `mktemp -d'.
mkWorkdir :: IO FilePath
mkWorkdir = trim <$> readProcess "mktemp" ["-d"] ""

runCommand :: FilePath -> Maybe FilePath -> String -> IO ()
runCommand configFile mScript flakeArgStr = do
    cfg <- loadConfig configFile
    (ref, name) <- splitFlakeArg flakeArgStr
    putStrLn ("honstarehand: validating flake ref " ++ ref)
    validateFlakeRef ref
    rc <- evalRunConfig ref name
    validateDirs rc
    flakePath <- flakeStorePath ref
    script <- resolveRunPiMicrovm mScript
    withDb cfg $ \conn -> do
        ensureSchema conn
        workdir <- mkWorkdir
        startTime <- getCurrentTime
        inserted <- query conn
            "INSERT INTO run (config, workdir, status, \"startTime\") \
            \VALUES (?,?,?,?) RETURNING id"
            (flakePath, workdir, statusName Initializing, startTime) :: IO [Only Int]
        runId <- case inserted of
            [Only i] -> pure i
            _        -> fail "could not read back the id of the inserted run entry"
        putStrLn ("honstarehand: run entry " ++ show runId ++
                  " created (workdir " ++ workdir ++ ")")
        result <- try (runJob conn runId script workdir rc
                              (cfgOpenRouterApiKeyFile cfg))
        case result of
            Right exitCode  -> finishRun conn runId workdir exitCode
            Left (e :: SomeException) -> do
                now <- getCurrentTime
                void (execute conn
                    "UPDATE run SET status = ?, \"endTime\" = ? WHERE id = ?"
                    (statusName Terminated, now, runId))
                hPutStrLn stderr ("honstarehand: run failed: " ++ show e)
                exitWith (ExitFailure 1)

-- Spawn run-pi-microvm for the entry, monitor it while it runs (updating
-- the entry's status from initializing to ongoing once it is confirmed
-- running), and return its exit code.
runJob :: Connection -> Int -> FilePath -> FilePath -> RunConfig
       -> FilePath -> IO ExitCode
runJob conn runId script workdir RunConfig{..} apiKeyFile =
    withFile (workdir </> "run-pi-microvm.log") WriteMode $ \logH -> do
        let args = concat
                [ ["--workdir", workdir]
                , ["--disk-size", show rcDisk]
                , ["--ram", show rcRam ++ "M"]
                , concatMap (\d -> ["--read-only", d]) rcRoDirs
                , concatMap (\d -> ["--read-write", d]) rcRwDirs
                , if T.null rcModel
                      then [] else ["--model", T.unpack rcModel]
                , ["--api-key-file", apiKeyFile]
                ]
        (Just stdinH, _, _, processH) <- createProcess (proc script args)
            { std_in  = CreatePipe
            , std_out = UseHandle logH
            , std_err = UseHandle logH
            }
        TIO.hPutStr stdinH rcPrompt
        hClose stdinH
        monitorLoop processH False
  where
    -- Poll the script's state while it runs; once it is confirmed running,
    -- move the entry's status from initializing to ongoing.
    monitorLoop processH marked = do
        threadDelay 500000
        mExit <- getProcessExitCode processH
        case mExit of
            Just exitCode -> pure exitCode
            Nothing -> do
                unless marked $ void (execute conn
                    "UPDATE run SET status = ? WHERE id = ?"
                    (statusName Ongoing, runId))
                monitorLoop processH True

-- Handle the end of the run: on success turn the workdir into a nix store
-- derivation, store its path in the entry and print it; on failure mark
-- the entry terminated.
finishRun :: Connection -> Int -> FilePath -> ExitCode -> IO ()
finishRun conn runId workdir exitCode = do
    now <- getCurrentTime
    case exitCode of
        ExitSuccess -> do
            outputPath <- trim <$> runNix "nix" ["store", "add", workdir]
            void (execute conn
                "UPDATE run SET status = ?, \"endTime\" = ?, output = ? \
                \WHERE id = ?"
                (statusName Done, now, outputPath, runId))
            putStrLn outputPath
        ExitFailure code -> do
            void (execute conn
                "UPDATE run SET status = ?, \"endTime\" = ? WHERE id = ?"
                (statusName Terminated, now, runId))
            hPutStrLn stderr ("honstarehand: run-pi-microvm exited with status " ++
                              show code ++ "; run " ++ show runId ++
                              " marked terminated")
            exitWith (ExitFailure code)

-- ---------------------------------------------------------------------------
-- The `config-guide' subcommand
-- ---------------------------------------------------------------------------

-- | Print a description of how to properly write the TOML configuration
-- file that the @run@ and @list@ subcommands consume.
configGuideCommand :: IO ()
configGuideCommand = TIO.putStr configGuideText

configGuideText :: Text
configGuideText = T.unlines
    [ "honstarehand configuration guide"
    , "==========================="
    , ""
    , "The `run' and `list' subcommands both take a required --config (-c)"
    , "option pointing at a TOML configuration file. The file must contain"
    , "two top-level string keys:"
    , ""
    , "  databaseUrl"
    , "      A URL to a postgresql server holding the `run' table, using the"
    , "      postgresql-simple connection syntax; both connection URIs and"
    , "      keyword strings work, e.g."
    , ""
    , "          databaseUrl = \"postgres://user:password@localhost:5432/runs\""
    , ""
    , "      or"
    , ""
    , "          databaseUrl = \"host=localhost dbname=runs user=user\""
    , ""
    , "  openrouterApiKeyFile"
    , "      The path of a file holding the OpenRouter API key; the file is"
    , "      handed to run-pi-microvm with --api-key-file. The key itself is"
    , "      never copied, logged, or printed by honstarehand: only the path is"
    , "      passed on. The file must exist, be non-empty, and ideally have"
    , "      mode 0600 (a warning is printed otherwise)."
    , ""
    , "A minimal, complete example config file:"
    , ""
    , "  databaseUrl = \"postgres:///runs\""
    , "  openrouterApiKeyFile = \"/etc/honstarehand/openrouter-key\""
    , ""
    , "Notes:"
    , ""
    , "  * The file must be valid TOML and both keys must be plain strings."
    , "  * The config path is checked for existence before it is decoded; a"
    , "    missing file is a hard error. The API key file is checked too: a"
    , "    missing or empty key file is a hard error, and a key file with"
    , "    group- or world-read permission enabled produces a warning."
    , "  * The postgresql server does not need to exist yet for `run' to"
    , "    validate the flake, but the connection is opened before anything is"
    , "    inserted, so it must be reachable when a run starts."
    , ""
    ]

-- ---------------------------------------------------------------------------
-- The `list' subcommand
-- ---------------------------------------------------------------------------

-- Parse a --status string of letters into the statuses to list.
parseStatusChars :: Maybe String -> IO [RunStatus]
parseStatusChars mChars = case mChars of
    Nothing -> pure [Ongoing, Initializing]
    Just chars
        | null chars -> fail "--status must not be empty"
        | otherwise ->
            case mapM statusFromChar chars of
                Just sts -> pure sts
                Nothing  -> fail ("invalid --status letters in " ++ show chars ++
                                  " (valid letters: o, d, i, t)")

listCommand :: FilePath -> Maybe String -> IO ()
listCommand configFile mStatusChars = do
    statuses <- parseStatusChars mStatusChars
    cfg <- loadConfig configFile
    withDb cfg $ \conn -> do
        ensureSchema conn
        let placeholders = T.unpack
                (T.intercalate "," (map (const "?") statuses))
            q = Query (BSC.pack
                ( "SELECT id, config, workdir, status, \"startTime\", \"endTime\", output FROM run"
                  ++ " WHERE status IN (" ++ placeholders ++ ") ORDER BY id"))
        rows <- query conn q (map statusName statuses)
            :: IO [(Int, Text, Text, Text, Maybe UTCTime, Maybe UTCTime,
                    Maybe Text)]
        printRows rows

-- Print the rows as a nushell-friendly table: whitespace-aligned
-- columns whose first line holds single-word headers, so that piping the
-- output into nushell's @detect columns@ yields a proper structured
-- table. Constraints honored here:
--
--   * headers must be single words (they become the column names),
--   * no cell may contain whitespace (nix store paths and @mktemp -d@
--     workdirs never do; timestamps are rendered space-free ISO-8601),
--   * no decoration rows (e.g. a dash separator), which would be parsed
--     as data by nushell.
printRows :: [(Int, Text, Text, Text, Maybe UTCTime, Maybe UTCTime, Maybe Text)]
          -> IO ()
printRows rows = do
    if null rows
        then putStrLn "(no entries)"
        else mapM_ putStrLn (table header (map rowCells rows))
  where
    header = ["ID", "STATUS", "START", "END", "CONFIG", "OUTPUT",
              "WORKDIR"]
    rowCells (i, cfgPath, workdir, status, start, end, output) =
        [ show i
        , T.unpack status
        , maybe "-" fmtTime start
        , maybe "-" fmtTime end
        , T.unpack cfgPath
        , maybe "-" T.unpack output
        , T.unpack workdir
        ]
    -- Space-free ISO-8601 (UTC) so each timestamp stays a single column
    -- for nushell's `detect columns'.
    fmtTime = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"
    table hdr cells =
        let cols = length hdr
            widths = [ maximum ((length (hdr !! c)) : map length (column c))
                     | c <- [0 .. cols - 1] ]
            column c = [ r !! c | r <- cells ]
            render row = unwords [ pad (row !! c) (widths !! c)
                                 | c <- [0 .. cols - 1] ]
        in render hdr : map render cells
    pad s w = s ++ replicate (max 1 (w - length s + 2)) ' '
