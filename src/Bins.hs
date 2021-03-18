-- | Predefined 'binary' programs, which will be available on the file-system.
module Bins (
  man, echo, cat, rev, grep, ls, ps, lsof, sum, type_, xargs,
  ) where

import Control.Monad (when)
import Data.List (sort,sortOn,isInfixOf)
import Data.Map (Map)
import Interaction (Prompt(..))
import Lib (read,write,stdin,stdout,stderr,withOpen,checkNoArgs,getSingleArg,readAll,exit)
import Misc (EOF(..))
import Path (Path)
import Prelude hiding (head,read,sum)
import Prog (Prog,Command(..),OpenMode(..),SysCall(..),FD,FileKind(..),BinaryMeta(..))
import Text.Read (readMaybe)
import qualified Data.Map.Strict as Map
import qualified Path (create,toString,hidden)
import qualified Prelude
import qualified Prog (Prog(..))

man :: Prog ()
man = do
  Command(me,args) <- Prog.Argv
  let
    manline :: String -> Prog ()
    manline name =
      case Map.lookup name docsMap of
        Just text -> write stdout (name ++ " : " ++ text)
        Nothing -> write stderr (me ++ " : no manual entry for '" ++ name ++ "'")
  mapM_ manline args
  where
    docsMap :: Map String String
    docsMap = Map.fromList
     [ ("man"  , "list the manual entries for the given commands")
     , ("echo" , "write given arguments to stdout")
     , ("cat"  , "write named files (or stdin in no files given) to stdout")
     , ("rev"  , "copy stdin to stdout, reversing each line")
     , ("grep" , "copy lines which match the given pattern to stdout ")
     , ("ls"   , "list non-hidden files; add '-a' flag to also see hidden files")
     , ("ps"   , "list all running processes")
     , ("lsof" , "list open files in running processes")
     , ("sum"  , "write sum of the given numeric arguments to stdout")
     , ("type" , "determine the type of named files: binary or data")
     , ("xargs", "concatenate lines from stdin, and pass as arguments to the given command")
     , ("sham" , "interpret a script, or command (with '-c'), or start a new console (no args)")
     ]

echo :: Prog ()
echo = do
  Command(_,args) <- Prog.Argv
  write stdout (unwords args)

cat :: Prog ()
cat = do
  Command(_,args) <- Prog.Argv
  case args of
    [] -> catFd stdin
    args -> sequence_ [ catProg1 (Path.create arg) | arg <- args ]
  where
    catProg1 :: Path -> Prog ()
    catProg1 path = withOpen path OpenForReading $ catFd

    catFd :: FD -> Prog ()
    catFd fd = loop where
      loop :: Prog ()
      loop = do
        read NoPrompt fd >>= \case
          Left EOF -> pure ()
          Right line -> do
            write stdout line
            loop

rev :: Prog ()
rev = checkNoArgs loop where
  loop :: Prog ()
  loop = do
    read NoPrompt stdin >>= \case
      Left EOF -> pure ()
      Right line -> do
        write stdout (reverse line)
        loop

grep :: Prog ()
grep = do
  getSingleArg $ \pat -> do
  let
    loop :: Prog ()
    loop = do
      read NoPrompt stdin >>= \case
        Left EOF -> pure ()
        Right line -> do
          when (pat `isInfixOf` line) $
            write stdout line
          loop
  loop

ls :: Prog ()
ls = do
  Command(me,args) <- Prog.Argv
  seeHidden <- case args of
    [] -> pure False
    ["-a"] -> pure True
    _ -> do write stderr (me ++ ": takes no arguments, or a single '-a'"); exit
  paths <- Prog.Call Paths ()
  mapM_ (write stdout . Path.toString) $ sort [ p | p <- paths , seeHidden || not (Path.hidden p) ]

ps :: Prog ()
ps = checkNoArgs $ do
  xs <- Prog.Procs
  sequence_
    [ write stdout (show pid ++ " " ++ show com)  | (pid,com) <- sortOn fst xs ]

lsof :: Prog ()
lsof = checkNoArgs $ do
  xs <- Prog.Lsof
  sequence_
    [ write stdout (show pid ++ " (" ++ show command ++ ") " ++ show fd ++ " " ++ show entry)
    | (pid,command,fd,entry) <- xs ]

sum :: Prog ()
sum = do
  Command(me,args) <- Prog.Argv
  let
    toInt :: String -> Prog Int
    toInt s =
      case readMaybe s of
        Just n -> pure n
        Nothing -> do
          write stderr (me ++ ": unable to convert '" ++ s ++ "' to a number")
          pure 0
  ns <- mapM toInt args
  let res = Prelude.sum ns
  write stdout (show res)

type_ :: Prog ()
type_ = do
  Command(_,args) <- Prog.Argv
  let
    typeline :: String -> Prog ()
    typeline name = do
      Prog.Call Kind (Path.create name) >>= \case
        Left _ ->  write stderr $ "no such path: " ++ name
        Right kind -> do
          let
            str = case kind of
              K_Data -> "Data/Script"
              K_Binary (BinaryMeta s) -> "Binary *" ++ s ++ "*"
          write stdout (name ++ " : " ++ str)
  mapM_ typeline args

xargs :: (Command -> Prog ()) -> Prog ()
xargs runCommand = do
  Command(me,args) <- Prog.Argv
  case args of
    [] -> write stderr (me ++ ": takes at least 1 argument")
    com:args -> do
      lines <- readAll stdin
      runCommand (Command (com, args ++ lines))