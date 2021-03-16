module Prog (
  Prog(..), SysCall(..),
  OpenMode(..), WriteOpenMode(..),
  BadFileDescriptor(..), OpenError(..), LoadBinaryError(..),
  Command(..), FD(..), Pid(..)
  ) where

import Control.Monad (ap,liftM)
import Interaction (Prompt)
import Misc (EOF(..),EPIPE(..),NotReadable(..),NotWritable(..),PipeEnds(..))
import Path (Path)

newtype Pid = Pid Int deriving (Eq,Ord,Num)
instance Show Pid where show (Pid n) = "[" ++ show n ++ "]"

data Command = Command { argv :: (String,[String]) }
instance Show Command where show (Command (x,xs)) = unwords (x:xs)

newtype FD = FD Int
  deriving (Eq,Ord,Enum,Num)

instance Show FD where show (FD n) = "&" ++ show n

data BadFileDescriptor = BadFileDescriptor deriving Show

data Prog a where
  Ret :: a -> Prog a
  Bind :: Prog a -> (a -> Prog b) -> Prog b
  Exit :: Prog a
  Trace :: String -> Prog ()
  Fork :: Prog (Maybe Pid)
  Exec :: Command -> Prog a -> Prog b
  Wait :: Pid -> Prog ()
  Argv :: Prog Command
  MyPid :: Prog Pid
  Procs :: Prog [(Pid,Command)]
  Call :: (Show a) => SysCall a b -> a -> Prog b

instance Functor Prog where fmap = liftM
instance Applicative Prog where pure = return; (<*>) = ap
instance Monad Prog where return = Ret; (>>=) = Bind

data SysCall a b where
  LoadBinary :: SysCall Path (Either LoadBinaryError (Prog ()))
  Open :: SysCall (Path,OpenMode) (Either OpenError FD)
  Close :: SysCall FD ()
  Dup2 :: SysCall (FD,FD) (Either BadFileDescriptor ())
  Read :: Prompt -> SysCall FD (Either NotReadable (Either EOF String))
  Write :: SysCall (FD,String) (Either NotWritable (Either EPIPE ()))
  Paths :: SysCall () [Path]
  SysPipe :: SysCall () (PipeEnds FD)
  Unused :: SysCall () FD -- TODO: for used for by with redirectsa

data OpenMode
  = OpenForReading -- creating if doesn't exist
  | OpenForWriting WriteOpenMode -- rm, then append
  deriving Show

data WriteOpenMode = Truncate | Append deriving Show

data OpenError
  = OE_NoSuchPath
  | OE_CantOpenForReading
  deriving Show

data LoadBinaryError
  = LBE_NoSuchPath
  | LBE_CantLoadAsBinary
  deriving Show

instance Show (SysCall a b) where -- TODO: automate?
  show = \case
    LoadBinary -> "LoadBinary"
    Open -> "Open"
    Close -> "Close"
    Dup2 -> "Dup2"
    Read _ -> "Read"
    Write -> "Write"
    Paths -> "Paths"
    SysPipe -> "Pipe"
    Unused -> "Unused"