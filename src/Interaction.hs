-- | An 'interaction' is the result of running a program on MeNicks.
module Interaction (Interaction(..),Prompt(..),OutMode(..),EOF(..)) where

data Interaction where
  I_Read :: Prompt -> (Maybe (Either EOF String) -> Interaction) -> Interaction
  I_Write :: OutMode -> String -> Interaction -> Interaction
  I_Trace :: String -> Interaction -> Interaction
  I_Halt :: Interaction

data Prompt = Prompt String | NoPrompt

data OutMode = StdOut | StdErr

instance Show OutMode where show = \case StdOut -> "stdout"; StdErr -> "stderr"

data EOF = EOF deriving Show
