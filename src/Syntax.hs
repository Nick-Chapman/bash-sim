-- | Parser and AST for 'sham' scripts
module Syntax (
  Script(..), Redirect(..), RedirectRhs(..), Pred(..), Word(..), Var(..),
  parseLine,
  ) where

import EarleyM (Gram,fail,alts,getToken,many,skipWhile,ParseError(..),Ambiguity(..),SyntaxError(..))
import Environment (Var(..))
import Prelude hiding (Word,read,fail)
import Prog (FD(..),OpenMode(..),WriteOpenMode(..))
import qualified Data.Char as Char
import qualified EarleyM as EM (parse,Parsing(..))

data Script -- TODO: loose Q prefix?
  = QNull
  | QSeq Script Script
  | QIf Pred Script Script
  | QShamError String
  | QEcho [Word]
  | QSetVar Var Word
  | QReadIntoVar Var
  | QExit
  | QExec Script
  | QInvoke Word [Word]
  | QSource Word [Word]
  | QPipe Script Script
  | QBackGrounding Script
  | QRedirecting Script [Redirect] -- TODO: have just 1 redirect!
  | QRedirects [Redirect]
  deriving Show

data Pred
  = Eq Word Word
  | NotEq Word Word
  deriving Show

data Word
  = Word String
  | DollarHash
  | DollarN Int
  | DollarDollar
  | DollarName Var
  deriving Show

data Redirect = Redirect OpenMode FD RedirectRhs
  deriving Show

data RedirectRhs = RedirectRhsPath Word | RedirectRhsFD FD | RedirectRhsClose
  deriving Show


parseLine :: String -> String -> Script
parseLine errPrefix str = do
  case EM.parse (lang <$> getToken) str of
    EM.Parsing{EM.outcome} -> case outcome of
      Left pe -> QShamError (errPrefix ++ prettyParseError str pe)
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
    res <- alts [ do res <- script; ws; pure res
                , do eps; pure QNull ]
    alts [eps,lineComment]
    pure res

  lineComment = do symbol '#'; skipWhile (skip token)

  script = alts [ pipeline, conditional, setVar ]

  conditional = do
    keyword "if"
    ws1; p <- pred
    ws1; s <- step
    pure $ QIf p s QNull

  pred = alts [equal,notEqual]

  equal = do
    x1 <- word
    ws; keyword "="; ws
    x2 <- word
    pure (Eq x1 x2)

  notEqual = do
    x1 <- word
    ws; keyword "!="; ws
    x2 <- word
    pure (NotEq x1 x2)

  setVar = do
    x <- varname
    keyword "=" -- no surrounding whitespace
    w <- word
    pure (QSetVar x w)

  pipeline = do
    x1 <- step
    xs <- many (do ws; symbol '|'; ws; step)
    m <- mode
    pure $ m $ foldl QPipe x1 xs

  mode :: Gram (Script -> Script) =
    alts [ do eps; pure id,
           do ws; symbol '&'; pure QBackGrounding ]

  step = alts [subshell,runCommand,execCommand,execRedirects]

  subshell = do
    symbol '('
    script <- sequence
    symbol ')'
    rs <- redirects False
    pure $ (case rs of [] -> script; _-> QRedirecting script rs)

  sequence = do
    x1 <- script
    xs <- many (do ws; symbol ';'; ws; step)
    pure $ foldl QSeq x1 xs

  runCommand = do
    (thing,num) <- command
    rs <- redirects num
    pure $ (case rs of [] -> thing; _ -> QRedirecting thing rs)

  execCommand = do
    keyword "exec"
    ws1; (thing,num) <- command
    rs <- redirects num
    pure $ QExec (case rs of [] -> thing; _ -> QRedirecting thing rs)

  execRedirects = do
    keyword "exec"
    rs <- redirects False
    pure $ QRedirects rs

  command :: Gram (Script,Bool) -- this Bool is True if the final word was a number
  command = alts [echo,exit,source,invocation,readIntoVar]

  echo = do
    keyword "echo"
    ws <- words
    let num = case ws of [] -> False; _ -> isNumeric (last ws)
    pure (QEcho ws, num)

  exit = do
    keyword "exit"
    pure (QExit, False)

  source = do
    alts [keyword "source",keyword "."]
    ws1; w <- word
    ws <- words
    let num = isNumeric (last (w:ws))
    pure (QSource w ws, num)

  invocation = do
    com <- nonBuiltinWord
    args <- words
    let num = isNumeric (last (com:args))
    pure (QInvoke com args, num)

  readIntoVar = do
    keyword "read"
    ws1; x <- varname
    pure (QReadIntoVar x, False)

  words = many (do ws1; word)

  builtinList = ["echo","exec","exit","read","source","."]

  nonBuiltinWord = do
    com <- word
    case com of Word w | w `elem` builtinList -> fail; _ -> pure com

  redirects num = alts [ do eps; pure []
                      , do
                          r <- redirect num
                          rs <- many (redirect False)
                          pure (r:rs)
                      ]

  redirect followingNum = do
    -- If the word before a redirect is a number then we insist on a space before ">" or "<".
    -- This avoids ambiguity in cases like "echo foo 11> x" (which is parsed as a redirect of FD 11)
    -- As opposed to "echo foo 11 > x" which echo "foo 11" to file x.
    --
    -- (we always insist on a space before "11>" or "11<")
    let leadWs = if followingNum then ws1 else ws
    alts
      [ do
          dest <- alts [ do leadWs; pure 0, do ws1; n <- fd; pure n ]
          symbol '<'
          let mode = OpenForReading
          ws
          src <- redirectRhs
          pure $ Redirect mode dest src
      , do
          dest <- alts [ do leadWs; pure 1, do ws1; n <- fd; pure n ]
          mode <-
            alts [ do symbol  '>';  pure $ OpenForWriting Truncate
                 , do keyword ">>"; pure $ OpenForWriting Append ]
          ws
          src <- redirectRhs
          pure $ Redirect mode dest src
      ]

  redirectRhs = alts
    [ RedirectRhsPath <$> word
    , do symbol '&'; RedirectRhsFD <$> fd
    , do symbol '&'; symbol '-'; pure RedirectRhsClose
    ]

  fd = FD <$> digits

  word = alts [ Word <$> ident
              , Word <$> quotedIdent
              , do keyword "$$"; pure DollarDollar
              , do keyword "$#"; pure DollarHash
              , do keyword "$"; DollarN <$> digits
              , do keyword "$"; DollarName <$> varname
              ]

  quotedIdent = do
    symbol q
    res <- many (sat (not . (== q)))
    symbol q
    pure res
      where q = '\''

  keyword string = mapM_ symbol string

  varname = Var <$> do
    x <- alpha
    xs <- many (alts [alpha,numer])
    pure (x : xs)

  ident = do
    x <- alts [alpha,numer,dash,dot,colon]
    xs <- many (alts [alpha,numer,dash,dot,colon])
    pure (x : xs)

  digits = digit >>= more
    where more n = alts [ pure n , do d <- digit; more (10*n+d)]

  digit = do c <- numer; pure (digitOfChar c)
    where digitOfChar c = Char.ord c - ord0 where ord0 = Char.ord '0'

  alpha = sat Char.isAlpha
  numer = sat Char.isDigit
  dash = sat (== '-')
  dot = sat (== '.')
  colon = sat (== ':')
  space = skip (sat Char.isSpace)

  symbol x = do t <-token; if t==x then pure () else fail
  sat pred = do c <- token; if pred c then pure c else fail

  ws = skipWhile space -- white*
  ws1 = do space; ws -- white+

  skip p = do _ <- p; eps
  eps = pure ()


isNumeric :: Word -> Bool
isNumeric = \case
  Word s -> all Char.isDigit s
  _ -> False
