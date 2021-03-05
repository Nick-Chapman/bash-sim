
module Os2 ( -- with support for co-operatove threading!
  Prog(..),
  SysCall(..),
  OpenMode(..),NoSuchPath(..),FD(..),
  sim,
  ) where

import Control.Monad (ap,liftM)
import Data.Map (Map)
import FileSystem (FileSystem,NoSuchPath(..))
import Misc (Block(..),EOF(..),EPIPE(..),NotReadable(..),NotWritable(..))
import OsState (OsState,OpenMode(..))
import Path (Path)
import Interaction (Interaction(..))
import qualified Data.Map.Strict as Map
import qualified OsState (init,ls,open,Key,close,dup,read,write)

instance Functor Prog where fmap = liftM
instance Applicative Prog where pure = return; (<*>) = ap
instance Monad Prog where return = Ret; (>>=) = Bind

data Prog a where
  Ret :: a -> Prog a
  Bind :: Prog a -> (a -> Prog b) -> Prog b
  Exit :: Prog a
  Trace :: String -> Prog ()
  Spawn :: Prog () -> (Pid -> Prog a) -> Prog a
  Wait :: Pid -> Prog ()
  Call :: SysCall a b -> a -> Prog b

sim :: FileSystem -> Prog () -> Interaction
sim fs prog = do
  let action = linearize prog (\() -> A_Halt)
  let (state,pid) = newPid (initState fs)
  resume pid (Proc env0 action) state

linearize :: Prog a -> (a -> Action) -> Action
linearize p0 = case p0 of
  Ret a -> \k -> k a
  Bind p f -> \k ->linearize p $ \a -> linearize (f a) k
  Exit -> \_ignoredK -> A_Halt
  Trace message -> \k -> A_Trace message (k ())
  Spawn child f -> \k -> do
    let action = linearize child $ \() -> A_Halt
    A_Spawn action $ \pid -> linearize (f pid) k
  Wait pid -> \k -> A_Wait pid (k ())
  Call sys arg -> \k -> A_Call sys arg k

data Action where
  A_Halt :: Action
  A_Trace :: String -> Action -> Action
  A_Spawn :: Action -> (Pid -> Action) -> Action
  A_Wait :: Pid -> Action -> Action
  A_Call :: SysCall a b -> a -> (b -> Action) -> Action

----------------------------------------------------------------------

resume :: Pid -> Proc -> State -> Interaction
resume me proc0@(Proc env action0) state@State{os} = case action0 of

  A_Halt -> do
    case choose state of
      Nothing -> I_Halt
      Just (state,other,proc2) ->
        resume other proc2 state

  A_Trace message action ->
    I_Trace message (resume me (Proc env action) state)

  A_Spawn action f -> do
    -- TODO: dup all file-descriptors in env
    let child = Proc env action
    let (state',pid) = newPid state
    let parent = Proc env (f pid)
    yield me parent (suspend pid child state')

  A_Wait pid action ->
    if running pid state
    then block me proc0 state
    else yield me (Proc env action) state

  A_Call sys arg f -> do
    case runSysI sys os env arg of
      Left Block -> block me proc0 state
      Right proceed -> do
        proceed $ \os env res -> do
          let action = f res
          yield me (Proc env action) state { os }

block :: Pid -> Proc -> State -> Interaction
block = yield

yield :: Pid -> Proc -> State -> Interaction
yield me proc1 state = do
  case choose state of
    Nothing ->
      resume me proc1 state -- nothing else to do, so continue
    Just (state,other,proc2) ->
      --I_Trace (show ("yield",me,other)) $ do
      resume other proc2 (suspend me proc1 state)

----------------------------------------------------------------------

data Proc = Proc Env Action

newtype Pid = Pid Int deriving (Eq,Ord,Num,Show)

data State = State
  { os :: OsState
  , nextPid :: Pid
  , waiting :: Map Pid Proc
  , suspended :: Map Pid Proc
  }

initState :: FileSystem -> State
initState fs = State
  { os = OsState.init fs
  , nextPid = 1000
  , waiting = Map.empty
  , suspended = Map.empty
  }

running :: Pid -> State -> Bool
running pid State{waiting,suspended} =
  Map.member pid waiting || Map.member pid suspended

newPid :: State -> (State,Pid)
newPid s@State{nextPid} = (s { nextPid = nextPid + 1 }, nextPid)

suspend :: Pid -> Proc -> State -> State
suspend pid1 proc1 s@State{suspended} =
  s { suspended = Map.insert pid1 proc1 suspended }

choose :: State -> Maybe (State,Pid,Proc)
choose s@State{waiting,suspended} =
  case Map.minViewWithKey waiting of
    Just ((pid1,proc1),waiting) -> Just (s { waiting }, pid1, proc1)
    Nothing ->
      case Map.minViewWithKey suspended of
        Just ((pid1,proc1),suspended) ->
          -- re-animate the suspended...
          Just (s { waiting = suspended, suspended = Map.empty }, pid1, proc1)
        Nothing ->
          Nothing

----------------------------------------------------------------------
-- TODO: sep file

data SysCall a b where
  Open :: SysCall (Path,OpenMode) (Either NoSuchPath FD)
  Close :: SysCall FD ()
  Dup2 :: SysCall (FD,FD) ()
  Read :: SysCall FD (Either NotReadable (Either EOF String))
  Write :: SysCall (FD,String) (Either NotWritable (Either EPIPE ()))
  Paths :: SysCall () [Path]

runSysI :: SysCall a b ->
  OsState -> Env -> a ->
  Either Block ((OsState -> Env -> b -> Interaction) -> Interaction)

runSysI sys s env arg = case sys of

  Open -> do
    let (path,mode) = arg
    case OsState.open s path mode of
      Left NoSuchPath -> do
        Right $ \k ->
          k s env (Left NoSuchPath)
      Right (key,s) -> do
        Right $ \k -> do
          let fd = smallestUnused env
          --I_Trace (show ("Open",path,mode,fd)) $ do
          let env' = Map.insert fd (File key) env
          k s env' (Right fd)

  Close -> do
    let fd = arg
    Right $ \k -> do
      --I_Trace (show ("Close",fd)) $ do
      let env' = Map.delete fd env
      let s' = case look "sim,Close" fd env of
            File key -> OsState.close s key
            Console -> s
      k s' env' ()

  Dup2 -> do
    let (fdDest,fdSrc) = arg
    Right $ \k -> do
      --I_Trace (show ("Dup2",fdDest,fdSrc)) $ do
      let s' = case look "sim,Dup2,dest" fdDest env of
            File key -> OsState.close s key
            Console -> s
      let target = look "sim,Dup2,src" fdSrc env
      let s'' = case target of
            File key -> OsState.dup s' key
            Console -> s'
      let env' = Map.insert fdDest target env
      k s'' env' ()

  Read -> do
    let fd = arg
    case look "sim,Read" fd env of
      File key -> do
        case OsState.read s key of
          Left NotReadable -> do
            Right $ \k ->
              k s env (Left NotReadable)
          Right (Left Block) ->
            undefined -- TODO: blocking; when we have pipes
          Right (Right (dat,s)) -> do
            Right $ \k ->
              k s env (Right dat)
      Console -> do
        Right $ \k -> do
          I_Read $ \case -- TODO: share alts
            Left EOF ->
              k s env (Right (Left EOF))
            Right line ->
              k s env (Right (Right line))

  Write -> do
    let (fd,line) = arg
    case look "sim,Write" fd env of
      File key -> do
        case OsState.write s key line of
          Left NotWritable -> do
            Right $ \k ->
              k s env (Left NotWritable)
          Right (Left Block) -> do
            undefined -- TODO: blocking; when we have pipes
            --Left Block -- but easy to implement!!
          Right (Right (Left EPIPE)) -> do
            Right $ \k ->
              k s env (Right (Left EPIPE))
          Right (Right (Right s)) -> do
            Right $ \k ->
              k s env (Right (Right ()))
      Console -> do
        Right $ \k ->
          I_Write line (k s env (Right (Right ())))

  Paths{} -> do
    Right $ \k -> do
      let paths = OsState.ls s
      k s env paths

----------------------------------------------------------------------

type Env = Map FD Target -- per process state, currently just FD map

data Target
  = Console
  | File OsState.Key
  deriving Show

env0 :: Env
env0 = Map.fromList [ (FD n, Console) | n <- [0,1,2] ]

newtype FD = FD Int
  deriving (Eq,Ord,Enum,Show)

smallestUnused :: Env -> FD
smallestUnused env = head [ fd | fd <- [FD 0..], fd `notElem` used ]
  where used = Map.keys env

-- helper for map lookup
look :: (Show k, Ord k) => String -> k -> Map k b -> b
look tag k env = maybe (error (show ("look/error",tag,k))) id (Map.lookup k env)
