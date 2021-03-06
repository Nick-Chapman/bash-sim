-- | Regression tests for 'sham' console interactions.
module Tests (run) where

import Data.List (isInfixOf)
import Testing (test)
import qualified FileSystem (ls)
import qualified Image (fs0,days,readme)
import qualified Path (toString,hidden)
import qualified Testing (run)

run :: IO ()
run = Testing.run $ do
  let days = Image.days
  let rw = map reverse days
  let merge xs ys = case xs of [] -> ys; x:xs -> x:merge ys xs
  let paths0 = [ Path.toString p | p <- FileSystem.ls Image.fs0, not (Path.hidden p) ]

  test ["man"] ["cat cut echo env exec exit grep kill ls lsof man mv ps read rev rm sham source sum type xargs"]

  test ["ls | xargs type | grep Data | cut 1 | xargs echo"] ["README countdown cp days head help pkill wc-l yes"]

  test ["echo foo"] ["foo"]
  test ["sham echo foo"] ["(stderr) cant open for reading: echo"]
  test ["sham -c echo foo"] ["foo"]

  test ["help"] Image.readme
  test [". help"] Image.readme
  test ["exec help"] Image.readme
  test ["sham help"] Image.readme
  test ["echo help | sham"] Image.readme
  test ["ls | grep lp | sham"] Image.readme
  test ["cat README"] Image.readme
  test ["sham cat README"] ["(stderr) cant open for reading: cat"]
  test ["sham -c cat README"] Image.readme
  test ["echo README | xargs cat"] Image.readme
  test ["cat README | xargs echo"] [ unwords Image.readme ]

  test ["*"] ["(stderr) unexpected '*' at position 1"]
  test ["*","echo ok"] ["(stderr) unexpected '*' at position 1","ok"]
  test ["README"] [
    "(stderr) README:1: unexpected '*' at position 12",
    "(stderr) README:2: unexpected ',' at position 31",
    "(stderr) no such executable: Type"]

  test ["ls"] paths0
  test ["exec ls"] paths0
  test ["sham ls"] ["(stderr) cant open for reading: ls"]
  test ["sham -c ls"] paths0
  test [". ls"] ["(stderr) cant open for reading: ls"]
  test ["echo ls | sham"] paths0
  test ["ls | xargs echo"] [unwords paths0]

  test ["echo cat | sham"] []

  test ["echo foo | rev"] ["oof"]
  test ["echo foo > x"," cat x | rev"] ["oof"]
  test ["echo rev > x","echo foo >> x"," cat x | sham"] ["oof"]
  test ["rev < days"] rw
  test ["cat days | rev"] rw
  test ["echo rev > x","cat days >> x","cat x | sham"] rw

  test ["rev < days > rw", "cat rw"] rw
  test ["cat days | rev | rev"] days
  test ["cat days | rev | rev | rev"] rw

  test ["echo foo | xargs ps"] ["(stderr) ps: takes no arguments"]

  test ["type"] ["(stderr) type: takes at least one argument"]
  test ["type ls help"] ["ls : Binary *ls*","help : Data/Script"]

  test ["man foo"] ["(stderr) man : no manual entry for 'foo'"]
  test ["man ps"] ["ps : list running processes"]
  test ["echo ps | xargs man"] ["ps : list running processes"]
  test ["echo ps mv | xargs man"] ["ps : list running processes","mv : rename a file"]

  test ["mv"] ["(stderr) mv: takes two arguments"]
  test ["mv xx yy"] ["(stderr) mv: no such path: xx"]
  test ["mv ps xx","type xx"] ["xx : Binary *ps*"]

  test ["rm foo help bar"] ["(stderr) rm: no such path: foo","(stderr) rm: no such path: bar"]
  test ["rm sham","help"] ["(stderr) no such executable: sham"]
  test ["mv ls .ls",".ls | xargs rm",".ls","echo oops"] ["oops"]

  test ["if 2=3 echo foo"] []
  test ["if 2!=3 echo foo"] ["foo"]
  test ["if 4=4 echo foo"] ["foo"]
  test ["if 4!=4 echo foo"] []

  test ["sum 100 -1 0 200"] ["299"]
  test ["sum 100 -1 0 x200"] ["(stderr) sum: unable to convert 'x200' to a number","99"]

  test ["cat days | head 1"] ["Monday"]
  test ["cat days | grep u | head 1"] ["Tuesday"]
  test ["yes | head 1", "echo woo hoo"] ["y","woo hoo"]
  test ["yes | head 2", "echo woo hoo"] ["y","y","woo hoo"]
  test ["yes | head 1", "yes | head 1"] ["y","y"]

  test ["countdown"] ["(stderr) countdown : takes one argument"]
  test ["countdown 0"] []
  test ["countdown 1"] ["1"]
  test ["countdown 3"] ["3","2","1"] -- test fails if countdown uses backgrounding to continue
  test ["countdown -1 | head 1"] ["-1"]

  test ["cat days | head 3"] (take 3 days)
  test ["head 3 < days"] (take 3 days)
  test ["countdown -1 | head 3"] ["-1","-2","-3"]

  test ["doh"] ["(stderr) no such executable: doh"]

  test ["echo $0"] ["sham"]
  test ["echo $1"] ["(stderr) $1 unbound",""]
  test ["echo $1","echo qaz"] ["(stderr) $1 unbound","","qaz"]
  test ["echo $1 qaz"] ["(stderr) $1 unbound"," qaz"]

  test ["cp README xx", "cat xx"] Image.readme
  test ["cp"] ["(stderr) cp : takes two arguments"]
  test ["cp foo"] ["(stderr) cp : takes two arguments"]
  test ["cp foo bar"] ["(stderr) no such path: foo"]

  test [] []
  test [""] []
  test ["echo"] [""]
  test ["echo foo", "echo bar"] ["foo","bar"]
  test ["echo foo bar"] ["foo bar"]
  test ["echo foo  bar"] ["foo bar"]
  test ["echo foo > x", "echo bar > x", "cat x"] ["bar"]
  test ["echo foo > x", "echo bar >> x", "cat x"] ["foo","bar"]

  test ["cat days"] days
  test ["cat days days"] (days ++ days)
  test ["cat days","cat days"] (days ++ days)
  test ["cat days","echo foo"] (days ++ ["foo"])
  test ["cat < days"] days

  test ["*"] ["(stderr) unexpected '*' at position 1"]
  test ["."] ["(stderr) unexpected end of line"]
  test ["exit nope"] ["(stderr) unexpected 'n' at position 6"]

  test ["rev nope"] ["(stderr) rev: takes no arguments"]
  test ["rev nope < days"] ["(stderr) rev: takes no arguments"]
  test ["ls nope"] ["(stderr) ls: takes no arguments, or a single '-a'"]
  test ["ps nope"] ["(stderr) ps: takes no arguments"]

  test ["echo doh > x","echo echo foo >> x","x"] ["(stderr) no such executable: doh","foo"]
  test ["echo doh > x","echo echo foo >> x","x > hide"] ["(stderr) no such executable: doh"]
  test ["echo doh > x","echo echo foo >> x","x 2> hide"] ["foo"]
  test ["echo doh > x","echo echo foo >> x","x 2>&1 > hide"] ["no such executable: doh"]
  test ["echo doh > x","echo echo foo >> x","x > hide 2>&1"] []
  test ["echo doh > x","echo echo foo >> x","x 3>&2 2>&1 1>&3"]
    ["no such executable: doh","(stderr) foo"]
  test ["echo doh > x","echo echo foo >> x","x 3>&1 1>&2 2>&3"]
    ["no such executable: doh","(stderr) foo"]

  test ["rev 0> x"] ["(stderr) &0 not readable"]
  test ["echo hey < days >&0"] ["(stderr) &1 not writable"]

  test ["echo AA 4< days >&4"] ["(stderr) &1 not writable"]
  test ["doh 4< days"] ["(stderr) no such executable: doh"]
  test ["doh 4< days 2>&4"] [] -- redirecting stderr to unwritable FD looses error

  test ["cat days &", "cat days"] (take 1 days ++ merge (drop 1 days) days) -- rather fragile

  test ["cat > x","echo OUT","echo ERR >&2","","x"] ["OUT","(stderr) ERR"]
  test ["cat > x","echo OUT","echo ERR >&2","",". x"] ["OUT","(stderr) ERR"]

  test ["exit"] []
  test ["cat > x","echo 1","exit","echo 2","","x"] ["1"]
  test ["echo exit > y","cat > x","echo 1","y","echo 2","","x"] ["1","2"]
  test ["echo exit > y","cat > x","echo 1",". y","echo 2","","x"] ["1"]

  test ["grep"] ["(stderr) grep: takes optional '-v' and one more argument"]
  test ["cat days | grep ur"] [ d | d <- days, "ur" `isInfixOf` d ]
  test ["grep ur < days"] [ d | d <- days, "ur" `isInfixOf` d ]
  test ["grep -v ur < days"] [ d | d <- days, not ("ur" `isInfixOf` d) ]

  test ["(echo foo; echo bar)"] ["foo","bar"]
  test ["(echo foo; echo bar) | rev"] ["oof","rab"]
  test ["(ls;cat days) | grep es"] ["yes","Tuesday","Wednesday"]

  test ["help &"] Image.readme
  test ["cat days &", "echo FOO"] ("FOO" : days)

  test ["exec 2>e","foo","bar","cat e"] ["no such executable: foo", "no such executable: bar"]
  test ["exec >&2", "echo foo"] ["(stderr) foo"]

  test ["echo foo >&0"] ["foo"]
  test ["echo foo >&1"] ["foo"]
  test ["echo foo >&2"] ["(stderr) foo"]
  test ["echo foo >&3"] ["(stderr) bad file descriptor: &3"]
  test ["echo foo >&7"] ["(stderr) bad file descriptor: &7"]
  test ["echo foo >&23"] ["(stderr) bad file descriptor: &23"]

  test ["echo foo <days >&0"] ["(stderr) &1 not writable"]
  test ["echo foo >&0 <days"] ["foo"]
  test ["(echo foo >&0) <days"] ["(stderr) &1 not writable"]

  test ["echo foo >&-"] ["(stderr) bad file descriptor: &1"]

  test ["((echo before >&4; lsof 4>&- 0<&- 2<&-; echo after >&4) | grep lsof | grep -v grep) 4>&1"]
    ["before","9 (lsof) &1 Write:pipe2","after"]

  test ["env"] ["Version=MeNicks-0.1","debug=0","prefix=sham"]
  test ["foo=123","echo $foo"] ["123"]
  test ["foo=123","bar=456","echo $foo $bar"] ["123 456"]
  test ["foo=ls","$foo"] paths0

  test ["echo $$","echo echo $$ > x","x"] ["2","2"]
  test ["echo $$","echo 'echo $$' > x","x"] ["2","4"]

  test ["wc-l < days"] ["7"]
  test ["wc-l days"] ["7"]
  test ["wc-l days days"] ["(stderr) wc-l : takes zero or one argument"]

  test ["ps"] ["1 init","2 sham","3 ps"]
  test ["exec ps"] ["1 init","2 ps"]
  test ["echo my pid is $$"] ["my pid is 2"]
  test [".me"] ["3"]
  test ["exec .me"] ["2"]
  test ["cat .me > a","echo .me >> a","a",".me"] ["5","6","7"]
  test ["cat .me > a","echo exec .me >> a","a",".me"] ["5","5","6"]

  test ["kill"] ["(stderr) kill: takes at least one argument"]
  test ["kill what"] ["(stderr) kill: not a pid: what"]
  test ["kill 99"] ["(stderr) kill: no such process: 99"]
  test ["kill 2"] []
  test ["kill 1","echo carry on after init gone"] ["carry on after init gone"]

  test ["echo foo11 >x", "cat x"] ["foo11"]
  test ["echo foo11>x", "cat x"] ["foo11"]
  test ["echo foo 11 >x", "cat x"] ["foo 11"]
  test ["echo foo 11>x"] ["foo"]
