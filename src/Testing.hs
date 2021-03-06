-- | Small testing framework for writng 'sham' regression tests.
module Testing (test,run) where

import Control.Monad (ap,liftM)
import Data.List (intercalate)
import Image (fs0)
import Interaction (Interaction(..),OutMode(..),EOF(..))
import qualified MeNicks (start)

test :: [String] -> [String] -> Testing ()
test is xs = T1 (Test (Lines is) (Lines xs))

run :: Testing () -> IO ()
run testing = do
  bools <- sequence [ runTest i x | (i,x) <- zip [1..] (collect testing) ]
  let numTests = length bools
  let numPass = length [ () | res <- bools, res ]
  let numFail = numTests - numPass
  putStrLn $
    show numTests ++ " tests ran; " ++ (if numFail > 0 then show numFail ++ " fail." else "all pass.")

instance Functor Testing where fmap = liftM
instance Applicative Testing where pure = return; (<*>) = ap
instance Monad Testing where return = Ret; (>>=) = Bind

data Testing a where
  Ret :: a -> Testing a
  Bind :: Testing a -> (a -> Testing b) -> Testing b
  T1 :: Test -> Testing ()

collect :: Testing () -> [Test]
collect m = loop m $ \_ -> [] where
  loop :: Testing a -> (a -> [Test]) -> [Test]
  loop m k = case m of
    Ret a -> k a
    Bind m f -> loop m $ \a -> loop (f a) k
    T1 x -> x : k ()

data Test = Test Lines Lines

newtype Lines = Lines [String] deriving Eq
instance Show Lines where show (Lines xs) = intercalate "/" xs

instance Show Test where
  show (Test is xs) = "input: " ++ show is ++ "\n- expect: " ++ show xs

runTest :: Int -> Test -> IO Bool
runTest n t@(Test input expected) = do
  --print (n,input)
  case runConsole input of
    Left (Unconsumed lines) -> do
      putStrLn $ "test #" ++ show n ++ " : " ++ show t
      putStrLn $ "- unconsumed: " ++ show lines
      pure False
    Right actual -> do
      if actual == expected then pure True else do
        putStrLn $ "test #" ++ show n ++ ", " ++ show t
        putStrLn $ "- actual: " ++ show actual
        pure False

runConsole :: Lines -> Either Unconsumed Lines
runConsole input = runInteraction (MeNicks.start fs0) input

runInteraction :: Interaction -> Lines -> Either Unconsumed Lines
runInteraction i (Lines xs0) = loop xs0 [] i where
  loop :: [String] -> [String] -> Interaction -> Either Unconsumed Lines
  loop xs ys = \case
    I_Read _ f -> do
      case xs of
        [] -> loop xs ys (f (Just (Left EOF)))
        "":xs -> loop xs ys (f (Just (Left EOF)))
        line:xs -> loop xs ys (f (Just (Right line)))
    I_Write mode line i -> do
      loop xs ((tag++line):ys) i
        where tag = case mode of StdOut -> ""; StdErr -> "(stderr) "
    I_Trace _ i -> do
      loop xs ys i
    I_Halt -> do
      case xs of
        [] -> Right (Lines (reverse ys))
        _ -> Left (Unconsumed (Lines xs))

data Unconsumed = Unconsumed Lines
