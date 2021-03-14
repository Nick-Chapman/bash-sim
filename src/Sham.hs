
module Sham (shamConsole) where

import Data.Map (Map)
import EarleyM (Gram,fail,alts,getToken,many,skipWhile,ParseError(..),Ambiguity(..),SyntaxError(..))
import Interaction (Prompt(..))
import MeNicks (Prog(Trace),Command(..),OpenMode(..),WriteOpenMode(..))
import Misc (EOF(..))
import Prelude hiding (Word,read,fail)
import Script (Script(..),Step(..),WaitMode(..),Redirect(..),RedirectSource(..),Word(..),)
import SysCall (FD(..))
import qualified Data.Char as Char
import qualified Data.Map.Strict as Map
import qualified EarleyM as EM (parse,Parsing(..))
import qualified MeNicks (Prog(Argv,MyPid))
import qualified Native (echo,cat,rev,grep,head,ls,ps,bins,man,read,xargs,checkNoArgs,loadFile)
import qualified Script (runScript,Env(..))


shamConsole :: Int -> Prog ()
shamConsole level = runConsole level
  where

    binMap :: Map String (Prog ())
    binMap = Map.fromList [ (name,prog) | (name,prog,_) <- table ]

    docMap :: Map String String
    docMap = Map.fromList [ (name,text) | (name,_,text) <- table ]

    table :: [(String,Prog (),String)]
    table =
      [ ("echo",Native.echo,
        "write given arguments to stdout")
      , ("cat",Native.cat,
        "write named files (or stdin in no files given) to stdout")
      , ("rev",Native.rev,
        "copy stdin to stdout, reversing each line")
      , ("grep",Native.grep,
        "copy lines which match the given pattern to stdout ")
      , ("head",Native.head,
        "copy just the first line on stdin to stdout, then exit")
      , ("ls",Native.ls,
        "list all files on the filesystem")
      , ("ps",Native.ps,
        "list all running process")
      , ("sham",sham (level+1),
        "start a nested sham console")
      , ("xargs",Native.xargs runCommand,
         "concatenate lines from stdin, and pass as arguments to the given command")
      , ("bins",Native.bins (Map.keys binMap),
        "list builtin executables")
      , ("man",Native.man docMap,
         "list the manual entries for the given commands")
      ]

    runCommand :: Command -> Prog ()
    runCommand (Command (com,args)) = do
      -- TODO: reconstructing the command seems hacky
      let script = Invoke1 (Run (Word com) (map Word args) []) Wait
      runScript script args

    sham :: Int -> Prog ()
    sham level = do
      Command(_,args) <- MeNicks.Argv
      case args of
        [] -> runConsole level
        "-c":args -> do
          let script = parseLine (unwords args)
          MeNicks.Trace (show script) -- for debug
          runScript script []
        path:args -> do
          lines <- Native.loadFile path
          let script = parseLines lines
          runScript script args

    runConsole :: Int -> Prog ()
    runConsole level = Native.checkNoArgs $ loop 1 where
      loop :: Int -> Prog ()
      loop n = do
        let prompt = "sham[" ++ show level ++ "." ++ show n ++ "]$ "
        Native.read (Prompt prompt) (FD 0) >>= \case
          Left EOF -> pure ()
          Right line -> do
            let script = parseLine line
            let _ = MeNicks.Trace (show script) -- for debug
            runScript script []
            loop (n+1)

    runScript :: Script -> [String] -> Prog ()
    runScript script args = do
      pid <- MeNicks.MyPid
      let env = Script.Env
            { pid
            , com = "sham"
            , args
            , lookNative = \s -> Map.lookup s binMap
            , shamParser = parseLines
            }
      Script.runScript env script

parseLines :: [String] -> Script
parseLines lines = foldl Seq Null (map parseLine lines)

parseLine :: String -> Script
parseLine str = do
  case EM.parse (lang <$> getToken) str of
    EM.Parsing{EM.outcome} -> case outcome of
      Left pe -> ShamError $ prettyParseError str pe
      Right script -> script

prettyParseError :: String -> ParseError -> String
prettyParseError str = \case
  AmbiguityError (Ambiguity _ p1 p2) -> "ambiguous parse between positions " ++ show p1 ++ "--" ++ show p2
  SyntaxError (UnexpectedTokenAt p) -> "unexpected '" ++ char p ++ "' at position " ++ show p
  SyntaxError (UnexpectedEOF _) -> "unexpected end of line"
  SyntaxError (ExpectedEOF p) -> "expected EOF at position " ++ show p
  where char p = [str!!(p-1)]

lang :: Gram Char -> Gram Script
lang token = script0 where

  script0 = do
    ws
    res <- alts [ do res <- command; ws; pure res
                , do eps; pure Null ]
    alts [eps,lineComment]
    pure res

  lineComment = do symbol '#'; skipWhile (skip token)

  command = alts [ pipeline, conditional ]

  conditional = do
    keyword "ifeq"
    ws1; x1 <- word
    ws1; x2 <- word
    ws1; s <- step
    pure $ IfEq x1 x2 (Invoke1 s Wait) Null

  pipeline = do
    (x,xs) <- parseListSep step (do ws; symbol '|'; ws)
    m <- mode
    case xs of
      [] -> pure $ Invoke1 x m
      _ -> pure $ Pipeline (x:xs) m

  mode =
    alts [ do eps; pure Wait,
           do ws; symbol '&'; pure NoWait ]

  step = do
    (com,args) <- parseListSep word ws1
    case com of Word "ifeq" -> fail; _ -> pure ()
    rs <- redirects
    pure $ Run com args rs

  redirects = alts
    -- TODO: Goal: allow just "ws" to separate args from redirects.
    -- Problem is that currently this causes ambiguity for examples such as:
    --  "echo foo1>xx"
    -- It should parse as:       "echo foo1 >xx"
    -- But we think it might be  "echo foo 1>xx"  !!
    [ do ws1; (r1,rs) <- parseListSep redirect ws1; pure (r1:rs)
    , do eps; pure []
    ]

  redirect = alts
    [ do
        dest <- alts [ do eps; pure 0, do n <- fd; ws; pure n ]
        let mode = OpenForReading
        symbol '<'
        ws
        src <- redirectSource
        pure $ Redirect mode dest src
    , do
        dest <- alts [ do eps; pure 1, do n <- fd; ws; pure n ]
        mode <-
          alts [ do symbol  '>';  pure $ OpenForWriting Truncate
               , do keyword ">>"; pure $ OpenForWriting Append ]
        ws
        src <- redirectSource
        pure $ Redirect mode dest src
    ]

  redirectSource = alts [ FromPath <$> word, FromFD <$> fdRef ]
  fdRef = do symbol '&'; fd
  fd = FD <$> digit -- TODO: multi-digit file-desciptors

  word = alts [ Word <$> ident0
              , do keyword "$$"; pure DollarDollar
              , do keyword "$"; DollarN <$> digit
              ]

  keyword string = mapM_ symbol string

  ident0 = do
    x <- alts [alpha,numer,dash,dot]
    xs <- many (alts [alpha,numer,dash,dot])
    pure (x : xs)

  digit = do c <- numer; pure (digitOfChar c)

  alpha = sat Char.isAlpha
  numer = sat Char.isDigit
  dash = sat (== '-')
  dot = sat (== '.')
  space = skip (sat Char.isSpace)

  symbol x = do t <-token; if t==x then pure () else fail
  sat pred = do c <- token; if pred c then pure c else fail

  ws = skipWhile space -- white*
  ws1 = do space; ws -- white+

  skip p = do _ <- p; eps
  eps = pure ()


digitOfChar :: Char -> Int
digitOfChar c = Char.ord c - ord0 where ord0 = Char.ord '0'

parseListSep :: Gram a -> Gram () -> Gram (a,[a])
parseListSep p sep = alts [
    do x <- p; sep; (x1,xs) <- parseListSep p sep; pure (x,x1:xs),
    do x <- p; pure (x,[])]
